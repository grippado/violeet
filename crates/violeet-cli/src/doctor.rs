//! `violeet doctor` — say what is wrong and what to type.
//!
//! Every check prints ✓, ✗ or ⚠ and, when it is not ✓, the thing to do about
//! it. A diagnostic that reports a problem without a next step has moved the
//! work rather than done it.
//!
//! The check that justifies the command existing is the trust one. Project
//! settings in an untrusted directory are ignored **in silence** — no warning
//! anywhere — so the visible symptom is "my hooks do not fire" and the cause is
//! not in the hooks at all. It is exactly the kind of thing a doctor should
//! find, because nothing else will.

use std::path::Path;

use crate::cursor_hooks;
use crate::hooks;
use crate::probe;
use crate::settings::Settings;
use crate::ui::Style;

pub enum Status {
    Ok,
    Warn,
    Fail,
}

pub struct Check {
    pub status: Status,
    pub title: String,
    pub detail: Option<String>,
    /// What to type. Only present when there is something to type.
    pub fix: Option<String>,
}

impl Check {
    fn ok(title: impl Into<String>) -> Self {
        Self {
            status: Status::Ok,
            title: title.into(),
            detail: None,
            fix: None,
        }
    }
    fn warn(title: impl Into<String>) -> Self {
        Self {
            status: Status::Warn,
            title: title.into(),
            detail: None,
            fix: None,
        }
    }
    fn fail(title: impl Into<String>) -> Self {
        Self {
            status: Status::Fail,
            title: title.into(),
            detail: None,
            fix: None,
        }
    }
    fn detail(mut self, d: impl Into<String>) -> Self {
        self.detail = Some(d.into());
        self
    }
    fn fix(mut self, f: impl Into<String>) -> Self {
        self.fix = Some(f.into());
        self
    }
}

