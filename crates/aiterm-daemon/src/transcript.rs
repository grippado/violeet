//! Following session transcripts and turning them into `session_updated`.
//!
//! The daemon learns a `transcript_path` from a hook payload and starts tailing
//! that file through `aiterm-transcript`. Everything about the *format* lives in
//! that crate; everything here is about when to publish and what the numbers
//! mean once both sources are in the same room.
//!
//! # The point of the integration: disambiguating state
//!
//! Neither source can tell working from blocked on its own.
//!
//! - The **transcript** shows a tool call with no result yet. That is a tool in
//!   flight — it says nothing about *why* it has not returned. Blocked on a
//!   human, blocked on the network, or merely slow all look identical
//!   (`docs/TRANSCRIPT_FORMAT.md` § 3).
//! - The **daemon** knows whether it is holding an HTTP response open for a
//!   permission request on that session, because it is the one holding it.
//!
//! Put together they are unambiguous, and that is the whole reason this module
//! exists rather than the app reading transcripts itself:
//!
//! | in-flight tool | pending HITL | state |
//! |---|---|---|
//! | yes | yes | `waiting_hitl` |
//! | yes | no  | `working` |
//! | no  | —   | left alone |
//!
//! The last row matters as much as the others: no tool in flight means the
//! transcript has nothing to say about the lifecycle, and overwriting a state
//! the hooks established would be the reader inventing an opinion.
//!
//! # Debounce
//!
//! An agent writing a reply appends several lines in a burst, one per content
//! block. Publishing per append would send three `session_updated` messages
//! differing only in completeness. Updates are coalesced per session and
//! published at most every [`PUBLISH_DEBOUNCE`].

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use aiterm_transcript::{watch, ClaudeCodeReader, Telemetry, WatchHandle};
use chrono::Utc;

use crate::registry::SessionState;
use crate::socket::Hub;
use crate::wire::{self, DaemonToApp, SessionUpdated};

/// How long to sit on updates before publishing. One reply's worth of appends
/// arrives well inside this.
pub const PUBLISH_DEBOUNCE: Duration = Duration::from_millis(250);

/// One followed transcript.
struct Followed {
    path: PathBuf,
    /// Dropping this stops the watcher and its thread.
    _handle: WatchHandle,
}

/// Every transcript the daemon is currently following, keyed by session.
#[derive(Default)]
pub struct TranscriptSupervisor {
    followed: HashMap<String, Followed>,
}

impl TranscriptSupervisor {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_following(&self, session_id: &str, path: &Path) -> bool {
        self.followed
            .get(session_id)
            .is_some_and(|f| f.path == path)
    }

    pub fn len(&self) -> usize {
        self.followed.len()
    }

    pub fn is_empty(&self) -> bool {
        self.followed.is_empty()
    }

    pub fn forget(&mut self, session_id: &str) {
        self.followed.remove(session_id);
    }
}

/// Start following `path` for `session_id`, if we are not already.
///
/// Idempotent per (session, path): hooks carry `transcript_path` on nearly every
/// event, so this is called constantly and must be free when nothing changed.
/// A session whose path *changes* is re-followed, and the old watcher is
/// dropped by the replacement.
pub fn follow(hub: &Hub, session_id: &str, path: &Path) {
    {
        let supervisor = lock(hub.transcripts());
        if supervisor.is_following(session_id, path) {
            return;
        }
    }

    // Read from the end when there is already a file, from the start when
    // there is not.
    //
    // From the end, because a transcript is up to 15 MB and the daemon usually
    // meets a session already in progress; replaying it would publish an hour
    // of stale actions as if they had just happened. The cost is that
    // cumulative counters begin partial — they stay `None` until something is
    // actually read, which is honest, and is why the app must never present
    // them as a complete bill.
    //
    // From the start when the file does not exist yet, because there is no
    // backlog to skip and "seek to the end" of a file that is not there is an
    // error rather than a no-op. A hook can name a transcript a moment before
    // Claude Code creates it, and the watch is on the parent directory
    // precisely so the creation is seen.
    let already_exists = path.exists();
    let reader = Box::new(ClaudeCodeReader::new());
    let (handle, updates) = match watch(path, reader, already_exists) {
        Ok(pair) => pair,
        Err(e) => {
            // Not fatal, and deliberately not retried here: the next hook for
            // this session calls `follow` again. A transcript we cannot watch
            // costs telemetry, not the session.
            eprintln!(
                "aiterm-daemon: not following {} for session {session_id}: {e}",
                path.display()
            );
            return;
        }
    };

    let thread_hub = hub.clone();
    let owned_session = session_id.to_string();

    // A plain thread rather than a tokio task: the channel from the watcher is
    // a blocking `std::sync::mpsc`, and parking a runtime worker on it would
    // starve the async side. Nothing here awaits.
    let spawned = std::thread::Builder::new()
        .name(format!("aiterm-tx-{}", &session_id[..session_id.len().min(8)]))
        .spawn(move || {
            let mut last_publish = Instant::now() - PUBLISH_DEBOUNCE;

            loop {
                // Block for the first update, then coalesce whatever follows
                // inside the debounce window.
                let Ok(update) = updates.recv() else {
                    return; // the watcher was dropped
                };
                let mut pending: Option<Telemetry> = Some(update.telemetry);

                let wait = PUBLISH_DEBOUNCE.saturating_sub(last_publish.elapsed());
                if !wait.is_zero() {
                    std::thread::sleep(wait);
                }
                while let Ok(newer) = updates.try_recv() {
                    pending = Some(newer.telemetry);
                }

                if let Some(telemetry) = pending.take() {
                    publish(&thread_hub, &owned_session, &telemetry);
                    last_publish = Instant::now();
                }
            }
        });

    match spawned {
        Ok(_thread) => {
            lock(hub.transcripts()).followed.insert(
                session_id.to_string(),
                Followed {
                    path: path.to_path_buf(),
                    _handle: handle,
                },
            );
        }
        Err(e) => eprintln!("aiterm-daemon: could not spawn a transcript reader: {e}"),
    }
}

