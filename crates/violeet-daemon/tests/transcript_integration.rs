//! The wave-2 integration: transcript telemetry reaching the socket.
//!
//! The property worth testing is not "the parser works" — `violeet-transcript`
//! has its own tests for that. It is the thing neither source can do alone:
//! deciding whether a tool in flight means `working` or `waiting_hitl`.

use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use violeet_daemon::registry::{Harness, HookObservation, Registry, SessionState};
use violeet_daemon::socket::Hub;
use violeet_daemon::transcript;

fn temp(name: &str) -> PathBuf {
    let p = std::env::temp_dir().join(format!(
        "violeet-daemon-tx-{}-{}-{name}.jsonl",
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

fn hub_with_cursor_session(session_id: &str) -> Hub {
    let hub = Hub::new(Registry::with_default_ttl());
    let obs = HookObservation::new(session_id, Harness::Cursor);
    hub.observe_hook(obs, chrono::Utc::now());
    hub
}

/// Cursor agent JSONL: `role`/`message`, `Shell` instead of `Bash`.
fn cursor_tool_call(id: &str) -> String {
    format!(
        r#"{{"role":"assistant","timestamp":"2026-08-09T20:00:00Z","message":{{"id":"{id}","model":"composer-2","content":[{{"type":"tool_use","name":"Shell","input":{{"command":"cargo test","description":"run tests"}}}}],"usage":{{"input_tokens":1000,"cache_read_input_tokens":50000,"output_tokens":40}}}}}}
"#
    )
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
    transcript::follow(&hub, "s-working", &path, Harness::ClaudeCode);

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
        None,
        "the window size is not in the transcript and is not guessed from the \
         model name — a real claude-opus-5 session was measured at 1M while a \
         lookup table claimed 200k. It arrives from the status line payload or \
         it stays unknown."
    );
    assert!(session
        .last_action
        .as_deref()
        .is_some_and(|a| a.starts_with("Bash")));
    drop(registry);

    let _ = std::fs::remove_file(&path);
}

/// Cursor harness selects the Cursor reader, not Claude Code's `type` lines.
#[test]
fn cursor_harness_populates_telemetry_from_cursor_jsonl() {
    let path = temp("cursor");
    append(&path, &cursor_tool_call("gen-1"));

    let hub = hub_with_cursor_session("s-cursor");
    transcript::follow(&hub, "s-cursor", &path, Harness::Cursor);

    append(&path, &cursor_tool_call("gen-2"));

    // Wait on the *second* line's arrival, not on something the first line
    // already satisfies. Both appended lines produce a `Shell` last_action, so
    // polling for that returned as soon as line one was read and the token
    // assertion below then raced the second read — passing on an idle machine
    // and failing under load. The cumulative total is the only condition here
    // that line one alone cannot meet.
    assert!(
        eventually(|| {
            hub.registry()
                .lock()
                .unwrap()
                .session("s-cursor")
                .is_some_and(|s| s.tokens.cumulative_output_tokens == Some(80))
        }),
        "expected both lines folded in, got {:?}",
        hub.registry()
            .lock()
            .unwrap()
            .session("s-cursor")
            .map(|s| (s.tokens.cumulative_output_tokens, s.last_action.clone()))
    );

    let registry = hub.registry().lock().unwrap();
    let session = registry.session("s-cursor").unwrap();
    assert_eq!(session.model.as_deref(), Some("composer-2"));
    assert_eq!(session.tokens.context_window_used_tokens, Some(51_000));
    assert_eq!(session.tokens.cumulative_output_tokens, Some(80));
    assert!(session
        .last_action
        .as_deref()
        .is_some_and(|a| a.starts_with("Shell")));
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
        violeet_daemon::hitl::NewHitl {
            session_id: "s-hitl".to_string(),
            tab_id: None,
            tool_name: "Bash".to_string(),
            tool_input: serde_json::json!({"command": "cargo test"}),
            permission_suggestions: serde_json::Value::Array(Vec::new()),
        },
        chrono::Utc::now(),
    );
    assert!(hub.has_pending_hitl("s-hitl"));

    transcript::follow(&hub, "s-hitl", &path, Harness::ClaudeCode);
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

    transcript::follow(&hub, "s-quiet", &path, Harness::ClaudeCode);
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

    transcript::follow(&hub, "s-life", &path, Harness::ClaudeCode);
    transcript::follow(&hub, "s-life", &path, Harness::ClaudeCode);
    transcript::follow(&hub, "s-life", &path, Harness::ClaudeCode);

    assert_eq!(
        hub.transcripts().lock().unwrap().len(),
        1,
        "hooks carry transcript_path on nearly every event; re-following must be free"
    );

    hub.publish_session_ended(
        "s-life",
        None,
        violeet_daemon::wire::EndReason::TabClosed,
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
    let missing = PathBuf::from("/nonexistent-directory-violeet/transcript.jsonl");

    transcript::follow(&hub, "s-missing", &missing, Harness::ClaudeCode);

    assert!(
        state_of(&hub, "s-missing").is_some(),
        "the session must survive a transcript we cannot follow"
    );
}

/// Lines written after `SessionEnd` still land on the card.
///
/// Regression test for a bug the real thing exposed and no unit test would
/// have: Claude Code writes a session's last lines *after* its SessionEnd hook
/// fires. The daemon used to drop the watch on the hook, so the card kept
/// numbers that were wrong and looked final — measured at 345 output tokens
/// against 489 in the file. `forget_transcript` now reads once more first.
#[test]
fn the_final_lines_are_read_before_the_watch_is_dropped() {
    let path = temp("final-flush");
    let hub = hub_with_session("s-final");

    transcript::follow(&hub, "s-final", &path, Harness::ClaudeCode);
    append(&path, &tool_call("m1", "toolu_1"));

    assert!(
        eventually(|| {
            let r = hub.registry().lock().unwrap();
            r.session("s-final")
                .and_then(|s| s.tokens.cumulative_output_tokens)
                == Some(40)
        }),
        "the first turn never landed"
    );

    // The last write races the end of the session, exactly as Claude Code
    // does it: appended with no chance for the watcher to have seen it.
    append(&path, &tool_call("m2", "toolu_2"));
    hub.publish_session_ended(
        "s-final",
        None,
        violeet_daemon::wire::EndReason::SessionEndHook,
        chrono::Utc::now(),
    );

    let registry = hub.registry().lock().unwrap();
    let session = registry.session("s-final").expect("session still in the registry");
    assert_eq!(
        session.tokens.cumulative_output_tokens,
        Some(80),
        "the line written after SessionEnd must be counted; a card that stops \
         at 40 is not stale, it is wrong while looking final"
    );
    drop(registry);

    assert!(hub.transcripts().lock().unwrap().is_empty(), "and the watch is released");
    let _ = std::fs::remove_file(&path);
}

// ---------------------------------------------------------------------------
// Background agents: waiting on one is not being free
// ---------------------------------------------------------------------------

/// The launch of a background agent: a `tool_use`, then the acknowledgement that
/// closes it immediately. Both lines are the shape found under
/// `~/.claude/projects`, which is why the session ends up with nothing in flight
/// while the agent runs.
///
/// **Timestamped relative to now, and that is not cosmetic.** The count applies
/// an age limit against wall clock, so a launch pinned to a literal date is an
/// abandoned launch the day after it is written, and this test would have started
/// failing on its own. `minutes_ago` is what each case is actually about.
fn agent_launch_aged(msg_id: &str, tool_id: &str, agent_id: &str, minutes_ago: i64) -> String {
    let at = (chrono::Utc::now() - chrono::Duration::minutes(minutes_ago)).to_rfc3339();
    format!(
        r#"{{"type":"assistant","uuid":"u","sessionId":"s","timestamp":"{at}","message":{{"id":"{msg_id}","model":"claude-opus-5","content":[{{"type":"tool_use","id":"{tool_id}","name":"Agent","input":{{"subagent_type":"code-reviewer"}}}}],"usage":{{"input_tokens":10,"output_tokens":5}}}}}}
{{"type":"user","uuid":"u2","sessionId":"s","timestamp":"{at}","message":{{"role":"user","content":[{{"tool_use_id":"{tool_id}","type":"tool_result","content":"Async agent launched successfully."}}]}},"toolUseResult":{{"isAsync":true,"status":"async_launched","agentId":"{agent_id}"}}}}
"#
    )
}

/// A launch that happened a moment ago: the ordinary case.
fn agent_launch(msg_id: &str, tool_id: &str, agent_id: &str) -> String {
    agent_launch_aged(msg_id, tool_id, agent_id, 0)
}

/// The agent reporting in.
fn agent_notification(tool_id: &str, agent_id: &str) -> String {
    let at = chrono::Utc::now().to_rfc3339();
    format!(
        r#"{{"type":"user","uuid":"u3","sessionId":"s","timestamp":"{at}","message":{{"role":"user","content":"<task-notification>\n<task-id>{agent_id}</task-id>\n<tool-use-id>{tool_id}</tool-use-id>\n<status>completed</status>\n<summary>Agent finished</summary>"}}}}
"#
    )
}

/// The same notification, delivered as a queued command on an `attachment` line.
/// 130 of 358 deliveries measured on the reference corpus arrive this way.
fn agent_notification_as_attachment(tool_id: &str, agent_id: &str) -> String {
    let at = chrono::Utc::now().to_rfc3339();
    format!(
        r#"{{"type":"attachment","uuid":"u4","sessionId":"s","timestamp":"{at}","attachment":{{"type":"queued_command","commandMode":"task-notification","prompt":"<task-notification>\n<task-id>{agent_id}</task-id>\n<tool-use-id>{tool_id}</tool-use-id>\n<status>completed</status>\n<summary>Agent finished</summary>\n</task-notification>"}}}}
"#
    )
}

fn pending_agents(hub: &Hub, session_id: &str) -> Option<Option<u64>> {
    let registry = hub.registry().lock().unwrap();
    registry.session(session_id).map(|s| s.pending_agents)
}

/// The bug, end to end: the session stopped, the hooks say `idle`, and the count
/// is what says somebody is still working for it.
///
/// Note what is *not* asserted: that the state changed. `idle` is the contract —
/// the `Stop` hook did fire and nothing is computing in the foreground. What
/// changes is that the app can now tell this apart from a session that wants its
/// user, which it could not do before.
#[test]
fn a_session_waiting_on_an_agent_reports_it_while_still_reading_idle() {
    let path = temp("pending-agents");
    let hub = hub_with_session("s-agents");
    transcript::follow(&hub, "s-agents", &path, Harness::ClaudeCode);

    append(&path, &agent_launch("m1", "toolu_a", "agent_a"));
    append(&path, &agent_launch("m2", "toolu_b", "agent_b"));

    assert!(
        eventually(|| pending_agents(&hub, "s-agents") == Some(Some(2))),
        "expected two pending agents, got {:?}",
        pending_agents(&hub, "s-agents")
    );

    // The `Stop` hook lands while both agents are still out. This is the exact
    // moment the sidebar used to show the card as free.
    let mut stop = HookObservation::new("s-agents", Harness::ClaudeCode);
    stop.state = Some(SessionState::Idle);
    hub.observe_hook(stop, chrono::Utc::now());

    assert_eq!(state_of(&hub, "s-agents"), Some(SessionState::Idle));
    assert_eq!(
        pending_agents(&hub, "s-agents"),
        Some(Some(2)),
        "the hook says idle and the count says two: both are true"
    );

    let _ = std::fs::remove_file(&path);
}

/// **No `SubagentStop` hook is delivered anywhere in this test**, and the count
/// still comes back to zero, because the number is derived from the file rather
/// than decremented on an event. A counter would have needed the hook and would
/// have stayed at one for the rest of the session without it.
#[test]
fn a_completion_the_hooks_never_reported_still_clears_the_count() {
    let path = temp("pending-agents-recovery");
    let hub = hub_with_session("s-recover");
    transcript::follow(&hub, "s-recover", &path, Harness::ClaudeCode);

    append(&path, &agent_launch("m1", "toolu_a", "agent_a"));
    assert!(
        eventually(|| pending_agents(&hub, "s-recover") == Some(Some(1))),
        "the launch never landed: {:?}",
        pending_agents(&hub, "s-recover")
    );

    append(&path, &agent_notification("toolu_a", "agent_a"));
    assert!(
        eventually(|| pending_agents(&hub, "s-recover") == Some(Some(0))),
        "the next read of the transcript must be right on its own: {:?}",
        pending_agents(&hub, "s-recover")
    );

    let _ = std::fs::remove_file(&path);
}

/// Zero and unknown are two different claims on the producer side too.
///
/// Before a transcript has been read the daemon has said nothing, and the mirror
/// is `None`; the first read of a session with no agents publishes an explicit
/// `0`. Collapsing the two would make "waiting on none" indistinguishable from
/// "never looked", which is the same mistake as rendering an unknown token count
/// as `0`.
#[test]
fn a_session_with_no_agents_publishes_zero_and_not_silence() {
    let path = temp("pending-agents-zero");
    let hub = hub_with_session("s-zero");

    assert_eq!(
        pending_agents(&hub, "s-zero"),
        Some(None),
        "nothing read yet: the app has not been told anything"
    );

    transcript::follow(&hub, "s-zero", &path, Harness::ClaudeCode);
    append(&path, &tool_call("m1", "toolu_1"));

    assert!(
        eventually(|| pending_agents(&hub, "s-zero") == Some(Some(0))),
        "a read with no agents is a positive zero, got {:?}",
        pending_agents(&hub, "s-zero")
    );

    let _ = std::fs::remove_file(&path);
}

/// The delivery the reader could not see. 130 of 358 notifications on the
/// reference corpus arrive on an `attachment` line, and before this branch every
/// one of them left its wait open until the age limit expired it.
#[test]
fn a_notification_delivered_as_an_attachment_clears_the_count() {
    let path = temp("pending-agents-attachment");
    let hub = hub_with_session("s-attach");
    transcript::follow(&hub, "s-attach", &path, Harness::ClaudeCode);

    append(&path, &agent_launch("m1", "toolu_a", "agent_a"));
    assert!(
        eventually(|| pending_agents(&hub, "s-attach") == Some(Some(1))),
        "the launch never landed: {:?}",
        pending_agents(&hub, "s-attach")
    );

    append(
        &path,
        &agent_notification_as_attachment("toolu_a", "agent_a"),
    );
    assert!(
        eventually(|| pending_agents(&hub, "s-attach") == Some(Some(0))),
        "a notification is a notification whichever line carries it: {:?}",
        pending_agents(&hub, "s-attach")
    );

    let _ = std::fs::remove_file(&path);
}

/// The backstop, end to end. An agent launched three quarters of an hour ago that
/// never reported is not counted — and the point is what that buys: the card's
/// error is bounded in time instead of lasting as long as the session does.
#[test]
fn an_agent_that_never_reported_stops_being_counted_once_it_is_too_old() {
    let path = temp("pending-agents-abandoned");
    let hub = hub_with_session("s-old");
    transcript::follow(&hub, "s-old", &path, Harness::ClaudeCode);

    // Two launches, one recent and one abandoned 45 minutes ago.
    append(
        &path,
        &agent_launch_aged("m1", "toolu_old", "agent_old", 45),
    );
    append(&path, &agent_launch_aged("m2", "toolu_new", "agent_new", 1));

    assert!(
        eventually(|| pending_agents(&hub, "s-old") == Some(Some(1))),
        "expected only the recent launch to count, got {:?}",
        pending_agents(&hub, "s-old")
    );

    let _ = std::fs::remove_file(&path);
}

/// The second of the three ways a wait ends: the session goes away.
///
/// `forget_transcript` is the `SessionEnd` path. Whatever is still open on the
/// last line belongs to a session that no longer exists, so the count is closed
/// rather than left on a card that will keep saying "1 agent running" for as long
/// as it is on screen.
#[test]
fn a_session_that_ends_stops_waiting_on_whatever_was_still_out() {
    let path = temp("pending-agents-sessionend");
    let hub = hub_with_session("s-end");
    transcript::follow(&hub, "s-end", &path, Harness::ClaudeCode);

    append(&path, &agent_launch("m1", "toolu_a", "agent_a"));
    assert!(
        eventually(|| pending_agents(&hub, "s-end") == Some(Some(1))),
        "the launch never landed: {:?}",
        pending_agents(&hub, "s-end")
    );

    // No notification ever arrives. The session simply ends.
    hub.forget_transcript("s-end");

    assert_eq!(
        pending_agents(&hub, "s-end"),
        Some(Some(0)),
        "a session that is gone is waiting on nothing"
    );

    let _ = std::fs::remove_file(&path);
}

// ---- answer_request: the question the state cannot carry -------------------

/// An assistant reply, in prose, with no tool call in it — the shape a question
/// actually has and the one the transcript reader used to have no opinion about.
fn assistant_says(msg_id: &str, text: &str) -> String {
    let at = chrono::Utc::now().to_rfc3339();
    format!(
        r#"{{"type":"assistant","uuid":"u","sessionId":"s","timestamp":"{at}","message":{{"id":"{msg_id}","model":"claude-opus-5","content":[{{"type":"text","text":"{text}"}}],"usage":{{"input_tokens":10,"output_tokens":5}}}}}}
"#
    )
}

/// The `Stop` hook's own line: the end of the turn, as Claude Code writes it.
fn stop_point() -> String {
    let at = chrono::Utc::now().to_rfc3339();
    format!(
        r#"{{"type":"system","subtype":"stop_hook_summary","uuid":"u","sessionId":"s","timestamp":"{at}"}}
"#
    )
}

fn user_says(text: &str) -> String {
    let at = chrono::Utc::now().to_rfc3339();
    format!(
        r#"{{"type":"user","uuid":"u","sessionId":"s","timestamp":"{at}","message":{{"role":"user","content":"{text}"}}}}
"#
    )
}

/// Three states, read off the registry exactly as the wire carries them: `None`
/// is absent, `Some(None)` is `null`, `Some(Some(_))` is the question.
fn answer_request(
    hub: &Hub,
    session_id: &str,
) -> Option<Option<Option<violeet_proto::wire::AnswerRequest>>> {
    let registry = hub.registry().lock().unwrap();
    registry
        .session(session_id)
        .map(|s| s.answer_request.clone())
}

/// The bug, end to end. `Stop` maps to `Idle` and the transcript correction only
/// fires with a tool in flight, which a question in prose never has — so a
/// session genuinely waiting on a written answer read as plain idle.
///
/// What is asserted is not the state: `idle` is the contract. It is that the app
/// now has the one field that tells this session apart from one that finished.
#[test]
fn a_question_in_prose_reaches_the_registry_as_an_object() {
    let path = temp("answer-request");
    let hub = hub_with_session("s-asking");
    transcript::follow(&hub, "s-asking", &path, Harness::ClaudeCode);

    append(&path, &user_says("compara as duas rotas"));
    append(
        &path,
        &assistant_says(
            "m1",
            "Achei dois caminhos para o corte. Sigo pelo primeiro?",
        ),
    );
    append(&path, &stop_point());

    assert!(
        eventually(|| matches!(answer_request(&hub, "s-asking"), Some(Some(Some(_))))),
        "the question never landed: {:?}",
        answer_request(&hub, "s-asking")
    );

    let asked = answer_request(&hub, "s-asking")
        .flatten()
        .flatten()
        .expect("an object");
    assert_eq!(asked.signal, "question_mark");
    assert_eq!(
        asked.question,
        "Achei dois caminhos para o corte. Sigo pelo primeiro?"
    );
    assert_eq!(
        asked.context.first().map(|m| m.text.as_str()),
        Some("compara as duas rotas"),
        "the excerpt carries the turn that led to the question"
    );

    // And the state is untouched: this is a field, not a fifth state. The
    // session here was never sent a `Stop` hook, so it is still `Starting` — and
    // reading a question out of the transcript moved it nowhere.
    assert_eq!(state_of(&hub, "s-asking"), Some(SessionState::Starting));

    let _ = std::fs::remove_file(&path);
}

/// The answer ends the wait. `null` and not silence: silence would mean
/// *unchanged*, and the panel the app opened would never learn to close.
#[test]
fn an_answered_question_becomes_an_explicit_null() {
    let path = temp("answer-request-answered");
    let hub = hub_with_session("s-answered");
    transcript::follow(&hub, "s-answered", &path, Harness::ClaudeCode);

    append(&path, &assistant_says("m1", "Sigo pelo primeiro?"));
    append(&path, &stop_point());
    assert!(
        eventually(|| matches!(answer_request(&hub, "s-answered"), Some(Some(Some(_))))),
        "the question never landed"
    );

    append(&path, &user_says("sim, pode seguir"));
    assert!(
        eventually(|| answer_request(&hub, "s-answered") == Some(Some(None))),
        "the wait never ended: {:?}",
        answer_request(&hub, "s-answered")
    );

    let _ = std::fs::remove_file(&path);
}

/// A session that stopped having finished says so. This is the reading that
/// separates "quiet" from "never looked", and it is a claim the daemon is
/// entitled to make: it read the stop point itself.
#[test]
fn a_session_that_stopped_without_asking_publishes_null() {
    let path = temp("answer-request-quiet");
    let hub = hub_with_session("s-quiet");
    transcript::follow(&hub, "s-quiet", &path, Harness::ClaudeCode);

    append(
        &path,
        &assistant_says("m1", "Feito. Os dois arquivos foram atualizados."),
    );
    append(&path, &stop_point());

    assert!(
        eventually(|| answer_request(&hub, "s-quiet") == Some(Some(None))),
        "an observed session with nothing asked must say so: {:?}",
        answer_request(&hub, "s-quiet")
    );

    let _ = std::fs::remove_file(&path);
}

/// **The state that is easy to lose.** A session the detector never ran on — no
/// stop point in the file — publishes nothing at all. A `null` here would tell
/// the app "there is no question" about a session the daemon never saw stop.
#[test]
fn a_session_with_no_stop_point_publishes_nothing_at_all() {
    let path = temp("answer-request-unobserved");
    let hub = hub_with_session("s-unobserved");
    transcript::follow(&hub, "s-unobserved", &path, Harness::ClaudeCode);

    // A whole turn's worth of file, and not one stop point in it.
    append(&path, &user_says("compara as duas rotas"));
    append(&path, &assistant_says("m1", "Achei dois caminhos. Sigo?"));

    // Wait for the read to have happened at all, on a field that does move.
    assert!(
        eventually(|| {
            let registry = hub.registry().lock().unwrap();
            registry
                .session("s-unobserved")
                .is_some_and(|s| s.tokens.cumulative_output_tokens.is_some())
        }),
        "the transcript was never read"
    );

    assert_eq!(
        answer_request(&hub, "s-unobserved"),
        Some(None),
        "never observed is not the same as observed and quiet"
    );

    let _ = std::fs::remove_file(&path);
}

/// The two blocked readings at the same instant: a tool in flight *and* a
/// permission request open. ADR-004 says the HITL card outranks everything, and
/// the way this field respects that is by not competing — it says nothing.
///
/// The assertion follows from the code (no stop point, so the detector never
/// ran) but nothing pinned it, and this is the corner where a future "publish
/// null when the session is blocked" would look reasonable and would be a lie:
/// the daemon has not looked for a question here, and `null` claims it has.
#[test]
fn a_tool_in_flight_under_a_pending_hitl_publishes_no_question_at_all() {
    let path = temp("answer-request-hitl");
    append(&path, &tool_call("m1", "toolu_1"));

    let hub = hub_with_session("s-asking-hitl");
    let (_request, _rx) = hub.open_hitl(
        violeet_daemon::hitl::NewHitl {
            session_id: "s-asking-hitl".to_string(),
            tab_id: None,
            tool_name: "Bash".to_string(),
            tool_input: serde_json::json!({"command": "cargo test"}),
            permission_suggestions: serde_json::Value::Array(Vec::new()),
        },
        chrono::Utc::now(),
    );
    assert!(hub.has_pending_hitl("s-asking-hitl"));

    transcript::follow(&hub, "s-asking-hitl", &path, Harness::ClaudeCode);
    append(&path, &tool_call("m2", "toolu_2"));

    assert!(
        eventually(|| state_of(&hub, "s-asking-hitl") == Some(SessionState::WaitingHitl)),
        "expected waiting_hitl, got {:?}",
        state_of(&hub, "s-asking-hitl")
    );

    // Both readings, at the same instant: the HITL is open and the question
    // field was never published — absent, not `null`.
    assert!(hub.has_pending_hitl("s-asking-hitl"));
    assert_eq!(
        answer_request(&hub, "s-asking-hitl"),
        Some(None),
        "a blocked session is not a session we read a stop point for"
    );

    let _ = std::fs::remove_file(&path);
}
