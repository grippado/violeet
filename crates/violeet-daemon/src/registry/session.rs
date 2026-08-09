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
    /// The hook carried no `VIOLEET_TAB_ID` at all — an agent started outside
    /// violeet. There is nothing to match on, so this never becomes bound.
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
    /// Prompt tokens served from, and written into, the cache. Kept apart from
    /// the input counter because they are priced differently and because cache
    /// reads dominate the sum so heavily that merging would hide fresh input
    /// entirely. See `violeet_transcript::Telemetry`.
    pub cumulative_cache_read_tokens: Option<u64>,
    pub cumulative_cache_creation_tokens: Option<u64>,
    pub context_window_used_tokens: Option<u64>,
    pub context_window_size_tokens: Option<u64>,
    /// Whether the cumulative pair covers the whole session.
    ///
    /// `None` until we have read anything. `Some(true)` when reading began
    /// partway through a session already in progress — see the field of the
    /// same name in `docs/PROTOCOL.md`.
    pub cumulative_tokens_partial: Option<bool>,
}

/// What a session wrote, as last published.
///
/// Held so the daemon can tell a changed list from an unchanged one and keep
/// the patch sparse: a session working in one file emits a tool result every
/// few seconds, and re-sending the whole list each time would be the noisiest
/// field on the wire by a wide margin.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FileTelemetry {
    /// Ordered by path, as it goes on the wire.
    pub files: Vec<violeet_proto::wire::FileChange>,
    /// The list covers only part of the session. See the wire field.
    pub partial: Option<bool>,
    /// The list was cut to fit a line the client will accept.
    pub truncated: Option<bool>,
}

impl TokenTelemetry {
    /// Everything unknown. Written out field by field rather than derived, so
    /// that adding a field forces a decision here instead of silently
    /// defaulting it.
    pub const fn unknown() -> Self {
        Self {
            cumulative_input_tokens: None,
            cumulative_output_tokens: None,
            cumulative_cache_read_tokens: None,
            cumulative_cache_creation_tokens: None,
            context_window_used_tokens: None,
            context_window_size_tokens: None,
            cumulative_tokens_partial: None,
        }
    }

    /// True when we have not read a single number yet.
    pub fn is_fully_unknown(&self) -> bool {
        self.cumulative_input_tokens.is_none()
            && self.cumulative_output_tokens.is_none()
            && self.cumulative_cache_read_tokens.is_none()
            && self.cumulative_cache_creation_tokens.is_none()
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

/// The account's usage limits, as reported by Claude Code.
///
/// Not in the transcript and not derivable from it: these arrive in the status
/// line payload's `rate_limits`, which is a different channel entirely. Every
/// field stays `None` until one is seen, and `None` means unknown — a limit at
/// 0% and a limit we have not been told about are different facts.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct RateLimits {
    /// 0–100.
    pub five_hour_used_percent: Option<f64>,
    /// Unix epoch seconds when the 5-hour window resets.
    pub five_hour_resets_at: Option<i64>,
    pub seven_day_used_percent: Option<f64>,
    pub seven_day_resets_at: Option<i64>,
}

impl RateLimits {
    pub const fn unknown() -> Self {
        Self {
            five_hour_used_percent: None,
            five_hour_resets_at: None,
            seven_day_used_percent: None,
            seven_day_resets_at: None,
        }
    }
}

/// Where a session's title came from. A user-set title is never overwritten by
/// a derived one (`docs/PROTOCOL.md`, `rename_session`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TitleSource {
    /// Nothing has named it yet.
    None,
    /// The path's last component. The weakest name there is: it describes the
    /// folder, not the work, and two checkouts of one repository share it.
    Cwd,
    /// Derived from the session's first prompt. Available within a second of
    /// the session starting, which is why it is the name rather than a
    /// placeholder.
    Prompt,
    /// Claude Code's own `ai-title`. Measured landing one exchange in, and
    /// stable for the life of the session. Better than anything violeet can
    /// derive, so it upgrades over `Prompt`.
    AiTitle,
    /// Set by the human through `rename_session`. Sticky: nothing outranks it.
    User,
}

