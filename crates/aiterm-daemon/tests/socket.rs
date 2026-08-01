//! Integration tests for the Unix socket server.
//!
//! These drive a real listener over a real socket in a temp dir. They cover the
//! properties the fan-out brief asks for and that unit tests cannot show:
//! several clients at once, broadcast reaching all of them, and one client
//! misbehaving without hurting the others.
//!
//! TODO(track-B): the real client is the SwiftUI app. Everything here is a fake
//! speaking the same JSON-lines protocol.

use std::time::Duration;

use aiterm_daemon::registry::{Harness, HookObservation, Registry, SessionState, TitleSource};
use aiterm_daemon::socket::{Hub, SocketServer};
use aiterm_daemon::wire::{DaemonToApp, EndReason, SessionEnded, PROTOCOL_VERSION};
use chrono::Utc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

/// Everything here should be near-instant; a hang is a bug, not slowness.
const PATIENCE: Duration = Duration::from_secs(5);

struct Harnessed {
    hub: Hub,
    path: std::path::PathBuf,
    _dir: tempfile::TempDir,
}

/// Bind a server on a throwaway path and start serving it.
async fn start() -> Harnessed {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("daemon.sock");

    // Persisted session titles go in the temp dir, not in the developer's real
    // `~/.aiterm/`. Not hypothetical: the rename test below wrote `"s1": "my
    // run"` into a live store the first time it ran. Every test in this binary
    // sets the same value, so setting it here repeatedly is harmless.
    unsafe {
        std::env::set_var("AITERM_STATE_DIR", dir.path());
    }

    let hub = Hub::new(Registry::with_default_ttl());
    let server = SocketServer::bind(&path, hub.clone()).expect("bind");
    tokio::spawn(server.serve());

    Harnessed {
        hub,
        path,
        _dir: dir,
    }
}

/// A fake app: a connected socket with a line reader.
struct Client {
    reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: tokio::net::unix::OwnedWriteHalf,
}

impl Client {
    async fn connect(path: &std::path::Path) -> Self {
        let stream = UnixStream::connect(path).await.expect("connect");
        let (r, w) = stream.into_split();
        Self {
            reader: BufReader::new(r),
            writer: w,
        }
    }

    async fn send(&mut self, line: &str) {
        self.writer.write_all(line.as_bytes()).await.expect("write");
        self.writer.write_all(b"\n").await.expect("write newline");
    }

    /// Next message, or panic if nothing arrives in time.
    async fn next(&mut self) -> serde_json::Value {
        let mut line = String::new();
        tokio::time::timeout(PATIENCE, self.reader.read_line(&mut line))
            .await
            .expect("timed out waiting for a message")
            .expect("read");
        assert!(
            !line.is_empty(),
            "socket closed while a message was expected"
        );
        serde_json::from_str(&line).expect("server sent invalid JSON")
    }

    /// Assert nothing arrives within a short window.
    async fn expect_silence(&mut self) {
        let mut line = String::new();
        let got =
            tokio::time::timeout(Duration::from_millis(200), self.reader.read_line(&mut line))
                .await;
        if let Ok(Ok(n)) = got {
            assert_eq!(n, 0, "expected silence, got {line:?}");
        }
    }
}

fn session_ended(session_id: &str) -> DaemonToApp {
    DaemonToApp::SessionEnded(SessionEnded {
        v: PROTOCOL_VERSION,
        ts: aiterm_daemon::wire::timestamp(Utc::now()),
        session_id: session_id.to_string(),
        tab_id: None,
        reason: EndReason::DaemonShutdown,
    })
}

#[tokio::test]
async fn the_socket_is_created_private_to_the_user() {
    use std::os::unix::fs::PermissionsExt;
    let h = start().await;
    let mode = std::fs::metadata(&h.path).unwrap().permissions().mode();
    assert_eq!(
        mode & 0o777,
        0o600,
        "the socket must not be readable by other users"
    );
}

#[tokio::test]
async fn binding_replaces_a_stale_socket_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("daemon.sock");
    std::fs::write(&path, b"leftover from a crashed daemon").unwrap();

    let hub = Hub::new(Registry::with_default_ttl());
    SocketServer::bind(&path, hub).expect("a stale file must not block startup");
}

