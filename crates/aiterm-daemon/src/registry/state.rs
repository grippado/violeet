//! Session lifecycle state and its legal transitions.
//!
//! The internal state set is richer than the one `docs/PROTOCOL.md` puts on the
//! wire. That is deliberate and allowed: the protocol is frozen, the internal
//! model is not, and a state with no wire representation is simply not
//! published. See [`SessionState::wire_state`] and
//! `docs/tracks/A-protocol-request.md`.

use std::fmt;

/// Where a session is in its life.
///
/// `Starting` is the state a session is born in and can never return to.
/// `Dead` is terminal: nothing leaves it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SessionState {
    /// Known to exist, nothing observed yet.
    Starting,
    /// Alive, not currently doing anything.
    Idle,
    /// Alive and working.
    Working,
    /// Blocked on a permission request (HITL).
    WaitingHitl,
    /// Finished cleanly.
    Done,
    /// Gone: tab closed, or expired for inactivity.
    Dead,
}

impl SessionState {
    /// Every variant, for exhaustive testing.
    pub const ALL: [SessionState; 6] = [
        SessionState::Starting,
        SessionState::Idle,
        SessionState::Working,
        SessionState::WaitingHitl,
        SessionState::Done,
        SessionState::Dead,
    ];

    /// `Dead` is the only state nothing leaves.
    ///
    /// This is a question about *transitions*. For "has this session ended",
    /// which is what the UI and inactivity expiry care about, use
    /// [`is_finished`](Self::is_finished) — `Done` has ended but can still
    /// legally become `Dead`.
    pub fn is_terminal(self) -> bool {
        matches!(self, SessionState::Dead)
    }

    /// Whether the session has reached an end, cleanly (`Done`) or otherwise
    /// (`Dead`).
    ///
    /// Inactivity expiry keys off this rather than [`is_terminal`](Self::is_terminal):
    /// expiry *infers* death from silence, and there is nothing to infer about
    /// a session we already watched finish. A `Done` session is not quiet, it
    /// is over.
    pub fn is_finished(self) -> bool {
        matches!(self, SessionState::Done | SessionState::Dead)
    }

    /// Whether `self -> next` is a legal move.
    ///
    /// The rules, in full:
    ///
    /// - nothing may transition *into* `Starting`; it is only ever the birth state
    /// - nothing leaves `Dead`
    /// - `Done` may only become `Dead`
    /// - the live states (`Starting`, `Idle`, `Working`, `WaitingHitl`) may move
    ///   to any non-`Starting` state, including themselves — re-asserting the
    ///   current state on every hook is normal traffic, not an error
    pub fn can_transition_to(self, next: SessionState) -> bool {
        use SessionState::*;
        match (self, next) {
            (_, Starting) => false,
            (Dead, _) => false,
            (Done, Dead) => true,
            (Done, _) => false,
            (Starting | Idle | Working | WaitingHitl, _) => true,
        }
    }

    /// How this state is spelled in `session_updated.state` on the wire, if it
    /// can be spelled at all.
    ///
    /// `docs/PROTOCOL.md` allows `idle | working | waiting_input | hitl | error`.
    /// Three of our states have no counterpart:
    ///
    /// - `Starting` — the protocol has no "known but unobserved" state. We emit
    ///   **no** `state` field rather than guessing one. In a sparse patch an
    ///   absent field means *unchanged*, so this is honest rather than a lie.
    /// - `Done` / `Dead` — these are reported by `session_ended`, which carries
    ///   no `state` field at all.
    pub fn wire_state(self) -> Option<&'static str> {
        match self {
            SessionState::Idle => Some("idle"),
            SessionState::Working => Some("working"),
            SessionState::WaitingHitl => Some("hitl"),
            SessionState::Starting | SessionState::Done | SessionState::Dead => None,
        }
    }
}

impl fmt::Display for SessionState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            SessionState::Starting => "starting",
            SessionState::Idle => "idle",
            SessionState::Working => "working",
            SessionState::WaitingHitl => "waiting_hitl",
            SessionState::Done => "done",
            SessionState::Dead => "dead",
        };
        f.write_str(s)
    }
}

/// A refused transition. Carries both ends so the caller can log something useful.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidTransition {
    pub from: SessionState,
    pub to: SessionState,
}

impl fmt::Display for InvalidTransition {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "illegal session transition {} -> {}", self.from, self.to)
    }
}

impl std::error::Error for InvalidTransition {}

#[cfg(test)]
mod tests {
    use super::SessionState::*;
    use super::*;

    /// The full legal transition table, written out by hand rather than derived
    /// from the implementation — otherwise the test just restates the bug.
    const LEGAL: &[(SessionState, SessionState)] = &[
        (Starting, Idle),
        (Starting, Working),
        (Starting, WaitingHitl),
        (Starting, Done),
        (Starting, Dead),
        (Idle, Idle),
        (Idle, Working),
        (Idle, WaitingHitl),
        (Idle, Done),
        (Idle, Dead),
        (Working, Idle),
        (Working, Working),
        (Working, WaitingHitl),
        (Working, Done),
        (Working, Dead),
        (WaitingHitl, Idle),
        (WaitingHitl, Working),
        (WaitingHitl, WaitingHitl),
        (WaitingHitl, Done),
        (WaitingHitl, Dead),
        (Done, Dead),
    ];

    #[test]
    fn every_pair_is_classified_and_matches_the_hand_written_table() {
        for from in SessionState::ALL {
            for to in SessionState::ALL {
                let expected = LEGAL.contains(&(from, to));
                assert_eq!(
                    from.can_transition_to(to),
                    expected,
                    "{from} -> {to} should be {}",
                    if expected { "legal" } else { "illegal" }
                );
            }
        }
    }

    #[test]
    fn nothing_transitions_into_starting() {
        for from in SessionState::ALL {
            assert!(!from.can_transition_to(Starting), "{from} -> starting");
        }
    }

    #[test]
    fn dead_is_terminal() {
        assert!(Dead.is_terminal());
        for to in SessionState::ALL {
            assert!(!Dead.can_transition_to(to), "dead -> {to}");
        }
    }

    #[test]
    fn done_only_becomes_dead() {
        for to in SessionState::ALL {
            assert_eq!(Done.can_transition_to(to), to == Dead, "done -> {to}");
        }
    }

    #[test]
    fn live_states_may_reassert_themselves() {
        for s in [Idle, Working, WaitingHitl] {
            assert!(
                s.can_transition_to(s),
                "{s} -> {s} should be a no-op, not an error"
            );
        }
    }

    #[test]
    fn starting_cannot_reassert_itself() {
        assert!(!Starting.can_transition_to(Starting));
    }

    #[test]
    fn states_with_no_wire_spelling_emit_nothing_rather_than_guessing() {
        assert_eq!(Starting.wire_state(), None);
        assert_eq!(Done.wire_state(), None);
        assert_eq!(Dead.wire_state(), None);

        assert_eq!(Idle.wire_state(), Some("idle"));
        assert_eq!(Working.wire_state(), Some("working"));
        assert_eq!(WaitingHitl.wire_state(), Some("hitl"));
    }

    #[test]
    fn wire_spellings_are_all_allowed_by_the_frozen_protocol() {
        // docs/PROTOCOL.md, session_updated.state
        const ALLOWED: &[&str] = &["idle", "working", "waiting_input", "hitl", "error"];
        for s in SessionState::ALL {
            if let Some(w) = s.wire_state() {
                assert!(
                    ALLOWED.contains(&w),
                    "{w:?} is not in the protocol's state set"
                );
            }
        }
    }
}
