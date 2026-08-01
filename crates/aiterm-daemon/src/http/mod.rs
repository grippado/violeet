//! Loopback HTTP endpoint for Claude Code hooks.
//!
//! Binds `127.0.0.1` only. Informational hook routes answer immediately and
//! never block; `/hook/permission-request` blocks by design until the app
//! resolves it, the human wins the race in the terminal, or the daemon's own
//! timeout fires.
//!
//! See ADR-004 for why HITL rides on `PermissionRequest` and for the semantics
//! of the three resolutions.
//!
//! # Routes
//!
//! | Route | Blocks | Answers |
//! |---|---|---|
//! | `POST /hook/event` | no | `204` |
//! | `POST /hook/permission-request` | yes | `200` + decision, or `500` |
//! | `GET /health` | no | `200` |
//!
//! Informational hooks share one route and are discriminated by the payload's
//! own `hook_event_name`, so `aiterm install-hooks` writes the same URL for all
//! of them and a Claude Code that adds an event needs no new route.
//!
//! # The invariant
//!
//! **No permission request may ever go unanswered.** ADR-004 measured what
//! silence costs: a route that accepts the connection and never replies hangs
//! the agent for as long as the human tolerates it — over eleven minutes in the
//! spike, with no error and no fallback. Every failure path here answers `500`
//! instead, which drops the user into the interactive dialog that is still on
//! screen. Three layers enforce it:
//!
//! 1. a panicking handler becomes `500` via `CatchPanicLayer`, rather than a
//!    dropped connection
//! 2. the handler owns its own deadline and resolves itself when it passes
//! 3. the daemon's sweeper expires anything a handler abandoned, so a request
//!    whose client vanished still clears its card
//!
//! # Trust
//!
//! None, and none is needed. This is a loopback socket on a single-user
//! machine, exactly like the Unix socket: any local process can POST to it, and
//! the worst it can do is invent sessions in a sidebar. It must never bind
//! anything but `127.0.0.1`, which the tests assert.

pub mod payload;

use std::net::{Ipv4Addr, SocketAddr};

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::Utc;
use tokio::net::TcpListener;
use tower_http::catch_panic::CatchPanicLayer;

use crate::hitl::{NewHitl, Resolution};
use crate::registry::Harness;
use crate::socket::Hub;
use crate::wire::{EndReason, HitlOrigin};

pub use aiterm_proto::DEFAULT_HOOK_PORT;
use payload::{HookEvent, HookPayload, PermissionResponse};

/// The header the installed hook command uses to pass `AITERM_TAB_ID`.
///
/// A header rather than a body field so the hook can be a plain `curl` that
/// forwards the agent's payload untouched — no `jq`, no shell JSON assembly,
/// nothing that breaks when the payload gains a field.
pub const TAB_ID_HEADER: &str = "x-aiterm-tab-id";

/// Optional; identifies a non-Claude-Code adapter. Absent means Claude Code,
/// which is the only harness with a usable permission hook today (ADR-004).
pub const HARNESS_HEADER: &str = "x-aiterm-harness";

/// A bound hook endpoint, ready to serve.
pub struct HookServer {
    listener: TcpListener,
    port: u16,
    hub: Hub,
}

impl HookServer {
    /// Bind on loopback. Port `0` asks the OS for a free one, which is how the
    /// tests avoid fighting over a fixed port.
    pub async fn bind(port: u16, hub: Hub) -> std::io::Result<Self> {
        let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
        let listener = TcpListener::bind(addr).await?;
        let port = listener.local_addr()?.port();
        Ok(Self {
            listener,
            port,
            hub,
        })
    }

    /// The port actually bound, which is what `~/.aiterm/daemon.json` must
    /// carry — the default is only a default.
    pub fn port(&self) -> u16 {
        self.port
    }

    pub async fn serve(self) -> std::io::Result<()> {
        axum::serve(self.listener, router(self.hub)).await
    }
}

fn router(hub: Hub) -> Router {
    Router::new()
        .route("/hook/event", post(hook_event))
        .route("/hook/permission-request", post(permission_request))
        .route("/health", get(health))
        // Layer 1 of the never-silent invariant: a panicking handler answers
        // 500 instead of dropping the connection, which for a permission
        // request is the difference between a fallback dialog and a hang.
        .layer(CatchPanicLayer::new())
        .with_state(hub)
}

