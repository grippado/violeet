//! Pending permission requests.
//!
//! When a `PermissionRequest` hook arrives, the daemon holds the HTTP response
//! open and parks the request here until one of three things resolves it: the
//! app answers, the human wins the race in the terminal, or our own deadline
//! fires. See ADR-004 for why it works this way and why every failure path
//! answers `500` rather than staying silent.
//!
//! Like [`crate::registry`], this module is synchronous, I/O-free, and takes
//! `now` as a parameter rather than reading the clock, so expiry is tested
//! without sleeping. The one concession is the `oneshot::Sender` it holds per
//! request: resolving has to wake a parked HTTP handler, and sending on a
//! oneshot is a non-blocking synchronous operation.
//!
//! # The invariant this module exists to enforce
//!
//! **Every request that is opened is resolved exactly once.** Not at most once
//! — exactly once. A permission request that is silently forgotten hangs the
//! user's agent forever with no error and no fallback, which the ADR-004 spike
//! measured at over eleven minutes before the human gave up. Every method that
//! removes an entry from the map returns it, so the caller cannot drop one on
//! the floor without ignoring a return value.

use std::collections::HashMap;

use chrono::{DateTime, Duration, Utc};
use tokio::sync::oneshot;

use crate::wire::{Decision, HitlOrigin};

/// How long the daemon holds a permission request before giving up.
///
/// ADR-004: the daemon owns this deadline because Claude Code does not impose
/// one. Five minutes is a guess about human patience and belongs in config
/// eventually.
pub const DEFAULT_HITL_TIMEOUT_SECONDS: i64 = 300;

/// A permission request the daemon is holding open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HitlRequest {
    /// Minted by the daemon. ADR-004: the hook payload carries no
    /// `tool_use_id`, so there is no agent-side identifier to borrow.
    pub hitl_id: String,
    pub session_id: String,
    pub tab_id: Option<String>,
    pub tool_name: String,
    /// Verbatim from the hook payload, opaque to us.
    pub tool_input: serde_json::Value,
    /// Verbatim passthrough. The documented shape is wrong in v2.1.220, so we
    /// normalize into neither shape.
    pub permission_suggestions: serde_json::Value,
    pub created_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

/// How a request ended.
///
/// `decision` is `Some` only when the app answered. The other three origins are
/// all `500` on the HTTP side and `decision: null` on the wire — when the human
/// answered in the terminal we genuinely do not know what they chose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolution {
    pub origin: HitlOrigin,
    pub decision: Option<Decision>,
}

impl Resolution {
    /// The app answered: the only path that produces a `200` and a decision.
    pub fn from_app(decision: Decision) -> Self {
        Self {
            origin: HitlOrigin::App,
            decision: Some(decision),
        }
    }

    /// Every other ending. The agent falls back to its own dialog, which ADR-004
    /// measured as still on screen and still live.
    ///
    /// # Panics
    ///
    /// If handed [`HitlOrigin::App`], which would claim the app answered while
    /// carrying no answer.
    pub fn fallback(origin: HitlOrigin) -> Self {
        assert!(
            origin != HitlOrigin::App,
            "an `app` resolution must carry the decision the app sent"
        );
        Self {
            origin,
            decision: None,
        }
    }

    /// Whether the agent gets a real answer, as opposed to a `500` and its own
    /// dialog back.
    pub fn is_answered(&self) -> bool {
        self.decision.is_some()
    }
}

/// What the HTTP layer knows when a `PermissionRequest` hook arrives.
#[derive(Debug, Clone)]
pub struct NewHitl {
    pub session_id: String,
    pub tab_id: Option<String>,
    pub tool_name: String,
    pub tool_input: serde_json::Value,
    pub permission_suggestions: serde_json::Value,
}

struct Entry {
    request: HitlRequest,
    responder: oneshot::Sender<Resolution>,
}

/// Every permission request currently being held open.
pub struct HitlRegistry {
    pending: HashMap<String, Entry>,
    next_seq: u64,
    timeout: Duration,
}

impl std::fmt::Debug for HitlRegistry {
    /// Hand-written because `oneshot::Sender` is not `Debug`.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HitlRegistry")
            .field("pending", &self.pending.len())
            .field("next_seq", &self.next_seq)
            .field("timeout", &self.timeout)
            .finish()
    }
}

