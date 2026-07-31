//! The JSON-lines message types of `docs/PROTOCOL.md`.
//!
//! Every client of the protocol depends on this one module rather than
//! reimplementing the shapes. That is the point of it living in `aiterm-proto`:
//! a second hand-written copy of a wire format is a second thing to keep in
//! sync, and the one that drifts is always the one nobody is testing.
//!
//! # Fidelity rules
//!
//! - The document is normative. Where this file and the document disagree, this
//!   file is the bug.
//! - `session_updated` is a **sparse patch**: absent means *unchanged*, explicit
//!   `null` means *became unknown*. That is a three-way distinction, so those
//!   fields are `Option<Option<T>>` with `skip_serializing_if` on the outside.
//!   Collapsing it to `Option<T>` would make "unchanged" and "unknown" the same
//!   message, which is exactly the fabrication the registry refuses to do.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub use crate::PROTOCOL_VERSION;

/// RFC 3339, which is what the protocol's `ts` field is.
pub fn timestamp(now: DateTime<Utc>) -> String {
    now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// A field in a sparse patch. Absent, explicitly unknown, or a value.
pub type Patch<T> = Option<Option<T>>;

// ---------------------------------------------------------------------------
// daemon -> app
// ---------------------------------------------------------------------------

/// Everything the daemon can say to a client.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DaemonToApp {
    SessionRegistered(SessionRegistered),
    SessionUpdated(SessionUpdated),
    HitlPending(HitlPending),
    HitlResolved(HitlResolved),
    SessionEnded(SessionEnded),
}

impl DaemonToApp {
    /// Serialize to exactly one JSON-lines line, terminator included.
    ///
    /// Returns `None` if serialization somehow fails, so that a single bad
    /// message can never take down the broadcast loop.
    pub fn to_line(&self) -> Option<String> {
        let mut s = serde_json::to_string(self).ok()?;
        debug_assert!(
            !s.contains('\n'),
            "a JSON-lines message must never embed a newline"
        );
        s.push('\n');
        Some(s)
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct SessionRegistered {
    pub v: u32,
    pub ts: String,
    pub session_id: String,
    /// `null` when the session is not bound to a tab. A *pending* claim is not a
    /// binding and is published as `null`.
    pub tab_id: Option<String>,
    pub agent: String,
    /// `null` when the session was first seen through a hook with no working
    /// directory. Deliberately not `""`: an empty string renders as an empty
    /// path, which is a lie, where `null` renders as unknown, which is the
    /// truth.
    pub cwd: Option<String>,
    pub title: Option<String>,
    pub model: Option<String>,
    pub started_at: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq, Default)]
pub struct SessionUpdated {
    pub v: u32,
    pub ts: String,
    pub session_id: String,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Patch<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Patch<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cwd: Patch<String>,

    // The four token quantities. Two pairs that measure different things: the
    // first is how full the window is *now* and falls on compaction, the second
    // is what the session has cost since it started and only ever climbs.
    // Summing across the pairs produces a wrong-but-plausible number, which is
    // why neither pair is named just "tokens".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window_used_tokens: Patch<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_window_size_tokens: Patch<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cumulative_input_tokens: Patch<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cumulative_output_tokens: Patch<u64>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub git_branch: Patch<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_action: Patch<String>,
    /// When the *session* last did something. Distinct from the envelope `ts`,
    /// which is when the daemon emitted this message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_event_at: Patch<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tab_id: Patch<String>,
}

impl SessionUpdated {
    /// An otherwise-empty patch for `session_id`.
    pub fn new(session_id: impl Into<String>, now: DateTime<Utc>) -> Self {
        Self {
            v: PROTOCOL_VERSION,
            ts: timestamp(now),
            session_id: session_id.into(),
            ..Default::default()
        }
    }