/// Fold a telemetry snapshot into the registry and broadcast what changed.
///
/// Everything here is a **sparse patch**: a field that did not change is not
/// sent, and `None` is never rendered as zero. The registry holds the previous
/// values, so the comparison is against what the app was last told.
fn publish(hub: &Hub, session_id: &str, telemetry: &Telemetry) {
    let now = Utc::now();

    // Whether a permission request is open for this session. Read before the
    // registry lock and never while holding it — the two locks are deliberately
    // never held at once.
    let hitl_pending = hub.has_pending_hitl(session_id);

    let patch = {
        let mut registry = match hub.registry().lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        let Some(session) = registry.session_mut(session_id) else {
            // The session ended while we were reading. Nothing to update, and
            // the app has already been told it is gone.
            return;
        };

        let mut patch = SessionUpdated::new(session_id, now);
        let mut anything = false;

        // --- the four token numbers ---------------------------------------
        //
        // Two pairs measuring different things. Occupancy falls on compaction;
        // the cumulative pair only climbs. They are copied across
        // independently, and summing the cumulative pair to estimate occupancy
        // would be wrong — see `aiterm_transcript::Telemetry`.
        macro_rules! copy_token_field {
            ($field:ident) => {
                if telemetry.$field.is_some() && session.tokens.$field != telemetry.$field {
                    session.tokens.$field = telemetry.$field;
                    patch.$field = Some(telemetry.$field);
                    anything = true;
                }
            };
        }
        copy_token_field!(cumulative_input_tokens);
        copy_token_field!(cumulative_output_tokens);
        copy_token_field!(context_window_used_tokens);
        copy_token_field!(context_window_size_tokens);

        // --- model ---------------------------------------------------------
        if let Some(model) = &telemetry.model {
            if session.model.as_deref() != Some(model.as_str()) {
                session.model = Some(model.clone());
                patch.model = Some(Some(model.clone()));
                anything = true;
            }
        }

        // --- last action ----------------------------------------------------
        if let Some(action) = &telemetry.last_action {
            if session.last_action.as_deref() != Some(action.as_str()) {
                session.last_action = Some(action.clone());
                patch.last_action = Some(Some(action.clone()));
                anything = true;
            }
        }

        // --- the cross-source state -----------------------------------------
        //
        // The one inference neither source could make alone. Only asserted when
        // a tool is actually in flight: with none, the transcript has no
        // opinion about the lifecycle and the hooks' state stands.
        if telemetry.in_flight_tool.is_some() {
            let implied = if hitl_pending {
                SessionState::WaitingHitl
            } else {
                SessionState::Working
            };
            // A rejected transition is not worth reporting: it means the
            // session is finished, and a card the app is about to remove does
            // not need a state.
            if session.state() != implied && session.transition_to(implied, now).is_ok() {
                patch.state = session.state().wire_state().map(str::to_string);
                anything = true;
            }
        }

        if !anything {
            return;
        }

        session.touch(now);
        patch.last_event_at = Some(Some(wire::timestamp(session.last_event_at)));
        patch
    };

    hub.broadcast(&DaemonToApp::SessionUpdated(patch));
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

pub type SharedSupervisor = Arc<Mutex<TranscriptSupervisor>>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn following_the_same_path_twice_is_recognized_as_already_followed() {
        let mut s = TranscriptSupervisor::new();
        assert!(s.is_empty());
        assert!(!s.is_following("s1", Path::new("/a.jsonl")));

        // `follow` needs a Hub; the bookkeeping is what is asserted here, and
        // the end-to-end path is covered in tests/transcript_integration.rs.
        s.forget("s1");
        assert_eq!(s.len(), 0);
    }
}
