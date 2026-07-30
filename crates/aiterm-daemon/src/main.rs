//! aiterm daemon.
//!
//! Owns the live picture of the product: which agent sessions exist, what state
//! they are in, and which ones are blocked on a permission request. Clients (the
//! macOS app, the CLI) are dumb: they render and they command.
//!
//! Module map, one per responsibility:
//!
//! - [`registry`] — live sessions, tab bindings, HITL bookkeeping
//! - [`http`]     — loopback HTTP endpoint receiving Claude Code hooks
//! - [`socket`]   — Unix socket server speaking JSON-lines (docs/PROTOCOL.md)
//!
//! Transcript reading and context math are deliberately *not* here: they live in
//! the `aiterm-transcript` crate, which Track C owns. The daemon does not depend
//! on it yet — that wiring lands in Wave 2 integration.
//!
//! No logic yet: the repository is at the structure-and-contract stage.

#![forbid(unsafe_code)]

mod http;
mod registry;
mod socket;

fn main() {
    eprintln!("aiterm-daemon: not implemented yet — see docs/adr/ and docs/PROTOCOL.md");
}
