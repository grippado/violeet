//! `violeet-daemon` entry point.
//!
//! Thin on purpose: everything lives in the library so it can be tested without
//! a running daemon. See `lib.rs` for the module map.
//!
//! Startup order matters and is not arbitrary:
//!
//! 1. bind the Unix socket
//! 2. bind the hook endpoint, learning the port the OS actually gave us
//! 3. only then write `~/.violeet/daemon.json`
//!
//! Writing the discovery file earlier would publish a port that might fail to
//! bind, and a client cannot tell an advertised-but-wrong port from a daemon
//! that is down.

#![forbid(unsafe_code)]

use std::process::ExitCode;
use std::time::Duration as StdDuration;

use violeet_daemon::discovery::{self, DaemonInfo};
use violeet_daemon::http::{HookServer, DEFAULT_HOOK_PORT};
use violeet_daemon::registry::Registry;
use violeet_daemon::socket::{default_socket_path, Hub, SocketServer};
use violeet_daemon::wire::EndReason;

/// How often to sweep for sessions that have gone quiet and permission requests
/// that have run out of time.
const SWEEP: StdDuration = StdDuration::from_secs(5);

/// Overrides the hook port. The discovery file carries whatever we end up on,
/// so nothing downstream has to know this variable exists.
const PORT_ENV: &str = "VIOLEET_HOOK_PORT";

#[tokio::main]
async fn main() -> ExitCode {
    let Some(socket_path) = default_socket_path() else {
        eprintln!("violeet-daemon: HOME is not set, cannot place the socket");
        return ExitCode::FAILURE;
    };

    let hub = Hub::new(Registry::with_default_ttl());

    let socket = match SocketServer::bind(&socket_path, hub.clone()) {
        Ok(server) => server,
        Err(e) => {
            eprintln!("violeet-daemon: cannot bind {}: {e}", socket_path.display());
            return ExitCode::FAILURE;
        }
    };
    eprintln!("violeet-daemon: listening on {}", socket.path().display());

    let hooks = match HookServer::bind(hook_port(), hub.clone()).await {
        Ok(server) => server,
        Err(e) => {
            eprintln!("violeet-daemon: cannot bind the hook endpoint: {e}");
            return ExitCode::FAILURE;
        }
    };
    let hook_port = hooks.port();
    eprintln!("violeet-daemon: hooks on http://127.0.0.1:{hook_port}");

    // Both servers are up, so the port we are about to publish is real.
    let discovery_path = discovery::default_path();
    if let Some(path) = &discovery_path {
        let info = DaemonInfo::new(&socket_path, hook_port, chrono::Utc::now());
        if let Err(e) = discovery::write(path, &info) {
            // Not fatal. The daemon works; clients just have to be told the
            // port some other way. Failing to start over this would be worse.
            eprintln!("violeet-daemon: could not write {}: {e}", path.display());
        }
    }

    tokio::spawn(sweeper(hub.clone()));
    tokio::spawn(async move {
        if let Err(e) = hooks.serve().await {
            eprintln!("violeet-daemon: hook endpoint stopped: {e}");
        }
    });

    let outcome = tokio::select! {
        result = socket.serve() => match result {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("violeet-daemon: socket server stopped: {e}");
                ExitCode::FAILURE
            }
        },
        _ = shutdown_signal() => {
            eprintln!("violeet-daemon: shutting down");
            ExitCode::SUCCESS
        }
    };

    if let Some(path) = &discovery_path {
        let _ = discovery::remove(path);
    }
    outcome
}

fn hook_port() -> u16 {
    match std::env::var(PORT_ENV) {
        Ok(raw) => raw.parse().unwrap_or_else(|_| {
            eprintln!("violeet-daemon: {PORT_ENV}={raw:?} is not a port; using the default");
            DEFAULT_HOOK_PORT
        }),
        Err(_) => DEFAULT_HOOK_PORT,
    }
}

/// Both signals that mean "stop", not just the interactive one.
///
/// `SIGTERM` is what a process manager sends, so handling only `SIGINT` would
/// leave `~/.violeet/daemon.json` behind on every managed shutdown — and a stale
/// discovery file is worse than none, because it points a client at a port
/// nothing is listening on.
async fn shutdown_signal() {
    use tokio::signal::unix::{signal, SignalKind};

    let mut term = match signal(SignalKind::terminate()) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("violeet-daemon: cannot listen for SIGTERM: {e}");
            let _ = tokio::signal::ctrl_c().await;
            return;
        }
    };

    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
}

/// Kill sessions that have gone quiet, and time out permission requests whose
/// handler is no longer around to do it itself.
///
/// The handler owns the primary HITL deadline; this is the backstop for a
/// request whose HTTP client vanished, which is why the sweep interval can be
/// coarse without making the user-visible timeout imprecise.
async fn sweeper(hub: Hub) {
    let mut ticker = tokio::time::interval(SWEEP);
    loop {
        ticker.tick().await;
        let now = chrono::Utc::now();

        let expired_hitl = hub.expire_hitl(now);
        if expired_hitl > 0 {
            eprintln!("violeet-daemon: {expired_hitl} permission request(s) timed out");
        }

        let expired: Vec<String> = {
            let mut registry = match hub.registry().lock() {
                Ok(g) => g,
                Err(p) => p.into_inner(),
            };
            registry.expire_idle(now)
        };

        for session_id in expired {
            eprintln!("violeet-daemon: session {session_id} expired for inactivity");
            let tab_id = hub.bound_tab_of(&session_id);
            hub.publish_session_ended(&session_id, tab_id, EndReason::ProcessExited, now);
        }
    }
}
