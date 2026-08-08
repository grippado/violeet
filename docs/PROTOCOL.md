# violeet socket protocol

> **Wire version `v` = 1. Document revision 7.**
>
> These are two different numbers and conflating them has now cost time twice:
> two separate tracks were briefed that the protocol was "v2, frozen", read
> "Status: v1" at the top of this file, and had to stop and work out which was
> authoritative.
>
> - **`v` is what goes on the wire.** It is `1`. Every message carries `"v": 1`,
>   `violeet_proto::PROTOCOL_VERSION` is `1`, and a receiver drops anything
>   greater. Changing it is a code change in three projections, not an edit
>   here.
> - **The revision number counts edits to this document.** Revision 2 was the
>   2026-07-31 pass that absorbed the seven change requests in
>   [`tracks/A-protocol-request.md`](tracks/A-protocol-request.md). Revision 3
>   (2026-08-01) added `cumulative_tokens_partial`. Neither bumped `v`:
>   revision 2 for the reason recorded below, revision 3 because adding an
>   optional field is backward compatible by the rule in *Envelope*. Revision 6
>   (2026-08-01) added `release_session_title`, an inbound message: a new
>   `type` is ignored by older receivers, which is the same rule. Revision 7
>   (2026-08-08) added `answer_request` and `pending_agents`, both optional
>   fields of `session_updated`, absorbing the Track C request — same rule
>   again, so `v` stays `1`. (That request is `docs/tracks/C-protocol-request.md`
>   on the `feat/write-the-answer` branch, unlinked here because this revision
>   lands first; it is marked absorbed when that branch merges.)
>
> When a brief says "the protocol is at v2", it means this document's second
> revision. The wire is still `1`.

Status: **normative.**

This document is the contract between `violeet-daemon` and its clients. The Rust
types in `crates/violeet-proto` and the Swift decoder in
`app/Sources/Violeet/Daemon` are *projections* of this document. When a
projection and this document disagree, the document is right and the code is the
bug.

> **Why the revision did not bump `v`.** Two of the seven changes are breaking:
> the token fields were renamed, and two unreachable states were removed. The
> rule below says a change between waves bumps `v` — and it was waived here,
> once, deliberately. No peer speaks v1 outside this repository: the daemon is
> the only implementation, and it was updated in the same commit. Bumping would
> have made the daemon reject messages from nobody and spent the number on
> ceremony. **This waiver does not survive the first release.** Once a build
> ships, or once the Swift app can talk to a daemon it did not come packaged
> with, the rule is back in force with no judgement call attached.

---

## Transport

- Unix domain socket, `SOCK_STREAM`, at `~/.violeet/daemon.sock`.
- The daemon creates the socket with mode `0600` and unlinks a stale one on
  startup. It is a local, single-user channel: there is no authentication and no
  attempt at one.
- **JSON-lines.** One JSON object per line, UTF-8, terminated by `\n` (`0x0A`).
  No pretty-printing, no embedded raw newlines. A line longer than 1 MiB is
  dropped by the receiver rather than buffered.
- Full duplex. Either side may write at any time; there is no request/response
  pairing and no message ids. Correlation happens through domain identifiers
  (`session_id`, `hitl_id`).
- Multiple clients may connect at once. Every daemon→app message is broadcast to
  all connected clients.

### Discovery

The daemon writes `~/.violeet/daemon.json` on startup:

```json
{
  "pid": 4823,
  "socket": "/Users/you/.violeet/daemon.sock",
  "hook_port": 9847,
  "protocol_version": 1,
  "started_at": "2026-07-30T18:02:11Z"
}
```

Clients read this rather than assuming the port. The hook port is configurable
and `9847` is only the default; the file carries the **effective** port.

---

## Envelope

Every message, both directions:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `type` | string | yes | Discriminant. Values enumerated below. |
| `v` | integer | yes | Protocol version. `1` today. |
| `ts` | string | yes | RFC 3339 / ISO 8601 with timezone, when the sender emitted it. |

Receivers **must ignore unknown fields** and **must ignore messages with an
unknown `type`**. That is what lets a later version add both without breaking an
older peer. Receivers must *not* ignore an unknown `v`: a message with a `v`
greater than the reader supports is dropped and logged.

---

## Identifiers

