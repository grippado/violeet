//! Unix socket server at `~/.aiterm/daemon.sock`.
//!
//! JSON-lines, one object per line, discriminated by `type`. The normative
//! contract is `docs/PROTOCOL.md`.
//!
//! # Isolation
//!
//! Every connection runs in its own pair of tasks (one reader, one writer) and
//! owns nothing shared except an `Arc<Mutex<Registry>>` and a broadcast
//! subscription. A client that hangs up, sends garbage, or stops reading cannot
//! stall the daemon or any other client:
//!
//! - a slow reader eventually **lags** its broadcast receiver; we log the gap
//!   and keep going rather than disconnecting it or blocking the sender
//! - a malformed line is dropped and logged; the protocol has no error reply
//! - a dead connection ends its own tasks and nothing else
//!
//! The registry mutex is only ever held across synchronous work — never across
//! an `.await` — so one connection cannot park it.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::Utc;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc};

use crate::hitl::{HitlRegistry, HitlRequest, NewHitl, Resolution};
use crate::registry::{HookObservation, HookOutcome, Registry, Session};
use crate::wire::{
    self, AppToDaemon, DaemonToApp, HitlOrigin, HitlPending, HitlResolved, Rejected,
    SessionRegistered, SessionUpdated, PROTOCOL_VERSION,
};

/// How many messages a slow client may fall behind before it starts losing
/// them. Generous: these are human-rate events.
const BROADCAST_CAPACITY: usize = 1024;

/// Per-connection unicast queue depth, used for snapshot replay.
const UNICAST_CAPACITY: usize = 256;

/// `docs/PROTOCOL.md`: a line longer than this is dropped rather than buffered.
const MAX_LINE_BYTES: u64 = 1024 * 1024;

/// Shared handle to the daemon's state and its outbound broadcast.
///
/// Two locks, never held at once. Nothing in this module needs both, and
/// keeping them separate means a long-running HITL cannot park the registry.
#[derive(Clone)]
pub struct Hub {
    registry: Arc<Mutex<Registry>>,
    hitl: Arc<Mutex<HitlRegistry>>,
    /// Transcripts currently being followed. A third lock, and like the other
    /// two it is never held while either of them is.
    transcripts: crate::transcript::SharedSupervisor,
    tx: broadcast::Sender<String>,
}

impl Hub {
    pub fn new(registry: Registry) -> Self {
        Self::with_hitl(registry, HitlRegistry::with_default_timeout())
    }

    /// Same, with an explicit HITL registry — tests use it to set a deadline
    /// they can actually reach.
    pub fn with_hitl(registry: Registry, hitl: HitlRegistry) -> Self {
        let (tx, _rx) = broadcast::channel(BROADCAST_CAPACITY);
        Self {
            registry: Arc::new(Mutex::new(registry)),
            hitl: Arc::new(Mutex::new(hitl)),
            transcripts: Arc::new(Mutex::new(
                crate::transcript::TranscriptSupervisor::new(),
            )),
            tx,
        }
    }

    pub fn registry(&self) -> &Arc<Mutex<Registry>> {
        &self.registry
    }

    pub fn hitl(&self) -> &Arc<Mutex<HitlRegistry>> {
        &self.hitl
    }

    pub fn transcripts(&self) -> &Mutex<crate::transcript::TranscriptSupervisor> {
        &self.transcripts
    }

    /// Read a session's transcript one last time, then stop following it.
    ///
    /// The final read is not optional bookkeeping: Claude Code writes a
    /// session's last lines *after* its `SessionEnd` hook fires, so dropping
    /// the watch on the hook leaves the card holding numbers that are wrong and
    /// look final.
    pub fn forget_transcript(&self, session_id: &str) {
        crate::transcript::finalize(self, session_id);
    }

