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
    /// Every daemon message is an idempotent upsert into this table, and the
    /// sidebar renders it directly. The app derives nothing here beyond
    /// presentation: the four token numbers, the state and the model all come
    /// off the wire as sent.
    @Published private(set) var sessions: [String: SessionCard] = [:]

    /// Cards in the order the sidebar shows them: waiting-for-you first, then
    /// by how recently the session did something.
    ///
    /// Sorted here rather than in the view so the ordering is one decision with
    /// one place to change it — and so a card cannot jump because two views
    /// disagreed about the rank.
    /// Sessions running in a tab of this window.
    var localSessions: [SessionCard] {
        orderedSessions.filter { $0.tabID != nil }
    }

    /// Sessions aiterm did not launch — an agent in iTerm, or another window.
    ///
    /// Real sessions, and shown (ADR-003), but separated: they cannot be
    /// revealed in a tab, and mixing them in means the ones you opened here
    /// compete for space with ones you cannot act on from here.
    ///
    /// A waiting-for-you card is the exception and is promoted out of this
    /// list by `hasWaitingElsewhere` — a blocked agent is worth interrupting
    /// for wherever it lives.
    var elsewhereSessions: [SessionCard] {
        orderedSessions.filter { $0.tabID == nil }
    }

    /// True when something outside aiterm is blocked on the user.
    ///
    /// Drives the section header's own attention state, so a collapsed section
    /// cannot hide the one thing this product exists to surface.
    var hasWaitingElsewhere: Bool {
        elsewhereSessions.contains { $0.lifecycle == .waitingForYou }
    }

    /// Hand keyboard focus back to the terminal.
    ///
    /// This is the settings panel's central requirement, not a nicety. A panel
    /// you cannot touch without having to click back into the terminal is a
    /// panel that interrupts the thing the window is for — and the interruption
    /// is silent, because a terminal that has lost first responder looks
    /// identical to one that has it right up until you type.
    ///
    /// Asynchronous on purpose. A control that is finishing its own
    /// first-responder change would undo a synchronous call here: AppKit
    /// resolves the click after the SwiftUI action runs, so setting the
    /// responder back inside the action loses the race.
    func focusTerminal() {
        guard let view = selectedTab?.session.view else { return }
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }

    /// Push the current settings onto every live terminal.
    ///
    /// Every tab, not only the visible one: a background tab whose font is
    /// stale is a tab that reflows the moment you switch to it, and the agent
    /// inside it has been composing for the wrong width the whole time.
    func applyTerminalSettings() {
        let settings = preferences.terminal
        for tab in tabs {
            tab.session.apply(settings)
        }
    }

    /// The title to render for a session, made unique across the window.
    ///
    /// The rule lives in `SessionCard.uniqueTitles(for:)`; this only supplies
    /// the window's set of cards.
    func displayTitle(for card: SessionCard) -> String {
        SessionCard.uniqueTitles(for: Array(sessions.values))[card.sessionID] ?? card.baseTitle
    }

    /// The distinct terminal applications the hidden sessions are running in,
    /// in the order the cards appear.
    ///
    /// Sessions whose origin the daemon could not resolve contribute nothing —
    /// the summary lists the places we know, and never an "unknown" that would
    /// read as a place of its own.
    var elsewhereApps: [String] {
        var seen = Set<String>()
        return elsewhereSessions.compactMap { card in
            guard let app = card.originApp, !app.isEmpty else { return nil }
            return seen.insert(app).inserted ? app : nil
        }
    }

    var orderedSessions: [SessionCard] {
        sessions.values.sorted { a, b in
            if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
            let lhs = a.lastEventAt ?? a.startedAt
            let rhs = b.lastEventAt ?? b.startedAt
            if lhs != rhs { return lhs > rhs }
            // Total order, so equal timestamps cannot make the list reshuffle
            // on every update.
            return a.sessionID < b.sessionID
        }
    }

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

        // Everything visual is one publisher now: a change anywhere in the
        // settings value is pushed to every live terminal, including the fonts
        // the ⌘+ / ⌘- shortcuts change.
        preferences.$terminal
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTerminalSettings() }
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
        // Before the shell is spawned: the PTY takes its initial window size
        // from the view's cell dimensions, and a tab that started at the
        // default font and was resized afterwards would hand its child one
        // size and then immediately a different one.
        tab.session.apply(preferences.terminal)
        tab.start(
            socketPath: Discovery.socketPath(),
            shell: preferences.terminal.behaviour.shellOverride
        )

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

    /// Show or hide the right sidebar, and give the keyboard back either way.
    ///
    /// The shortcut is the one path into the panel that starts from the
    /// terminal having focus, so it is also the one most likely to lose it.
    func toggleInspector() {
        preferences.inspectorVisible.toggle()
        focusTerminal()
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
            // Idempotent upsert: a replay on reconnect is normal traffic, not a
            // duplicate. An existing card keeps the telemetry it has
            // accumulated, because `session_registered` carries none of it and
            // replacing the card wholesale would blank the numbers on every
            // reconnect.
            if var existing = sessions[session.sessionID] {
                existing.tabID = session.tabID
                existing.agent = session.agent
                existing.cwd = session.cwd ?? existing.cwd
                existing.title = session.title ?? existing.title
                existing.model = session.model ?? existing.model
                sessions[session.sessionID] = existing
            } else {
                sessions[session.sessionID] = SessionCard(registered: session)
            }

        case .sessionUpdated(let patch):
            guard var card = sessions[patch.sessionID] else {
                // A patch for a session we have never seen. Dropped rather than
                // synthesized: a sparse patch cannot describe a whole session,
                // and inventing the missing fields would put values on screen
                // the daemon never sent.
                return
            }
            card.apply(patch)
            sessions[patch.sessionID] = card

        case .hitlPending(let request):
            pendingHitl[request.hitlID] = request
            attachPendingHitl()

        case .hitlResolved(let resolved):
            // The card clears on this message and on no other signal — including
            // our own click, which is a request and not a fact (ADR-004).
            pendingHitl.removeValue(forKey: resolved.hitlID)
            attachPendingHitl()

        case .sessionEnded(let ended):
            sessions.removeValue(forKey: ended.sessionID)
            pendingHitl = pendingHitl.filter { $0.value.sessionID != ended.sessionID }
            attachPendingHitl()
        }
    }

    /// Point each card at its pending request, if it has one.
    ///
    /// Recomputed wholesale rather than patched incrementally: the table is a
    /// handful of entries, and a card left holding a request that was resolved
    /// would keep pulsing for a decision nobody can make any more.
    private func attachPendingHitl() {
        let bySession = Dictionary(
            pendingHitl.values.map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (id, var card) in sessions where card.pendingHitl != bySession[id] {
            card.pendingHitl = bySession[id]
            sessions[id] = card
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
