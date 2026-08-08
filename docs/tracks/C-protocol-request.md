# Track C — protocol change request: "write the answer"

Raised against `docs/PROTOCOL.md` **revision 6, wire `v` = 1**.

**Status: open. Nothing here is on the wire.** Per the *Changing this protocol*
rule, this file exists instead of an edit to `PROTOCOL.md`, and the work that
does not depend on it was done anyway:

| Landed | Where |
|---|---|
| The detection rule, measured against the real corpus | `crates/violeet-transcript/src/answer_request.rs` |
| The context cut and the payload renderer | same module, `build_request` / `render_payload` |
| The corpus probe that produced the rates | `crates/violeet-transcript/examples/answer_request_probe.rs` |
| The PTY insert invariant (no Enter, ever) | `app/Sources/Violeet/Terminal/DraftInsertion.swift` |

What is **not** landed, and why: the sidebar panel, the providers, the Keychain
and the consent gate. All four need the daemon to tell the app that a session
just asked something, and it has nowhere to say it. Building them against a stub
would mean shipping a panel that cannot open. See *What is blocked* at the end.

---

## The feature, in one paragraph

When a session goes idle **and** the assistant's last message ends by asking the
user something, the sidebar offers to draft a reply. The draft is generated
locally by `claude -p` (default, free, no key) or by a provider the user
configured with their own key, shown in an editable panel next to the payload
that was sent, and — on an explicit click — typed into the tab's prompt **without
Enter**. It never sends. It is not a permission request and does not touch the
HITL path.

---

## 1. The daemon can see the request; nothing can carry it

**What exists.** `session_updated.state` already reports `idle`, and the daemon
already tails the transcript. Everything the rule needs is in the daemon's hands.

**What is missing.** No field carries *the assistant's closing prose*, and by
design: `PROTOCOL.md` keeps `transcript_path` off the wire (request 6 of Track A)
and `last_action` is a one-line summary, not the message. The app has no
transcript reader at all — measured: `grep -rn transcript app/Sources` finds
comments and one constant, no parser — and giving it one would be a second
implementation of a format that changes without notice, which is exactly what
`docs/TRANSCRIPT_FORMAT.md` argues against.

**Proposed: one optional nested field on `session_updated`.**

```json
{
  "type": "session_updated", "v": 1, "ts": "2026-08-08T14:03:11Z",
  "session_id": "b497437c-…",
  "state": "idle",
  "answer_request": {
    "signal": "question_mark",
    "question": "Achei dois caminhos para o corte de contexto.\n\nSigo pelo primeiro?",
    "context": [
      { "role": "user", "text": "compara as duas rotas" },
      { "role": "assistant", "text": "A primeira lê do fim do arquivo…" }
    ],
    "context_truncated": true
  }
}
```

| Field | Type | Notes |
|---|---|---|
| `answer_request` | object \| null | Sparse-patch member. Absent means *unchanged*; explicit `null` means *the session is no longer asking* — which is how the panel learns to close. |
| `.signal` | string | `question_mark` \| `lexicon`. Which of the two rules fired. Display and telemetry only; the app must not re-derive it. |
| `.question` | string | The asking message, whole. |
| `.context` | array | `{role, text}`, oldest first, already cut to the budget. |
| `.context_truncated` | boolean | The excerpt does not cover the whole conversation. The panel says so, same discipline as `files_partial`. |

**Why the daemon cuts and not the app.** The cut is a named, tested constant in
`answer_request.rs`; the app re-deriving it would be a second definition of "what
leaves the machine", and the panel's whole privacy claim is that the disclosure
and the payload are the same string. One cut, one renderer, one place to audit.

**Why an addition and not a bump.** It is an optional field of a sparse patch: a
client that does not know it ignores it, which is what the *receivers must ignore
unknown fields* rule is for. No existing field changes shape or meaning. Wire `v`
stays `1`.

**Why not a new message type.** A new `type` would also be backward compatible,
but the fact is a property of a session and its arrival is already an event the
app handles as an idempotent upsert keyed by `session_id`. A separate message
would need its own clear-on-`session_ended` handling; a field on `session_updated`
gets it for free.

**Line-size risk, and the mitigation.** `PROTOCOL.md` drops a line over 1 MiB.
The excerpt is capped at 6000 characters plus the asking message, so the
practical ceiling is well under 100 KiB — but the asking message is
*deliberately* uncapped (a truncated question is unanswerable). A message longer
than ~900 KiB would take the whole `session_updated` line down, silently, which
is the failure `files_truncated` exists to prevent. **Decision requested:** cap
`.question` at a documented ceiling with its own truncation flag, or accept the
risk. The conservative reading is to cap it.

