# Terminal

Terminal tabs: VT emulation and PTY handling via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
See `docs/adr/ADR-001` for why we host SwiftTerm instead of writing an emulator.

Each spawned tab exports `VIOLEET_TAB_ID` into the child environment; that is the
whole tab-to-session binding mechanism (`docs/adr/ADR-003`).

| File | Responsibility |
|---|---|
| `TerminalSession.swift` | The PTY: environment injection, cwd, lifecycle. |
| `TerminalHostView.swift` | The `NSViewRepresentable` seam, and nothing else. |
| `ProcessDirectory.swift` | Asks the kernel where a shell is. |

## Three things measured the hard way

**A login shell, or the user's `PATH` is wrong.** An app launched from Finder
inherits almost no environment. `startProcess` is given `argv[0]` with a leading
dash — the only way Unix has to say "login shell" — so the shell reads the rc
files that build the environment the user actually has. Without it, Homebrew is
not on `PATH` and nothing the user types works the way it does in iTerm.

**An interactive shell ignores `SIGTERM`.** SwiftTerm's `terminate()` closes the
PTY and sends `SIGTERM`, which a `zsh` at a prompt simply declines. Closing a tab
therefore removed it from the window and left its shell running forever — one
orphan per closed tab, invisible, discovered only by counting processes.
`TerminalSession.terminate()` follows with `SIGHUP`, which is the signal that
means "your terminal went away" and the one a shell honours, and `SIGKILL` after
a grace period for anything that has blocked even that.

**No stock macOS shell reports its working directory.** OSC 7 is the well-behaved
answer and macOS only emits it when `TERM_PROGRAM` is `Apple_Terminal`. So the
cwd is read from the kernel with `proc_pidinfo`, polled, and OSC 7 is honoured
as a bonus when a configured shell does send it. See the header of
`ProcessDirectory.swift` for the alternatives and why they lost.

## Terminal views are never rebuilt

`TerminalHostView.makeNSView` returns a view that already exists, owned by the
tab. SwiftUI recreates representable *values* freely; a terminal whose NSView
were rebuilt on an update pass would lose its scrollback and its PTY with it —
which is to say switching tabs would kill agents. For the same reason every tab
stays mounted in the window's `ZStack`, with only visibility moving.
