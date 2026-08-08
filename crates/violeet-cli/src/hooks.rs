//! What an violeet hook entry looks like, and how to recognize one.
//!
//! # Two URLs, not eleven
//!
//! The daemon exposes **one** route for every informational hook,
//! `/hook/event`, and discriminates on the payload's own `hook_event_name`.
//! `/hook/permission-request` is separate because it is the only one that
//! blocks. So every informational event gets the same URL, and adding an event
//! to the list below needs no daemon change at all.
//!
//! Confirmed by reading `crates/violeet-daemon/src/http/mod.rs`, not by
//! assuming: a `PermissionRequest` payload arriving at `/hook/event` is
//! answered `500` on purpose, precisely so this mistake is loud.
//!
//! # `allowedEnvVars` is load-bearing
//!
//! The tab binding (ADR-003) rides in the `x-violeet-tab-id` header as
//! `$VIOLEET_TAB_ID`. Claude Code only interpolates an environment variable into
//! a header if that variable is **also listed in `allowedEnvVars`** — otherwise
//! the reference resolves to an empty string. And the daemon deliberately reads
//! an empty header as *no tab*, so getting this wrong does not error: it
//! silently unbinds every session from its tab. It is one array and it is the
//! difference between the product working and looking broken.

use serde_json::{json, Map, Value};

/// Every event we install against `/hook/event`.
///
/// Ten, not nine. The daemon's `HookEvent` enumerates nine informational events
/// and `CwdChanged` is not among them — it lands in `Unrecognized`, which the
/// registry records as activity without deriving a state. We install it anyway
/// because `docs/PROTOCOL.md` documents `cwd` as "emitted on `cwd-changed`", so
/// the wire contract expects it to exist; the daemon simply does not consume it
/// yet. Recorded in `docs/tracks/C.md` rather than papered over by dropping an
/// event to make the count read nine.
pub const INFORMATIONAL_EVENTS: &[&str] = &[
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Notification",
    "Stop",
    "SubagentStop",
    "PreCompact",
    "SessionEnd",
    "CwdChanged",
];

/// The one that blocks.
pub const PERMISSION_EVENT: &str = "PermissionRequest";

/// How an violeet entry is recognized on the way back out.
///
/// A query parameter on our own URL rather than an extra JSON key. Claude Code
/// validates hook entries against a schema, and an unknown field is a bet that
/// the schema is permissive — a bet that costs the user a settings file that no
/// longer loads. A query string is inert: the daemon routes on path, so
/// `/hook/event?src=violeet` and `/hook/event` reach the same handler, and the
/// marker survives a port change because it is matched independently of it.
pub const MARKER: &str = "src=violeet";

/// Informational hooks answer immediately; five seconds is already generous for
/// a loopback POST the daemon replies `204` to without doing any work.
const INFORMATIONAL_TIMEOUT: u64 = 5;

/// The permission hook must outlive the daemon's own deadline.
///
/// The daemon expires a held request after five minutes and answers `500`,
/// which drops the user into the interactive dialog — the measured-safe
/// fallback. If the *hook* timed out first, the same thing would happen but
/// earlier and for a different reason, and the daemon would still be holding a
/// card for a request nobody is waiting on. So this is comfortably past 300s.
const PERMISSION_TIMEOUT: u64 = 600;

/// The header carrying `VIOLEET_TAB_ID`, spelled as the daemon reads it.
const TAB_ID_HEADER: &str = "x-violeet-tab-id";
const TAB_ID_ENV: &str = "VIOLEET_TAB_ID";

/// Events that take a tool matcher. The rest reject or ignore one.
///
/// `CwdChanged` explicitly does not support matchers and fires on every change,
/// so giving it one would be writing a field the schema does not accept.
fn takes_matcher(event: &str) -> bool {
    matches!(event, "PreToolUse" | "PostToolUse" | PERMISSION_EVENT)
}

pub fn informational_url(port: u16) -> String {
    format!("http://127.0.0.1:{port}/hook/event?{MARKER}")
}

pub fn permission_url(port: u16) -> String {
    format!("http://127.0.0.1:{port}/hook/permission-request?{MARKER}")
}

/// True if this hook object is one of ours.
pub fn is_ours(hook: &Value) -> bool {
    hook.get("url")
        .and_then(Value::as_str)
        .is_some_and(|url| url.contains(MARKER))
}

/// True if this matcher group contains only our hooks (so the whole group goes).
pub fn group_is_ours(group: &Value) -> bool {
    match group.get("hooks").and_then(Value::as_array) {
        Some(hooks) => !hooks.is_empty() && hooks.iter().all(is_ours),
        None => false,
    }
}