    /// True when nothing but the envelope is set — such a patch is not worth
    /// broadcasting.
    pub fn is_empty(&self) -> bool {
        self.state.is_none()
            && self.title.is_none()
            && self.model.is_none()
            && self.cwd.is_none()
            && self.context_window_used_tokens.is_none()
            && self.context_window_size_tokens.is_none()
            && self.cumulative_input_tokens.is_none()
            && self.cumulative_output_tokens.is_none()
            && self.git_branch.is_none()
            && self.last_action.is_none()
            && self.last_event_at.is_none()
            && self.tab_id.is_none()
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct HitlPending {
    pub v: u32,
    pub ts: String,
    pub hitl_id: String,
    pub session_id: String,
    pub tab_id: Option<String>,
    pub tool_name: String,
    /// Verbatim from the hook payload; opaque to us.
    pub tool_input: serde_json::Value,
    /// Verbatim passthrough. The documented shape is already wrong in
    /// v2.1.220, so we normalize into neither shape. See `docs/PROTOCOL.md`.
    pub permission_suggestions: serde_json::Value,
    pub expires_at: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct HitlResolved {
    pub v: u32,
    pub ts: String,
    pub hitl_id: String,
    pub session_id: String,
    pub origin: HitlOrigin,
    /// `allow` / `deny` only when `origin` is `app`. `null` otherwise: when the
    /// human answered in the TUI we genuinely do not know what they chose.
    pub decision: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HitlOrigin {
    App,
    Tui,
    Timeout,
    DaemonError,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct SessionEnded {
    pub v: u32,
    pub ts: String,
    pub session_id: String,
    pub tab_id: Option<String>,
    pub reason: EndReason,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EndReason {
    SessionEndHook,
    ProcessExited,
    TabClosed,
    DaemonShutdown,
}

// ---------------------------------------------------------------------------
// app -> daemon
// ---------------------------------------------------------------------------

/// Everything a client can say to the daemon.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AppToDaemon {
    RegisterTab {
        tab_id: String,
        #[serde(default)]
        cwd: Option<String>,
    },
    /// The tab is gone. Symmetric with `RegisterTab`, and the only way the
    /// daemon can learn a tab closed rather than inferring it from silence.
    CloseTab {
        tab_id: String,
    },
    ResolveHitl {
        hitl_id: String,
        decision: Decision,
    },
    RenameSession {
        session_id: String,
        title: String,
    },
    RequestSnapshot {},
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct Decision {
    pub behavior: String,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub updated_input: Option<serde_json::Value>,
    #[serde(default)]
    pub updated_permissions: Option<serde_json::Value>,
}

/// Why a received line produced nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rejected {
    /// Not JSON, or not an object.
    Malformed(String),
    /// Well-formed, but `v` is newer than we understand. Dropped and logged, per
    /// the protocol — unknown `v` is *not* ignorable the way unknown fields are.
    UnsupportedVersion(u64),
    /// A `type` we do not know. Ignored on purpose: that is what lets a later
    /// protocol version add messages without breaking us.
    UnknownType(String),
}

/// Parse one inbound line.
///
/// Deliberately total: every failure is a [`Rejected`], never a panic and never
/// an error the caller has to translate. A client sending garbage must not be
/// able to affect the daemon or any other client.
pub fn parse_inbound(line: &str) -> Result<AppToDaemon, Rejected> {
    let value: serde_json::Value =
        serde_json::from_str(line).map_err(|e| Rejected::Malformed(e.to_string()))?;

    let obj = value
        .as_object()
        .ok_or_else(|| Rejected::Malformed("top-level value is not an object".into()))?;

    // Version first: an unknown `v` is dropped even if the rest parses.
    match obj.get("v").and_then(serde_json::Value::as_u64) {
        Some(v) if v > PROTOCOL_VERSION as u64 => return Err(Rejected::UnsupportedVersion(v)),
        _ => {}
    }

    let ty = obj
        .get("type")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| Rejected::Malformed("missing `type`".into()))?
        .to_string();

    serde_json::from_value(value).map_err(|_| Rejected::UnknownType(ty))
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    fn json_of(msg: &DaemonToApp) -> serde_json::Value {
        serde_json::from_str(&serde_json::to_string(msg).unwrap()).unwrap()
    }

    #[test]
    fn every_outbound_message_is_one_line_with_a_trailing_newline() {
        let msg = DaemonToApp::SessionEnded(SessionEnded {
            v: PROTOCOL_VERSION,
            ts: timestamp(now()),
            session_id: "s1".into(),
            tab_id: None,
            reason: EndReason::TabClosed,
        });
        let line = msg.to_line().unwrap();
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1);
    }

    #[test]
    fn the_type_discriminant_is_flattened_onto_the_object() {
        let msg = DaemonToApp::SessionRegistered(SessionRegistered {
            v: PROTOCOL_VERSION,
            ts: timestamp(now()),
            session_id: "s1".into(),
            tab_id: Some("tab-1".into()),
            agent: "claude-code".into(),
            cwd: Some("/repo".into()),
            title: None,
            model: None,
            started_at: timestamp(now()),
        });
        let j = json_of(&msg);
        assert_eq!(j["type"], "session_registered");
        assert_eq!(j["v"], 1);
        assert_eq!(j["session_id"], "s1");
        assert!(
            j["title"].is_null(),
            "unknown title is null, never a placeholder"
        );
    }

    /// An unknown cwd is `null`, and specifically not `""`.
    ///
    /// The empty string is schema-compliant and renders as an empty path, which
    /// reads as "the session is at the root" rather than "we do not know". That
    /// is the same fabrication the registry's no-zero rule exists to prevent,
    /// so it gets its own test rather than riding along with the others.
    #[test]
    fn an_unknown_cwd_is_null_and_never_the_empty_string() {
        let msg = DaemonToApp::SessionRegistered(SessionRegistered {
            v: PROTOCOL_VERSION,
            ts: timestamp(now()),
            session_id: "s1".into(),
            tab_id: None,
            agent: "unknown".into(),
            cwd: None,
            title: None,
            model: None,
            started_at: timestamp(now()),
        });
        let j = json_of(&msg);
        assert!(j["cwd"].is_null());
        assert_ne!(j["cwd"], "");
        assert_eq!(
            j["agent"], "unknown",
            "`unknown` is an enumerated agent value, not a fallback we invented"
        );
    }

    #[test]
    fn enum_spellings_match_the_protocol() {
        let j = json_of(&DaemonToApp::HitlResolved(HitlResolved {
            v: PROTOCOL_VERSION,
            ts: timestamp(now()),
            hitl_id: "h1".into(),
            session_id: "s1".into(),
            origin: HitlOrigin::DaemonError,
            decision: None,
        }));
        assert_eq!(j["origin"], "daemon_error");
        assert!(j["decision"].is_null());

        let j = json_of(&DaemonToApp::SessionEnded(SessionEnded {
            v: PROTOCOL_VERSION,
            ts: timestamp(now()),
            session_id: "s1".into(),
            tab_id: None,
            reason: EndReason::SessionEndHook,
        }));
        assert_eq!(j["reason"], "session_end_hook");
    }

    /// The three-way distinction that makes the sparse patch honest.
    #[test]
    fn sparse_patch_distinguishes_absent_from_null_from_value() {
        let mut p = SessionUpdated::new("s1", now());
        p.context_window_used_tokens = Some(Some(39_104)); // a reading
        p.title = Some(None); // became unknown
                              // model left as None -> unchanged, must not appear at all

        let j = json_of(&DaemonToApp::SessionUpdated(p));
        assert_eq!(j["context_window_used_tokens"], 39_104);
        assert!(j["title"].is_null());
        assert!(
            j.get("model").is_none(),
            "an unchanged field must be absent, not null — null means 'became unknown'"
        );
    }

    #[test]
    fn an_untouched_patch_carries_only_the_envelope() {
        let p = SessionUpdated::new("s1", now());
        assert!(p.is_empty());

        let j = json_of(&DaemonToApp::SessionUpdated(p));
        let obj = j.as_object().unwrap();
        let mut keys: Vec<_> = obj.keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(keys, vec!["session_id", "ts", "type", "v"]);
    }

    #[test]
    fn there_is_no_context_pct_on_the_wire() {
        let mut p = SessionUpdated::new("s1", now());
        p.context_window_used_tokens = Some(Some(100));
        p.context_window_size_tokens = Some(Some(200));
        let j = json_of(&DaemonToApp::SessionUpdated(p));
        assert!(
            j.get("context_pct").is_none(),
            "the app derives the percentage; the daemon must not send one"
        );
    }

    /// The four token quantities are four independent fields.
    ///
    /// The point of the long names is that occupancy and cost are different
    /// measurements: compaction drops the first while the second keeps
    /// climbing. If these ever collapse into one number, or if a total appears
    /// on the wire, the distinction is lost before the app can see it.
    #[test]
    fn the_four_token_quantities_stay_four_and_nothing_totals_them() {
        let mut p = SessionUpdated::new("s1", now());
        p.context_window_used_tokens = Some(Some(39_104));
        p.context_window_size_tokens = Some(Some(200_000));
        p.cumulative_input_tokens = Some(Some(1_204_882));
        p.cumulative_output_tokens = Some(Some(88_120));

        let j = json_of(&DaemonToApp::SessionUpdated(p));
        assert_eq!(j["context_window_used_tokens"], 39_104);
        assert_eq!(j["context_window_size_tokens"], 200_000);
        assert_eq!(j["cumulative_input_tokens"], 1_204_882);
        assert_eq!(j["cumulative_output_tokens"], 88_120);

        for invented in ["tokens", "total_tokens", "context_pct", "cost"] {
            assert!(
                j.get(invented).is_none(),
                "`{invented}` is derived; deriving it here is what makes the two \
                 pairs look interchangeable"
            );
        }
    }

    /// `last_event_at` is about the session; `ts` is about the message.
    #[test]
    fn last_event_at_is_distinct_from_the_envelope_timestamp() {
        let mut p = SessionUpdated::new("s1", now());
        p.last_event_at = Some(Some("2026-07-31T10:00:00Z".into()));

        let j = json_of(&DaemonToApp::SessionUpdated(p));
        assert_eq!(j["last_event_at"], "2026-07-31T10:00:00Z");
        assert_ne!(
            j["last_event_at"], j["ts"],
            "collapsing these means the sidebar can only infer quietness from \
             the absence of messages, which the protocol forbids"
        );
    }

    // ---- inbound ---------------------------------------------------------

    #[test]
    fn parses_each_app_to_daemon_message() {
        let m =
            parse_inbound(r#"{"type":"register_tab","v":1,"ts":"x","tab_id":"tab-1","cwd":"/r"}"#)
                .unwrap();
        assert_eq!(
            m,
            AppToDaemon::RegisterTab {
                tab_id: "tab-1".into(),
                cwd: Some("/r".into())
            }
        );

        let m = parse_inbound(
            r#"{"type":"rename_session","v":1,"ts":"x","session_id":"s","title":"t"}"#,
        )
        .unwrap();
        assert_eq!(
            m,
            AppToDaemon::RenameSession {
                session_id: "s".into(),
                title: "t".into()
            }
        );

        let m = parse_inbound(r#"{"type":"close_tab","v":1,"ts":"x","tab_id":"tab-1"}"#).unwrap();
        assert_eq!(
            m,
            AppToDaemon::CloseTab {
                tab_id: "tab-1".into()
            }
        );

        let m = parse_inbound(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#).unwrap();
        assert_eq!(m, AppToDaemon::RequestSnapshot {});

        let m = parse_inbound(
            r#"{"type":"resolve_hitl","v":1,"ts":"x","hitl_id":"h","decision":{"behavior":"allow"}}"#,
        )
        .unwrap();
        match m {
            AppToDaemon::ResolveHitl { hitl_id, decision } => {
                assert_eq!(hitl_id, "h");
                assert_eq!(decision.behavior, "allow");
                assert_eq!(decision.reason, None);
            }
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[test]
    fn unknown_fields_are_ignored_so_a_newer_client_still_works() {
        let m = parse_inbound(
            r#"{"type":"register_tab","v":1,"ts":"x","tab_id":"t","future_field":42}"#,
        )
        .unwrap();
        assert_eq!(
            m,
            AppToDaemon::RegisterTab {
                tab_id: "t".into(),
                cwd: None
            }
        );
    }

    #[test]
    fn an_unknown_type_is_rejected_not_fatal() {
        let e = parse_inbound(r#"{"type":"from_the_future","v":1,"ts":"x"}"#).unwrap_err();
        assert_eq!(e, Rejected::UnknownType("from_the_future".into()));
    }

    #[test]
    fn a_newer_protocol_version_is_dropped_rather_than_guessed_at() {
        let e = parse_inbound(r#"{"type":"request_snapshot","v":99,"ts":"x"}"#).unwrap_err();
        assert_eq!(e, Rejected::UnsupportedVersion(99));
    }

    #[test]
    fn garbage_never_panics() {
        for bad in ["", "   ", "not json", "[1,2,3]", "null", "{", r#"{"v":1}"#] {
            assert!(
                parse_inbound(bad).is_err(),
                "{bad:?} should be rejected, not accepted"
            );
        }
    }
}
