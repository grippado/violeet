---
date: "2026-07-30"
type: decision
tags: [adr, violeet, daemon, ipc, unix-socket, ffi, rust, swift]
status: accepted
---

# ADR-002: The daemon is a separate process behind a Unix socket, not an FFI library

> **Status:** accepted (2026-07-30)
> **Context:** the Rust intelligence (session registry, hook endpoint, transcript reading) has to reach a SwiftUI app.
>
> **Wording updated 2026-08-01.** The decision stands unchanged; the prose below
> described transcript parsing as happening *inside the daemon process*, which
> was true when this was written and is now imprecise. Parsing lives in the
> `violeet-transcript` crate, which the daemon depends on and links in. The
> crate is a pure library — no socket, no registry, no runtime — but it does run
> in the daemon's address space, so every blast-radius argument below applies to
> it exactly as written. A panic in transcript parsing still must not be able to
> kill live PTYs, and it still cannot, because the PTYs are in another process. Either it is linked into the app as a static library over FFI, or it runs as its own process and talks over IPC.

## Context and problem

`violeet-daemon` owns everything that is not pixels: which sessions exist, what
they are doing, how full their context windows are, and which of them are
blocked on a permission request. The app renders that. The two have to
communicate.

The FFI route is tempting: one process, one lifecycle, no serialization, no
socket to clean up. But three constraints push hard the other way.

**The hook endpoint must outlive the app's UI.** Claude Code hooks fire over
HTTP against a port that has to be listening whenever an agent is running. A
spike on v2.1.220 established that a `PermissionRequest` hook can hold a
decision open for minutes and that the agent imposes **no timeout of its own** —
a route that never answers left a session hanging for over 11 minutes with no
error. Whatever holds that connection must not be coupled to a UI event loop
that can hitch, beachball, or be quit by the user mid-request.

**A crash must not take the terminal with it.** The daemon parses JSONL written
by other tools, at their schema's discretion. That is exactly the code most
likely to panic on an unexpected shape. In an FFI build, a Rust panic crossing
the boundary is undefined behaviour at worst and a dead app at best — taking
every running agent's PTY with it. Losing a sidebar is an annoyance; losing four
live agent sessions is data loss.

**Agents run outside violeet too.** A Claude Code session started in iTerm should
still appear on the board. That only works if the hook endpoint and registry
exist independently of whether the app is open.

## Decision

**`violeet-daemon` runs as its own process. Clients talk to it over a Unix domain
socket at `~/.violeet/daemon.sock`, JSON-lines, one object per line, discriminated
by `type`.**

- The daemon owns the HTTP hook endpoint, the registry, and all computation.
- The app is a **dumb client**: it renders and it sends commands. It computes no
  token counts and no context percentages. `session_updated` carries
  `context_tokens` and `context_window`; the app divides them for display and
  derives nothing else.
- The CLI is another client of the same socket, with no privileged path.
- The contract is `docs/PROTOCOL.md`, frozen during fan-out waves.

### An unrecognized hook still updates what it carries

Deliberate, and load-bearing enough to state here rather than leave as an
implementation detail somebody tidies away.

An event whose `hook_event_name` this daemon does not know maps to
`HookEvent::Unrecognized`, and `Unrecognized` **still feeds `cwd`,
`transcript_path` and liveness into the registry**. It derives no lifecycle
state — it has no basis for one — but it is not discarded.

That is what makes the daemon degrade well when Claude Code adds an event. It
was measured in wave 2: `CwdChanged` was being installed by `violeet
install-hooks` for a whole wave before the daemon enumerated it, and the working
directory on a card stayed correct throughout, because the unrecognized event
carried a `cwd` and the registry applied it. Enumerating the event later bought
clarity, not a bug fix.

**Do not "fix" this by rejecting unknown events.** Doing so would trade a
daemon that quietly keeps working against a newer agent for one that silently
stops updating the moment the agent ships an event we have not enumerated — and
the symptom would be a stale card with no error anywhere, which is the worst
shape a failure can take.

### Addendum, 2026-08-09: reading git is allowed; computing telemetry is not

**The decision stands unchanged.** What follows fixes a wording that was precise
enough while there was one caller and stops being so now that there are two.

