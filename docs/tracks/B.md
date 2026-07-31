---
date: "2026-07-31"
type: log
tags: [aiterm, track-b, app, swift, swiftui, swiftterm]
---

# Track B — the app: window, tabs, terminal

Wave 1. Scope as briefed: `app/` plus this file. Protocol frozen, read before
starting, not extended — no `docs/tracks/B-protocol-request.md` was needed.

## What is done and tested

Everything below was exercised against the real `aiterm-daemon` (the committed
`target/debug/aiterm-daemon`), not a mock, in a build installed as
`~/Applications/aiterm.app` and driven by hand.

**The window.** One window, sidebar left, terminals right, drag handle between.
Sidebar is resizable (160–480 pt) and collapsible. Not a `NavigationSplitView`:
that owns its column widths and its collapse behaviour and negotiates both with
the system, and all three are things this app needs to own — see the header of
`ContentView.swift`.

**Tabs and PTYs.** Each tab runs the user's shell as a **login** shell through
SwiftTerm 1.15.0, hosted by exactly one `NSViewRepresentable`
(`TerminalHostView`) and nothing else. Every tab stays mounted in a `ZStack`
with only visibility moving, because a terminal that left the view hierarchy
would have its NSView torn down and its PTY with it — switching tabs would kill
agents.

**The binding (ADR-003).** A fresh UUID per tab, exported as `AITERM_TAB_ID`
alongside `AITERM_SOCKET`, and `register_tab` is sent **before** the child is
spawned so the daemon can never see a hook naming a tab it has not heard of.
Verified end to end: `echo $AITERM_TAB_ID` in a tab returned
`447a0aea-…`, and a hook posted with that id came back as
`session_registered` carrying that `tab_id` — which it could only do if
`register_tab` had already arrived.

**`close_tab`.** ⌘W on one of two tabs produced exactly one `session_ended`
with `reason: "tab_closed"` for that tab's session, with the other tab left
running. ⌘Q closed both and produced one `session_ended` each.

**Graceful degradation.** Killed the daemon with a tab open: app alive, shell
alive, socket file gone. Restarted it: the client reconnected on its own and
showed up as an established client connection on the new daemon's socket.

One caveat on that last test, stated rather than glossed: what was *observed*
was the reconnection, by inspecting the daemon's open descriptors. The
re-sending of `register_tab` on reconnect was not observed directly — it would
have needed one more round of reading a tab id out of the window. It is the same
code path as the first connect, which was observed, but it is inference and not
measurement, and the difference is worth a sentence.

