//! Session registry: the daemon's source of truth.
//!
//! Holds every live agent session, its binding to a terminal tab (via
//! `AITERM_TAB_ID`, see docs/adr/ADR-003), and the pending HITL requests keyed
//! by the daemon-minted `hitl_id`.
//!
//! Not implemented yet.
