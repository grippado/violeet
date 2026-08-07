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

@testable import AITerm

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
    @Test("a vim-family editor opens on the first uncommitted hunk")
    func jumpsToFirstHunk() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        #expect(command.contains("nav_hunk"))
        #expect(command.contains("get_hunks"), "it must wait for hunks, not fire blind")
        #expect(command.contains("pcall(require,\"gitsigns\")"), "a missing gitsigns must not raise")
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

    /// Order matters and is invisible. Switching a display on makes gitsigns
    /// recompute, and the hunk list is empty while it does — so toggling first
    /// makes the jump report `No hunks` on a file with six of them. Measured
    /// both ways on the same file.
    @Test("the jump happens before the displays are switched on")
    func jumpPrecedesTheDisplays() {
        let command = AppState.editorCommand(forFileAt: "/tmp/a.md")
        guard let jump = command.range(of: "nav_hunk"),
              let firstToggle = command.range(of: "toggle_deleted")
        else {
            Issue.record("the command no longer both jumps and toggles")
            return
        }
        #expect(
            jump.lowerBound < firstToggle.lowerBound,
            "a toggle before the jump empties the hunk list under it"
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
