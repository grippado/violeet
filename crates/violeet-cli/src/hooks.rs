//! What an violeet hook entry looks like, and how to recognize one.
//!
//! # Two routes, not eleven
//!
//! The daemon exposes **one** route for every informational hook,
//! `/hook/event`, and discriminates on the payload's own `hook_event_name`.
//! `/hook/permission-request` is separate because it is the only one that
//! blocks. So every informational event goes to the same place, and adding an
//! event to the list below needs no daemon change at all — nor a script
//! change, since the script neither reads nor cares which event it is
//! carrying.
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
//!
//! This applies to the permission hook, which is still `type: http`. The
//! informational events carry the same binding through the adapter script,
//! which reads `$VIOLEET_TAB_ID` out of its own environment and sends the same
//! header — no `allowedEnvVars` involved, because nothing is interpolated.
//!
//! # Two shapes, and why
//!
//! The informational events are `type: command`, pointing at
//! `~/.violeet/claude-hook.sh`; only `PermissionRequest` is still `type: http`.
//!
//! They started out alike, both HTTP. The trouble is that an HTTP hook has no
//! way to express "the daemon is not running": Claude Code treats a connection
//! failure as non-blocking, so nothing breaks, but it writes
//! `<event> hook error / connect ECONNREFUSED` into the transcript every time.
//! `PreToolUse` and `PostToolUse` fire on every tool call, so a machine with the
//! daemon down fills with errors about a feature nobody asked for. The hook
//! schema offers no `optional`/`ignoreFailure` to turn that off — checked
//! against the reference rather than assumed — so the only lever left is to
//! stop making a request that cannot succeed. The script checks for
//! `~/.violeet/daemon.json` and exits 0 when it is absent, which is what the
//! Cursor adapter has always done.
//!
//! `PermissionRequest` stays HTTP deliberately, and the reason is that its
//! failure mode is already correct. It fires only when a human is about to be
//! asked something, so it is rare and its error is not the wall of noise above;
//! and when the daemon is unreachable, Claude Code falls through to its own
//! permission dialog — the same measured-safe fallback the 600s timeout below
//! exists to preserve. Rewriting the one hook that blocks on a person, to fix
//! noise it does not produce, would be trading a real invariant for a cosmetic
//! win.
//!
//! A consequence worth naming: the port is no longer baked into the
//! informational entries, because the script reads it from the discovery file
//! at fire time. Those entries now survive the daemon moving to another port,
//! which the HTTP ones never did.

use std::path::PathBuf;

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

pub fn permission_url(port: u16) -> String {
    format!("http://127.0.0.1:{port}/hook/permission-request?{MARKER}")
}

/// Where the adapter script lives once installed.
pub fn script_path() -> Option<PathBuf> {
    crate::probe::violeet_dir().map(|d| d.join("claude-hook.sh"))
}

/// The adapter script body — versioned in `scripts/claude-hook.sh` and copied
/// to `~/.violeet/claude-hook.sh` on install.
pub fn adapter_script_source() -> &'static str {
    include_str!("../../../scripts/claude-hook.sh")
}

