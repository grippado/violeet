// What a tab is called, decided in one place.
//
// # Why this file exists at all
//
// A name has six plausible sources — the human, the file a tab was opened to
// edit, the program in the foreground, the agent's own title, the working
// directory, and a generic last resort — and every one of them updates at a
// different moment. Spread
// the precedence across the views that render it and you get the worst bug
// this feature can have: *I renamed it and it came back on its own*. That is
// not a cosmetic failure. It teaches the user that renaming does not work,
// and after the second time they stop doing it.
//
// So the rule is a pure function over a value. Not a method on the tab, not a
// computed property on the card: a function, with the whole input in front of
// it, testable without a window. There is one test per level and one test for
// each of the four ways level 1 has to win.
//
// # The order
//
//  1. **The human.** Nothing overrides it. Ever.
//  2. **The file the tab was opened to edit**, when there is one. The tab
//     exists because of that file; the editor running it is a detail.
//  3. **The foreground process** — `btop`, `vim`, `ssh`. What the tab *is
//     doing* beats where it is.
//  4. **The agent's title** — derived from the first prompt, upgraded to
//     Claude Code's own `ai-title`. What the tab is *for*.
//  5. **The working directory.**
//  6. **A generic fallback**, for a tab that has told us nothing.
//
// # Where each level comes from
//
// Levels 2, 3 and 5 are the app's own knowledge: only it holds the PTY and only
// it spawned the editor. Level 4 belongs to the daemon, which decides between prompt and `ai-title` on its
// own rank ladder and sends the winner. Level 1 can arrive from either side —
// a tab with no session is renamed locally, a session is renamed through
// `rename_session` — and both arrive here as the same field.

import Foundation

/// Which level named a tab. Rendered, not just recorded: the lock badge and
/// the "back to automatic" menu item both need to know.
enum NameSource: Equatable {
    case manual
    case process
    case agent
    case directory
    case fallback

    /// Whether automatic naming is switched off. One place, so no view can
    /// invent a second definition of "locked".
    var isLocked: Bool { self == .manual }
}

/// Everything that could name a tab, gathered before anything decides.
struct NameInputs: Equatable {
    /// A name the user typed for a tab that has no agent session. The app owns
    /// this one, because the daemon has nowhere to put it.
    var manualName: String?

    /// The title the daemon holds for this tab's session, and who set it.
    /// `titleSource == "user"` is a manual rename that the daemon has already
    /// persisted — including one made in a previous run.
    var agentTitle: String?
    var agentTitleSource: String?

    /// The program in the foreground of the PTY right now, as the kernel
    /// reports it. Already stripped of a login shell's leading dash by
    /// `ForegroundProcess`; shells are filtered here, not there, so the rule
    /// is testable without a PTY.
    var foregroundProcess: String?

    /// A title the program set with OSC 0/2, and the foreground process it was
    /// set under.
    ///
    /// An optional layer *above* the process name, never a source of its own —
    /// see `Naming/README` reasoning in `ForegroundProcess`. Carrying the
    /// process it arrived under is what makes it expire: a program that sets a
    /// title and exits without clearing it would otherwise leave the tab
    /// wearing that name for ever.
    var oscTitle: String?
    var oscProcess: String?

    var cwd: String?

    /// The file this tab was opened to edit, when it was.
    ///
    /// The same fact the OSC layer below is trying to obtain, arriving by a
    /// route that cannot fail: this app spawned the editor and knows what it
    /// handed it. No stock shell in this app emits OSC — see `ProcessDirectory`
    /// for the same problem with `cwd` — so waiting for vim to announce its
    /// filename means waiting for something that never comes, and the tab sits
    /// there called `nvim` while three of them are open.
    var editingFile: String?

    init(
        manualName: String? = nil,
        agentTitle: String? = nil,
        agentTitleSource: String? = nil,
        foregroundProcess: String? = nil,
        oscTitle: String? = nil,
        oscProcess: String? = nil,
        cwd: String? = nil,
        editingFile: String? = nil
    ) {
        self.manualName = manualName
        self.agentTitle = agentTitle
        self.agentTitleSource = agentTitleSource
        self.foregroundProcess = foregroundProcess
        self.oscTitle = oscTitle
        self.oscProcess = oscProcess
        self.cwd = cwd
        self.editingFile = editingFile
    }
}

struct ResolvedName: Equatable {
    let text: String
    let source: NameSource

    var isLocked: Bool { source.isLocked }
}

enum SessionName {
    /// What a tab is called when it has told us nothing at all.
    ///
    /// Not "unknown": the tab is not unknown, it is simply new. And not the
    /// empty string, which would render as a row with no name and no height.
    static let fallback = "terminal"

