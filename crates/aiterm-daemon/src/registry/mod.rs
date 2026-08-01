//! In-memory session registry: the daemon's source of truth.
//!
//! Deliberately synchronous, deliberately I/O-free, and deliberately unaware
//! that a socket exists. Every method takes `now` rather than reading the clock,
//! so expiry and lifetime behaviour are testable without sleeping. The socket
//! layer owns the clock; this owns the facts.
//!
//! Tab binding (ADR-003) has to work in both arrival orders, because both
//! happen: the app usually sends `register_tab` before spawning the agent, but a
//! hook can win the race, and an agent started outside aiterm never sends one at
//! all.

pub mod session;
pub mod state;

use chrono::{DateTime, Duration, Utc};
use std::collections::HashMap;
use std::path::PathBuf;

pub use session::{Harness, Session, TabBinding, TitleSource, TokenTelemetry};
pub use state::{InvalidTransition, SessionState};

/// How long a session may go without any event before it is presumed dead.
pub const DEFAULT_IDLE_TTL_MINUTES: i64 = 30;

/// A tab the app has told us about.
#[derive(Debug, Clone)]
pub struct Tab {
    pub tab_id: String,
    pub cwd: Option<String>,
    pub registered_at: DateTime<Utc>,
}

/// What a hook told us. The HTTP layer builds these; the registry consumes
/// them. Everything except `session_id` is optional because hooks genuinely
/// differ in what they carry.
///
/// TODO(track-A): the HTTP hook endpoint that constructs these is the next task.
#[derive(Debug, Clone)]
pub struct HookObservation {
    pub session_id: String,
    /// From `AITERM_TAB_ID` in the hook payload's environment. `None` for an
    /// agent started outside aiterm.
    pub tab_id: Option<String>,
    pub harness: Harness,
    pub cwd: Option<String>,
    pub transcript_path: Option<PathBuf>,
    /// Where the hook came from, resolved by [`crate::origin`] from the
    /// connection it arrived on. Only the HTTP layer can produce this — the
    /// registry does no I/O — and it only bothers for a session that has none.
    pub origin: Option<crate::origin::Origin>,
    /// The state this hook implies, when it implies one.
    pub state: Option<SessionState>,
}

impl HookObservation {
    /// The minimum a hook can tell us: that a session exists.
    pub fn new(session_id: impl Into<String>, harness: Harness) -> Self {
        Self {
            session_id: session_id.into(),
            tab_id: None,
            harness,
            cwd: None,
            transcript_path: None,
            origin: None,
            state: None,
        }
    }

    pub fn with_origin(mut self, origin: crate::origin::Origin) -> Self {
        self.origin = Some(origin);
        self
    }

    pub fn with_tab_id(mut self, tab_id: impl Into<String>) -> Self {
        self.tab_id = Some(tab_id.into());
        self
    }

    pub fn with_cwd(mut self, cwd: impl Into<String>) -> Self {
        self.cwd = Some(cwd.into());
        self
    }

    pub fn with_state(mut self, state: SessionState) -> Self {
        self.state = Some(state);
        self
    }
}

/// What changed as a result of feeding an observation in. The socket layer turns
/// this into wire messages; the registry itself publishes nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookOutcome {
    pub session_id: String,
    /// First time we have seen this session.
    pub created: bool,
    /// It acquired a tab binding on this observation.
    pub newly_bound: bool,
    /// Its lifecycle state moved.
    pub state_changed: bool,
    /// We learned where it is running, or learned something different.
    pub origin_changed: bool,
    /// The hook implied a state the session could not legally move to. The
    /// session is untouched; the caller should log it.
    pub rejected_transition: Option<InvalidTransition>,
}

/// The registry.
#[derive(Debug)]
pub struct Registry {
    sessions: HashMap<String, Session>,
    tabs: HashMap<String, Tab>,
    idle_ttl: Duration,
}

impl Registry {
    pub fn new(idle_ttl: Duration) -> Self {
        Self {
            sessions: HashMap::new(),
            tabs: HashMap::new(),
            idle_ttl,
        }
    }

    pub fn with_default_ttl() -> Self {
        Self::new(Duration::minutes(DEFAULT_IDLE_TTL_MINUTES))
    }

    pub fn idle_ttl(&self) -> Duration {
        self.idle_ttl
    }

