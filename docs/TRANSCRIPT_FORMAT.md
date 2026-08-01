---
date: "2026-07-31"
type: reference
tags: [aiterm, transcript, claude-code, jsonl, telemetry]
---

# Claude Code transcript format

What `~/.claude/projects/<slug>/<session-id>.jsonl` contains, as observed on
**Claude Code v2.1.220** on 2026-07-31, across 520 files in 41 project
directories.

This document has three sections on purpose: **measured**, **inferred**, and
**not determined**. There is no published schema for this format, and this
project has already been burned three separate times by treating documentation
as authority for how Claude Code behaves (see `docs/spikes/README.md`). So the
distinction between "I counted this" and "this seems likely" is load-bearing,
and anything in the third section is a gap, not a detail.

Method, so the claims can be checked: a Python pass over the raw files to count
and cross-tabulate, then the Rust parser in `crates/aiterm-transcript`, then a
comparison of the two on the same files. Where a number appears below, both
arrived at it independently.

---

## 1. Measured

### File layout

One JSONL file per session, named for the session id, under a directory named
for the project path with separators replaced by `-`. Sub-agent transcripts live
in a `subagents/` subdirectory of a session directory.

Largest file observed: **15 MB**. That number is the reason the reader tails
from an offset rather than re-parsing.

### Line types

Every line is a JSON object with a `type`. Observed values:

| `type` | What it is |
|---|---|
| `assistant` | One content block of an assistant reply |
| `user` | A user message, or a tool result |
| `system` | Lifecycle and instrumentation, discriminated by `subtype` |
| `attachment` | Attached content |
| `mode`, `permission-mode` | Mode changes |
| `ai-title`, `last-prompt` | UI bookkeeping |
| `queue-operation` | Prompt queue |
| `file-history-snapshot`, `file-history-delta` | Edit history |

Observed `system.subtype` values, by frequency: `turn_duration` (830),
`stop_hook_summary` (828), `away_summary` (213), `local_command` (31),
`scheduled_task_fire` (29), **`compact_boundary` (17)**, `informational` (7),
`bridge_status` (4).

Fields present on essentially every line: `uuid`, `sessionId`, `timestamp`,
`cwd`, `version`, `gitBranch`, `userType`, `entrypoint`, `isSidechain`,
`parentUuid`.

### One reply is several lines, and every one repeats the same `usage`

**This is the single most important thing in this document.**

Claude Code writes **one JSONL line per content block**, not one per message.
Every one of those lines carries the *entire message's* `usage` object.

Counted in one file (`099399e5-…`):

- 803 lines of `type: "assistant"`
- **344** distinct `message.id`
- content blocks: 227 `thinking` + 252 `text` + 324 `tool_use` = **803**

The block count equals the line count exactly. Summing `usage` per line rather
than per `message.id` inflates cumulative output from **404,098** to
**1,124,616** — 2.8x — and the wrong number looks entirely plausible.

Deduplication key: `message.id`. `requestId` had identical cardinality (344) in
the same file and would work equally well; `uuid` is per line and would not.

### `usage`

On `assistant` lines, at `message.usage`:

```json
{
  "input_tokens": 26111,
  "cache_creation_input_tokens": 16189,
  "cache_read_input_tokens": 25153,
  "output_tokens": 3491,
  "server_tool_use": { "web_search_requests": 0, "web_fetch_requests": 0 },
  "service_tier": "standard",
  "cache_creation": { "ephemeral_1h_input_tokens": 16189, "ephemeral_5m_input_tokens": 0 },
  "iterations": [ … ],
  "speed": "standard"
}
```

Only the first four are read. The rest are real but not needed, and modelling a
format we do not control earns nothing.

### Window occupancy is the prompt of the latest turn

`input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of the
**most recent** assistant turn is the current occupancy of the context window:
the prompt of the latest call is the conversation as the model currently sees
it.

It is a **reading**, not an accumulation. Measured occupancy at the end of one
session: **662,536** tokens, while that session's cumulative output was
**404,098**. Neither is derivable from the other, and adding the cumulative pair
to estimate occupancy produces a number that is wrong, plausible, monotonically
increasing, and never falls when the window is actually emptied.

### Compaction, with numbers from the file itself

A `system` line with `subtype: "compact_boundary"` carries `compactMetadata`:

```json
{
  "trigger": "manual",
  "preTokens": 337228,
  "postTokens": 15850,
  "cumulativeDroppedTokens": 321378,
  "durationMs": 172673,
  "preCompactDiscoveredTools": ["TaskGet", "TaskList", "TaskStop"],
  "preservedSegment": { "headUuid": "…", "anchorUuid": "…", "tailUuid": "…" },
  "preservedMessages": { "anchorUuid": "…", "uuids": [ … ], "allUuids": [ … ] }
}
```

`preTokens` and `postTokens` are the occupancy before and after, **measured and
written by Claude Code** — we do not have to infer the drop. Observed
`trigger` values: `auto` (14) and `manual` (3). The following line is a `user`
line with `isCompactSummary: true` carrying the summary itself.

Across 20 sampled files, every compaction with both numbers had
`postTokens < preTokens`. There is a test asserting exactly that against the
real files.

### Tools

A `tool_use` content block:

```json
{ "type": "tool_use", "id": "toolu_…", "name": "Bash",
  "input": { "command": "…", "description": "…" }, "caller": … }
