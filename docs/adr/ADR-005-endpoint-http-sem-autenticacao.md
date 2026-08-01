---
date: "2026-08-01"
type: decision
tags: [adr, aiterm, security, http, hooks, authentication, threat-model]
status: accepted
---

# ADR-005: The hook endpoint is unauthenticated in v0, deliberately

> **Status:** accepted (2026-08-01)
> **Context:** the daemon listens on a loopback TCP port for Claude Code's hooks and publishes that port in a file any local process can read. Nothing verifies that a request came from Claude Code. This ADR exists to make that a decision on the record rather than something nobody got round to.

## Context and problem

The daemon binds `127.0.0.1` on a port it publishes in `~/.aiterm/daemon.json`,
and answers two routes: `/hook/event` and `/hook/permission-request`. There is
no token, no signature, no check on the caller. Any process running as this user
can read the discovery file, learn the port, and POST whatever it likes.

That is not a hypothetical. Three concrete abuses, in ascending order of how
much they matter:

**A forged session.** POST a `SessionStart` payload with an invented
`session_id` and the sidebar grows a card for an agent that does not exist. It
would sit there until it expired for inactivity. Cosmetic, confusing, harmless.

**A forged tab binding.** POST with an `x-aiterm-tab-id` header naming a tab
that *does* exist and the fake session attaches to a real tab. Now the sidebar
misattributes: a card claiming to be the agent in tab 2 is not. ADR-003 went to
some trouble to make binding exact rather than heuristic, and this walks around
that guarantee from outside.

**A resolved permission request.** This is the one that matters. When the daemon
is holding a `PermissionRequest` open, a local process that guesses or observes
the `hitl_id` can send `resolve_hitl` over the socket — or, more simply, race
the human by answering the HTTP request the daemon is waiting on. The outcome is
that something other than the user allows a tool call the user was being asked
about. **The blast radius of that is the blast radius of the tool call**, which
for `Bash` is unbounded.

The socket has filesystem permissions and is now `0600` inside a `0700`
directory (wave 2). The TCP port has nothing. It is on TCP only because Claude
Code's `http` hook type requires a URL, which is exactly the trade ADR-002
described when it put the *client* channel on a Unix socket and left the hook
endpoint on loopback.

## Decision

**Ship v0 with the hook endpoint unauthenticated, on the explicit reasoning
below, and record the mitigation now rather than discovering it later.**

The reasoning, stated as an assumption so it can be checked rather than
assumed:

> **aiterm's threat model for v0 is a single-user machine where every local
> process is already trusted.**

On such a machine an attacker who can POST to loopback can also read
`~/.claude/`, write to `~/.claude/settings.json`, install their own hook, or
simply run `claude` themselves. Authentication on this endpoint would not be
the weakest link; it would be a lock on one door of a house with no walls.

This is a real limit and not a universal one. It stops being true on a shared
machine, a multi-user build box, or anywhere untrusted code runs as this user —
a sandboxed-but-local process, a compromised dependency in a project the agent
is working on, a malicious VS Code extension. In those settings the argument
above does not hold, and this decision should be revisited before aiterm is used
there.

### What is *not* accepted

Two things are out of scope for the acceptance and stay as they are:

- **The endpoint stays bound to `127.0.0.1`.** Binding `0.0.0.0` would turn a
  local trust assumption into a network one and is not covered by any of this.
- **The `500`-always invariant stands** (ADR-004). Authentication must never
  become a new way for a permission request to go unanswered — a rejected
  request still answers, and answers `500`, so the agent falls back to its own
  dialog.

## Proposed mitigation, for when the assumption stops holding

**A shared secret in a header.**

- The daemon generates a random token at startup and writes it into
  `~/.aiterm/daemon.json`, which is already `0600` in a `0700` directory — so
  the token is readable by exactly the accounts that could already reach the
  socket.
- `aiterm install-hooks` reads it and writes it into each hook entry as
  `"headers": {"x-aiterm-token": "$AITERM_TOKEN"}` with `AITERM_TOKEN` in
  `allowedEnvVars`, or inlines the literal value.
- The daemon rejects any request whose token does not match, with `500` on
  `/hook/permission-request` so the invariant above survives.

Two known costs, worth writing down before someone implements it and is
surprised:

1. **Token rotation invalidates installed hooks.** A daemon that generated a
   fresh token every start would silently break the hooks in the user's settings
   on every restart — the hooks would fire, be rejected, and the board would go
   quiet with no error the user ever sees. Either the token is persisted across
   restarts, or `install-hooks` has to be re-run each time, and the second is
   not acceptable. `aiterm doctor` should compare the two and report a mismatch,
   because this failure is otherwise invisible.
2. **The token would sit in the user's settings file in plaintext.** That is the
   same trust boundary as the discovery file, so it adds no new exposure — but
   it does mean the settings file becomes something worth not pasting into a bug
   report, which it currently is not.

**Not implemented in this ADR.** Writing it down is the deliverable; the
mitigation lands when the threat model changes or when someone wants to run
aiterm somewhere the assumption above is false.

## Consequences

**Good**

- No token plumbing in v0: nothing to rotate, nothing to leak, nothing to get
  out of step between the daemon and the settings file.
- The failure mode we would be defending against is dominated by failures we
  cannot defend against anyway at this trust boundary.
- The mitigation is designed and costed, so adopting it is an implementation
  task rather than a design one.

**Bad, accepted**

- A local process can forge sessions, forge tab bindings, and answer permission
  requests the user was being asked about. The third is the serious one and it is
  accepted only under the single-user assumption stated above.
- `aiterm doctor` cannot currently tell a forged session from a real one, and
  will not be able to until there is a token to check.
- Anyone deploying aiterm outside the stated threat model inherits a decision
  they did not make. This document is the mitigation for that: it is findable,
  and it says plainly when it stops applying.

**Neutral**

- The discovery file's `0600` and the `~/.aiterm` directory's `0700` (wave 2)
  narrow *who can find the port*, which is defence in depth rather than
  authentication. A process that can read the file is not the only process that
  can find a listening port on loopback.

## Alternatives considered

**Authenticate now with a shared token.** The mitigation above, implemented
today. Rejected for v0 not because it is wrong but because it is premature: it
adds a rotation-and-mismatch failure mode (cost 1 above) that is *silent*, in
exchange for closing a hole that the threat model says is already open by five
other routes. A silent failure traded for a theoretical one is a bad trade at
this stage.

**Unix socket for hooks too.** Would get filesystem permissions for free, as the
client channel does. Rejected because it is not available: Claude Code's `http`
hook type takes a URL, and there is no socket-path form. A `command` hook
shelling out to `curl --unix-socket` would work and was rejected separately — it
puts a shell and a `curl` on the hot path of every hook, and the whole reason
the CLI writes `http` hooks is that a `command` hook is a fork per event.

**Verify the caller's pid via `SO_PEERCRED` / `LOCAL_PEERPID`.** Establishes
which process is calling. Rejected: it authenticates the *process*, and every
local process is the same user here, so it answers a question we are not asking.
It would also break the moment a hook is legitimately proxied.

**Bind to a random high port and rely on it being unguessable.** Rejected
outright — the port is published in a file specifically so clients do not have to
guess, so it is not secret from anything that can read the file, and a port scan
of loopback finds it in milliseconds regardless. Obscurity that the design
itself removes is not a control.
