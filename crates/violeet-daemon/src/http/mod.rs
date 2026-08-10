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
//! own `hook_event_name`, so `violeet install-hooks` writes the same URL for all
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

use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr};
use std::time::Instant;

use axum::extract::{ConnectInfo, State};
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

pub use violeet_proto::DEFAULT_HOOK_PORT;
use payload::{HookEvent, HookPayload, PermissionResponse};
pub use payload::StatusLinePayload;

/// The header the installed hook command uses to pass `VIOLEET_TAB_ID`.
///
/// A header rather than a body field so the hook can be a plain `curl` that
/// forwards the agent's payload untouched — no `jq`, no shell JSON assembly,
/// nothing that breaks when the payload gains a field.
pub const TAB_ID_HEADER: &str = "x-violeet-tab-id";

/// Optional; identifies a non-Claude-Code adapter. Absent means Claude Code,
/// which is the only harness with a usable permission hook today (ADR-004).
pub const HARNESS_HEADER: &str = "x-violeet-harness";

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

    /// The port actually bound, which is what `~/.violeet/daemon.json` must
    /// carry — the default is only a default.
    pub fn port(&self) -> u16 {
        self.port
    }

    pub async fn serve(self) -> std::io::Result<()> {
        // `into_make_service_with_connect_info` is what makes the peer address
        // reachable from a handler, and the peer address is how a session that
        // violeet did not start gets identified — see `crate::origin`.
        axum::serve(
            self.listener,
            router(self.hub).into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
    }
}

