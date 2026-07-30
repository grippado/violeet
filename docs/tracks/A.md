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

- `src/main.rs` module-map doc comment — now names only `registry`, `http`,
  `socket`, and says explicitly where transcript went and that the dependency
  arrives in Wave 2.
- `Cargo.toml` `description` — still advertised "transcript reader".

**No dependency on `aiterm-transcript` was added.** The crate does not exist,
and nothing in the current task (registry, socket, HTTP hook endpoint) needs it.
Wiring is Wave 2 integration work.

`cargo check -p aiterm-daemon` passes after the removal.

#### Note for Wave 2 integration

I raised this before the correction landed, and record it because it shaped the
above: the original fan-out brief named `aiterm-transcript` as a Track C crate,
while the repo at `a77a1ac` had transcript as a module *inside* my scope. Had I
not been told to delete it, Track C would eventually have needed to edit a file
formally owned by Track A. The boundary is now clean: no file is claimed by two
tracks.

Consequence for whoever integrates: `docs/adr/` and `README.md` still describe
transcript reading as living in the daemon (README's component table, and
ADR-002's framing of what the daemon owns). Both are **outside my scope** and I
did not touch them. They need a pass in Wave 2.

---

## Assumptions about other tracks

*(filled in as they come up)*

## Things I nearly changed outside my scope, and did not

- `README.md` — the component table lists "JSONL transcript reading, token and
  context math" under `aiterm-daemon`, which is now wrong. Left alone.
- `docs/adr/ADR-002-daemon-processo-separado-unix-socket.md` — its context
  section leans on transcript parsing as the motivating example for why a daemon
  panic must not kill the app. The argument still holds (the daemon will consume
  `aiterm-transcript`), but the wording implies the parsing happens in-process
  here. Left alone.