impl HitlRegistry {
    pub fn new(timeout: Duration) -> Self {
        Self {
            pending: HashMap::new(),
            next_seq: 1,
            timeout,
        }
    }

    pub fn with_default_timeout() -> Self {
        Self::new(Duration::seconds(DEFAULT_HITL_TIMEOUT_SECONDS))
    }

    pub fn timeout(&self) -> Duration {
        self.timeout
    }

    pub fn len(&self) -> usize {
        self.pending.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pending.is_empty()
    }

    /// Every outstanding request, for snapshot replay.
    pub fn pending(&self) -> impl Iterator<Item = &HitlRequest> {
        self.pending.values().map(|e| &e.request)
    }

    pub fn get(&self, hitl_id: &str) -> Option<&HitlRequest> {
        self.pending.get(hitl_id).map(|e| &e.request)
    }

    /// Park a new request and hand back the channel the HTTP handler waits on.
    ///
    /// Ids are a plain counter rather than anything random or time-based. They
    /// only have to be unique among requests alive at the same moment in one
    /// process: nothing persists them, and a client that reconnects gets the
    /// live set replayed rather than reusing ids it remembers.
    pub fn open(
        &mut self,
        new: NewHitl,
        now: DateTime<Utc>,
    ) -> (HitlRequest, oneshot::Receiver<Resolution>) {
        let hitl_id = format!("hitl-{:06}", self.next_seq);
        self.next_seq += 1;

        let request = HitlRequest {
            hitl_id: hitl_id.clone(),
            session_id: new.session_id,
            tab_id: new.tab_id,
            tool_name: new.tool_name,
            tool_input: new.tool_input,
            permission_suggestions: new.permission_suggestions,
            created_at: now,
            expires_at: now + self.timeout,
        };

        let (responder, rx) = oneshot::channel();
        self.pending.insert(
            hitl_id,
            Entry {
                request: request.clone(),
                responder,
            },
        );
        (request, rx)
    }

    /// Resolve one request by id. First resolution wins; later ones find
    /// nothing.
    ///
    /// Returns `None` for an unknown or already-resolved id, which is the
    /// normal outcome of the race and not an error: the user clicked the card
    /// at the same moment the terminal answer landed.
    ///
    /// A failed send means the HTTP handler already gave up and dropped its
    /// receiver. The entry is still removed and still returned, because the
    /// card in the sidebar has to be cleared either way.
    pub fn resolve(&mut self, hitl_id: &str, resolution: Resolution) -> Option<HitlRequest> {
        let entry = self.pending.remove(hitl_id)?;
        let _ = entry.responder.send(resolution);
        Some(entry.request)
    }

    /// Resolve the request a `PostToolUse` hook implies the human already
    /// answered in the terminal.
    ///
    /// ADR-004 correlates on `session_id` + `tool_name` + structural equality of
    /// `tool_input`, because there is no `tool_use_id` to key on. **An ambiguous
    /// match resolves nothing** and lets the timeout handle it: clearing the
    /// wrong card is worse than clearing the right one late.
    pub fn resolve_tui_race(
        &mut self,
        session_id: &str,
        tool_name: &str,
        tool_input: &serde_json::Value,
    ) -> Option<HitlRequest> {
        let mut matches = self.pending.values().filter(|e| {
            e.request.session_id == session_id
                && e.request.tool_name == tool_name
                && &e.request.tool_input == tool_input
        });

        let hitl_id = matches.next()?.request.hitl_id.clone();
        if matches.next().is_some() {
            // Two identical calls in flight for one session. Which one the
            // human answered is unknowable, so we answer neither.
            return None;
        }

        self.resolve(&hitl_id, Resolution::fallback(HitlOrigin::Tui))
    }

    /// Resolve everything whose deadline has passed.
    pub fn expire(&mut self, now: DateTime<Utc>) -> Vec<HitlRequest> {
        let mut due: Vec<String> = self
            .pending
            .values()
            .filter(|e| e.request.expires_at <= now)
            .map(|e| e.request.hitl_id.clone())
            .collect();
        due.sort();

        due.into_iter()
            .filter_map(|id| self.resolve(&id, Resolution::fallback(HitlOrigin::Timeout)))
            .collect()
    }

