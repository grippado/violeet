# Violeet

**[grippado.github.io/violeet →](https://grippado.github.io/violeet/)** · a terminal for watching agents work.
Named after the colour it has always used, and shipping with
[Violeeter](https://github.com/grippado/violeeter), that colour as a palette anyone can take.


**This `violeet`:** a native macOS terminal built for running several AI coding agents (Claude Code, Codex, opencode) as tabs in a single window, instead of scattering them across six terminal windows you lose track of. Tabs name themselves from what the agent is actually working on. A SwiftUI sidebar keeps one card per session showing its state, how full its context window is, and, the reason this exists, any permission request currently blocking that agent, answerable from the sidebar without switching tabs. It is the sibling of [aitop](https://github.com/grippado/aitop), which monitors agent sessions read-only from a TUI; `violeet` is where you actually run them.

<img width="2056" height="1290" alt="image" src="https://github.com/user-attachments/assets/5b80ca79-26fe-45ad-9ef9-cddc9f21bddd" />


## Shape of the thing

| Component | Language | Job |
|---|---|---|
| `violeet-daemon` | Rust | Owns all intelligence: session registry, permission-request bookkeeping, HTTP endpoint for Claude Code hooks. Serves clients over a Unix socket. |
| `violeet-transcript` | Rust | JSONL transcript reading, token and context math. A pure library: it takes a path and returns typed events plus telemetry, and knows nothing about the socket or the registry. The daemon depends on it, not the other way round. |
| `violeet-app` | Swift / SwiftUI | Native macOS app. Terminal tabs via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), sidebar in pure SwiftUI. A dumb client: renders and sends commands, computes nothing. |
| `violeet-cli` | Rust | `violeet doctor`, `violeet install-hooks`, `violeet uninstall-hooks`. |
| `violeet-proto` | Rust | Serde types for the socket protocol, shared by daemon and CLI. |

The socket lives at `~/.violeet/daemon.sock` and speaks JSON-lines: one object per line, discriminated by a `type` field. The contract is [`docs/PROTOCOL.md`](docs/PROTOCOL.md); it is frozen during a fan-out wave and changed only through the process described there.

## Status

**All four pieces exist and talk to each other.** Verified against a real Claude Code v2.1.220, not against mocks.

- `violeet-daemon`: session registry, Unix socket server, hook endpoint and HITL, plus transcript telemetry. Run it, point Claude Code's hooks at it, and watch a permission request block and then resolve over the socket.
- `violeet-app`: window, tabs and a working terminal via SwiftTerm, with the sidebar listing tabs. The session cards are the next piece of work.
- `violeet-transcript`: reads Claude Code JSONL incrementally and reports the four token numbers, the model and the last action. What it could *not* determine is written down as plainly as what it could: see [`docs/TRANSCRIPT_FORMAT.md`](docs/TRANSCRIPT_FORMAT.md) § 3.
- `violeet-cli`: `doctor`, `install-hooks` and `uninstall-hooks`.

Two numbers that look alike and are not: **window occupancy** falls when the context is compacted, **cumulative cost** only climbs. Adding the cumulative pair to estimate occupancy produces a plausible, wrong number, and the code says so at the point somebody would be tempted.

See [`docs/adr/`](docs/adr/) for the decisions that got us here, and [`docs/tracks/`](docs/tracks/) for what each piece actually guarantees, including, in each log, what was measured versus inferred.

## Building

```bash
# Rust side
cargo build --workspace

# macOS app (the .xcodeproj is generated, not committed)
brew install xcodegen
cd app && xcodegen generate && open Violeet.xcodeproj
```

## License

MIT © Gabriel Gripp
