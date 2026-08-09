//! `violeet` CLI.
//!
//! Three jobs, deliberately no more:
//!
//! - `violeet doctor` — is the daemon up, is the socket healthy, are the hooks
//!   installed and pointing at the right port
//! - `violeet install-hooks` — write the violeet hook entries into the user's
//!   Claude Code settings
//! - `violeet uninstall-hooks` — take them back out, leaving other hooks intact
//! - `violeet sessions` — what the daemon thinks is running, for debugging
//!   without opening the app
//!
//! # No argument-parsing crate
//!
//! Three subcommands and two flags. `clap` is excellent and would be a dozen
//! transitive crates in a tool whose whole job is to edit one JSON file
//! carefully. The parser below is thirty lines and rejects what it does not
//! understand rather than guessing.

#![forbid(unsafe_code)]

mod cursor_hooks;
mod doctor;
mod hooks;
mod install_record;
mod probe;
mod sessions;
mod settings;
mod statusline;
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
    probe::violeet_dir().map(|d| d.join("absorbed-hooks.json"))
}

struct Options {
    /// Skip the confirmation prompt. Never skips the *conflict* prompt — see
    /// `resolve_permission_conflict`.
    yes: bool,
    /// Answer the conflict prompt without asking. `None` means ask.
    ///
    /// `--yes` deliberately does not cover this: the conflict question is about
    /// somebody else's hook, and "yes" is not an answer to it. But a caller with
    /// no terminal still needs a way to say what it wants, and the app has one —
    /// it puts a button on the status line and the user presses it. Without this
    /// flag that button could not work at all: the CLI reached the prompt,
    /// found no terminal, and aborted.
    on_conflict: Option<ConflictChoice>,
}

#[derive(Clone, Copy, PartialEq)]
enum ConflictChoice {
    Absorb,
    Replace,
    Abort,
    Coexist,
}

impl ConflictChoice {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "absorb" => Some(Self::Absorb),
            "replace" => Some(Self::Replace),
            "abort" => Some(Self::Abort),
            "coexist" => Some(Self::Coexist),
            _ => None,
        }
    }

    fn index(self) -> usize {
        match self {
            Self::Absorb => 0,
            Self::Replace => 1,
            Self::Abort => 2,
            Self::Coexist => 3,
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let style = Style::detect();

    let mut command = None;
    let mut options = Options { yes: false, on_conflict: None };

    for arg in &args {
        match arg.as_str() {
            "-y" | "--yes" => options.yes = true,
            other if other.starts_with("--on-conflict=") => {
                let value = &other["--on-conflict=".len()..];
                match ConflictChoice::parse(value) {
                    Some(choice) => options.on_conflict = Some(choice),
                    None => {
                        eprintln!(
                            "violeet: --on-conflict must be absorb, replace, abort or coexist (got {value})"
                        );
                        return ExitCode::FAILURE;
                    }
                }
            }
            "-h" | "--help" | "help" => {
                print_help();
                return ExitCode::SUCCESS;
            }
            "--version" => {
                println!("violeet {}", env!("CARGO_PKG_VERSION"));
                return ExitCode::SUCCESS;
            }
            other if other.starts_with('-') => {
                eprintln!("violeet: unknown flag {other}");
                print_help();
                return ExitCode::FAILURE;
            }
            other if command.is_none() => command = Some(other.to_string()),
            other => {
                eprintln!("violeet: unexpected argument {other}");
                return ExitCode::FAILURE;
            }
        }
    }

    match command.as_deref() {
        Some("doctor") => run_doctor(&style),
        Some("sessions") => match sessions::run(&style) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("{} {e}", style.red("×"));
                ExitCode::FAILURE
            }
        },
        Some("install-hooks") => run_install(&options, &style),
        Some("uninstall-hooks") => run_uninstall(&options, &style),
        Some("install-cursor-hooks") => run_install_cursor(&options, &style),
        Some("uninstall-cursor-hooks") => run_uninstall_cursor(&options, &style),
        Some("install-statusline") => run_install_statusline(&options, &style),
        Some("uninstall-statusline") => run_uninstall_statusline(&options, &style),
        Some(other) => {
            eprintln!("violeet: unknown command {other}");
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
        "violeet — native macOS terminal for AI coding agents

USAGE:
    violeet <COMMAND> [--yes]

COMMANDS:
    doctor                Check the daemon, the hooks, and this directory
    install-hooks         Add violeet's hooks to ~/.claude/settings.json
    uninstall-hooks       Remove them again, leaving other hooks intact
    install-cursor-hooks  Add violeet's adapter to ~/.cursor/hooks.json
    uninstall-cursor-hooks Remove the adapter from ~/.cursor/hooks.json
    install-statusline    Wrap your status line so violeet can read the context
                          window size and your usage limits. Your status line
                          keeps rendering exactly as it does now.
    uninstall-statusline  Put your original status line back

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
        // Non-zero so `violeet doctor && …` means something in a script.
        ExitCode::FAILURE
    }
}