    pub fn session(&self, session_id: &str) -> Option<&Session> {
        self.sessions.get(session_id)
    }

    pub fn session_mut(&mut self, session_id: &str) -> Option<&mut Session> {
        self.sessions.get_mut(session_id)
    }

    /// Every session, in no particular order. Includes terminal ones — deciding
    /// what to show is not the registry's job.
    pub fn sessions(&self) -> impl Iterator<Item = &Session> {
        self.sessions.values()
    }

    /// Sessions that have not ended. A finished session is not replayed into a
    /// freshly connected client's snapshot.
    pub fn live_sessions(&self) -> impl Iterator<Item = &Session> {
        self.sessions.values().filter(|s| !s.state().is_finished())
    }

    pub fn tab(&self, tab_id: &str) -> Option<&Tab> {
        self.tabs.get(tab_id)
    }

    /// The app opened a tab.
    ///
    /// Returns the sessions that were waiting for this tab id and just became
    /// bound — the *hook arrived first* order.
    pub fn register_tab(
        &mut self,
        tab_id: impl Into<String>,
        cwd: Option<String>,
        now: DateTime<Utc>,
    ) -> Vec<String> {
        let tab_id = tab_id.into();
        self.tabs.insert(
            tab_id.clone(),
            Tab {
                tab_id: tab_id.clone(),
                cwd,
                registered_at: now,
            },
        );

        let mut bound = Vec::new();
        for session in self.sessions.values_mut() {
            if session.state().is_finished() {
                continue;
            }
            if matches!(&session.binding, TabBinding::Pending(p) if *p == tab_id) {
                session.binding = TabBinding::Bound(tab_id.clone());
                session.touch(now);
                bound.push(session.session_id.clone());
            }
        }
        bound.sort();
        bound
    }

    /// The app closed a tab. Every session bound to it dies.
    ///
    /// Returns the sessions that actually moved to `Dead`.
    ///
    /// TODO(track-B): `docs/PROTOCOL.md` has no app→daemon message that carries
    /// this. See `docs/tracks/A-protocol-request.md`. The registry supports it;
    /// the wire does not yet.
    pub fn close_tab(&mut self, tab_id: &str, now: DateTime<Utc>) -> Vec<String> {
        self.tabs.remove(tab_id);

        let mut killed = Vec::new();
        for session in self.sessions.values_mut() {
            // A pending claim counts: that session was only ever going to bind
            // to this tab, and the tab is gone.
            if session.binding.claimed_tab_id() == Some(tab_id)
                && session.transition_to(SessionState::Dead, now).is_ok()
            {
                killed.push(session.session_id.clone());
            }
        }
        killed.sort();
        killed
    }

    /// Feed in what a hook told us.
    pub fn observe_hook(&mut self, obs: HookObservation, now: DateTime<Utc>) -> HookOutcome {
        let known_tab = obs
            .tab_id
            .as_deref()
            .is_some_and(|t| self.tabs.contains_key(t));

        let created = !self.sessions.contains_key(&obs.session_id);
        if created {
            // Binding decided at birth: bound if we already know the tab,
            // pending if a tab id was claimed but is unknown to us, unbound if
            // the hook carried none at all.
            let binding = match &obs.tab_id {
                Some(t) if known_tab => TabBinding::Bound(t.clone()),
                Some(t) => TabBinding::Pending(t.clone()),
                None => TabBinding::Unbound,
            };
            self.sessions.insert(
                obs.session_id.clone(),
                Session::new(obs.session_id.clone(), binding, obs.harness, now),
            );
        }

        let session = self
            .sessions
            .get_mut(&obs.session_id)
            .expect("just inserted or already present");

        let mut newly_bound = false;
        if created {
            newly_bound = session.binding.is_bound();
        } else if let Some(claimed) = obs.tab_id.as_deref() {
            // Late binding, the *register_tab arrived first* order: a session
            // that claimed a tab we now recognise.
            match &session.binding {
                TabBinding::Unbound => {
                    session.binding = if known_tab {
                        newly_bound = true;
                        TabBinding::Bound(claimed.to_string())
                    } else {
                        TabBinding::Pending(claimed.to_string())
                    };
                }
                TabBinding::Pending(p) if p == claimed && known_tab => {
                    session.binding = TabBinding::Bound(claimed.to_string());
                    newly_bound = true;
                }
                _ => {}
            }
        }

        // Never overwrite something we know with something we don't.
        if obs.cwd.is_some() {
            session.cwd = obs.cwd;
        }
        // Same rule for the origin, and per field: a resolution that found the
        // application but no controlling terminal must not erase a tty an
        // earlier hook did find.
        let mut origin_changed = false;
        if let Some(origin) = obs.origin {
            if origin.app.is_some() && origin.app != session.origin_app {
                session.origin_app = origin.app;
                origin_changed = true;
            }
            if origin.tty.is_some() && origin.tty != session.origin_tty {
                session.origin_tty = origin.tty;
                origin_changed = true;
            }
        }
        if obs.transcript_path.is_some() {
            session.transcript_path = obs.transcript_path;
        }
        if session.harness == Harness::Unknown && obs.harness != Harness::Unknown {
            session.harness = obs.harness;
        }

        let mut state_changed = false;
        let mut rejected_transition = None;
        match obs.state {
            Some(next) if next != session.state() => match session.transition_to(next, now) {
                Ok(()) => state_changed = true,
                Err(e) => rejected_transition = Some(e),
            },
            _ => session.touch(now),
        }

        HookOutcome {
            session_id: session.session_id.clone(),
            created,
            newly_bound,
            state_changed,
            origin_changed,
            rejected_transition,
        }
    }

