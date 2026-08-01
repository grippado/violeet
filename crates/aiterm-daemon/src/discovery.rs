//! `~/.aiterm/daemon.json`, the file clients read instead of guessing.
//!
//! `docs/PROTOCOL.md`: the hook port is configurable and `9847` is only the
//! default, so the file carries the **effective** port. That is the whole reason
//! it exists — a client that assumes the default is wrong the first time
//! somebody changes it.
//!
//! Written after both servers are bound, never before. Publishing a port we
//! have not successfully bound would advertise a lie, and the client that
//! believes it has no way to tell the difference between "wrong port" and
//! "daemon down".

use std::io;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::Serialize;

/// The contents of the discovery file.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct DaemonInfo {
    pub pid: u32,
    pub socket: String,
    pub hook_port: u16,
    pub protocol_version: u32,
    pub started_at: String,
}

impl DaemonInfo {
    pub fn new(socket: &Path, hook_port: u16, started_at: DateTime<Utc>) -> Self {
        Self {
            pid: std::process::id(),
            socket: socket.display().to_string(),
            hook_port,
            protocol_version: crate::wire::PROTOCOL_VERSION,
            started_at: crate::wire::timestamp(started_at),
        }
    }
}

/// `~/.aiterm/daemon.json`, or `None` if we cannot tell where home is.
pub fn default_path() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(aiterm_proto::DAEMON_JSON_RELATIVE_PATH))
}

/// Write the file, creating `~/.aiterm/` if needed.
///
/// Written to a temporary file and renamed, so a client never reads a
/// half-written object. Rename within a directory is atomic on macOS, which is
/// the only platform this daemon targets.
pub fn write(path: &Path, info: &DaemonInfo) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
        // `create_dir_all` applies the process umask, which on a default macOS
        // account yields 0755. That directory holds the control socket: a
        // world-traversable path to it means any other account on the machine
        // can reach the channel that resolves permission requests. The socket
        // being 0600 does not help if the directory around it is not.
        restrict(parent, 0o700)?;
    }

    let body = serde_json::to_string_pretty(info)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, body)?;
    // Tightened before the rename, so the file is never briefly world-readable
    // under its final name. It carries the pid and the hook port — the two
    // things needed to forge a hook (see ADR-005).
    restrict(&tmp, 0o600)?;
    std::fs::rename(&tmp, path)
}

/// Set permissions, on Unix.
///
/// Applied unconditionally rather than only when they look wrong: reading first
/// would be a check followed by a write, and the gap between them is exactly
/// where a wrong mode survives.
#[cfg(unix)]
fn restrict(path: &Path, mode: u32) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn restrict(_path: &Path, _mode: u32) -> io::Result<()> {
    Ok(())
}

/// Remove the file on a clean shutdown.
///
/// A missing file is success: the point is that it is gone, not that we were
/// the one to remove it. A stale file left by a crash is handled by the client,
/// which has to tolerate a daemon that died without cleaning up anyway.
pub fn remove(path: &Path) -> io::Result<()> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn now() -> DateTime<Utc> {
        Utc.timestamp_opt(1_700_000_000, 0).unwrap()
    }

    #[test]
    fn the_file_carries_the_effective_port_not_the_default() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("daemon.json");

        // A port the OS handed us, deliberately not 9847.
        let info = DaemonInfo::new(Path::new("/tmp/daemon.sock"), 51234, now());
        write(&path, &info).unwrap();

        let read: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(read["hook_port"], 51234);
        assert_eq!(read["socket"], "/tmp/daemon.sock");
        assert_eq!(read["protocol_version"], 1);
        assert_eq!(read["pid"], std::process::id());
        assert_eq!(read["started_at"], "2023-11-14T22:13:20Z");
    }

    #[test]
    fn writing_creates_the_directory() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested").join("daemon.json");

        write(&path, &DaemonInfo::new(Path::new("/s.sock"), 1, now())).unwrap();
        assert!(path.exists());
    }

    /// A reader must never see a partial object.
    #[test]
    fn writing_over_an_existing_file_leaves_no_temporary_behind() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("daemon.json");

        write(&path, &DaemonInfo::new(Path::new("/a.sock"), 1, now())).unwrap();
        write(&path, &DaemonInfo::new(Path::new("/b.sock"), 2, now())).unwrap();

        let read: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(read["socket"], "/b.sock");
        assert!(!path.with_extension("json.tmp").exists());
    }

    #[test]
    fn removing_a_file_that_is_not_there_is_success() {
        let dir = tempfile::tempdir().unwrap();
        remove(&dir.path().join("never-written.json")).expect("absence is the goal, not an error");
    }
}