```

Results come back on a `user` line, in **two** observed spellings: a
`tool_result` content block carrying `tool_use_id`, and a `sourceToolUseID`
field on the line itself. Both are handled.

In a completed session, all 324 `tool_use` ids had a matching result — zero
orphans.

### Model

`message.model` on assistant lines. Observed: `claude-sonnet-5`,
`claude-opus-4-8`. It is per message, so a session that switched models has
both, and the latest wins.

---

## 2. Inferred

Reasonable, not measured. Each of these could be wrong without anything
noticing.

**`message.id` is stable across the lines of one reply.** Measured to be
*consistent* — 344 ids over 803 lines, and blocks summing exactly to lines — but
that the id is *guaranteed* stable is an inference from a sample, not a
documented contract.

**The last assistant turn's prompt size is the current occupancy.** The
arithmetic is measured; that Claude Code's own context indicator uses the same
definition is inferred. If it counts something else — a system prompt not
reflected in `usage`, say — this reads slightly low.

**`requestId` would work as a deduplication key.** Same cardinality as
`message.id` in every file checked. Not used, so not exercised.

**Compaction is always announced before its effect appears.** The boundary line
precedes the next assistant turn in the files examined. A reader that trusted
ordering absolutely would break if that ever inverted; the implementation
applies `postTokens` immediately and lets the next real turn overwrite it, so it
degrades rather than breaking.

---

## 3. Not determined

Gaps. Named rather than guessed at.

### Context window size is not in the file — and not in the model name either

**There is no field carrying it.** Every file under `~/.claude/projects` was
searched for a window, limit or max-tokens key and there is none — the only
matches for "window" were an unrelated browser tool named `resize_window`.

The first implementation filled it from a lookup table keyed on model name, and
**that was wrong the day it shipped.** Measured 2026-08-01: a live session on
`claude-opus-5` — no suffix, nothing unusual about the id — ran against a
**one-million** token window while the table said 200,000. The card showed 24%
where Claude Code's own status line showed 5%. The occupancy reading was
correct; only the divisor was invented.

The failure is structural rather than a missing entry. **The window is a
property of the account and the model together.** The same model id is 200k for
one user and 1M for another depending on what their plan enables, so no table
keyed on the name is right for everyone — and one that is right for its author
is the most dangerous kind, because it passes every test they run.

`window_size_for_model` therefore returns `None` unconditionally now, and is
kept only as the place where the question is asked and answered. The gauge
renders indeterminate, `aiterm doctor` names the affected sessions, and the
percentage is absent rather than wrong.

**The authoritative source exists, outside the transcript.** Claude Code passes
it to the status line command on stdin (documented in the binary, extracted
2026-08-01):

```
"context_window": {
  "total_input_tokens": number,
  "total_output_tokens": number,
  "context_window_size": number,   // the real window for this model+account
  "current_usage": { "input_tokens", "output_tokens",
                     "cache_creation_input_tokens", "cache_read_input_tokens" } | null,
  "used_percentage": number | null,
  "remaining_percentage": number | null
},
"rate_limits": {                   // Claude.ai subscribers, after first response
  "five_hour": { "used_percentage": number, "resets_at": number },
  "seven_day": { "used_percentage": number, "resets_at": number }
}
```

**This is now implemented.** `aiterm install-statusline` writes a wrapper that
forwards the payload to the daemon and then runs the user's original status line
with the same stdin, printing its output verbatim — nothing about their prompt
changes on screen. The daemon exposes `POST /statusline` for it. Verified
end to end against the real `ccstatusline`: the bar rendered identically and the
daemon published `context_window_size_tokens: 1000000` for a `claude-opus-5`
session that a lookup table had claimed was 200k.

It delivers the 5-hour and weekly usage limits at the same time, which are
likewise absent from the transcript and available nowhere else.

### There is no pending-permission signal

Searched for: zero occurrences of any permission-request marker in the sampled
files, and every `tool_use` in a completed session had a matching result. This
confirms what ADR-004 established by a different route — the transcript records
a `tool_result` only *after* a decision, so by the time a permission request is
visible here there is nothing left to decide.

The crate therefore exposes `in_flight_tool` — a tool call with no result yet —
and **does not call it a pending HITL**. An in-flight tool may be blocked on a
human, blocked on the network, or simply slow, and the transcript cannot tell
the three apart. The real HITL signal comes from the daemon's
`PermissionRequest` hook.

This is a deliberate departure from the task as briefed, which asked for "the
pending HITL text". It is not obtainable from this source.

### Not investigated

- **`iterations` inside `usage`.** Present, plural on some turns, not read. What
  a multi-iteration turn means for cost is unexamined.
- **`cache_creation` sub-fields** (`ephemeral_1h`, `ephemeral_5m`). Read only in
  aggregate via `cache_creation_input_tokens`.
- **Sub-agent transcripts.** Files exist under `subagents/`. Whether their usage
  should roll up into the parent session's cost is a product question that has
  not been asked, let alone answered.
- **`file-history-snapshot` / `file-history-delta`.** Ignored entirely.
- **Codex and opencode formats.** Not examined at all. `TranscriptReader` exists
  so they can be added; nothing about their shape is known here.
- **Whether a resumed session appends to the same file or starts a new one.**
  The tailing code handles a shrinking file by restarting, which covers the case
  either way, but the actual behaviour was not observed.

---

## Consequences for the implementation

`crates/aiterm-transcript` follows from the above:

- usage is counted **once per `message.id`**
- occupancy is **last-write-wins from one turn**, cost is a **sum over turns**,
  and they are computed in different places so they cannot be confused
- `compactMetadata.postTokens` is applied directly, because the file's own
  number beats anything we would derive
- every field is `Option`; a real `0` survives as `Some(0)` and stays distinct
  from unknown
- nothing panics or errors on malformed input, because the format changes
  without notice and a hard failure would silently take out telemetry for a
  whole session