"The daemon owns the HTTP hook endpoint, the registry, and **all computation**"
was written when nothing in the app shelled out to anything. Two places now run
`git` directly: `app/Sources/Violeet/Model/FileHistory.swift`, which runs
`git log -1` for an editor tab, and the LAB-6 diff core, whose intended producer
is `git diff` for the file the reader has open. Read literally, "all computation"
forbids both, and neither is the thing this ADR was defending against.

The rule the ADR is actually enforcing, stated so it does not have to be
reconstructed from first principles in every new file:

> **The app may ask git about the working tree. The app may not recompute a
> number the daemon observed being made.**

The distinction is provenance, not tooling. `context_tokens`, `context_window`
and the per-file `+n −n` are *observations of a session*: the daemon read them
out of a transcript as they happened, and a second measurement taken later from
the checkout would disagree — `docs/PROTOCOL.md` spells out why, at length, for
`files`. An app that recomputed them would be a second opinion on a fact it did
not witness, and the two opinions would drift with no way to tell which was
stale.

The content of a diff is not in that category. The daemon never had it: it sums
`structuredPatch` to two integers and discards *which* line changed. There is no
daemon answer for the app to disagree with, so reading it locally creates no
second source of truth.

Two limits, so this does not become a licence:

- It covers reads of the working tree that produce **content**, not counts. A
  diff's text, a file's last commit, a branch name. The moment the app is
  tempted to derive a session metric from git, it is on the wrong side of the
  line, whatever the mechanism.
- Where a daemon field already exists, the daemon field wins. The app renders it
  and does not check it.

The convention for recording this in code stays what `FileHistory` established:
a header comment on the file that shells out, saying which of the two categories
it is in. This addendum exists so that argument is made once here instead of
rebuilt, slightly differently, in each new file.

## Consequences

**Good**

- A daemon panic loses the sidebar, not the terminals. The app reconnects and
  sends `request_snapshot`.
- The hook endpoint is up whenever the daemon is, regardless of the app.
- The boundary is inspectable by a human with `nc -U ~/.violeet/daemon.sock`, and
  testable without building a macOS app at all — which is what makes parallel
  fan-out across tracks possible.
- Rust and Swift keep independent build and release cycles. No bridging headers,
  no `cbindgen`, no `@_silgen_name`.

**Bad, accepted**

- Two lifecycles to manage: startup, discovery, stale-socket cleanup, orphan
  daemons. `violeet doctor` exists precisely to make that debuggable.
- Serialization cost on every update. Irrelevant at this scale — these are
  human-rate events, not a render loop.
- The app must handle "daemon not running" as a real, ordinary state and not as
  an error dialog.
- Two processes to sign and ship in one `.app` bundle.

**Neutral**

- The daemon writes `~/.violeet/daemon.json` with pid, socket path and the
  **effective** hook port, so clients discover rather than assume.
- Nothing in the protocol is macOS-specific, so a future non-macOS client is
  possible. Not a goal.

## Alternatives considered

**Static Rust library over FFI.** Simplest to ship, best latency. Rejected on
the crash-blast-radius argument alone: a panic in transcript parsing must not be
able to kill live PTYs. That argument is about *which process* the parsing runs
in, not which crate it lives in — `violeet-transcript` runs inside the daemon,
which is the whole point of the daemon being separate from the app. The hook-endpoint lifetime argument is independent and
also fatal.

**Daemon in Swift, no Rust at all.** One language, one process, trivially
embedded. Rejected because the transcript/context logic is the part we most want
to share lineage with `aitop`, and because Swift's story for a long-lived
headless daemon on macOS is worse than Rust's.

**HTTP/WebSocket on localhost for the client channel too.** Would reuse the hook
server. Rejected: it puts the client channel on a TCP port any local process can
reach, where a Unix socket gets filesystem permissions for free. The hook
endpoint is on TCP only because Claude Code requires a URL.

**gRPC or a schema'd IPC (protobuf, Cap'n Proto).** Real type safety across the
boundary. Rejected as premature: JSON-lines is debuggable with `cat`, and the
message set is small enough that a hand-written document plus two projections is
honest. Revisit if the protocol outgrows one page.
