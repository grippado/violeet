//! What Claude Code's hooks send us, and what we send back.
//!
//! Two translations live here and nowhere else:
//!
//! 1. **Inbound** — the hook payload into a [`HookObservation`] the registry can
//!    consume. Everything is optional except `session_id`, because hooks
//!    genuinely differ in what they carry and a missing field is information,
//!    not an error.
//! 2. **Outbound** — a `resolve_hitl` decision into the hook's response JSON.
//!    `docs/PROTOCOL.md` is snake_case throughout and the agent's hook format is
//!    camelCase; the boundary is here so no client has to know that.
//!
//! # Trusting this payload
//!
//! Not at all, beyond its shape. It arrives over loopback from a process we did
//! not authenticate, so every field is optional, unknown fields are ignored, and
//! nothing here can panic on bad input. An unknown `hook_event_name` maps to
//! [`HookEvent::Unrecognized`] and is answered normally rather than rejected: a
//! newer Claude Code that adds an event must not start failing hook calls
//! against an older daemon.

use serde::{Deserialize, Serialize};

use crate::registry::{Harness, HookObservation, SessionState};
use crate::wire::Decision;

/// The events violeet installs hooks for.
///
/// Spelled exactly as Claude Code spells `hook_event_name`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookEvent {
    SessionStart,
    UserPromptSubmit,
    PreToolUse,
    PostToolUse,
    Notification,
    Stop,
    SubagentStop,
    PreCompact,
    SessionEnd,
    PermissionRequest,
    /// The agent's working directory changed — a `cd`, typically.
    ///
    /// Added in wave 2. `violeet install-hooks` had been installing this hook
    /// since track C and the daemon was dropping it into `Unrecognized`, so the
    /// cwd on a card went stale at the session's first `cd` and stayed stale.
    /// It carries no matcher and fires on every change.
    CwdChanged,
    /// The agent finished writing a file, and told us which one and what it
    /// swapped.
    ///
    /// **Not a Claude Code spelling.** Every other variant here is named after
    /// an event Claude Code emits; this one is named after what it means,
    /// because it exists for the harnesses whose transcripts cannot answer the
    /// question. Claude Code records each edit's `structuredPatch` in the
    /// transcript, so `crate::transcript` measures its diffstat there and this
    /// event never fires for it. Cursor's transcript has **no `tool_result`
    /// lines at all** — measured across six real transcripts on 2026-08-09: 477
    /// `tool_use` blocks, zero results — so the file a `Write` touched is
    /// visible but everything about the outcome is not. Its `afterFileEdit`
    /// hook is the only channel that carries it.
    FileEdited,
    /// Something this daemon does not know. Recorded as activity, nothing more.
    Unrecognized,
}

impl HookEvent {
    pub fn parse(name: &str) -> Self {
        match name {
            "SessionStart" => Self::SessionStart,
            "UserPromptSubmit" => Self::UserPromptSubmit,
            "PreToolUse" => Self::PreToolUse,
            "PostToolUse" => Self::PostToolUse,
            "Notification" => Self::Notification,
            "Stop" => Self::Stop,
            "SubagentStop" => Self::SubagentStop,
            "PreCompact" => Self::PreCompact,
            "SessionEnd" => Self::SessionEnd,
            "PermissionRequest" => Self::PermissionRequest,
            "CwdChanged" => Self::CwdChanged,
            "FileEdited" => Self::FileEdited,
            _ => Self::Unrecognized,
        }
    }

