//! `aiterm-daemon` entry point.
//!
//! Thin on purpose: everything lives in the library so it can be tested without
//! a running daemon. See `lib.rs` for the module map.

#![forbid(unsafe_code)]

use std::process::ExitCode;
use std::time::Duration as StdDuration;

use aiterm_daemon::registry::Registry;
use aiterm_daemon::socket::{default_socket_path, Hub, SocketServer};

/// How often to sweep for sessions that have gone quiet.
const EXPIRY_SWEEP: StdDuration = StdDuration::from_secs(30);

#[tokio::main]
async fn main() -> ExitCode {
    let Some(socket_path) = default_socket_path() else {
        eprintln!("aiterm-daemon: HOME is not set, cannot place the socket");
        return ExitCode::FAILURE;
    };

    let hub = Hub::new(Registry::with_default_ttl());

    let server = match SocketServer::bind(&socket_path, hub.clone()) {
        Ok(server) => server,
        Err(e) => {
            eprintln!("aiterm-daemon: cannot bind {}: {e}", socket_path.display());
            return ExitCode::FAILURE;
        }
    };
    eprintln!("aiterm-daemon: listening on {}", server.path().display());

    // TODO(track-A): write ~/.aiterm/daemon.json here once the HTTP hook
    // endpoint exists — the discovery file carries the effective hook port, and
    // publishing it before the port is real would advertise a lie.

    tokio::spawn(expiry_sweeper(hub));

    if let Err(e) = server.serve().await {
        eprintln!("aiterm-daemon: socket server stopped: {e}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

/// Periodically kill sessions that have gone quiet, and announce each one.
async fn expiry_sweeper(hub: Hub) {
    let mut ticker = tokio::time::interval(EXPIRY_SWEEP);
    loop {
        ticker.tick().await;

        let expired = {
            let mut registry = match hub.registry().lock() {
                Ok(g) => g,
                Err(p) => p.into_inner(),
            };
            registry.expire_idle(chrono::Utc::now())
        };

        for session_id in expired {
            // TODO(track-A): emit session_ended for each. Building the message
            // needs the session's tab_id, which means another registry read;
            // folded into the HTTP task where the publish helpers land.
            eprintln!("aiterm-daemon: session {session_id} expired for inactivity");
        }
    }
}