    /// Explicit state change from somewhere other than a hook.
    pub fn set_state(
        &mut self,
        session_id: &str,
        next: SessionState,
        now: DateTime<Utc>,
    ) -> Option<Result<(), InvalidTransition>> {
        self.sessions
            .get_mut(session_id)
            .map(|s| s.transition_to(next, now))
    }

    /// `rename_session` from the app. Returns whether the session existed.
    pub fn rename_session(&mut self, session_id: &str, title: &str, now: DateTime<Utc>) -> bool {
        match self.sessions.get_mut(session_id) {
            Some(s) => {
                s.set_user_title(title, now);
                true
            }
            None => false,
        }
    }

    /// `release_session_title` from the app: back to automatic naming.
    /// Returns whether the session existed.
    pub fn release_session_title(&mut self, session_id: &str, now: DateTime<Utc>) -> bool {
        match self.sessions.get_mut(session_id) {
            Some(s) => {
                s.release_user_title(now);
                true
            }
            None => false,
        }
    }

    /// Kill everything that has gone quiet for longer than the TTL.
    ///
    /// Returns the sessions that just died, so the caller can publish
    /// `session_ended` for each.
    pub fn expire_idle(&mut self, now: DateTime<Utc>) -> Vec<String> {
        let ttl = self.idle_ttl;
        let mut expired: Vec<String> = self
            .sessions
            .values()
            .filter(|s| s.is_expired(now, ttl))
            .map(|s| s.session_id.clone())
            .collect();
        expired.sort();

        for id in &expired {
            if let Some(s) = self.sessions.get_mut(id) {
                // Deliberately ignoring the result: `is_expired` already
                // excluded terminal states, so this cannot legally fail — and
                // if it somehow did, the session simply stays as it was.
                let _ = s.transition_to(SessionState::Dead, now);
            }
        }
        expired
    }

    /// Drop finished sessions from memory. Not called on any hot path; exists
    /// so a long-lived daemon does not grow without bound.
    ///
    /// Reaps `Done` as well as `Dead`: both have ended, and memory does not
    /// care which way.
    pub fn reap_dead(&mut self) -> usize {
        let before = self.sessions.len();
        self.sessions.retain(|_, s| !s.state().is_finished());
        before - self.sessions.len()
    }
}

impl Default for Registry {
    fn default() -> Self {
        Self::with_default_ttl()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn t(secs: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000 + secs, 0).unwrap()
    }

    fn registry() -> Registry {
        Registry::new(Duration::seconds(60))
    }

    fn hook(session_id: &str) -> HookObservation {
        HookObservation::new(session_id, Harness::ClaudeCode)
    }

    // ---- binding, both arrival orders -----------------------------------