/// One `{matcher?, hooks: [...]}` group for `event`.
pub fn entry_for(event: &str, port: u16) -> Value {
    let is_permission = event == PERMISSION_EVENT;

    let mut hook = Map::new();
    hook.insert("type".into(), json!("http"));
    hook.insert(
        "url".into(),
        json!(if is_permission {
            permission_url(port)
        } else {
            informational_url(port)
        }),
    );
    hook.insert(
        "timeout".into(),
        json!(if is_permission {
            PERMISSION_TIMEOUT
        } else {
            INFORMATIONAL_TIMEOUT
        }),
    );
    hook.insert("headers".into(), json!({ TAB_ID_HEADER: format!("${TAB_ID_ENV}") }));
    hook.insert("allowedEnvVars".into(), json!([TAB_ID_ENV]));

    let mut group = Map::new();
    if takes_matcher(event) {
        group.insert("matcher".into(), json!("*"));
    }
    group.insert("hooks".into(), Value::Array(vec![Value::Object(hook)]));
    Value::Object(group)
}

/// Every event we install, permission last so a reader sees the ordinary ones
/// first.
pub fn all_events() -> Vec<&'static str> {
    let mut events: Vec<&'static str> = INFORMATIONAL_EVENTS.to_vec();
    events.push(PERMISSION_EVENT);
    events
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The failure this whole module is arranged to prevent: a header that
    /// interpolates to nothing, which the daemon reads as "no tab" and which
    /// therefore breaks the binding without producing a single error.
    #[test]
    fn every_entry_declares_the_env_var_it_interpolates() {
        for event in all_events() {
            let entry = entry_for(event, 9847);
            let hook = &entry["hooks"][0];

            let header = hook["headers"][TAB_ID_HEADER].as_str().unwrap();
            assert_eq!(header, "$VIOLEET_TAB_ID");

            let allowed = hook["allowedEnvVars"].as_array().unwrap();
            assert!(
                allowed.iter().any(|v| v == TAB_ID_ENV),
                "{event}: a header referencing $VIOLEET_TAB_ID that is not in \
                 allowedEnvVars resolves to an empty string, and an empty \
                 x-violeet-tab-id is read by the daemon as no tab at all"
            );
        }
    }

    #[test]
    fn the_permission_hook_outlives_the_daemons_own_deadline() {
        let entry = entry_for(PERMISSION_EVENT, 9847);
        let timeout = entry["hooks"][0]["timeout"].as_u64().unwrap();
        assert!(
            timeout > 300,
            "the daemon expires a held request at 300s; a shorter hook timeout \
             would pre-empt the fallback it is designed to produce"
        );
    }

    #[test]
    fn informational_events_share_one_url_and_permission_has_its_own() {
        let informational: Vec<String> = INFORMATIONAL_EVENTS
            .iter()
            .map(|e| entry_for(e, 9847)["hooks"][0]["url"].as_str().unwrap().to_string())
            .collect();

        assert!(
            informational.windows(2).all(|w| w[0] == w[1]),
            "the daemon discriminates on hook_event_name, so one route serves all"
        );
        assert!(informational[0].ends_with("/hook/event?src=violeet"));

        let permission = entry_for(PERMISSION_EVENT, 9847);
        assert_eq!(
            permission["hooks"][0]["url"],
            "http://127.0.0.1:9847/hook/permission-request?src=violeet"
        );
    }

    /// `CwdChanged` does not support matchers, and neither do the lifecycle
    /// events. Writing one anyway is writing a field the schema rejects.
    #[test]
    fn only_tool_events_carry_a_matcher() {
        assert!(entry_for("CwdChanged", 9847).get("matcher").is_none());
        assert!(entry_for("SessionStart", 9847).get("matcher").is_none());
        assert_eq!(entry_for("PreToolUse", 9847)["matcher"], "*");
        assert_eq!(entry_for(PERMISSION_EVENT, 9847)["matcher"], "*");
    }

    /// The marker has to survive the daemon moving to another port, because
    /// uninstall must still find entries installed against the old one.
    #[test]
    fn ours_is_recognized_independently_of_the_port() {
        assert!(is_ours(&entry_for("Stop", 9847)["hooks"][0]));
        assert!(is_ours(&entry_for("Stop", 51234)["hooks"][0]));

        let foreign = json!({"type": "command", "command": "notify.sh"});
        assert!(!is_ours(&foreign));

        let foreign_http = json!({"type": "http", "url": "http://127.0.0.1:9847/hook/event"});
        assert!(
            !is_ours(&foreign_http),
            "an unmarked URL is somebody else's, even pointing at our own route"
        );
    }
}
