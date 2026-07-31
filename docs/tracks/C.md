---
date: "2026-07-31"
type: log
tags: [aiterm, track-c, cli, hooks, doctor]
---

# Track C — the CLI: doctor, install-hooks, uninstall-hooks

Wave 2, last track. Scope as briefed: `crates/aiterm-cli/`,
`crates/aiterm-transcript/`, `docs/TRANSCRIPT_FORMAT.md`, and this file. Task 1
only — the CLI. Nothing was needed from outside the frozen protocol, so there is
no `docs/tracks/C-protocol-request.md`.

## Verified against the real thing

Not against a mock, and not only against unit tests. The full chain was driven
with **Claude Code v2.1.220** and the committed daemon:

1. `install-hooks` wrote the entries into a settings file.
2. Real `claude -p` was run with `--settings` pointing at that file.
3. The daemon received `UserPromptSubmit`, `Stop` and `SessionEnd`, and emitted
   `session_registered` → `session_updated` → `session_ended`.
4. With the tab pre-registered over the socket, `session_registered` came back
   carrying **`"tab_id": "tab-CLI-PROOF-42"`** — the binding of ADR-003, end to
   end, from a hook this CLI wrote.

The user's own `~/.claude/settings.json` was **never written to**. Every
install/uninstall ran against a copy under a disposable `HOME`, and the real
file is confirmed untouched — no aiterm entries, no backup files beside it.

### `allowedEnvVars` is the whole binding, and it is easy to miss

Claude Code interpolates `$AITERM_TAB_ID` into a header **only if the variable
is also listed in `allowedEnvVars`**; otherwise the reference resolves to an
empty string. The daemon deliberately reads an empty `x-aiterm-tab-id` as *no
tab*. So omitting one array would not error, would not warn, and would silently
unbind every session from its tab — the product's headline feature failing with
no symptom but a sidebar that never matches a tab.

Confirmed empirically rather than trusted: a logging server in place of the
daemon showed `x-aiterm-tab-id = 'tab-CLI-PROOF-42'` arriving on every request.
There is also a unit test asserting every entry declares the variable it
interpolates.

### The schema came from the binary, not from memory

`type: "http"` hook fields (`url`, `timeout`, `headers`, `allowedEnvVars`) were
read out of the Claude Code binary's embedded schema first and cross-checked
against the published docs second. Given that `docs/spikes/README.md` records
the documentation being wrong about this same hook three times, the binary is
the better first source.

## Two URLs, eleven events

Confirmed by reading `crates/aiterm-daemon/src/http/mod.rs`, as instructed:
`/hook/event` serves every informational hook and discriminates on the payload's
`hook_event_name`; `/hook/permission-request` is separate because it is the only
one that blocks. A `PermissionRequest` payload arriving at `/hook/event` is
answered `500` on purpose, so installing it wrongly is loud rather than subtle.

