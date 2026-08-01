//! A single agent session: what we know, and — just as important — what we
//! don't.
//!
//! # The hard rule
//!
//! **Unknown is `None`, never zero.** No constructor, no `Default`, no update
//! path may turn an absent reading into `0`. A zero is a measurement; `None` is
//! the absence of one, and the UI renders it as `—`. Conflating the two is a
//! bug class that has already bitten `aitop` and is not going to be repeated
//! here. The tests at the bottom of this file exist to enforce it.

use chrono::{DateTime, Utc};
use std::path::PathBuf;

use super::state::{InvalidTransition, SessionState};

/// Which agent this session is running.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Harness {
    ClaudeCode,
    Codex,
    Opencode,
    /// We saw a session but could not tell what is driving it. Rendered
    /// generically; never dropped.
    Unknown,
}

impl Harness {
    /// The `agent` field as spelled in `docs/PROTOCOL.md`.
    pub fn as_wire(self) -> &'static str {
        match self {
            Harness::ClaudeCode => "claude-code",
            Harness::Codex => "codex",
            Harness::Opencode => "opencode",
            Harness::Unknown => "unknown",
        }
    }
}

/// How this session relates to a terminal tab.
///
/// Three cases, deliberately distinguished — collapsing the middle one into the
/// last is what makes late binding impossible.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TabBinding {
    /// Matched to a tab the app told us about.
    Bound(String),
    /// A hook reported this `tab_id`, but no `register_tab` has arrived for it
    /// yet. Bindable later, the moment one does.
    Pending(String),
    /// The hook carried no `AITERM_TAB_ID` at all — an agent started outside
    /// aiterm. There is nothing to match on, so this never becomes bound.
    /// Per ADR-003 this is a supported state, not an error.
    Unbound,
}

impl TabBinding {
    /// The tab id to publish, which is `null` unless we are actually bound.
    /// A *pending* claim is not a binding and must never be reported as one.
    pub fn bound_tab_id(&self) -> Option<&str> {
        match self {
            TabBinding::Bound(id) => Some(id.as_str()),
            TabBinding::Pending(_) | TabBinding::Unbound => None,
        }
    }

    /// The tab id this session claims, bound or not. For matching only.
    pub fn claimed_tab_id(&self) -> Option<&str> {
        match self {
            TabBinding::Bound(id) | TabBinding::Pending(id) => Some(id.as_str()),
            TabBinding::Unbound => None,
        }
    }

    pub fn is_bound(&self) -> bool {
        matches!(self, TabBinding::Bound(_))
    }
}

/// Token readings.
///
/// Four numbers, and they are **four different quantities**. Adding the
/// cumulative pair to estimate window occupancy produces a wrong number that
/// looks plausible, which is the worst kind.
///
/// - [`cumulative_input_tokens`] / [`cumulative_output_tokens`] rise
///   monotonically over the session's life. They are what cost is computed
///   from.
/// - [`context_window_used_tokens`] is *current* occupancy. It **falls** on
///   every compaction.
/// - [`context_window_size_tokens`] is the window of the model in use.
///
/// The daemon does not compute a percentage. The app derives it from the last
/// two fields, per `docs/PROTOCOL.md`.
///
/// [`cumulative_input_tokens`]: TokenTelemetry::cumulative_input_tokens
/// [`cumulative_output_tokens`]: TokenTelemetry::cumulative_output_tokens
/// [`context_window_used_tokens`]: TokenTelemetry::context_window_used_tokens
/// [`context_window_size_tokens`]: TokenTelemetry::context_window_size_tokens
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenTelemetry {
    pub cumulative_input_tokens: Option<u64>,
    pub cumulative_output_tokens: Option<u64>,
    pub context_window_used_tokens: Option<u64>,
    pub context_window_size_tokens: Option<u64>,
    /// Whether the cumulative pair covers the whole session.
    ///
    /// `None` until we have read anything. `Some(true)` when reading began
    /// partway through a session already in progress — see the field of the
    /// same name in `docs/PROTOCOL.md`.
    pub cumulative_tokens_partial: Option<bool>,
}

impl TokenTelemetry {
    /// Everything unknown. Written out field by field rather than derived, so
    /// that adding a field forces a decision here instead of silently
    /// defaulting it.
    pub const fn unknown() -> Self {
        Self {
            cumulative_input_tokens: None,
            cumulative_output_tokens: None,
            context_window_used_tokens: None,
            context_window_size_tokens: None,
            cumulative_tokens_partial: None,
        }
    }

