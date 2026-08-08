// Quoting the one string that reaches a shell.
//
// The Files panel opens a file by running `${VISUAL:-${EDITOR:-vi}} <path>` in
// a new tab, and the path comes off the wire — it is whatever the agent wrote,
// which is whatever the user asked it to write. Everything else in that command
// is a literal in the source; this is the only part that is data, so it is the
// only part that can carry a quote, a space, a `$` or a `;` into a shell that
// would otherwise act on them.
//
// These are tests about a string, not about a terminal: what matters is that
// the bytes between the quotes cannot end the quoting early.

import Foundation
import Testing

@testable import Violeet

@Suite("Editor tabs")
struct EditorTabTests {
    /// The row under a session card is named by the file, not by the path: the
    /// tree above it already said where the file lives.
    @Test("an editor tab is named by its file")
    func namedByFile() {
        #expect(EditorTab(path: "/a/b/notes.md", sessionID: "s1").name == "notes.md")
        #expect(EditorTab(path: "notes.md", sessionID: nil).name == "notes.md")
    }

    /// Identity is the path. Two rows for one file in one session would be two
    /// editors on one buffer, which is how the older copy wins.
    @Test("tabs for the same file are the same tab")
    func pathIsIdentity() {
        let first = EditorTab(path: "/a/b.md", sessionID: "s1")
        let again = EditorTab(path: "/a/b.md", sessionID: "s1")
        #expect(first == again)
        #expect(first != EditorTab(path: "/a/c.md", sessionID: "s1"))
    }
}

@Suite("Shell quoting")
struct ShellQuotingTests {
    private func quoted(_ path: String) -> String {
        AppState.shellQuoted(path)
    }

    @Test("an ordinary path is wrapped and otherwise untouched")
    func plainPath() {
        #expect(quoted("/Users/x/notes.md") == "'/Users/x/notes.md'")
    }

    @Test("spaces stay one argument")
    func spaces() {
        #expect(quoted("/Users/x/My Notes/a b.md") == "'/Users/x/My Notes/a b.md'")
    }

    /// Inside single quotes the shell expands nothing, so these need no
    /// escaping — and must not get any, or the editor would open a file whose
    /// name contains a backslash.
    @Test("shell metacharacters are inert, not escaped")
    func metacharacters() {
        #expect(quoted("/tmp/$HOME.md") == "'/tmp/$HOME.md'")
        #expect(quoted("/tmp/a;rm -rf b.md") == "'/tmp/a;rm -rf b.md'")
        #expect(quoted("/tmp/`whoami`.md") == "'/tmp/`whoami`.md'")
        #expect(quoted("/tmp/a$(id).md") == "'/tmp/a$(id).md'")
    }

    /// The only character single quoting cannot contain. Close, escape, reopen
    /// — the shell concatenates adjacent quoted runs into one word.
    @Test("a quote in the name closes and reopens the quoting")
    func embeddedQuote() {
        #expect(quoted("/tmp/it's here.md") == "'/tmp/it'\\''s here.md'")
    }

