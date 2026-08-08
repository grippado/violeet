//! The status line channel: the only source for the context window size and
//! the account's usage limits.

use violeet_daemon::http::StatusLinePayload;
use violeet_daemon::registry::{Harness, HookObservation, Registry};
use violeet_daemon::socket::Hub;

const PAYLOAD: &str = r#"{
  "session_id": "s1",
  "model": {"id": "claude-opus-5", "display_name": "Opus 5"},
  "context_window": {
    "total_input_tokens": 48000,
    "context_window_size": 1000000,
    "used_percentage": 4.8
  },
  "rate_limits": {
    "five_hour": {"used_percentage": 30.0, "resets_at": 1785620000},
    "seven_day": {"used_percentage": 62.5, "resets_at": 1785700000}
  }
}"#;

fn hub_with(session_id: &str) -> Hub {
    let hub = Hub::new(Registry::with_default_ttl());
    hub.observe_hook(
        HookObservation::new(session_id, Harness::ClaudeCode),
        chrono::Utc::now(),
    );
    hub
}

/// The payload Claude Code actually sends must parse.
#[test]
fn the_real_payload_shape_parses() {
    let parsed: StatusLinePayload =
        serde_json::from_str(PAYLOAD).expect("the documented payload must parse");

    assert_eq!(
        parsed.context_window.as_ref().unwrap().context_window_size,
        Some(1_000_000)
    );
    assert_eq!(
        parsed.rate_limits.as_ref().unwrap().five_hour.as_ref().unwrap().used_percentage,
        Some(30.0)
    );
}

/// The window size lands on the session — the whole reason this exists.
#[test]
fn the_window_size_and_limits_reach_the_session() {
    let hub = hub_with("s1");
    let payload: StatusLinePayload = serde_json::from_str(PAYLOAD).unwrap();

    assert!(
        hub.observe_statusline("s1", &payload, chrono::Utc::now()),
        "a payload carrying new values must report that something changed"
    );

    let registry = hub.registry().lock().unwrap();
    let session = registry.session("s1").unwrap();
    assert_eq!(session.tokens.context_window_size_tokens, Some(1_000_000));
    assert_eq!(session.model.as_deref(), Some("claude-opus-5"));
    assert_eq!(session.limits.five_hour_used_percent, Some(30.0));
    assert_eq!(session.limits.seven_day_used_percent, Some(62.5));
    assert_eq!(session.limits.five_hour_resets_at, Some(1_785_620_000));
}

/// The status line renders every frame, so an unchanged payload must be free
/// and must not broadcast.
#[test]
fn an_unchanged_payload_publishes_nothing() {
    let hub = hub_with("s1");
    let payload: StatusLinePayload = serde_json::from_str(PAYLOAD).unwrap();

    assert!(hub.observe_statusline("s1", &payload, chrono::Utc::now()));
    assert!(
        !hub.observe_statusline("s1", &payload, chrono::Utc::now()),
        "the second identical payload changed nothing and must stay silent"
    );
}

/// The status line is not a registration channel.
///
/// A session violeet has not seen through a hook has no tab binding and no
/// lifecycle; putting a card on screen from this payload would announce a
/// session the hooks never did.
#[test]
fn an_unknown_session_is_ignored_rather_than_created() {
    let hub = Hub::new(Registry::with_default_ttl());
    let payload: StatusLinePayload = serde_json::from_str(PAYLOAD).unwrap();

    assert!(!hub.observe_statusline("never-seen", &payload, chrono::Utc::now()));
    assert_eq!(hub.registry().lock().unwrap().sessions().count(), 0);
}

/// A payload missing everything optional must not panic or fabricate.
#[test]
fn a_sparse_payload_leaves_everything_unknown() {
    let hub = hub_with("s1");
    let payload: StatusLinePayload = serde_json::from_str(r#"{"session_id":"s1"}"#).unwrap();

    assert!(!hub.observe_statusline("s1", &payload, chrono::Utc::now()));

    let registry = hub.registry().lock().unwrap();
    let session = registry.session("s1").unwrap();
    assert_eq!(session.tokens.context_window_size_tokens, None);
    assert_eq!(session.limits.five_hour_used_percent, None);
}
