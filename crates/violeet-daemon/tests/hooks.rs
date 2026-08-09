//! Integration tests for the HTTP hook endpoint.
//!
//! These drive a real listener over real TCP with a real HTTP client, because
//! the properties that matter here are not unit-testable: that a permission
//! request genuinely blocks, that it genuinely unblocks when the app answers
//! over the *socket*, and that every way it can fail still produces a response.
//!
//! The recurring assertion is ADR-004's invariant: **no permission request goes
//! unanswered.** A test that hangs here is not a slow test, it is the bug the
//! whole design exists to prevent — so everything is wrapped in a deadline and
//! a timeout is a failure.

use std::time::Duration;

use violeet_daemon::hitl::HitlRegistry;
use violeet_daemon::http::{HookServer, HARNESS_HEADER, TAB_ID_HEADER};
use violeet_daemon::registry::{Registry, SessionState};
use violeet_daemon::socket::{Hub, SocketServer};
use chrono::Duration as ChronoDuration;
use http_body_util::BodyExt;
use hyper::{Request, StatusCode};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpStream, UnixStream};

/// Everything here should be near-instant. A hang is the failure mode under
/// test, so the deadline is short and hitting it fails the test.
const PATIENCE: Duration = Duration::from_secs(5);

struct Harnessed {
    hub: Hub,
    port: u16,
    socket_path: std::path::PathBuf,
    _dir: tempfile::TempDir,
}

/// Bind both servers on throwaway addresses. `hitl_timeout` is short in the
/// tests that need to watch it fire.
async fn start_with(hitl_timeout: ChronoDuration) -> Harnessed {
    let dir = tempfile::tempdir().expect("tempdir");
    let socket_path = dir.path().join("daemon.sock");

    let hub = Hub::with_hitl(
        Registry::with_default_ttl(),
        HitlRegistry::new(hitl_timeout),
    );

    let socket = SocketServer::bind(&socket_path, hub.clone()).expect("bind socket");
    tokio::spawn(socket.serve());

    let http = HookServer::bind(0, hub.clone()).await.expect("bind http");
    let port = http.port();
    tokio::spawn(http.serve());

    Harnessed {
        hub,
        port,
        socket_path,
        _dir: dir,
    }
}

async fn start() -> Harnessed {
    start_with(ChronoDuration::seconds(300)).await
}

struct HookResponse {
    status: StatusCode,
    body: serde_json::Value,
}

/// POST a hook payload, the way the installed `curl` would.
async fn post(
    port: u16,
    path: &str,
    tab_id: Option<&str>,
    payload: serde_json::Value,
) -> HookResponse {
    post_with_harness(port, path, tab_id, None, payload).await
}

async fn post_with_harness(
    port: u16,
    path: &str,
    tab_id: Option<&str>,
    harness: Option<&str>,
    payload: serde_json::Value,
) -> HookResponse {
    let stream = TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("connect to the hook endpoint");
    let io = hyper_util::rt::TokioIo::new(stream);
    let (mut sender, conn) = hyper::client::conn::http1::handshake(io)
        .await
        .expect("handshake");
    tokio::spawn(conn);

    let mut builder = Request::post(format!("http://127.0.0.1:{port}{path}"))
        .header("content-type", "application/json");
    // The installed hook always sends the header, empty or not.
    builder = builder.header(TAB_ID_HEADER, tab_id.unwrap_or(""));
    if let Some(h) = harness {
        builder = builder.header(HARNESS_HEADER, h);
    }

    let req = builder
        .body(payload.to_string())
        .expect("build the request");

    let res = sender.send_request(req).await.expect("send");
    let status = res.status();
    let bytes = res
        .into_body()
        .collect()
        .await
        .expect("read body")
        .to_bytes();
    let body = serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null);

    HookResponse { status, body }
}

/// A fake app on the Unix socket, so HITL can be answered the way the real app
/// answers it.
struct AppClient {
    reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: tokio::net::unix::OwnedWriteHalf,
}

