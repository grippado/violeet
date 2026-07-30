---
date: "2026-07-30"
type: decision
tags: [adr, aiterm, hitl, permissions, hooks, pty, claude-code]
status: accepted
---

# ADR-004: HITL rides on the `PermissionRequest` hook, with no PTY injection in v0

> **Status:** accepted (2026-07-30)
> **Context:** the headline feature is answering an agent's permission prompt from the sidebar without switching tabs. There are two ways to do that: intercept the decision through the agent's hook system, or type into the agent's terminal on the user's behalf.

## Context and problem

The reason to build aiterm rather than keep using tabs in iTerm is this: when
four agents are running, three of them are usually blocked on a permission
prompt you have not noticed. The sidebar should surface that and let you answer
it in place.

A spike against Claude Code **v2.1.220** (2026-07-30) established the ground
truth. Treat these as measured facts, not assumptions:

- A `PermissionRequest` hook **can hold a decision open for minutes**, and
  `allow`/`deny` are honoured. The old failure reported in
  anthropics/claude-code#19298 does not reproduce on this version.
- **The TUI dialog is rendered anyway, and stays live.** The hook does not
  replace the prompt; it races it. When the human answers in the tab first, they
  win — the hook's later answer is discarded.
- **Claude Code imposes no timeout.** A route that accepted the connection and
  never answered left the session hanging for over 11 minutes: no error, no
  `tool_result`, no fallback. Silence hangs the user's session.
- **Answering HTTP `500` drops cleanly into the normal interactive dialog.** It
  is the proven safe failure path.
- The payload carries **no `tool_use_id`**, contradicting the documentation, and
  `permission_suggestions` has the undocumented shape
  `{type: "addRules", rules: [...], behavior, destination}`.
- `PermissionRequest` **does not fire in headless mode** (`claude -p`).

So the mechanism works, but it is not authoritative, it has no safety net of its
own, and the identifier we would naturally correlate on does not exist.

## Decision

**HITL is implemented on the `PermissionRequest` hook. The daemon holds the HTTP
response open and resolves it three ways. aiterm does not write into the
agent's PTY in v0.**

The three resolutions, first one wins:

| Resolution | Trigger | Daemon answers | `hitl_resolved.origin` |
|---|---|---|---|
| App | client sends `resolve_hitl` | `200` + decision JSON | `app` |
| TUI | `PostToolUse` arrives matching the pending call | `500` | `tui` |
| Timeout | daemon's own deadline, default 5 min | `500` | `timeout` |

And three consequences of the spike, baked in as rules:

1. **The daemon mints its own `hitl_id`.** Nothing may depend on
   `tool_use_id`.
2. **The daemon owns the timeout, because the agent does not.** Default 5
   minutes, well under any human's patience for a stuck tab.
3. **No permission request may ever go unanswered.** Panic, parse failure,
   socket down, unknown bug — every path answers `500` in under a second, via a
   `catch_unwind` wrapper around the handler. Silence is strictly worse than
   denying. This is an architectural invariant, not a quality goal.

TUI-race detection correlates on `session_id` + `tool_name` + structural
equality of `tool_input`. **When the match is ambiguous, the daemon does not
resolve** — the timeout covers it. Clearing the wrong card is worse than
clearing it late.

The wire shape of all three is `hitl_resolved` in
[`docs/PROTOCOL.md`](../PROTOCOL.md).

## Consequences

**Good**

- Works with stock Claude Code, no patching, no fork, no scraping.
- Structured input: real `tool_name` and `tool_input`, not text parsed off a
  screen.
- The failure path is the status quo. Every way this can break lands the user in
  the interactive dialog they would have had without aiterm.
- The daemon never has to understand the terminal, so ADR-001's boundary stays
  clean.

**Bad, accepted**

- **The race is permanent and visible.** The dialog is on screen in the tab
  while the card is in the sidebar. Both work. Whichever is answered first
  wins, and a card can vanish under the user's cursor because they answered in
  the tab. This is documented as intended behaviour, not hidden.
- **When the TUI wins, we do not know what was chosen.** `hitl_resolved` carries
  `decision: null` for `origin: "tui"`. The sidebar cannot show an outcome it
  never learned.
- **Claude Code only, for now.** Codex and opencode have no equivalent hook.
  Their sessions appear on the board with context and state, but without HITL.
- **No headless support**, by measurement. `claude -p` never fires the event and
  we will not pretend otherwise.
- A hook that is slower than a competing `PermissionRequest` hook in the user's
  own settings loses silently. `aiterm doctor` should report other
  `PermissionRequest` hooks it finds.

**Neutral**

- The 5-minute default is a guess about human patience and belongs in config.

## Alternatives considered

**Type the answer into the PTY (`1\r`) on the user's behalf.** This is the only
approach that makes the sidebar authoritative, since it drives the same dialog
the user sees, and it would work for any agent with a keyboard-driven prompt —
Codex and opencode included. Rejected for v0: it requires reading the screen to
know a prompt is up and which option is which, which means screen-scraping a
live agent's TUI and betting on its layout; a wrong keystroke sent to a terminal
that is *not* showing a prompt is typed into the agent's input, or worse, into a
shell. The blast radius of a mis-timed injection is unbounded, and the hook path
gets us the feature with structured data and a safe failure mode. Reconsider
after v0, as a fallback for agents with no hook system, never as the primary
path for Claude Code.

**`PreToolUse` instead of `PermissionRequest`.** Fires earlier and can block
outright. Rejected: it fires for *every* tool call, not just the ones needing a
decision, so it cannot distinguish "the user must choose" from ordinary
activity, and it carries no `permission_suggestions`.

**Static allow/deny rules in settings, no interaction.** Policy without a human
in the loop. Rejected: it is a different product. It also does not remove the
dialog for anything the rules do not cover.

**Poll the transcript JSONL to detect a pending permission.** No hook install
required. Rejected: the transcript records a `tool_result` only *after* the
decision, so by the time it is observable there is nothing left to decide. It is
a read-only signal, useful for state but useless for HITL.

**Wrap the `claude` binary in a shim that owns the prompt.** Rejected: fragile
against upstream changes, breaks the moment the user runs `claude` from
somewhere else, and duplicates a mechanism the tool already offers.
