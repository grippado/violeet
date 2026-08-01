//! Where a session is actually running, when it is not in an aiterm tab.
//!
//! # The problem
//!
//! aiterm sees every Claude Code session on the machine, not only the ones it
//! started: the hooks are installed user-wide, so an agent launched from iTerm2
//! posts to the same daemon. Those sessions are real and worth showing — they
//! are exactly the ones that block on a permission request while the user is
//! looking at a different window — but the card for one used to say nothing
//! about where it lived. "Running outside aiterm" is true and useless.
//!
//! # Why the peer port and not the working directory
//!
//! The obvious correlation is `cwd`: find the agent process whose working
//! directory matches the session's. Measured on this machine, that is ambiguous
//! — two agents in the same repository are indistinguishable, and that is the
//! normal case, not the corner case. `lsof` on the transcript file does not
//! help either: Claude Code closes it between writes, so nothing holds it open
//! to be found.
//!
//! What *is* exact is the connection the hook itself arrives on. The kernel
//! knows which process owns the client end of that TCP socket, and that process
//! is either the agent or a child of it. Walking up from there reaches the
//! terminal application. No guessing, no ambiguity: the identification is
//! derived from the very request being handled.
//!
//! # Cost
//!
//! One `lsof` and one `ps`, measured at ~45 ms together, and only on the first
//! hook of a session that has no origin yet. It happens on a `spawn_blocking`
//! while the connection is still open, because the answer stops existing the
//! moment the socket closes.
//!
//! # What this does not do
//!
//! It does not focus the terminal. That is a second step, needs macOS
//! automation permission, and is per-terminal. This module only answers "where
//! is it", and `tty` is captured because that is what a later focus step would
//! need to address one iTerm2 session out of many.

use std::collections::HashMap;
use std::process::Command;

/// Where a session lives, as far as the process tree can tell.
///
/// Either field may be `None` on its own: a process with no controlling
/// terminal still has an application, and a chain we cannot walk to the top
/// still has a tty. Nothing here is ever invented — a field we could not
/// determine stays `None` and the card says nothing rather than something
/// plausible.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Origin {
    /// The topmost ancestor below `launchd`, by its `comm` name: `iTerm2`,
    /// `Terminal`, `aiterm`, `tmux: server`. Reported verbatim rather than
    /// mapped to a prettier label, so a terminal nobody anticipated still shows
    /// its real name instead of "unknown".
    pub app: Option<String>,
    /// The controlling terminal of the nearest ancestor that has one, without
    /// the `/dev/` prefix: `ttys008`.
    pub tty: Option<String>,
}

impl Origin {
    pub fn is_empty(&self) -> bool {
        self.app.is_none() && self.tty.is_none()
    }
}

/// One row of `ps`.
struct Proc {
    ppid: i32,
    tty: Option<String>,
    comm: String,
}

/// Resolve the origin of whoever holds the client end of a connection to us.
///
/// `peer_port` is the remote port of the accepted socket. Returns `None` when
/// the chain cannot be walked at all — typically because the client already
/// disconnected, which is why the caller must do this before answering.
pub fn resolve(peer_port: u16) -> Option<Origin> {
    let pid = pid_owning(peer_port)?;
    let table = process_table()?;
    Some(walk(pid, &table))
}

/// The pid that owns the *client* end of `127.0.0.1:<peer_port>`.
///
/// Both ends of a loopback connection are listed, and one of them is this
/// daemon. They are told apart by direction: the client's name reads
/// `127.0.0.1:<peer_port>-><ours>`, the daemon's the other way round.
fn pid_owning(peer_port: u16) -> Option<i32> {
    let out = Command::new("lsof")
        .args([
            "-nP",
            &format!("-iTCP:{peer_port}"),
            "-sTCP:ESTABLISHED",
            // Field output: one `p<pid>` line then `n<name>` lines for its fds.
            // Stable across lsof versions in a way the columns are not.
            "-Fpn",
        ])
        .output()
        .ok()?;

    let text = String::from_utf8_lossy(&out.stdout);
    let mut current: Option<i32> = None;
    let local = format!("127.0.0.1:{peer_port}->");
    for line in text.lines() {
        match line.split_at_checked(1) {
            Some(("p", rest)) => current = rest.parse().ok(),
            Some(("n", rest)) if rest.starts_with(&local) => return current,
            _ => {}
        }
    }
    None
}

