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
//! - [`wire`]     — the JSON-lines message types of `docs/PROTOCOL.md`.
//! - [`socket`]   — the Unix socket server that speaks [`wire`] to clients.
//!
//! Transcript reading and context math are deliberately *not* here: they live in
//! the `aiterm-transcript` crate, which Track C owns. The daemon does not depend
//! on it yet — that wiring lands in Wave 2 integration.
//!
//! The HTTP endpoint that receives Claude Code hooks is the next task and does
//! not exist yet.

#![forbid(unsafe_code)]

pub mod registry;
pub mod socket;
pub mod wire;
