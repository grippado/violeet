//! `aiterm` CLI.
//!
//! Three jobs, deliberately no more:
//!
//! - `aiterm doctor` — is the daemon up, is the socket healthy, are the hooks
//!   installed and pointing at the right port
//! - `aiterm install-hooks` — write the aiterm hook entries into the user's
//!   Claude Code settings
//! - `aiterm uninstall-hooks` — take them back out, leaving other hooks intact
//!
//! # No argument-parsing crate
//!
//! Three subcommands and two flags. `clap` is excellent and would be a dozen
//! transitive crates in a tool whose whole job is to edit one JSON file
//! carefully. The parser below is thirty lines and rejects what it does not
//! understand rather than guessing.

#![forbid(unsafe_code)]

mod doctor;
mod hooks;
mod probe;
mod settings;
mod ui;

use std::path::PathBuf;
use std::process::ExitCode;

use serde_json::Value;

use settings::Settings;
use ui::Style;

/// Where an absorbed foreign hook is parked so `uninstall-hooks` can put it
/// back. Beside the socket rather than inside the user's settings, because the
/// settings file is theirs and this is our bookkeeping.
fn absorbed_path() -> Option<PathBuf> {
    probe::aiterm_dir().map(|d| d.join("absorbed-hooks.json"))
}

struct Options {
    /// Skip the confirmation prompt. Never skips the *conflict* prompt — see
    /// `resolve_permission_conflict`.
    yes: bool,
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let style = Style::detect();

    let mut command = None;
    let mut options = Options { yes: false };

    for arg in &args {
        match arg.as_str() {
            "-y" | "--yes" => options.yes = true,
            "-h" | "--help" | "help" => {
                print_help();
                return ExitCode::SUCCESS;
            }
            "--version" => {
                println!("aiterm {}", env!("CARGO_PKG_VERSION"));
                return ExitCode::SUCCESS;
            }
            other if other.starts_with('-') => {
                eprintln!("aiterm: unknown flag {other}");
                print_help();
                return ExitCode::FAILURE;
            }
            other if command.is_none() => command = Some(other.to_string()),
            other => {
                eprintln!("aiterm: unexpected argument {other}");
                return ExitCode::FAILURE;
            }
        }
    }

    match command.as_deref() {
        Some("doctor") => run_doctor(&style),
        Some("install-hooks") => run_install(&options, &style),
        Some("uninstall-hooks") => run_uninstall(&options, &style),
        Some(other) => {
            eprintln!("aiterm: unknown command {other}");
            print_help();
            ExitCode::FAILURE
        }
        None => {
            print_help();
            ExitCode::FAILURE
        }
    }
}

fn print_help() {
    println!(
        "aiterm — native macOS terminal for AI coding agents

USAGE:
    aiterm <COMMAND> [--yes]

COMMANDS:
    doctor             Check the daemon, the hooks, and this directory
    install-hooks      Add aiterm's hooks to ~/.claude/settings.json
    uninstall-hooks    Remove them again, leaving other hooks intact

OPTIONS:
    -y, --yes          Skip the confirmation prompt
    -h, --help         Show this
        --version      Show the version"
    );
}

// ---------------------------------------------------------------------------
// doctor
// ---------------------------------------------------------------------------

