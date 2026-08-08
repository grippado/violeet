# Validating the settings panel

Two things about this panel cannot be asserted in a unit test, and both are the
reason it was built the way it was. They need a human at the keyboard.

Run both after any change to `Settings/`, to `ContentView`, or to how a terminal
view is mounted.

---

## 1. Focus — the panel must never take the keyboard

**Why a script and not a test.** First responder is a property of a live
`NSWindow` with a real event loop and a real click. A test can assert that a
control declines the key view loop; it cannot assert that AppKit did not hand
focus to something else on the way, which is the failure that actually happens.
The symptom is also silent: a terminal that has lost first responder looks
exactly like one that has it, right up until you type into nothing.

### Setup

1. Open violeet. One tab, shell prompt visible.
2. `⌥⌘I` to open the panel.
3. Click into the terminal and type `echo focus` — **do not press Return.** The
   line on screen is the probe: every step below must be able to add to it.

### The steps

For each row, do the action, then type one more character in the terminal
**without clicking anywhere first**. The character must appear.

| # | Where | Action | Must still type |
|---|---|---|---|
| 1 | grid | Click **Appearance** | ✓ |
| 2 | Appearance | Click a theme row | ✓ |
| 3 | Appearance | Click a swatch under Background | ✓ |
| 4 | Appearance | Click an ANSI swatch, then a colour for it | ✓ |
| 5 | Appearance | Click the hex field, type `#112233`, press **Return** | ✓ |
| 6 | Appearance | Click the hex field, type nothing, click the terminal | ✓ |
| 7 | Font | Open the family menu, pick a font | ✓ |
| 8 | Font | Click `+` and `−` on Size | ✓ |
| 9 | Cursor | Click **Bar**, then **Off** | ✓ |
| 10 | Window | Drag the Opacity slider and release | ✓ |
| 11 | Terminal | Open the Scrollback menu, pick a value | ✓ |
| 12 | any | Click **All** to go back | ✓ |
| 13 | header | `⌥⌘I` to close the panel | ✓ |

Step 5 is the only text field in the panel and the one most likely to regress.
Step 6 checks the other half of it: clicking away is a **cancel**, so the field
must go back to the colour that is actually in use and the terminal must have
the keyboard.

### What a failure looks like

You type and nothing appears. Click the terminal once and it works again. That
is the bug, not a quirk — write down which row it was, because they fail for
different reasons: a control that joined the key view loop, or one whose
`onCommit` is not wired.

### The one thing that is allowed to hold focus

The hex field, while it is being typed into. That is what a text field is. It
gives the keyboard back on Return or on click-away, and nothing else in the
panel ever holds it at all.

---

## 2. The PTY — a font change must reach the program

**Why this matters more than it looks.** Font family, size and line spacing
change the cell size, which changes how many columns and rows fit. The program
on the other end of the PTY cannot see that. Without `TIOCSWINSZ` and the
`SIGWINCH` it raises, violeet redraws at the new size while the program keeps
composing for the old one — and a full-screen TUI tears the moment anything
repaints.

### The steps

1. Open a tab and start `claude` in it. Let it draw its prompt box.
2. `⌥⌘I` → **Font**.
3. Press `+` on **Size** three times, slowly.

**Expected:** the prompt box redraws at the new width each time, staying
correct. Its border lines up. Nothing is clipped and nothing wraps oddly.

**Failure:** the box keeps its old width while the text around it gets bigger,
or the border breaks. That means the resize reached the view and not the child.

4. Press `−` three times to go back. The box must re-fit again — shrinking is
   the direction that exposes a stale size most obviously, because the program
   composes lines wider than the window can hold.

5. Repeat with **Line spacing**, which changes rows rather than columns. A
   full-screen program should keep filling the window exactly.

### A second, harsher check

6. Open a second tab and run `claude` there too. Switch back to tab 1.
7. Change the font size.
8. Switch to tab 2.

**Expected:** tab 2 is already correct — no reflow on arrival.

**Failure:** tab 2 visibly re-lays-out when you switch to it. That means only
the visible terminal was told, and the agent in the background one has been
composing for the wrong width the entire time. Every tab is kept mounted at full
size specifically so this works; if this fails, check that the unselected
terminals are still in the view hierarchy.

### Cheap instrumentation

If the visual check is ambiguous, run this in the tab instead of an agent:

```sh
trap 'echo "SIGWINCH -> $(tput cols)x$(tput lines)"' WINCH; while :; do sleep 1; done
```

Every font change must print a line with the new dimensions. No line means no
signal reached the child, which is the whole failure this section is for.