async fn health(State(hub): State<Hub>) -> Response {
    // Models whose context window size we could not resolve.
    //
    // Reported here so `aiterm doctor` can surface them. A model Anthropic
    // ships tomorrow is not in the lookup table, which makes the window size
    // `None`, which makes `compaction_imminent` `None` — and an alert that
    // quietly stops firing is worse than one that never existed, because the
    // user has learned to rely on it.
    let (sessions, unknown_window_models) = match hub.registry().lock() {
        Ok(r) => {
            let count = r.sessions().count();
            let mut models: Vec<String> = r
                .sessions()
                .filter(|s| s.tokens.context_window_size_tokens.is_none())
                .filter_map(|s| s.model.clone())
                .collect();
            models.sort();
            models.dedup();
            (count, models)
        }
        Err(_) => (0, Vec::new()),
    };
    let pending = hub.hitl().lock().map(|h| h.len()).unwrap_or(0);

    Json(serde_json::json!({
        "ok": true,
        "protocol_version": crate::wire::PROTOCOL_VERSION,
        "sessions": sessions,
        "hitl_pending": pending,
        "unknown_window_models": unknown_window_models,
    }))
    .into_response()
}

/// Read `AITERM_TAB_ID` off the request.
///
/// An empty value is `None`, not `Some("")`. The installed hook is a `curl`
/// that always sends the header, so an agent started outside aiterm sends it
/// empty — treating that as a tab id would bind every such session to one
/// imaginary tab.
fn tab_id_of(headers: &HeaderMap) -> Option<String> {
    headers
        .get(TAB_ID_HEADER)
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

fn harness_of(headers: &HeaderMap) -> Harness {
    match headers.get(HARNESS_HEADER).and_then(|v| v.to_str().ok()) {
        None | Some("") | Some("claude-code") => Harness::ClaudeCode,
        Some("codex") => Harness::Codex,
        Some("opencode") => Harness::Opencode,
        // A harness we do not know still gets a card. `Unknown` is a real value
        // on the wire, not a failure.
        Some(_) => Harness::Unknown,
    }
}

/// Every hook except `PermissionRequest`.
///
/// Answers `204` and never blocks: these are notifications, and an agent
/// waiting on our bookkeeping would be a regression for no benefit.
async fn hook_event(
    State(hub): State<Hub>,
    headers: HeaderMap,
    body: Option<Json<HookPayload>>,
) -> StatusCode {
    // A body we cannot parse is dropped, not rejected. There is nothing useful
    // to tell the agent, and failing the hook call would surface in the user's
    // terminal as an aiterm error for something aiterm merely observes.
    let Some(Json(payload)) = body else {
        return StatusCode::NO_CONTENT;
    };
    let Some(session_id) = payload.session_id.clone().filter(|s| !s.is_empty()) else {
        return StatusCode::NO_CONTENT;
    };

    let event = payload.event();
    let now = Utc::now();

    if event == HookEvent::PermissionRequest {
        // Installed against the wrong route. Answering 500 is the safe failure:
        // the agent falls straight back to its own dialog. A 204 here would be
        // silence wearing a success code.
        eprintln!(
            "aiterm-daemon: a PermissionRequest hook reached /hook/event — it must \
             point at /hook/permission-request. Run `aiterm install-hooks`."
        );
        return StatusCode::INTERNAL_SERVER_ERROR;
    }

    let obs = payload.observation(&session_id, tab_id_of(&headers), harness_of(&headers));
    // Start following the transcript before recording the hook: the reader is
    // idempotent per (session, path), so this is free once it is running, and
    // doing it first means a session is never briefly known-but-unfollowed.
    if let Some(path) = obs.transcript_path.clone() {
        crate::transcript::follow(&hub, &session_id, &path);
    }
    let outcome = hub.observe_hook(obs, now);

    if let Some(rejected) = &outcome.rejected_transition {
        eprintln!("aiterm-daemon: session {session_id}: ignoring {rejected}");
    }

    // A PostToolUse means a tool call completed. If we were holding a
    // permission request for that same call, the human answered it in the
    // terminal and won the race (ADR-004).
    if event == HookEvent::PostToolUse {
        if let (Some(tool_name), Some(tool_input)) =
            (payload.tool_name.as_deref(), payload.tool_input.as_ref())
        {
            hub.resolve_tui_race(&session_id, tool_name, tool_input);
        }
    }

    if event == HookEvent::SessionEnd {
        let tab_id = hub.bound_tab_of(&session_id);
        hub.publish_session_ended(&session_id, tab_id, EndReason::SessionEndHook, now);
    }

    StatusCode::NO_CONTENT
}

/// The blocking one.
///
/// Holds the response open until the app answers, the human answers in the
/// terminal, or the deadline passes. Every path out of this function writes a
/// response.
async fn permission_request(
    State(hub): State<Hub>,
    headers: HeaderMap,
    body: Option<Json<HookPayload>>,
) -> Response {
    let Some(Json(payload)) = body else {
        // Unparseable. `500` rather than `400`: the agent does not act on our
        // status codes, it acts on getting an answer at all, and `500` is the
        // measured-safe fallback.
        return fallback("a PermissionRequest payload we could not parse");
    };
    let Some(session_id) = payload.session_id.clone().filter(|s| !s.is_empty()) else {
        return fallback("a PermissionRequest with no session_id");
    };
    let Some(tool_name) = payload.tool_name.clone() else {
        // With no tool name there is nothing to put on a card and nothing to
        // correlate a terminal win against. Hand the decision straight back.
        return fallback("a PermissionRequest with no tool_name");
    };

    let now = Utc::now();
    let tab_id = tab_id_of(&headers);

    // Record the session first, so the app hears about it before it hears that
    // it is blocked.
    let obs = payload.observation(&session_id, tab_id.clone(), harness_of(&headers));
    if let Some(path) = obs.transcript_path.clone() {
        crate::transcript::follow(&hub, &session_id, &path);
    }
    hub.observe_hook(obs, now);

    // Prefer the binding the registry settled on over the header: a late-bound
    // session knows better than this one request does.
    let bound_tab = hub.bound_tab_of(&session_id).or(tab_id);

    let (request, rx) = hub.open_hitl(
        NewHitl {
            session_id,
            tab_id: bound_tab,
            tool_name,
            tool_input: payload
                .tool_input
                .clone()
                .unwrap_or(serde_json::Value::Null),
            permission_suggestions: payload
                .permission_suggestions
                .clone()
                .unwrap_or_else(|| serde_json::Value::Array(Vec::new())),
        },
        now,
    );

    // Layer 2: this handler owns the deadline. The sweeper is a backstop for
    // requests whose client vanished, not the primary timer — leaning on it
    // would make the effective timeout depend on the sweep interval.
    let budget = (request.expires_at - now)
        .to_std()
        .unwrap_or(std::time::Duration::ZERO);

    let resolution = match tokio::time::timeout(budget, rx).await {
        Ok(Ok(resolution)) => resolution,

        // The deadline passed. Resolve it ourselves so the card clears and the
        // app hears `hitl_resolved`. If someone beat us to it in the gap, their
        // answer went to the receiver we just consumed and is unrecoverable —
        // but they already broadcast the real `hitl_resolved`, so the app is
        // right even though this response is a fallback.
        Err(_elapsed) => {
            hub.resolve_hitl(&request.hitl_id, Resolution::fallback(HitlOrigin::Timeout));
            Resolution::fallback(HitlOrigin::Timeout)
        }

        // The sender was dropped without sending. Should not happen; survivable.
        Ok(Err(_recv_error)) => {
            eprintln!(
                "aiterm-daemon: HITL {} lost its resolver; answering 500",
                request.hitl_id
            );
            Resolution::fallback(HitlOrigin::DaemonError)
        }
    };

    match resolution.decision {
        Some(decision) => (
            StatusCode::OK,
            Json(PermissionResponse::from_decision(&decision)),
        )
            .into_response(),
        // tui, timeout, daemon_error: `500`, and the agent's own dialog.
        None => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

/// The safe failure: `500`, logged, never silence.
fn fallback(what: &str) -> Response {
    eprintln!("aiterm-daemon: answering 500 to {what}");
    StatusCode::INTERNAL_SERVER_ERROR.into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    fn headers_with(name: &'static str, value: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert(name, HeaderValue::from_str(value).unwrap());
        h
    }

    #[test]
    fn a_missing_tab_id_header_is_none() {
        assert_eq!(tab_id_of(&HeaderMap::new()), None);
    }

    /// The installed hook always sends the header; an agent started outside
    /// aiterm sends it empty. Treating `""` as a tab id would bind every such
    /// session to one imaginary tab.
    #[test]
    fn an_empty_tab_id_header_is_none_rather_than_an_empty_tab() {
        assert_eq!(tab_id_of(&headers_with(TAB_ID_HEADER, "")), None);
        assert_eq!(tab_id_of(&headers_with(TAB_ID_HEADER, "   ")), None);
        assert_eq!(
            tab_id_of(&headers_with(TAB_ID_HEADER, "tab-7f3a")),
            Some("tab-7f3a".into())
        );
    }

    #[test]
    fn an_absent_harness_header_means_claude_code() {
        assert_eq!(harness_of(&HeaderMap::new()), Harness::ClaudeCode);
        assert_eq!(
            harness_of(&headers_with(HARNESS_HEADER, "codex")),
            Harness::Codex
        );
        assert_eq!(
            harness_of(&headers_with(HARNESS_HEADER, "something-else")),
            Harness::Unknown
        );
    }
}
