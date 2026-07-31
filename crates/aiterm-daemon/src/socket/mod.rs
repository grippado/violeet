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
            tx,
        }
    }

    pub fn registry(&self) -> &Arc<Mutex<Registry>> {
        &self.registry
    }

    pub fn hitl(&self) -> &Arc<Mutex<HitlRegistry>> {
        &self.hitl
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
            // TODO(track-C): model comes from the transcript crate in Wave 2.
            model: None,
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
    fn snapshot(&self) -> Vec<DaemonToApp> {
        let mut out: Vec<DaemonToApp> = self
            .lock()
            .live_sessions()
            .map(Self::session_registered)
            .collect();
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
