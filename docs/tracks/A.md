# Track A — daemon

Scope: `crates/aiterm-daemon/`, `docs/PERMISSION_RACE.md`, this file.

Wave 1. Working from `docs/PROTOCOL.md` v1 as frozen at commit `a77a1ac`.

---

## Log

### Boundary correction: `transcript/` removed from the daemon

Deleted `crates/aiterm-daemon/src/transcript/` and dropped `mod transcript;`
from `src/main.rs`. Transcript reading is no longer the daemon's job: it becomes
`crates/aiterm-transcript/`, a crate Track C creates from scratch.

Also updated, both inside my scope and both stale the moment the module left:
the `src/main.rs` module-map doc comment, and the `Cargo.toml` `description`,
which still advertised "transcript reader".

**No dependency on `aiterm-transcript` was added.** The crate does not exist,
and nothing in the current task needs it. Wiring is Wave 2 integration work.

#### Note for Wave 2 integration

I raised this before the correction landed, and record it because it shaped the
above: the original fan-out brief named `aiterm-transcript` as a Track C crate,
while the repo at `a77a1ac` had transcript as a module *inside* my scope. Had I
not been told to delete it, Track C would eventually have needed to edit a file
formally owned by Track A. The boundary is now clean.

### Core: registry and socket server

`cargo test -p aiterm-daemon` → **67 passing** (54 unit, 13 integration).
`cargo clippy --all-targets` clean, `cargo fmt --check` clean.

---

## What is done and tested

### `registry/` — in-memory session registry

Synchronous, I/O-free, and unaware that a socket exists. **Every method takes
`now` as a parameter** rather than reading the clock, so expiry and lifetime
behaviour are tested deterministically without sleeping.

- `state.rs` — the six-state lifecycle and its transition table. The test asserts
  the implementation against a **hand-written** table of all 21 legal pairs
  rather than deriving expectations from the code, so a wrong rule fails the test
  instead of being restated by it. All 36 pairs are classified.
- `session.rs` — one session, plus `TokenTelemetry`, `TabBinding`, `Harness`,
  `TitleSource`.
- `mod.rs` — `Registry`: tab binding, hook observation, renaming, expiry,
  reaping.

**Two "ended" predicates, deliberately distinct.** This came out of a failing
test and is worth flagging:

- `is_terminal()` = `Dead` only. A question about **transitions** — nothing
  leaves `Dead`.
- `is_finished()` = `Done | Dead`. A question about **lifecycle**, and what
  inactivity expiry keys off.

Collapsing them meant a `Done` session was being expired for inactivity.
Expiry *infers* death from silence, and there is nothing to infer about a
session we watched finish: a `Done` session is not quiet, it is over.

**Binding works in both arrival orders**, which is the whole point of ADR-003:

| Order | Result |
|---|---|
| `register_tab` then hook | session born `Bound` |
| hook then `register_tab` | session born `Pending`, promoted to `Bound` on `register_tab` |
| hook with no tab id at all | `Unbound` forever — the supported "started outside aiterm" case |

`TabBinding` keeps `Pending` and `Unbound` as separate variants on purpose:
collapsing them is what would make late binding impossible. And
`bound_tab_id()` returns `None` for `Pending`, so **a pending claim is published
as `tab_id: null`, never as a hopeful guess**.

**The no-fabrication rule** (requirement 4) is enforced by tests, not just
convention:

- `no_unknown_token_field_is_ever_zero` asserts every constructor path leaves all
  four token fields `None`, and explicitly asserts they are not `Some(0)`.
- `zero_is_a_real_reading_and_stays_distinct_from_unknown` pins the other side:
  a genuine `0` survives as `Some(0)`.
- `nothing_in_the_registry_turns_an_unknown_into_a_zero` drives a session through
  register → bind → observe → rename → expire and asserts nothing invented a
  reading along the way.
- `an_observation_without_cwd_does_not_erase_a_cwd_we_already_had` and
  `an_unknown_harness_is_upgraded_but_a_known_one_is_never_downgraded` cover the
  inverse: a later, more ignorant event must not erase what we knew.

A refused transition does **not** bump `last_event_at`. Letting an illegal move
count as activity would keep dead sessions alive forever.

### `wire.rs` — the JSON-lines message types

All nine messages of `PROTOCOL.md`, both directions.

**`session_updated` is a genuine three-way sparse patch**: absent (unchanged) /
`null` (became unknown) / value. Implemented as `Option<Option<T>>` with
`skip_serializing_if` on the outside. Collapsing this to `Option<T>` would make
"unchanged" and "unknown" the same message — the same fabrication the registry
refuses to make. There is a test asserting all three render differently, and one
asserting no `context_pct` ever appears on the wire.

`parse_inbound` is total: garbage, unknown `type`, and unsupported `v` are
`Rejected` values, never panics. `garbage_never_panics` covers empty strings,
non-objects, and truncated JSON.

### `socket/` — the Unix socket server

tokio. `Hub` owns `Arc<Mutex<Registry>>` plus a `broadcast::Sender<String>`.
Each connection gets a reader loop and a writer task; the writer selects
`biased` over a per-client unicast queue (snapshot replay) and the broadcast
(everything else), so a snapshot the client explicitly asked for does not queue
behind unrelated traffic.

**Client isolation**, all integration-tested:

- a disconnect ends only that connection's tasks
- garbage input is dropped and logged; the client stays connected and keeps
  receiving broadcasts
- a slow client that **lags** its broadcast receiver logs the gap and continues.
  It is not disconnected — it can recover with `request_snapshot`