/// Write the adapter to `~/.violeet/claude-hook.sh`, executable.
///
/// Rewritten on every install rather than written once when missing: the body
/// is compiled into this binary, so an upgraded CLI beside a stale script is a
/// version skew nobody would think to look for.
pub fn install_script() -> Result<PathBuf, String> {
    let Some(path) = script_path() else {
        return Err("HOME is not set".into());
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    std::fs::write(&path, adapter_script_source())
        .map_err(|e| format!("write {}: {e}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("chmod {}: {e}", path.display()))?;
    }
    Ok(path)
}

/// True if this hook object is one of ours.
///
/// Both shapes have to be recognized here, and by the same marker. `uninstall`
/// removes exactly what `is_ours` claims, so a marker that only matched the
/// HTTP form would strand every informational entry in the user's settings
/// file — installed by us, invisible to us, removable only by hand. That also
/// covers the upgrade: a machine still carrying the old all-HTTP layout is
/// recognized entry for entry, so the next `install-hooks` replaces it instead
/// of doubling it.
pub fn is_ours(hook: &Value) -> bool {
    let marked = |field: &str| {
        hook.get(field)
            .and_then(Value::as_str)
            .is_some_and(|value| value.contains(MARKER))
    };
    marked("url") || marked("command")
}

/// True if this matcher group contains only our hooks (so the whole group goes).
pub fn group_is_ours(group: &Value) -> bool {
    match group.get("hooks").and_then(Value::as_array) {
        Some(hooks) => !hooks.is_empty() && hooks.iter().all(is_ours),
        None => false,
    }
}

/// The shell command an informational entry runs.
///
/// The marker rides as an argument the script ignores, rather than being read
/// off the file name. A path is something the user can move or rename; the
/// argument is ours and travels with the entry, so `is_ours` keeps working
/// either way.
pub fn informational_command(script: &str) -> String {
    format!("\"{script}\" --{MARKER}")
}

/// One `{matcher?, hooks: [...]}` group for `event`.
///
/// `port` is only consumed by the permission hook; the informational ones read
/// it from the discovery file when they fire.
pub fn entry_for(event: &str, port: u16, script: &str) -> Value {
    let mut hook = Map::new();

    if event == PERMISSION_EVENT {
        hook.insert("type".into(), json!("http"));
        hook.insert("url".into(), json!(permission_url(port)));
        hook.insert("timeout".into(), json!(PERMISSION_TIMEOUT));
        hook.insert("headers".into(), json!({ TAB_ID_HEADER: format!("${TAB_ID_ENV}") }));
        hook.insert("allowedEnvVars".into(), json!([TAB_ID_ENV]));
    } else {
        hook.insert("type".into(), json!("command"));
        hook.insert("command".into(), json!(informational_command(script)));
        hook.insert("timeout".into(), json!(INFORMATIONAL_TIMEOUT));
    }

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

    const SCRIPT: &str = "/Users/me/.violeet/claude-hook.sh";

    /// The route the daemon actually serves (`crates/violeet-daemon/src/http`
    /// registers it literally, so there is no shared constant to import). It
    /// lives here because the script is now the only thing that spells the URL
    /// out, and this is what holds it to the daemon.
    const INFORMATIONAL_ROUTE: &str = "/hook/event";

    /// The failure this whole module is arranged to prevent: a header that
    /// interpolates to nothing, which the daemon reads as "no tab" and which
    /// therefore breaks the binding without producing a single error.
    ///
    /// Only the permission hook interpolates anything now — the informational
    /// entries carry the same binding through the script's own environment —
    /// so this guards the one entry that still needs guarding.
    #[test]
    fn the_permission_entry_declares_the_env_var_it_interpolates() {
        let entry = entry_for(PERMISSION_EVENT, 9847, SCRIPT);
        let hook = &entry["hooks"][0];

        let header = hook["headers"][TAB_ID_HEADER].as_str().unwrap();
        assert_eq!(header, "$VIOLEET_TAB_ID");

        let allowed = hook["allowedEnvVars"].as_array().unwrap();
        assert!(
            allowed.iter().any(|v| v == TAB_ID_ENV),
            "a header referencing $VIOLEET_TAB_ID that is not in \
             allowedEnvVars resolves to an empty string, and an empty \
             x-violeet-tab-id is read by the daemon as no tab at all"
        );
    }

    #[test]
    fn the_permission_hook_outlives_the_daemons_own_deadline() {
        let entry = entry_for(PERMISSION_EVENT, 9847, SCRIPT);
        let timeout = entry["hooks"][0]["timeout"].as_u64().unwrap();
        assert!(
            timeout > 300,
            "the daemon expires a held request at 300s; a shorter hook timeout \
             would pre-empt the fallback it is designed to produce"
        );
    }

    /// The point of the whole change: an informational event must not be able
    /// to reach the network on its own, because that is what prints
    /// `connect ECONNREFUSED` once per tool call when the daemon is down.
    #[test]
    fn informational_events_run_the_script_and_name_no_url() {
        for event in INFORMATIONAL_EVENTS {
            let entry = entry_for(event, 9847, SCRIPT);
            let hook = &entry["hooks"][0];

            assert_eq!(hook["type"], "command", "{event}");
            assert!(
                hook.get("url").is_none(),
                "{event}: a url here is a request Claude Code makes itself, \
                 with no way to skip it when the daemon is absent"
            );
            assert!(
                hook["command"].as_str().unwrap().contains("claude-hook.sh"),
                "{event}"
            );
        }
    }

    /// The permission hook is the deliberate exception, not an oversight.
    #[test]
    fn the_permission_hook_stays_http() {
        let hook = &entry_for(PERMISSION_EVENT, 9847, SCRIPT)["hooks"][0];
        assert_eq!(hook["type"], "http");
        assert_eq!(
            hook["url"],
            "http://127.0.0.1:9847/hook/permission-request?src=violeet"
        );
    }

    /// The daemon discriminates on `hook_event_name`, so one script invocation
    /// serves every informational event — same command, byte for byte.
    #[test]
    fn informational_events_share_one_command() {
        let commands: Vec<String> = INFORMATIONAL_EVENTS
            .iter()
            .map(|e| entry_for(e, 9847, SCRIPT)["hooks"][0]["command"].as_str().unwrap().to_string())
            .collect();

        assert!(commands.windows(2).all(|w| w[0] == w[1]));
    }

    /// A path with a space in it is a real home directory, not a curiosity.
    #[test]
    fn the_script_path_survives_a_space() {
        let entry = entry_for("Stop", 9847, "/Users/my name/.violeet/claude-hook.sh");
        let command = entry["hooks"][0]["command"].as_str().unwrap();
        assert!(
            command.starts_with('"') && command.contains("my name/.violeet"),
            "an unquoted path would be split into two arguments by the shell: {command}"
        );
    }

    /// `CwdChanged` does not support matchers, and neither do the lifecycle
    /// events. Writing one anyway is writing a field the schema rejects.
    #[test]
    fn only_tool_events_carry_a_matcher() {
        assert!(entry_for("CwdChanged", 9847, SCRIPT).get("matcher").is_none());
        assert!(entry_for("SessionStart", 9847, SCRIPT).get("matcher").is_none());
        assert_eq!(entry_for("PreToolUse", 9847, SCRIPT)["matcher"], "*");
        assert_eq!(entry_for(PERMISSION_EVENT, 9847, SCRIPT)["matcher"], "*");
    }

    /// The marker has to survive the daemon moving to another port, because
    /// uninstall must still find entries installed against the old one.
    #[test]
    fn ours_is_recognized_independently_of_the_port() {
        assert!(is_ours(&entry_for("Stop", 9847, SCRIPT)["hooks"][0]));
        assert!(is_ours(&entry_for("Stop", 51234, SCRIPT)["hooks"][0]));

        let foreign = json!({"type": "command", "command": "notify.sh"});
        assert!(!is_ours(&foreign));

        let foreign_http = json!({"type": "http", "url": "http://127.0.0.1:9847/hook/event"});
        assert!(
            !is_ours(&foreign_http),
            "an unmarked URL is somebody else's, even pointing at our own route"
        );
    }

    /// Both shapes answer to the same marker, or uninstall strands whichever
    /// one it cannot see. The HTTP entry here is the layout every already
    /// installed machine is carrying right now.
    #[test]
    fn ours_is_recognized_in_either_shape() {
        for event in all_events() {
            assert!(is_ours(&entry_for(event, 9847, SCRIPT)["hooks"][0]), "{event}");
        }

        let previously_installed = json!({
            "type": "http",
            "url": "http://127.0.0.1:9847/hook/event?src=violeet",
            "timeout": 5,
        });
        assert!(
            is_ours(&previously_installed),
            "an upgrade must recognize the entries the previous version wrote, \
             or it doubles them instead of replacing them"
        );
    }

    /// A whole group of ours goes on uninstall; a group holding somebody
    /// else's hook does not.
    #[test]
    fn a_group_is_ours_only_when_every_hook_in_it_is() {
        assert!(group_is_ours(&entry_for("Stop", 9847, SCRIPT)));

        let mixed = json!({"hooks": [
            entry_for("Stop", 9847, SCRIPT)["hooks"][0],
            {"type": "command", "command": "notify.sh"},
        ]});
        assert!(!group_is_ours(&mixed));
    }

    /// The script is the only thing that knows the full URL now, so it is held
    /// to the route the daemon actually serves. A typo here would be a hook
    /// that runs, succeeds, and delivers nothing — the failure mode with no
    /// symptom.
    #[test]
    fn the_script_posts_to_the_route_we_document() {
        let script = adapter_script_source();
        assert!(script.contains(INFORMATIONAL_ROUTE));
        assert!(
            script.contains(MARKER),
            "the marker travels on the request too, so the daemon can tell our \
             traffic apart"
        );
        assert!(
            !script.contains("/hook/permission-request"),
            "this adapter carries informational events only; the blocking one \
             is still a native http hook"
        );
    }

    /// The whole point: no daemon, no request, no error. Asserted on the source
    /// because the alternative is asserting on a machine that happens to have
    /// the daemon down.
    #[test]
    fn the_script_gives_up_before_reaching_the_network() {
        let script = adapter_script_source();
        let discovery = script
            .find("daemon.json")
            .expect("the script must consult the discovery file");
        let curl = script.find("curl -s").expect("and eventually POST");
        assert!(
            discovery < curl,
            "the discovery check has to come first, or the request is already \
             made by the time we notice there is nobody to receive it"
        );
        assert!(script.contains("exit 0"));
    }

    /// An informational hook has no decision to make, so it must never hand
    /// Claude Code an exit code that reads as one. Exit 2 on `PreToolUse`
    /// blocks the tool call outright.
    #[test]
    fn the_script_never_exits_nonzero() {
        for line in adapter_script_source().lines() {
            let line = line.trim();
            if let Some(rest) = line.strip_prefix("exit ") {
                assert_eq!(rest, "0", "a nonzero exit from a PreToolUse hook blocks the tool");
            }
        }
    }
}