#[tokio::test]
async fn a_snapshot_replays_live_sessions_as_ordinary_messages() {
    let h = start().await;
    {
        let mut r = h.hub.registry().lock().unwrap();
        r.register_tab("tab-1", Some("/repo".into()), Utc::now());
        r.observe_hook(
            HookObservation::new("s1", Harness::ClaudeCode)
                .with_tab_id("tab-1")
                .with_cwd("/repo"),
            Utc::now(),
        );
    }

    let mut client = Client::connect(&h.path).await;
    client
        .send(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#)
        .await;

    let msg = client.next().await;
    assert_eq!(msg["type"], "session_registered");
    assert_eq!(msg["session_id"], "s1");
    assert_eq!(msg["tab_id"], "tab-1");
    assert_eq!(msg["agent"], "claude-code");
    assert_eq!(msg["cwd"], "/repo");
    assert!(
        msg["title"].is_null(),
        "nothing has named it, so null — not a placeholder"
    );
    assert!(msg["model"].is_null());
}

#[tokio::test]
async fn a_pending_binding_is_published_as_null_not_as_a_guess() {
    let h = start().await;
    {
        // A hook claiming a tab the app never registered.
        let mut r = h.hub.registry().lock().unwrap();
        r.observe_hook(
            HookObservation::new("s1", Harness::ClaudeCode).with_tab_id("tab-unknown"),
            Utc::now(),
        );
    }

    let mut client = Client::connect(&h.path).await;
    client
        .send(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#)
        .await;

    let msg = client.next().await;
    assert!(msg["tab_id"].is_null(), "a pending claim is not a binding");
}

#[tokio::test]
async fn a_snapshot_omits_sessions_that_already_ended() {
    let h = start().await;
    {
        let mut r = h.hub.registry().lock().unwrap();
        r.observe_hook(HookObservation::new("alive", Harness::Codex), Utc::now());
        r.observe_hook(HookObservation::new("gone", Harness::Codex), Utc::now());
        r.set_state("gone", SessionState::Dead, Utc::now())
            .unwrap()
            .unwrap();
    }

    let mut client = Client::connect(&h.path).await;
    client
        .send(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#)
        .await;

    // The live session replays twice — a registration, then a telemetry patch
    // restoring state, which `session_registered` has no field for. The dead
    // one replays not at all, which is what this test is about.
    let registered = client.next().await;
    assert_eq!(registered["type"], "session_registered");
    assert_eq!(registered["session_id"], "alive");

    let telemetry = client.next().await;
    assert_eq!(telemetry["type"], "session_updated");
    assert_eq!(telemetry["session_id"], "alive");

    client.expect_silence().await;
}

#[tokio::test]
async fn every_connected_client_receives_a_broadcast() {
    let h = start().await;

    let mut a = Client::connect(&h.path).await;
    let mut b = Client::connect(&h.path).await;
    let mut c = Client::connect(&h.path).await;

    // Give the three writer tasks a moment to subscribe before sending.
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(
        h.hub.broadcast(&session_ended("s1")),
        3,
        "all three should be subscribed"
    );

    for client in [&mut a, &mut b, &mut c] {
        let msg = client.next().await;
        assert_eq!(msg["type"], "session_ended");
        assert_eq!(msg["session_id"], "s1");
        assert_eq!(msg["reason"], "daemon_shutdown");
    }
}

#[tokio::test]
async fn register_tab_from_one_client_is_broadcast_to_the_others() {
    let h = start().await;
    {
        // A session already waiting on a tab the app has not announced yet.
        let mut r = h.hub.registry().lock().unwrap();
        r.observe_hook(
            HookObservation::new("s1", Harness::ClaudeCode).with_tab_id("tab-7"),
            Utc::now(),
        );
    }

    let mut actor = Client::connect(&h.path).await;
    let mut observer = Client::connect(&h.path).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    actor
        .send(r#"{"type":"register_tab","v":1,"ts":"x","tab_id":"tab-7"}"#)
        .await;

    // The late binding reaches the client that did not ask for it.
    let msg = observer.next().await;
    assert_eq!(msg["type"], "session_updated");
    assert_eq!(msg["session_id"], "s1");
    assert_eq!(msg["tab_id"], "tab-7");
}

#[tokio::test]
async fn a_client_that_disconnects_does_not_disturb_the_others() {
    let h = start().await;

    let mut survivor = Client::connect(&h.path).await;
    let doomed = Client::connect(&h.path).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    drop(doomed);
    tokio::time::sleep(Duration::from_millis(100)).await;

    h.hub.broadcast(&session_ended("still-here"));
    let msg = survivor.next().await;
    assert_eq!(msg["session_id"], "still-here");
}

#[tokio::test]
async fn garbage_from_one_client_neither_kills_it_nor_anyone_else() {
    let h = start().await;

    let mut noisy = Client::connect(&h.path).await;
    let mut quiet = Client::connect(&h.path).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    for junk in [
        "not json at all",
        "[1,2,3]",
        "{",
        r#"{"type":"from_the_future","v":1,"ts":"x"}"#,
        r#"{"type":"request_snapshot","v":99,"ts":"x"}"#,
        r#"{"no_type":true}"#,
    ] {
        noisy.send(junk).await;
    }

    // No error reply exists in the protocol: the daemon stays silent.
    noisy.expect_silence().await;

    // Both connections are still alive and still served.
    h.hub.broadcast(&session_ended("after-the-garbage"));
    assert_eq!(noisy.next().await["session_id"], "after-the-garbage");
    assert_eq!(quiet.next().await["session_id"], "after-the-garbage");
}

#[tokio::test]
async fn rename_session_is_applied_and_announced() {
    let h = start().await;
    {
        let mut r = h.hub.registry().lock().unwrap();
        r.observe_hook(HookObservation::new("s1", Harness::Opencode), Utc::now());
    }

    let mut client = Client::connect(&h.path).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    client
        .send(r#"{"type":"rename_session","v":1,"ts":"x","session_id":"s1","title":"my run"}"#)
        .await;

    let msg = client.next().await;
    assert_eq!(msg["type"], "session_updated");
    assert_eq!(msg["title"], "my run");
    assert!(
        msg.get("model").is_none(),
        "an unchanged field must be absent, not null"
    );

    let r = h.hub.registry().lock().unwrap();
    assert_eq!(r.session("s1").unwrap().title.as_deref(), Some("my run"));
}

/// The round trip the user actually performs: rename, let the agent produce a
/// better name behind the manual one, then ask for automatic naming back.
#[tokio::test]
async fn releasing_a_manual_name_announces_the_derived_one() {
    let h = start().await;
    {
        let mut r = h.hub.registry().lock().unwrap();
        r.observe_hook(HookObservation::new("s1", Harness::Opencode), Utc::now());
    }

    let mut client = Client::connect(&h.path).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    client
        .send(r#"{"type":"rename_session","v":1,"ts":"x","session_id":"s1","title":"my run"}"#)
        .await;
    assert_eq!(client.next().await["title"], "my run");

    // Arrives while the manual name holds: nothing is published, because
    // nothing on screen changed.
    h.hub
        .offer_title("s1", "Fix the parser", TitleSource::AiTitle, Utc::now());
    client.expect_silence().await;

    client
        .send(r#"{"type":"release_session_title","v":1,"ts":"x","session_id":"s1"}"#)
        .await;
    let msg = client.next().await;
    assert_eq!(msg["type"], "session_updated");
    assert_eq!(msg["title"], "Fix the parser");
    assert_eq!(msg["title_source"], "ai_title");
}

#[tokio::test]
async fn releasing_an_unknown_session_is_silently_ignored() {
    let h = start().await;
    let mut client = Client::connect(&h.path).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    client
        .send(r#"{"type":"release_session_title","v":1,"ts":"x","session_id":"ghost"}"#)
        .await;

    client.expect_silence().await;
}

#[tokio::test]
async fn renaming_an_unknown_session_is_silently_ignored() {
    let h = start().await;
    let mut client = Client::connect(&h.path).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    client
        .send(r#"{"type":"rename_session","v":1,"ts":"x","session_id":"ghost","title":"nope"}"#)
        .await;

    // The protocol has no error reply, so the correct behaviour is nothing at all.
    client.expect_silence().await;
}

#[tokio::test]
async fn resolving_an_unknown_hitl_is_silently_ignored() {
    let h = start().await;
    let mut client = Client::connect(&h.path).await;
    tokio::time::sleep(Duration::from_millis(50)).await;

    client
        .send(r#"{"type":"resolve_hitl","v":1,"ts":"x","hitl_id":"h1","decision":{"behavior":"allow"}}"#)
        .await;

    // Per docs/PROTOCOL.md this is the normal outcome of the race, not an error.
    client.expect_silence().await;
}

#[tokio::test]
async fn many_clients_and_many_sessions_stay_coherent() {
    let h = start().await;
    {
        let mut r = h.hub.registry().lock().unwrap();
        for i in 0..12 {
            r.observe_hook(
                HookObservation::new(format!("s{i:02}"), Harness::ClaudeCode)
                    .with_cwd(format!("/repo/{i}")),
                Utc::now(),
            );
        }
    }

    let mut clients = Vec::new();
    for _ in 0..4 {
        clients.push(Client::connect(&h.path).await);
    }

    for client in &mut clients {
        client
            .send(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#)
            .await;

        // Each session replays as a registration followed by a telemetry
        // patch, so the registrations are collected rather than counted.
        let mut seen = Vec::new();
        while seen.len() < 12 {
            let msg = client.next().await;
            if msg["type"] == "session_registered" {
                seen.push(msg["session_id"].as_str().unwrap().to_string());
            }
        }
        seen.sort();
        let expected: Vec<String> = (0..12).map(|i| format!("s{i:02}")).collect();
        assert_eq!(
            seen, expected,
            "every client sees every live session, exactly once"
        );
    }
}

// ---------------------------------------------------------------------------
// close_tab — the message added in the 2026-07-31 protocol revision.
//
// Registry::close_tab() was implemented and unit-tested during Wave 1 but was
// unreachable over the socket, so these tests exist to prove the wiring, not
// the registry logic.
// ---------------------------------------------------------------------------

#[tokio::test]
async fn closing_a_tab_ends_its_sessions_and_tells_every_client() {
    let h = start().await;
    {
        let mut r = h.hub.registry().lock().unwrap();
        r.register_tab("tab-1", Some("/repo".into()), Utc::now());
        r.observe_hook(
            HookObservation::new("s1", Harness::ClaudeCode)
                .with_tab_id("tab-1")
                .with_cwd("/repo"),
            Utc::now(),
        );
        // A second tab, to prove the blast radius is one tab wide.
        r.register_tab("tab-2", Some("/other".into()), Utc::now());
        r.observe_hook(
            HookObservation::new("s2", Harness::ClaudeCode).with_tab_id("tab-2"),
            Utc::now(),
        );
    }

    let mut watcher = Client::connect(&h.path).await;
    let mut closer = Client::connect(&h.path).await;

    closer
        .send(r#"{"type":"close_tab","v":1,"ts":"x","tab_id":"tab-1"}"#)
        .await;

    // session_ended is a broadcast: the client that asked and the one that did
    // not both hear about it.
    for client in [&mut watcher, &mut closer] {
        let msg = client.next().await;
        assert_eq!(msg["type"], "session_ended");
        assert_eq!(msg["session_id"], "s1");
        assert_eq!(msg["tab_id"], "tab-1");
        assert_eq!(msg["reason"], "tab_closed");
    }

    // s2 belongs to a different tab and must be untouched.
    watcher.expect_silence().await;

    let r = h.hub.registry().lock().unwrap();
    assert_eq!(r.session("s1").unwrap().state(), SessionState::Dead);
    assert_ne!(
        r.session("s2").unwrap().state(),
        SessionState::Dead,
        "closing one tab must not end another tab's sessions"
    );
}

/// A closed tab's session leaves the snapshot immediately.
///
/// This is the requirement the missing message was blocking: without
/// `close_tab` the card for a dead tab survived until the inactivity TTL, up to
/// thirty minutes.
#[tokio::test]
async fn a_closed_tabs_session_is_gone_from_the_next_snapshot() {
    let h = start().await;
    {
        let mut r = h.hub.registry().lock().unwrap();
        r.register_tab("tab-1", Some("/repo".into()), Utc::now());
        r.observe_hook(
            HookObservation::new("s1", Harness::ClaudeCode).with_tab_id("tab-1"),
            Utc::now(),
        );
    }

    let mut client = Client::connect(&h.path).await;
    client
        .send(r#"{"type":"close_tab","v":1,"ts":"x","tab_id":"tab-1"}"#)
        .await;
    let _ended = client.next().await;

    client
        .send(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#)
        .await;
    client.expect_silence().await;
}

/// Closing a tab the daemon never knew is the normal end of a race, not an
/// error. The protocol has no error reply, so the only correct answer is
/// nothing at all.
#[tokio::test]
async fn closing_an_unknown_tab_is_silently_ignored() {
    let h = start().await;
    let mut client = Client::connect(&h.path).await;

    client
        .send(r#"{"type":"close_tab","v":1,"ts":"x","tab_id":"tab-never-existed"}"#)
        .await;
    client.expect_silence().await;

    // Still connected and still healthy afterwards.
    client
        .send(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#)
        .await;
    client.expect_silence().await;
}

/// A session whose tab claim never resolved still dies with the tab.
///
/// `Pending` exists precisely because a hook can arrive before `register_tab`.
/// Such a session was only ever going to bind to that one tab, so if the tab
/// closes first there is nothing left for it to bind to.
#[tokio::test]
async fn a_session_pending_on_the_closed_tab_dies_with_it() {
    let h = start().await;
    {
        // Hook first, tab never registered: the claim stays pending.
        let mut r = h.hub.registry().lock().unwrap();
        r.observe_hook(
            HookObservation::new("s1", Harness::ClaudeCode).with_tab_id("tab-1"),
            Utc::now(),
        );
    }

    let mut client = Client::connect(&h.path).await;
    client
        .send(r#"{"type":"close_tab","v":1,"ts":"x","tab_id":"tab-1"}"#)
        .await;

    let msg = client.next().await;
    assert_eq!(msg["type"], "session_ended");
    assert_eq!(msg["session_id"], "s1");
    assert_eq!(msg["reason"], "tab_closed");
}
