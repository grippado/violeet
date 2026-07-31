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

/// The events aiterm installs hooks for.
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
    /// `Notification` and `Stop` both mean the agent stopped and is waiting on
    /// the human. They map to `Idle` rather than to a state of their own: the
    /// six-state model has no "waiting for input", and inventing a wire state
    /// nothing else can produce is what the protocol revision just removed.
    pub fn implied_state(self) -> Option<SessionState> {
        match self {
            Self::SessionStart => None,
            Self::UserPromptSubmit
            | Self::PreToolUse
            | Self::PostToolUse
            | Self::SubagentStop
            | Self::PreCompact => Some(SessionState::Working),
            Self::Notification | Self::Stop => Some(SessionState::Idle),
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
    /// part of the agent's payload at all, it is aiterm's own annotation, added
    /// by the installed hook command from `AITERM_TAB_ID`. See ADR-003.
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