impl AppClient {
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
        self.writer.write_all(b"\n").await.expect("newline");
    }

    async fn next(&mut self) -> serde_json::Value {
        let mut line = String::new();
        tokio::time::timeout(PATIENCE, self.reader.read_line(&mut line))
            .await
            .expect("timed out waiting for a socket message")
            .expect("read");
        serde_json::from_str(&line).expect("the daemon sent invalid JSON")
    }

    /// Read until a message of this type arrives, so a test asserting on
    /// `hitl_pending` is not tripped by the `session_registered` ahead of it.
    async fn next_of_type(&mut self, ty: &str) -> serde_json::Value {
        for _ in 0..16 {
            let msg = self.next().await;
            if msg["type"] == ty {
                return msg;
            }
        }
        panic!("no {ty} message arrived");
    }

    /// Read until a `session_updated` that actually carries a state for this
    /// session. The patches are sparse, so most of them say nothing about the
    /// lifecycle and would otherwise be mistaken for the one under test.
    async fn next_state_patch(&mut self, session_id: &str) -> serde_json::Value {
        for _ in 0..16 {
            let msg = self.next().await;
            if msg["type"] == "session_updated"
                && msg["session_id"] == session_id
                && !msg["state"].is_null()
            {
                return msg;
            }
        }
        panic!("no session_updated carrying a state arrived for {session_id}");
    }

    /// Round-trip a `request_snapshot` so the command sent before it is known to
    /// have been handled to the end.
    ///
    /// Inbound lines are read and dispatched in order on one task, so a reply to
    /// this one is proof the previous line finished — including the work that
    /// happens *after* its broadcast, which is exactly what these tests are
    /// asserting about.
    async fn settle(&mut self) {
        self.send(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#)
            .await;
        self.next_of_type("session_registered").await;
    }
}

/// What the registry believes about a session, read directly rather than off
/// the wire.
fn state_of(h: &Harnessed, session_id: &str) -> Option<SessionState> {
    h.hub
        .registry()
        .lock()
        .unwrap()
        .session(session_id)
        .map(|s| s.state())
}

fn session_start(session_id: &str, cwd: &str) -> serde_json::Value {
    serde_json::json!({
        "session_id": session_id,
        "hook_event_name": "SessionStart",
        "cwd": cwd,
        "transcript_path": "/tmp/transcript.jsonl",
    })
}

fn permission_payload(session_id: &str, command: &str) -> serde_json::Value {
    serde_json::json!({
        "session_id": session_id,
        "hook_event_name": "PermissionRequest",
        "cwd": "/repo",
        "tool_name": "Bash",
        "tool_input": { "command": command },
        "permission_suggestions": [{
            "type": "addRules",
            "rules": [{ "toolName": "Bash", "ruleContent": command }],
            "behavior": "allow",
            "destination": "localSettings"
        }],
    })
}

// ---------------------------------------------------------------------------
// Binding and reachability
// ---------------------------------------------------------------------------

/// The endpoint is for this machine's agents and nothing else.
#[tokio::test]
async fn the_hook_endpoint_binds_loopback_only() {
    let hub = Hub::new(Registry::with_default_ttl());
    let server = HookServer::bind(0, hub).await.expect("bind");
    let port = server.port();
    tokio::spawn(server.serve());

    // Reachable on loopback...
    assert!(TcpStream::connect(("127.0.0.1", port)).await.is_ok());

    // ...and nothing is listening on this host's external addresses. Binding
    // the same port on 0.0.0.0 must succeed, which it only can if the first
    // bind did not already claim every interface.
    let wildcard = tokio::net::TcpListener::bind(("0.0.0.0", port)).await;
    assert!(
        wildcard.is_ok(),
        "the hook endpoint claimed more than loopback"
    );
}

#[tokio::test]
async fn health_reports_what_the_daemon_is_holding() {
    let h = start().await;
    let res = post(h.port, "/health", None, serde_json::json!({})).await;
    // /health is a GET route; POSTing it is a 405, which is itself the assertion
    // that the router is wired rather than catching everything.
    assert_eq!(res.status, StatusCode::METHOD_NOT_ALLOWED);
}

// ---------------------------------------------------------------------------
// Informational hooks
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_session_start_hook_registers_a_session_and_announces_it() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let res = post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        session_start("s1", "/repo"),
    )
    .await;
    assert_eq!(res.status, StatusCode::NO_CONTENT);

    let msg = app.next_of_type("session_registered").await;
    assert_eq!(msg["session_id"], "s1");
    assert_eq!(msg["cwd"], "/repo");
    assert_eq!(msg["agent"], "claude-code");
    assert!(
        msg["tab_id"].is_null(),
        "the tab was never registered, so the claim is pending and publishes null"
    );
}

