// The window's state: the tabs, which one is selected, and the daemon link.
//
// Two rules shape this file, and both come from ADR-002.
//
// **The daemon is optional.** Every tab operation talks to the daemon on its
// way past, and not one of them checks whether the daemon is there first.
// `DaemonClient.send` drops what it cannot deliver and reconciles on reconnect,
// so opening a tab with the daemon down is the same code path as opening one
// with it up. The sidebar loses data; the terminal loses nothing.
//
// **The app computes nothing about sessions.** What the daemon says is stored
// as received. There is no derived state here, no percentage, no inferred
// status — the app is a renderer of the daemon's world, not a second copy of it.

import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var tabs: [TabModel] = []
    @Published var selectedTabID: String?

    /// Sessions the daemon knows about, keyed by `session_id`.
    ///
    /// Not rendered in this build — the sidebar shows tabs, and the cards come
    /// later. It is populated anyway because that is what proves the socket
    /// works end to end, and because dropping the messages would leave the
    /// reconnect path untested until the day it matters.
    @Published private(set) var sessions: [String: SessionRegistered] = [:]

    /// Pending permission requests, keyed by `hitl_id`. Same reasoning.
    @Published private(set) var pendingHitl: [String: HitlPending] = [:]

    let preferences: Preferences
    let daemon = DaemonClient()

    private var cancellables = Set<AnyCancellable>()

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences

        daemon.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.apply(message) }
        }
        daemon.liveTabs = { [weak self] in
            MainActor.assumeIsolated {
                self?.tabs.map { (tabID: $0.tabID, cwd: $0.currentDirectory) } ?? []
            }
        }
        daemon.start()

        // Re-publishing the client's own changes: `daemon` is a nested
        // ObservableObject, and SwiftUI does not observe through one.
        daemon.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // The font is shared by every terminal, so the views are updated here
        // rather than each one watching preferences.
        preferences.$fontSize
            .combineLatest(preferences.$fontName)
            .dropFirst()
            .sink { [weak self] _, _ in
                MainActor.assumeIsolated { self?.applyFontToAllTabs() }
            }
            .store(in: &cancellables)
    }

    var selectedTab: TabModel? {
        guard let selectedTabID else { return nil }
        return tabs.first { $0.tabID == selectedTabID }
    }

    // MARK: - Tabs

    /// Create a tab, announce it, then spawn the shell.
    ///
    /// The order is the contract, not a preference: ADR-003 requires
    /// `register_tab` to reach the daemon **before** the child exists, so the
    /// daemon can never receive a hook naming a tab it has not heard of.
    @discardableResult
    func newTab(directory: String? = nil) -> TabModel {
        let cwd = directory ?? defaultDirectory()
        let tab = TabModel(font: preferences.terminalFont, directory: cwd)

        daemon.send(.registerTab(tabID: tab.tabID, cwd: cwd))
        tab.start(socketPath: Discovery.socketPath())

        tabs.append(tab)
        selectedTabID = tab.tabID
        return tab
    }

    /// Close a tab: kill the shell, tell the daemon, pick a neighbour.
    ///
    /// `close_tab` is the only way the daemon can learn a tab is gone —
    /// everything else would be inferring it from silence, which the protocol
    /// refuses on purpose.
    func closeTab(_ tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.tabID == tabID }) else { return }
        let tab = tabs.remove(at: index)
        tab.terminate()
        daemon.send(.closeTab(tabID: tab.tabID))

        guard selectedTabID == tabID else { return }
        // The neighbour on the left, or the new last tab. Browsers pick the
        // right-hand neighbour; a terminal's tabs are a work queue, and going
        // back to what you were doing before beats going forward.
        selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].tabID
    }

    func closeSelectedTab() {
        guard let selectedTabID else { return }
        closeTab(selectedTabID)
    }

    /// A new tab opens where the current one is, so `⌘T` in a repo stays in it.
    private func defaultDirectory() -> String {
        if let current = selectedTab?.currentDirectory { return current }
        return NSHomeDirectory()
    }

    // MARK: - Selection

    func selectNextTab() { moveSelection(by: 1) }
    func selectPreviousTab() { moveSelection(by: -1) }

    private func moveSelection(by offset: Int) {
        guard !tabs.isEmpty else { return }
        guard let current = tabs.firstIndex(where: { $0.tabID == selectedTabID }) else {
            selectedTabID = tabs.first?.tabID
            return
        }
        // Wrapping, because with four agents open the tab you want next is as
        // often behind you as ahead.
        let count = tabs.count
        let next = ((current + offset) % count + count) % count
        selectedTabID = tabs[next].tabID
    }

    /// `⌘1`…`⌘8` select that tab; `⌘9` selects the last, whatever its number.
    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        if number >= 9 {
            selectedTabID = tabs.last?.tabID
            return
        }
        let index = number - 1
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].tabID
    }

    // MARK: - Appearance

    func toggleSidebar() {
        preferences.sidebarVisible.toggle()
    }

    private func applyFontToAllTabs() {
        let font = preferences.terminalFont
        for tab in tabs {
            tab.session.view.font = font
        }
    }

    // MARK: - Daemon messages

    /// Every daemon message is an idempotent upsert.
    ///
    /// `request_snapshot` is answered by replaying ordinary messages with no
    /// envelope and no end marker, so a `session_registered` for a session we
    /// already have is normal traffic on every reconnect — not a duplicate to
    /// detect. Handling it as an upsert is what makes the reconnect path need
    /// no code of its own.
    private func apply(_ message: DaemonMessage) {
        switch message {
        case .sessionRegistered(let session):
            sessions[session.sessionID] = session

        case .sessionUpdated(let patch):
            guard let existing = sessions[patch.sessionID] else {
                // A patch for a session we have never seen. Dropped rather than
                // synthesized: a sparse patch cannot describe a whole session,
                // and inventing the missing fields would put values on screen
                // the daemon never sent.
                return
            }
            sessions[patch.sessionID] = SessionRegistered(
                sessionID: existing.sessionID,
                tabID: patch.tabID.applied(to: existing.tabID),
                agent: existing.agent,
                cwd: patch.cwd.applied(to: existing.cwd),
                title: patch.title.applied(to: existing.title),
                model: patch.model.applied(to: existing.model),
                startedAt: existing.startedAt
            )

        case .hitlPending(let request):
            pendingHitl[request.hitlID] = request

        case .hitlResolved(let resolved):
            // The card clears on this message and on no other signal — including
            // our own click, which is a request and not a fact (ADR-004).
            pendingHitl.removeValue(forKey: resolved.hitlID)

        case .sessionEnded(let ended):
            sessions.removeValue(forKey: ended.sessionID)
            pendingHitl = pendingHitl.filter { $0.value.sessionID != ended.sessionID }
        }
    }

    // MARK: - Shutdown

    /// Close every tab properly on quit.
    ///
    /// Without this the daemon learns nothing and each session sits in the
    /// registry until it times out for inactivity — reported as
    /// `process_exited`, which is true but late and less specific than
    /// `tab_closed`.
    func shutdown() {
        for tab in tabs {
            tab.terminate()
            daemon.send(.closeTab(tabID: tab.tabID))
        }
        tabs.removeAll()
        selectedTabID = nil
        // Give the writes a moment to reach the socket before the process goes
        // away. They are a few hundred bytes on a local socket; this is a
        // flush, not a wait.
        Thread.sleep(forTimeInterval: 0.05)
        daemon.stop()
    }
}