- a client that stops reading has its unicast replies dropped rather than
  blocking the daemon

The registry mutex is never held across an `.await`, and `Hub::lock()` recovers
from poisoning instead of panicking, so a panic in one connection cannot wedge
the others.

Socket is created `0600` and a stale socket file is unlinked on bind — both
promised by `PROTOCOL.md`, both tested.

---

## What is stubbed, and who fills it

| Stub | Owner | Note |
|---|---|---|
| `Session::tokens` — all four fields `None` | **Track C** | `aiterm-transcript` fills them in Wave 2. Marked `TODO(track-C)`. |
| `Session::git_branch` — always `None` | **Track C** | The registry does no I/O, so it never populates this itself. |
| `SessionRegistered.model` — always `None` | **Track C** | Comes from the transcript. |
| `TitleSource::Derived` — nothing writes it | **Track C** | Naming logic is a future task; the field and stickiness rule exist. |
| `AppToDaemon::ResolveHitl` — parsed, then ignored | **Track A (me)** | HITL bookkeeping arrives with the HTTP endpoint, the next task. |
| `Hub::snapshot` — replays sessions only | **Track A (me)** | Will also replay `hitl_pending` once HITL exists. |
| `~/.aiterm/daemon.json` — not written | **Track A (me)** | The discovery file carries the effective **hook port**. Writing it before the HTTP server exists would advertise a lie, so `main.rs` has a `TODO` instead. |
| `session_ended` on expiry — logged, not published | **Track A (me)** | The sweeper detects expiry correctly; building the message needs publish helpers that land with the HTTP task. |
| The real socket client | **Track B** | Integration tests use fakes speaking the same JSON-lines protocol. |

---

## Protocol divergences

Seven, all recorded in [`A-protocol-request.md`](A-protocol-request.md). Nothing
was changed on the wire. Two are worth surfacing here:

1. **There is no app→daemon "tab closed" message.** `Registry::close_tab()` is
   implemented and tested, but nothing can reach it over the socket. A closed
   tab's sessions survive until the inactivity TTL — up to 30 minutes of a card
   for a tab that is gone. This blocks a stated requirement and also blocks
   Track B.
2. **`session_registered.cwd` is required and non-null**, but a hook that
   carried no working directory leaves us with nothing to send. I send `""`,
   which is schema-compliant and marked `TODO` at the call site — but it is
   exactly the fabrication the no-zero rule exists to prevent, since an empty
   string renders as an empty path rather than as `—`.

---

## Assumptions I made about the other tracks

- **Track B (app) treats every daemon→app message as an idempotent upsert** keyed
  by `session_id` / `hitl_id`. `PROTOCOL.md` requires this because snapshot
  replay has no envelope and no end marker, but nothing enforces it. If the app
  detects replayed `session_registered` as duplicates, reconnect breaks.
- **Track B tolerates `tab_id: null`** on a session it believes it owns. A
  session whose binding is still `Pending` publishes `null`, and that is correct,
  not a bug to work around.
- **Track B treats its own `resolve_hitl` click as a request, not a fact**, and
  updates the card only on `hitl_resolved`. Today the daemon ignores every
  `resolve_hitl`, so an app that optimistically clears its own card will
  desynchronise.
- **Track C's `aiterm-transcript` will expose the four token quantities
  separately** and will not pre-sum anything. If it returns a single "tokens"
  number, the distinction the registry protects is lost before it reaches me.
- **Track C does not need `Session` to be `Serialize`.** I deliberately did not
  derive it: serialization belongs to `wire.rs`, so the internal model can change
  without touching the frozen protocol.

---

## Things I nearly changed outside my scope, and did not

This is the section the Wave 2 integration should read first.

1. **`crates/aiterm-proto/` should own `wire.rs`.** `PROTOCOL.md` says in its
   own opening paragraph that the Rust projection of the protocol lives in
   `aiterm-proto`. It does not: it lives in `crates/aiterm-daemon/src/wire.rs`,
   because `aiterm-proto` is outside Track A's scope and rule 1 is absolute.
   This is the single largest piece of misplaced code in the repo right now.
   **Wave 2 should move it**, at which point `aiterm-cli` gets the types for
   free instead of duplicating them. I did depend on `aiterm-proto` for its
   constants (`PROTOCOL_VERSION`, `SOCKET_RELATIVE_PATH`), so the seam is
   already half there.

2. **`README.md` still says the daemon does transcript reading.** Its component
   table lists "JSONL transcript reading, token and context math" under
   `aiterm-daemon`. Wrong since the boundary correction. Left alone.

3. **ADR-002's motivating example is now slightly off.** It argues a daemon panic
   must not kill the app, using transcript parsing as the thing most likely to
   panic. The argument still holds — the daemon will consume
   `aiterm-transcript` — but the wording implies the parsing happens in-process
   here. Left alone.

4. **`aiterm-proto/src/lib.rs` has a `DEFAULT_HOOK_PORT` constant and nothing
   else that is used.** I wanted to add the message types next to it. Did not.

5. **I did not touch the workspace `Cargo.toml`.** `chrono`, `tokio` and
   `tempfile` are declared in the daemon's own manifest and are *not* promoted to
   `[workspace.dependencies]`, even though Track C will almost certainly want
   `chrono` too. Promoting them is a Wave 2 cleanup; doing it now would have
   edited a read-only file and probably conflicted with another track.

6. **I did not add a `[lib]` target to any other crate**, though `aiterm-cli`
   will need one to be testable the same way. The daemon needed lib+bin so its
   integration tests could import it; I added that only to my own manifest.