    /// Resolve every request belonging to a session that is ending.
    ///
    /// `docs/PROTOCOL.md` requires `hitl_resolved` before `session_ended`, so
    /// the app never has to garbage-collect an orphaned card. The caller emits
    /// these in the order returned.
    pub fn resolve_all_for_session(
        &mut self,
        session_id: &str,
        origin: HitlOrigin,
    ) -> Vec<HitlRequest> {
        let mut owned: Vec<String> = self
            .pending
            .values()
            .filter(|e| e.request.session_id == session_id)
            .map(|e| e.request.hitl_id.clone())
            .collect();
        owned.sort();

        owned
            .into_iter()
            .filter_map(|id| self.resolve(&id, Resolution::fallback(origin)))
            .collect()
    }
}

impl Default for HitlRegistry {
    fn default() -> Self {
        Self::with_default_timeout()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;
    use serde_json::json;

    fn t(secs: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000 + secs, 0).unwrap()
    }

    fn bash(command: &str) -> NewHitl {
        NewHitl {
            session_id: "s1".into(),
            tab_id: Some("tab-1".into()),
            tool_name: "Bash".into(),
            tool_input: json!({ "command": command }),
            permission_suggestions: json!([]),
        }
    }

    fn app_allow() -> Decision {
        Decision {
            behavior: "allow".into(),
            reason: None,
            updated_input: None,
            updated_permissions: None,
        }
    }

    #[test]
    fn opening_parks_a_request_and_dates_its_deadline_from_now() {
        let mut r = HitlRegistry::new(Duration::seconds(300));
        let (req, _rx) = r.open(bash("ls"), t(0));

        assert_eq!(req.created_at, t(0));
        assert_eq!(req.expires_at, t(300));
        assert_eq!(r.len(), 1);
        assert_eq!(r.get(&req.hitl_id).unwrap().tool_name, "Bash");
    }

    #[test]
    fn ids_are_unique_among_requests_alive_at_once() {
        let mut r = HitlRegistry::with_default_timeout();
        let (a, _ra) = r.open(bash("one"), t(0));
        let (b, _rb) = r.open(bash("two"), t(0));
        assert_ne!(a.hitl_id, b.hitl_id);
    }

    #[tokio::test]
    async fn an_app_resolution_reaches_the_parked_handler_with_its_decision() {
        let mut r = HitlRegistry::with_default_timeout();
        let (req, rx) = r.open(bash("ls"), t(0));

        let got = r.resolve(&req.hitl_id, Resolution::from_app(app_allow()));
        assert_eq!(got.unwrap().hitl_id, req.hitl_id);

        let resolution = rx.await.expect("the handler must be woken");
        assert_eq!(resolution.origin, HitlOrigin::App);
        assert_eq!(resolution.decision.unwrap().behavior, "allow");
        assert!(r.is_empty());
    }

    /// The whole point of first-wins: a second answer finds nothing.
    #[test]
    fn only_the_first_resolution_lands() {
        let mut r = HitlRegistry::with_default_timeout();
        let (req, _rx) = r.open(bash("ls"), t(0));

        assert!(r
            .resolve(&req.hitl_id, Resolution::from_app(app_allow()))
            .is_some());
        assert!(
            r.resolve(&req.hitl_id, Resolution::fallback(HitlOrigin::Timeout))
                .is_none(),
            "a second resolution must find nothing, not resolve again"
        );
    }

    #[test]
    fn resolving_an_unknown_id_is_not_an_error() {
        let mut r = HitlRegistry::with_default_timeout();
        assert!(r
            .resolve("hitl-never-existed", Resolution::from_app(app_allow()))
            .is_none());
    }

    /// A handler that gave up still leaves a card to clear.
    #[test]
    fn a_dropped_receiver_does_not_stop_the_request_from_resolving() {
        let mut r = HitlRegistry::with_default_timeout();
        let (req, rx) = r.open(bash("ls"), t(0));
        drop(rx);

        let got = r.resolve(&req.hitl_id, Resolution::fallback(HitlOrigin::Timeout));
        assert!(
            got.is_some(),
            "the sidebar card must still be cleared even though nobody is \
             listening on the HTTP side"
        );
        assert!(r.is_empty());
    }