    /// The lifecycle state this event implies, when it implies one.
    ///
    /// `None` means "this is activity, but it says nothing about what the
    /// session is doing" — the registry then bumps liveness without moving
    /// state. That is why `SessionStart` is `None`: a session that has just
    /// started is `Starting`, which is its birth state, and nothing may
    /// transition *into* `Starting`.
    ///
    /// `Notification` and `Stop` mean the agent stopped computing. They map to
    /// `Idle` rather than to a state of their own: the six-state model has no
    /// "waiting for input", and inventing a wire state nothing else can produce
    /// is what the protocol revision just removed.
    ///
    /// **`Stop` does not mean "a human now has the keyboard", and this comment
    /// used to say it did.** The same hook fires whether a person or a
    /// background agent is expected next: measured over 866 stop points on the
    /// reference corpus, 192 were followed by a `<task-notification>` rather
    /// than by a human. `SubagentStop` → `Working` below covers only the *end*
    /// of such a wait, never the window of it, and a backgrounded agent's launch
    /// is acknowledged immediately so nothing is in flight either. That gap is
    /// what `pending_agents` closes, from the transcript rather than from here:
    /// the wire state stays `idle` and the count says whether anyone needs to
    /// look. See `docs/PROTOCOL.md` § `pending_agents`.
    pub fn implied_state(self) -> Option<SessionState> {
        match self {
            Self::SessionStart => None,
            Self::UserPromptSubmit
            | Self::PreToolUse
            | Self::PostToolUse
            | Self::SubagentStop
            | Self::PreCompact
            // A file was written, so something wrote it. Same reading as
            // `PostToolUse`, which is the event this one stands in for on a
            // harness whose transcript cannot report a tool's outcome.
            | Self::FileEdited => Some(SessionState::Working),
            Self::Notification | Self::Stop => Some(SessionState::Idle),
            // A directory change says where the session is, not what it is
            // doing. Mapping it to `Working` would make a `cd` in an idle
            // terminal look like the agent woke up.
            Self::CwdChanged => None,
            Self::PermissionRequest => Some(SessionState::WaitingHitl),
            Self::SessionEnd => Some(SessionState::Done),
            Self::Unrecognized => None,
        }
    }
}

/// A hook payload, as far as we care about it.
///
/// Every field is `Option` on purpose. Claude Code sends different keys per
/// event, and a hook that carried no `cwd` leaves us with no `cwd` — which the
/// registry records as unknown rather than inventing.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct HookPayload {
    pub session_id: Option<String>,
    pub transcript_path: Option<String>,
    pub cwd: Option<String>,
    pub hook_event_name: Option<String>,
    pub tool_name: Option<String>,
    pub tool_input: Option<serde_json::Value>,
    /// Undocumented shape in v2.1.220; forwarded verbatim and never parsed.
    pub permission_suggestions: Option<serde_json::Value>,
    /// What the user typed. Present on `UserPromptSubmit` and nowhere else.
    ///
    /// This is the only channel that carries the prompt at the moment it is
    /// submitted — the transcript has it too, but not for another few hundred
    /// milliseconds, and the whole point of naming from the prompt is that the
    /// card is named before the first reply lands.
    pub prompt: Option<String>,
    /// The file a [`HookEvent::FileEdited`] is about. Absolute.
    pub file_path: Option<String>,
    /// What that edit swapped, one entry per replacement.
    pub edits: Option<Vec<HookEdit>>,
    /// Context occupancy, in tokens, at the moment a compaction was about to
    /// run. Only [`HookEvent::PreCompact`] carries it, and only from harnesses
    /// whose compaction hook reports it — Claude Code's does not, which is why
    /// this arrives on the hook channel rather than beside the status line's
    /// window size.
    pub context_tokens: Option<u64>,
    /// The window that `context_tokens` is a fraction of.
    pub context_window_size: Option<u64>,
}

/// One search-and-replace inside a [`HookEvent::FileEdited`].
///
/// Cursor's `afterFileEdit` sends the two strings and nothing else — no line
/// numbers, no ranges, no unified diff. That is enough to *measure* a diffstat
/// and not enough to locate it, which is exactly what the Files panel needs.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct HookEdit {
    pub old_string: Option<String>,
    pub new_string: Option<String>,
}