/// Every process, as `pid -> (ppid, tty, comm)`.
///
/// One `ps` for the whole tree rather than one per ancestor: the chain is
/// typically five deep, and five process spawns on a hook path is a cost with
/// no upside.
fn process_table() -> Option<HashMap<i32, Proc>> {
    let out = Command::new("ps")
        .args(["-axo", "pid=,ppid=,tty=,comm="])
        .output()
        .ok()?;

    let text = String::from_utf8_lossy(&out.stdout);
    let mut table = HashMap::new();
    for line in text.lines() {
        let Some((pid, ppid, tty, comm)) = split_row(line) else {
            continue;
        };
        let (Ok(pid), Ok(ppid)) = (pid.parse::<i32>(), ppid.parse::<i32>()) else {
            continue;
        };
        table.insert(
            pid,
            Proc {
                ppid,
                tty: normalize_tty(tty),
                comm: comm.to_string(),
            },
        );
    }
    (!table.is_empty()).then_some(table)
}

/// Split one `ps` row into `(pid, ppid, tty, comm)`.
///
/// `comm` is last and may contain spaces ("Cursor Helper (Plugin): …"), so only
/// the first three fields are taken off the front. And `ps` right-aligns its
/// columns, padding with **runs** of spaces — a `splitn` on single whitespace
/// characters yields empty fields for every row whose pid is shorter than the
/// column, which is most of them. Measured: it silently dropped `launchd` and
/// every low-numbered ancestor, which truncated the chain one step below the
/// application and reported the terminal's helper process as the terminal.
fn split_row(line: &str) -> Option<(&str, &str, &str, &str)> {
    let (pid, rest) = take_token(line)?;
    let (ppid, rest) = take_token(rest)?;
    let (tty, rest) = take_token(rest)?;
    Some((pid, ppid, tty, rest.trim()))
}

fn take_token(s: &str) -> Option<(&str, &str)> {
    let s = s.trim_start();
    let end = s.find(char::is_whitespace).unwrap_or(s.len());
    (end > 0).then(|| s.split_at(end))
}

/// `??` is how `ps` spells "no controlling terminal". It is not a tty name and
/// must never reach a card.
fn normalize_tty(raw: &str) -> Option<String> {
    let t = raw.trim().trim_start_matches("/dev/");
    (!t.is_empty() && t != "??" && t != "-").then(|| t.to_string())
}

/// Walk from `pid` up to `launchd`, taking the first tty seen and the last
/// application before the top.
fn walk(pid: i32, table: &HashMap<i32, Proc>) -> Origin {
    let mut origin = Origin::default();
    let mut cur = pid;
    // The chain is a handful of processes deep; the bound only exists so a
    // corrupt table cannot spin forever.
    for _ in 0..32 {
        let Some(p) = table.get(&cur) else { break };

        if origin.tty.is_none() {
            origin.tty = p.tty.clone();
        }
        // The topmost process below launchd is the application. Overwriting on
        // every step leaves exactly that one when the loop ends.
        if !p.comm.is_empty() {
            origin.app = Some(app_name(&p.comm));
        }

        if p.ppid <= 1 {
            break;
        }
        cur = p.ppid;
    }
    origin
}

