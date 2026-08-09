# Spike: Cursor hooks → violeet daemon

Date: 2026-08-09. Ticket: LAB-61.

## Goal

Confirm what Cursor sends on stdin, whether `session_id` is stable across a
composer session, and how HITL responses must be shaped for
`beforeShellExecution` / `beforeMCPExecution`.

## Adapter

`~/.violeet/cursor-hook.sh` (from `scripts/cursor-hook.sh`) reads stdin JSON,
maps Cursor hook names to the daemon's Claude Code spellings, and POSTs to:

- `POST /hook/event` — informational hooks (`x-violeet-harness: cursor`)
- `POST /hook/permission-request` — shell/MCP gates

Port comes from `~/.violeet/daemon.json` at runtime (not baked into hooks.json).

## Event mapping

| Cursor `hook_event_name` | Daemon `hook_event_name` | Route |
|---|---|---|
| `sessionStart` | `SessionStart` | `/hook/event` |
| `sessionEnd` | `SessionEnd` | `/hook/event` |
| `beforeSubmitPrompt` | `UserPromptSubmit` | `/hook/event` |
| `stop` | `Stop` | `/hook/event` |
| `beforeShellExecution` | `PermissionRequest` (`tool_name`: `Bash`) | `/hook/permission-request` |
| `beforeMCPExecution` | `PermissionRequest` | `/hook/permission-request` |

## Stdin samples (from Cursor docs + blog measurement)

### `sessionStart`

```json
{
  "session_id": "668320d2-2fd8-4888-b33c-2a466fec86e7",
  "hook_event_name": "sessionStart",
  "is_background_agent": false,
  "composer_mode": "agent",
  "workspace_roots": ["/Users/you/www/personal/violeet"]
}
```

`session_id` equals `conversation_id` for the composer session. violeet uses it
as `session_id` on the wire — never invented.

### `beforeSubmitPrompt`

```json
{
  "conversation_id": "668320d2-2fd8-4888-b33c-2a466fec86e7",
  "generation_id": "490b90b7-a2ce-4c2c-bb76-cb77b125df2f",
  "prompt": "add cursor harness to daemon",
  "hook_event_name": "beforeSubmitPrompt",
  "workspace_roots": ["/Users/you/www/personal/violeet"],
  "composer_mode": "agent"
}
```

No `session_id` field — adapter falls back to `conversation_id`.

### `stop`

```json
{
  "conversation_id": "668320d2-2fd8-4888-b33c-2a466fec86e7",
  "generation_id": "490b90b7-a2ce-4c2c-bb76-cb77b125df2f",
  "hook_event_name": "stop",
  "status": "completed",
  "loop_count": 0
}
```

### `sessionEnd`

```json
{
  "session_id": "668320d2-2fd8-4888-b33c-2a466fec86e7",
  "hook_event_name": "sessionEnd",
  "reason": "completed",
  "duration_ms": 45000,
  "is_background_agent": false
}
```

### `beforeShellExecution`

```json
{
  "conversation_id": "668320d2-2fd8-4888-b33c-2a466fec86e7",
  "command": "cargo test -p violeet-daemon",
  "cwd": "/Users/you/www/personal/violeet",
  "hook_event_name": "beforeShellExecution",
  "workspace_roots": ["/Users/you/www/personal/violeet"]
}
```

### `beforeMCPExecution`

```json
{
  "conversation_id": "668320d2-2fd8-4888-b33c-2a466fec86e7",
  "tool_name": "run_terminal_cmd",
  "tool_input": "{\"command\":\"ls\"}",
  "hook_event_name": "beforeMCPExecution",
  "url": "https://example.com/mcp"
}
```

## `session_id` stability

Per Cursor docs, `sessionStart.session_id` is the composer session identifier
and matches `conversation_id` on subsequent hooks in the same chat. Adapter rule:
use `session_id` when present, else `conversation_id`. Do not mint ids.

Manual check (daemon running, hooks installed):

1. `violeet install-cursor-hooks --yes`
2. Open Agent chat in Cursor, send one prompt, wait for stop.
3. `violeet sessions` — one session id, stable across hooks.
4. Close chat → `sessionEnd` → card ends in app.

## HITL response format

Claude Code (daemon `/hook/permission-request` response):

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" }
  }
}
```

Cursor expects stdout JSON:

```json
{
  "permission": "allow",
  "user_message": "optional when deny",
  "agent_message": "optional"
}
```

Adapter translation:

| Daemon `behavior` | Cursor `permission` |
|---|---|
| `allow` | `allow` |
| `deny` | `deny` (+ `user_message` from `reason`) |
| HTTP 500 / timeout / no daemon | `ask` (fail-open; IDE dialog remains) |

Measured gap: Cursor has no `hookSpecificOutput` wrapper — unlike Claude Code.
The spike does not send `updatedInput` / `updatedPermissions` back to Cursor;
only allow/deny/ask were exercised.

## Production fixes (2026-08-09, post-merge smoke)

1. **Stdin heredoc** — embedding Python in `cursor-hook.sh` via `<<'PY'` stole
   stdin when Cursor piped JSON. Shell now `cat`s stdin into `CURSOR_HOOK_INPUT`
   before exec.
2. **`beforeSubmitPrompt` stdout** — Cursor expects `{"continue": true}`; silence
   reads as failure.
3. **Double hook load at `$HOME` workspace** — when the workspace root is
   `$HOME`, `~/.cursor/hooks.json` is also the project hooks file; Cursor runs
   user + project hooks → duplicate invocations. Adapter debounces identical
   `(hook_event_name, session_id)` within 750ms via
   `~/.violeet/cursor-hook-debounce.json`.

## Manual validation

```bash
# daemon must be running
violeet-daemon &
violeet install-cursor-hooks --yes
violeet doctor   # ✓ Cursor hooks installed, port from daemon.json

# simulate sessionStart (replace port from daemon.json)
printf '%s' '{"session_id":"test-cursor-1","hook_event_name":"sessionStart","workspace_roots":["/tmp"]}' \
  | ~/.violeet/cursor-hook.sh

violeet sessions   # agent: cursor, harness header → purple card in app
```

## Install record

`~/.violeet/installed.json` gains `cursor_hooks: true` after install; `doctor`
flags if hooks.json is rewritten without the adapter.