/// Lines added and removed by a list of edits.
///
/// **Measured, not estimated** — the same standard the transcript path is held
/// to. A replacement removes the lines it matched and adds the lines it wrote,
/// so counting both sides is the diffstat, not a guess at one.
///
/// The one thing it deliberately does not report is whether the file was
/// *created*. An `afterFileEdit` with an empty `old_string` is a write at the
/// start of a file, which is what creating a file looks like and also what
/// prepending to an existing one looks like. The panel renders `created` as a
/// badge, and a badge is a claim; the hook does not carry the fact, so nothing
/// here invents it.
pub fn diffstat(edits: &[HookEdit]) -> (u64, u64) {
    let mut added = 0;
    let mut removed = 0;
    for edit in edits {
        removed += line_count(edit.old_string.as_deref());
        added += line_count(edit.new_string.as_deref());
    }
    (added, removed)
}

/// Lines in a replacement side. Absent or empty is zero — an edit that only
/// inserts removed nothing, and saying it removed one empty line would put a
/// number on the card that never happened.
fn line_count(text: Option<&str>) -> u64 {
    match text {
        None | Some("") => 0,
        Some(text) => text.lines().count() as u64,
    }
}

impl HookPayload {
    pub fn event(&self) -> HookEvent {
        self.hook_event_name
            .as_deref()
            .map(HookEvent::parse)
            .unwrap_or(HookEvent::Unrecognized)
    }

    /// Turn the payload into something the registry understands.
    ///
    /// `tab_id` comes from the request header rather than the body: it is not
    /// part of the agent's payload at all, it is violeet's own annotation, added
    /// by the installed hook command from `VIOLEET_TAB_ID`. See ADR-003.
    pub fn observation(
        &self,
        session_id: &str,
        tab_id: Option<String>,
        harness: Harness,
    ) -> HookObservation {
        let mut obs = HookObservation::new(session_id, harness);
        obs.tab_id = tab_id;
        obs.cwd = self.cwd.clone().filter(|c| !c.is_empty());
        obs.transcript_path = self
            .transcript_path
            .as_deref()
            .filter(|p| !p.is_empty())
            .map(Into::into);
        obs.state = self.event().implied_state();
        obs
    }
}

