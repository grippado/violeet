//! Wire types for the aiterm daemon socket protocol.
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
//! No logic lives here yet: the repository is at the structure-and-contract
//! stage. Types land with the wave that implements them.

#![forbid(unsafe_code)]

/// Protocol version carried in the `v` field of every message.
pub const PROTOCOL_VERSION: u32 = 1;

/// Default relative path of the daemon socket, under the user's home.
pub const SOCKET_RELATIVE_PATH: &str = ".aiterm/daemon.sock";

/// Default relative path of the daemon discovery file, under the user's home.
pub const DAEMON_JSON_RELATIVE_PATH: &str = ".aiterm/daemon.json";

/// Default TCP port for the loopback HTTP hook endpoint.
pub const DEFAULT_HOOK_PORT: u16 = 9847;
