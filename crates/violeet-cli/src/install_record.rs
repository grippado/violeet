//! What violeet has installed, so `doctor` can notice when it vanishes.
//!
//! A settings file is not only ours. Dotfile managers routinely *generate*
//! `~/.claude/settings.json` from a base and an overlay, reconstructing it from
//! scratch each time — which silently removes anything violeet wrote. The user
//! runs their installer for an unrelated reason and the sidebar quietly stops
//! filling in, with nothing anywhere saying why.
//!
//! Recording what we wrote is the whole mechanism. It does not prevent the
//! overwrite and cannot name what did it; it turns an invisible failure into a
//! visible one, which is the only thing a diagnostic can honestly promise.

use std::path::PathBuf;

use serde_json::Value;

#[derive(Debug, Clone, Copy, Default)]
pub struct Record {
    pub hooks: bool,
    pub cursor_hooks: bool,
    pub statusline: bool,
}

fn path() -> Option<PathBuf> {
    crate::probe::violeet_dir().map(|d| d.join("installed.json"))
}

pub fn read() -> Option<Record> {
    let text = std::fs::read_to_string(path()?).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    Some(Record {
        hooks: v.get("hooks").and_then(Value::as_bool).unwrap_or(false),
        cursor_hooks: v
            .get("cursor_hooks")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        statusline: v.get("statusline").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// Set Claude Code hooks flag, preserving the others.
pub fn set(hooks: Option<bool>, statusline: Option<bool>) {
    let Some(path) = path() else { return };
    let current = read().unwrap_or_default();

    let body = serde_json::json!({
        "hooks": hooks.unwrap_or(current.hooks),
        "cursor_hooks": current.cursor_hooks,
        "statusline": statusline.unwrap_or(current.statusline),
    });

    write_record(&path, &body);
}

/// Set Cursor hooks flag, preserving the others.
pub fn set_cursor(cursor_hooks: Option<bool>) {
    let Some(path) = path() else { return };
    let current = read().unwrap_or_default();

    let body = serde_json::json!({
        "hooks": current.hooks,
        "cursor_hooks": cursor_hooks.unwrap_or(current.cursor_hooks),
        "statusline": current.statusline,
    });

    write_record(&path, &body);
}

fn write_record(path: &PathBuf, body: &Value) {
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // Best effort throughout: failing to record costs a diagnostic, and must
    // never fail an install that otherwise succeeded.
    let _ = std::fs::write(path, serde_json::to_string_pretty(body).unwrap_or_default() + "\n");
}
