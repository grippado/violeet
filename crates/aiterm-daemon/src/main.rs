//! aiterm daemon.
//!
//! Owns every piece of intelligence in the product: which agent sessions exist,
//! what state they are in, how full their context windows are, and which ones
//! are blocked on a permission request. Clients (the macOS app, the CLI) are
//! dumb: they render and they command.
//!
//! Module map, one per responsibility:
//!
//! - [`registry`]  — live sessions, tab bindings, HITL bookkeeping
//! - [`http`]      — loopback HTTP endpoint receiving Claude Code hooks
//! - [`socket`]    — Unix socket server speaking JSON-lines (docs/PROTOCOL.md)
//! - [`transcript`] — JSONL transcript reading, token and context math
//!
//! No logic yet: the repository is at the structure-and-contract stage.

#![forbid(unsafe_code)]

mod http;
mod registry;
mod socket;
mod transcript;

fn main() {
    eprintln!("aiterm-daemon: not implemented yet — see docs/adr/ and docs/PROTOCOL.md");
}