    /// True when we have not read a single number yet.
    pub fn is_fully_unknown(&self) -> bool {
        self.cumulative_input_tokens.is_none()
            && self.cumulative_output_tokens.is_none()
            && self.context_window_used_tokens.is_none()
            && self.context_window_size_tokens.is_none()
            && self.cumulative_tokens_partial.is_none()
    }
}

impl Default for TokenTelemetry {
    fn default() -> Self {
        Self::unknown()
    }
}

/// Where a session's title came from. A user-set title is never overwritten by
/// a derived one (`docs/PROTOCOL.md`, `rename_session`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TitleSource {
    /// Nothing has named it yet.
    None,
    /// Derived by the daemon. TODO(track-C): naming logic is a future task;
    /// today nothing writes this.
    Derived,
    /// Set by the human through `rename_session`. Sticky.
    User,
}

/// One agent session.
#[derive(Debug, Clone)]
pub struct Session {
    pub session_id: String,
    pub binding: TabBinding,
    pub harness: Harness,
    pub cwd: Option<String>,
    /// TODO(track-C): filled from the working tree once someone owns git
    /// inspection. The registry does no I/O, so it never populates this itself.
    pub git_branch: Option<String>,
    pub transcript_path: Option<PathBuf>,
    state: SessionState,
    pub title: Option<String>,
    pub title_source: TitleSource,
    /// The model the session is running on, read from its transcript. `None`
    /// until a turn has been observed — never a default model name.
    pub model: Option<String>,
    /// The last tool the agent invoked, with a short summary of its input.
    /// Also from the transcript.
    pub last_action: Option<String>,
    pub created_at: DateTime<Utc>,
    pub last_event_at: DateTime<Utc>,
    /// Filled by `aiterm-transcript` via `crate::transcript`. Every field stays
    /// `None` until a real reading arrives — never `0`.
    pub tokens: TokenTelemetry,
}