    #[test]
    fn binding_when_register_tab_arrives_first() {
        let mut r = registry();
        assert!(r.register_tab("tab-1", None, t(0)).is_empty());

        let out = r.observe_hook(hook("s1").with_tab_id("tab-1"), t(1));
        assert!(out.created);
        assert!(out.newly_bound);

        let s = r.session("s1").unwrap();
        assert_eq!(s.binding, TabBinding::Bound("tab-1".into()));
        assert_eq!(s.binding.bound_tab_id(), Some("tab-1"));
    }

    #[test]
    fn binding_when_the_hook_arrives_first() {
        let mut r = registry();

        let out = r.observe_hook(hook("s1").with_tab_id("tab-1"), t(0));
        assert!(out.created);
        assert!(!out.newly_bound, "nothing to bind to yet");
        assert_eq!(
            r.session("s1").unwrap().binding,
            TabBinding::Pending("tab-1".into())
        );
        assert_eq!(
            r.session("s1").unwrap().binding.bound_tab_id(),
            None,
            "a pending session must publish tab_id: null, not a hopeful guess"
        );

        let bound = r.register_tab("tab-1", None, t(1));
        assert_eq!(bound, vec!["s1".to_string()]);
        assert_eq!(
            r.session("s1").unwrap().binding,
            TabBinding::Bound("tab-1".into())
        );
    }

    #[test]
    fn unbound_session_is_matched_by_a_later_hook_once_the_tab_is_known() {
        let mut r = registry();

        // A hook with no tab id at all: an agent started outside aiterm.
        r.observe_hook(hook("s1"), t(0));
        assert_eq!(r.session("s1").unwrap().binding, TabBinding::Unbound);

        // The tab shows up, and a later hook from the same session claims it.
        r.register_tab("tab-9", None, t(1));
        let out = r.observe_hook(hook("s1").with_tab_id("tab-9"), t(2));
        assert!(!out.created);
        assert!(out.newly_bound);
        assert_eq!(
            r.session("s1").unwrap().binding,
            TabBinding::Bound("tab-9".into())
        );
    }

    #[test]
    fn a_session_that_never_claims_a_tab_stays_unbound_forever() {
        let mut r = registry();
        r.register_tab("tab-1", None, t(0));
        r.observe_hook(hook("s1"), t(1));
        r.observe_hook(hook("s1"), t(2));

        assert_eq!(r.session("s1").unwrap().binding, TabBinding::Unbound);
        assert_eq!(r.session("s1").unwrap().binding.bound_tab_id(), None);
    }

    #[test]
    fn registering_an_unrelated_tab_binds_nothing() {
        let mut r = registry();
        r.observe_hook(hook("s1").with_tab_id("tab-1"), t(0));
        assert!(r.register_tab("tab-other", None, t(1)).is_empty());
        assert_eq!(
            r.session("s1").unwrap().binding,
            TabBinding::Pending("tab-1".into())
        );
    }

    #[test]
    fn two_sessions_pending_on_one_tab_both_bind() {
        let mut r = registry();
        r.observe_hook(hook("s1").with_tab_id("tab-1"), t(0));
        r.observe_hook(hook("s2").with_tab_id("tab-1"), t(0));

        let bound = r.register_tab("tab-1", None, t(1));
        assert_eq!(bound, vec!["s1".to_string(), "s2".to_string()]);
    }

    #[test]
    fn a_dead_session_is_not_resurrected_by_late_binding() {
        let mut r = registry();
        r.observe_hook(hook("s1").with_tab_id("tab-1"), t(0));
        r.set_state("s1", SessionState::Dead, t(1))
            .unwrap()
            .unwrap();

        assert!(r.register_tab("tab-1", None, t(2)).is_empty());
        assert_eq!(r.session("s1").unwrap().state(), SessionState::Dead);
    }

    // ---- lifecycle -------------------------------------------------------

    #[test]
    fn sessions_are_born_starting_and_know_nothing() {
        let mut r = registry();
        r.observe_hook(hook("s1"), t(0));
        let s = r.session("s1").unwrap();
        assert_eq!(s.state(), SessionState::Starting);
        assert_eq!(s.created_at, t(0));
        assert_eq!(s.last_event_at, t(0));
        assert!(s.tokens.is_fully_unknown());
    }

    #[test]
    fn a_hook_implying_a_legal_state_moves_the_session() {
        let mut r = registry();
        r.observe_hook(hook("s1"), t(0));

        let out = r.observe_hook(hook("s1").with_state(SessionState::Working), t(1));
        assert!(out.state_changed);
        assert_eq!(out.rejected_transition, None);
        assert_eq!(r.session("s1").unwrap().state(), SessionState::Working);
    }

