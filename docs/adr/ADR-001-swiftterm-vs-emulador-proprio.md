---
date: "2026-07-30"
type: decision
tags: [adr, violeet, terminal, swift, swiftterm, vt]
status: accepted
---

# ADR-001: Host SwiftTerm rather than write our own terminal emulator

> **Status:** accepted (2026-07-30)
> **Context:** violeet needs real VT emulation and PTY handling in a native macOS app. The question is whether that comes from an existing Swift library or from a Rust core we write and bridge.

## Context and problem

violeet is, first and last, a terminal. Agents like Claude Code drive the screen
hard: alternate screen buffer, bracketed paste, mouse reporting, OSC sequences
for the title, truecolor, wide glyphs and combining marks, resize during a
render. Anything short of correct here is not a rough edge, it is the product
being broken.

Writing a VT emulator is a genuinely large, genuinely boring problem, and the
failure mode is the worst kind: it mostly works, then corrupts one pane during a
long agent run and you cannot reproduce it. We already learned from `aitop` that
the interesting part of this family of products is *reading agent state*, not
pushing bytes to a grid.

There is a real pull toward Rust here. The daemon is Rust; crates like `alacritty_terminal`
and `wezterm-term` are mature; keeping emulation in Rust would put more of the
codebase in one language. But the terminal has to render inside a SwiftUI window
alongside a SwiftUI sidebar, which means either a Metal/CoreText renderer we also
write, or an FFI bridge feeding a Swift view — one more layer between a
keystroke and a glyph, on the hottest path in the app.

## Decision

**Use [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for VT emulation
and PTY handling, embedded directly in the SwiftUI app.**

- SwiftTerm owns the terminal grid, parsing, scrollback, selection, and the PTY
  lifecycle.
- The app hosts `TerminalView` via `NSViewRepresentable` and otherwise stays out
  of its way.
- The daemon never touches the terminal. It learns about sessions through hooks
  and transcripts, never by scraping the screen (see ADR-004).

## Consequences

**Good**

- VT correctness is someone else's solved problem, maintained by the author of
  the macOS terminal most likely to have already hit our edge cases.
- No FFI on the keystroke path. Native AppKit text rendering, native IME, native
  accessibility.
- The Rust/Swift boundary stays exactly one thing — a JSON-lines socket — which
  is testable with `nc` and readable by a human.

**Bad, accepted**

- We inherit SwiftTerm's bugs and its release cadence, and a fix we need may
  require a PR upstream or a fork. Acceptable: that is still less work than
  owning an emulator.
- Terminal behaviour is now unavailable to non-macOS clients forever. Fine —
  this is a macOS product by definition. `aitop` is the cross-platform sibling.
- We cannot reuse the emulator for a future headless/CI mode. If that ever
  matters, it argues for a separate tool, not for this decision being wrong.

**Neutral**

- SwiftTerm is pinned via SwiftPM in `app/project.yml` and `app/Package.swift`.
  Both must move together on a version bump.

## Alternatives considered

**`alacritty_terminal` or `wezterm-term` in Rust, bridged to Swift.** More code
in the language the daemon already speaks, and both are excellent. Rejected
because the bridge lands precisely on the latency-sensitive path, and because we
would still have to write the renderer, the selection model and the IME handling
in Swift anyway — we would be adopting a parser, not an emulator, and paying FFI
for it.

**Wrap an existing terminal app (iTerm2 via AppleScript, Terminal.app).** No
control over tabs, no way to embed a sidebar, automation surface far too thin
for per-tab environment injection. Rejected immediately.

**`SwiftTerm` in a `WKWebView` with xterm.js.** Web stack in a native app,
noticeably worse latency and memory, and an awkward story for PTY and IME.
Rejected.

**Write our own emulator in Swift.** Same objection as writing one in Rust,
minus the FFI cost and minus the mature-crate benefit. Strictly worse than
adopting SwiftTerm.