/// ADR-003's supported case: an agent started in iTerm, with no tab at all.
#[tokio::test]
async fn a_hook_with_no_tab_id_registers_an_unbound_session_rather_than_failing() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    // Header present but empty, which is what `curl -H "...: $VIOLEET_TAB_ID"`
    // sends when the variable is unset.
    let res = post(h.port, "/hook/event", None, session_start("s1", "/repo")).await;
    assert_eq!(res.status, StatusCode::NO_CONTENT);

    let msg = app.next_of_type("session_registered").await;
    assert_eq!(msg["session_id"], "s1");
    assert!(msg["tab_id"].is_null());
}

#[tokio::test]
async fn hook_events_move_the_session_through_its_states() {
    let h = start().await;

    post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        session_start("s1", "/repo"),
    )
    .await;
    assert_eq!(
        h.hub
            .registry()
            .lock()
            .unwrap()
            .session("s1")
            .unwrap()
            .state(),
        SessionState::Starting,
        "a session that has only started is Starting, not Idle"
    );

    post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        serde_json::json!({ "session_id": "s1", "hook_event_name": "PreToolUse" }),
    )
    .await;
    assert_eq!(
        h.hub
            .registry()
            .lock()
            .unwrap()
            .session("s1")
            .unwrap()
            .state(),
        SessionState::Working
    );

    post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        serde_json::json!({ "session_id": "s1", "hook_event_name": "Stop" }),
    )
    .await;
    assert_eq!(
        h.hub
            .registry()
            .lock()
            .unwrap()
            .session("s1")
            .unwrap()
            .state(),
        SessionState::Idle
    );
}

#[tokio::test]
async fn a_session_end_hook_ends_the_session_and_announces_it() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        session_start("s1", "/repo"),
    )
    .await;
    post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        serde_json::json!({ "session_id": "s1", "hook_event_name": "SessionEnd" }),
    )
    .await;

    let msg = app.next_of_type("session_ended").await;
    assert_eq!(msg["session_id"], "s1");
    assert_eq!(msg["reason"], "session_end_hook");
}

/// A newer Claude Code must not start failing hook calls against this daemon.
#[tokio::test]
async fn an_unknown_hook_event_is_accepted_as_activity() {
    let h = start().await;
    post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        session_start("s1", "/repo"),
    )
    .await;

    let res = post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        serde_json::json!({ "session_id": "s1", "hook_event_name": "InventedNextYear" }),
    )
    .await;
    assert_eq!(res.status, StatusCode::NO_CONTENT);

    // Still Starting: an event we do not understand is liveness, not a state.
    assert_eq!(
        h.hub
            .registry()
            .lock()
            .unwrap()
            .session("s1")
            .unwrap()
            .state(),
        SessionState::Starting
    );
}

#[tokio::test]
async fn garbage_and_empty_payloads_are_dropped_rather_than_failing_the_hook() {
    let h = start().await;

    for payload in [
        serde_json::json!({}),
        serde_json::json!({ "session_id": "" }),
        serde_json::json!({ "hook_event_name": "Stop" }),
    ] {
        let res = post(h.port, "/hook/event", Some("tab-1"), payload).await;
        assert_eq!(
            res.status,
            StatusCode::NO_CONTENT,
            "an unusable payload must not surface as an error in the user's terminal"
        );
    }
    assert_eq!(h.hub.registry().lock().unwrap().sessions().count(), 0);
}

#[tokio::test]
async fn an_unknown_harness_header_still_produces_a_card() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    post_with_harness(
        h.port,
        "/hook/event",
        Some("tab-1"),
        Some("some-new-agent"),
        session_start("s1", "/repo"),
    )
    .await;

    let msg = app.next_of_type("session_registered").await;
    assert_eq!(
        msg["agent"], "unknown",
        "an unrecognised harness is rendered generically, not dropped"
    );
}

// ---------------------------------------------------------------------------
// HITL: the reason the product exists
// ---------------------------------------------------------------------------