    #[test]
    fn a_hook_implying_an_illegal_state_is_reported_and_changes_nothing() {
        let mut r = registry();
        r.observe_hook(hook("s1"), t(0));
        r.set_state("s1", SessionState::Dead, t(1))
            .unwrap()
            .unwrap();

        let out = r.observe_hook(hook("s1").with_state(SessionState::Working), t(2));
        assert!(!out.state_changed);
        let rejected = out.rejected_transition.expect("should report the refusal");
        assert_eq!(rejected.from, SessionState::Dead);
        assert_eq!(rejected.to, SessionState::Working);
        assert_eq!(r.session("s1").unwrap().state(), SessionState::Dead);
    }

    #[test]
    fn re_asserting_the_current_state_is_not_a_change_and_not_an_error() {
        let mut r = registry();
        r.observe_hook(hook("s1").with_state(SessionState::Working), t(0));
        let out = r.observe_hook(hook("s1").with_state(SessionState::Working), t(1));
        assert!(!out.state_changed);
        assert_eq!(out.rejected_transition, None);
        assert_eq!(
            r.session("s1").unwrap().last_event_at,
            t(1),
            "still counts as activity"
        );
    }

    #[test]
    fn closing_a_tab_kills_its_sessions_including_merely_pending_ones() {
        let mut r = registry();
        r.register_tab("tab-1", None, t(0));
        r.observe_hook(hook("bound").with_tab_id("tab-1"), t(0));
        r.observe_hook(hook("pending").with_tab_id("tab-2"), t(0));
        r.observe_hook(hook("elsewhere"), t(0));

        assert_eq!(r.close_tab("tab-1", t(1)), vec!["bound".to_string()]);
        assert_eq!(r.close_tab("tab-2", t(1)), vec!["pending".to_string()]);

        assert_eq!(r.session("bound").unwrap().state(), SessionState::Dead);
        assert_eq!(r.session("pending").unwrap().state(), SessionState::Dead);
        assert_eq!(
            r.session("elsewhere").unwrap().state(),
            SessionState::Starting
        );
    }

    #[test]
    fn closing_an_unknown_tab_is_harmless() {
        let mut r = registry();
        r.observe_hook(hook("s1"), t(0));
        assert!(r.close_tab("nope", t(1)).is_empty());
        assert_eq!(r.session("s1").unwrap().state(), SessionState::Starting);
    }

    // ---- expiry ----------------------------------------------------------

    #[test]
    fn a_quiet_session_expires_after_the_ttl() {
        let mut r = registry();
        r.observe_hook(hook("s1").with_state(SessionState::Idle), t(0));

        assert!(
            r.expire_idle(t(60)).is_empty(),
            "exactly at the ttl is still alive"
        );
        assert_eq!(r.expire_idle(t(61)), vec!["s1".to_string()]);
        assert_eq!(r.session("s1").unwrap().state(), SessionState::Dead);
    }

    #[test]
    fn activity_keeps_a_session_alive() {
        let mut r = registry();
        r.observe_hook(hook("s1").with_state(SessionState::Idle), t(0));
        r.observe_hook(hook("s1"), t(59));

        assert!(
            r.expire_idle(t(100)).is_empty(),
            "last_event_at moved to t(59)"
        );
        assert!(!r.expire_idle(t(120)).is_empty());
    }

    #[test]
    fn expiry_is_idempotent_and_does_not_re_report_the_dead() {
        let mut r = registry();
        r.observe_hook(hook("s1"), t(0));
        assert_eq!(r.expire_idle(t(61)), vec!["s1".to_string()]);
        assert!(
            r.expire_idle(t(999)).is_empty(),
            "already dead, not expiring again"
        );
    }

    #[test]
    fn a_finished_session_is_not_expired_it_is_just_finished() {
        let mut r = registry();
        r.observe_hook(hook("s1").with_state(SessionState::Done), t(0));
        assert!(r.expire_idle(t(9_999)).is_empty());
        assert_eq!(r.session("s1").unwrap().state(), SessionState::Done);
    }

