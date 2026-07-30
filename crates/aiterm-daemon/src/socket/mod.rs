//! Unix socket server at `~/.aiterm/daemon.sock`.
//!
//! JSON-lines, one object per line, discriminated by `type`. The normative
//! contract is `docs/PROTOCOL.md`.
//!
//! # Isolation
//!
//! Every connection runs in its own pair of tasks (one reader, one writer) and
//! owns nothing shared except an `Arc<Mutex<Registry>>` and a broadcast
//! subscription. A client that hangs up, sends garbage, or stops reading cannot
//! stall the daemon or any other client:
//!
//! - a slow reader eventually **lags** its broadcast receiver; we log the gap
//!   and keep going rather than disconnecting it or blocking the sender
//! - a malformed line is dropped and logged; the protocol has no error reply
//! - a dead connection ends its own tasks and nothing else
//!
//! The registry mutex is only ever held across synchronous work — never across
//! an `.await` — so one connection cannot park it.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::Utc;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc};

use crate::registry::{Registry, Session};
use crate::wire::{
    self, AppToDaemon, DaemonToApp, Rejected, SessionRegistered, SessionUpdated, PROTOCOL_VERSION,
};

/// How many messages a slow client may fall behind before it starts losing
/// them. Generous: these are human-rate events.
const BROADCAST_CAPACITY: usize = 1024;

/// Per-connection unicast queue depth, used for snapshot replay.
const UNICAST_CAPACITY: usize = 256;

/// `docs/PROTOCOL.md`: a line longer than this is dropped rather than buffered.
const MAX_LINE_BYTES: u64 = 1024 * 1024;

/// Shared handle to the daemon's state and its outbound broadcast.
#[derive(Clone)]
pub struct Hub {
    registry: Arc<Mutex<Registry>>,
    tx: broadcast::Sender<String>,
}

impl Hub {
    pub fn new(registry: Registry) -> Self {
        let (tx, _rx) = broadcast::channel(BROADCAST_CAPACITY);
        Self {
            registry: Arc::new(Mutex::new(registry)),
            tx,
        }
    }

    pub fn registry(&self) -> &Arc<Mutex<Registry>> {
        &self.registry
    }