    /// The precedence the fallback exists for. `$VISUAL` and `$EDITOR` come
    /// first because setting either is a statement of intent; the search below
    /// them exists because neither is set on a stock macOS account, where
    /// honouring the convention literally would open the system `vi` on a
    /// machine that has Neovim.
    @Test("the editor chain prefers the user's, then the best installed")
    func editorChain() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        #expect(command.contains("${VISUAL:-${EDITOR:-}}"))
        guard let nvim = command.range(of: "nvim"),
              let vim = command.range(of: " vim"),
              let vi = command.range(of: " vi;")
        else {
            Issue.record("the fallback no longer names nvim, vim and vi")
            return
        }
        #expect(nvim.lowerBound < vim.lowerBound, "nvim must be tried before vim")
        #expect(vim.lowerBound < vi.lowerBound, "vim must be tried before vi")
    }

    /// `exec`, so the editor replaces the shell and quitting it closes the tab
    /// — the same rule a tab already follows when its shell exits.
    @Test("the editor replaces the shell, and gets the path quoted")
    func commandExecsWithQuotedPath() {
        let command = AppState.editorCommand(forFileAt: "/tmp/it's here.md")
        #expect(command.contains("exec $editor -c "))
        #expect(command.contains("'/tmp/it'\\''s here.md'"))
    }

    /// The jump waits for hunks to exist, because the attach is asynchronous and
    /// gitsigns' own `GitSignsUpdate` fires once before they are computed.
    ///
    /// It then places the cursor from the hunk it was handed, rather than
    /// asking gitsigns to navigate. `nav_hunk("first")` reads a cursor already
    /// inside the first hunk as a reason to move to its far edge, and a new
    /// file is one hunk covering every line — so `nav_hunk` opened a 114-line
    /// new file on line 114. Measured before and after.
    @Test("a vim-family editor opens on the first uncommitted hunk")
    func jumpsToFirstHunk() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        #expect(command.contains("nvim_win_set_cursor"))
        #expect(command.contains("h[1].added.start"), "the position comes from the hunk, not from a navigator")
        #expect(!command.contains("nav_hunk"), "nav_hunk lands on the wrong end of a whole-file hunk")
        #expect(command.contains("get_hunks"), "it must wait for hunks, not fire blind")
        #expect(command.contains("pcall(require,\"gitsigns\")"), "a missing gitsigns must not raise")
    }

    /// A hunk that only deletes reports `added.start` as 0, meaning "after this
    /// line". Passing it straight through is an invalid cursor position.
    @Test("a pure deletion does not ask for line zero")
    func deletionOnlyHunkClamps() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        #expect(command.contains("math.max(1,h[1].added.start)"))
    }

    /// The sign column marks *that* a line changed and never what it replaced.
    /// `toggle_deleted` is the one that carries the weight: without it a
    /// deletion leaves no trace and the file reads as if nothing was there.
    @Test("the diff is shown, not only marked")
    func showsTheDiffItself() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        #expect(command.contains("toggle_deleted"), "a deletion must not be invisible")
        #expect(command.contains("toggle_word_diff"))
        #expect(command.contains("toggle_linehl"))
    }

    /// Order used to matter and was invisible. Switching a display on makes
    /// gitsigns recompute, and the hunk list is empty while it does — so a
    /// `nav_hunk` issued after the toggles reported `No hunks` on a file with
    /// six of them. Measured both ways on the same file.
    ///
    /// The position now comes from `h`, a table read once before any toggle
    /// runs, so a recompute underneath it cannot take the answer away. The
    /// order is kept anyway — it costs nothing and the failure it prevented was
    /// silent — but this test asserts the property that actually protects it
    /// now, which is that the cursor never re-reads the hunk list.
    @Test("the position is taken before the displays can disturb it")
    func jumpPrecedesTheDisplays() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        guard let jump = command.range(of: "nvim_win_set_cursor"),
              let firstToggle = command.range(of: "toggle_deleted")
        else {
            Issue.record("the command no longer both places the cursor and toggles")
            return
        }
        #expect(
            jump.lowerBound < firstToggle.lowerBound,
            "the cursor is placed before anything can make gitsigns recompute"
        )
        #expect(
            !command.contains("gs.get_hunks()") || command.range(of: "gs.get_hunks()")!.lowerBound < jump.lowerBound,
            "the hunk list is read once, before the cursor is placed"
        )
    }

    /// Set, not toggled. A toggle assumes it knows the current value and would
    /// switch these off for a user whose own config turns them on.
    @Test("the displays are set true, never flipped")
    func displaysAreSetNotToggled() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        for display in ["toggle_deleted", "toggle_word_diff", "toggle_linehl"] {
            #expect(
                command.contains("pcall(gs.\(display),true)"),
                "\(display) must be set to true explicitly"
            )
        }
    }

    /// The bound is the point. An unbounded wait would still be armed after the
    /// file is open, so the first edit that made gitsigns recompute would pull
    /// the cursor away from wherever the user was typing.
    @Test("the jump gives up rather than staying armed")
    func jumpIsBounded() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        #expect(command.contains("t<20"), "the retry must terminate")
        #expect(command.contains("return end"), "finding a hunk must stop the retry")
        #expect(!command.contains("autocmd"), "an autocmd would outlive the opening")
    }

    /// `-c` belongs to vim and nvim. An `$EDITOR` of `code` or `emacs` reads it
    /// as something else entirely, so the command has two branches.
    @Test("only vim-family editors are handed -c")
    func onlyVimFamilyGetsTheFlag() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        #expect(command.contains("case \"${editor##*/}\" in"), "the branch keys off the program name, not the full path")
        #expect(command.contains("nvim|nvim\\ *|vim|vim\\ *"))
        // The other branch exists and is plain.
        #expect(command.contains("exec $editor '/tmp/a.md'"))
    }

    // MARK: - Diff mode

    /// The default is inline, and it is a decision rather than an accident: a
    /// vertical split in an 80-column tab leaves 40 a side, and that is where a
    /// terminal usually is.
    @Test("the diff is inline unless the user said otherwise")
    func inlineIsTheDefault() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        #expect(command.contains("toggle_deleted"))
        #expect(!command.contains("diffthis"))
    }

    /// Side by side is `diffthis` and nothing else. The inline displays would
    /// be marking up one half of a window that is already showing both, and the
    /// jump is redundant because vim's diff mode opens on the first change.
    @Test("side by side splits, and does not also mark up the buffer")
    func sideBySideIsOnlyTheSplit() {
        let command = AppState.editorCommand(
            forFileAt: "/tmp/a.md",
            settings: TerminalSettings.EditorSettings(diffMode: .sideBySide)
        )
        #expect(command.contains("pcall(gs.diffthis)"))
        #expect(!command.contains("nvim_win_set_cursor"), "the split already opens on the first change")
        #expect(!command.contains("toggle_deleted"), "the other half is where the deleted lines are")
        #expect(!command.contains("toggle_word_diff"))
    }

    /// Both modes wait the same way. The poll is the part that knows the attach
    /// is asynchronous, and it does not become unnecessary because the payload
    /// changed — a `diffthis` issued before the attach diffs against nothing.
    @Test("both modes wait for the attach")
    func bothModesPoll() {
        for mode in TerminalSettings.EditorSettings.DiffMode.allCases {
            let command = AppState.editorCommand(
                forFileAt: "/tmp/a.md",
                settings: TerminalSettings.EditorSettings(diffMode: mode)
            )
            #expect(command.contains("get_hunks"), "\(mode.label) must wait for hunks")
            #expect(command.contains("t<20"), "\(mode.label) must give up rather than stay armed")
        }
    }

    // MARK: - Minimap

    /// Detected, never installed. A terminal that edits your Neovim config to
    /// draw a sidebar has overstepped — the same surface ADR-003 declined for
    /// tab binding.
    @Test("the minimap is asked for, never required")
    func minimapIsOptional() {
        let off = AppState.editorCommand(forFileAt: "/tmp/a.md")
        #expect(!off.contains("mini.map"), "off by default")

        let on = AppState.editorCommand(
            forFileAt: "/tmp/a.md",
            settings: TerminalSettings.EditorSettings(showMinimap: true)
        )
        #expect(on.contains("pcall(require,\"mini.map\")"), "a missing plugin must not raise")
        #expect(on.contains("pcall(mm.open)"))
    }

    /// The map is not part of the diff. It is drawn from the buffer, so it
    /// belongs to opening the file and not to finding a hunk — a clean file
    /// with the setting on still gets one.
    @Test("the minimap does not depend on there being a diff")
    func minimapIsIndependentOfHunks() {
        let command = AppState.editorCommand(
            forFileAt: "/tmp/a.md",
            settings: TerminalSettings.EditorSettings(showMinimap: true)
        )
        guard let poll = command.range(of: "if t<20"),
              let map = command.range(of: "mini.map")
        else {
            Issue.record("the command no longer both polls and opens a map")
            return
        }
        #expect(
            poll.upperBound < map.lowerBound,
            "the map must sit outside the hunk poll, not inside its success branch"
        )
    }

    /// The property the whole thing rests on: whatever the path is, the result
    /// is a single shell word. Counted by the runs between quotes rather than
    /// by running a shell, since the test has no business spawning one.
    @Test("no path can escape its quoting")
    func quotingAlwaysCloses() {
        let paths = [
            "/tmp/plain.md",
            "/tmp/it's.md",
            "/tmp/''.md",
            "/tmp/a'b'c'.md",
            "/tmp/'",
        ]
        for path in paths {
            let result = quoted(path)
            #expect(result.hasPrefix("'"), "\(path) does not open quoted")
            #expect(result.hasSuffix("'"), "\(path) does not close quoted")
            // Every quote in the result is either one of the wrapping pair or
            // part of a `'\''` sequence. An odd count anywhere else would mean
            // the path had ended the quoting and kept going unquoted.
            let quotes = result.filter { $0 == "'" }.count
            let embedded = path.filter { $0 == "'" }.count
            #expect(quotes == 2 + embedded * 3, "\(path) produced unbalanced quoting")
        }
    }
}
