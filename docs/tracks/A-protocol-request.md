# Track A — protocol change requests

Raised against `docs/PROTOCOL.md` v1, frozen at commit `a77a1ac`.

**Nothing here has been implemented on the wire.** Per rule 2 of the fan-out
brief, the protocol is frozen and the other tracks are coding against it as it
stands. Every item below is either carried in the daemon's *internal* model
only, or worked around in a way that is documented at the call site.

Ordered by how much it costs to leave unfixed.

---

## 1. There is no app→daemon message for "the tab closed" — **blocking a stated requirement**

**What the task asks for:** "Sessão vira `dead` quando o app avisa que a aba
fechou."

**What the protocol has:** `session_ended` (daemon→app) accepts
`reason: "tab_closed"`, so the *outcome* is expressible. But there is no message
in the app→daemon direction that lets the app say it. The four are
`register_tab`, `resolve_hitl`, `rename_session`, `request_snapshot`.

**Consequence today:** `Registry::close_tab()` is implemented and unit-tested,
but nothing can reach it over the socket. A closed tab's sessions stay alive
until the inactivity TTL kills them — up to 30 minutes of a card for a tab that
is gone.

**Proposed addition** (app→daemon):

```json
{ "type": "close_tab", "v": 1, "ts": "...", "tab_id": "tab-7f3a" }
```

The daemon marks every session claiming that tab `dead` and emits
`session_ended` with `reason: "tab_closed"` for each. Symmetric with
`register_tab`, and needs no other change.

**Also affects Track B:** the app has no way to report tab closure until this
exists.

---

## 2. `session_registered.cwd` is required and non-null, but cwd is not always known

**What the protocol says:** `cwd` is `string`, required, with no null allowed —
unlike `title` and `model`, which are explicitly `string | null`.

**Reality:** a session first observed through a hook that did not carry a working
directory has no cwd. The registry holds `Option<String>` and refuses to invent
one.

**Workaround in place:** `Hub::session_registered` sends `""` when cwd is
unknown. This is schema-compliant and marked `TODO(track-A)` at the call site,
but it is exactly the fabrication the "never invent state from an empty value"
rule exists to prevent — an empty string will render as an empty path rather
than as `—`.

**Proposed change:** make `cwd` `string | null`, matching `title` and `model`.
One-word edit; no new message.

---

## 3. The wire state set does not cover the lifecycle the task specifies

**Task states:** `starting | idle | working | waiting_hitl | done | dead`
**Protocol `session_updated.state`:** `idle | working | waiting_input | hitl | error`

| Internal | Wire | Note |
|---|---|---|
| `Starting` | *(none)* | No "known but unobserved" state exists. We omit `state` rather than guess — in a sparse patch, absent means *unchanged*, so this is honest but it does mean a brand-new session shows no state at all until it moves. |
| `Idle` | `idle` | |
| `Working` | `working` | |
| `WaitingHitl` | `hitl` | |
| `Done` / `Dead` | *(none)* | Reported by `session_ended`, which has no `state` field. |

Two protocol states have **no internal counterpart** and are currently
unreachable: `waiting_input` and `error`. Nothing in the daemon can produce
them.

**Proposed change:** either add `starting` to the protocol's set, or drop
`waiting_input`/`error` from it if nothing will ever emit them. As it stands the
document promises two states that do not exist and omits one that does.

---

## 4. Token telemetry: the wire carries two numbers, the model needs four

**Protocol `session_updated`:** `context_tokens`, `context_window`.

**Task requirement, and the registry's model:**

| Internal field | Meaning | Wire |
|---|---|---|
| `context_window_used_tokens` | current occupancy; **falls** on compaction | `context_tokens` |
| `context_window_size_tokens` | the model's window | `context_window` |
| `cumulative_input_tokens` | monotonic; for cost | **no wire field** |
| `cumulative_output_tokens` | monotonic; for cost | **no wire field** |

The first two map cleanly, modulo naming. The cumulative pair has nowhere to go.

**Why this matters more than it looks:** the whole reason the task spells out
four separate fields is that summing the cumulative pair to estimate window
occupancy yields a wrong-but-plausible number. A protocol that carries only the
occupancy pair cannot express cost at all, and the first person who wants a cost
readout in the sidebar will be tempted to derive it from `context_tokens` —
which is precisely the bug.

**Proposed addition** to `session_updated`, same sparse-patch semantics:

```
cumulative_input_tokens   integer | null
cumulative_output_tokens  integer | null
```

Optionally rename the existing pair to `context_window_used_tokens` /
`context_window_size_tokens` so all four say what they are. That rename is
breaking; the addition is not.

**Note:** none of this is urgent for Wave 1. All four fields are `None` until
Track C's `aiterm-transcript` fills them.

---

## 5. `harness` vs `agent`, and the missing `unknown` value

**Protocol:** `session_registered.agent`, values `claude-code | codex |
opencode`. The document says unknown values are "rendered generically, not
dropped".

**Task:** calls the field `harness` and includes `unknown` as an explicit
fourth value.

**Workaround in place:** the internal type is `Harness` with an `Unknown`
variant; it serializes to the wire field `agent` as the string `"unknown"`.
That is consistent with the document's instruction to render unknown values
generically, so nothing is broken — but `"unknown"` is not in the enumerated
list, and a strict client could reject it.

**Proposed change:** add `unknown` to the documented value list. Naming
(`agent` vs `harness`) is cosmetic; I did not change it and would leave it.

---

## 6. `git_branch` and `transcript_path` have no wire representation

Both are in the task's session model and both exist in the registry. Neither
appears in `session_registered` or `session_updated`.

`transcript_path` is arguably internal — the app has no use for it, and Track C
consumes it in-process. `git_branch` is display data the sidebar will want.

**Proposed addition** to `session_updated`: `git_branch: string | null`.
No opinion on `transcript_path`; leaving it off the wire seems right.

---

## 7. Minor: no way to report that a session's `last_event_at` moved

`session_updated` has no timestamp for the session's own last activity, only the
envelope's `ts` (when the daemon emitted the message). A sidebar wanting to show
"quiet for 4 minutes" cannot, and would have to infer it from when messages stop
arriving — which is exactly the "infer state from absence of data" pattern the
task forbids.

**Proposed addition:** `last_event_at: string` on `session_updated`.

Low priority; listed for completeness.