impl TitleSource {
    /// How much authority a source has. A title is only ever replaced by one
    /// that outranks it, which is what stops a name from flickering between
    /// two derivations — and what makes the manual rename final.
    pub fn rank(self) -> u8 {
        match self {
            Self::None => 0,
            Self::Cwd => 1,
            Self::Prompt => 2,
            Self::AiTitle => 3,
            Self::User => 4,
        }
    }

    /// The wire spelling.
    pub fn as_wire(self) -> Option<&'static str> {
        match self {
            Self::None => None,
            Self::Cwd => Some("cwd"),
            Self::Prompt => Some("prompt"),
            Self::AiTitle => Some("ai_title"),
            Self::User => Some("user"),
        }
    }
}

/// One agent session.
#[derive(Debug, Clone)]
pub struct Session {
    pub session_id: String,
    pub binding: TabBinding,
    pub harness: Harness,
    pub cwd: Option<String>,
    /// The terminal application the session is running in, from
    /// [`crate::origin`]. `None` until a hook has been resolved — and it stays
    /// `None` for a session the app started, which needs no origin because its
    /// tab is the answer.
    pub origin_app: Option<String>,
    /// Its controlling terminal, without `/dev/`.
    pub origin_tty: Option<String>,
    /// TODO(track-C): filled from the working tree once someone owns git
    /// inspection. The registry does no I/O, so it never populates this itself.
    pub git_branch: Option<String>,
    pub transcript_path: Option<PathBuf>,
    state: SessionState,
    /// The name in force: the human's if they set one, otherwise the best we
    /// derived. This is the only title that goes on the wire.
    pub title: Option<String>,
    pub title_source: TitleSource,
    /// The best name we derived on our own, kept **even while a manual name is
    /// in force**.
    ///
    /// Without this, `release_user_title` would have nowhere to go back to: the
    /// `ai-title` that arrived after the rename would have been discarded on
    /// arrival, and "back to automatic" would drop the card to its working
    /// directory even though a good derived name existed. Two tracks, one
    /// effective name — see `offer_title`.
    pub auto_title: Option<String>,
    pub auto_source: TitleSource,
    /// The model the session is running on, read from its transcript. `None`
    /// until a turn has been observed — never a default model name.
    pub model: Option<String>,
    /// The last tool the agent invoked, with a short summary of its input.
    /// Also from the transcript.
    pub last_action: Option<String>,
    /// Subscription limits, from the status line payload. `None` until one
    /// arrives — and it only arrives for Claude.ai subscribers, after the
    /// session's first API response, so `None` is the normal early state.
    pub limits: RateLimits,
    pub created_at: DateTime<Utc>,
    pub last_event_at: DateTime<Utc>,
    /// Filled by `violeet-transcript` via `crate::transcript`. Every field stays
    /// `None` until a real reading arrives — never `0`.
    pub tokens: TokenTelemetry,
    /// What this session wrote, as last published. Same source as `tokens`.
    pub files: FileTelemetry,
    /// How many background agents the session was waiting on, **as last
    /// published**.
    ///
    /// Held only to keep the patch sparse, exactly like `files`. It is never the
    /// source of the number: that is derived afresh from the transcript on every
    /// read (`violeet_transcript::Telemetry::pending_agents`), and nothing here
    /// ever increments it. `None` means the daemon has not told the app anything
    /// yet, which is not the same as having told it zero — see the wire field.
    pub pending_agents: Option<u64>,
    /// What the session is asking, **as last published**.
    ///
    /// Held to keep the patch sparse, like `files` and `pending_agents`, and
    /// never the source of anything: the question is decided afresh from the
    /// transcript on every read.
    ///
    /// Two `Option`s, and they are two different facts. The outer `None` means
    /// the daemon has told the app nothing, because no stop point has been read
    /// for this session — it does not know whether there is a question. The
    /// inner `None` is the positive claim "not asking", which is what closes a
    /// panel the app opened. Collapsing them would make "I never looked"
    /// indistinguishable from "I looked and it is quiet".
    pub answer_request: Option<Option<violeet_proto::wire::AnswerRequest>>,
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
            origin_app: None,
            origin_tty: None,
            git_branch: None,
            transcript_path: None,
            state: SessionState::Starting,
            title: None,
            title_source: TitleSource::None,
            auto_title: None,
            auto_source: TitleSource::None,
            model: None,
            last_action: None,
            limits: RateLimits::unknown(),
            created_at: now,
            last_event_at: now,
            tokens: TokenTelemetry::unknown(),
            files: FileTelemetry::default(),
            pending_agents: None,
            answer_request: None,
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
    ///
    /// Returns whether the effective name changed, so the caller knows whether
    /// there is anything to publish. Renaming a session to the name it already
    /// had, by a user who already owned the name, publishes nothing.
    pub fn set_user_title(&mut self, title: impl Into<String>, now: DateTime<Utc>) -> bool {
        let title = title.into();
        if title.trim().is_empty() {
            return false;
        }
        let changed =
            self.title.as_deref() != Some(title.as_str()) || self.title_source != TitleSource::User;
        self.title = Some(title);
        self.title_source = TitleSource::User;
        self.touch(now);
        changed
    }