    /// Lock the registry, recovering from a poisoned mutex rather than
    /// panicking. A panic in one connection must not take the daemon down with
    /// it: the registry's invariants are enforced by its own methods, not by
    /// the lock.
    fn lock(&self) -> MutexGuard<'_, Registry> {
        match self.registry.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Send to every connected client.
    ///
    /// Returns how many receivers it reached. Zero is normal — the app may
    /// simply not be running — and is never an error.
    pub fn broadcast(&self, msg: &DaemonToApp) -> usize {
        match msg.to_line() {
            Some(line) => self.tx.send(line).unwrap_or(0),
            None => {
                // Serializing our own type failed. Log and carry on: one
                // unsendable message must not stop the daemon.
                eprintln!("aiterm-daemon: could not serialize outbound message {msg:?}");
                0
            }
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<String> {
        self.tx.subscribe()
    }

    /// The `session_registered` message for a session as it stands.
    fn session_registered(session: &Session) -> DaemonToApp {
        DaemonToApp::SessionRegistered(SessionRegistered {
            v: PROTOCOL_VERSION,
            ts: wire::timestamp(Utc::now()),
            session_id: session.session_id.clone(),
            // A pending claim is not a binding: publish null, never a guess.
            tab_id: session.binding.bound_tab_id().map(str::to_string),
            agent: session.harness.as_wire().to_string(),
            // TODO(track-A): the protocol makes `cwd` required and non-null, but
            // a session we only heard about through a hook that carried none has
            // no cwd to report. Empty string is the least-bad schema-compliant
            // value. See docs/tracks/A-protocol-request.md.
            cwd: session.cwd.clone().unwrap_or_default(),
            title: session.title.clone(),
            // TODO(track-C): model comes from the transcript crate in Wave 2.
            model: None,
            started_at: wire::timestamp(session.created_at),
        })
    }

    /// Everything a freshly connected client needs, as ordinary messages.
    ///
    /// `docs/PROTOCOL.md` deliberately has no snapshot envelope and no
    /// end-of-snapshot marker: the daemon replays `session_registered` per live
    /// session. Clients treat all inbound messages as idempotent upserts, so a
    /// replay for a session they already know is normal traffic.
    ///
    /// TODO(track-A): once HITL exists, a `hitl_pending` per outstanding request
    /// is replayed here too.
    fn snapshot(&self) -> Vec<DaemonToApp> {
        self.lock()
            .live_sessions()
            .map(Self::session_registered)
            .collect()
    }

    /// Apply one inbound command. Returns messages for *this* client only;
    /// anything the others need is broadcast from inside.
    pub fn handle(&self, msg: AppToDaemon) -> Vec<DaemonToApp> {
        let now = Utc::now();

        match msg {
            AppToDaemon::RegisterTab { tab_id, cwd } => {
                // Build the patches while holding the lock, broadcast after
                // dropping it.
                let patches: Vec<SessionUpdated> = {
                    let mut registry = self.lock();
                    let bound = registry.register_tab(tab_id, cwd, now);
                    bound
                        .into_iter()
                        .filter_map(|id| {
                            let session = registry.session(&id)?;
                            let mut patch = SessionUpdated::new(&session.session_id, now);
                            patch.tab_id = Some(session.binding.bound_tab_id().map(str::to_string));
                            Some(patch)
                        })
                        .collect()
                };

                for patch in patches {
                    self.broadcast(&DaemonToApp::SessionUpdated(patch));
                }
                Vec::new()
            }

            AppToDaemon::RenameSession { session_id, title } => {
                let patch = {
                    let mut registry = self.lock();
                    registry.rename_session(&session_id, &title, now).then(|| {
                        let mut patch = SessionUpdated::new(&session_id, now);
                        patch.title = Some(Some(title));
                        patch
                    })
                };

                // An unknown session produces nothing. The protocol has no error
                // reply and inventing one would be a unilateral extension.
                if let Some(patch) = patch {
                    self.broadcast(&DaemonToApp::SessionUpdated(patch));
                }
                Vec::new()
            }

            AppToDaemon::RequestSnapshot {} => self.snapshot(),

            AppToDaemon::ResolveHitl { hitl_id, .. } => {
                // TODO(track-A): HITL bookkeeping arrives with the HTTP hook
                // endpoint, the next task. Until then a resolve targets nothing.
                // Per docs/PROTOCOL.md, resolving an unknown hitl_id is silently
                // ignored: it is the normal outcome of the race, not an error.
                let _ = hitl_id;
                Vec::new()
            }
        }
    }
}

/// A bound listener, ready to serve.
pub struct SocketServer {
    listener: UnixListener,
    path: PathBuf,
    hub: Hub,
}

impl SocketServer {
    /// Bind the socket, replacing a stale one if present.
    ///
    /// Created `0600`: this is a local, single-user channel and filesystem
    /// permissions are the whole of its access control (ADR-002).
    pub fn bind(path: impl AsRef<Path>, hub: Hub) -> io::Result<Self> {
        let path = path.as_ref().to_path_buf();

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        // A socket file left behind by a crashed daemon would make bind() fail
        // with EADDRINUSE. Removing it is what the protocol document promises.
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }

        let listener = UnixListener::bind(&path)?;

        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        }

        Ok(Self {
            listener,
            path,
            hub,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn hub(&self) -> &Hub {
        &self.hub
    }

    /// Accept forever. Each connection is spawned and then forgotten.
    ///
    /// An accept error is logged and the loop continues: one failed connection
    /// must not end the daemon.
    pub async fn serve(self) -> io::Result<()> {
        loop {
            match self.listener.accept().await {
                Ok((stream, _addr)) => {
                    let hub = self.hub.clone();
                    tokio::spawn(async move {
                        if let Err(e) = serve_connection(stream, hub).await {
                            eprintln!("aiterm-daemon: client connection ended: {e}");
                        }
                    });
                }
                Err(e) => eprintln!("aiterm-daemon: accept failed: {e}"),
            }
        }
    }
}

impl Drop for SocketServer {
    fn drop(&mut self) {
        // Best effort: a stale socket left behind is survivable, since bind()
        // unlinks it. Not worth reporting.
        let _ = std::fs::remove_file(&self.path);
    }
}

/// One client: a writer task fed by both the broadcast and a unicast queue, and
/// a reader loop on this task.
pub async fn serve_connection(stream: UnixStream, hub: Hub) -> io::Result<()> {
    let (read_half, mut write_half) = stream.into_split();

    let mut broadcast_rx = hub.subscribe();
    let (unicast_tx, mut unicast_rx) = mpsc::channel::<String>(UNICAST_CAPACITY);

    let writer = tokio::spawn(async move {
        loop {
            let line = tokio::select! {
                // Unicast first: a snapshot the client explicitly asked for
                // should not queue behind unrelated broadcast traffic.
                biased;

                got = unicast_rx.recv() => match got {
                    Some(line) => line,
                    None => break,
                },
                got = broadcast_rx.recv() => match got {
                    Ok(line) => line,
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        // This client read too slowly and missed messages. It is
                        // not disconnected: it can recover with request_snapshot.
                        eprintln!("aiterm-daemon: client lagged, dropped {n} messages");
                        continue;
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                },
            };

            if write_half.write_all(line.as_bytes()).await.is_err() {
                break; // client hung up; its own problem, nobody else's
            }
        }
        let _ = write_half.shutdown().await;
    });

    let mut lines = BufReader::new(read_half.take(MAX_LINE_BYTES)).lines();
    loop {
        let line = match lines.next_line().await {
            Ok(Some(line)) => line,
            Ok(None) => break, // clean EOF
            Err(e) => {
                eprintln!("aiterm-daemon: read error from client: {e}");
                break;
            }
        };

        if line.trim().is_empty() {
            continue;
        }

        match wire::parse_inbound(&line) {
            Ok(msg) => {
                for reply in hub.handle(msg) {
                    if let Some(line) = reply.to_line() {
                        // A full queue means a client that asked for a snapshot
                        // and then stopped reading. Drop rather than block.
                        if unicast_tx.try_send(line).is_err() {
                            eprintln!("aiterm-daemon: client unicast queue full, dropping reply");
                        }
                    }
                }
            }
            // The protocol has no error reply, by design. Log and move on.
            Err(Rejected::Malformed(why)) => {
                eprintln!("aiterm-daemon: dropping malformed line: {why}")
            }
            Err(Rejected::UnsupportedVersion(v)) => {
                eprintln!("aiterm-daemon: dropping message with unsupported v={v}")
            }
            Err(Rejected::UnknownType(ty)) => {
                eprintln!("aiterm-daemon: ignoring unknown message type {ty:?}")
            }
        }
    }

    drop(unicast_tx);
    let _ = writer.await;
    Ok(())
}

/// The default socket path, `~/.aiterm/daemon.sock`.
pub fn default_socket_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(PathBuf::from(home).join(aiterm_proto::SOCKET_RELATIVE_PATH))
}