**A count that does not match the brief, stated rather than smoothed over.** The
brief said "the nine informational hooks" with `CwdChanged` among them. The
daemon's `HookEvent` enumerates exactly nine informational events and
`CwdChanged` is *not* one of them — it falls through to `Unrecognized`, which
the registry records as activity without deriving state or updating `cwd`. I
install ten informational events (the daemon's nine plus `CwdChanged`) because
`docs/PROTOCOL.md` documents `cwd` as "emitted on `cwd-changed`", so the wire
contract expects the event to exist. Dropping one to make the number read nine
would have been arithmetic, not engineering.

**Consequence for track A:** `CwdChanged` currently reaches the daemon and does
nothing useful. Adding it to `HookEvent` with `implied_state() == None` and
letting `observation()` pick up its `cwd` would make the sidebar's working
directory live. Not mine to change.

## The `PermissionRequest` conflict

This machine's global settings already had a competing hook — the superset
notifier, a `command` hook that exits 0 without emitting JSON. It is exactly the
case ADR-004 warns about: with two hooks on this event the first to decide wins
and the slower one is not awaited, and aiterm holds its answer open for minutes
waiting for a human, so it is *structurally* the slower one. A competing hook
does not degrade HITL; it silently wins.

Four explicit outcomes, no decision made on the user's behalf:

- **absorb** — the foreign group is moved out of the settings and parked in
  `~/.aiterm/absorbed-hooks.json`; `uninstall-hooks` puts it back where it was.
- **replace** — removed, with a copy-pasteable restore recipe printed first.
- **abort** — nothing changes.
- **coexist** — left in place, with a plain warning that HITL is now
  non-deterministic, and `doctor` reports ✗ until it is resolved.

`--yes` deliberately does **not** skip this prompt. `--yes` means "I have seen
the diff and accept it"; it cannot mean "delete another tool's hook for me",
because when the flag was typed the user had not been told there was one. A
non-interactive run that hits a conflict aborts.

**One thing "absorb" does not do yet.** The brief describes absorbing as *the
daemon invokes the old hook as an observer, ignoring its return*. The daemon has
no such mechanism, and the daemon is outside my scope. So absorb currently means
*moved aside and restorable* — the hook does not run while absorbed. The CLI
says this in plain text at the moment the user picks it, rather than letting
them infer a behaviour that does not exist. Making it true needs a daemon-side
observer invocation; that is a track A change, not a protocol change, which is
why it is here and not in a protocol request.

## `doctor`

Every check prints ✓/⚠/✗ and, when it is not ✓, what to type. Real output on
this machine found four true problems on the first run.

The check that earns the command is **trust**. Project settings in an untrusted
directory are ignored *in silence* — no warning, no log line — so the symptom is
"my hooks do not fire" and the cause is nowhere near the hooks. Trust is read
from `~/.claude.json` → `projects[<abs path>].hasTrustDialogAccepted`. This very
repository is not in that map, so the check fires on its own author's checkout.

It is a ⚠ and not a ✗: aiterm installs into *user* settings, which trust does
not gate, so it only bites someone who also keeps hooks in project settings. The
fix text says so rather than issuing an order for a problem the user may not
have.

## Never corrupting the settings file

Three rules, and a bug that a test caught.

**Merge, never overwrite.** Other hooks on the same event, other top-level keys
and key order all survive. Our entries are recognized by a `?src=aiterm` query
parameter on our own URL — not by an extra JSON key, because an unknown field is
a bet that Claude Code's schema is permissive, and losing that bet costs the
user a settings file that no longer loads. The marker also survives a port
change, so uninstall still finds entries installed against an old port.

**Refuse what cannot be round-tripped.** Claude Code accepts JSONC. `serde_json`
does not, and a parser that quietly dropped a comment would be deleting the
user's own notes. A file we cannot parse losslessly is a hard stop with an
explanation, never a best-effort rewrite.

**Preserve the file's formatting.** `serde_json` without `preserve_order` uses a
`BTreeMap`, so reading a file and writing it back *unchanged* alphabetizes every
key. The feature is enabled in `Cargo.toml` for that reason, with the reason
written next to it.

### The bug the round-trip test caught

`rendered()` hardcoded a four-space indent, on the stated assumption that "this
is what Claude Code writes". A test that reads the developer's **actual**
`~/.claude/settings.json`, re-renders it in memory and asserts the bytes match
failed immediately: the real file uses **two** spaces. Left alone, the first
`install-hooks` on any machine would have reindented the entire file — a diff
touching every line, to add eleven entries.

The fix was not to swap one guess for the other. The indent is now measured off
the file being edited, which is also the only version that survives a user who
indents with tabs. There is a test for two spaces, four spaces and tabs.

That test is worth keeping precisely because it is the one that cannot be
written from imagination: synthetic fixtures are written by the same person who
wrote the code, and share its assumptions.

### Tests

24 unit tests. The ones that matter:

- install → uninstall restores the file **byte for byte**, including a file that
  never had a `hooks` key getting none back
- installing twice changes nothing the second time
- reinstalling on a different port replaces rather than accumulates
- foreign hooks on the same event survive install *and* uninstall
- awkward-but-valid JSON round trips: escapes, non-ASCII, empty containers,
  large integers, deep nesting
- the real settings file round trips, if there is one

End-to-end, under a PTY (the CLI refuses destructive choices when stdin is not a
terminal, which is correct and also means a pipe cannot test it): absorb →
install → install again ("nothing to do") → uninstall → **byte-identical to the
original**, with the superset hook restored to its original position and the
parked file consumed.

## Deliberate omissions

- **No `clap`, no HTTP crate, no diff crate.** Three subcommands, two flags, one
  `GET /health` on loopback against a server we wrote, and a line diff that is
  thirty lines of LCS. Each dependency would have been larger than the code it
  replaced. Written out rather than assumed to be obvious.
- **`crates/aiterm-transcript/` does not exist.** Task 2 was not given. It also
  cannot be created without adding a member to the workspace `Cargo.toml`, which
  is read-only and outside my scope — flagging it now so it is not discovered
  mid-task later.
- **`docs/TRANSCRIPT_FORMAT.md` not written**, same reason.

## Outside my scope, noted and not touched

- **`docs/PROTOCOL.md` says "Status: v1 — normative"; the brief said v2.** I
  coded against the file, which is normative and which the brief also told me to
  read. Nothing depends on the answer: the wire `v` is `1` either way, which is
  what the daemon accepts and what `aiterm-proto::PROTOCOL_VERSION` says. Track
  B's log records the same discrepancy from wave 1, so it has now survived two
  tracks without being reconciled.
- **The daemon creates `~/.aiterm` with mode 755.** The socket is `0600`, but
  the directory holding it is world-readable and group/world-traversable. It is
  the daemon's control channel; another account on the machine should not be
  able to reach the directory. `doctor` reports it as ⚠ with `chmod 700` as the
  fix, which treats a symptom — the real fix is the daemon creating it `0700`.
- **`/health` counts a session as live after its `session_ended`.** Observed
  again here, as track B observed it. The registry appears to keep ended
  sessions until they expire, which makes the `sessions` count read high.
- **`request_snapshot` did not replay a session that `/health` was counting.**
  Seen once during testing: `/health` reported one session while a fresh
  `request_snapshot` on a new connection replayed nothing. It may be the same
  ended-session bookkeeping as above, and I did not chase it far enough to say.
  Recorded as an observation, not a diagnosis.

## Dependency change, which is a scope deviation

`crates/aiterm-cli/Cargo.toml` enables `serde_json`'s `preserve_order` feature.
That pulls in `indexmap` and therefore **modifies `Cargo.lock`**, which is at the
repository root and outside my scope. The workspace `Cargo.toml` was not
touched.

It is not avoidable: without the feature, every write reorders the user's
settings file alphabetically, which contradicts the central requirement of the
task. Feature unification means the daemon links the same `serde_json` build,
but the daemon serializes structs with fixed field order rather than arbitrary
maps, so its output is unaffected — its own test suite still passes.

## Assumptions about the other tracks

- **The daemon is authoritative for routing.** I read `http/mod.rs` rather than
  the brief, as instructed, and the two agreed.
- **`aiterm-proto` owns the protocol types.** `PROTOCOL_VERSION` and
  `DEFAULT_HOOK_PORT` are used from it, not re-declared. The CLI does not need
  the message types themselves: it never opens the socket for messaging, only to
  check that it accepts a connection.
- **The app (track B) is what sends `register_tab`.** The CLI never does. A hook
  carrying a tab id the daemon has not heard of registers with `tab_id: null`,
  which is correct and is what the pending-claim rule in `wire.rs` describes — it
  briefly looked like a bug in my hook configuration during testing, and was not.
