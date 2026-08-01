# Validation: session and tab names

What automated tests cover, and what only a person in front of the window can.

## Already measured (do not re-check by eye)

| Claim | Where |
|---|---|
| `tcgetpgrp` on the master PTY names the running program | `ForegroundProcessTests.theForegroundProgramIsReadable` |
| The name follows a program in **and out**: `zsh` → `sleep` → `zsh`, on a real shell driven by typed input | `ForegroundProcessTests.theNameFollowsTheProgramInAndOut` |
| Level 1 beats each of levels 2, 3, 4, 5 — and all four at once | `SessionNameTests`, five tests |
| `~` is `~` and never the login name | `SessionNameTests.homeIsTilde` |
| A shell in the foreground names nothing and falls through | `SessionNameTests.shellsAreNotNames` |
| An OSC title expires when its process goes | `SessionNameTests.oscTitleExpiresWithItsProcess` |
| Unlocking returns the name derived *while locked*, not the older one | `session.rs::releasing_a_manual_name_goes_back_to_the_best_derived_one` |
| `release_session_title` round-trips over the socket | `tests/socket.rs::releasing_a_manual_name_announces_the_derived_one` |
| Poll cost: 1.26µs per tab (proc_pidinfo 0.79 + proc_name 0.26 + tcgetpgrp 0.21) | measured over 100k iterations each |

## What a human has to check

Four tabs, set up like this:

1. **btop** — a tab running `btop`
2. **Claude Code** — a tab running an agent
3. **shell in `~`** — a plain shell, `cd ~`
4. **shell in a repo** — a plain shell in `~/www/personal/aiterm`

### Round 1 — automatic names

- [ ] Tab 1 is called `btop` within about a second of launching it
- [ ] Tab 2 is called by its prompt-derived title, and upgrades to Claude Code's own title one exchange later
- [ ] Tab 3 is called **`~`** — not `grippado`. This is the reported bug
- [ ] Tab 4 is called `aiterm`
- [ ] The window's title bar shows the selected tab's name and changes with the selection

### Round 2 — renaming

Rename all four, by double click on the name in the sidebar, and once by right
click → Rename.

- [ ] Each accepts the new name on Return
- [ ] Escape cancels and leaves the old name
- [ ] Clicking elsewhere cancels
- [ ] A small pin appears beside each renamed name
- [ ] **After each rename, type into the terminal without clicking back into
      it.** The characters must appear. This is the settings panel's rule and
      it fails silently: a terminal that lost first responder looks identical
      to one that has it

### Round 3 — the point of the whole task

Now change what each tab is doing, and watch the names.

- [ ] Quit btop in tab 1 → the name **does not change**
- [ ] Start `vim` in tab 3 → the name **does not change**
- [ ] Let the agent in tab 2 produce a new title → the name **does not change**
- [ ] `cd` somewhere else in tab 4 → the name **does not change**
- [ ] Leave it a minute with all four busy → still no name has changed

Any name that comes back on its own is the failure this task exists to prevent.

### Round 4 — back to automatic

- [ ] Right click → **Use automatic name** on tab 1: it becomes `btop` again if
      btop is running, or its directory if not
- [ ] On tab 2 it becomes the agent's own title — including one produced
      *while* the manual name was in force
- [ ] The pin disappears
- [ ] The menu item is greyed out on a tab that was never renamed

### Round 5 — restart

- [ ] Rename tab 2, quit **the daemon** (`aiterm daemon stop` / kill), start it
      again: the manual name comes back, still pinned
- [ ] Unlock it after the restart: it still falls back to the agent's title,
      not to the directory
- [ ] Rename a tab with **no session** in it, quit the app, reopen: the tab is
      gone, because tabs are not restored. Nothing to check — recorded here so
      the absence is not read as a bug

### Round 6 — the daemon is down

- [ ] Stop the daemon, rename a session-backed tab, start the daemon: the name
      is still there once it reconnects. The app holds unconfirmed renames and
      replays them on reconcile