/// The response body that answers a `PermissionRequest` hook.
///
/// # This shape is measured, not documented
///
/// It is copied from the hook scripts the ADR-004 spike actually ran on Claude
/// Code v2.1.220 — the ones whose `allow` and `deny` were honoured, verified
/// against the session transcript rather than against the screen. Preserved in
/// [`docs/spikes/`](../../../../docs/spikes/), `hook-allow-0.sh` and
/// `hook-deny.sh`:
///
/// ```json
/// {"hookSpecificOutput":{"hookEventName":"PermissionRequest",
///  "decision":{"behavior":"allow"}}}
/// ```
///
/// **The documented shape is different and does not work here.** The docs
/// describe `permissionDecision` / `permissionDecisionReason` as siblings of
/// `hookEventName`; what the agent honoured was a nested `decision` object
/// carrying `behavior` and `reason`. That is now three things the docs get wrong
/// about this one hook — a `tool_use_id` that does not exist, a
/// `permission_suggestions` shape that does not match, and this. The spike is
/// the authority; the documentation is not.
///
/// # What is still unmeasured
///
/// Only `behavior` and `reason` were exercised. `updatedInput` and
/// `updatedPermissions` are spelled camelCase to match their siblings, but no
/// spike sent them, so they are the remaining guess. They are optional and
/// omitted unless a client asks for them, which keeps the measured path — a
/// plain allow or deny — free of anything invented.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PermissionResponse {
    pub hook_specific_output: HookSpecificOutput,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HookSpecificOutput {
    pub hook_event_name: &'static str,
    pub decision: PermissionDecision,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PermissionDecision {
    /// `allow` or `deny`.
    pub behavior: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_input: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub updated_permissions: Option<serde_json::Value>,
}

impl PermissionResponse {
    /// Translate the app's decision into the agent's format.
    ///
    /// The behaviour string is passed through rather than validated against a
    /// list. `docs/PROTOCOL.md` says `allow | deny`, and a client sending
    /// anything else has already broken the contract; forwarding it lets the
    /// agent reject it, which is a far more debuggable failure than the daemon
    /// silently substituting a decision the user never made.
    pub fn from_decision(decision: &Decision) -> Self {
        Self {
            hook_specific_output: HookSpecificOutput {
                hook_event_name: "PermissionRequest",
                decision: PermissionDecision {
                    behavior: decision.behavior.clone(),
                    reason: decision.reason.clone(),
                    updated_input: decision.updated_input.clone(),
                    updated_permissions: decision.updated_permissions.clone(),
                },
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn events_map_to_the_states_they_actually_imply() {
        assert_eq!(HookEvent::parse("PreToolUse"), HookEvent::PreToolUse);
        assert_eq!(
            HookEvent::PreToolUse.implied_state(),
            Some(SessionState::Working)
        );
        assert_eq!(HookEvent::Stop.implied_state(), Some(SessionState::Idle));
        assert_eq!(
            HookEvent::Notification.implied_state(),
            Some(SessionState::Idle)
        );
        assert_eq!(
            HookEvent::PermissionRequest.implied_state(),
            Some(SessionState::WaitingHitl)
        );
        assert_eq!(
            HookEvent::SessionEnd.implied_state(),
            Some(SessionState::Done)
        );
    }

    /// Nothing may transition into `Starting`, so the event that starts a
    /// session must imply no state at all.
    #[test]
    fn session_start_implies_no_state_because_starting_is_a_birth_state() {
        assert_eq!(HookEvent::SessionStart.implied_state(), None);
    }

    // ---- the diffstat a hook can be held to ------------------------------

    fn edit(old: &str, new: &str) -> HookEdit {
        HookEdit {
            old_string: Some(old.to_string()),
            new_string: Some(new.to_string()),
        }
    }

    /// A replacement removes what it matched and adds what it wrote. Both sides
    /// are counted, because both sides happened.
    #[test]
    fn a_replacement_is_measured_on_both_sides() {
        let (added, removed) = diffstat(&[edit("one\ntwo\nthree", "uno\ndos")]);
        assert_eq!((added, removed), (2, 3));
    }

    /// `afterFileEdit` fires once per edit, so a file touched repeatedly must
    /// sum rather than report only its last change.
    #[test]
    fn several_edits_in_one_hook_sum() {
        let (added, removed) = diffstat(&[edit("a", "b\nc"), edit("d\ne", "f")]);
        assert_eq!((added, removed), (3, 3));
    }

    /// An insertion removed nothing. Counting the empty side as one line would
    /// put a removal on the card that never happened.
    #[test]
    fn an_insertion_removes_nothing_rather_than_one_empty_line() {
        assert_eq!(diffstat(&[edit("", "new line")]), (1, 0));
        assert_eq!(
            diffstat(&[HookEdit {
                old_string: None,
                new_string: Some("only this".into())
            }]),
            (1, 0)
        );
    }

    /// A deletion is the mirror image, and an empty hook is a no-op rather than
    /// a panic.
    #[test]
    fn a_deletion_adds_nothing_and_an_empty_list_is_zero() {
        assert_eq!(diffstat(&[edit("gone\naway", "")]), (0, 2));
        assert_eq!(diffstat(&[]), (0, 0));
    }

    /// A trailing newline ends the last line; it does not open another one.
    #[test]
    fn a_trailing_newline_does_not_invent_a_line() {
        assert_eq!(diffstat(&[edit("", "a\nb\n")]), (2, 0));
        assert_eq!(diffstat(&[edit("", "a\nb")]), (2, 0));
    }

    /// The event violeet spells itself, and the state it implies.
    #[test]
    fn a_file_edit_is_a_working_session() {
        assert_eq!(HookEvent::parse("FileEdited"), HookEvent::FileEdited);
        assert_eq!(
            HookEvent::FileEdited.implied_state(),
            Some(SessionState::Working)
        );
    }

    #[test]
    fn a_file_edit_payload_carries_its_path_and_edits() {
        let p: HookPayload = serde_json::from_str(
            r#"{"session_id":"s1","hook_event_name":"FileEdited",
                "file_path":"/repo/src/lib.rs",
                "edits":[{"old_string":"a","new_string":"b\nc"}]}"#,
        )
        .unwrap();

        assert_eq!(p.event(), HookEvent::FileEdited);
        assert_eq!(p.file_path.as_deref(), Some("/repo/src/lib.rs"));
        assert_eq!(diffstat(p.edits.as_deref().unwrap()), (2, 1));
    }

    /// The compaction hook is the only place a Cursor session's occupancy comes
    /// from. A payload without the numbers leaves them unknown.
    #[test]
    fn a_precompact_payload_carries_the_context_reading_when_it_has_one() {
        let with: HookPayload = serde_json::from_str(
            r#"{"session_id":"s1","hook_event_name":"PreCompact",
                "context_tokens":181000,"context_window_size":200000}"#,
        )
        .unwrap();
        assert_eq!(with.context_tokens, Some(181_000));
        assert_eq!(with.context_window_size, Some(200_000));

        let without: HookPayload =
            serde_json::from_str(r#"{"session_id":"s1","hook_event_name":"PreCompact"}"#).unwrap();
        assert_eq!(without.context_tokens, None, "unknown, never zero");
        assert_eq!(without.context_window_size, None);
    }

    /// A newer Claude Code must not break an older daemon.
    #[test]
    fn an_unknown_event_is_activity_rather_than_an_error() {
        let e = HookEvent::parse("SomethingAddedNextYear");
        assert_eq!(e, HookEvent::Unrecognized);
        assert_eq!(e.implied_state(), None);
    }

    #[test]
    fn a_payload_missing_everything_optional_still_parses() {
        let p: HookPayload = serde_json::from_str(r#"{"session_id":"s1"}"#).unwrap();
        assert_eq!(p.session_id.as_deref(), Some("s1"));
        assert_eq!(p.event(), HookEvent::Unrecognized);

        let obs = p.observation("s1", None, Harness::ClaudeCode);
        assert!(obs.cwd.is_none());
        assert!(obs.transcript_path.is_none());
        assert!(obs.tab_id.is_none());
    }

    #[test]
    fn unknown_payload_fields_are_ignored() {
        let p: HookPayload = serde_json::from_str(
            r#"{"session_id":"s1","hook_event_name":"Stop","invented_next_version":42}"#,
        )
        .unwrap();
        assert_eq!(p.event(), HookEvent::Stop);
    }

    /// An empty string is not a working directory.
    #[test]
    fn an_empty_cwd_is_unknown_rather_than_a_path() {
        let p: HookPayload =
            serde_json::from_str(r#"{"session_id":"s1","cwd":"","transcript_path":""}"#).unwrap();
        let obs = p.observation("s1", None, Harness::ClaudeCode);
        assert!(
            obs.cwd.is_none(),
            "`\"\"` must not become a cwd; it would render as an empty path \
             instead of as unknown"
        );
        assert!(obs.transcript_path.is_none());
    }

    /// A bare allow must serialize to **exactly** what the spike's
    /// `hook-allow-0.sh` emitted, byte for byte.
    ///
    /// That script's output is the only allow this project has ever seen Claude
    /// Code honour (v2.1.220, verified in the session transcript as
    /// `err=False`). This is not a formatting test — it is the regression guard
    /// on the one message whose failure mode is silent: a wrong shape here means
    /// the sidebar reports success while the user's agent sits on a dialog
    /// nobody is watching.
    #[test]
    fn a_bare_allow_matches_the_spike_script_byte_for_byte() {
        let decision = Decision {
            behavior: "allow".into(),
            reason: None,
            updated_input: None,
            updated_permissions: None,
        };

        // docs/spikes/hook-allow-0.sh, verbatim.
        const MEASURED: &str = r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#;

        assert_eq!(
            serde_json::to_string(&PermissionResponse::from_decision(&decision)).unwrap(),
            MEASURED
        );
    }

    /// And the deny, from `hook-deny.sh` — same nesting, plus the reason.
    #[test]
    fn a_denial_matches_the_spike_script_and_carries_its_reason() {
        let decision = Decision {
            behavior: "deny".into(),
            reason: Some("not on main".into()),
            updated_input: None,
            updated_permissions: None,
        };

        let j = serde_json::to_value(PermissionResponse::from_decision(&decision)).unwrap();
        let d = &j["hookSpecificOutput"]["decision"];
        assert_eq!(
            j["hookSpecificOutput"]["hookEventName"],
            "PermissionRequest"
        );
        assert_eq!(d["behavior"], "deny");
        assert_eq!(d["reason"], "not on main");
    }

    /// The documented shape is wrong for this hook, and staying wrong is the
    /// failure this test exists to catch. Anyone "fixing" the struct to match
    /// the docs breaks HITL silently, so the docs' key names are asserted
    /// **absent**.
    #[test]
    fn the_documented_but_wrong_key_names_never_appear() {
        let decision = Decision {
            behavior: "allow".into(),
            reason: Some("go ahead".into()),
            updated_input: None,
            updated_permissions: None,
        };
        let j = serde_json::to_value(PermissionResponse::from_decision(&decision)).unwrap();
        let out = &j["hookSpecificOutput"];

        assert!(
            out.get("permissionDecision").is_none()
                && out.get("permissionDecisionReason").is_none(),
            "the documented flat keys are not what v2.1.220 honoured; the spike's \
             nested `decision` object is. See docs/spikes/RESULTADO.md."
        );
        assert!(
            j.get("hook_specific_output").is_none(),
            "the snake_case of the socket protocol must not leak to the agent"
        );
    }

    #[test]
    fn the_optional_fields_are_omitted_rather_than_sent_as_null() {
        let decision = Decision {
            behavior: "allow".into(),
            reason: None,
            updated_input: Some(json!({ "command": "ls" })),
            updated_permissions: None,
        };
        let j = serde_json::to_value(PermissionResponse::from_decision(&decision)).unwrap();
        let d = &j["hookSpecificOutput"]["decision"];

        assert_eq!(d["updatedInput"]["command"], "ls");
        assert!(d.get("reason").is_none());
        assert!(d.get("updatedPermissions").is_none());
    }
}

// ---------------------------------------------------------------------------
// Status line payload
// ---------------------------------------------------------------------------

/// What Claude Code passes to the status line command on stdin.
///
/// A **different channel from the hooks**, and it carries two things the
/// transcript does not have at all:
///
///  - `context_window.context_window_size` — the real window for this model
///    *and this account*. Measured 2026-08-01: the same `claude-opus-5` runs at
///    1M for one account and 200k for another, so it cannot be looked up from
///    the model name, and a table that tried produced 24% where the truth was
///    5%.
///  - `rate_limits` — the subscriber's 5-hour and weekly usage. Nothing else
///    violeet can see reports these.
///
/// Only the fields we use are modelled; the payload has a dozen more. Parsed as
/// defensively as the hook payload and for the same reason — it is written by
/// another tool with no published schema, and a shape change must cost
/// telemetry rather than the daemon.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct StatusLinePayload {
    pub session_id: Option<String>,
    pub transcript_path: Option<String>,
    pub cwd: Option<String>,
    pub model: Option<StatusLineModel>,
    pub context_window: Option<StatusLineContextWindow>,
    pub rate_limits: Option<StatusLineRateLimits>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct StatusLineModel {
    pub id: Option<String>,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct StatusLineContextWindow {
    /// The authoritative window size. This is the whole reason the route exists.
    pub context_window_size: Option<u64>,
    pub total_input_tokens: Option<u64>,
    pub total_output_tokens: Option<u64>,
    pub used_percentage: Option<f64>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct StatusLineRateLimits {
    pub five_hour: Option<StatusLineWindow>,
    pub seven_day: Option<StatusLineWindow>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct StatusLineWindow {
    pub used_percentage: Option<f64>,
    /// Unix epoch seconds.
    pub resets_at: Option<i64>,
}