---

## 2. Generation, the key, and the consent all stay in the app

**No protocol change requested here.** Recorded so the decision is not made twice.

- **Default provider is `claude -p`**, spawned by the app with `--model`, default
  `claude-haiku-4-5-20251001`. It runs under the user's existing Claude Code
  subscription: zero added cost, zero configuration, and the payload's
  destination is the one the session is already talking to.
- **Alternative providers by key**: Anthropic Messages API, OpenAI, and a generic
  compatible endpoint (base URL + model) for Kimi, GLM and friends.
- **The key lives in the macOS Keychain and never in a config file.** The config
  file holds the selected provider, the model and the base URL — three facts that
  are not secrets. A provider selected with no key in the Keychain renders as
  *no key configured* rather than failing at request time.
- **Timeout 20 s, and failure is quiet.** On timeout or error the panel says it
  could not and disappears. No spinner without an end, no retry loop.
- **Consent is per provider, explicit, before the first use, and persisted.** The
  prompt names the destination. Revocable in settings. `claude -p` is not
  exempt — same destination as always is a reason the sentence is short, not a
  reason to skip it.
- **The panel discloses the payload, collapsed, verbatim.** It is
  `render_payload()`'s output, not a summary of it. A summary cannot be checked,
  which is the only thing the disclosure is for.

None of this needs a socket message: the app spawns the process or makes the HTTP
call itself. The daemon never sees a key and never talks to a third party, which
is worth keeping true.

---

## 3. The context cut, stated once

Implemented in `AnswerRequestConfig`, `crates/violeet-transcript/src/answer_request.rs`:

> Walk backwards from the newest message, taking **whole** messages, and stop at
> the first one that would push the total past `context_char_budget` (6000
> characters) or past `context_max_messages` (12). Never split a message. The
> asking message is always included in full, even when it alone exceeds the
> budget, and it is charged against the budget first.

Rationale for each number, so a later change is a decision and not a guess:

- **6000 characters** is roughly 1500 tokens: enough for a handful of real turns,
  small enough that the disclosure is something a person can actually read before
  clicking, and cheap on the default provider.
- **12 messages** bounds the case the character budget does not: a hundred
  one-word turns fit in 6000 characters and are noise.
- **Whole messages** because a half sentence read as a whole one is a worse
  prompt than a shorter excerpt, and because a cut mid-message is invisible in
  the disclosure.

---

## 4. The detection rule is measured, and the numbers are in the code

Full method and table in the module note. Summary: 112 sessions, 835 stop points
(a `system`/`stop_hook_summary` line paired with the assistant message before
it), rule fires on **32.1%** of stop points and **45.6%** of human stops.
Reproduce with

    cargo run --release --example answer_request_probe -p violeet-transcript

Two things the brief asked to keep straight:

- **Measured:** the rates above; that 29.6% of stop points are not a human being
  handed the keyboard (`<task-notification>` 185, local-command caveat 58); that
  narrowing the lexicon to the last paragraph is what holds the false-positive
  rate down; that a Python second implementation over the same files agrees to
  within one stop point.
- **Inferred:** that `stop_hook_summary` is the right proxy for "the session went
  idle" — the daemon's own `state: "idle"` comes from the same hook, so the
  proxy and the product signal are the same thing, but that identity was reasoned
  about rather than observed end to end. Also inferred: that the lexicon
  generalises past this one user's Portuguese. It was tuned on one corpus by one
  person, and a second user's phrasing has not been measured at all.

The two text guards — `No response requested.` and `API Error:` — suppressed
**zero** stop points in this corpus. They are insurance against a shape known to
exist, and the module note says so rather than implying they were load-bearing.

---

## What is blocked

Until item 1 is decided, these cannot be built without either extending the
protocol unilaterally or duplicating the transcript reader in Swift:

1. The sidebar draft panel (editable text, collapsed payload, regenerate).
2. The providers and the Keychain access.
3. The consent gate.
4. Wiring `DraftInsertion.insertDraft` to a button, and handing first responder
   back to the terminal after it.

Item 4's *safety* property is already landed and tested independently, which was
the point of landing it early: the invariant that automation never presses Enter
should not be waiting on a protocol decision.