    /// Give the session back to automatic naming.
    ///
    /// The counterpart to `set_user_title`, and not optional: a name that can
    /// be locked and never unlocked is a name the user is stuck with. The
    /// session drops straight back to the best title we derived while the
    /// manual one was in force — which is why `auto_title` is kept.
    ///
    /// Returns whether anything changed. A session with no manual name is
    /// already automatic and this does nothing.
    pub fn release_user_title(&mut self, now: DateTime<Utc>) -> bool {
        if self.title_source != TitleSource::User {
            return false;
        }
        self.title = self.auto_title.clone();
        self.title_source = match self.auto_title {
            Some(_) => self.auto_source,
            // No derived name yet. `None` rather than `Cwd`: the daemon never
            // set a cwd title, and claiming it did would tell the app a name
            // exists where there is none.
            None => TitleSource::None,
        };
        self.touch(now);
        true
    }

    /// Offer a title from `source`. Records it on the automatic track if it
    /// outranks what named the session there, and promotes it to the effective
    /// name unless a human has taken the name over.
    ///
    /// Returns whether the **effective** title changed, so the caller knows
    /// whether there is anything to publish.
    ///
    /// The rank check is what makes the sequence stable: the first prompt names
    /// the session immediately, Claude Code's own `ai-title` upgrades it once,
    /// and a human rename ends the conversation. Nothing downgrades, so a
    /// re-read of the transcript cannot walk a good name backwards.
    ///
    /// A `User` source arriving here is a restored manual name — `titles.json`
    /// replays whatever source it stored — and is routed to `set_user_title`
    /// rather than treated as one more rank, so there is exactly one place
    /// where a name becomes the human's.
    pub fn offer_title(
        &mut self,
        title: impl Into<String>,
        source: TitleSource,
        now: DateTime<Utc>,
    ) -> bool {
        let title = title.into();
        if source == TitleSource::User {
            return self.set_user_title(title, now);
        }
        if source.rank() < self.auto_source.rank() {
            return false;
        }
        if title.trim().is_empty() {
            return false;
        }

        let auto_changed = self.auto_title.as_deref() != Some(title.as_str());
        self.auto_title = Some(title);
        self.auto_source = source;
        self.touch(now);

        // The human owns the name. The derived one is still worth recording —
        // it is what unlocking goes back to — but it does not go on screen.
        if self.title_source == TitleSource::User {
            return false;
        }
        self.title = self.auto_title.clone();
        self.title_source = source;
        auto_changed
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

        // `dead -> done` rather than `dead -> working`: the latter is legal now,
        // because a hook is evidence the session is alive. Ending something
        // already ended is the move that still carries no information.
        let err = s.transition_to(SessionState::Done, t(99)).unwrap_err();
        assert_eq!(err.from, SessionState::Dead);
        assert_eq!(err.to, SessionState::Done);
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
        assert!(s.offer_title("auto name", TitleSource::Prompt, t(1)));
        s.set_user_title("mine", t(2));
        assert!(!s.offer_title("auto again", TitleSource::Prompt, t(3)));
        assert!(
            !s.offer_title("Claude's own title", TitleSource::AiTitle, t(4)),
            "not even the best generated name overwrites one the human chose"
        );
        assert_eq!(s.title.as_deref(), Some("mine"));
        assert_eq!(s.title_source, TitleSource::User);
    }

