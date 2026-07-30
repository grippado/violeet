//! Loopback HTTP endpoint for Claude Code hooks.
//!
//! Binds 127.0.0.1 only. Informational hook routes answer immediately and never
//! block; `/hook/permission-request` blocks by design until the app resolves it,
//! the human wins the race in the TUI, or the daemon's own timeout fires.
//!
//! See docs/adr/ADR-004 for why HITL rides on `PermissionRequest` and for the
//! semantics of the three resolutions.
//!
//! Not implemented yet.
