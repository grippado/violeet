# Spikes

Preserved evidence, not documentation. These are the runs that measured how
Claude Code actually behaves, and they are in the repository because the
official documentation has been wrong about the same hook three separate times.

**When this project and the docs disagree about `PermissionRequest`, these files
win.**

## 2026-08-08 — a stopped session is not a session waiting for you

[`2026-08-08-parada-nao-e-pergunta.md`](2026-08-08-parada-nao-e-pergunta.md).
112 sessions, 835 stop points across `~/.claude/projects/**/*.jsonl`. **22% of
the moments a session goes quiet are a background task reporting in, not a
person being asked anything**, and the `Task` tool's `tool_result` lands
immediately at launch — so nothing is in flight by the time the session stops.

Two consequences, and only the first is implemented: the detection rule for
"write the answer" (`crates/violeet-transcript/src/answer_request.rs`), and a
pre-existing bug where the sidebar shows a session waiting on five background
agents as **idle**, sorted below sessions doing less. The write-up names the
three lines the bug lives on and does not fix it.

Reproduce with `cargo run --release --example answer_request_probe -p
violeet-transcript`.

## 2026-07-30 — `PermissionRequest`, holding and resolving a permission

[`RESULTADO.md`](RESULTADO.md) is the full write-up: verdict, method, the two
methodological traps that nearly invalidated it, and the three caveats that
shaped [ADR-004](../adr/ADR-004-hitl-via-permissionrequest-sem-injecao-pty.md).
Claude Code **v2.1.220**, TUI driven over a real PTY, with the session
transcript as the arbiter rather than the screen.

Rescued from `/tmp/violeet-spike` on 2026-07-31, where it would not have survived
a reboot.

### The part the daemon depends on

`scripts/hook-allow-0.sh` and `scripts/hook-deny.sh` are the hooks whose
decisions Claude Code **honoured**, confirmed as `err=False` in the transcript.
Their output is the shape `PermissionResponse` in
`crates/violeet-daemon/src/http/payload.rs` must produce, and there is a test
asserting it byte for byte:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

The documented shape — `permissionDecision` and `permissionDecisionReason` as
siblings of `hookEventName` — is **not** what worked. A well-meaning fix toward
the docs breaks HITL silently, so there is also a test asserting those key names
never appear.

`hook-payload.log` is the raw inbound payload, which is where the other two
documentation errors were caught: no `tool_use_id`, and a `permission_suggestions`
shape that does not match the published schema.

### Still unmeasured

`updatedInput` and `updatedPermissions` were never sent by any spike. The daemon
spells them camelCase to match their measured siblings and omits them unless a
client asks, so the measured path stays clean — but if the sidebar ever starts
amending tool input, that is the next thing to spike.

## Contents

| Path | What |
|---|---|
| `RESULTADO.md` | The write-up, in full |
| `hook-payload.log` | Raw `PermissionRequest` payloads as received |
| `scripts/hook-allow-0.sh` | Immediate allow — **the authoritative output shape** |
| `scripts/hook-deny.sh` | Deny with a reason, plus payload introspection |
| `scripts/hook-slow-allow.sh` | 90-second hold, then allow |
| `scripts/slow_server.py` | HTTP hook: `/slow-allow`, `/error-500`, `/never` |
| `scripts/pty_drive.py` | Drives the real TUI over a PTY and captures the screen |
| `scripts/pty_race.py` | Same, but presses `1` mid-hold — the race in ADR-004 |

The `settings-*.json` files from the original run were left behind; each one
registered a single hook against one of the scripts above, and the reproduction
recipe at the end of `RESULTADO.md` shows how they were used.
