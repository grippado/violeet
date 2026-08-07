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