    // ---- the TUI race ----------------------------------------------------

    #[test]
    fn a_post_tool_use_matching_one_pending_call_resolves_it_as_tui() {
        let mut r = HitlRegistry::with_default_timeout();
        let (req, _rx) = r.open(bash("rm -rf build/"), t(0));

        let got = r
            .resolve_tui_race("s1", "Bash", &json!({ "command": "rm -rf build/" }))
            .expect("an unambiguous match must resolve");
        assert_eq!(got.hitl_id, req.hitl_id);
        assert!(r.is_empty());
    }

    /// Key order is not part of the identity of a tool input.
    #[test]
    fn tool_input_matching_is_structural_not_textual() {
        let mut r = HitlRegistry::with_default_timeout();
        let mut new = bash("ls");
        new.tool_input = json!({ "command": "ls", "description": "list" });
        let (req, _rx) = r.open(new, t(0));

        let got = r.resolve_tui_race(
            "s1",
            "Bash",
            &json!({ "description": "list", "command": "ls" }),
        );
        assert_eq!(got.unwrap().hitl_id, req.hitl_id);
    }

    /// ADR-004: when the match is ambiguous the daemon does not resolve.
    #[test]
    fn two_identical_calls_in_flight_resolve_neither() {
        let mut r = HitlRegistry::with_default_timeout();
        let (_a, _ra) = r.open(bash("ls"), t(0));
        let (_b, _rb) = r.open(bash("ls"), t(0));

        assert!(
            r.resolve_tui_race("s1", "Bash", &json!({ "command": "ls" }))
                .is_none(),
            "clearing the wrong card is worse than clearing it late"
        );
        assert_eq!(r.len(), 2, "neither request may be consumed by a guess");
    }

    #[test]
    fn a_post_tool_use_for_a_different_session_or_tool_matches_nothing() {
        let mut r = HitlRegistry::with_default_timeout();
        let (_req, _rx) = r.open(bash("ls"), t(0));

        assert!(r
            .resolve_tui_race("s2", "Bash", &json!({ "command": "ls" }))
            .is_none());
        assert!(r
            .resolve_tui_race("s1", "Write", &json!({ "command": "ls" }))
            .is_none());
        assert!(r
            .resolve_tui_race("s1", "Bash", &json!({ "command": "pwd" }))
            .is_none());
        assert_eq!(r.len(), 1);
    }

    // ---- expiry ----------------------------------------------------------

    #[test]
    fn expiry_fires_on_the_deadline_and_not_before() {
        let mut r = HitlRegistry::new(Duration::seconds(300));
        let (req, _rx) = r.open(bash("ls"), t(0));

        assert!(r.expire(t(299)).is_empty(), "not due yet");
        let expired = r.expire(t(300));
        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].hitl_id, req.hitl_id);
        assert!(r.is_empty());
    }

    #[tokio::test]
    async fn an_expired_request_tells_its_handler_to_answer_500() {
        let mut r = HitlRegistry::new(Duration::seconds(60));
        let (_req, rx) = r.open(bash("ls"), t(0));

        r.expire(t(60));

        let resolution = rx.await.expect("the handler must be woken, not left");
        assert_eq!(resolution.origin, HitlOrigin::Timeout);
        assert!(
            !resolution.is_answered(),
            "a timeout is a 500 and the agent's own dialog, never a decision"
        );
    }

    #[test]
    fn a_session_ending_resolves_its_requests_so_no_card_is_orphaned() {
        let mut r = HitlRegistry::with_default_timeout();
        let (_a, _ra) = r.open(bash("one"), t(0));
        let (_b, _rb) = r.open(bash("two"), t(0));
        let mut other = bash("three");
        other.session_id = "s2".into();
        let (_c, _rc) = r.open(other, t(0));

        let resolved = r.resolve_all_for_session("s1", HitlOrigin::DaemonError);
        assert_eq!(resolved.len(), 2);
        assert_eq!(r.len(), 1, "another session's request is untouched");
    }

    #[test]
    #[should_panic(expected = "must carry the decision")]
    fn an_app_origin_without_a_decision_is_a_bug_not_a_state() {
        let _ = Resolution::fallback(HitlOrigin::App);
    }
}
