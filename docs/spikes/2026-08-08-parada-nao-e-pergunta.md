# 2026-08-08 — a stopped session is not a session waiting for you

Preserved evidence, in the sense `README.md` means it: a run over real files,
kept because the conclusion is not derivable from anything documented.

**The headline is not the heuristic. It is that 22–30% of the moments a Claude
Code session goes quiet are not a person being asked anything** — they are a
background task reporting in. That fact outlives the feature it was measured
for, and it is a bug in the sidebar today (see *Consequence* at the end).

Method and numbers first, then the part that is judgement.

---

## What a "stop point" is, and why the count differs between rounds

There is no field that says "the agent is waiting for you". Two proxies were
used, in two rounds, and they do not count the same thing. Both are recorded
because the difference is the sort of thing that gets mistaken for a regression
later.

| | round 1 | round 2 |
|---|---|---|
| proxy | an assistant message followed by a `user` line | a `system` / `stop_hook_summary` line paired with the assistant message before it |
| sessions | 112 | 112 |
| stop points | 942 | 835 |
| background-task notifications | 206 = **22%** | 247 = **29.6%** (`<task-notification>` 185, local-command caveat 58, interrupt 4) |
| human stop points | 618 | 588 |
| rule fires, of all stop points | 32% | **32.1%** |
| rule fires, of human stop points | 43% | **45.6%** |

Round 2 is the one the code implements, because `stop_hook_summary` is the same
`Stop` hook the daemon already keys `state: "idle"` off — the proxy and the
product signal are then the same event, rather than two things that agree most of
the time. It counts fewer stop points because a stop the session never woke from
has no following `user` line in round 1's definition either way, and because
round 1 counted some assistant messages that carried no prose.

The two rounds agreeing to within 0.1 percentage points on the firing rate, from
different definitions and different implementations (Python, then Rust), is the
reason there is any confidence here at all. Reproduce round 2 with:

    cargo run --release --example answer_request_probe -p violeet-transcript

**The corpus is live and the counts drift.** Every figure here was taken on
2026-08-08; re-running an hour later already read 836 stop points instead of 835,
because the machine kept working. The *rates* held to a tenth of a point. Treat a
difference in the third significant figure as the corpus moving, and a difference
in the first as the rule having changed.

---

## 1. Measured

### 22–30% of quiet moments are a machine, not a person

The shape, verbatim from the corpus — a `user` line whose content is:

```
<task-notification>
<task-id>a63cc3ed1fbc05ef6</task-id>
<tool-use-id>toolu_01EnyHkDciDKv7S4bGeY4dii</tool-use-id>
<output-file>/private/tmp/…/tasks/a63cc3ed1fbc05ef6.output</output-file>
<status>completed</status>
<summary>Agent "…" finished</summary>
```

185 of 835 stop points (22.2%) were followed by one of these. A further 58 (6.9%)
were followed by the local-command caveat, and 4 by an interrupt.

**The `Task` tool's result arrives twice, and the first one is a lie about
completion.** Sampled 6 backgrounded tasks across 2 sessions: in every one, the
`tool_use` line was followed *immediately* by a `tool_result` — the launch
acknowledgement — and the real outcome arrived as a `<task-notification>` user
message between 7 and 128 lines later. In all 6, a `stop_hook_summary` fell
between the two.

| session | `tool_use` | `tool_result` | notification | stop between |
|---|---|---|---|---|
| d766f32a | 1192 | 1193 | 1320 | yes |
| 177f6afc | 26 | 27 | 48 | yes |
| 177f6afc | 122 | 123 | 141 | yes |
| 177f6afc | 279 | 280 | 303 | yes |
| 177f6afc | 395 | 396 | 420 | yes |
| 177f6afc | 438 | 439 | 446 | yes |

This is why the transcript's "is a tool in flight?" signal cannot cover the case:
by the time the session stops, nothing is in flight as far as the file is
concerned. The tool finished. The *work* did not.

### The rule that was picked

`?` in the last two paragraphs of the assistant's prose, **or** a first-person
request phrase in the **last** paragraph only. Paragraph = block separated by a
blank line. Only `type: "text"` blocks; `thinking` and `tool_use` are not prose.

