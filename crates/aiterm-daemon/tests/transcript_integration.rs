//! The wave-2 integration: transcript telemetry reaching the socket.
//!
//! The property worth testing is not "the parser works" — `aiterm-transcript`
//! has its own tests for that. It is the thing neither source can do alone:
//! deciding whether a tool in flight means `working` or `waiting_hitl`.

use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use aiterm_daemon::registry::{Harness, HookObservation, Registry, SessionState};
use aiterm_daemon::socket::Hub;
use aiterm_daemon::transcript;

fn temp(name: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!(
        "aiterm-daemon-tx-{}-{}-{name}.jsonl",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0)
    ));
    let _ = std::fs::remove_file(&p);
    p
}

fn append(path: &PathBuf, text: &str) {
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .unwrap();
    f.write_all(text.as_bytes()).unwrap();
    f.flush().unwrap();
}

/// An assistant line that invokes a tool and never gets a result: a tool in
/// flight, which is the ambiguous case.
fn tool_call(id: &str, tool_id: &str) -> String {
    format!(
        r#"{{"type":"assistant","uuid":"u","sessionId":"s","timestamp":"2026-08-01T10:00:00Z","message":{{"id":"{id}","model":"claude-sonnet-5","content":[{{"type":"tool_use","id":"{tool_id}","name":"Bash","input":{{"command":"cargo test"}}}}],"usage":{{"input_tokens":1000,"cache_read_input_tokens":50000,"output_tokens":40}}}}}}
"#
    )
}

fn hub_with_session(session_id: &str) -> Hub {
    let hub = Hub::new(Registry::with_default_ttl());
    let obs = HookObservation::new(session_id, Harness::ClaudeCode);
    hub.observe_hook(obs, chrono::Utc::now());
    hub
}

fn state_of(hub: &Hub, session_id: &str) -> Option<SessionState> {
    let registry = hub.registry().lock().unwrap();
    registry.session(session_id).map(|s| s.state())
}

/// Wait for a condition, or give up. The reader runs on its own thread with a
/// debounce, so the test cannot assert synchronously.
fn eventually(mut check: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if check() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

/// A tool in flight with **no** permission request open means the agent is
/// working.
#[test]
fn a_tool_in_flight_without_a_pending_hitl_reads_as_working() {
    let path = temp("working");
    append(&path, &tool_call("m1", "toolu_1"));

    let hub = hub_with_session("s-working");
    transcript::follow(&hub, "s-working", &path);

    // `follow` reads from the end, so the line already there is history.
    // Appending is what the reader must react to.
    append(&path, &tool_call("m2", "toolu_2"));

    assert!(
        eventually(|| state_of(&hub, "s-working") == Some(SessionState::Working)),
        "expected working, got {:?}",
        state_of(&hub, "s-working")
    );

    let registry = hub.registry().lock().unwrap();
    let session = registry.session("s-working").unwrap();
    assert_eq!(session.model.as_deref(), Some("claude-sonnet-5"));
    assert_eq!(session.tokens.context_window_used_tokens, Some(51_000));
    assert_eq!(
        session.tokens.context_window_size_tokens,
        Some(200_000),
        "resolved from the model name, since no transcript field carries it"
    );
    assert!(session
        .last_action
        .as_deref()
        .is_some_and(|a| a.starts_with("Bash")));
    drop(registry);

    let _ = std::fs::remove_file(&path);
}

/// The same transcript, with a permission request open, reads as blocked.
///
/// This is the assertion the whole integration exists for: the *file is
/// identical* in both tests, and only the daemon's own knowledge differs.
#[test]
fn the_same_transcript_reads_as_waiting_hitl_when_a_request_is_open() {
    let path = temp("hitl");
    append(&path, &tool_call("m1", "toolu_1"));

    let hub = hub_with_session("s-hitl");

    // Open a permission request for this session before following, so the
    // reader's first publish already sees it.
    let (_request, _rx) = hub.open_hitl(
        aiterm_daemon::hitl::NewHitl {
            session_id: "s-hitl".to_string(),
            tab_id: None,
            tool_name: "Bash".to_string(),
            tool_input: serde_json::json!({"command": "cargo test"}),
            permission_suggestions: serde_json::Value::Array(Vec::new()),
        },
        chrono::Utc::now(),
    );
    assert!(hub.has_pending_hitl("s-hitl"));

    transcript::follow(&hub, "s-hitl", &path);
    append(&path, &tool_call("m2", "toolu_2"));

    assert!(
        eventually(|| state_of(&hub, "s-hitl") == Some(SessionState::WaitingHitl)),
        "expected waiting_hitl, got {:?}",
        state_of(&hub, "s-hitl")
    );

    let _ = std::fs::remove_file(&path);
}

/// No tool in flight: the transcript has no opinion about the lifecycle and
/// must not overwrite what the hooks established.
#[test]
fn a_transcript_with_no_tool_in_flight_leaves_the_state_alone() {
    let path = temp("quiet");
    let hub = hub_with_session("s-quiet");

    // Drive the session to Idle through the ordinary hook path.
    let mut obs = HookObservation::new("s-quiet", Harness::ClaudeCode);
    obs.state = Some(SessionState::Idle);
    hub.observe_hook(obs, chrono::Utc::now());
    assert_eq!(state_of(&hub, "s-quiet"), Some(SessionState::Idle));

    transcript::follow(&hub, "s-quiet", &path);
    // A plain assistant turn: usage, no tool call.
    append(
        &path,
        r#"{"type":"assistant","uuid":"u","sessionId":"s","message":{"id":"m1","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5}}}
"#,
    );

    // The telemetry must land...
    assert!(
        eventually(|| {
            let r = hub.registry().lock().unwrap();
            r.session("s-quiet")
                .and_then(|s| s.tokens.cumulative_output_tokens)
                == Some(5)
        }),
        "telemetry never arrived"
    );
    // ...without the state moving.
    assert_eq!(
        state_of(&hub, "s-quiet"),
        Some(SessionState::Idle),
        "a transcript with no tool in flight must not assert a lifecycle state"
    );

    let _ = std::fs::remove_file(&path);
}

/// Following the same path twice is free, and following is released on end.
#[test]
fn following_is_idempotent_and_released_when_the_session_ends() {
    let path = temp("lifecycle");
    let hub = hub_with_session("s-life");

    transcript::follow(&hub, "s-life", &path);
    transcript::follow(&hub, "s-life", &path);
    transcript::follow(&hub, "s-life", &path);

    assert_eq!(
        hub.transcripts().lock().unwrap().len(),
        1,
        "hooks carry transcript_path on nearly every event; re-following must be free"
    );

    hub.publish_session_ended(
        "s-life",
        None,
        aiterm_daemon::wire::EndReason::TabClosed,
        chrono::Utc::now(),
    );
    assert!(
        hub.transcripts().lock().unwrap().is_empty(),
        "an ended session must not keep a thread and a filesystem watch alive"
    );

    let _ = std::fs::remove_file(&path);
}

/// A file the daemon cannot watch costs telemetry, not the session.
#[test]
fn an_unwatchable_transcript_does_not_take_the_session_down() {
    let hub = hub_with_session("s-missing");
    let missing = PathBuf::from("/nonexistent-directory-aiterm/transcript.jsonl");

    transcript::follow(&hub, "s-missing", &missing);

    assert!(
        state_of(&hub, "s-missing").is_some(),
        "the session must survive a transcript we cannot follow"
    );
}
