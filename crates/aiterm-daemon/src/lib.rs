//! aiterm daemon.
//!
//! Owns the live picture of the product: which agent sessions exist, what state
//! they are in, and which ones are blocked on a permission request. Clients (the
//! macOS app, the CLI) are dumb: they render and they command. See ADR-002.
//!
//! Module map, one per responsibility:
//!
//! - [`registry`] — live sessions, tab bindings, lifecycle. Synchronous and
//!   I/O-free, so it is testable without a socket.
//! - [`hitl`]     — permission requests being held open. Same discipline as
//!   [`registry`]: synchronous, and `now` is a parameter.
//! - [`wire`]     — the JSON-lines message types of `docs/PROTOCOL.md`,
//!   re-exported from `aiterm-proto`, which owns them.
//! - [`socket`]   — the Unix socket server that speaks [`wire`] to clients.
//! - [`http`]     — the loopback endpoint Claude Code's hooks POST to.
//! - [`discovery`] — `~/.aiterm/daemon.json`, so clients need not guess a port.
//! - [`transcript`] — follows session transcripts and publishes telemetry.
//!
//! Transcript **parsing** and context math are deliberately not here: they live
//! in the `aiterm-transcript` crate, which knows nothing about sockets or the
//! registry. [`transcript`] is only the wiring — when to publish, and what the
//! numbers mean once the daemon's own knowledge is in the same room. That
//! second part is the whole point: a tool in flight is `working` or
//! `waiting_hitl` depending on whether this process is holding a permission
//! request open, and only the daemon knows that.

#![forbid(unsafe_code)]

pub mod discovery;
pub mod hitl;
pub mod http;
pub mod origin;
pub mod registry;
pub mod socket;
pub mod titles;
pub mod transcript;

/// The protocol's Rust projection, re-exported from `aiterm-proto`.
///
/// It lives there, not here: `docs/PROTOCOL.md` says so, and every client of
/// the protocol — daemon, CLI, anything later — depends on the one definition
/// rather than keeping its own copy in step.
pub use aiterm_proto::wire;