/// Run every check. Returns them in the order they should be read.
pub fn run(cwd: &Path) -> Vec<Check> {
    let mut checks = Vec::new();

    // --- the daemon -------------------------------------------------------
    let discovery = probe::read_discovery();

    match &discovery {
        Some(info) => {
            let mut check = Check::ok("daemon discovery file").detail(format!(
                "pid {}, hook port {}, up since {}",
                info.pid, info.hook_port, info.started_at
            ));
            // Checked here as well as against /health, because a version skew
            // is worth naming even when the endpoint is unreachable — those are
            // two different problems and the second would otherwise mask this.
            if info.protocol_version != violeet_proto::PROTOCOL_VERSION as u64 {
                check = Check::warn("daemon discovery file")
                    .detail(format!(
                        "the daemon advertises protocol v{}, this CLI speaks v{}",
                        info.protocol_version,
                        violeet_proto::PROTOCOL_VERSION
                    ))
                    .fix("rebuild the daemon and the CLI from the same checkout");
            }
            checks.push(check);
        }
        None => {
            checks.push(
                Check::fail("daemon discovery file")
                    .detail("~/.violeet/daemon.json is missing, so the daemon is probably not running")
                    .fix("violeet-daemon &"),
            );
        }
    }

    let socket_path = discovery
        .as_ref()
        .map(|i| i.socket.clone())
        .or_else(probe::default_socket_path);

    match &socket_path {
        Some(path) => match probe::socket_connects(path) {
            Ok(()) => checks.push(Check::ok("socket").detail(path.display().to_string())),
            Err(e) => checks.push(
                Check::fail("socket")
                    .detail(format!("{}: {e}", path.display()))
                    // A socket file with nothing behind it is the SIGKILL
                    // leftover, and it is worth naming because the file's
                    // presence makes it look like the daemon is up.
                    .fix("start the daemon; if the file exists but refuses connections, remove it first"),
            ),
        },
        None => checks.push(Check::fail("socket").detail("HOME is not set, so there is no path to check")),
    }

    let port = discovery.as_ref().map(|i| i.hook_port);
    let health = port.map(probe::health);

    match (&port, &health) {
        (Some(p), Some(Ok(h))) => {
            let mut check = Check::ok("hook endpoint")
                .detail(format!("http://127.0.0.1:{p}/health — {} session(s), {} pending", h.sessions, h.hitl_pending));
            if h.protocol_version != violeet_proto::PROTOCOL_VERSION as u64 {
                check = Check::warn("hook endpoint")
                    .detail(format!(
                        "the daemon speaks protocol v{}, this CLI speaks v{}",
                        h.protocol_version,
                        violeet_proto::PROTOCOL_VERSION
                    ))
                    .fix("rebuild both from the same checkout");
            }
            checks.push(check);
        }
        (Some(p), Some(Err(e))) => checks.push(
            Check::fail("hook endpoint")
                .detail(format!("http://127.0.0.1:{p}/health — {e}"))
                .fix("start the daemon"),
        ),
        _ => checks.push(
            Check::fail("hook endpoint")
                .detail("no port to check, because there is no discovery file")
                .fix("violeet-daemon &"),
        ),
    }

    // --- the hooks --------------------------------------------------------
    let settings_path = crate::settings::default_path();
    let settings = settings_path.as_deref().map(Settings::load);

    match &settings {
        Some(Ok(s)) => {
            checks.extend(hook_checks(s, port));
            checks.extend(permission_conflict_check(s));
        }
        Some(Err(e)) => checks.push(
            Check::fail("settings file")
                .detail(e.to_string())
                .fix("fix the file by hand; violeet will not rewrite one it cannot parse"),
        ),
        None => checks.push(Check::fail("settings file").detail("HOME is not set")),
    }

    // --- Cursor hooks -----------------------------------------------------
    if let Some(path) = cursor_hooks::hooks_path() {
        match cursor_hooks::load(&path) {
            Ok(doc) => {
                checks.extend(cursor_hook_checks(&doc, port));
                let script_path = cursor_hooks::script_path();
                if let Some(script) = script_path {
                    if script.exists() {
                        checks.push(
                            Check::ok("Cursor hook adapter script")
                                .detail(script.display().to_string()),
                        );
                    } else if cursor_hooks::count_ours(&doc) > 0 {
                        checks.push(
                            Check::fail("Cursor hook adapter script")
                                .detail(format!("{} is missing", script.display()))
                                .fix("violeet install-cursor-hooks"),
                        );
                    }
                }
            }
            Err(e) => checks.push(
                Check::fail("Cursor hooks file")
                    .detail(e)
                    .fix("fix ~/.cursor/hooks.json by hand"),
            ),
        }
    } else {
        checks.push(Check::fail("Cursor hooks file").detail("HOME is not set"));
    }

    // --- the third silent one ---------------------------------------------
    if let Some(Ok(s)) = &settings {
        checks.push(overwritten_check(s));
    }

    // --- a second silent one ----------------------------------------------
    if let Some(Ok(h)) = &health {
        checks.push(unknown_model_check(&h.unknown_window_models));
    }

    // --- the silent one ---------------------------------------------------
    checks.push(trust_check(cwd));

    // --- environment ------------------------------------------------------
    match probe::claude_code_version() {
        Some(v) => checks.push(Check::ok("Claude Code").detail(format!("v{v}"))),
        None => checks.push(
            Check::warn("Claude Code")
                .detail("no versions found under ~/.local/share/claude/versions")
                .fix("this only affects the version shown here, not whether violeet works"),
        ),
    }

    checks.push(violeet_dir_check());

    checks
}

