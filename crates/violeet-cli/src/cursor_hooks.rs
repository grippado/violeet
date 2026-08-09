//! Cursor IDE hooks — `~/.cursor/hooks.json` in the command schema.
//!
//! Claude Code uses HTTP hooks in `~/.claude/settings.json`; Cursor spawns a
//! command and passes JSON on stdin. The adapter script in `~/.violeet/` POSTs
//! to the same daemon routes, with `x-violeet-harness: cursor`.

use std::path::PathBuf;

use serde_json::{json, Map, Value};

/// Lifecycle and HITL events installed for Cursor. Names are Cursor's hook keys.
pub const EVENTS: &[&str] = &[
    "sessionStart",
    "sessionEnd",
    "beforeSubmitPrompt",
    "stop",
    "beforeShellExecution",
    "beforeMCPExecution",
];

/// Permission hooks need a longer timeout — the daemon may hold the response
/// until the human answers in the app.
const PERMISSION_TIMEOUT: u64 = 600;

/// Informational hooks: fire-and-forget on the daemon side.
const INFORMATIONAL_TIMEOUT: u64 = 5;

pub fn hooks_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cursor").join("hooks.json"))
}

pub fn script_path() -> Option<PathBuf> {
    crate::probe::violeet_dir().map(|d| d.join("cursor-hook.sh"))
}

/// True when this hook entry points at violeet's adapter script.
pub fn is_ours(hook: &Value) -> bool {
    hook.get("command")
        .and_then(Value::as_str)
        .is_some_and(|cmd| cmd.contains("cursor-hook.sh"))
}

/// One hook entry for `event`, pointing at the installed adapter script.
pub fn entry_for(event: &str, script: &str) -> Value {
    let is_permission = matches!(event, "beforeShellExecution" | "beforeMCPExecution");

    let mut hook = Map::new();
    hook.insert("command".into(), json!(script));
    hook.insert(
        "timeout".into(),
        json!(if is_permission {
            PERMISSION_TIMEOUT
        } else {
            INFORMATIONAL_TIMEOUT
        }),
    );

    Value::Object(hook)
}

/// The adapter script body — versioned in `scripts/cursor-hook.sh` and copied
/// to `~/.violeet/cursor-hook.sh` on install.
pub fn adapter_script_source() -> &'static str {
    include_str!("../../../scripts/cursor-hook.sh")
}

/// Read `~/.cursor/hooks.json`, or an empty shell when absent.
pub fn load(path: &std::path::Path) -> Result<Value, String> {
    if !path.exists() {
        return Ok(empty_document());
    }
    let text = std::fs::read_to_string(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let v: Value = serde_json::from_str(&text)
        .map_err(|e| format!("parse {}: {e}", path.display()))?;
    if !v.is_object() {
        return Err(format!("{} must be a JSON object", path.display()));
    }
    Ok(v)
}

pub fn empty_document() -> Value {
    json!({
        "version": 1,
        "hooks": {}
    })
}

/// Upsert violeet entries for every Cursor event.
pub fn upsert_ours(doc: &mut Value, script: &str) {
    let hooks = doc
        .as_object_mut()
        .expect("document object")
        .entry("hooks")
        .or_insert_with(|| json!({}));
    let hooks_obj = hooks.as_object_mut().expect("hooks object");

    for event in EVENTS {
        let entry = entry_for(event, script);
        let mut ours = vec![entry];
        if let Some(existing) = hooks_obj.get(*event).and_then(Value::as_array) {
            for hook in existing {
                if !is_ours(hook) {
                    ours.push(hook.clone());
                }
            }
        }
        hooks_obj.insert((*event).into(), Value::Array(ours));
    }
}

/// Remove violeet entries. Returns how many hook objects were removed.
pub fn remove_ours(doc: &mut Value) -> usize {
    let Some(hooks_obj) = doc.get_mut("hooks").and_then(Value::as_object_mut) else {
        return 0;
    };
    let mut removed = 0;
    for event in EVENTS {
        if let Some(arr) = hooks_obj.get_mut(*event).and_then(Value::as_array_mut) {
            let before = arr.len();
            arr.retain(|h| !is_ours(h));
            removed += before - arr.len();
            if arr.is_empty() {
                hooks_obj.remove(*event);
            }
        }
    }
    removed
}

pub fn count_ours(doc: &Value) -> usize {
    EVENTS
        .iter()
        .filter(|event| {
            doc.get("hooks")
                .and_then(|h| h.get(*event))
                .and_then(Value::as_array)
                .is_some_and(|arr| arr.iter().any(is_ours))
        })
        .count()
}

pub fn write(path: &std::path::Path, doc: &Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    let body = serde_json::to_string_pretty(doc).map_err(|e| e.to_string())? + "\n";
    std::fs::write(path, body).map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(())
}

pub fn install_script() -> Result<(), String> {
    let Some(path) = script_path() else {
        return Err("HOME is not set".into());
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    std::fs::write(&path, adapter_script_source()).map_err(|e| format!("write script: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| format!("chmod script: {e}"))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn permission_hooks_outlive_the_daemon_deadline() {
        let entry = entry_for("beforeShellExecution", "/home/me/.violeet/cursor-hook.sh");
        let timeout = entry["timeout"].as_u64().unwrap();
        assert!(
            timeout > 300,
            "daemon expires HITL at 300s; the hook must not time out first"
        );
    }

    #[test]
    fn informational_hooks_are_short() {
        let entry = entry_for("stop", "/home/me/.violeet/cursor-hook.sh");
        assert_eq!(entry["timeout"], 5);
    }

    #[test]
    fn ours_is_recognized_by_script_path() {
        let ours = entry_for("stop", "/Users/you/.violeet/cursor-hook.sh");
        assert!(is_ours(&ours));

        let foreign = json!({"command": "/other/hook.sh"});
        assert!(!is_ours(&foreign));
    }
}