// ---------------------------------------------------------------------------
// install
// ---------------------------------------------------------------------------

fn run_install(options: &Options, style: &Style) -> ExitCode {
    let Some(path) = settings::default_path() else {
        eprintln!("violeet: HOME is not set, so there is no settings file to edit");
        return ExitCode::FAILURE;
    };

    let mut settings = match Settings::load(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("violeet: {e}");
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
                "violeet: ~/.violeet/daemon.json is missing, so I cannot tell which port \
                 the daemon is on.\n\n\
                 The port is configurable and {} is only the default; writing hooks \
                 against a guess would point them at nothing, and that failure is \
                 silent. Start the daemon and run this again.",
                violeet_proto::DEFAULT_HOOK_PORT
            );
            return ExitCode::FAILURE;
        }
    };

    // Settle any competing PermissionRequest hook before writing anything.
    let absorbed = match resolve_permission_conflict(&mut settings, style, options.on_conflict) {
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
                eprintln!("violeet: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    match settings.back_up() {
        Ok(Some(backup)) => println!("{} backup: {}", style.dim("·"), backup.display()),
        Ok(None) => {}
        Err(e) => {
            eprintln!("violeet: could not write a backup, so I will not write the file: {e}");
            return ExitCode::FAILURE;
        }
    }

    if let Err(e) = settings.write() {
        eprintln!("violeet: {e}");
        return ExitCode::FAILURE;
    }

    if let Some(group) = absorbed {
        if let Err(e) = park_absorbed(&group) {
            // The settings are already written and correct; failing to record
            // the absorbed hook only costs the automatic restore.
            eprintln!(
                "violeet: hooks installed, but the absorbed hook could not be recorded ({e}).\n\
                 Keep this so you can restore it by hand:\n{}",
                serde_json::to_string_pretty(&group).unwrap_or_default()
            );
        }
    }

    install_record::set(Some(true), None);
    println!(
        "{} installed {} hook events against port {port}",
        style.green("✓"),
        hooks::all_events().len()
    );
    println!("  {} violeet doctor", style.dim("check with:"));
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
/// decide wins and the slower one is not awaited. violeet holds its response open
/// for minutes waiting for a human, so it is *structurally* the slower one. A
/// competing hook does not degrade HITL — it silently wins the race.
fn resolve_permission_conflict(
    settings: &mut Settings,
    style: &Style,
    preset: Option<ConflictChoice>,
) -> Conflict {
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
             not even waited for. violeet holds its answer open for minutes waiting for you,\n  \
             so it is always the slower one. It has to be the only decider."
        )
    );

    // A preset answers without asking. Printed, not silent: the caller chose
    // this on the user's behalf and the user is entitled to see what happened
    // to a hook they installed.
    let choice = if let Some(preset) = preset {
        println!(
            "\n{}",
            style.dim("Answering with --on-conflict, so nothing is being asked.")
        );
        Ok(Some(preset.index()))
    } else {
        ui::choose(
        "How should violeet handle this?",
        &[
            (
                "absorb",
                "move the hook aside so violeet decides alone; uninstall-hooks puts it back",
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
        )
    };

    match choice {
        Ok(Some(0)) => {
            // Only one group can be parked for automatic restore, because the
            // parked file holds one. More than that and we say so rather than
            // silently keeping the first and dropping the rest.
            if foreign.len() > 1 {
                println!(
                    "\n{}",
                    style.yellow(
                        "More than one competing hook. violeet can only restore one\n  \
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
                     answers first wins, and violeet is structurally the slower one.\n  \
                     `violeet doctor` reports this as ✗ until it is resolved."
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
        eprintln!("violeet: HOME is not set, so there is no settings file to edit");
        return ExitCode::FAILURE;
    };

    let mut settings = match Settings::load(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("violeet: {e}");
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
            "{} no violeet hooks are installed. Nothing to do.",
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
                eprintln!("violeet: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    match settings.back_up() {
        Ok(Some(backup)) => println!("{} backup: {}", style.dim("·"), backup.display()),
        Ok(None) => {}
        Err(e) => {
            eprintln!("violeet: could not write a backup, so I will not write the file: {e}");
            return ExitCode::FAILURE;
        }
    }

    if let Err(e) = settings.write() {
        eprintln!("violeet: {e}");
        return ExitCode::FAILURE;
    }

    install_record::set(Some(false), None);
    println!("{} removed {removed} violeet hook entr(ies)", style.green("✓"));
    ExitCode::SUCCESS
}

// ---------------------------------------------------------------------------
// Cursor hooks
// ---------------------------------------------------------------------------

fn run_install_cursor(options: &Options, style: &Style) -> ExitCode {
    let Some(hooks_path) = cursor_hooks::hooks_path() else {
        eprintln!("violeet: HOME is not set");
        return ExitCode::FAILURE;
    };
    let Some(script_path) = cursor_hooks::script_path() else {
        eprintln!("violeet: HOME is not set");
        return ExitCode::FAILURE;
    };

    if probe::read_discovery().is_none() {
        eprintln!(
            "violeet: ~/.violeet/daemon.json is missing, so I cannot tell which port \
             the daemon is on.\n\n\
             Start the daemon and run this again."
        );
        return ExitCode::FAILURE;
    }

    let mut doc = match cursor_hooks::load(&hooks_path) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("violeet: {e}");
            return ExitCode::FAILURE;
        }
    };

    let before = doc.clone();
    let script = script_path.to_string_lossy();
    cursor_hooks::upsert_ours(&mut doc, &script);

    if doc == before && script_path.exists() {
        if let Ok(current) = std::fs::read_to_string(&script_path) {
            if current == cursor_hooks::adapter_script_source() {
                println!(
                    "{} Cursor hooks are already installed. Nothing to do.",
                    style.green("✓")
                );
                return ExitCode::SUCCESS;
            }
        }
    }

    println!("\n{}", style.bold(&hooks_path.display().to_string()));
    print!(
        "{}",
        ui::diff(
            &serde_json::to_string_pretty(&before).unwrap_or_default(),
            &serde_json::to_string_pretty(&doc).unwrap_or_default(),
            style,
        )
    );
    println!("\n{} {}", style.dim("script:"), script_path.display());

    if !options.yes {
        match ui::confirm("\nWrite these changes?") {
            Ok(true) => {}
            Ok(false) => {
                println!("Aborted. Nothing was written.");
                return ExitCode::SUCCESS;
            }
            Err(e) => {
                eprintln!("violeet: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    if let Err(e) = cursor_hooks::install_script() {
        eprintln!("violeet: {e}");
        return ExitCode::FAILURE;
    }

    if let Err(e) = cursor_hooks::write(&hooks_path, &doc) {
        eprintln!("violeet: {e}");
        return ExitCode::FAILURE;
    }

    install_record::set_cursor(Some(true));
    println!(
        "{} installed {} Cursor hook events",
        style.green("✓"),
        cursor_hooks::EVENTS.len()
    );
    println!("  {} violeet doctor", style.dim("check with:"));
    ExitCode::SUCCESS
}

fn run_uninstall_cursor(options: &Options, style: &Style) -> ExitCode {
    let Some(hooks_path) = cursor_hooks::hooks_path() else {
        eprintln!("violeet: HOME is not set");
        return ExitCode::FAILURE;
    };

    if !hooks_path.exists() {
        println!(
            "{} no Cursor hooks file exists. Nothing to do.",
            style.green("✓")
        );
        return ExitCode::SUCCESS;
    }

    let mut doc = match cursor_hooks::load(&hooks_path) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("violeet: {e}");
            return ExitCode::FAILURE;
        }
    };

    let before = doc.clone();
    let removed = cursor_hooks::remove_ours(&mut doc);

    if doc == before {
        println!(
            "{} no violeet Cursor hooks are installed. Nothing to do.",
            style.green("✓")
        );
        return ExitCode::SUCCESS;
    }

    println!("\n{}", style.bold(&hooks_path.display().to_string()));
    print!(
        "{}",
        ui::diff(
            &serde_json::to_string_pretty(&before).unwrap_or_default(),
            &serde_json::to_string_pretty(&doc).unwrap_or_default(),
            style,
        )
    );

    if !options.yes {
        match ui::confirm("\nWrite these changes?") {
            Ok(true) => {}
            Ok(false) => {
                println!("Aborted. Nothing was written.");
                return ExitCode::SUCCESS;
            }
            Err(e) => {
                eprintln!("violeet: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    if let Err(e) = cursor_hooks::write(&hooks_path, &doc) {
        eprintln!("violeet: {e}");
        return ExitCode::FAILURE;
    }

    let _ = std::fs::remove_file(cursor_hooks::script_path().unwrap_or_default());

    install_record::set_cursor(Some(false));
    println!("{} removed {removed} violeet Cursor hook entr(ies)", style.green("✓"));
    ExitCode::SUCCESS
}

// ---------------------------------------------------------------------------
// status line
// ---------------------------------------------------------------------------

/// Install the wrapper around the user's existing status line.
///
/// Nothing about their prompt changes on screen: the wrapper forwards a copy of
/// the payload to the daemon and then runs the original, printing its output
/// verbatim. See `statusline.rs` for why this is a wrapper rather than a
/// replacement.
fn run_install_statusline(options: &Options, style: &Style) -> ExitCode {
    let Some(path) = settings::default_path() else {
        eprintln!("violeet: HOME is not set, so there is no settings file to edit");
        return ExitCode::FAILURE;
    };
    let (Some(wrapper), Some(parked)) = (statusline::wrapper_path(), statusline::parked_path())
    else {
        eprintln!("violeet: HOME is not set");
        return ExitCode::FAILURE;
    };

    let mut settings = match Settings::load(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("violeet: {e}");
            return ExitCode::FAILURE;
        }
    };

    let port = match probe::read_discovery() {
        Some(info) => info.hook_port,
        None => {
            eprintln!(
                "violeet: ~/.violeet/daemon.json is missing, so I cannot tell which port \
                 the daemon is on. Start the daemon and run this again."
            );
            return ExitCode::FAILURE;
        }
    };

    // What to wrap. If we are already installed, the thing to wrap is whatever
    // was parked the first time — not our own wrapper, which would nest.
    let existing = statusline::current(&settings);
    let already_ours = statusline::is_ours(&settings);

    let original: Option<Value> = if already_ours {
        std::fs::read_to_string(&parked)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
    } else {
        existing.clone()
    };
    let original_command = original.as_ref().and_then(statusline::command_of);

    match &original_command {
        Some(command) => println!(
            "\n{} {}",
            style.dim("wrapping your status line:"),
            style.bold(command)
        ),
        None => println!(
            "\n{}",
            style.dim("no status line configured; the wrapper will print nothing")
        ),
    }
    println!(
        "{}",
        style.dim(
            "  It keeps rendering exactly as it does now — the wrapper forwards a copy of\n  \
             the payload to the daemon and then runs your command unchanged."
        )
    );

    let before = settings.original.clone().unwrap_or_default();
    settings.value.as_object_mut().expect("checked on load").insert(
        "statusLine".into(),
        statusline::wrapper_entry(&wrapper.to_string_lossy()),
    );

    let script = statusline::wrapper_script(port, original_command.as_deref());
    let script_exists_and_matches = std::fs::read_to_string(&wrapper)
        .map(|current| current == script)
        .unwrap_or(false);

    if settings.is_unchanged() && script_exists_and_matches {
        println!("{} the status line wrapper is already installed. Nothing to do.", style.green("✓"));
        return ExitCode::SUCCESS;
    }

    println!("\n{}", style.bold(&path.display().to_string()));
    print!("{}", ui::diff(&before, &settings.rendered(), style));
    println!("\n{} {}", style.dim("script:"), wrapper.display());

    if !options.yes {
        match ui::confirm("\nWrite these changes?") {
            Ok(true) => {}
            Ok(false) => {
                println!("Aborted. Nothing was written.");
                return ExitCode::SUCCESS;
            }
            Err(e) => {
                eprintln!("violeet: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    // Park the original before touching anything, so a failure halfway leaves
    // the user able to restore by hand.
    if let Some(original) = &original {
        if let Err(e) = write_parked(&parked, original) {
            eprintln!("violeet: could not record your existing status line ({e}); not proceeding");
            return ExitCode::FAILURE;
        }
    } else {
        let _ = std::fs::remove_file(&parked);
    }

    if let Err(e) = write_wrapper(&wrapper, &script) {
        eprintln!("violeet: could not write {}: {e}", wrapper.display());
        return ExitCode::FAILURE;
    }

    match settings.back_up() {
        Ok(Some(backup)) => println!("{} backup: {}", style.dim("·"), backup.display()),
        Ok(None) => {}
        Err(e) => {
            eprintln!("violeet: could not write a backup, so I will not write the file: {e}");
            return ExitCode::FAILURE;
        }
    }
    if let Err(e) = settings.write() {
        eprintln!("violeet: {e}");
        return ExitCode::FAILURE;
    }

    install_record::set(None, Some(true));
    println!("{} status line wrapped against port {port}", style.green("✓"));
    println!(
        "  {}",
        style.dim("restart your agent for it to pick up the new command")
    );
    ExitCode::SUCCESS
}

fn write_parked(path: &std::path::Path, original: &Value) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, serde_json::to_string_pretty(original)? + "\n")
}

fn write_wrapper(path: &std::path::Path, script: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, script)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // Executable by the owner only, like everything else in ~/.violeet.
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Put the user's original status line back.
fn run_uninstall_statusline(options: &Options, style: &Style) -> ExitCode {
    let Some(path) = settings::default_path() else {
        eprintln!("violeet: HOME is not set");
        return ExitCode::FAILURE;
    };
    let (Some(wrapper), Some(parked)) = (statusline::wrapper_path(), statusline::parked_path())
    else {
        eprintln!("violeet: HOME is not set");
        return ExitCode::FAILURE;
    };

    let mut settings = match Settings::load(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("violeet: {e}");
            return ExitCode::FAILURE;
        }
    };

    if !statusline::is_ours(&settings) {
        println!(
            "{} the configured status line is not violeet's. Leaving it alone.",
            style.green("✓")
        );
        return ExitCode::SUCCESS;
    }

    let before = settings.original.clone().unwrap_or_default();
    let original: Option<Value> = std::fs::read_to_string(&parked)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok());

    {
        let root = settings.value.as_object_mut().expect("checked on load");
        match &original {
            Some(entry) => {
                root.insert("statusLine".into(), entry.clone());
            }
            // Nothing was parked, so there was nothing before us. Remove the
            // key rather than leaving an empty one behind.
            None => {
                root.remove("statusLine");
            }
        }
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
                eprintln!("violeet: {e}");
                return ExitCode::FAILURE;
            }
        }
    }

    match settings.back_up() {
        Ok(Some(backup)) => println!("{} backup: {}", style.dim("·"), backup.display()),
        Ok(None) => {}
        Err(e) => {
            eprintln!("violeet: could not write a backup: {e}");
            return ExitCode::FAILURE;
        }
    }
    if let Err(e) = settings.write() {
        eprintln!("violeet: {e}");
        return ExitCode::FAILURE;
    }

    let _ = std::fs::remove_file(&wrapper);
    let _ = std::fs::remove_file(&parked);

    install_record::set(None, Some(false));
    println!("{} your status line is back as it was", style.green("✓"));
    ExitCode::SUCCESS
}