fn hook_checks(settings: &Settings, port: Option<u16>) -> Vec<Check> {
    let mut missing = Vec::new();
    let mut wrong_port = Vec::new();

    for event in hooks::all_events() {
        let ours: Vec<&serde_json::Value> = settings
            .groups_for(event)
            .into_iter()
            .filter(|g| hooks::group_is_ours(g))
            .collect();

        if ours.is_empty() {
            missing.push(event);
            continue;
        }
        if let Some(port) = port {
            let expected = if event == hooks::PERMISSION_EVENT {
                hooks::permission_url(port)
            } else {
                hooks::informational_url(port)
            };
            let matches = ours.iter().any(|g| {
                g["hooks"]
                    .as_array()
                    .is_some_and(|hs| hs.iter().any(|h| h["url"] == expected.as_str()))
            });
            if !matches {
                wrong_port.push(event);
            }
        }
    }

    let mut checks = Vec::new();

    if missing.is_empty() {
        checks.push(
            Check::ok("hooks installed")
                .detail(format!("{} event(s)", hooks::all_events().len())),
        );
    } else {
        checks.push(
            Check::fail("hooks installed")
                .detail(format!("missing for: {}", missing.join(", ")))
                .fix("violeet install-hooks"),
        );
    }

    if !wrong_port.is_empty() {
        checks.push(
            Check::fail("hooks point at the running daemon")
                .detail(format!(
                    "stale port for: {}. The hooks fire and reach nothing.",
                    wrong_port.join(", ")
                ))
                // Re-running install is enough because upsert replaces rather
                // than appends; the user does not have to uninstall first.
                .fix("violeet install-hooks"),
        );
    } else if port.is_some() && missing.is_empty() {
        checks.push(Check::ok("hooks point at the running daemon"));
    }

    checks
}

fn cursor_hook_checks(doc: &serde_json::Value, port: Option<u16>) -> Vec<Check> {
    let mut missing = Vec::new();

    for event in cursor_hooks::EVENTS {
        let ours = doc
            .get("hooks")
            .and_then(|h| h.get(*event))
            .and_then(|v| v.as_array())
            .is_some_and(|arr| arr.iter().any(cursor_hooks::is_ours));

        if !ours {
            missing.push(*event);
        }
    }

    let mut checks = Vec::new();

    if missing.is_empty() {
        checks.push(
            Check::ok("Cursor hooks installed")
                .detail(format!("{} event(s)", cursor_hooks::EVENTS.len())),
        );
    } else {
        checks.push(
            Check::fail("Cursor hooks installed")
                .detail(format!("missing for: {}", missing.join(", ")))
                .fix("violeet install-cursor-hooks"),
        );
    }

    if port.is_some() && missing.is_empty() {
        let discovery_port = port.unwrap();
        checks.push(
            Check::ok("Cursor hooks point at the running daemon")
                .detail(format!(
                    "adapter reads port {} from ~/.violeet/daemon.json",
                    discovery_port
                )),
        );
    } else if port.is_none() && missing.is_empty() {
        checks.push(
            Check::warn("Cursor hooks point at the running daemon")
                .detail("no discovery file — adapter will fail-open until the daemon starts")
                .fix("violeet-daemon &"),
        );
    }

    checks
}

/// The one that decides whether HITL works at all.
///
/// With two `PermissionRequest` hooks the first to decide wins and the slower
/// one is not even waited for (ADR-004). violeet has to be the only decider, and
/// a competing hook makes the outcome depend on a race — so this is a hard ✗
/// rather than a warning, with the conflicting command printed so the user can
/// see what they are up against.
fn permission_conflict_check(settings: &Settings) -> Vec<Check> {
    let foreign = settings.foreign_groups_for(hooks::PERMISSION_EVENT);
    if foreign.is_empty() {
        return vec![Check::ok("PermissionRequest is uncontested")];
    }

    let described: Vec<String> = foreign.iter().map(|g| describe_group(g)).collect();

    vec![Check::fail("PermissionRequest is uncontested")
        .detail(format!(
            "{} other hook(s) claim this event, so which one decides is a race:\n      {}",
            foreign.len(),
            described.join("\n      ")
        ))
        .fix("violeet install-hooks  (it offers to absorb or replace them)")]
}