fn run_doctor(style: &Style) -> ExitCode {
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let checks = doctor::run(&cwd);

    if doctor::report(&checks, style) {
        ExitCode::SUCCESS
    } else {
        // Non-zero so `aiterm doctor && …` means something in a script.
        ExitCode::FAILURE
    }
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

fn run_install(options: &Options, style: &Style) -> ExitCode {
    let Some(path) = settings::default_path() else {
        eprintln!("aiterm: HOME is not set, so there is no settings file to edit");
        return ExitCode::FAILURE;
    };

    let mut settings = match Settings::load(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("aiterm: {e}");
            return ExitCode::FAILURE;
        }
    };

    // The port has to come from the running daemon. Guessing the default and
    // being wrong writes hooks that fire into nothing — which looks exactly
    // like hooks that were never installed.
    let port = match probe::read_discovery() {
        Some(info) => info.hook_port,
        None => {
            eprintln!(
                "aiterm: ~/.aiterm/daemon.json is missing, so I cannot tell which port \
                 the daemon is on.\n\n\
                 The port is configurable and {} is only the default; writing hooks \
                 against a guess would point them at nothing, and that failure is \
                 silent. Start the daemon and run this again.",
                aiterm_proto::DEFAULT_HOOK_PORT
            );
            return ExitCode::FAILURE;
        }
    };

    // Settle any competing PermissionRequest hook before writing anything.
    let absorbed = match resolve_permission_conflict(&mut settings, style) {
        Conflict::Proceed(absorbed) => absorbed,
        Conflict::Abort => {
            println!("Aborted. Nothing was written.");
            return ExitCode::SUCCESS;
        }
    };

    let before = settings.original.clone().unwrap_or_default();
    for event in hooks::all_events() {
        settings.upsert_ours(event, port);
    }

    if settings.is_unchanged() {
        println!(
            "{} hooks are already installed and pointing at port {port}. Nothing to do.",
            style.green("✓")
        );
        return ExitCode::SUCCESS;
    }

    println!("\n{}", style.bold(&path.display().to_string()));
    print!("{}", ui::diff(&before, &settings.rendered(), style));

    if !options.yes {
        match ui::confirm("\nWrite these changes?") {
            Ok(true) => {}
            Ok(false) => {
                println!("Aborted. Nothing was written.");
                return ExitCode::SUCCESS;
            }
            Err(e) => {
                eprintln!("aiterm: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    match settings.back_up() {
        Ok(Some(backup)) => println!("{} backup: {}", style.dim("·"), backup.display()),
        Ok(None) => {}
        Err(e) => {
            eprintln!("aiterm: could not write a backup, so I will not write the file: {e}");
            return ExitCode::FAILURE;
        }
    }

    if let Err(e) = settings.write() {
        eprintln!("aiterm: {e}");
        return ExitCode::FAILURE;
    }

    if let Some(group) = absorbed {
        if let Err(e) = park_absorbed(&group) {
            // The settings are already written and correct; failing to record
            // the absorbed hook only costs the automatic restore.
            eprintln!(
                "aiterm: hooks installed, but the absorbed hook could not be recorded ({e}).\n\
                 Keep this so you can restore it by hand:\n{}",
                serde_json::to_string_pretty(&group).unwrap_or_default()
            );
        }
    }

    println!(
        "{} installed {} hook events against port {port}",
        style.green("✓"),
        hooks::all_events().len()
    );
    println!("  {} aiterm doctor", style.dim("check with:"));
    ExitCode::SUCCESS
}

enum Conflict {
    /// Carry on. Carries a foreign group that was removed and should be parked.
    Proceed(Option<Value>),
    Abort,
}

/// Detect and resolve competing `PermissionRequest` hooks.
///
/// The only interactive decision in the tool, and `--yes` does **not** skip it.
/// `--yes` means "I have seen the diff and accept it"; it cannot mean "delete
/// another tool's hook on my behalf", because at the point the flag was typed
/// the user had not been told there was one. A non-interactive run with a
/// conflict aborts.
///
/// Why it matters (ADR-004, measured): with two hooks on this event the first to
/// decide wins and the slower one is not awaited. aiterm holds its response open
/// for minutes waiting for a human, so it is *structurally* the slower one. A
/// competing hook does not degrade HITL — it silently wins the race.
fn resolve_permission_conflict(settings: &mut Settings, style: &Style) -> Conflict {
    let foreign: Vec<Value> = settings
        .foreign_groups_for(hooks::PERMISSION_EVENT)
        .into_iter()
        .cloned()
        .collect();

    if foreign.is_empty() {
        return Conflict::Proceed(None);
    }

    println!(
        "\n{}",
        style.yellow(&format!(
            "{} other hook(s) already claim PermissionRequest:",
            foreign.len()
        ))
    );
    for group in &foreign {
        println!(
            "\n{}",
            indent(&serde_json::to_string_pretty(group).unwrap_or_default(), 6)
        );
    }

    println!(
        "\n{}",
        style.dim(
            "With two hooks on this event the first to decide wins, and the slower one is\n  \
             not even waited for. aiterm holds its answer open for minutes waiting for you,\n  \
             so it is always the slower one. It has to be the only decider."
        )
    );

    let choice = ui::choose(
        "How should aiterm handle this?",
        &[
            (
                "absorb",
                "move the hook aside so aiterm decides alone; uninstall-hooks puts it back",
            ),
            (
                "replace",
                "remove it and print the exact command to restore it yourself",
            ),
            ("abort", "change nothing and exit"),
            (
                "coexist",
                "leave it in place — HITL becomes non-deterministic and doctor reports ✗",
            ),
        ],
    );

    match choice {
        Ok(Some(0)) => {
            // Only one group can be parked for automatic restore, because the
            // parked file holds one. More than that and we say so rather than
            // silently keeping the first and dropping the rest.
            if foreign.len() > 1 {
                println!(
                    "\n{}",
                    style.yellow(
                        "More than one competing hook. aiterm can only restore one\n  \
                         automatically, so the rest are being treated as `replace` — their\n  \
                         restore commands are printed below."
                    )
                );
                for group in &foreign[1..] {
                    print_restore_recipe(group, style);
                }
            }
            for group in &foreign {
                settings.remove_group(hooks::PERMISSION_EVENT, group);
            }
            println!(
                "\n{}",
                style.yellow(
                    "Note: the daemon does not yet re-invoke an absorbed hook as an observer.\n  \
                     It is stored and restorable, but it will not run while absorbed. That\n  \
                     gap is recorded in docs/tracks/C.md."
                )
            );
            Conflict::Proceed(Some(foreign[0].clone()))
        }
        Ok(Some(1)) => {
            for group in &foreign {
                print_restore_recipe(group, style);
                settings.remove_group(hooks::PERMISSION_EVENT, group);
            }
            Conflict::Proceed(None)
        }
        Ok(Some(3)) => {
            println!(
                "\n{}",
                style.yellow(
                    "Leaving both in place. HITL is now non-deterministic: whichever hook\n  \
                     answers first wins, and aiterm is structurally the slower one.\n  \
                     `aiterm doctor` reports this as ✗ until it is resolved."
                )
            );
            Conflict::Proceed(None)
        }
        // Abort, EOF, or a read error all mean the same thing: do nothing.
        _ => Conflict::Abort,
    }
}

/// Print a copy-pasteable way to put a removed hook back.
///
/// Printed *before* the removal happens, and printed whether or not the user
/// later confirms, because the whole point is that they keep it.
fn print_restore_recipe(group: &Value, style: &Style) {
    let json = serde_json::to_string(group).unwrap_or_default();
    println!("\n{}", style.bold("To restore this hook by hand:"));
    println!(
        "  python3 - <<'EOF'
import json, pathlib
p = pathlib.Path.home() / '.claude/settings.json'
d = json.loads(p.read_text())
d.setdefault('hooks', {{}}).setdefault('PermissionRequest', []).insert(0, {json})
p.write_text(json.dumps(d, indent=4) + '\\n')
EOF"
    );
}

fn park_absorbed(group: &Value) -> std::io::Result<()> {
    let Some(path) = absorbed_path() else {
        return Err(std::io::Error::other("HOME is not set"));
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let body = serde_json::json!({
        "event": hooks::PERMISSION_EVENT,
        "group": group,
    });
    std::fs::write(&path, serde_json::to_string_pretty(&body)? + "\n")
}

/// Read and consume the parked hook, if there is one.
fn take_absorbed() -> Option<(String, Value)> {
    let path = absorbed_path()?;
    let text = std::fs::read_to_string(&path).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let event = v.get("event")?.as_str()?.to_string();
    let group = v.get("group")?.clone();
    let _ = std::fs::remove_file(&path);
    Some((event, group))
}

fn indent(text: &str, spaces: usize) -> String {
    let pad = " ".repeat(spaces);
    text.lines()
        .map(|l| format!("{pad}{l}"))
        .collect::<Vec<_>>()
        .join("\n")
}

// ---------------------------------------------------------------------------
// uninstall
// ---------------------------------------------------------------------------

fn run_uninstall(options: &Options, style: &Style) -> ExitCode {
    let Some(path) = settings::default_path() else {
        eprintln!("aiterm: HOME is not set, so there is no settings file to edit");
        return ExitCode::FAILURE;
    };

    let mut settings = match Settings::load(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("aiterm: {e}");
            return ExitCode::FAILURE;
        }
    };

    let before = settings.original.clone().unwrap_or_default();

    let mut removed = 0;
    for event in hooks::all_events() {
        removed += settings.remove_ours(event);
    }

    // Put back whatever install absorbed, before rendering the diff, so the
    // user sees the restore as part of the same change.
    let restored = take_absorbed();
    if let Some((event, group)) = &restored {
        settings.restore_group(event, group.clone());
    }

    if settings.is_unchanged() {
        println!(
            "{} no aiterm hooks are installed. Nothing to do.",
            style.green("✓")
        );
        // Nothing was written, so the parked record must survive: consuming it
        // above was for the preview, not for the removal.
        if let Some((_, group)) = &restored {
            let _ = park_absorbed(group);
        }
        return ExitCode::SUCCESS;
    }

    println!("\n{}", style.bold(&path.display().to_string()));
    print!("{}", ui::diff(&before, &settings.rendered(), style));

    if restored.is_some() {
        println!(
            "\n{} restoring the hook that was absorbed at install time",
            style.dim("·")
        );
    }

    if !options.yes {
        match ui::confirm("\nWrite these changes?") {
            Ok(true) => {}
            Ok(false) => {
                // The parked record was consumed to build the preview; put it
                // back, or aborting here would lose the ability to restore it.
                if let Some((_, group)) = &restored {
                    let _ = park_absorbed(group);
                }
                println!("Aborted. Nothing was written.");
                return ExitCode::SUCCESS;
            }
            Err(e) => {
                eprintln!("aiterm: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    match settings.back_up() {
        Ok(Some(backup)) => println!("{} backup: {}", style.dim("·"), backup.display()),
        Ok(None) => {}
        Err(e) => {
            eprintln!("aiterm: could not write a backup, so I will not write the file: {e}");
            return ExitCode::FAILURE;
        }
    }

    if let Err(e) = settings.write() {
        eprintln!("aiterm: {e}");
        return ExitCode::FAILURE;
    }

    println!("{} removed {removed} aiterm hook entr(ies)", style.green("✓"));
    ExitCode::SUCCESS
}
