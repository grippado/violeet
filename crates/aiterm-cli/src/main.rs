//! `aiterm` CLI.
//!
//! Three jobs, deliberately no more:
//!
//! - `aiterm doctor` — is the daemon up, is the socket healthy, are the hooks
//!   installed and pointing at the right port
//! - `aiterm install-hooks` — write the aiterm hook entries into the user's
//!   Claude Code settings
//! - `aiterm uninstall-hooks` — take them back out, leaving other hooks intact
//!
//! Not implemented yet.

#![forbid(unsafe_code)]

fn main() {
    eprintln!("aiterm: not implemented yet — see docs/adr/ and docs/PROTOCOL.md");
}