fn describe_group(group: &serde_json::Value) -> String {
    let matcher = group
        .get("matcher")
        .and_then(|m| m.as_str())
        .unwrap_or("(no matcher)");
    let commands: Vec<String> = group
        .get("hooks")
        .and_then(|h| h.as_array())
        .map(|hooks| {
            hooks
                .iter()
                .map(|h| match h.get("type").and_then(|t| t.as_str()) {
                    Some("command") => h
                        .get("command")
                        .and_then(|c| c.as_str())
                        .unwrap_or("(no command)")
                        .to_string(),
                    Some("http") => h
                        .get("url")
                        .and_then(|u| u.as_str())
                        .unwrap_or("(no url)")
                        .to_string(),
                    Some(other) => format!("({other} hook)"),
                    None => "(untyped hook)".to_string(),
                })
                .collect()
        })
        .unwrap_or_default();

    format!("matcher {matcher}: {}", commands.join(" ; "))
}

/// Did something rewrite the settings file after we wrote it?
///
/// This exists because a settings file is not only ours. Dotfile managers
/// commonly *generate* `~/.claude/settings.json` from a base plus an overlay —
/// on this machine, `merge-settings.sh` does exactly that with
/// `jq -s '.[0] * .[1]' base overlay > settings.json`, which reconstructs the
/// file from scratch. Anything `violeet install-hooks` wrote is gone the next
/// time that runs.
///
/// The failure is invisible: the user runs their dotfile installer for an
/// unrelated reason, the hooks disappear, and the sidebar simply stops filling
/// in. Nothing errors. They would reasonably conclude violeet is broken.
///
/// So install records what it wrote, and this compares. It cannot name the
/// culprit — that would mean knowing about every dotfile manager — but "you
/// installed these and they are no longer there" is enough to point at one.
fn overwritten_check(settings: &Settings) -> Check {
    let Some(record) = crate::install_record::read() else {
        return Check::ok("installed configuration is still in place")
            .detail("nothing installed by violeet yet, so nothing to lose");
    };

    let mut missing: Vec<&str> = Vec::new();
    if record.hooks {
        let absent: Vec<&str> = hooks::all_events()
            .into_iter()
            .filter(|e| {
                !settings
                    .groups_for(e)
                    .iter()
                    .any(|g| hooks::group_is_ours(g))
            })
            .collect();
        if !absent.is_empty() {
            missing.push("hooks");
        }
    }
    if record.cursor_hooks {
        let path = cursor_hooks::hooks_path();
        let absent = path.as_ref().map(|p| cursor_hooks::load(p).ok()).flatten();
        let count = absent
            .as_ref()
            .map(cursor_hooks::count_ours)
            .unwrap_or(0);
        if count < cursor_hooks::EVENTS.len() {
            missing.push("Cursor hooks");
        }
    }
    if record.statusline && !crate::statusline::is_ours(settings) {
        missing.push("the status line wrapper");
    }

    if missing.is_empty() {
        return Check::ok("installed configuration is still in place");
    }

    Check::fail("installed configuration is still in place")
        .detail(format!(
            "violeet installed {} and {} no longer there. Something rewrote \
             ~/.claude/settings.json — a dotfile manager that generates it from \
             a template will do this silently, and the only symptom is a sidebar \
             that stops filling in.",
            missing.join(" and "),
            if missing.len() == 1 { "it is" } else { "they are" }
        ))
        .fix("re-run the install, and write it into your dotfile manager's source file rather than the generated one so it survives the next sync")
}

/// A session whose context window size we do not know.
///
/// The size is not in the transcript, and — measured — it is not derivable from
/// the model name either: the same `claude-opus-5` runs against 200k for one
/// account and 1M for another, depending on the plan. A lookup table produced
/// 24% where the agent's own status line said 5%, so the table was removed
/// rather than corrected.
///
/// The authoritative value arrives in Claude Code's status line payload
/// (`context_window.context_window_size`), which violeet does not yet read.
/// Until it does, the gauge renders indeterminate and this check says so — an
/// unknown that is visible beats a percentage that is wrong.
fn unknown_model_check(models: &[String]) -> Check {
    if models.is_empty() {
        return Check::ok("context window size is known for every live session");
    }
    Check::warn("context window size is known for every live session")
        .detail(format!(
            "no window size for: {}. The gauge shows indeterminate and the \
             compaction warning is off for those sessions — not because they \
             are safe, but because we cannot tell.",
            models.join(", ")
        ))
        .fix("expected until violeet reads the status line payload, which is where the real window size lives")
}