impl Session {
    /// A session we have just heard of. Born `Starting`, everything unmeasured.
    pub fn new(
        session_id: impl Into<String>,
        binding: TabBinding,
        harness: Harness,
        now: DateTime<Utc>,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            binding,
            harness,
            cwd: None,
            git_branch: None,
            transcript_path: None,
            state: SessionState::Starting,
            title: None,
            title_source: TitleSource::None,
            model: None,
            last_action: None,
            created_at: now,
            last_event_at: now,
            tokens: TokenTelemetry::unknown(),
        }
    }

    pub fn state(&self) -> SessionState {
        self.state
    }

    /// Move to `next`, or refuse and leave the session untouched.
    ///
    /// A refused transition does **not** bump `last_event_at`: nothing valid
    /// happened, and letting an illegal move keep a session alive would defeat
    /// inactivity expiry.
    pub fn transition_to(
        &mut self,
        next: SessionState,
        now: DateTime<Utc>,
    ) -> Result<(), InvalidTransition> {
        if !self.state.can_transition_to(next) {
            return Err(InvalidTransition {
                from: self.state,
                to: next,
            });
        }
        self.state = next;
        self.touch(now);
        Ok(())
    }

    /// Record that we heard from this session.
    pub fn touch(&mut self, now: DateTime<Utc>) {
        self.last_event_at = now;
    }

    /// Set a human-chosen title. Sticky: derived naming must not clobber it.
    pub fn set_user_title(&mut self, title: impl Into<String>, now: DateTime<Utc>) {
        self.title = Some(title.into());
        self.title_source = TitleSource::User;
        self.touch(now);
    }

    /// Set a machine-derived title, unless the human already named it.
    /// Returns whether it took.
    pub fn set_derived_title(&mut self, title: impl Into<String>, now: DateTime<Utc>) -> bool {
        if self.title_source == TitleSource::User {
            return false;
        }
        self.title = Some(title.into());
        self.title_source = TitleSource::Derived;
        self.touch(now);
        true
    }

    /// Whether this session has gone quiet for longer than `ttl`.
    ///
    /// A session that already ended is never "idle": it is finished. Expiry
    /// infers death from silence, and there is nothing to infer once we watched
    /// it stop.
    pub fn is_expired(&self, now: DateTime<Utc>, ttl: chrono::Duration) -> bool {
        if self.state.is_finished() {
            return false;
        }
        now.signed_duration_since(self.last_event_at) > ttl
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn t(secs: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000 + secs, 0).unwrap()
    }

    fn session() -> Session {
        Session::new("sess-1", TabBinding::Unbound, Harness::ClaudeCode, t(0))
    }

    #[test]
    fn a_new_session_knows_nothing_and_invents_nothing() {
        let s = session();
        assert_eq!(s.state(), SessionState::Starting);
        assert_eq!(s.cwd, None);
        assert_eq!(s.git_branch, None);
        assert_eq!(s.transcript_path, None);
        assert_eq!(s.title, None);
        assert_eq!(s.title_source, TitleSource::None);
        assert!(s.tokens.is_fully_unknown());
    }

    /// The rule this whole file exists for.
    #[test]
    fn no_unknown_token_field_is_ever_zero() {
        for tokens in [
            TokenTelemetry::unknown(),
            TokenTelemetry::default(),
            session().tokens,
        ] {
            assert_eq!(tokens.cumulative_input_tokens, None);
            assert_eq!(tokens.cumulative_output_tokens, None);
            assert_eq!(tokens.context_window_used_tokens, None);
            assert_eq!(tokens.context_window_size_tokens, None);

            // The failure we are guarding against: an unknown reading that
            // arrives at the UI as a real, plausible-looking zero.
            assert_ne!(tokens.cumulative_input_tokens, Some(0));
            assert_ne!(tokens.cumulative_output_tokens, Some(0));
            assert_ne!(tokens.context_window_used_tokens, Some(0));
            assert_ne!(tokens.context_window_size_tokens, Some(0));
        }
    }

    #[test]
    fn zero_is_a_real_reading_and_stays_distinct_from_unknown() {
        let mut s = session();
        s.tokens.cumulative_output_tokens = Some(0);
        assert_eq!(s.tokens.cumulative_output_tokens, Some(0));
        assert!(!s.tokens.is_fully_unknown());
        // ...while its neighbours are still genuinely unknown.
        assert_eq!(s.tokens.cumulative_input_tokens, None);
    }

    #[test]
    fn legal_transition_moves_state_and_bumps_last_event() {
        let mut s = session();
        s.transition_to(SessionState::Working, t(10)).unwrap();
        assert_eq!(s.state(), SessionState::Working);
        assert_eq!(s.last_event_at, t(10));
    }

    #[test]
    fn refused_transition_changes_nothing_at_all() {
        let mut s = session();
        s.transition_to(SessionState::Dead, t(10)).unwrap();

        let err = s.transition_to(SessionState::Working, t(99)).unwrap_err();
        assert_eq!(err.from, SessionState::Dead);
        assert_eq!(err.to, SessionState::Working);
        assert_eq!(s.state(), SessionState::Dead);
        // and crucially, it did not keep the session alive
        assert_eq!(s.last_event_at, t(10));
    }

    #[test]
    fn pending_binding_is_not_reported_as_bound() {
        let b = TabBinding::Pending("tab-1".into());
        assert_eq!(
            b.bound_tab_id(),
            None,
            "a pending claim must publish tab_id: null"
        );
        assert_eq!(b.claimed_tab_id(), Some("tab-1"));
        assert!(!b.is_bound());
    }

    #[test]
    fn user_title_is_sticky_against_derived_naming() {
        let mut s = session();
        assert!(s.set_derived_title("auto name", t(1)));
        s.set_user_title("mine", t(2));
        assert!(!s.set_derived_title("auto again", t(3)));
        assert_eq!(s.title.as_deref(), Some("mine"));
        assert_eq!(s.title_source, TitleSource::User);
    }

    #[test]
    fn expiry_is_strictly_greater_than_the_ttl() {
        let mut s = session();
        s.transition_to(SessionState::Idle, t(0)).unwrap();
        let ttl = chrono::Duration::seconds(60);

        assert!(
            !s.is_expired(t(60), ttl),
            "exactly at the ttl is not yet expired"
        );
        assert!(s.is_expired(t(61), ttl));
    }

    #[test]
    fn terminal_sessions_are_finished_not_idle() {
        let mut s = session();
        s.transition_to(SessionState::Dead, t(0)).unwrap();
        assert!(!s.is_expired(t(99_999), chrono::Duration::seconds(1)));
    }

    #[test]
    fn harness_wire_spellings_match_the_protocol() {
        assert_eq!(Harness::ClaudeCode.as_wire(), "claude-code");
        assert_eq!(Harness::Codex.as_wire(), "codex");
        assert_eq!(Harness::Opencode.as_wire(), "opencode");
        assert_eq!(Harness::Unknown.as_wire(), "unknown");
    }
}