/// The headline path: the card is answered from the sidebar and the agent gets
/// a real decision without the user touching the tab.
#[tokio::test]
async fn the_app_can_answer_a_permission_request_and_the_agent_gets_the_decision() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "rm -rf build/"),
        )
        .await
    });

    let pending = app.next_of_type("hitl_pending").await;
    assert_eq!(pending["session_id"], "s1");
    assert_eq!(pending["tool_name"], "Bash");
    assert_eq!(pending["tool_input"]["command"], "rm -rf build/");
    assert_eq!(
        pending["permission_suggestions"][0]["type"], "addRules",
        "permission_suggestions is forwarded verbatim, not normalised"
    );
    assert!(!pending["expires_at"].as_str().unwrap().is_empty());

    let hitl_id = pending["hitl_id"].as_str().unwrap().to_string();
    app.send(&format!(
        r#"{{"type":"resolve_hitl","v":1,"ts":"x","hitl_id":"{hitl_id}","decision":{{"behavior":"allow","reason":"go ahead"}}}}"#
    ))
    .await;

    let resolved = app.next_of_type("hitl_resolved").await;
    assert_eq!(resolved["hitl_id"], hitl_id);
    assert_eq!(resolved["origin"], "app");
    assert_eq!(resolved["decision"], "allow");

    let res = tokio::time::timeout(PATIENCE, agent)
        .await
        .expect("the agent must not be left hanging")
        .expect("task");
    assert_eq!(res.status, StatusCode::OK);

    let out = &res.body["hookSpecificOutput"];
    assert_eq!(out["hookEventName"], "PermissionRequest");
    // The shape the ADR-004 spike measured, not the one the docs describe.
    // See docs/spikes/scripts/hook-allow-0.sh.
    assert_eq!(out["decision"]["behavior"], "allow");
    assert_eq!(out["decision"]["reason"], "go ahead");
}

#[tokio::test]
async fn a_denial_reaches_the_agent_as_a_denial() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "rm -rf /"),
        )
        .await
    });

    let hitl_id = app.next_of_type("hitl_pending").await["hitl_id"]
        .as_str()
        .unwrap()
        .to_string();
    app.send(&format!(
        r#"{{"type":"resolve_hitl","v":1,"ts":"x","hitl_id":"{hitl_id}","decision":{{"behavior":"deny","reason":"absolutely not"}}}}"#
    ))
    .await;

    let res = tokio::time::timeout(PATIENCE, agent)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(res.status, StatusCode::OK);
    assert_eq!(
        res.body["hookSpecificOutput"]["decision"]["behavior"],
        "deny"
    );
}

/// ADR-004: the human answered in the terminal, and we find out because the
/// tool call completed. `500`, and `decision: null` — we do not know what they
/// chose, and the protocol refuses to guess.
#[tokio::test]
async fn the_human_winning_in_the_terminal_resolves_the_card_without_a_decision() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "ls"),
        )
        .await
    });

    let pending = app.next_of_type("hitl_pending").await;
    let hitl_id = pending["hitl_id"].as_str().unwrap().to_string();

    // The tool ran, so the human must have allowed it in the tab.
    post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        serde_json::json!({
            "session_id": "s1",
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_input": { "command": "ls" },
        }),
    )
    .await;

    let resolved = app.next_of_type("hitl_resolved").await;
    assert_eq!(resolved["hitl_id"], hitl_id);
    assert_eq!(resolved["origin"], "tui");
    assert!(
        resolved["decision"].is_null(),
        "when the terminal wins we genuinely do not know the outcome"
    );

    let res = tokio::time::timeout(PATIENCE, agent)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        res.status,
        StatusCode::INTERNAL_SERVER_ERROR,
        "500 is the measured-safe answer: the agent had already moved on"
    );
}

/// A `PostToolUse` for a call nobody was blocked on must not clear a card.
#[tokio::test]
async fn an_unrelated_post_tool_use_does_not_resolve_a_pending_request() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let _agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "rm -rf build/"),
        )
        .await
    });

    app.next_of_type("hitl_pending").await;

    post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        serde_json::json!({
            "session_id": "s1",
            "hook_event_name": "PostToolUse",
            "tool_name": "Read",
            "tool_input": { "file_path": "/repo/README.md" },
        }),
    )
    .await;

    assert_eq!(
        h.hub.hitl().lock().unwrap().len(),
        1,
        "a different tool call must not clear the card"
    );
}

