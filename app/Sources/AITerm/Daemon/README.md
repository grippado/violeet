# Daemon client

Connects to `~/.aiterm/daemon.sock`, reads JSON-lines, decodes by the `type`
discriminant, and publishes into SwiftUI state. Sends `register_tab`,
`close_tab`, `resolve_hitl`, `rename_session` and `request_snapshot`.

Normative contract: `docs/PROTOCOL.md`. This client is the Swift projection of
it; when the two disagree, the document wins. `crates/aiterm-proto` is the Rust
projection of the same document — keep the two shaped alike so a human can diff
them.

| File | Responsibility |
|---|---|
| `Protocol.swift` | Message types, the decoder, the outbound encoder. |
| `Discovery.swift` | Reads `~/.aiterm/daemon.json`. |
| `DaemonClient.swift` | The socket, the read loop, reconnection. |

## Three things that are easy to get wrong

**`session_updated` is a sparse patch with three states, not two.** Absent means
*unchanged*; an explicit `null` means *became unknown*. That is why those fields
decode into `Patch` rather than `T?` — collapsing them would make "the daemon
told us nothing" and "the daemon told us it no longer knows" the same value, and
the daemon goes out of its way to keep them distinct.

**Every daemon message is an idempotent upsert.** `request_snapshot` is answered
by replaying ordinary messages — no envelope, no end-of-snapshot marker — so a
`session_registered` for a session already on screen is normal traffic on every
reconnect, not a duplicate to detect. Getting this wrong writes a bug that only
shows up after the daemon restarts.

**An unknown `type` is ignored; an unknown `v` is dropped and logged.** They look
like the same tolerance and are not. Unknown fields and unknown message types are
how a later protocol version reaches an older client without breaking it. An
unknown `v` means the fields we *do* recognize may no longer mean what we think,
so the line goes in the bin and the status line says so.

## The daemon being down is a status, not an error

ADR-002 puts the daemon in its own process so that losing it loses the sidebar
and not the terminals. `DaemonClient` keeps that promise by making disconnection
ordinary: `send` drops what it cannot deliver, reconnection backs off on its own
(0.25s doubling to a 15s cap), and no caller checks the status before opening or
closing a tab.

That is also why nothing is queued while disconnected. The only messages that
would matter are `register_tab` — which the reconnect path re-sends for every
live tab, *before* `request_snapshot`, so a session the snapshot is about to
describe can already be bound to its tab — and a `close_tab` for a tab the
daemon never learned about, which it would ignore anyway. A queue would replay a
history the daemon has no use for.