    /// Program names that describe nothing.
    ///
    /// A shell in the foreground is the *absence* of a running program — it is
    /// what the PTY reports between commands — so it must not name the tab.
    /// Every tab would be called "zsh", which is worse than no rule at all.
    /// Falling through to the next level is what makes `btop` → `zsh` read as
    /// "back to whatever this tab is about" rather than as "now called zsh".
    static let shells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "login",
    ]

    /// The one decision. Every renderer calls this and none of them second-guess it.
    static func resolve(_ input: NameInputs) -> ResolvedName {
        // ---- 1. the human -------------------------------------------------
        //
        // The daemon's copy is checked first, and that ordering is deliberate:
        // for a tab that has a session, the daemon is the source of truth for
        // a manual name (it persists it, and it is the only one that knows
        // about a rename made before this app launched). A local `manualName`
        // on the same tab is a name the app is about to promote into the
        // daemon, so preferring the daemon's cannot lose anything.
        if isUser(input.agentTitleSource), let title = trimmed(input.agentTitle) {
            return ResolvedName(text: title, source: .manual)
        }
        if let manual = trimmed(input.manualName) {
            return ResolvedName(text: manual, source: .manual)
        }

        // ---- 2. what the tab is *for* --------------------------------------
        //
        // Above the process, and that is the point rather than an oversight.
        // A tab opened from the Files panel exists because of one file; the
        // program editing it is an implementation detail of that. Three such
        // tabs all called `nvim` is a tab strip that has stopped naming
        // anything — which is exactly what it did.
        //
        // This is the same judgement the OSC layer below makes ("`vim`
        // announcing the file it has open is worth more than `vim`"), reached
        // without needing vim to announce anything. It is also more stable than
        // the process: the file does not change for the life of the tab, and
        // `EditorTab` is set once, at spawn, for that reason.
        if let file = trimmed(input.editingFile) {
            return ResolvedName(text: file, source: .process)
        }

        // ---- 3. what the tab is doing --------------------------------------
        if let process = usefulProcess(input.foregroundProcess) {
            // The OSC title rides on top, and only while the process that set
            // it is still there. `vim` announcing the file it has open is
            // worth more than "vim"; `vim` having exited two hours ago and
            // left its title behind is worth less than nothing.
            if let osc = trimmed(input.oscTitle),
               let under = usefulProcess(input.oscProcess),
               under == process {
                return ResolvedName(text: osc, source: .process)
            }
            return ResolvedName(text: process, source: .process)
        }

        // ---- 4. what the agent says it is ----------------------------------
        //
        // `cwd` as a daemon source is skipped on purpose: that is level 4
        // wearing level 3's clothes, and the app's own rule for directories is
        // better than the daemon's (it knows about `$HOME`).
        if isDerivedAgentTitle(input.agentTitleSource), let title = trimmed(input.agentTitle) {
            return ResolvedName(text: title, source: .agent)
        }

        // ---- 5. where the tab is -------------------------------------------
        if let directory = directoryName(input.cwd) {
            return ResolvedName(text: directory, source: .directory)
        }

        // ---- 6. nothing ------------------------------------------------------
        return ResolvedName(text: fallback, source: .fallback)
    }

    /// A directory's name, as a person would say it.
    ///
    /// `$HOME` is `~` and not the login name. That is not a nicety: the home
    /// directory's last component is the user's username, so every tab sitting
    /// in `~` was called "grippado" — a name that is the same for every such
    /// tab, describes nothing, and reads as though it meant something.
    ///
    /// Everything else is the last component, which is the repository or
    /// project name in the case that matters. The full path is never the name:
    /// it is on the card in its own right, under the title, where a long
    /// string can wrap.
    static func directoryName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path == home || path == home + "/" { return "~" }
        if path == "/" { return "/" }

        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    /// The foreground process name, or `nil` when it does not name anything.
    static func usefulProcess(_ name: String?) -> String? {
        guard let name = trimmed(name) else { return nil }
        // A login shell's argv[0] is `-zsh`. The dash is the convention, not
        // part of the name.
        let bare = name.hasPrefix("-") ? String(name.dropFirst()) : name
        guard !bare.isEmpty, !shells.contains(bare.lowercased()) else { return nil }
        return bare
    }

    private static func isUser(_ source: String?) -> Bool {
        source == "user"
    }

    /// The daemon sources that describe the work rather than the place.
    private static func isDerivedAgentTitle(_ source: String?) -> Bool {
        switch source {
        case "prompt", "ai_title": return true
        // A session registered before any `session_updated` has no source yet,
        // and its title — when it has one — came from the same two places.
        // Treating it as derived is what keeps a card from flickering
        // through its directory on the first frame.
        case nil: return true
        default: return false
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