/// The daemon owns the deadline, because ADR-004 measured that Claude Code does
/// not. This is the test that proves an unanswered request still ends.
#[tokio::test]
async fn a_request_nobody_answers_times_out_into_a_500() {
    let h = start_with(ChronoDuration::milliseconds(150)).await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "sleep 600"),
        )
        .await
    });

    let resolved = app.next_of_type("hitl_resolved").await;
    assert_eq!(resolved["origin"], "timeout");
    assert!(resolved["decision"].is_null());

    let res = tokio::time::timeout(PATIENCE, agent)
        .await
        .expect("a timed-out request must still answer; silence is the bug")
        .unwrap();
    assert_eq!(res.status, StatusCode::INTERNAL_SERVER_ERROR);
    assert!(h.hub.hitl().lock().unwrap().is_empty());
}

/// Resolving twice is the normal end of the race, not an error.
#[tokio::test]
async fn a_second_resolution_for_the_same_request_changes_nothing() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "ls"),
        )
        .await
    });

    let hitl_id = app.next_of_type("hitl_pending").await["hitl_id"]
        .as_str()
        .unwrap()
        .to_string();

    for _ in 0..2 {
        app.send(&format!(
            r#"{{"type":"resolve_hitl","v":1,"ts":"x","hitl_id":"{hitl_id}","decision":{{"behavior":"allow"}}}}"#
        ))
        .await;
    }

    let resolved = app.next_of_type("hitl_resolved").await;
    assert_eq!(resolved["origin"], "app");

    tokio::time::timeout(PATIENCE, agent)
        .await
        .unwrap()
        .unwrap();

    // Exactly one hitl_resolved: the second resolve found nothing to resolve.
    let mut app2 = AppClient::connect(&h.socket_path).await;
    app2.send(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#)
        .await;
    let msg = app2.next().await;
    assert_eq!(
        msg["type"], "session_registered",
        "the snapshot must not still contain a hitl_pending"
    );
}

/// A malformed permission payload is the one case where dropping it silently
/// would hang the agent. It gets a `500` like every other failure.
#[tokio::test]
async fn an_unusable_permission_payload_still_answers() {
    let h = start().await;

    for payload in [
        serde_json::json!({}),
        serde_json::json!({ "session_id": "s1" }),
        serde_json::json!({ "session_id": "", "tool_name": "Bash" }),
    ] {
        let res = tokio::time::timeout(
            PATIENCE,
            post(h.port, "/hook/permission-request", Some("tab-1"), payload),
        )
        .await
        .expect("silence is never an acceptable answer to a permission request");

        assert_eq!(res.status, StatusCode::INTERNAL_SERVER_ERROR);
    }
}

/// A `PermissionRequest` hook installed against the informational route is a
/// misconfiguration, and the safe answer is the fallback, not a cheerful 204.
#[tokio::test]
async fn a_permission_request_on_the_wrong_route_answers_500_rather_than_204() {
    let h = start().await;
    let res = post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        permission_payload("s1", "ls"),
    )
    .await;
    assert_eq!(res.status, StatusCode::INTERNAL_SERVER_ERROR);
}

// ---------------------------------------------------------------------------
// HITL: the wait has to end in the session's own state, not only in the card
// ---------------------------------------------------------------------------
//
// The app reads "waiting for you" from two independent places: an open request,
// and `state == "hitl"`. `hitl_resolved` clears the first. These tests are here
// because for a long time nothing cleared the second, and the card kept its lit
// border and its place in the top band of the board for the rest of the
// session's life.

/// The headline of LAB-8: an answer from the panel ends the wait in the state
/// too, on the same turn, without waiting for the next hook to nudge it.
#[tokio::test]
async fn answering_from_the_panel_takes_the_session_out_of_waiting() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "ls"),
        )
        .await
    });

    let hitl_id = app.next_of_type("hitl_pending").await["hitl_id"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(
        state_of(&h, "s1"),
        Some(SessionState::WaitingHitl),
        "the request is open, so the state is the true one to be in"
    );

    app.send(&format!(
        r#"{{"type":"resolve_hitl","v":1,"ts":"x","hitl_id":"{hitl_id}","decision":{{"behavior":"allow"}}}}"#
    ))
    .await;

    let patch = app.next_state_patch("s1").await;
    assert_eq!(
        patch["state"], "idle",
        "the answer has to reach the app as a state, not only as a resolved card"
    );
    assert_eq!(state_of(&h, "s1"), Some(SessionState::Idle));

    tokio::time::timeout(PATIENCE, agent)
        .await
        .unwrap()
        .unwrap();
}