| Id | Minted by | Shape | Notes |
|---|---|---|---|
| `session_id` | the agent | opaque string | Claude Code's own session UUID, read from the hook payload. Never invented by violeet. |
| `tab_id` | the app | opaque string | Generated when a tab is created, exported to the child process as `VIOLEET_TAB_ID`. See ADR-003. |
| `hitl_id` | **the daemon** | opaque string | Minted per permission request. |

> **`hitl_id` exists because `tool_use_id` does not.** The `PermissionRequest`
> hook payload in Claude Code v2.1.220 carries no `tool_use_id`, despite the
> documentation listing one. There is no agent-side identifier for a permission
> request, so the daemon mints its own. Nothing in this protocol may be built on
> `tool_use_id`.

---

## Messages: daemon → app

### `session_registered`

A new agent session became known to the daemon.

```json
{
  "type": "session_registered", "v": 1, "ts": "2026-07-30T18:02:44Z",
  "session_id": "b497437c-e819-4d0c-9145-03eb6573f8ef",
  "tab_id": "tab-7f3a",
  "agent": "claude-code",
  "cwd": "/Users/you/www/personal/violeet",
  "title": "Add HTTP hook endpoint",
  "model": "claude-opus-5",
  "started_at": "2026-07-30T18:02:44Z"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `session_id` | string | yes | |
| `tab_id` | string \| null | yes | `null` when the session could not be bound to a tab (agent started outside violeet). |
| `agent` | string | yes | `claude-code` \| `codex` \| `opencode` \| `unknown`. Values outside this list are rendered generically, not dropped. |
| `cwd` | string \| null | yes | `null` when the session was first seen through a hook that carried no working directory. Never `""` — an empty string renders as an empty path instead of as *unknown*. |
| `title` | string \| null | yes | `null` until the daemon has something real to name it with. Never a placeholder. |
| `model` | string \| null | yes | `null` when unknown. |
| `started_at` | string | yes | |

### `session_updated`

A **sparse patch**. Only `type`, `v`, `ts`, `session_id` are always present;
every other field is optional and, when absent, means *unchanged* — not *null*.
An explicit `null` means *became unknown*.

```json
{
  "type": "session_updated", "v": 1, "ts": "2026-07-30T18:04:02Z",
  "session_id": "b497437c-e819-4d0c-9145-03eb6573f8ef",
  "state": "working",
  "context_window_used_tokens": 39104,
  "context_window_size_tokens": 200000,
  "last_action": "Edit crates/violeet-daemon/src/http/mod.rs"
}
```

| Field | Type | Notes |
|---|---|---|
| `state` | string | `starting` \| `idle` \| `working` \| `hitl` |
| `title` | string \| null | |
| `model` | string \| null | |
| `cwd` | string \| null | Emitted on `cwd-changed`. |
| `title_source` | string \| null | `cwd` \| `prompt` \| `ai_title` \| `user`. Who named the session — see below. |
| `context_window_used_tokens` | integer \| null | Current occupancy of the context window. Absolute, not a delta, and it **falls** on compaction. |
| `context_window_size_tokens` | integer \| null | The model's window. The app computes the percentage for display; it does not compute the inputs. |
| `cumulative_input_tokens` | integer \| null | Monotonic. **Fresh input only** — see below. Never decreases. |
| `cumulative_cache_read_tokens` | integer \| null | Monotonic. Prompt tokens served from the cache. |
| `cumulative_cache_creation_tokens` | integer \| null | Monotonic. Prompt tokens written into the cache. |
| `cumulative_output_tokens` | integer \| null | Monotonic, for cost. Never decreases. |
| `cumulative_tokens_partial` | boolean \| null | `true` when the cumulative pair counts only part of the session. See below. |
| `five_hour_limit_used_percent` | number \| null | 0–100. The Claude.ai subscription's 5-hour window. |
| `five_hour_limit_resets_at` | string \| null | RFC 3339, when that window resets. |
| `seven_day_limit_used_percent` | number \| null | 0–100. The weekly window. |
| `seven_day_limit_resets_at` | string \| null | RFC 3339. |
| `origin_app` | string \| null | The terminal application a session with no tab is running in, verbatim from the process tree: `iTerm2`, `Terminal`, `tmux: server`. See below. |
| `origin_tty` | string \| null | Its controlling terminal, without `/dev/`: `ttys005`. `null` for an agent that has none. |
| `git_branch` | string \| null | Display data for the sidebar. |
| `last_action` | string \| null | |
| `last_event_at` | string \| null | When the *session* last did something, as distinct from the envelope's `ts`, which is when the daemon emitted this message. |
| `tab_id` | string \| null | Late binding: a session that registered unbound can acquire a tab later. |
| `files` | array \| null | Every file the session has written. Whole list, never a delta. See below. |
| `files_partial` | boolean \| null | `true` when that list covers only part of the session. |
| `files_truncated` | boolean \| null | `true` when the list was cut to fit the line. |
| `answer_request` | object \| null | The session's last message ends by asking the user something. See below. |
| `pending_agents` | integer \| null | How many background agents this session is waiting on. **Derived every read, never counted up.** See below. |

### `files`: what the session wrote

Each entry is one file, with the diffstat this session is responsible for:

```json
{"path": "/Users/you/www/app/src/main.rs", "added": 42, "removed": 7, "created": false}
```

| Field | Type | Notes |
|---|---|---|
| `path` | string | Absolute, as the transcript writes it. Relativising is a display decision and needs to know what the path is relative *to*. |
| `added` | integer | Lines added by this session, summed over every edit of the file. |
| `removed` | integer | Lines removed. |
| `created` | boolean | This session created the file rather than editing one that existed. Sticky: created once stays created, however many edits follow. |

**The whole list, not a delta.** Every other message here is an idempotent
upsert keyed by `session_id`, which is what lets snapshot replay reuse the
ordinary path instead of needing a second one. A delta would be the single field
that breaks that property. The list is sent only when it changes, and it is
ordered by path so an unchanged set is byte-identical and publishes nothing.

**The numbers are measured, not estimated.** Claude Code writes the diff into
the transcript itself: an `Edit` result carries `structuredPatch`, whose hunk
lines are prefixed `+`, `-` or space, and counting those prefixes gives what
`git diff --numstat` would give. A `Write` that creates a file has no diff to
read — every one of the 387 creates measured on the reference machine carried an
empty patch — so its `added` is the line count of the content written.

`git diff` is deliberately **not** the source. It measures the checkout, not the
session: two agents working in one repo would each be shown the other's work,
which is precisely the case this product exists for. It also disagrees with
itself over time, since anything that commits — including the user, between two
reads — resets the numbers under a session that did the work.

**`files_partial` is not optional decoration.** It carries the same warning as
`cumulative_tokens_partial`, for the same reason and one more:

1. The daemon reads a transcript from its end, so a session already running when
   the daemon started contributes nothing before that moment.
2. A file written by `Bash` — `sed -i`, `mv`, a heredoc, `git checkout` — leaves
   no tool result naming a path and **cannot appear here at all**.

So this list is "files edited by tool", not "files that changed", and a tree
showing three files for a session that touched forty is the same class of lie as
`8k` for a session that burned `400k`. Clients must mark a partial list rather
than presenting it as the whole truth.

**`files_truncated` guards a silent failure.** A client reads whole lines and
*drops* one over its size limit rather than buffering it, so an unbounded list
would not arrive cut — it would not arrive, and the panel would stop updating
with nothing on screen to explain why. The daemon cuts at 500 entries, keeping
the first by path, and says that it did.

**Compatibility.** These three fields were added without bumping `v`. They are
optional fields of a sparse patch: a client that does not know them ignores
them, exactly as it ignores any absent field, and no existing field changed
shape or meaning. The next *breaking* change still bumps `v`.

**`cumulative_tokens_partial` exists because a partial total is not a small
total.** The daemon starts reading a transcript from its *end*, so a session
already in progress when the daemon started contributes nothing before that
moment. The resulting counters are not incomplete-but-approaching-right: they
are wrong, by an unknown amount, and nothing about the number says so. A card
reading `8k out` for a session that has burned `400k` is a lie the user cannot
detect.

So the flag travels with the numbers. `true` means "this counts from when we
started looking, not from when the session started"; the app must mark it —
`~8k` rather than `8k`. Absent or `null` means unknown in the sparse-patch
sense: unchanged, not "complete". `false` is a positive claim that the count
covers the whole session.

This is the same discipline as `null` versus zero, applied one level up: a
number whose *provenance* is uncertain is as dangerous as a number that is
missing, and more dangerous than one that is obviously absent.

Added in document revision 3. It is an addition, so the wire `v` stays `1`:
a client that does not know the field ignores it, which is exactly what the
"receivers must ignore unknown fields" rule is for.

**`origin_app` / `origin_tty` answer "where is this session", for the ones
violeet did not start.** The hooks are installed user-wide, so an agent launched
from iTerm2 reaches the same daemon and gets a card. Those cards are the ones
most worth having — they block on a permission request while the user is looking
somewhere else — but until revision 4 they could only say *outside violeet*,
which is true and unusable.

They are resolved from the process tree behind the hook's **own TCP connection**:
the kernel knows which process owns the client end, and walking up from it
reaches the terminal application. The obvious alternative, matching on `cwd`,
was measured ambiguous — two agents in the same repository are indistinguishable,
and that is the normal case, not the corner case. `lsof` on the transcript path
finds nothing, because Claude Code closes the file between writes.

`origin_app` is reported **verbatim** from the process's own name rather than
mapped to a friendlier label, so a terminal nobody anticipated shows its real
name instead of "unknown". Either field may be `null` on its own: an agent with
no controlling terminal still has an application. A session bound to an violeet
tab carries neither, because its tab already answers the question.

Resolution costs two short-lived subprocesses (~45 ms, measured) and happens at
most **once per session** — on the first hook that arrives with no origin yet.
It has to complete before the response is written, because the kernel's view of
the connection stops existing when the socket closes.

Added in document revision 4, and again an addition: the wire `v` stays `1`.

**The prompt side is three numbers, not one, because they have three
prices.** `cumulative_input_tokens` counts only input that was neither read
from nor written to the cache, and on its own it is not what the session cost.
Measured across four real transcripts:

| session | `input` | `cache_read` | `cache_creation` | understated by |
|---|---|---|---|---|
| 11.2 MB | 628 | 120 795 446 | 833 136 | 193 677x |
| 12.9 MB | 58 565 | 210 051 939 | 1 133 697 | 3 607x |
| 15.4 MB | 1 558 | 239 984 106 | 2 632 530 | 155 724x |
| 10.8 MB | 1 242 | 265 631 149 | 1 052 986 | 214 723x |

Two independent implementations — the Rust reader and a Python script written
against the same files — agree on every figure. This shipped as a card reading
`in ~170` for a session holding 187k in its window, which is what exposed it.

They are kept apart rather than summed for two reasons. **Price**: a cache read
costs a fraction of fresh input and a cache write costs more than it, so one
merged number cannot be turned into money by anyone downstream. **Scale**: cache
reads were 99.5% of the prompt side in every session measured, so a merged
figure would be the cache reads wearing a different label, and fresh input would
vanish — the same failure as before, mirrored.

Added in document revision 5. An addition, so the wire `v` stays `1`.

**`title_source` says who named the session**, and exists because the
precedence is not visible from the title alone. In rank order:

| source | when | outranks |
|---|---|---|
| `cwd` | nothing has named it; the client falls back to the path's last component | — |
| `prompt` | the first `UserPromptSubmit`, derived from what the user typed | `cwd` |
| `ai_title` | Claude Code's own `ai-title` line in the transcript | `prompt` |
| `user` | `rename_session`. Sticky: nothing overwrites it, and only `release_session_title` clears it | everything |

A title is only ever replaced by one that outranks it, which is what stops a
name from flickering between derivations — and what makes a manual rename
final. The daemon persists the pair to `~/.violeet/titles.json` so a restart does
not rename every card back to its folder.

`ai-title` rather than `summary` on measurement: `summary` appears in **none**
of the transcripts on the machine this was built on, while `ai-title` lands on
line 12 of every session that gets that far, carries one stable value for the
session's life, and is written in the language of the conversation.

**The rate-limit fields come from a different channel entirely.** They are not
in the transcript and not in any hook: Claude Code reports them, along with the
real `context_window_size`, only to the **status line** command. `violeet
install-statusline` wraps whatever status line the user already has, forwards a
copy of that payload to the daemon, and runs the original unchanged — so the
user's prompt looks identical and the daemon gains two numbers it otherwise
cannot see.

They are four flat fields rather than one nested object because this is a sparse
patch: "the 5-hour percentage moved" and "the whole rate-limit block became
unknown" are different messages, and a nested object cannot express the first
without resending the second. Absent for anyone not on a Claude.ai
subscription, and absent until the session's first API response.

Added in document revision 3. Wire `v` stays `1`.

**The four token fields are four numbers, not two pairs of synonyms.** The first
pair describes how full the window is right now; the second describes what the
session has cost since it started. They move independently — compaction drops
occupancy while cost keeps climbing — and any client that adds the cumulative
pair to estimate occupancy will get a wrong-but-plausible number. That failure
is the reason the names are long.

`state` covers only the states the daemon can actually observe. `starting`
exists because a session that is known but has not yet been observed doing
anything is a real state, and in a sparse patch an absent `state` means
*unchanged* — so without it a brand-new session has no state at all. `done` and
`dead` are not here on purpose: the end of a session is reported by
`session_ended`, which is a different message with a different shape.

There is deliberately **no `context_pct`**. A percentage is presentation derived
from two numbers the daemon already sends, and duplicating it invites the two
from disagreeing.

### `answer_request`: the session asked the user something

`state: "idle"` says the agent stopped. It does not say whether it stopped
having finished or stopped having asked, and those are different situations for
the person reading the sidebar. This field carries the second one.

```json
"answer_request": {
  "signal": "question_mark",
  "question": "Achei dois caminhos para o corte de contexto.\n\nSigo pelo primeiro?",
  "context": [
    { "role": "user", "text": "compara as duas rotas" },
    { "role": "assistant", "text": "A primeira lê do fim do arquivo…" }
  ],
  "context_truncated": true,
  "question_truncated": false
}
```

| Field | Type | Notes |
|---|---|---|
| `signal` | string | `question_mark` \| `lexicon`. Which rule fired. Display and telemetry only: **clients must not re-derive it.** |
| `question` | string | The asking message, whole, up to the cap below. |
| `context` | array | `{role, text}`, oldest first, already cut to the daemon's budget. |
| `context_truncated` | boolean | The excerpt does not cover the whole conversation. |
| `question_truncated` | boolean | The asking message itself was cut at the cap. |

**Three states, not two.** Absent means *unchanged*, in the ordinary
sparse-patch sense — including "this daemon never looked". An explicit `null`
means *the session is no longer asking*, which is how a client learns to close
the panel; without it a panel opened once would have to guess when to go away.
An object means it is asking now. Collapsing absent and `null` into one value
would make "I do not know" indistinguishable from "I know it is not asking",
which is the `None`-becomes-zero mistake one level up.

**Two truncation flags, because they are two different facts.** A cut excerpt
and a cut question fail differently: the first means the reader is seeing less
of the conversation than happened, the second means the reader is seeing less of
*the question they are being asked*. A client that knows only "something was
truncated" can say so but cannot say what, and a warning that cannot name its
subject gets ignored. Same discipline as `files_partial` beside
`files_truncated`.

**`question` is capped at 128 KiB, and the cap is measured.** A line over 1 MiB
is dropped by the rule in *Envelope*, so an uncapped question would not arrive
cut — the whole `session_updated` would not arrive, silently, which is the
failure `files_truncated` exists to prevent. The cap sits far above real use and
far below the line limit: over 618 human stop points on the reference corpus the
asking message had a **median of 1.6 KB, a p95 of 3.3 KB and a maximum of
6.8 KB**. 128 KiB is roughly nineteen times the largest one observed and leaves
the line about eight times of headroom with the excerpt attached. Hitting it is
pathological, and `question_truncated` is how the client says so instead of
presenting a fragment as the whole question.

**Why the daemon cuts the excerpt and not the app.** The budget is a named,
tested constant on the daemon side. An app re-deriving it would be a second
definition of what leaves the machine, and the feature's whole disclosure claim
is that what the user is shown and what was sent are the same string. One cut,
one renderer, one place to audit.

Added in document revision 7. An addition, so the wire `v` stays `1`.

### `pending_agents`: waiting on an agent is not being free

A session that dispatched background agents and is waiting for them reports
`state: "idle"`, because the hook that fires at the end of a turn is the same
one whether a person or a subagent is expected next. It is idle in the sense
that nothing is being computed in the foreground, and it is emphatically not
free: nobody needs to look at it. Reported as plain `idle`, it renders
identically to a session that is genuinely waiting on its user, and it sorts
alongside it.

This is not hypothetical. Over 942 stop points on the reference corpus,
**247 (29.6%) were not a person being handed the keyboard** — 185 of them a
background task notification. Roughly one stop in four looked available and was
not.

`pending_agents` is the count of background agents the session is waiting on.
`0` is a positive claim that it is waiting on none; absent or `null` is
unchanged, in the sparse-patch sense.

**It is derived on every read and never counted up.** The value is recomputed
from the transcript each time it is read, as *tool uses of the `Task` tool with
no matching result yet*. There is no increment and no decrement, so there is
nothing to leak: a `SubagentStop` that never arrives, or arrives twice, costs
one stale reading and corrects itself on the next. A counter would be wrong from
the first missed event until the session ended, and missed events happen. A
number whose error is unbounded in time is worse than no number, because it
looks like the same kind of fact as a correct one.

**Why a field and not a state.** `state` has four wire values and a transition
matrix that the 2026-07-31 revision spent effort *simplifying*, removing two
unreachable states in the process. A fifth value would reopen that matrix and
make one hook produce two different states depending on transcript context.
A client that wants "does a human need to look at this" reads two fields and
combines them, which it already does:

| reading | means |
|---|---|
| `state == "idle"` and `pending_agents > 0` | busy, but not computing. Nobody needs to look. |
| `state == "idle"` and `pending_agents == 0` and `answer_request` **is an object** | your turn, and there is a question to answer. |
| `state == "idle"` and `pending_agents == 0` and `answer_request` is absent or `null` | stopped, with nothing asked. |

**"Is an object" and not "is not null."** `answer_request` has three states, so
`!= null` is also true when the field is *absent* — which means unchanged, and
includes "this daemon never looked". A client testing for non-null would claim
"your turn, here is the question" for a session it knows nothing about. The test
is presence of the object, and this paragraph exists because the first draft of
this section got it wrong.

Added in document revision 7. An addition, so the wire `v` stays `1`.

### `hitl_pending`

An agent is blocked on a permission request and the daemon is holding the HTTP
response open.

```json
{
  "type": "hitl_pending", "v": 1, "ts": "2026-07-30T18:05:10Z",
  "hitl_id": "hitl-01J8Z9",
  "session_id": "b497437c-e819-4d0c-9145-03eb6573f8ef",
  "tab_id": "tab-7f3a",
  "tool_name": "Bash",
  "tool_input": { "command": "rm -rf build/", "description": "Clean build dir" },
  "permission_suggestions": [
    {
      "type": "addRules",
      "rules": [{ "toolName": "Bash", "ruleContent": "rm -rf build/" }],
      "behavior": "allow",
      "destination": "localSettings"
    }
  ],
  "expires_at": "2026-07-30T18:10:10Z"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `hitl_id` | string | yes | Daemon-minted. |
| `session_id` | string | yes | |
| `tab_id` | string \| null | yes | |
| `tool_name` | string | yes | Verbatim from the hook payload. |
| `tool_input` | object | yes | Verbatim, opaque. The app renders it; it must not assume a schema per tool. |
| `permission_suggestions` | array | yes | **Verbatim passthrough.** See the note below. |
| `expires_at` | string | yes | When the daemon's own timeout fires. The app should show this as a countdown; it is a real deadline. |

> **`permission_suggestions` is passed through untouched.** Its real shape in
> v2.1.220 is `{type: "addRules", rules: [{toolName, ruleContent}], behavior,
> destination}` — *not* the `{type: "allow", reason}` the official docs show.
> Since the documented shape is already wrong, the daemon does not normalize
> into either one: it forwards the array exactly as received and the app treats
> it as opaque display data. Anything that parses it is betting on an
> undocumented shape and must tolerate being wrong.

### `hitl_resolved`

The permission request reached a terminal state. Always emitted, exactly once
per `hitl_id`, whatever the outcome. The app clears the card on this message and
on no other signal.

```json
{
  "type": "hitl_resolved", "v": 1, "ts": "2026-07-30T18:05:31Z",
  "hitl_id": "hitl-01J8Z9",
  "session_id": "b497437c-e819-4d0c-9145-03eb6573f8ef",
  "origin": "tui",
  "decision": null
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `hitl_id` | string | yes | |
| `session_id` | string | yes | |
| `origin` | string | yes | `app` \| `tui` \| `timeout` \| `daemon_error` |
| `decision` | string \| null | yes | `allow` \| `deny` when `origin` is `app`. `null` otherwise — when the human answered in the TUI, violeet genuinely does not know what they chose. |

`origin` values, in full:

- **`app`** — a client sent `resolve_hitl` and the daemon answered the agent's
  HTTP request with that decision.
- **`tui`** — the human answered the dialog in the terminal tab and won the
  race. The daemon inferred this from a `PostToolUse` hook arriving for a
  matching call. It answered `500`, which is harmless because the agent had
  already moved on. `decision` is `null`: the outcome is real but unknown to us.
- **`timeout`** — the daemon's own deadline (`expires_at`) elapsed. It answered
  `500`; the agent falls back to its interactive dialog, which is still on
  screen and still live.
- **`daemon_error`** — something went wrong inside the daemon (panic, malformed
  payload, socket down). It answered `500`. This exists so the invariant below
  is observable rather than silent.

Why every failure path is `500` and never silence: see
[ADR-004](adr/ADR-004-hitl-via-permissionrequest-sem-injecao-pty.md).

### `session_ended`

```json
{
  "type": "session_ended", "v": 1, "ts": "2026-07-30T18:31:02Z",
  "session_id": "b497437c-e819-4d0c-9145-03eb6573f8ef",
  "tab_id": "tab-7f3a",
  "reason": "session_end_hook"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `reason` | string | yes | `session_end_hook` \| `process_exited` \| `tab_closed` \| `daemon_shutdown` |

A session with a pending HITL that ends must emit `hitl_resolved`
(`origin: "daemon_error"` if nothing better applies) **before** `session_ended`,
so the app never has to garbage-collect an orphaned card.

---

## Messages: app → daemon

### `register_tab`

Announces a tab and its `VIOLEET_TAB_ID` before the agent process is spawned, so
the daemon can bind the first session that reports that id.

```json
{ "type": "register_tab", "v": 1, "ts": "...", "tab_id": "tab-7f3a", "cwd": "/Users/you/www/personal/violeet" }
```

| Field | Type | Required |
|---|---|---|
| `tab_id` | string | yes |
| `cwd` | string \| null | yes |

### `close_tab`

The tab is gone. Symmetric with `register_tab`, and the only way the daemon can
learn that a tab closed.

```json
{ "type": "close_tab", "v": 1, "ts": "...", "tab_id": "tab-7f3a" }
```

| Field | Type | Required |
|---|---|---|
| `tab_id` | string | yes |

The daemon marks every session claiming that tab as ended and emits one
`session_ended` with `reason: "tab_closed"` for each. A session with a pending
HITL gets its `hitl_resolved` first, per the ordering rule under
`session_ended`.

**`close_tab` for an unknown tab id is silently ignored**, on the same reasoning
as `resolve_hitl`: the app closing a tab the daemon never bound is a normal
outcome, not an error. Without this message the daemon can only *infer* a closed
tab from thirty minutes of silence — which is the infer-from-absence pattern the
rest of this protocol refuses.

### `resolve_hitl`

Answers a pending permission request.

```json
{
  "type": "resolve_hitl", "v": 1, "ts": "...",
  "hitl_id": "hitl-01J8Z9",
  "decision": {
    "behavior": "allow",
    "updated_input": { "command": "rm -rf build/" },
    "updated_permissions": {
      "rules": [{ "pattern": "Bash(rm -rf build/)", "behavior": "allow", "duration": "session" }]
    }
  }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `hitl_id` | string | yes | |
| `decision.behavior` | string | yes | `allow` \| `deny` |
| `decision.reason` | string | no | Shown to the agent when denying. |
| `decision.updated_input` | object | no | Replaces the named fields of `tool_input`; unnamed fields keep their original values. |
| `decision.updated_permissions` | object | no | Persisted rules so the agent stops asking. Shape mirrors the Claude Code hook output. |

The daemon translates this into the hook's response JSON. The snake_case here is
deliberate: this protocol is snake_case throughout, and the daemon does the
camelCase translation at the hook boundary so no client has to know the agent's
wire format.

**`resolve_hitl` for an unknown or already-resolved `hitl_id` is silently
ignored.** This is not an error path, it is the normal outcome of the race: the
user clicked the card at the same moment the TUI answer landed. The app must
therefore treat its own click as a *request*, not as a fact, and update the card
only when `hitl_resolved` arrives.

### `rename_session`

```json
{ "type": "rename_session", "v": 1, "ts": "...", "session_id": "b497...", "title": "HTTP hook endpoint" }
```

A user-set title. The daemon stores it and stops overwriting that session's
title with auto-derived ones; it echoes the change back as `session_updated`.

An empty or whitespace-only title is refused rather than stored: an empty name
is a mistake, and giving up a manual name is a decision with a message of its
own.

### `release_session_title`

```json
{ "type": "release_session_title", "v": 1, "ts": "...", "session_id": "b497..." }
```

Added in document revision 6. An addition, so the wire `v` stays `1`.

Gives a session back to automatic naming: the counterpart to `rename_session`,
and not optional. `user` is a rank nothing outranks, so without this message a
session that was renamed once can never be renamed by anything again — the user
is stuck with what they typed, and the only way out is ending the session.

The daemon replies with `session_updated` carrying the name the session falls
back to, which is the best title it derived **while the manual name was in
force** — the `ai-title` that arrived after the rename, not the older one that
preceded it. That requires the daemon to keep two tracks per session (the name
on screen and the best derived name underneath), and both are persisted, so
unlocking works the same before and after a restart.

A session with nothing derived underneath falls back to `title: null`, and the
client names it from its working directory. Unknown `session_id` is silently
ignored, like every other message here.

It is a separate message rather than `rename_session` with a null title because
an unknown `type` is ignored by design (see the version rules above), while a
null in a field typed as a string is malformed — so an old daemon meeting a new
client quietly keeps the manual name instead of logging an error the user did
not cause.

### `request_snapshot`

```json
{ "type": "request_snapshot", "v": 1, "ts": "..." }
```

Asks for current state — sent on connect, and after any reconnect.

The daemon replies by **replaying ordinary messages**: one `session_registered`
per live session, followed by one `hitl_pending` per pending request. There is
no snapshot envelope and no end-of-snapshot marker.

That is a deliberate choice, and it costs the client something: all daemon→app
messages must be handled as **idempotent upserts keyed by `session_id` /
`hitl_id`**, because a replayed `session_registered` for a session the app
already knows is normal traffic, not a duplicate to detect. In exchange, the
reconnect path needs no separate code and no extra message type.

---

## Errors

There is **no error message type**, in either direction. This is deliberate:

- Malformed lines, unknown `type`, unknown `v` — the receiver drops the line and
  logs locally. It does not reply.
- The one failure that actually matters — a permission request that never gets
  answered — is not covered by an error channel. It is covered by the daemon's
  own timeout and the `500`-always invariant, which are stronger guarantees than
  a message the peer might never read.

If a track finds a failure that genuinely cannot be expressed as
`hitl_resolved` + `origin`, that is a protocol gap and goes through the change
process below.

---

## Changing this protocol

**Frozen during a fan-out wave.** Parallel tracks are coding against the version
of this file that existed when the wave started; editing it mid-wave silently
breaks work already in progress in another session.

If your implementation needs a field or message that is not here:

1. **Stop.** Do not extend unilaterally.
2. Write `docs/tracks/<X>-protocol-request.md` — what is missing, why, and what
   you would add.
3. Tell the human.
4. Keep working on everything that does not depend on it.

Between waves, the protocol changes by bumping `v` and updating this document
first, then the two projections.

The 2026-07-31 revision waived the bump, once, for the reason recorded at the
top of this file. Treat that as spent: the next breaking change bumps `v`.

### Related fan-out rules

- The workspace `Cargo.toml` is read-only during a wave. Dependencies go in your
  own crate's manifest.
- `Cargo.lock` is gitignored during a wave so parallel dependency additions do
  not collide. It comes back before we ship binaries.
- Where another track's work does not exist yet, write a stub with the exact
  interface above and mark it `TODO(track-<Y>): …`. Test against the stub.