    /// The intended sequence: the first prompt names it in under a second, and
    /// Claude Code's own title upgrades it one exchange later.
    #[test]
    fn the_ai_title_upgrades_a_prompt_derived_name_but_not_the_reverse() {
        let mut s = session();
        assert!(s.offer_title("Arrumar o parser", TitleSource::Prompt, t(1)));
        assert!(s.offer_title(
            "Corrigir o parser de transcripts",
            TitleSource::AiTitle,
            t(2)
        ));
        assert_eq!(s.title.as_deref(), Some("Corrigir o parser de transcripts"));

        assert!(
            !s.offer_title("Arrumar o parser", TitleSource::Prompt, t(3)),
            "a re-read of the first prompt must not walk the name backwards"
        );
        assert_eq!(s.title.as_deref(), Some("Corrigir o parser de transcripts"));
    }

    /// The way out of a manual name, and what makes level 1 safe to enter: the
    /// user can always leave it.
    #[test]
    fn releasing_a_manual_name_goes_back_to_the_best_derived_one() {
        let mut s = session();
        s.offer_title("Arrumar o parser", TitleSource::Prompt, t(1));
        s.set_user_title("mine", t(2));
        // Arrives while the manual name is in force: invisible, and recorded.
        assert!(!s.offer_title("Corrigir o parser", TitleSource::AiTitle, t(3)));
        assert_eq!(s.title.as_deref(), Some("mine"));

        assert!(s.release_user_title(t(4)));
        assert_eq!(
            s.title.as_deref(),
            Some("Corrigir o parser"),
            "unlocking returns the name the session would have had, not the one \
             it had before the rename"
        );
        assert_eq!(s.title_source, TitleSource::AiTitle);
    }

    /// Unlocking a session nothing ever named leaves it with no name, which the
    /// app renders from its working directory. Not an empty string, and not the
    /// manual name it just gave up.
    #[test]
    fn releasing_with_nothing_derived_underneath_leaves_no_name_at_all() {
        let mut s = session();
        s.set_user_title("mine", t(1));
        assert!(s.release_user_title(t(2)));
        assert_eq!(s.title, None);
        assert_eq!(s.title_source, TitleSource::None);
    }

    #[test]
    fn releasing_a_session_that_was_never_renamed_changes_nothing() {
        let mut s = session();
        s.offer_title("auto", TitleSource::Prompt, t(1));
        assert!(!s.release_user_title(t(2)));
        assert_eq!(s.title.as_deref(), Some("auto"));
        assert_eq!(s.title_source, TitleSource::Prompt);
    }

    /// Renaming to the name it already has is not a change. Worth a test
    /// because the app sends a rename on every commit of the field, including
    /// the one where the user typed nothing and pressed Enter.
    #[test]
    fn renaming_to_the_same_name_reports_no_change() {
        let mut s = session();
        assert!(s.set_user_title("mine", t(1)));
        assert!(!s.set_user_title("mine", t(2)));
    }

    /// Re-offering the same title at the same rank is not a change, so nothing
    /// is published — a transcript re-read must not churn the sidebar.
    #[test]
    fn re_offering_the_same_title_reports_no_change() {
        let mut s = session();
        assert!(s.offer_title("mesmo nome", TitleSource::AiTitle, t(1)));
        assert!(!s.offer_title("mesmo nome", TitleSource::AiTitle, t(2)));
    }

    #[test]
    fn an_empty_title_is_never_accepted() {
        let mut s = session();
        assert!(!s.offer_title("   ", TitleSource::AiTitle, t(1)));
        assert_eq!(s.title, None);
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