fn router(hub: Hub) -> Router {
    Router::new()
        .route("/hook/event", post(hook_event))
        .route("/hook/permission-request", post(permission_request))
        .route("/statusline", post(statusline))
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
    // Reported here so `violeet doctor` can surface them. A model Anthropic
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

/// Read `VIOLEET_TAB_ID` off the request.
///
/// An empty value is `None`, not `Some("")`. The installed hook is a `curl`
/// that always sends the header, so an agent started outside violeet sends it
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

/// Work out where this session is running, at most once per session.
///
/// Must be awaited **before** the response is written: the resolution reads the
/// kernel's view of the connection this request arrived on, and that view stops
/// existing when the socket closes. The work itself is two short-lived
/// subprocesses, so it goes on a blocking thread rather than stalling a runtime
/// worker for the ~45 ms it takes.
///
/// Returns `None` — and costs nothing — for a session whose origin is already
/// known, which is every hook after the first.
async fn origin_for(hub: &Hub, session_id: &str, peer: SocketAddr) -> Option<crate::origin::Origin> {
    if hub.knows_origin(session_id) {
        return None;
    }
    let port = peer.port();
    tokio::task::spawn_blocking(move || crate::origin::resolve(port))
        .await
        .ok()
        .flatten()
        .filter(|o| !o.is_empty())
}

/// Look up and publish a Cursor session's model, when it is worth looking.
///
/// Cursor is the only harness that never states its model: not in the
/// transcript, not on any hook, and it has no status line. The name lives in a
/// database Cursor keeps for itself, so it costs a query rather than a field.
///
/// **When**, and the reasoning is entirely about not paying on every hook:
///
/// - while the model is unknown, because a card with a blank model line is the
///   problem being solved and hooks fire several times a turn, so the first one
///   to arrive fixes it — but no more often than `MODEL_RETRY_FLOOR`, because
///   a session that will never have a model stays unknown forever and would
///   otherwise buy a full table scan on every hook it ever fires;
/// - on `Stop`, once per turn, which is what catches a model the user switched
///   between turns. Anything finer would query during the turn to notice a
///   change that cannot happen mid-turn anyway.
///
/// Off the runtime thread, **and never awaited**. The query opens a file
/// another process is writing to and waits up to `BUSY_TIMEOUT` if it is
/// locked; short, but not zero, and this handler's own doc promises it never
/// blocks. So the task is spawned and dropped on the floor.
///
/// Fire-and-forget is safe here and is not safe in [`origin_for`], and the
/// difference is what each one reads. `origin_for` resolves the kernel's view
/// of *this connection*, which stops existing the moment the socket closes — it
/// has to finish before the response is written or it has nothing left to read.
/// This reads a file on disk, which does not care whether the hook is still
/// open, and it delivers its answer over `broadcast` to the app rather than
/// through the hook's response body. Nothing downstream of the `204` is waiting
/// on it. Nothing upstream is either: the adapter's `urlopen(timeout=5)` and the
/// installed hook's `INFORMATIONAL_TIMEOUT = 5` are both wall clock the user
/// pays for, spent on a lookup whose result they receive by another route.
fn name_the_model(
    hub: &Hub,
    session_id: &str,
    harness: Harness,
    event: HookEvent,
    now: chrono::DateTime<Utc>,
) {
    if harness != Harness::Cursor {
        return;
    }
    if !(event == HookEvent::Stop || hub.model_is_unknown(session_id)) {
        return;
    }
    // `Stop` is the once-a-turn sweep and always runs. Everything else is the
    // while-unknown path, which is the one that needs a floor under it.
    if event != HookEvent::Stop && !off_backoff(session_id) {
        return;
    }

    let hub = hub.clone();
    let owned = session_id.to_string();
    tokio::task::spawn_blocking(move || {
        let found = crate::cursor_model::model_for_session(&owned);
        match found {
            Some(model) => {
                forget_miss(&owned);
                hub.observe_model(&owned, &model, now);
            }
            None => record_miss(owned),
        }
    });
}

/// How long a session that came back with no model is left alone.
///
/// **A guess, not a measurement**, in the same spirit as
/// [`crate::hitl::DEFAULT_HITL_TIMEOUT_SECONDS`]. What it is trading is real
/// and measured: `conversationId` is not indexed in Cursor's table, so every
/// miss is a full scan, and a session that will never have a model — 3 of the 7
/// sessions measured on 2026-08-09 wrote no code at all — would otherwise pay
/// that scan on every hook for as long as it lives. Five seconds is picked to
/// be shorter than a human notices a blank model line and longer than the burst
/// of hooks a single turn fires. Measure the two and this number should move.
const MODEL_RETRY_FLOOR: std::time::Duration = std::time::Duration::from_secs(5);

/// Entries older than this are dropped on the next sweep. Only a memory bound:
/// a session past the floor would be retried anyway, so forgetting it is free.
const MISS_TTL: std::time::Duration = std::time::Duration::from_secs(300);

/// When each session's model lookup last came back empty.
///
/// Local to this module rather than a field on [`Hub`] on purpose: the state is
/// an optimisation for one call site and nothing else observes it, and widening
/// `Hub`'s constructor to carry it would touch every test that builds one.
static MODEL_MISSES: std::sync::OnceLock<std::sync::Mutex<HashMap<String, Instant>>> =
    std::sync::OnceLock::new();

fn model_misses() -> &'static std::sync::Mutex<HashMap<String, Instant>> {
    MODEL_MISSES.get_or_init(Default::default)
}

/// Whether this session has waited out the floor since its last empty lookup.
///
/// A poisoned lock answers `true`: the failure mode of querying too often is a
/// wasted scan, and the failure mode of never querying again is a card that
/// stays blank forever.
fn off_backoff(session_id: &str) -> bool {
    let Ok(misses) = model_misses().lock() else {
        return true;
    };
    misses
        .get(session_id)
        .is_none_or(|last| last.elapsed() >= MODEL_RETRY_FLOOR)
}

fn record_miss(session_id: String) {
    let Ok(mut misses) = model_misses().lock() else {
        return;
    };
    let now = Instant::now();
    // Swept here rather than on a timer: the map only grows when a miss is
    // recorded, so the moment one is recorded is the only moment it can leak.
    misses.retain(|_, last| now.duration_since(*last) < MISS_TTL);
    misses.insert(session_id, now);
}

fn forget_miss(session_id: &str) {
    if let Ok(mut misses) = model_misses().lock() {
        misses.remove(session_id);
    }
}

