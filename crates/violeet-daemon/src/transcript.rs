//! Following session transcripts and turning them into `session_updated`.
//!
//! The daemon learns a `transcript_path` from a hook payload and starts tailing
//! that file through `violeet-transcript`. Everything about the *format* lives in
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

use violeet_transcript::{watch_shared, ClaudeCodeReader, CursorReader, Telemetry, TranscriptSession, WatchHandle};
use chrono::Utc;

use crate::registry::{Harness, SessionState, TitleSource};
use crate::socket::Hub;
use crate::wire::{self, DaemonToApp, FileChange as WireFileChange, SessionUpdated};

/// How long to sit on updates before publishing. One reply's worth of appends
/// arrives well inside this.
pub const PUBLISH_DEBOUNCE: Duration = Duration::from_millis(250);

/// One followed transcript.
struct Followed {
    path: PathBuf,
    /// Dropping this stops the watcher and its thread.
    _handle: WatchHandle,
    /// Shared with the watcher thread, so the session can be read one last
    /// time before the watch is dropped. See `finalize`.
    session: Arc<Mutex<TranscriptSession>>,
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

    /// Take a session out of the table, handing back what was following it.
    fn take(&mut self, session_id: &str) -> Option<Followed> {
        self.followed.remove(session_id)
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
///
/// `hook_harness` is what the current hook claims. When the session is already
/// in the registry, its stored harness wins — the first hook may call `follow`
/// before `observe_hook` registers the session.
pub fn follow(hub: &Hub, session_id: &str, path: &Path, hook_harness: Harness) {
    {
        let supervisor = lock(hub.transcripts());
        if supervisor.is_following(session_id, path) {
            return;
        }
    }

    let harness = {
        let registry = lock(hub.registry());
        registry
            .session(session_id)
            .map(|s| s.harness)
            .unwrap_or(hook_harness)
    };

    // Always from the start. This used to read from the end of a transcript
    // that already existed, and the reasoning was about the wrong thing.
    //
    // The fear was replaying an hour of stale actions as if they had just
    // happened, and that fear is right about *events*. It is wrong about
    // *numbers*, which is what the backlog actually carries: token totals and
    // the files the session wrote. Skipping it did not avoid publishing stale
    // data, it published `partial` forever — every counter tilde'd and the
    // Files panel saying "File changes unknown" for a session whose whole
    // history was sitting on disk, unread.
    //
    // The distinction that makes reading it safe: the watcher emits one update
    // per *batch*, not per event. Reading the file in one pass produces a
    // single update carrying the complete totals and the genuinely last action,
    // rather than an hour of actions arriving one by one. Nothing is presented
    // as newer than it is; `last_event_at` still comes from the event.
    //
    // The cost is one parse of a file that can reach 15 MB, once, when a
    // session is adopted. That buys exact counters instead of permanently
    // approximate ones, which is the whole point of measuring rather than
    // estimating.
    //
    // `false` also covers the case the old flag existed for: seeking to the end
    // of a file that does not exist yet is an error, and a hook can name a
    // transcript a moment before Claude Code creates it.
    let from_end = false;

    let reader: Box<dyn violeet_transcript::TranscriptReader> = match harness {
        Harness::Cursor => Box::new(CursorReader::new()),
        _ => Box::new(ClaudeCodeReader::new()),
    };
    let (handle, updates, shared) = match watch_shared(path, reader, from_end) {
        Ok(pair) => pair,
        Err(e) => {
            // Not fatal, and deliberately not retried here: the next hook for
            // this session calls `follow` again. A transcript we cannot watch
            // costs telemetry, not the session.
            eprintln!(
                "violeet-daemon: not following {} for session {session_id}: {e}",
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
        .name(format!("violeet-tx-{}", &session_id[..session_id.len().min(8)]))
        .spawn(move || {
            let mut last_publish = Instant::now() - PUBLISH_DEBOUNCE;

            loop {
                // Block for the first update, then coalesce whatever follows
                // inside the debounce window.
                let Ok(update) = updates.recv() else {
                    return; // the watcher was dropped
                };
                let mut partial = update.cumulative_is_partial;
                let mut pending: Option<Telemetry> = Some(update.telemetry);

                let wait = PUBLISH_DEBOUNCE.saturating_sub(last_publish.elapsed());
                if !wait.is_zero() {
                    std::thread::sleep(wait);
                }
                while let Ok(newer) = updates.try_recv() {
                    partial = newer.cumulative_is_partial;
                    pending = Some(newer.telemetry);
                }

                if let Some(telemetry) = pending.take() {
                    publish(&thread_hub, &owned_session, &telemetry, partial, false);
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
                    session: shared,
                },
            );
        }
        Err(e) => eprintln!("violeet-daemon: could not spawn a transcript reader: {e}"),
    }
}

/// Read a session's transcript one last time, then stop following it.
///
/// Called when the session ends. It matters because **a session's last lines
/// are written after its `SessionEnd` hook fires**: dropping the watch on the
/// hook loses them, and the counters left on the card are wrong while looking
/// final. Measured before this existed: a card showing 345 output tokens for a
/// session whose transcript recorded 489.
///
/// Best effort by design. If the final read fails the numbers stay as they
/// were, which is the same outcome as not having tried — a session already
/// ending is not worth an error path.
pub fn finalize(hub: &Hub, session_id: &str) {
    let Some(followed) = lock(hub.transcripts()).take(session_id) else {
        return;
    };

    let final_read = {
        let mut session = lock(&followed.session);
        session
            .read()
            .ok()
            .map(|_| (session.telemetry().clone(), session.cumulative_is_partial()))
    };

    if let Some((telemetry, partial)) = final_read {
        // `ending`: this is the `SessionEnd` path, so whatever launches are
        // still open on the last line are open on a session that no longer
        // exists. See the `pending_agents` block in `publish`.
        publish(hub, session_id, &telemetry, partial, true);
    }
    // `followed` drops here, taking the watcher and its thread with it.
}

/// Fold a telemetry snapshot into the registry and broadcast what changed.
///
/// Everything here is a **sparse patch**: a field that did not change is not
/// sent, and `None` is never rendered as zero. The registry holds the previous
/// values, so the comparison is against what the app was last told.
/// Name a session from the head of its own transcript.
///
/// This is the answer to the adopted-session case: one already running when
/// violeet first saw it has no first `UserPromptSubmit` to hook, but its first
/// prompt is still in the file, and so, usually, is Claude Code's `ai-title` —
/// both within the first dozen lines. Reading them gives an adopted session the
/// same name, by the same rules, as one violeet started, which is what keeps the
/// sidebar to a single register instead of two kinds of card.
///
/// The alternative considered was leaving it on the working directory until a
/// summary turned up. Rejected on measurement: `summary` appears in **none** of
/// the transcripts on this machine, so "until" would have meant "never" — and
/// the outside sessions, the ones you most need to identify because you cannot
/// see their window, would have been the only ones permanently named after a
/// folder.
///
/// Called once, when the session is first registered, and not from `follow`:
/// the watch is started before the registry knows the session exists, and a
/// title offered to a session that is not there yet goes nowhere.
///
/// The stronger source wins on its own: `offer_title` refuses a downgrade, so
/// offering the derived name first and the `ai-title` second cannot leave the
/// weaker one in place — and a session the human already renamed keeps its name
/// through both.
pub fn name_from_head(hub: &Hub, session_id: &str, path: &Path) {
    let scan = match violeet_transcript::claude_code::scan_head(path) {
        Ok(scan) if !scan.is_empty() => scan,
        // Unreadable, or a file with nothing nameable in its first lines. The
        // session keeps whatever it has; there is no worse name to fall to.
        _ => return,
    };
    let now = Utc::now();

    if let Some(derived) = scan
        .first_prompt
        .as_deref()
        .and_then(violeet_transcript::title::from_prompt)
    {
        hub.offer_title(session_id, &derived, TitleSource::Prompt, now);
    }
    if let Some(ai) = &scan.ai_title {
        hub.offer_title(session_id, ai, TitleSource::AiTitle, now);
    }
}

/// How many files one message may carry.
///
/// The client reads whole lines and **drops** one longer than its limit rather
/// than buffering it, so an unbounded list does not arrive truncated — it does
/// not arrive, and the panel stops updating with nothing on screen to say why.
/// At roughly 120 bytes an entry this leaves the line an order of magnitude
/// inside that limit even for a session that rewrote a monorepo.
const MAX_FILES_ON_WIRE: usize = 500;

/// The file list as it goes on the wire, and whether it had to be cut.
///
/// Cutting keeps the first N by path rather than by size or recency: the panel
/// renders a tree, and a tree missing a random half is harder to read than one
/// that stops. The flag is what keeps it honest either way.
fn wire_files(telemetry: &Telemetry) -> (Vec<WireFileChange>, bool) {
    let truncated = telemetry.files.len() > MAX_FILES_ON_WIRE;
    let files = telemetry
        .files
        .iter()
        .take(MAX_FILES_ON_WIRE)
        .map(|(path, stat)| WireFileChange {
            path: path.clone(),
            added: stat.added,
            removed: stat.removed,
            created: stat.created,
        })
        .collect();
    (files, truncated)
}

/// What `pending_agents` goes on the wire as: a count, or nothing at all.
///
/// A pure function so the rule can be read and tested without a Hub, because it
/// is a rule about *what a number claims* rather than about plumbing.
///
/// - **`ending`** — the `SessionEnd` path. The session is gone, so it waits on
///   nothing, whatever the last lines say about launches that never reported.
/// - **`partial` with a count of zero** — we met this session already running,
///   so launches from before we started looking are not in our sets. `0` there
///   is the positive claim "waiting on none" with nothing behind it, so the
///   field is left unknown instead.
/// - **`partial` with a positive count** — still published. That launch is one we
///   read with our own eyes; a partial read weakens what a zero means, not what a
///   one means.
fn pending_on_wire(counted: u64, partial: bool, ending: bool) -> Option<u64> {
    match (ending, partial, counted) {
        (true, _, _) => Some(0),
        (false, true, 0) => None,
        (false, _, n) => Some(n),
    }
}

fn publish(hub: &Hub, session_id: &str, telemetry: &Telemetry, partial: bool, ending: bool) {
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
        // would be wrong — see `violeet_transcript::Telemetry`.
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
        copy_token_field!(cumulative_cache_read_tokens);
        copy_token_field!(cumulative_cache_creation_tokens);

        // Travels with the pair it qualifies. Sent whenever it changes,
        // including from unknown to `false`, because "this total is complete"
        // is a claim worth making explicitly rather than by omission.
        if session.tokens.cumulative_tokens_partial != Some(partial) {
            session.tokens.cumulative_tokens_partial = Some(partial);
            patch.cumulative_tokens_partial = Some(Some(partial));
            anything = true;
        }
        copy_token_field!(context_window_used_tokens);
        copy_token_field!(context_window_size_tokens);

        // --- what the session wrote -----------------------------------------
        //
        // Compared against the last published list, not sent every read: a
        // session working in one file produces a tool result every few seconds
        // and this is the largest field on the wire.
        {
            let (files, truncated) = wire_files(telemetry);
            if session.files.files != files {
                session.files.files = files.clone();
                patch.files = Some(Some(files));
                anything = true;
            }
            // Two reasons, not one, and this used to carry only the first.
            //
            // A partial *read* means we started watching midway. A `Bash` that
            // writes means we were watching the whole time and still cannot see
            // what it did — the tool result carries no path, so those edits
            // exist nowhere in this list.
            //
            // The comment here named both reasons long before the code did, and
            // the gap had a visible cost: a session that changed a hundred files
            // through the shell showed "nothing written yet", which is the one
            // claim this panel is built to never make.
            let files_partial = partial || telemetry.wrote_untracked;
            if session.files.partial != Some(files_partial) {
                session.files.partial = Some(files_partial);
                patch.files_partial = Some(Some(files_partial));
                anything = true;
            }
            if session.files.truncated != Some(truncated) {
                session.files.truncated = Some(truncated);
                patch.files_truncated = Some(Some(truncated));
                anything = true;
            }
        }

        // --- background agents ----------------------------------------------
        //
        // Derived, never counted. `pending_agents()` is a set difference over
        // the transcript as read so far, so this is a fresh reading on every
        // publish and there is no counter here to drift: a completion the file
        // never recorded costs one stale reading, not a wrong number until the
        // session ends.
        //
        // Sent whenever it changes, including the first `0`, because zero is the
        // positive claim "waiting on none" and the app needs it to tell a free
        // session from one this daemon has never looked at. The state stays
        // `idle` on the wire — that is the contract, and the presentation
        // decision belongs to the client.
        //
        // Two guards, and both are about what a `0` *asserts*:
        //
        // - **`ending`** — the `SessionEnd` path. The session is gone, so it is
        //   waiting on nothing, whatever the file's last lines say about
        //   launches that never reported. This is the second of the three ways a
        //   wait ends in `docs/PROTOCOL.md`, and without it a card keeps an
        //   orphan launch for as long as it stays on screen.
        // - **`partial`** — we met this session already running, so the launches
        //   that happened before we started looking are not in our sets. `0`
        //   there is the positive claim "waiting on none" with nothing behind
        //   it, so the field is cleared to unknown instead. A *positive* count
        //   under a partial read is still a launch we read with our own eyes and
        //   is published.
        {
            let pending = pending_on_wire(telemetry.pending_agents(now), partial, ending);
            if session.pending_agents != pending {
                session.pending_agents = pending;
                patch.pending_agents = Some(pending);
                anything = true;
            }
        }

        // --- the name -------------------------------------------------------
        //
        // Claude Code's own title for the session, which outranks anything
        // derived from the first prompt and is taken as soon as it appears.
        // `offer_title` enforces the ordering, so a human rename still wins.
        if let Some(title) = &telemetry.ai_title {
            if session.offer_title(title, TitleSource::AiTitle, now) {
                patch.title = Some(session.title.clone());
                patch.title_source = Some(
                    session.title_source.as_wire().map(str::to_string),
                );
                anything = true;
            }
        }

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

    // ---- the file list on the wire --------------------------------------

    fn telemetry_with(count: usize) -> Telemetry {
        let mut t = Telemetry::new();
        for i in 0..count {
            t.apply(&violeet_transcript::TranscriptEvent::ToolResult {
                tool_use_id: format!("t{i}"),
                at: None,
                file: Some(violeet_transcript::FileChange {
                    // Zero-padded so lexical order is numeric order, and the
                    // assertion below says what it means.
                    path: format!("/repo/f{i:04}.rs"),
                    added: 1,
                    removed: 0,
                    created: false,
                }),
            });
        }
        t
    }

    #[test]
    fn a_short_list_travels_whole_and_says_it_was_not_cut() {
        let (files, truncated) = wire_files(&telemetry_with(3));
        assert_eq!(files.len(), 3);
        assert!(!truncated);
        // Ordered by path: the tree renders in a stable order, and an
        // unordered set would make every publish look like a change.
        assert_eq!(files[0].path, "/repo/f0000.rs");
        assert_eq!(files[2].path, "/repo/f0002.rs");
    }

    /// The failure this prevents is silent: a line over the client's limit is
    /// dropped, not truncated, so the panel would simply stop updating.
    #[test]
    fn an_oversized_list_is_cut_and_says_so() {
        let (files, truncated) = wire_files(&telemetry_with(MAX_FILES_ON_WIRE + 40));
        assert_eq!(files.len(), MAX_FILES_ON_WIRE);
        assert!(truncated, "a cut list that does not say so is a lie");
    }

    #[test]
    fn a_session_that_wrote_nothing_has_an_empty_list_and_not_a_cut_one() {
        let (files, truncated) = wire_files(&Telemetry::new());
        assert!(files.is_empty());
        assert!(!truncated);
    }

    // ---- what a count is allowed to claim -------------------------------

    /// A partial read may not assert "waiting on none".
    ///
    /// The block that publishes this field used to ignore `partial` while the
    /// three fields beside it all honoured it, and the zero it sent was a
    /// positive claim about launches it had never had the chance to see.
    #[test]
    fn a_partial_read_publishes_unknown_rather_than_a_zero_it_cannot_support() {
        assert_eq!(pending_on_wire(0, true, false), None, "no basis for a zero");
        assert_eq!(
            pending_on_wire(2, true, false),
            Some(2),
            "a launch we read is a launch we read, partial or not"
        );
        assert_eq!(
            pending_on_wire(0, false, false),
            Some(0),
            "a complete read of a session with no agents is a positive zero"
        );
    }

    /// `SessionEnd` closes whatever is left. The second of the three ways a wait
    /// ends, and the one that keeps a departing card from lying for good.
    #[test]
    fn a_session_that_ends_publishes_zero_whatever_was_open() {
        assert_eq!(pending_on_wire(3, false, true), Some(0));
        assert_eq!(
            pending_on_wire(3, true, true),
            Some(0),
            "even a partial read: the session is gone either way"
        );
    }
}
