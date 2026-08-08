//! Wire types for the violeet daemon socket protocol.
//!
//! `docs/PROTOCOL.md` is the normative contract; this crate is its Rust
//! projection. When the two disagree, the document wins and this crate is the
//! bug.
//!
//! The protocol is frozen during a fan-out wave. Changing a type here is
//! changing the contract for every track at once, so it goes through the
//! process in `docs/PROTOCOL.md § Changing this protocol` — not through a
//! unilateral edit.
//!
//! The message types live in [`wire`]. They were written inside
//! `violeet-daemon` during Wave 1, because this crate was outside Track A's
//! scope and the no-edits-outside-scope rule was absolute; they moved here on
//! 2026-07-31, once the wave was over and one owner could touch both crates.
//! This is where the document always said they belonged.

#![forbid(unsafe_code)]

pub mod wire;

/// Protocol version carried in the `v` field of every message.
pub const PROTOCOL_VERSION: u32 = 1;

/// Default relative path of the daemon socket, under the user's home.
pub const SOCKET_RELATIVE_PATH: &str = ".violeet/daemon.sock";

/// Default relative path of the daemon discovery file, under the user's home.
pub const DAEMON_JSON_RELATIVE_PATH: &str = ".violeet/daemon.json";

/// Default TCP port for the loopback HTTP hook endpoint.
pub const DEFAULT_HOOK_PORT: u16 = 9847;