/// A denial is an answer. Same ending.
#[tokio::test]
async fn a_denial_ends_the_wait_the_same_way_an_approval_does() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "rm -rf /"),
        )
        .await
    });

    let hitl_id = app.next_of_type("hitl_pending").await["hitl_id"]
        .as_str()
        .unwrap()
        .to_string();
    app.send(&format!(
        r#"{{"type":"resolve_hitl","v":1,"ts":"x","hitl_id":"{hitl_id}","decision":{{"behavior":"deny"}}}}"#
    ))
    .await;

    assert_eq!(app.next_state_patch("s1").await["state"], "idle");
    assert_eq!(state_of(&h, "s1"), Some(SessionState::Idle));

    tokio::time::timeout(PATIENCE, agent)
        .await
        .unwrap()
        .unwrap();
}

/// Nobody answered and the deadline passed. The human is no longer being waited
/// on either way, so the card and the state both have to say so.
#[tokio::test]
async fn a_request_that_times_out_also_ends_the_wait() {
    let h = start_with(ChronoDuration::milliseconds(150)).await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "sleep 600"),
        )
        .await
    });

    assert_eq!(app.next_of_type("hitl_resolved").await["origin"], "timeout");
    assert_eq!(app.next_state_patch("s1").await["state"], "idle");
    assert_eq!(state_of(&h, "s1"), Some(SessionState::Idle));

    tokio::time::timeout(PATIENCE, agent)
        .await
        .unwrap()
        .unwrap();
}

/// The sweeper's path, which announces a resolution the registry already
/// performed rather than performing one. It ends the wait too — driven here
/// directly, because the deadline it reads is the one thing a test can move.
#[tokio::test]
async fn the_expiry_sweeper_ends_the_wait_as_well() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "sleep 600"),
        )
        .await
    });

    app.next_of_type("hitl_pending").await;
    let past_every_deadline = chrono::Utc::now() + ChronoDuration::hours(1);
    assert_eq!(h.hub.expire_hitl(past_every_deadline), 1);

    assert_eq!(app.next_of_type("hitl_resolved").await["origin"], "timeout");
    assert_eq!(app.next_state_patch("s1").await["state"], "idle");
    assert_eq!(state_of(&h, "s1"), Some(SessionState::Idle));

    tokio::time::timeout(PATIENCE, agent)
        .await
        .unwrap()
        .unwrap();
}

/// The case that decides the fix. One session can hold more than one open
/// request, and answering one of them is not the end of the wait: the other is
/// still parked, the human is still being waited on, and clearing the state
/// there would be the same lie pointing the other way.
#[tokio::test]
async fn answering_one_of_two_open_requests_leaves_the_session_waiting() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let first_agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "ls"),
        )
        .await
    });
    let first = app.next_of_type("hitl_pending").await["hitl_id"]
        .as_str()
        .unwrap()
        .to_string();

    // Opened after the first is known to be parked, so the ids below cannot be
    // attributed to the wrong request.
    let second_agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "rm -rf build/"),
        )
        .await
    });
    let second = app.next_of_type("hitl_pending").await["hitl_id"]
        .as_str()
        .unwrap()
        .to_string();
    assert_ne!(first, second);

    app.send(&format!(
        r#"{{"type":"resolve_hitl","v":1,"ts":"x","hitl_id":"{first}","decision":{{"behavior":"allow"}}}}"#
    ))
    .await;
    app.settle().await;

    assert_eq!(
        h.hub.hitl().lock().unwrap().len(),
        1,
        "the second request is still open"
    );
    assert_eq!(
        state_of(&h, "s1"),
        Some(SessionState::WaitingHitl),
        "one answer must not clear a signal the other request is still holding up"
    );

    app.send(&format!(
        r#"{{"type":"resolve_hitl","v":1,"ts":"x","hitl_id":"{second}","decision":{{"behavior":"allow"}}}}"#
    ))
    .await;
    app.settle().await;

    assert_eq!(
        state_of(&h, "s1"),
        Some(SessionState::Idle),
        "with nothing left pending, the wait is over"
    );

    for agent in [first_agent, second_agent] {
        tokio::time::timeout(PATIENCE, agent)
            .await
            .unwrap()
            .unwrap();
    }
}

