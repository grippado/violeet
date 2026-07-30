# aiterm

**This `aiterm`:** a native macOS terminal built for running several AI coding agents — Claude Code, Codex, opencode — as tabs in a single window, instead of scattering them across six terminal windows you lose track of. Tabs name themselves from what the agent is actually working on. A SwiftUI sidebar keeps one card per session showing its state, how full its context window is, and — the reason this exists — any permission request currently blocking that agent, answerable from the sidebar without switching tabs. It is the sibling of [aitop](https://github.com/grippado/aitop), which monitors agent sessions read-only from a TUI; `aiterm` is where you actually run them.

## Shape of the thing

| Component | Language | Job |
|---|---|---|
| `aiterm-daemon` | Rust | Owns all intelligence: session registry, HTTP endpoint for Claude Code hooks, JSONL transcript reading, token/context math. Serves clients over a Unix socket. |
| `aiterm-app` | Swift / SwiftUI | Native macOS app. Terminal tabs via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), sidebar in pure SwiftUI. A dumb client: renders and sends commands, computes nothing. |
| `aiterm-cli` | Rust | `aiterm doctor`, `aiterm install-hooks`, `aiterm uninstall-hooks`. |
| `aiterm-proto` | Rust | Serde types for the socket protocol, shared by daemon and CLI. |

The socket lives at `~/.aiterm/daemon.sock` and speaks JSON-lines — one object per line, discriminated by a `type` field. The contract is [`docs/PROTOCOL.md`](docs/PROTOCOL.md); it is frozen during a fan-out wave and changed only through the process described there.

## Status

Pre-implementation. This repository currently holds structure, ADRs and the protocol contract — no logic. See [`docs/adr/`](docs/adr/) for the decisions that got us here.

## Building

```bash
# Rust side
cargo build --workspace

# macOS app (the .xcodeproj is generated, not committed)
brew install xcodegen
cd app && xcodegen generate && open AITerm.xcodeproj
```

## License

MIT © Gabriel Gripp
