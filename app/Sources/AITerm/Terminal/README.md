# Terminal

Terminal tabs: VT emulation and PTY handling via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).
See `docs/adr/ADR-001` for why we host SwiftTerm instead of writing an emulator.

Each spawned tab exports `AITERM_TAB_ID` into the child environment; that is the
whole tab-to-session binding mechanism (`docs/adr/ADR-003`).

Not implemented yet.
