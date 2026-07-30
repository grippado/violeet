# Daemon client

Connects to `~/.aiterm/daemon.sock`, reads JSON-lines, decodes by the `type`
discriminant, and publishes into SwiftUI state. Sends `register_tab`,
`resolve_hitl`, `rename_session` and `request_snapshot`.

Normative contract: `docs/PROTOCOL.md`. This client is the Swift projection of
it; when the two disagree, the document wins.

Not implemented yet.
