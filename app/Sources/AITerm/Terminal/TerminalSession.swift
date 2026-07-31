// One tab's terminal: a SwiftTerm view, the PTY behind it, and the environment
// the child was born with.
//
// ADR-001 hands the grid to SwiftTerm and asks the app to stay out of its way,
// so this class is thin on purpose. It owns three things SwiftTerm does not:
//
//  1. **The environment injection.** `AITERM_TAB_ID` is the whole tab/session
//     binding mechanism (ADR-003), and it has to be in the child's environment
//     from `exec` — there is no retrofitting it into a running shell.
//  2. **The working directory.** Polled from the kernel, because no stock macOS
//     shell reports it. See `ProcessDirectory`.
//  3. **Lifecycle callbacks** the tab model needs: title, cwd, and exit.

import AppKit
import Foundation
import SwiftTerm

final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    /// How often to ask the kernel where the shell is. Slow enough to be free,
    /// fast enough that the sidebar is not visibly stale after a `cd`.
    private static let cwdPollInterval: TimeInterval = 2

    let view: LocalProcessTerminalView

    /// The id exported as `AITERM_TAB_ID` and sent in `register_tab`. Opaque,
    /// minted by the app, stable for the life of the tab, never reused.
    let tabID: String

    private(set) var currentDirectory: String?
    private(set) var hasExited = false

    /// All three fire on the main queue.
    var onDirectoryChange: ((String) -> Void)?
    var onTitleChange: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?

    private var cwdPoller: DispatchSourceTimer?

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
    func start(inDirectory directory: String, socketPath: String) {
        let shell = Self.userShell()
        let name = (shell as NSString).lastPathComponent

        currentDirectory = directory
        view.startProcess(
            executable: shell,
            args: [],
            environment: Self.environment(tabID: tabID, socketPath: socketPath),
            // A leading dash in argv[0] is how Unix says "login shell". The
            // shell reads it off its own name; there is no flag for it here
            // because `args` would be argv[1...].
            execName: "-\(name)",
            currentDirectory: directory
        )
        startPollingDirectory()
    }

    /// The environment the child is born with.
    ///
    /// Built from the app's own environment rather than from SwiftTerm's
    /// defaults: those omit `PATH` entirely, which a login shell recovers but
    /// anything else launched in this tab would not.
    static func environment(tabID: String, socketPath: String) -> [String] {
        var variables = ProcessInfo.processInfo.environment

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

    // MARK: - Working directory

    private func startPollingDirectory() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.cwdPollInterval, repeating: Self.cwdPollInterval)
        timer.setEventHandler { [weak self] in self?.pollDirectory() }
        timer.resume()
        cwdPoller = timer
    }

    private func pollDirectory() {
        guard !hasExited, view.process.running else { return }
        guard let path = ProcessDirectory.current(of: view.process.shellPid) else { return }
        setDirectory(path)
    }

    private func setDirectory(_ path: String) {
        guard path != currentDirectory else { return }
        currentDirectory = path
        onDirectoryChange?(path)
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
        cwdPoller?.cancel()
        cwdPoller = nil
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
        cwdPoller?.cancel()
        cwdPoller = nil
        onExit?(exitCode)
    }
}