/// The last path component, with the login shell's leading dash removed.
///
/// `ps` reports a login shell as `-zsh`, which is an argv convention and not a
/// program name.
fn app_name(comm: &str) -> String {
    let base = comm.rsplit('/').next().unwrap_or(comm);
    base.strip_prefix('-').unwrap_or(base).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(rows: &[(i32, i32, Option<&str>, &str)]) -> HashMap<i32, Proc> {
        rows.iter()
            .map(|(pid, ppid, tty, comm)| {
                (
                    *pid,
                    Proc {
                        ppid: *ppid,
                        tty: tty.map(str::to_string),
                        comm: comm.to_string(),
                    },
                )
            })
            .collect()
    }

    /// The chain measured on a real machine: the agent, its login shell, the
    /// terminal's per-session server, and the application.
    #[test]
    fn an_iterm_session_resolves_to_the_application_and_its_tty() {
        // Paths as `ps -o comm=` actually reports them on macOS, and the
        // ancestry as measured: the per-session server hangs off the app, and
        // the app hangs off launchd.
        let t = table(&[
            (20641, 20640, Some("ttys008"), "claude"),
            (20640, 20639, Some("ttys008"), "-zsh"),
            (20639, 35714, Some("ttys008"), "/usr/bin/login"),
            (
                35714,
                35711,
                None,
                "/Users/x/Library/Application Support/iTerm2/iTermServer-3.6.11",
            ),
            (35711, 1, None, "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
            (1, 0, None, "/sbin/launchd"),
        ]);
        let o = walk(20641, &t);
        assert_eq!(o.app.as_deref(), Some("iTerm2"));
        assert_eq!(o.tty.as_deref(), Some("ttys008"));
    }

    #[test]
    fn a_session_started_by_aiterm_says_so() {
        let t = table(&[
            (92112, 92111, Some("ttys010"), "claude"),
            (92111, 92110, Some("ttys010"), "-zsh"),
            (92110, 1, None, "aiterm"),
            (1, 0, None, "launchd"),
        ]);
        assert_eq!(walk(92112, &t).app.as_deref(), Some("aiterm"));
    }

    /// The status line forwards through a backgrounded `curl`, so the peer is
    /// two processes below the agent. The answer must be the same.
    #[test]
    fn a_curl_child_resolves_to_the_same_application() {
        let t = table(&[
            (5001, 5000, Some("ttys008"), "curl"),
            (5000, 20641, Some("ttys008"), "sh"),
            (20641, 20640, Some("ttys008"), "claude"),
            (20640, 900, Some("ttys008"), "login"),
            (900, 1, None, "iTerm2"),
            (1, 0, None, "launchd"),
        ]);
        let o = walk(5001, &t);
        assert_eq!(o.app.as_deref(), Some("iTerm2"));
        assert_eq!(o.tty.as_deref(), Some("ttys008"));
    }

    /// A daemon-launched agent has no controlling terminal. That is a real
    /// answer, and it must not become `"??"` on a card.
    #[test]
    fn no_controlling_terminal_stays_unknown_rather_than_becoming_a_string() {
        let t = table(&[(400, 1, None, "claude"), (1, 0, None, "launchd")]);
        let o = walk(400, &t);
        assert_eq!(o.tty, None);
        assert_eq!(o.app.as_deref(), Some("claude"));
    }

    #[test]
    fn ps_spelling_of_an_absent_tty_is_not_a_tty() {
        assert_eq!(normalize_tty("??"), None);
        assert_eq!(normalize_tty(""), None);
        assert_eq!(normalize_tty("ttys008"), Some("ttys008".into()));
        assert_eq!(normalize_tty("/dev/ttys008"), Some("ttys008".into()));
    }

    #[test]
    fn a_login_shells_leading_dash_is_an_argv_convention_and_not_a_name() {
        assert_eq!(app_name("-zsh"), "zsh");
        assert_eq!(app_name("/usr/bin/login"), "login");
        assert_eq!(app_name("iTerm2"), "iTerm2");
    }

    /// A cycle in the table must not hang the hook path.
    #[test]
    fn a_cyclic_parent_chain_terminates() {
        let t = table(&[(10, 11, None, "a"), (11, 10, None, "b")]);
        let _ = walk(10, &t);
    }

    /// The bug that made the first live run report `iTermServer-3.6.11` as the
    /// terminal: `ps` pads its columns, and a naive split threw away every row
    /// whose pid was narrower than the column — including `launchd` and the
    /// application itself.
    #[test]
    fn padded_columns_parse_and_a_command_may_contain_spaces() {
        assert_eq!(
            split_row("    1     0 ?? /sbin/launchd"),
            Some(("1", "0", "??", "/sbin/launchd"))
        );
        assert_eq!(
            split_row("11614  1234 ?? Cursor Helper (Plugin): extension-host"),
            Some((
                "11614",
                "1234",
                "??",
                "Cursor Helper (Plugin): extension-host"
            ))
        );
        assert_eq!(split_row(""), None);
    }

    /// Every ancestor must be reachable, not only the wide-pid ones.
    #[test]
    fn low_numbered_ancestors_survive_the_parse() {
        let table = process_table().expect("ps output");
        assert!(
            table.contains_key(&1),
            "launchd is pid 1 and its row is the most padded of all"
        );
    }

    /// The real `ps` on this machine must parse — a format change would
    /// otherwise show up as origins silently going missing.
    #[test]
    fn the_real_process_table_parses_and_contains_this_process() {
        let t = process_table().expect("ps output");
        let me = std::process::id() as i32;
        assert!(t.contains_key(&me), "our own pid must be in the table");
        assert!(walk(me, &t).app.is_some());
    }
}
