---
date: "2026-07-30"
type: decision
tags: [adr, violeet, binding, environment, hooks, session, tab]
status: accepted
---

# ADR-003: Bind tab to session through an `VIOLEET_TAB_ID` environment variable

> **Status:** accepted (2026-07-30)
> **Context:** the sidebar shows one card per agent session. Clicking a card should reveal the tab that session is running in, and a HITL card must know which tab is blocked. So each session has to be attributable to a tab — and the daemon learns about sessions from hooks, which know nothing about violeet.

## Context and problem

The app creates a tab and spawns a shell in a PTY. Some time later, possibly
after the user typed `claude` by hand, an agent starts and fires a hook at the
daemon. The daemon now has a `session_id` and needs to answer: *which tab is
this?*

Nothing in the hook payload helps. It carries `session_id`, `cwd`,
`transcript_path`, `permission_mode` — nothing about the terminal hosting it.
And the obvious correlators are all unreliable:

- **`cwd`** — two tabs in the same repo is the normal case, not the exception.
- **Process tree** — the agent is a grandchild of the shell we spawned, walking
  `ppid` chains works until a session is started under `tmux`, `direnv`, or a
  wrapper script, and the daemon is a separate process that would have to poll
  `proc` to do it.
- **Timing** — "the tab most recently interacted with" is a heuristic that
  breaks exactly when the user has several agents going, which is the entire
  reason this product exists.

Getting this wrong is not cosmetic. A misattributed HITL card offers the user a
permission decision for an agent they are not looking at.

## Decision

**The app mints a `tab_id` when it creates a tab and exports it into the child
environment as `VIOLEET_TAB_ID`. Every hook forwards that variable to the daemon,
and that is the whole binding mechanism.**

- The app sends `register_tab` with the `tab_id` **before** spawning the child,
  so the daemon can never receive a hook for a tab it has not heard of.
- The installed hook commands read `VIOLEET_TAB_ID` from the environment and
  include it in the payload they POST.
- A session whose hook reports no `VIOLEET_TAB_ID` registers with
  `tab_id: null`. It still appears on the board, still gets context and token
  readings, still raises HITL cards — it simply cannot be revealed in a tab.
  That is the honest state for an agent started in iTerm, and it is supported,
  not an error.
- Binding is **late-bindable**: a session that registered with `tab_id: null`
  may acquire one later, delivered as a `session_updated` carrying `tab_id`.

`tab_id` is opaque, minted by the app, and stable for the life of the tab. It is
not a PID, not an index, and not reused when a tab closes.

## Consequences

**Good**

- The binding is exact. No heuristic, no tie-break, no window where the wrong
  card is live.
- It survives arbitrary process nesting — `tmux`, `direnv`, `script`, a shell
  function, a wrapper — because environment variables are inherited by
  everything downstream for free.
- It degrades honestly: unknown becomes `null`, never a guess.
- It is trivially debuggable. `echo $VIOLEET_TAB_ID` in the tab answers the
  question.

**Bad, accepted**

- The variable leaks into every process the user runs in that tab. It is an
  opaque local id, so the exposure is uninteresting, but it is real and will
  show up in `env` dumps and bug reports.
- A user who copies a command with its environment into another terminal
  attributes that session to the wrong tab. Rare, self-inflicted, not worth
  defending against.
- Hooks must be installed for *any* attribution to work. The CLI's
  `install-hooks` and `doctor` carry that weight, and `doctor` should say
  plainly when hooks are missing rather than letting the board look merely
  empty.
- A session started before the app registered its tab is unbound forever unless
  late binding catches it.

**Neutral**

- Nothing about this is Claude Code specific. Codex and opencode adapters bind
  the same way if they can forward an environment variable.

## Alternatives considered

**Walk the process tree from the transcript's writer PID up to the PTY's
session leader.** No hook installation required, works for agents we did not
launch. Rejected: `tmux` and wrapper scripts break the chain, it needs polling
from a separate process, and it fails silently and unpredictably — the worst
property for something that gates a permission prompt.

**Match on `cwd` plus most-recent-activity.** Needs no environment at all.
Rejected outright: two agents in one repo is the normal case for this product,
and a wrong match here shows a permission dialog attributed to the wrong agent.

**A per-tab socket or a per-tab port.** Unambiguous by construction. Rejected as
far heavier: N sockets to manage, N ports to allocate and record, and the hook
configuration would have to be rewritten per tab rather than installed once.

**Write a marker file into a per-tab temp dir and have the agent's `cwd` point
at it.** Rejected: it constrains the user's working directory, which is not
ours to constrain.

**Inject a shell integration (`precmd` hook) that reports the tab.** Would also
work, and gives richer signal. Rejected for v0 as a much larger surface —
per-shell support, user rc files we would have to edit — for a benefit an
environment variable already delivers.