Implemented in `crates/violeet-transcript/src/answer_request.rs`, every parameter
in one named constant, `ANSWER_REQUEST`.

Fires on 268 of 835 stop points (32.1%) and 268 of 588 human stops (45.6%).

### Two guards that measured zero

`No response requested.` and `API Error:` suppressed **no** stop points in this
corpus. Neither was ever the closing message at a stop. They are insurance
against a shape known to exist, not a measured contributor, and the code says so
rather than implying they earned their place.

---

## 2. Judged, not measured

Everything in this section is one person reading text and forming an opinion. It
is separated out because the counts above can be re-run and this cannot.

### Labelling a 40-message sample

20 firing and 20 quiet human stop points, sampled with a fixed seed, read by
hand as *is this message asking the user for something?*

| | correct | wrong | uncertain |
|---|---|---|---|
| fired (20) | 17 | — | 3 |
| quiet (20) | 14 | 3 | 3 |

The 3 uncertain firings are messages whose `?` sat in the second-to-last
paragraph, where the sampled excerpt does not show enough to judge. So the
false-positive rate on this sample is bounded between **0/20 and 3/20**, and a
point estimate would be inventing precision. Round 1's hand-labelled set of 60
(15 POS / 15 SOFT / 30 NEG, reported as 15/15 on POS and 1 false positive in 30
NEG) is a different sample by a different reader and is recorded here as that
round's judgement, not reproduced.

### The misses are a lexicon gap, and they are named rather than patched

The three clear false negatives all failed for the same structural reason: the
verb was outside the list, or in a tense the list does not cover.

| missed text | why |
|---|---|
| "se quiser eu **apago** ela depois que a #92 entrar" | `apago` is not in `FIRST_PERSON_VERBS` |
| "subo na 4201 assim que você **me disser** o que é" | the lexicon has `me diga`/`me diz`, not `me disser` |
| "**Manda** os ajustes conforme for testando" | a bare second-person imperative; nothing in the rule looks for one |

Three more were soft invitations ("quando quiser resolver", "se quiser, é
`./target/...`") that a person might or might not count as a request.

**Deliberately not fixed here.** Widening the verb list or adding conjugations
would change the firing rate, and the rate is the thing this document is
evidence for. Tuning against a 40-message sample after the fact is how a measured
number becomes a number someone remembers being measured. The gap is written
down so a later pass can widen the lexicon *and re-run the probe*, which is the
only honest order.

### Inferred

- **That `stop_hook_summary` means "a person now has the keyboard".** The daemon
  derives `state: "idle"` from the same hook, so the two agree by construction —
  but that this is what a *user* would call waiting was reasoned about, not
  observed.
- **That the lexicon generalises past one user's Portuguese.** It was tuned on
  one corpus written by one person. A second user's phrasing has not been
  measured at all, and this is the single largest thing not known about the rule.

---

## Consequence: the sidebar shows a busy session as free, today

**Not a regression, not caused by this work, and not fixed by it.** Recorded
because the measurement above is what makes it visible.

The chain, in the code:

1. `crates/violeet-daemon/src/http/payload.rs:91` — `Stop` and `Notification`
   both map to `SessionState::Idle`. There is no hook for "a background task is
   outstanding": `SubagentStop` exists and maps to `Working`
   (`payload.rs:88`), so a subagent *finishing* wakes the card, but nothing keeps
   it awake while one *runs*.
2. `crates/violeet-daemon/src/transcript.rs:443` — the transcript's cross-source
   correction only overrides the hooks' state when `in_flight_tool.is_some()`.
   Per the table above, the backgrounded `Task` already has its `tool_result`, so
   nothing is in flight and `Idle` stands.
3. `app/Sources/Violeet/Sidebar/SessionCardModel.swift:260` — `"idle"` renders as
   `.idle`, and line 276 gives it sort rank 3: below `working`.

So a session that launched five background agents and is waiting on all five
appears in the sidebar as idle, and sorts below sessions that are doing less. It
is the same class of failure as `8k` for a session that burned `400k`: a number
the user cannot tell is wrong.

Fixing it is its own scope. It needs a state or a flag the protocol does not
have — the daemon would have to count outstanding `Task` launches against
`<task-notification>` arrivals, which is a transcript-side inference and belongs
in a protocol request of its own, not bolted onto this one.
