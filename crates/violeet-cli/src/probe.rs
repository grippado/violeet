//! Is the daemon there, and is it the daemon we think it is.
//!
//! # No HTTP crate
//!
//! `doctor` needs exactly one request: `GET /health` on loopback, tiny JSON
//! response. That is forty lines of `TcpStream`, against a server we wrote,
//! over an interface with no proxies, no TLS, no redirects and no chunked
//! encoding. Pulling in an async runtime and a TLS stack to make it would be a
//! dependency tree bigger than this crate, for one request.
//!
//! The parsing below is correspondingly narrow, and says so: it handles the
//! responses our own daemon produces and nothing else.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

const TIMEOUT: Duration = Duration::from_secs(2);

/// `~/.violeet/daemon.json`, as the daemon writes it.
#[derive(Debug, Clone)]
pub struct DaemonInfo {
    pub pid: u32,
    pub socket: PathBuf,
    pub hook_port: u16,
    pub protocol_version: u64,
    pub started_at: String,
}

pub fn violeet_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".violeet"))
}

pub fn discovery_path() -> Option<PathBuf> {
    violeet_dir().map(|d| d.join("daemon.json"))
}

/// Read the discovery file.
///
/// Absence is not failure: the daemon removes it on a clean shutdown, and
/// treats failing to write it as non-fatal. It means "look for the daemon
/// elsewhere", not "the daemon is broken".
pub fn read_discovery() -> Option<DaemonInfo> {
    let path = discovery_path()?;
    let text = std::fs::read_to_string(path).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    Some(DaemonInfo {
        pid: v.get("pid")?.as_u64()? as u32,
        socket: PathBuf::from(v.get("socket")?.as_str()?),
        hook_port: u16::try_from(v.get("hook_port")?.as_u64()?).ok()?,
        protocol_version: v.get("protocol_version").and_then(Value::as_u64).unwrap_or(0),
        started_at: v
            .get("started_at")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
    })
}

/// The socket path the protocol fixes, used when there is no discovery file.
pub fn default_socket_path() -> Option<PathBuf> {
    violeet_dir().map(|d| d.join("daemon.sock"))
}

/// Can we open the Unix socket?
///
/// Connecting and hanging up is the only honest test. The socket *file* can
/// exist with nothing listening — a daemon killed with `SIGKILL` leaves one
/// behind — and a client that checked for the file would report a daemon that
/// is not there.
pub fn socket_connects(path: &Path) -> Result<(), String> {
    match UnixStream::connect(path) {
        Ok(_) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

/// What `GET /health` said.
#[derive(Debug, Clone)]
pub struct Health {
    pub protocol_version: u64,
    pub sessions: u64,
    pub hitl_pending: u64,
    /// Models the daemon could not resolve a context window size for.
    ///
    /// Empty on an older daemon that does not report the field, which is
    /// indistinguishable from "none" — an acceptable blind spot, since the
    /// alternative is a check that fails against every daemon built before
    /// this one.
    pub unknown_window_models: Vec<String>,
}

/// One `GET /health` against loopback.
pub fn health(port: u16) -> Result<Health, String> {
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let mut stream = TcpStream::connect_timeout(&addr, TIMEOUT).map_err(|e| e.to_string())?;
    stream.set_read_timeout(Some(TIMEOUT)).ok();
    stream.set_write_timeout(Some(TIMEOUT)).ok();

    // `Connection: close` so the daemon hangs up and we can read to EOF instead
    // of parsing Content-Length.
    let request = format!(
        "GET /health HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
    );
    stream
        .write_all(request.as_bytes())
        .map_err(|e| e.to_string())?;

    let mut response = Vec::new();
    stream
        .read_to_end(&mut response)
        .map_err(|e| e.to_string())?;

    let text = String::from_utf8_lossy(&response);
    let (head, body) = text
        .split_once("\r\n\r\n")
        .ok_or("the response had no header/body separator")?;

    let status = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .unwrap_or("?");
    if status != "200" {
        return Err(format!("/health answered {status}"));
    }

    let v: Value = serde_json::from_str(body.trim())
        .map_err(|e| format!("/health did not return JSON: {e}"))?;

    Ok(Health {
        protocol_version: v.get("protocol_version").and_then(Value::as_u64).unwrap_or(0),
        sessions: v.get("sessions").and_then(Value::as_u64).unwrap_or(0),
        hitl_pending: v.get("hitl_pending").and_then(Value::as_u64).unwrap_or(0),
        unknown_window_models: v
            .get("unknown_window_models")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default(),
    })
}

/// Is `cwd` a project Claude Code trusts?
///
/// This check exists because of a specific, expensive failure: **project
/// settings in an untrusted directory are ignored in silence.** No warning, no
/// log line, no hint in the UI — hooks simply never fire, and the obvious
/// conclusion is that the hooks are wrong. Trust lives in `~/.claude.json`
/// under `projects[<absolute path>].hasTrustDialogAccepted`.
///
/// Returns `None` when the file cannot be read, which is genuinely unknown
/// rather than untrusted.
pub fn project_is_trusted(cwd: &Path) -> Option<bool> {
    let home = std::env::var_os("HOME")?;
    let path = PathBuf::from(home).join(".claude.json");
    let text = std::fs::read_to_string(path).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;

    let projects = v.get("projects")?.as_object()?;
    let key = cwd.to_string_lossy().to_string();

    match projects.get(&key) {
        Some(entry) => Some(
            entry
                .get("hasTrustDialogAccepted")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        ),
        // A directory Claude Code has never opened is, for our purposes,
        // untrusted: its project settings would be ignored just the same.
        None => Some(false),
    }
}

/// The Claude Code version, best effort.
///
/// Read from the versions directory rather than by running `claude --version`:
/// the launcher is often a shell function that does not exist in a
/// non-interactive shell, so invoking it fails in a way that says nothing about
/// whether Claude Code is installed.
pub fn claude_code_version() -> Option<String> {
    let home = std::env::var_os("HOME")?;
    let dir = PathBuf::from(home).join(".local/share/claude/versions");
    let mut versions: Vec<String> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    versions.sort_by(|a, b| compare_versions(a, b));
    versions.pop()
}

/// Numeric comparison of dotted versions, so `2.1.220` sorts above `2.1.99`.
fn compare_versions(a: &str, b: &str) -> std::cmp::Ordering {
    let parts = |s: &str| -> Vec<u64> {
        s.split('.').map(|p| p.parse().unwrap_or(0)).collect()
    };
    parts(a).cmp(&parts(b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_numerically_and_not_as_strings() {
        assert_eq!(compare_versions("2.1.220", "2.1.99"), std::cmp::Ordering::Greater);
        assert_eq!(compare_versions("2.1.9", "2.1.10"), std::cmp::Ordering::Less);
        assert_eq!(compare_versions("2.1.220", "2.1.220"), std::cmp::Ordering::Equal);
    }

    /// A socket path that does not exist must report as unreachable rather than
    /// panicking, which is the state every check runs in when the daemon is off.
    #[test]
    fn a_missing_socket_is_an_error_and_not_a_panic() {
        let missing = PathBuf::from("/nonexistent/violeet/daemon.sock");
        assert!(socket_connects(&missing).is_err());
    }

    #[test]
    fn health_on_a_dead_port_fails_without_hanging() {
        // Port 1 on loopback: privileged, nothing listening, refuses fast.
        assert!(health(1).is_err());
    }
}
