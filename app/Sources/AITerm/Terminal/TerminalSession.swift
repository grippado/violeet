// One tab's terminal: a SwiftTerm view, the PTY behind it, and the environment
// the child was born with.
//
// ADR-001 hands the grid to SwiftTerm and asks the app to stay out of its way,
// so this class is thin on purpose. It owns three things SwiftTerm does not:
//
//  1. **The environment injection.** `AITERM_TAB_ID` is the whole tab/session
//     binding mechanism (ADR-003), and it has to be in the child's environment
//     from `exec` — there is no retrofitting it into a running shell.
//  2. **The working directory and the foreground program.** Both polled from
//     the kernel, because no stock macOS shell reports either. See
//     `ProcessDirectory` and `ForegroundProcess`.
//  3. **Lifecycle callbacks** the tab model needs: title, cwd, foreground,
//     and exit.

import AppKit
import Foundation
import SwiftTerm

final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    /// How often to ask the kernel where the shell is and what it is running.
    ///
    /// One timer for both, because they answer the same question — what is
    /// this tab? — and two timers would be two schedules to reason about for
    /// no gain.
    ///
    /// **One second**, and the number is a judgement backed by a measurement,
    /// not a default. The poll is three syscalls per tab — `proc_pidinfo` for
    /// the directory, `tcgetpgrp` + `proc_name` for the foreground — each a
    /// read of a struct the kernel already holds: no allocation, no fork, no
    /// filesystem.
    ///
    /// Timed on this machine over 100k iterations each: `proc_pidinfo` 0.79µs,
    /// `proc_name` 0.26µs, `tcgetpgrp` 0.21µs — **1.26µs per tab per poll**.
    /// Eight tabs at 1Hz is ten microseconds of CPU per second, or one part in
    /// a hundred thousand of one core. The cost is not the reason to choose a
    /// slower interval, so it did not.
    ///
    /// It was 2s for the directory alone, and 2s is wrong for a name: you
    /// launch `btop` and watch the tab sit on its old name for what reads as a
    /// hang. At 1s the rename lands within the time it takes to look up. Below
    /// that there is nothing to win — a human cannot tell 250ms from 1s here —
    /// and the cost multiplies by four.
    ///
    /// Selecting a tab polls it immediately as well, so switching tabs never
    /// shows a name up to a second old.
    private static let pollInterval: TimeInterval = 1

    let view: LocalProcessTerminalView

    /// The id exported as `AITERM_TAB_ID` and sent in `register_tab`. Opaque,
    /// minted by the app, stable for the life of the tab, never reused.
    let tabID: String

    private(set) var currentDirectory: String?
    /// The program in the foreground of the PTY, as the kernel reports it.
    /// `nil` before the first poll and whenever it cannot be read.
    private(set) var foregroundProcess: String?
    private(set) var hasExited = false

    /// All four fire on the main queue.
    var onDirectoryChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    /// The foreground process changed. Carries the new one, `nil` when the
    /// kernel stopped answering.
    var onForegroundChange: ((String?) -> Void)?
    var onExit: ((Int32?) -> Void)?

    private var poller: DispatchSourceTimer?

    init(tabID: String, font: NSFont) {
        self.tabID = tabID
        self.view = LocalProcessTerminalView(frame: .zero)
        super.init()
        view.processDelegate = self
        view.font = font
        view.configureNativeColors()
    }

    // MARK: - Starting

    /// Spawn the user's login shell.
    ///
    /// A **login** shell, deliberately: an app launched from Finder inherits
    /// almost no environment, so anything short of `-l` gives the user a `PATH`
    /// without Homebrew in it and a shell that does not look like their shell.
    /// `shellOverride` empty means the account's own shell. A configured shell
    /// that has since been uninstalled falls back rather than failing: a tab
    /// that opens to nothing is worse than a tab that opens to zsh.
    /// `command`, when given, is run by that shell instead of a prompt. Still
    /// the login shell, and for the same reason: the command needs the user's
    /// `PATH` to find `nvim` at all, and `-c` on a login shell reads
    /// `.zprofile`, which is where that `PATH` comes from.
    func start(
        inDirectory directory: String,
        socketPath: String,
        shell shellOverride: String = "",
        command: String? = nil
    ) {
        let shell = Self.resolveShell(shellOverride)
        let name = (shell as NSString).lastPathComponent

        currentDirectory = directory
        view.startProcess(
            executable: shell,
            args: command.map { ["-c", $0] } ?? [],
            environment: Self.environment(tabID: tabID, socketPath: socketPath),
            // A leading dash in argv[0] is how Unix says "login shell". The
            // shell reads it off its own name; there is no flag for it here
            // because `args` would be argv[1...].
            execName: "-\(name)",
            currentDirectory: directory
        )
        startPolling()
    }

    /// The environment the child is born with.
    ///
    /// Built from the app's own environment rather than from SwiftTerm's
    /// defaults: those omit `PATH` entirely, which a login shell recovers but
    /// anything else launched in this tab would not.
    static func environment(tabID: String, socketPath: String) -> [String] {
        var variables = ProcessInfo.processInfo.environment

        // Whatever agent launched *aiterm* must not be inherited by the agents
        // aiterm launches.
        //
        // Measured, and it is not hypothetical: an aiterm started from inside a
        // Claude Code session inherits that session's markers, and copying the
        // environment wholesale hands them to every tab. The result was a
        // session announcing itself as a child of a session it has nothing to
        // do with — and, worse for this app specifically,
        // `CLAUDE_CODE_CHILD_SESSION` turns transcript writing **off**. The
        // transcript is where every number on a card comes from, so aiterm was
        // blinding itself: no tokens, no title, no last action.
        //
        // Stripping is safe because the child is a **login** shell. Anything
        // the user actually configured — in `.zprofile`, `.zshrc`, direnv — is
        // put back by the shell a moment later. The only thing lost is state
        // that belonged to a different process.
        for name in Self.inheritedAgentState {
            variables.removeValue(forKey: name)
        }

        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        // Without a UTF-8 locale, full-screen tools emit sequences that are not
        // UTF-8 friendly and the grid fills with replacement characters.
        if variables["LANG"] == nil { variables["LANG"] = "en_US.UTF-8" }
        variables["TERM_PROGRAM"] = "aiterm"

        // The binding (ADR-003). Everything downstream inherits it for free —
        // tmux, direnv, wrapper scripts — which is the entire reason it is an
        // environment variable and not a heuristic.
        variables["AITERM_TAB_ID"] = tabID
        // So a child (the CLI, an installed hook) can find the daemon without
        // re-deriving the path.
        variables["AITERM_SOCKET"] = socketPath

        return variables.map { "\($0.key)=\($0.value)" }
    }

    /// Variables that describe *a* session and must never describe another.
    ///
    /// Named individually rather than matched by prefix. A prefix would also
    /// take a user's own `CLAUDE_CONFIG_DIR` or API key if they set it outside
    /// their shell profile, and this list is meant to remove state that leaked
    /// in, not configuration someone chose. Every name here was read off a
    /// running process, not guessed.
    static let inheritedAgentState: Set<String> = [
        // Claude Code's own session markers.
        "CLAUDECODE",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_PID",
        "CLAUDE_EFFORT",
        // And aiterm's own, for the case that catches people out: an aiterm
        // launched from inside an aiterm tab would otherwise hand every new tab
        // the *old* tab's id, and every session in it would bind to a tab in
        // another window.
        "AITERM_TAB_ID",
        "AITERM_SOCKET",
    ]

    static func resolveShell(_ override: String) -> String {
        guard !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) else {
            return userShell()
        }
        return override
    }

    /// `$SHELL`, else the account's shell, else `/bin/zsh`.
    static func userShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        // `getpwuid` is what the login window used; `$SHELL` can be absent when
        // the app is launched by `launchd` or from Finder.
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty { return shell }
        }
        return "/bin/zsh"
    }

    // MARK: - Live settings

    /// Push the whole settings value onto this terminal.
    ///
    /// # The part that is not cosmetic
    ///
    /// Font family, size and line spacing change the **cell** size, which
    /// changes how many columns and rows fit — and the program on the other end
    /// of the PTY has no way to notice on its own. Without `TIOCSWINSZ` and the
    /// `SIGWINCH` it raises, aiterm redraws at 90 columns while Claude Code
    /// keeps composing for 120, and its layout tears the moment anything
    /// redraws.
    ///
    /// Measured in SwiftTerm 1.15.0, the chain already exists and is complete:
    /// `view.font = …` → `resetFont()` → `resize(cols:rows:)` →
    /// `sizeChanged(source: Terminal)` → `LocalProcessTerminalView.sizeChanged`
    /// → `PseudoTerminalHelpers.setWinSize` → `ioctl(TIOCSWINSZ)`, which is what
    /// makes the kernel signal the foreground process group. `lineSpacing` goes
    /// through the same `resetFont()`.
    ///
    /// Two conditions guard it inside SwiftTerm, and both are worth knowing:
    /// `resetFont` only resizes when the view has a non-zero frame, and
    /// `sizeChanged` only touches the PTY while the process is running. Every
    /// tab is mounted at full size at all times (see `ContentView`), so a
    /// background tab satisfies the first — which is the whole reason the
    /// unselected terminals are kept in the hierarchy rather than torn down.
    ///
    /// `syncWindowSize` is belt and braces for the case those guards skip: a
    /// change that produces the same column count raises no `sizeChanged`, and
    /// re-asserting a size that has not moved costs one `ioctl` and no signal.
    func apply(_ settings: TerminalSettings) {
        let font = MonospacedFonts.font(named: settings.font.name, size: settings.font.size)
        if view.font != font {
            view.font = font
        }
        if view.lineSpacing != settings.font.lineSpacing {
            view.lineSpacing = settings.font.lineSpacing
        }

        view.installColors(settings.appearance.ansi.map(\.swiftTerm))
        view.nativeForegroundColor = settings.appearance.foreground.nsColor
        view.nativeBackgroundColor = settings.appearance.background.nsColor
        view.caretColor = settings.appearance.cursorColor.nsColor

        view.getTerminal().setCursorStyle(
            settings.cursor.shape.swiftTermStyle(blinking: settings.cursor.blinks)
        )
        view.changeScrollback(settings.behaviour.scrollbackLines)
        // DECAWM, fed to the emulator rather than set through a property:
        // SwiftTerm keeps `setWraparound` internal, and the escape sequence is
        // the interface every other program uses for this anyway. Fed to the
        // *terminal*, not written to the PTY — the child must not receive it as
        // input.
        view.getTerminal().feed(text: settings.behaviour.wrapLines ? "\u{1b}[?7h" : "\u{1b}[?7l")

        // Translucency.
        //
        // The alpha goes on the **background colour**, never on the view: a
        // faded `alphaValue` would take the text with it, and text is
        // unreadable long before a background is interestingly transparent.
        //
        // Both places have to be set, and this is the part that cost an
        // afternoon. `nativeBackgroundColor`'s setter only forwards the colour
        // to the emulator; the layer's own `backgroundColor` is written in
        // SwiftTerm's `setupOptions()`, which runs on layout and not on
        // assignment. Setting only the property leaves an opaque layer filling
        // the view behind everything drawn on it — the terminal composites
        // correctly onto a backdrop nobody can see.
        // When translucent, the terminal paints **no** background of its own
        // and `ContentView` paints the only one.
        //
        // Both painting it composites the same colour twice, and two layers at
        // 85% come out at 97.75% while the padding and the seam beside the
        // panel — which have one layer — stay at 85%. That difference is
        // invisible at 99% and obvious below 95%, which is exactly how it was
        // reported.
        //
        // The alpha is set to zero rather than using `NSColor.clear`, because
        // SwiftTerm forwards this colour to the emulator as *the* background
        // colour and uses it to reason about contrast. `.clear` would tell it
        // the background is black, which is wrong for a light theme; a
        // zero-alpha theme colour keeps the right answer to "what colour is
        // behind this text" while painting nothing.
        let background = settings.window.isTranslucent
            ? settings.appearance.background.nsColor.withAlphaComponent(0)
            : settings.appearance.background.nsColor

        view.nativeBackgroundColor = background
        view.wantsLayer = true
        view.layer?.backgroundColor = background.cgColor
        view.layer?.isOpaque = !settings.window.isTranslucent

        releaseScrollerGutter()
        syncWindowSize()
        view.needsDisplay = true
    }

    /// Give the terminal back the strip SwiftTerm reserves for its scroller.
    ///
    /// `reservedScrollerWidth` is `NSScroller.scrollerWidth(…)` unless the
    /// scroller is hidden, and it is subtracted from the width the grid is laid
    /// out in — so roughly fifteen points down the right-hand edge belong to a
    /// scrollbar that, in `.overlay` style, is not drawn. That was invisible
    /// while it sat against the window's edge. Put a sidebar beside it and it
    /// reads as a seam between the two, which is what it was reported as.
    ///
    /// Hiding the scroller is what releases the width; there is no public
    /// setter, so the subview is found by type. Nothing is lost with it: the
    /// scroller is auto-hiding, the wheel and the trackpad scroll through a
    /// different path entirely, and fifteen points of dead column beside a
    /// panel is worse than a scrollbar that was never on screen.
    private func releaseScrollerGutter() {
        for subview in view.subviews {
            guard let scroller = subview as? NSScroller, !scroller.isHidden else { continue }
            scroller.isHidden = true
            // The reserved width is read during layout, so the grid only widens
            // on the next pass. SwiftUI lays this view out constantly; asking
            // explicitly means the change lands on this frame rather than the
            // next time something else happens to move.
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Re-assert the current grid size on the PTY.
    ///
    /// Idempotent and cheap. Sending a size the child already has raises no
    /// `SIGWINCH`, so this cannot cause a spurious redraw in the program.
    func syncWindowSize() {
        guard !hasExited, view.process.running else { return }
        var size = view.getWindowSize()
        _ = PseudoTerminalHelpers.setWinSize(
            masterPtyDescriptor: view.process.childfd,
            windowSize: &size
        )
    }

    /// Write bytes to the PTY as though they had been typed.
    ///
    /// Input, not output: this goes to the program, and must never be fed to
    /// the emulator — feeding it would print the escape sequence into the grid
    /// instead of sending it. See `TerminalKeys`.
    func send(_ bytes: [UInt8]) {
        guard !hasExited, view.process.running else { return }
        view.process.send(data: bytes[...])
    }

    // MARK: - Working directory and foreground process

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        poller = timer
    }

    /// Read both facts now, off-schedule.
    ///
    /// Called when a tab becomes the selected one: the tab you are looking at
    /// is the one whose name being a second stale is worth a syscall to avoid.
    func pollNow() {
        poll()
    }

    private func poll() {
        guard !hasExited, view.process.running else { return }
        if let path = ProcessDirectory.current(of: view.process.shellPid) {
            setDirectory(path)
        }
        setForeground(ForegroundProcess.name(ofPTY: view.process.childfd))
    }

    private func setDirectory(_ path: String) {
        guard path != currentDirectory else { return }
        currentDirectory = path
        onDirectoryChange?(path)
    }

    /// An unreadable foreground is published as `nil` rather than dropped.
    ///
    /// The difference matters at exactly one moment: a program that ends while
    /// the PTY is being torn down. Keeping the last value there would leave a
    /// tab called `btop` after btop is gone, which is the stale-name failure
    /// this source was chosen to avoid.
    private func setForeground(_ name: String?) {
        guard name != foregroundProcess else { return }
        foregroundProcess = name
        onForegroundChange?(name)
    }

    // MARK: - Ending

    /// Kill the child and stop polling. Idempotent.
    ///
    /// Three signals, because one is not enough and the reason is not obvious.
    /// SwiftTerm's `terminate()` closes the PTY and sends `SIGTERM` — and an
    /// **interactive shell ignores `SIGTERM`**. So closing a tab would remove
    /// it from the window and leave its shell running forever, invisible,
    /// accumulating one orphan per closed tab.
    ///
    /// `SIGHUP` is the signal that actually means "your terminal went away",
    /// and it is the one a shell honours. `SIGKILL` after a grace period is the
    /// backstop for a child that has blocked even that.
    func terminate() {
        poller?.cancel()
        poller = nil
        guard !hasExited else { return }

        let pid = view.process.shellPid
        if view.process.running {
            view.process.terminate()
        }
        guard pid > 0 else { return }

        kill(pid, SIGHUP)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.killGrace) {
            // `kill(pid, 0)` only probes; it does not signal. A pid that has
            // been reaped answers ESRCH and we do nothing.
            guard kill(pid, 0) == 0 else { return }
            kill(pid, SIGKILL)
        }
    }

    /// How long a shell gets to notice its terminal is gone before it is killed
    /// outright. Long enough for a `zsh` to run its exit hooks, short enough
    /// that the pid cannot plausibly have been recycled.
    private static let killGrace: TimeInterval = 2

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm has already told the PTY. Nothing here needs the size, and
        // the daemon has no message that carries one.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7, when a configured shell sends it. Faster than the poller and
        // never the only source — see `ProcessDirectory`.
        guard let directory, !directory.isEmpty else { return }
        // OSC 7 carries a file URL; a bare path is tolerated because some
        // shells send one.
        let path = URL(string: directory)?.path ?? directory
        setDirectory(path.isEmpty ? directory : path)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        hasExited = true
        poller?.cancel()
        poller = nil
        onExit?(exitCode)
    }
}
