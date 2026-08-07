// One tab: an id, a terminal, and the little the sidebar needs to draw a row.
//
// A class rather than a struct because it owns an NSView and a live process,
// and because SwiftUI rows observe it directly — a `@Published` on the tab
// redraws that row without touching the list.
//
// `tabID` is the identity the daemon knows (ADR-003): opaque, minted here,
// stable for the life of the tab, and never reused when a tab closes. That last
// property is why it is a fresh UUID and not an index into `tabs`.

import AppKit
import Foundation

final class TabModel: ObservableObject, Identifiable {
    let tabID: String
    let session: TerminalSession

    /// Where the shell is right now. Seeded with where it was spawned so a row
    /// is never blank, then kept current by the session's poller.
    @Published private(set) var currentDirectory: String

    /// The title the terminal asked for, via OSC 0/2. `nil` until it does.
    ///
    /// Never a name on its own. It is offered to `SessionName` alongside the
    /// process it was set under, and expires when that process goes — see
    /// `ForegroundProcess` for the three ways OSC breaks when trusted.
    @Published private(set) var terminalTitle: String?

    /// The foreground process at the moment the OSC title arrived.
    @Published private(set) var terminalTitleProcess: String?

    /// The program in the foreground of this tab's PTY. `nil` between the tab
    /// opening and the first poll, and whenever the kernel declines.
    @Published private(set) var foregroundProcess: String?

    /// A name the user typed for **this tab**, when no agent session owns it.
    ///
    /// A session-backed tab keeps its manual name in the daemon instead, which
    /// is the only copy: two copies of one name is how they come to disagree.
    /// `AppState` promotes this one and clears it the moment a session claims
    /// the tab.
    @Published private(set) var manualName: String?

    /// The shell exited. True for the moment between the child dying and the
    /// tab being taken off screen — `AppState` closes the tab through
    /// `onShellExit`, the way every other terminal does when you type `exit`.
    ///
    /// The flag outlives that moment only when nobody is listening on
    /// `onShellExit`, which is why the sidebar still knows how to draw a dead
    /// tab rather than assuming it can never see one.
    @Published private(set) var hasExited = false

    /// Called when this tab's shell dies, for whatever reason: `exit`, a signal,
    /// or the process crashing.
    ///
    /// A callback rather than the tab closing itself, because closing is not a
    /// tab's decision to make: `AppState.closeTab` is the only path that also
    /// tells the daemon (`close_tab`) and picks the neighbour to select. A tab
    /// removing itself from the list would leave the daemon believing in a tab
    /// that no longer exists.
    var onShellExit: (() -> Void)?

    var id: String { tabID }

    init(font: NSFont, directory: String) {
        self.tabID = UUID().uuidString.lowercased()
        self.currentDirectory = directory
        self.session = TerminalSession(tabID: tabID, font: font)

        session.onDirectoryChange = { [weak self] path in
            self?.currentDirectory = path
        }
        session.onTitleChange = { [weak self] title in
            guard let self else { return }
            self.terminalTitle = title.isEmpty ? nil : title
            // Stamped with the process that set it, here rather than in the
            // resolver: this is the only moment we know which program was
            // speaking.
            self.terminalTitleProcess = title.isEmpty ? nil : self.foregroundProcess
        }
        session.onForegroundChange = { [weak self] name in
            self?.foregroundProcess = name
        }
        session.onExit = { [weak self] _ in
            guard let self else { return }
            self.hasExited = true
            // A dead shell has no foreground program. Leaving the last one
            // would leave the tab named after something that is not running.
            self.foregroundProcess = nil
            self.onShellExit?()
        }
    }

    /// `shell` empty means the account's own shell, resolved at spawn.
    /// `command`, when given, is what the tab runs instead of a prompt.
    func start(socketPath: String, shell: String = "", command: String? = nil) {
        session.start(
            inDirectory: currentDirectory,
            socketPath: socketPath,
            shell: shell,
            command: command
        )
    }

    func terminate() {
        session.terminate()
    }

    // MARK: - Naming

    /// Everything that could name this tab, for `SessionName.resolve`.
    ///
    /// `agent` is the card the daemon holds for this tab, when there is one.
    /// Passed in rather than looked up, because a tab does not know about the
    /// session table and should not start to.
    func nameInputs(agent: SessionCard?) -> NameInputs {
        NameInputs(
            manualName: manualName,
            agentTitle: agent?.title,
            agentTitleSource: agent?.titleSource,
            foregroundProcess: foregroundProcess,
            oscTitle: terminalTitle,
            oscProcess: terminalTitleProcess,
            cwd: currentDirectory
        )
    }

    /// This tab's name when no session owns it. A tab with a session is named
    /// through its card — see `AppState.name(for:)`.
    var resolvedName: ResolvedName {
        SessionName.resolve(nameInputs(agent: nil))
    }

    /// Take the name over. Empty or blank clears it instead, which is the same
    /// as never having set one.
    func setManualName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        manualName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    // MARK: - Presentation

    /// What the sidebar shows for a tab with no session.
    var displayName: String { resolvedName.text }

    /// The working directory, with `$HOME` abbreviated. Shown under the name,
    /// never as the name.
    var pathLabel: String {
        ProcessDirectory.abbreviated(currentDirectory)
    }
}