/// Project settings in an untrusted directory are ignored without a word.
fn trust_check(cwd: &Path) -> Check {
    match probe::project_is_trusted(cwd) {
        Some(true) => Check::ok("this directory is a trusted project").detail(cwd.display().to_string()),
        Some(false) => Check::warn("this directory is a trusted project")
            .detail(format!(
                "{} has not been trusted. Claude Code ignores a project's \
                 .claude/settings.json in an untrusted directory **silently** — no \
                 warning, no log. If you keep hooks in project settings they will \
                 not fire and nothing will say why.",
                cwd.display()
            ))
            // A warning rather than a failure: violeet installs into *user*
            // settings, which trust does not gate. It only bites if the user
            // also has project-level hooks, which is why the fix is phrased as
            // a condition rather than an order.
            .fix("open Claude Code here once and accept the trust prompt — only needed if you keep hooks in project settings"),
        None => Check::warn("this directory is a trusted project")
            .detail("could not read ~/.claude.json, so trust is unknown"),
    }
}

fn violeet_dir_check() -> Check {
    let Some(dir) = probe::violeet_dir() else {
        return Check::fail("~/.violeet permissions").detail("HOME is not set");
    };
    if !dir.exists() {
        return Check::warn("~/.violeet permissions")
            .detail(format!("{} does not exist yet", dir.display()))
            .fix("it is created when the daemon starts");
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        match std::fs::metadata(&dir) {
            Ok(meta) => {
                let mode = meta.permissions().mode() & 0o777;
                // Group or world access to the directory holding the control
                // socket means another account on this machine can drive the
                // daemon. Local-only is not the same as private.
                if mode & 0o077 != 0 {
                    return Check::warn("~/.violeet permissions")
                        .detail(format!("{} is mode {mode:o}; the socket is the daemon's control channel", dir.display()))
                        .fix(format!("chmod 700 {}", dir.display()));
                }
                Check::ok("~/.violeet permissions").detail(format!("{} is mode {mode:o}", dir.display()))
            }
            Err(e) => Check::warn("~/.violeet permissions").detail(e.to_string()),
        }
    }
    #[cfg(not(unix))]
    {
        Check::ok("~/.violeet permissions")
    }
}

/// Print the report. Returns true when nothing failed.
pub fn report(checks: &[Check], style: &Style) -> bool {
    let mut healthy = true;

    println!();
    for check in checks {
        let mark = match check.status {
            Status::Ok => style.green("✓"),
            Status::Warn => style.yellow("⚠"),
            Status::Fail => {
                healthy = false;
                style.red("✗")
            }
        };
        println!("  {mark} {}", check.title);
        if let Some(detail) = &check.detail {
            println!("      {}", style.dim(detail));
        }
        if let Some(fix) = &check.fix {
            println!("      {} {}", style.dim("fix:"), fix);
        }
    }
    println!();

    healthy
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The failure this check exists to make visible: a model nobody has told
    /// the lookup table about turns the compaction warning off, and nothing
    /// else would ever say so.
    #[test]
    fn an_unknown_model_is_a_warning_that_names_it() {
        let check = unknown_model_check(&["claude-something-6".to_string()]);
        assert!(matches!(check.status, Status::Warn));
        let detail = check.detail.unwrap();
        assert!(
            detail.contains("claude-something-6"),
            "naming the model is the whole point; without it the user cannot act"
        );
        assert!(check.fix.is_some());
    }

    #[test]
    fn every_model_known_is_a_plain_pass() {
        let check = unknown_model_check(&[]);
        assert!(matches!(check.status, Status::Ok));
        assert!(check.fix.is_none(), "nothing to fix, so nothing to type");
    }
}
