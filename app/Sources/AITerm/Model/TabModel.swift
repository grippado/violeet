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
    @Published private(set) var terminalTitle: String?

    /// The shell exited but the tab is still on screen. The user closes it; the
    /// app does not close it for them, because the scrollback is often the
    /// reason they want to look.
    @Published private(set) var hasExited = false

    var id: String { tabID }

    init(font: NSFont, directory: String) {
        self.tabID = UUID().uuidString.lowercased()
        self.currentDirectory = directory
        self.session = TerminalSession(tabID: tabID, font: font)

        session.onDirectoryChange = { [weak self] path in
            self?.currentDirectory = path
        }
        session.onTitleChange = { [weak self] title in
            self?.terminalTitle = title.isEmpty ? nil : title
        }
        session.onExit = { [weak self] _ in
            self?.hasExited = true
        }
    }

    func start(socketPath: String) {
        session.start(inDirectory: currentDirectory, socketPath: socketPath)
    }

    func terminate() {
        session.terminate()
    }

    /// What the sidebar shows. The directory, not the title: with several agents
    /// running, *where* they are is the thing that tells them apart, and an
    /// agent's OSC title is usually the name of the tool it is running.
    var displayName: String {
        ProcessDirectory.abbreviated(currentDirectory)
    }

    /// The trailing path component, for the compact row.
    var shortName: String {
        let name = (currentDirectory as NSString).lastPathComponent
        return name.isEmpty ? currentDirectory : name
    }
}
