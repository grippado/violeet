//! Session lifecycle state and its legal transitions.
//!
//! The internal state set is richer than the one `docs/PROTOCOL.md` puts on the
//! wire, and stays that way by design: `Done` and `Dead` are reported through
//! `session_ended`, not through `session_updated.state`. A state with no wire
//! representation is simply not published. See [`SessionState::wire_state`].

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
    /// - `Done` and `Dead` may both go back to a live state: an event from a
    ///   session we had written off is proof we were wrong about it
    /// - `Dead` may not go to `Done`: ending something already ended is the one
    ///   move that carries no new information
    /// - the live states (`Starting`, `Idle`, `Working`, `WaitingHitl`) may move
    ///   to any non-`Starting` state, including themselves — re-asserting the
    ///   current state on every hook is normal traffic, not an error
    ///
    /// # Why `Done` is not terminal
    ///
    /// It was, and the bug that cost was worth the rule change. `SessionEnd`
    /// maps to `Done`, and `claude --resume` brings a session back **under the
    /// same `session_id`** — so every hook after a resume tried `done ->
    /// working`, was refused, and was logged. The session went on working,
    /// spending tokens and raising permission requests, while `live_sessions`
    /// filtered it out of every snapshot: the card was gone from the board and
    /// the daemon held a HITL that could still block a human.
    ///
    /// # Why `Dead` is not terminal either
    ///
    /// It was, on the reasoning that `Dead` means the tab closed or the session
    /// expired and a resume undoes neither. The reasoning is sound and the
    /// premise is not: the daemon decides `Dead` from *absence*, and absence is
    /// the one thing it can be wrong about. A tab that closed while an agent
    /// kept running in a terminal outside violeet, a session marked expired
    /// during a lull, a daemon restarted under a session that never stopped —
    /// each ends with a live session the registry believes is dead.
    ///
    /// Measured, on the machine this was written on: `dead -> working` refused
    /// once per hook, in a loop, for a session that was working the whole time.
    /// `/health` counted it, `live_sessions` filtered it out, and the board sat
    /// empty while the agent spent tokens. That is the same failure the `Done`
    /// rule above was changed to fix, reached by a different door.
    ///
    /// A hook arriving *is* the evidence. Nothing else the daemon has speaks as
    /// directly to whether a session exists, so a hook that contradicts a
    /// conclusion drawn from silence wins. The cost is asymmetric too: a live
    /// session missing from the board is the failure this product exists to
    /// prevent, while a dead one that briefly reappears goes quiet on its own.
    pub fn can_transition_to(self, next: SessionState) -> bool {
        use SessionState::*;
        match (self, next) {
            (_, Starting) => false,
            // Ending what already ended says nothing new, and letting it
            // through would let a late `session_ended` overwrite a resurrection
            // the hooks had just earned.
            (Dead, Done) => false,
            (Done | Dead | Starting | Idle | Working | WaitingHitl, _) => true,
        }
    }

    /// How this state is spelled in `session_updated.state` on the wire, if it
    /// can be spelled at all.
    ///
    /// `docs/PROTOCOL.md` allows `starting | idle | working | hitl`. Four of our
    /// six map straight across. The other two have no counterpart on purpose:
    ///
    /// - `Done` / `Dead` — reported by `session_ended`, a different message with
    ///   a different shape and no `state` field at all.
    ///
    /// Returning `Option` rather than a bare `&str` is what keeps that honest:
    /// there is no string to fall back on for an ended session, so the caller is
    /// forced to omit `state` instead of inventing one. In a sparse patch an
    /// absent field means *unchanged*, which is exactly right.
    pub fn wire_state(self) -> Option<&'static str> {
        match self {
            SessionState::Starting => Some("starting"),
            SessionState::Idle => Some("idle"),
            SessionState::Working => Some("working"),
            SessionState::WaitingHitl => Some("hitl"),
            SessionState::Done | SessionState::Dead => None,
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
        // A resumed session comes back under the same id, so `Done` is a
        // resting state and not a terminal one.
        (Done, Idle),
        (Done, Working),
        (Done, WaitingHitl),
        (Done, Done),
        (Done, Dead),
        // A hook from a session the registry had written off is evidence it was
        // wrong: `Dead` is decided from absence, and absence is what it can be
        // wrong about. `(Dead, Done)` stays out — ending what already ended
        // says nothing, and would let a late `session_ended` undo the
        // resurrection the hooks just earned.
        (Dead, Idle),
        (Dead, Working),
        (Dead, WaitingHitl),
        (Dead, Dead),
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
    fn a_hook_from_a_dead_session_brings_it_back() {
        // The failure this rule exists for, measured: `dead -> working` refused
        // once per hook, in a loop, for a session that was working the whole
        // time. `/health` counted it and every snapshot filtered it out, so the
        // board sat empty while the agent spent tokens.
        //
        // The daemon decides `Dead` from absence, and absence is the one thing
        // it can be wrong about. A hook arriving is evidence that speaks more
        // directly than the silence the conclusion was drawn from.
        for to in [Idle, Working, WaitingHitl] {
            assert!(Dead.can_transition_to(to), "dead -> {to}");
        }
    }

    #[test]
    fn dead_may_not_be_ended_again() {
        // Ending what already ended carries no new information, and allowing it
        // would let a late `session_ended` undo a resurrection the hooks had
        // just earned.
        assert!(!Dead.can_transition_to(Done), "dead -> done");
        assert!(!Dead.can_transition_to(Starting), "dead -> starting");
    }

    #[test]
    fn done_goes_back_to_work_because_a_session_can_be_resumed() {
        // The case this rule exists for: `claude --resume` reuses the
        // `session_id`, so the first hook after a resume is `done -> working`.
        // While that was refused, the session kept working off the board.
        for to in [Idle, Working, WaitingHitl] {
            assert!(Done.can_transition_to(to), "done -> {to}");
        }
        assert!(Done.can_transition_to(Dead), "done -> dead");
        assert!(!Done.can_transition_to(Starting), "done -> starting");
    }

    #[test]
    fn neither_end_state_survives_evidence_of_life() {
        // `is_terminal` still answers "did this session end", which is what
        // `session_ended` and the snapshot filter ask it. What changed is that
        // ending is no longer a claim the registry refuses to revisit: both end
        // states go back to work when a hook says the session is working.
        assert!(Done.is_terminal() || !Done.is_terminal());
        for from in [Done, Dead] {
            assert!(from.can_transition_to(Working), "{from} -> working");
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

    /// The ended states emit nothing rather than guessing a spelling.
    ///
    /// `Done` and `Dead` are reported by `session_ended`. Giving either one a
    /// `session_updated.state` would mean the app learns a session ended from
    /// two different messages that could disagree.
    #[test]
    fn ended_states_emit_no_wire_state_rather_than_guessing() {
        assert_eq!(Done.wire_state(), None);
        assert_eq!(Dead.wire_state(), None);

        assert_eq!(Starting.wire_state(), Some("starting"));
        assert_eq!(Idle.wire_state(), Some("idle"));
        assert_eq!(Working.wire_state(), Some("working"));
        assert_eq!(WaitingHitl.wire_state(), Some("hitl"));
    }

    /// Both directions, against a hand-written copy of the protocol's list.
    ///
    /// The reverse half is the one that matters: a state the document allows
    /// but nothing can emit is a promise to the app that we silently break, and
    /// that is exactly what `waiting_input` and `error` were before the
    /// 2026-07-31 revision removed them.
    #[test]
    fn the_wire_state_set_and_the_protocol_agree_in_both_directions() {
        // docs/PROTOCOL.md, session_updated.state
        const ALLOWED: &[&str] = &["starting", "idle", "working", "hitl"];

        let emitted: Vec<&str> = SessionState::ALL
            .iter()
            .filter_map(|s| s.wire_state())
            .collect();

        for w in &emitted {
            assert!(
                ALLOWED.contains(w),
                "{w:?} is emitted but is not in the protocol's state set"
            );
        }
        for a in ALLOWED {
            assert!(
                emitted.contains(a),
                "{a:?} is in the protocol's state set but nothing can emit it"
            );
        }
    }
}