    /// Is a permission request open for this session?
    ///
    /// The daemon's half of the cross-source state inference: the transcript
    /// can see a tool in flight but not why it has not returned, and this is
    /// the difference between `working` and `waiting_hitl`.
    pub fn has_pending_hitl(&self, session_id: &str) -> bool {
        match self.hitl.lock() {
            Ok(g) => g.pending().any(|r| r.session_id == session_id),
            Err(p) => p.into_inner().pending().any(|r| r.session_id == session_id),
        }
    }

    /// Lock the registry, recovering from a poisoned mutex rather than
    /// panicking. A panic in one connection must not take the daemon down with
    /// it: the registry's invariants are enforced by its own methods, not by
    /// the lock.
    fn lock(&self) -> MutexGuard<'_, Registry> {
        match self.registry.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Same recovery for the HITL registry, and for the same reason: a panic
    /// while one permission request is in flight must not strand every other.
    fn lock_hitl(&self) -> MutexGuard<'_, HitlRegistry> {
        match self.hitl.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Send to every connected client.
    ///
    /// Returns how many receivers it reached. Zero is normal — the app may
    /// simply not be running — and is never an error.
    pub fn broadcast(&self, msg: &DaemonToApp) -> usize {
        match msg.to_line() {
            Some(line) => self.tx.send(line).unwrap_or(0),
            None => {
                // Serializing our own type failed. Log and carry on: one
                // unsendable message must not stop the daemon.
                eprintln!("aiterm-daemon: could not serialize outbound message {msg:?}");
                0
            }
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<String> {
        self.tx.subscribe()
    }

    /// The `session_registered` message for a session as it stands.
    fn session_registered(session: &Session) -> DaemonToApp {
        DaemonToApp::SessionRegistered(SessionRegistered {
            v: PROTOCOL_VERSION,
            ts: wire::timestamp(Utc::now()),
            session_id: session.session_id.clone(),
            // A pending claim is not a binding: publish null, never a guess.
            tab_id: session.binding.bound_tab_id().map(str::to_string),
            agent: session.harness.as_wire().to_string(),
            // `null`, not `""`. A session first seen through a hook that carried
            // no working directory has none to report, and an empty string would
            // render as an empty path rather than as unknown.
            cwd: session.cwd.clone(),
            title: session.title.clone(),
            model: session.model.clone(),
            started_at: wire::timestamp(session.created_at),
        })
    }

    /// Feed in what a hook told us, and announce whatever changed.
    ///
    /// This is the HTTP layer's only way into the registry. It returns the raw
    /// [`HookOutcome`] so the caller can log a refused transition, but the
    /// caller never has to build a wire message itself.
    ///
    /// A refused transition publishes **nothing**. The registry leaves the
    /// session untouched in that case — including `last_event_at`, deliberately
    /// — so there is genuinely no change to report, and inventing a patch would
    /// tell the app a session is alive on the strength of an illegal move.
    pub fn observe_hook(&self, obs: HookObservation, now: chrono::DateTime<Utc>) -> HookOutcome {
        let (outcome, msg) = {
            let mut registry = self.lock();
            let outcome = registry.observe_hook(obs, now);

            let msg = match registry.session(&outcome.session_id) {
                _ if outcome.rejected_transition.is_some() => None,
                Some(session) if outcome.created => Some(Self::session_registered(session)),
                // A session that just finished gets no patch. `session_ended`
                // is the message that reports the end, and `Done`/`Dead` have
                // no wire state anyway — so a patch here would be a stateless
                // update about a card the app is one message away from
                // removing.
                Some(session) if session.state().is_finished() => None,
                Some(session) => {
                    let mut patch = SessionUpdated::new(&session.session_id, now);
                    if outcome.state_changed {
                        patch.state = session.state().wire_state().map(str::to_string);
                    }
                    if outcome.newly_bound {
                        patch.tab_id = Some(session.binding.bound_tab_id().map(str::to_string));
                    }
                    patch.cwd = Some(session.cwd.clone());
                    patch.last_event_at = Some(Some(wire::timestamp(session.last_event_at)));
                    Some(DaemonToApp::SessionUpdated(patch))
                }
                None => None,
            };
            (outcome, msg)
        };

        if let Some(msg) = msg {
            self.broadcast(&msg);
        }
        outcome
    }

    /// Fold a status line payload into a session and publish what changed.
    ///
    /// The status line fires on every frame of the agent's UI, so this is on a
    /// hot path and does almost nothing: it compares each field against what
    /// the app was last told and broadcasts only differences. A payload that
    /// changed nothing — the overwhelmingly common case — produces no message.
    pub fn observe_statusline(
        &self,
        session_id: &str,
        payload: &crate::http::StatusLinePayload,
        now: chrono::DateTime<Utc>,
    ) -> bool {
        let patch = {
            let mut registry = self.lock();
            // Only sessions we already know. The status line is not a
            // registration channel: a session aiterm has not seen through a
            // hook has no tab binding and no lifecycle, and inventing one here
            // would put a card on screen that the hooks never announced.
            let Some(session) = registry.session_mut(session_id) else {
                return false;
            };

            let mut patch = SessionUpdated::new(session_id, now);
            let mut anything = false;

            if let Some(window) = &payload.context_window {
                // The authoritative window size, which is the reason this
                // channel exists at all.
                if let Some(size) = window.context_window_size {
                    if session.tokens.context_window_size_tokens != Some(size) {
                        session.tokens.context_window_size_tokens = Some(size);
                        patch.context_window_size_tokens = Some(Some(size));
                        anything = true;
                    }
                }
            }

            if let Some(model) = payload.model.as_ref().and_then(|m| m.id.as_deref()) {
                if !model.is_empty() && session.model.as_deref() != Some(model) {
                    session.model = Some(model.to_string());
                    patch.model = Some(Some(model.to_string()));
                    anything = true;
                }
            }

            if let Some(limits) = &payload.rate_limits {
                macro_rules! copy_limit {
                    ($src:ident, $pct:ident, $at:ident, $patch_pct:ident, $patch_at:ident) => {
                        if let Some(window) = &limits.$src {
                            if let Some(pct) = window.used_percentage {
                                if session.limits.$pct != Some(pct) {
                                    session.limits.$pct = Some(pct);
                                    patch.$patch_pct = Some(Some(pct));
                                    anything = true;
                                }
                            }
                            if let Some(at) = window.resets_at {
                                if session.limits.$at != Some(at) {
                                    session.limits.$at = Some(at);
                                    patch.$patch_at = Some(Some(wire::timestamp(
                                        chrono::DateTime::from_timestamp(at, 0)
                                            .unwrap_or_else(Utc::now),
                                    )));
                                    anything = true;
                                }
                            }
                        }
                    };
                }
                copy_limit!(
                    five_hour,
                    five_hour_used_percent,
                    five_hour_resets_at,
                    five_hour_limit_used_percent,
                    five_hour_limit_resets_at
                );
                copy_limit!(
                    seven_day,
                    seven_day_used_percent,
                    seven_day_resets_at,
                    seven_day_limit_used_percent,
                    seven_day_limit_resets_at
                );
            }

            if !anything {
                return false;
            }
            patch
        };

        self.broadcast(&DaemonToApp::SessionUpdated(patch));
        true
    }

    /// The `hitl_pending` message for a request as it stands.
    fn hitl_pending(request: &HitlRequest) -> DaemonToApp {
        DaemonToApp::HitlPending(HitlPending {
            v: PROTOCOL_VERSION,
            ts: wire::timestamp(Utc::now()),
            hitl_id: request.hitl_id.clone(),
            session_id: request.session_id.clone(),
            tab_id: request.tab_id.clone(),
            tool_name: request.tool_name.clone(),
            tool_input: request.tool_input.clone(),
            permission_suggestions: request.permission_suggestions.clone(),
            expires_at: wire::timestamp(request.expires_at),
        })
    }

    /// Everything a freshly connected client needs, as ordinary messages.
    ///
    /// `docs/PROTOCOL.md` deliberately has no snapshot envelope and no
    /// end-of-snapshot marker: the daemon replays `session_registered` per live
    /// session, then `hitl_pending` per outstanding request. Clients treat all
    /// inbound messages as idempotent upserts, so a replay for something they
    /// already know is normal traffic.
    ///
    /// Sessions come first on purpose: a `hitl_pending` names a `session_id`,
    /// and a client that builds cards in arrival order should never meet a
    /// permission request for a session it has not been told about.
    /// Everything known about one session that `session_registered` cannot say.
    ///
    /// `session_registered` carries identity, not telemetry — the token
    /// numbers, the limits and the last action have no field there. Without
    /// this, a client that reconnects gets its cards back **blank** and stays
    /// blank until each session happens to move, which for an idle session is
    /// never. Replaying an ordinary `session_updated` is exactly what the
    /// protocol's "the snapshot is just ordinary messages" rule is for.
    fn session_telemetry(session: &Session, now: chrono::DateTime<Utc>) -> Option<DaemonToApp> {
        let mut patch = SessionUpdated::new(&session.session_id, now);

        patch.state = session.state().wire_state().map(str::to_string);
        if session.tokens.cumulative_input_tokens.is_some() {
            patch.cumulative_input_tokens = Some(session.tokens.cumulative_input_tokens);
        }
        if session.tokens.cumulative_output_tokens.is_some() {
            patch.cumulative_output_tokens = Some(session.tokens.cumulative_output_tokens);
        }
        if session.tokens.context_window_used_tokens.is_some() {
            patch.context_window_used_tokens = Some(session.tokens.context_window_used_tokens);
        }
        if session.tokens.context_window_size_tokens.is_some() {
            patch.context_window_size_tokens = Some(session.tokens.context_window_size_tokens);
        }
        if session.tokens.cumulative_tokens_partial.is_some() {
            patch.cumulative_tokens_partial = Some(session.tokens.cumulative_tokens_partial);
        }
        if session.limits.five_hour_used_percent.is_some() {
            patch.five_hour_limit_used_percent = Some(session.limits.five_hour_used_percent);
        }
        if session.limits.seven_day_used_percent.is_some() {
            patch.seven_day_limit_used_percent = Some(session.limits.seven_day_used_percent);
        }
        if let Some(at) = session.limits.five_hour_resets_at {
            patch.five_hour_limit_resets_at = Some(Some(wire::timestamp(
                chrono::DateTime::from_timestamp(at, 0).unwrap_or(now),
            )));
        }
        if let Some(at) = session.limits.seven_day_resets_at {
            patch.seven_day_limit_resets_at = Some(Some(wire::timestamp(
                chrono::DateTime::from_timestamp(at, 0).unwrap_or(now),
            )));
        }
        if session.last_action.is_some() {
            patch.last_action = Some(session.last_action.clone());
        }
        if session.git_branch.is_some() {
            patch.git_branch = Some(session.git_branch.clone());
        }
        patch.last_event_at = Some(Some(wire::timestamp(session.last_event_at)));

        (!patch.is_empty()).then_some(DaemonToApp::SessionUpdated(patch))
    }

    fn snapshot(&self) -> Vec<DaemonToApp> {
        let now = Utc::now();

        // Each session is announced, then filled in. `session_registered`
        // carries identity only — the telemetry has no field there — so a
        // client reconnecting would otherwise get blank cards that stay blank
        // until each session next moves, which for an idle one is never.
        let mut out: Vec<DaemonToApp> = Vec::new();
        {
            let registry = self.lock();
            for session in registry.live_sessions() {
                out.push(Self::session_registered(session));
                if let Some(telemetry) = Self::session_telemetry(session, now) {
                    out.push(telemetry);
                }
            }
        }

        out.extend(self.lock_hitl().pending().map(Self::hitl_pending));
        out
    }

    /// Park a permission request, announce it, and hand back the channel the
    /// HTTP handler waits on.
    pub fn open_hitl(
        &self,
        new: NewHitl,
        now: chrono::DateTime<Utc>,
    ) -> (HitlRequest, tokio::sync::oneshot::Receiver<Resolution>) {
        let (request, rx) = self.lock_hitl().open(new, now);
        self.broadcast(&Self::hitl_pending(&request));
        (request, rx)
    }

    /// Resolve a request and announce it. Returns whether anything was there.
    ///
    /// Announcing happens after the lock is dropped, and only when a request
    /// was actually consumed — so the exactly-once guarantee on `hitl_resolved`
    /// comes from the registry's first-wins removal, not from a check here.
    pub fn resolve_hitl(&self, hitl_id: &str, resolution: Resolution) -> bool {
        let origin = resolution.origin;
        let decision = resolution.decision.as_ref().map(|d| d.behavior.clone());

        let Some(request) = self.lock_hitl().resolve(hitl_id, resolution) else {
            return false;
        };

        self.broadcast(&DaemonToApp::HitlResolved(HitlResolved {
            v: PROTOCOL_VERSION,
            ts: wire::timestamp(Utc::now()),
            hitl_id: request.hitl_id,
            session_id: request.session_id,
            origin,
            decision,
        }));
        true
    }

    /// Announce a resolution the HITL registry already performed.
    ///
    /// Used by the paths that resolve in bulk — expiry, and a session ending —
    /// where the removal happened inside the registry and only the broadcast is
    /// left to do.
    fn announce_resolved(&self, request: &HitlRequest, origin: HitlOrigin) {
        self.broadcast(&DaemonToApp::HitlResolved(HitlResolved {
            v: PROTOCOL_VERSION,
            ts: wire::timestamp(Utc::now()),
            hitl_id: request.hitl_id.clone(),
            session_id: request.session_id.clone(),
            origin,
            // Only the app path knows what was chosen.
            decision: None,
        }));
    }

    /// End a session: clear its permission requests, then announce the end.
    ///
    /// The order is required by `docs/PROTOCOL.md` and is the whole reason this
    /// helper exists. A `session_ended` that arrives while the app still holds a
    /// `hitl_pending` card for that session leaves the app garbage-collecting
    /// orphans, which is exactly the bookkeeping the protocol promises it will
    /// never have to do.
    /// Announce a session's end and release what was following it.
    ///
    /// Dropping the transcript watcher here matters: it owns a thread and a
    /// filesystem watch, and a daemon that ran for a day would otherwise hold
    /// one of each for every session it had ever seen.
    pub fn publish_session_ended(
        &self,
        session_id: &str,
        tab_id: Option<String>,
        reason: wire::EndReason,
        now: chrono::DateTime<Utc>,
    ) {
        let orphaned = self
            .lock_hitl()
            .resolve_all_for_session(session_id, HitlOrigin::DaemonError);
        for request in &orphaned {
            self.announce_resolved(request, HitlOrigin::DaemonError);
        }

        self.forget_transcript(session_id);
        self.broadcast(&DaemonToApp::SessionEnded(wire::SessionEnded {
            v: PROTOCOL_VERSION,
            ts: wire::timestamp(now),
            session_id: session_id.to_string(),
            tab_id,
            reason,
        }));
    }


    /// The tab a session is bound to, if it is bound at all.
    ///
    /// A *pending* claim answers `None`, same as everywhere else: it is not a
    /// binding until the tab is known.
    pub fn bound_tab_of(&self, session_id: &str) -> Option<String> {
        self.lock()
            .session(session_id)?
            .binding
            .bound_tab_id()
            .map(str::to_string)
    }

    /// The human answered in the terminal and won the race.
    ///
    /// Returns whether a request was actually consumed. `false` is the common
    /// case by far: most `PostToolUse` hooks are for calls that never needed a
    /// permission decision at all.
    pub fn resolve_tui_race(
        &self,
        session_id: &str,
        tool_name: &str,
        tool_input: &serde_json::Value,
    ) -> bool {
        let Some(request) = self
            .lock_hitl()
            .resolve_tui_race(session_id, tool_name, tool_input)
        else {
            return false;
        };
        self.announce_resolved(&request, HitlOrigin::Tui);
        true
    }

    /// Resolve everything past its deadline and announce each one.
    ///
    /// Returns how many fired, for the caller's log.
    pub fn expire_hitl(&self, now: chrono::DateTime<Utc>) -> usize {
        let expired = self.lock_hitl().expire(now);
        for request in &expired {
            self.announce_resolved(request, HitlOrigin::Timeout);
        }
        expired.len()
    }

    /// Apply one inbound command. Returns messages for *this* client only;
    /// anything the others need is broadcast from inside.
    pub fn handle(&self, msg: AppToDaemon) -> Vec<DaemonToApp> {
        let now = Utc::now();

        match msg {
            AppToDaemon::RegisterTab { tab_id, cwd } => {
                // Build the patches while holding the lock, broadcast after
                // dropping it.
                let patches: Vec<SessionUpdated> = {
                    let mut registry = self.lock();
                    let bound = registry.register_tab(tab_id, cwd, now);
                    bound
                        .into_iter()
                        .filter_map(|id| {
                            let session = registry.session(&id)?;
                            let mut patch = SessionUpdated::new(&session.session_id, now);
                            patch.tab_id = Some(session.binding.bound_tab_id().map(str::to_string));
                            Some(patch)
                        })
                        .collect()
                };

                for patch in patches {
                    self.broadcast(&DaemonToApp::SessionUpdated(patch));
                }
                Vec::new()
            }

            AppToDaemon::CloseTab { tab_id } => {
                // The registry marks the tab's sessions dead; we announce each
                // one. Built under the lock, published after dropping it.
                let killed = self.lock().close_tab(&tab_id, now);

                // An unknown tab kills nothing and says nothing. Per
                // docs/PROTOCOL.md that is the normal outcome, not an error.
                for session_id in killed {
                    self.publish_session_ended(
                        &session_id,
                        Some(tab_id.clone()),
                        wire::EndReason::TabClosed,
                        now,
                    );
                }
                Vec::new()
            }

            AppToDaemon::RenameSession { session_id, title } => {
                let patch = {
                    let mut registry = self.lock();
                    registry.rename_session(&session_id, &title, now).then(|| {
                        let mut patch = SessionUpdated::new(&session_id, now);
                        patch.title = Some(Some(title));
                        patch
                    })
                };

                // An unknown session produces nothing. The protocol has no error
                // reply and inventing one would be a unilateral extension.
                if let Some(patch) = patch {
                    self.broadcast(&DaemonToApp::SessionUpdated(patch));
                }
                Vec::new()
            }

            AppToDaemon::RequestSnapshot {} => self.snapshot(),

            AppToDaemon::ResolveHitl { hitl_id, decision } => {
                // An unknown or already-resolved id is silently ignored: per
                // docs/PROTOCOL.md that is the normal outcome of the race with
                // the terminal, not an error. The app learns the real outcome
                // from `hitl_resolved` either way, which is why it must treat
                // its own click as a request rather than a fact.
                self.resolve_hitl(&hitl_id, Resolution::from_app(decision));
                Vec::new()
            }
        }
    }
}

/// A bound listener, ready to serve.
pub struct SocketServer {
    listener: UnixListener,
    path: PathBuf,
    hub: Hub,
}

impl SocketServer {
    /// Bind the socket, replacing a stale one if present.
    ///
    /// Created `0600`: this is a local, single-user channel and filesystem
    /// permissions are the whole of its access control (ADR-002).
    pub fn bind(path: impl AsRef<Path>, hub: Hub) -> io::Result<Self> {
        let path = path.as_ref().to_path_buf();

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        // A socket file left behind by a crashed daemon would make bind() fail
        // with EADDRINUSE. Removing it is what the protocol document promises.
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }

        let listener = UnixListener::bind(&path)?;

        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        }

        Ok(Self {
            listener,
            path,
            hub,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn hub(&self) -> &Hub {
        &self.hub
    }

    /// Accept forever. Each connection is spawned and then forgotten.
    ///
    /// An accept error is logged and the loop continues: one failed connection
    /// must not end the daemon.
    pub async fn serve(self) -> io::Result<()> {
        loop {
            match self.listener.accept().await {
                Ok((stream, _addr)) => {
                    let hub = self.hub.clone();
                    tokio::spawn(async move {
                        if let Err(e) = serve_connection(stream, hub).await {
                            eprintln!("aiterm-daemon: client connection ended: {e}");
                        }
                    });
                }
                Err(e) => eprintln!("aiterm-daemon: accept failed: {e}"),
            }
        }
    }
}

impl Drop for SocketServer {
    fn drop(&mut self) {
        // Best effort: a stale socket left behind is survivable, since bind()
        // unlinks it. Not worth reporting.
        let _ = std::fs::remove_file(&self.path);
    }
}

/// One client: a writer task fed by both the broadcast and a unicast queue, and
/// a reader loop on this task.
pub async fn serve_connection(stream: UnixStream, hub: Hub) -> io::Result<()> {
    let (read_half, mut write_half) = stream.into_split();

    let mut broadcast_rx = hub.subscribe();
    let (unicast_tx, mut unicast_rx) = mpsc::channel::<String>(UNICAST_CAPACITY);

    let writer = tokio::spawn(async move {
        loop {
            let line = tokio::select! {
                // Unicast first: a snapshot the client explicitly asked for
                // should not queue behind unrelated broadcast traffic.
                biased;

                got = unicast_rx.recv() => match got {
                    Some(line) => line,
                    None => break,
                },
                got = broadcast_rx.recv() => match got {
                    Ok(line) => line,
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        // This client read too slowly and missed messages. It is
                        // not disconnected: it can recover with request_snapshot.
                        eprintln!("aiterm-daemon: client lagged, dropped {n} messages");
                        continue;
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                },
            };

            if write_half.write_all(line.as_bytes()).await.is_err() {
                break; // client hung up; its own problem, nobody else's
            }
        }
        let _ = write_half.shutdown().await;
    });

    let mut lines = BufReader::new(read_half.take(MAX_LINE_BYTES)).lines();
    loop {
        let line = match lines.next_line().await {
            Ok(Some(line)) => line,
            Ok(None) => break, // clean EOF
            Err(e) => {
                eprintln!("aiterm-daemon: read error from client: {e}");
                break;
            }
        };

        if line.trim().is_empty() {
            continue;
        }

        match wire::parse_inbound(&line) {
            Ok(msg) => {
                for reply in hub.handle(msg) {
                    if let Some(line) = reply.to_line() {
                        // A full queue means a client that asked for a snapshot
                        // and then stopped reading. Drop rather than block.
                        if unicast_tx.try_send(line).is_err() {
                            eprintln!("aiterm-daemon: client unicast queue full, dropping reply");
                        }
                    }
                }
            }
            // The protocol has no error reply, by design. Log and move on.
            Err(Rejected::Malformed(why)) => {
                eprintln!("aiterm-daemon: dropping malformed line: {why}")
            }
            Err(Rejected::UnsupportedVersion(v)) => {
                eprintln!("aiterm-daemon: dropping message with unsupported v={v}")
            }
            Err(Rejected::UnknownType(ty)) => {
                eprintln!("aiterm-daemon: ignoring unknown message type {ty:?}")
            }
        }
    }

    drop(unicast_tx);
    let _ = writer.await;
    Ok(())
}

/// The default socket path, `~/.aiterm/daemon.sock`.
pub fn default_socket_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(aiterm_proto::SOCKET_RELATIVE_PATH))
}