fn harness_of(headers: &HeaderMap) -> Harness {
    match headers.get(HARNESS_HEADER).and_then(|v| v.to_str().ok()) {
        None | Some("") | Some("claude-code") => Harness::ClaudeCode,
        Some("codex") => Harness::Codex,
        Some("opencode") => Harness::Opencode,
        Some("cursor") => Harness::Cursor,
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
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    body: Option<Json<HookPayload>>,
) -> StatusCode {
    // A body we cannot parse is dropped, not rejected. There is nothing useful
    // to tell the agent, and failing the hook call would surface in the user's
    // terminal as an violeet error for something violeet merely observes.
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
            "violeet-daemon: a PermissionRequest hook reached /hook/event — it must \
             point at /hook/permission-request. Run `violeet install-hooks`."
        );
        return StatusCode::INTERNAL_SERVER_ERROR;
    }

    let mut obs = payload.observation(&session_id, tab_id_of(&headers), harness_of(&headers));
    if let Some(origin) = origin_for(&hub, &session_id, peer).await {
        obs = obs.with_origin(origin);
    }
    // Start following the transcript before recording the hook: the reader is
    // idempotent per (session, path), so this is free once it is running, and
    // doing it first means a session is never briefly known-but-unfollowed.
    if let Some(path) = obs.transcript_path.clone() {
        crate::transcript::follow(&hub, &session_id, &path);
    }
    let outcome = hub.observe_hook(obs, now);

    // Cursor names its model nowhere we are told, so it is looked up. See
    // `crate::cursor_model`.
    name_the_model(&hub, &session_id, harness_of(&headers), event, now);

    // Name the session from what the user just typed. This runs on the hook
    // rather than off the transcript because it has to be on screen before the
    // first reply is: the transcript route is hundreds of milliseconds later,
    // and a card that is nameless for the length of a turn is a card you cannot
    // find. Claude Code's own `ai-title` upgrades it one exchange in.
    if event == HookEvent::UserPromptSubmit {
        if let Some(prompt) = payload.prompt.as_deref() {
            hub.offer_title_from_prompt(&session_id, prompt, now);
        }
    }

    if let Some(rejected) = &outcome.rejected_transition {
        eprintln!("violeet-daemon: session {session_id}: ignoring {rejected}");
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

/// The status line channel.
///
/// Answers `204` immediately and never blocks. The status line renders on every
/// frame of the agent's UI, so anything slow here is felt directly by the user
/// as a laggy prompt — and the wrapper `violeet install-statusline` writes fires
/// this in the background for the same reason.
///
/// It exists for what the transcript cannot provide: the context window size
/// for this account, and the subscription's usage limits.
async fn statusline(State(hub): State<Hub>, body: Option<Json<StatusLinePayload>>) -> StatusCode {
    // Unparseable, or no session to attach it to. Dropped silently: there is
    // nothing useful to tell a status line, and a non-2xx would surface in the
    // user's prompt as an violeet error for something violeet merely observes.
    let Some(Json(payload)) = body else {
        return StatusCode::NO_CONTENT;
    };
    let Some(session_id) = payload.session_id.clone().filter(|s| !s.is_empty()) else {
        return StatusCode::NO_CONTENT;
    };

    hub.observe_statusline(&session_id, &payload, Utc::now());
    StatusCode::NO_CONTENT
}

/// The blocking one.
///
/// Holds the response open until the app answers, the human answers in the
/// terminal, or the deadline passes. Every path out of this function writes a
/// response.
async fn permission_request(
    State(hub): State<Hub>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
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
    let mut obs = payload.observation(&session_id, tab_id.clone(), harness_of(&headers));
    // Worth the ~45 ms here more than anywhere else: this is the hook that
    // makes a card say "waiting for you", and a card the user cannot locate is
    // the whole reason the origin exists.
    if let Some(origin) = origin_for(&hub, &session_id, peer).await {
        obs = obs.with_origin(origin);
    }
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
                "violeet-daemon: HITL {} lost its resolver; answering 500",
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
    eprintln!("violeet-daemon: answering 500 to {what}");
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
    /// violeet sends it empty. Treating `""` as a tab id would bind every such
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
            harness_of(&headers_with(HARNESS_HEADER, "cursor")),
            Harness::Cursor
        );
        assert_eq!(
            harness_of(&headers_with(HARNESS_HEADER, "something-else")),
            Harness::Unknown
        );
    }
}