/// The reconnect corollary. The snapshot replays `session.state()`, so a state
/// left behind is not a transient: every client that starts up afterwards is
/// told the session is waiting on a question answered long ago.
#[tokio::test]
async fn a_client_connecting_after_the_answer_is_not_told_the_session_is_waiting() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "ls"),
        )
        .await
    });

    let hitl_id = app.next_of_type("hitl_pending").await["hitl_id"]
        .as_str()
        .unwrap()
        .to_string();
    app.send(&format!(
        r#"{{"type":"resolve_hitl","v":1,"ts":"x","hitl_id":"{hitl_id}","decision":{{"behavior":"allow"}}}}"#
    ))
    .await;
    app.settle().await;

    let mut fresh = AppClient::connect(&h.socket_path).await;
    fresh
        .send(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#)
        .await;
    let telemetry = fresh.next_state_patch("s1").await;
    assert_ne!(
        telemetry["state"], "hitl",
        "a session with nothing pending must never be replayed as waiting"
    );
    assert_eq!(telemetry["state"], "idle");

    tokio::time::timeout(PATIENCE, agent)
        .await
        .unwrap()
        .unwrap();
}

// ---------------------------------------------------------------------------
// Ordering and snapshot
// ---------------------------------------------------------------------------

/// `docs/PROTOCOL.md`: a session with a pending HITL that ends must emit
/// `hitl_resolved` before `session_ended`, so the app never has to
/// garbage-collect an orphaned card.
#[tokio::test]
async fn a_session_ending_clears_its_card_before_announcing_the_end() {
    let h = start().await;
    let mut app = AppClient::connect(&h.socket_path).await;

    let port = h.port;
    let _agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "ls"),
        )
        .await
    });
    app.next_of_type("hitl_pending").await;

    post(
        h.port,
        "/hook/event",
        Some("tab-1"),
        serde_json::json!({ "session_id": "s1", "hook_event_name": "SessionEnd" }),
    )
    .await;

    // Order is the assertion, so these are read in sequence rather than filtered.
    let first = app.next().await;
    assert_eq!(first["type"], "hitl_resolved");
    assert_eq!(first["origin"], "daemon_error");

    let second = app.next().await;
    assert_eq!(second["type"], "session_ended");
    assert_eq!(second["reason"], "session_end_hook");
}

/// A client that connects mid-flight gets the blocked session *and* the card.
#[tokio::test]
async fn a_late_client_sees_pending_requests_in_its_snapshot() {
    let h = start().await;

    let port = h.port;
    let _agent = tokio::spawn(async move {
        post(
            port,
            "/hook/permission-request",
            Some("tab-1"),
            permission_payload("s1", "ls"),
        )
        .await
    });

    // Wait for the request to actually be parked before connecting.
    for _ in 0..50 {
        if !h.hub.hitl().lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let mut app = AppClient::connect(&h.socket_path).await;
    app.send(r#"{"type":"request_snapshot","v":1,"ts":"x"}"#)
        .await;

    // Drain until the pending request arrives, remembering what came before it.
    //
    // Asserted by ordering rather than by index: the snapshot also replays a
    // `session_updated` per session to restore telemetry that
    // `session_registered` has no fields for, and a positional assertion would
    // break every time the snapshot gains a message. What the protocol
    // actually promises is that a client never meets a `hitl_pending` for a
    // session it has not been told about.
    let mut seen_registration = false;
    let mut hitl = None;
    for _ in 0..8 {
        let message = app.next().await;
        match message["type"].as_str() {
            Some("session_registered") => seen_registration = true,
            Some("hitl_pending") => {
                hitl = Some(message);
                break;
            }
            _ => {}
        }
    }

    let hitl = hitl.expect("the pending request must be replayed");
    assert!(
        seen_registration,
        "sessions replay before the requests that reference them"
    );
    assert_eq!(hitl["session_id"], "s1");
}