    #[test]
    fn expiry_only_touches_what_actually_went_quiet() {
        let mut r = registry();
        r.observe_hook(hook("quiet"), t(0));
        r.observe_hook(hook("chatty"), t(0));
        r.observe_hook(hook("chatty"), t(80));

        assert_eq!(r.expire_idle(t(100)), vec!["quiet".to_string()]);
        assert_eq!(r.session("chatty").unwrap().state(), SessionState::Starting);
    }

    // ---- no fabrication --------------------------------------------------

    #[test]
    fn nothing_in_the_registry_turns_an_unknown_into_a_zero() {
        let mut r = registry();
        r.register_tab("tab-1", None, t(0));
        r.observe_hook(hook("s1").with_tab_id("tab-1").with_cwd("/tmp"), t(1));
        r.observe_hook(hook("s1").with_state(SessionState::Working), t(2));
        r.rename_session("s1", "titled", t(3));
        r.expire_idle(t(500));

        let s = r.session("s1").unwrap();
        assert!(
            s.tokens.is_fully_unknown(),
            "no code path may invent a token reading"
        );
        assert_eq!(s.git_branch, None, "nothing here inspects git");
        assert_eq!(s.transcript_path, None, "no hook supplied one");
    }

    #[test]
    fn an_observation_without_cwd_does_not_erase_a_cwd_we_already_had() {
        let mut r = registry();
        r.observe_hook(hook("s1").with_cwd("/repo"), t(0));
        r.observe_hook(hook("s1"), t(1));
        assert_eq!(r.session("s1").unwrap().cwd.as_deref(), Some("/repo"));
    }

    #[test]
    fn an_unknown_harness_is_upgraded_but_a_known_one_is_never_downgraded() {
        let mut r = registry();
        r.observe_hook(HookObservation::new("s1", Harness::Unknown), t(0));
        assert_eq!(r.session("s1").unwrap().harness, Harness::Unknown);

        r.observe_hook(HookObservation::new("s1", Harness::ClaudeCode), t(1));
        assert_eq!(r.session("s1").unwrap().harness, Harness::ClaudeCode);

        r.observe_hook(HookObservation::new("s1", Harness::Unknown), t(2));
        assert_eq!(
            r.session("s1").unwrap().harness,
            Harness::ClaudeCode,
            "a later ignorant hook must not erase what we knew"
        );
    }

    // ---- misc ------------------------------------------------------------

    #[test]
    fn rename_marks_the_title_as_the_users_and_reports_unknown_sessions() {
        let mut r = registry();
        r.observe_hook(hook("s1"), t(0));

        assert!(r.rename_session("s1", "my session", t(1)));
        assert_eq!(
            r.session("s1").unwrap().title.as_deref(),
            Some("my session")
        );
        assert_eq!(r.session("s1").unwrap().title_source, TitleSource::User);

        assert!(!r.rename_session("ghost", "nope", t(2)));
    }

    #[test]
    fn live_sessions_excludes_the_dead() {
        let mut r = registry();
        r.observe_hook(hook("alive"), t(0));
        r.observe_hook(hook("goner"), t(0));
        r.set_state("goner", SessionState::Dead, t(1))
            .unwrap()
            .unwrap();

        let live: Vec<_> = r.live_sessions().map(|s| s.session_id.clone()).collect();
        assert_eq!(live, vec!["alive".to_string()]);
        assert_eq!(r.sessions().count(), 2, "the dead are still on the books");
    }

    #[test]
    fn reaping_removes_only_terminal_sessions() {
        let mut r = registry();
        r.observe_hook(hook("alive"), t(0));
        r.observe_hook(hook("goner"), t(0));
        r.set_state("goner", SessionState::Dead, t(1))
            .unwrap()
            .unwrap();

        assert_eq!(r.reap_dead(), 1);
        assert!(r.session("goner").is_none());
        assert!(r.session("alive").is_some());
    }

    #[test]
    fn many_sessions_across_many_tabs_stay_independent() {
        let mut r = registry();
        for i in 0..10 {
            r.register_tab(format!("tab-{i}"), None, t(0));
            r.observe_hook(hook(&format!("s{i}")).with_tab_id(format!("tab-{i}")), t(0));
        }
        assert_eq!(r.sessions().count(), 10);

        r.close_tab("tab-3", t(1));
        assert_eq!(r.session("s3").unwrap().state(), SessionState::Dead);
        assert_eq!(r.live_sessions().count(), 9);
    }
}