**Shortcuts.** ⌘T new tab, ⌘W close tab, ⌘⇧] / ⌘⇧[ next and previous (wrapping),
⌘1–⌘8 by position with ⌘9 as "last", ⌘⌥S toggle sidebar, ⌘+ / ⌘− font size.

**Persistence.** Window frame via AppKit's autosave name; sidebar width and
collapsed state and font name/size via `UserDefaults`. Tabs and scrollback are
deliberately *not* restored — restoring a tab would mean restoring a process,
and a tab whose shell is gone is a lie about state the user can act on.

**Packaging.** `app/scripts/package.sh` builds a universal binary, assembles the
bundle by hand, signs it (Developer ID if `AITERM_SIGN_IDENTITY` is set, ad-hoc
otherwise) and emits a `.dmg` and a `.zip`. Ran locally, produced both, and the
resulting `.app` is the one all the testing above was done with.

## Three bugs worth remembering

**An interactive shell ignores `SIGTERM`.** SwiftTerm's `terminate()` closes the
PTY and sends `SIGTERM`, which a `zsh` at a prompt declines. Closing a tab
removed it from the window and left the shell running forever — one orphan per
closed tab, invisible in the UI, found by counting child processes across a test
run. `TerminalSession.terminate()` now follows with `SIGHUP` (the signal that
means "your terminal went away") and `SIGKILL` after a 2 s grace.

**`.disabled` on a SwiftUI command latches.** `Close Tab` was
`.disabled(state.selectedTabID == nil)`, which SwiftUI evaluated against the
state the menu was first built in — empty — and a disabled item does not fire
its key equivalent. The guard now lives inside the action, where it cannot
latch.

**AppKit localizes its standard menus.** The removal of the stock ⌘W item
originally looked up a menu titled `File`; on a Portuguese system it is
`Arquivo`, so the lookup found nothing and left two items claiming the shortcut.
It now searches every submenu by selector, and runs again on
`applicationDidBecomeActive` because SwiftUI rebuilds the menu bar after
`applicationDidFinishLaunching`.

## Stubs and deliberate omissions

- **The sidebar shows tabs, not session cards.** As briefed. `AppState` does
  decode and store every `session_registered`, `session_updated` and
  `hitl_pending` — including the three-way sparse patch — so the data is
  arriving; it is simply not drawn. No placeholder card, on purpose: a layout
  designed before its inputs exist gets defended later because it is there.
- **`resolve_hitl` and `rename_session` are encoded but never sent.** No UI
  raises them yet. They are in the projection because leaving them out would
  make the next wave edit the wire format instead of the view.
- **The working directory is polled, not subscribed.** No stock macOS shell
  emits OSC 7 outside Apple Terminal, so the cwd comes from `proc_pidinfo` every
  2 s, with OSC 7 honoured when a configured shell does send it.
- **Tests cover `Protocol.swift` and nothing else.** Added after the wave, on
  Gabriel's argument, which is the right one: the sparse-patch decoder is the
  only place in the app where a mistake is *silent*. Everything else fails
  loudly — a broken PTY is a dead tab, a broken socket is an offline badge —
  where a bad decode renders a value the session no longer has and looks like a
  daemon bug from the outside.

  **They do not run on this machine.** Neither `Testing` nor `XCTest` ships with
  Command Line Tools, and there is no Xcode here, so `swift test` fails with "no
  such module". CI runs them; locally they are compiled by nobody. `swift build`
  and `scripts/package.sh` still need nothing but CLT, so this is the one place
  the toolchain floor is higher than the rest of the repo's.

## What I nearly changed outside my scope, and did not

- **`docs/PROTOCOL.md` says "Status: v1", the brief said v2.** I coded against
  the file, which is normative and which the brief also told me to read. Not
  edited, not reconciled — flagging it here instead. Nothing in my
  implementation depends on the answer: the wire `v` is `1` either way, which is
  what the daemon accepts.
- **`.gitignore` ignored `app/Package.resolved`.** I force-added the file rather
  than editing a root file that was not mine, and flagged the line as track A's
  call. Gabriel's correction: track A is finished, nobody is contending for the
  root any more, and the line had already done its job. Removed in a follow-up
  commit — the ignore rule and the force-add were contradicting each other, and
  a repo where the two disagree is a repo where the next person reverts the
  wrong one.
- **`crates/aiterm-daemon` `/health` reports a session as live after its
  `session_ended`.** Observed while testing; the registry appears to keep ended
  sessions until they expire. Did not touch it. Track A's.

## Deviations from the fan-out rules, authorized mid-wave

Both by explicit instruction from Gabriel during the wave, overriding the brief:

1. **Rule 5 said no push.** He created `github.com/grippado/aiterm` and asked for
   everything to go to origin. Added the remote (SSH — HTTPS had no credential)
   and pushed `main`. The working tree had no other track's uncommitted work at
   the time; I checked before pushing and committed nothing but my own paths.
2. **Rule 1 confined me to `app/`.** He asked for GitHub CI producing `.dmg`
   releases, which needs `.github/workflows/`. I wrote two files there, named
   `app-*` so a Rust workflow from track A cannot collide with them, and neither
   one builds or gates the other's code.

Also outside the repo, for testing only: the app was installed to
`~/Applications/aiterm.app` (the computer-use tooling only resolves apps in
standard locations).

**A mistake worth recording.** I reported two `zsh` processes on ttys008 and
ttys009 as orphans left by the pre-`SIGHUP` runs, and killed them when asked.
They were not ours. Both ttys had real terminal sessions underneath — `login` →
`-zsh` → `claude`, parented to the terminal app — and the two pids were almost
certainly prompt workers (p10k/gitstatus) belonging to those sessions. The
sessions survived; their prompts likely lost git status until reopened. The
diagnosis rested on `ppid == 1` plus a timestamp that overlapped the test run,
which is not enough to attribute a process, and I presented it with more
confidence than it earned.

## Repository hygiene, checked after the push

`docs/spikes/` went public-repo-shaped before anyone audited it. Checked:
`grep -rniE 'gabriel|grippado|arco|isaac|/Users/'`. The only hits are
`/Users/grippado/…` in home paths — the `cwd` of every captured payload is
`/private/tmp/aiterm-spike` and every `tool_input` is `/bin/date
+SPIKE_MARKER_*`. No client repo path, no work context, no secret. The spike's
discipline held.

The repository is **private with zero forks**, so nothing was exposed and no
history rewrite is warranted. If it is ever made public, normalizing
`/Users/grippado/` to `/Users/you/` in `docs/spikes/` (which is the convention
`PROTOCOL.md` already uses) is a two-minute job and the only thing outstanding.

## Assumptions about the other tracks

- **Track A (daemon) is done and its wire format is the one in
  `crates/aiterm-proto`.** I read it to cross-check my projection rather than to
  copy it, and both are checked against `docs/PROTOCOL.md`.
- **The `x-aiterm-tab-id` header is the hook's business, not mine.** The app
  only exports the environment variable; whatever `aiterm install-hooks` writes
  is what forwards it. I used the header directly to inject test sessions, which
  is not something the app ever does.
- **`aiterm-cli` and `aiterm-transcript` do not exist and are not needed.** The
  app never shells out to either. `AITERM_SOCKET` is exported for a future CLI's
  benefit and nothing in this build reads it back.
- **Nobody else touches `app/`.** All of `Package.swift`, `project.yml` and
  `Info.plist` are edited here on that assumption. `project.yml` no longer has
  an `info:` block, because XcodeGen's `info:` *generates* `Info.plist` and
  would overwrite the file `package.sh` copies into the bundle.
