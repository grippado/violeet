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
    @Published var selectedTabID: String? {
        didSet {
            guard selectedTabID != oldValue else { return }
            // The tab you are looking at is the one whose name being a second
            // stale is worth a syscall to avoid.
            selectedTab?.session.pollNow()
        }
    }

    /// The selected tab's name, for the window's own title bar.
    ///
    /// This window has no tab bar — the sidebar is the tab list — so the title
    /// bar is where a tab's name is stated at full size. It follows the same
    /// chain as everything else, which is the point: one rule, every surface.
    var windowTitle: String {
        guard let tab = selectedTab else { return "aiterm" }
        if let card = session(ofTab: tab.tabID) {
            return displayTitle(for: card)
        }
        return name(for: tab).text
    }

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
        let unique = SessionCard.uniqueTitles(for: Array(sessions.values)) { self.name(for: $0).text }
        return unique[card.sessionID] ?? name(for: card).text
    }

    // MARK: - Naming

    /// The resolved name of a session's card, with every level of the chain
    /// filled in.
    ///
    /// This is where the two halves meet: levels 3 and 1 come off the socket,
    /// levels 2 and 4 come from the tab — and only for a card that *has* a tab.
    /// A session running in iTerm has no PTY we can read, so it is named from
    /// what the daemon knows and nothing else, which is the honest answer.
    func name(for card: SessionCard) -> ResolvedName {
        guard let tabID = card.tabID, let tab = tabsByID[tabID] else {
            return SessionName.resolve(
                NameInputs(
                    agentTitle: card.title,
                    agentTitleSource: card.titleSource,
                    cwd: card.cwd
                )
            )
        }
        var inputs = tab.nameInputs(agent: card)
        // The daemon's working directory wins over the tab's when it has one:
        // the agent's own cwd is what the card is about, and an agent can be
        // running in a directory the shell has since left.
        inputs.cwd = card.cwd ?? inputs.cwd
        return SessionName.resolve(inputs)
    }

    /// The resolved name of a tab, whether or not a session owns it.
    func name(for tab: TabModel) -> ResolvedName {
        SessionName.resolve(tab.nameInputs(agent: session(ofTab: tab.tabID)))
    }

    /// The card running in a tab, if one is.
    func session(ofTab tabID: String) -> SessionCard? {
        sessions.values.first { $0.tabID == tabID }
    }

    private var tabsByID: [String: TabModel] {
        Dictionary(tabs.map { ($0.tabID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Rename a tab, and mean it: nothing automatic overwrites this until the
    /// user asks for automatic naming back.
    ///
    /// Where the name is *kept* depends on what the tab is. A tab with an agent
    /// session hands the name to the daemon, which persists it and is the only
    /// copy — a second copy here is how the two come to disagree. A tab with no
    /// session keeps it locally, because the daemon has nowhere to put a name
    /// for something it does not know exists.
    func rename(tab: TabModel, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let card = session(ofTab: tab.tabID) {
            tab.setManualName(nil)
            rename(session: card.sessionID, to: trimmed)
        } else {
            tab.setManualName(trimmed)
        }
        focusTerminal()
    }

    func rename(session sessionID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Optimistic, and only optimistic: the card is repainted from the
        // daemon's echo like every other field. Writing it here too is what
        // keeps the field from flickering back to the old name for the length
        // of a round trip.
        if var card = sessions[sessionID] {
            card.title = trimmed
            card.titleSource = "user"
            sessions[sessionID] = card
        }
        // Held until the daemon confirms. A rename typed while the daemon is
        // down would otherwise be dropped on the floor: `DaemonClient` discards
        // what it cannot deliver, which is right for telemetry and wrong for
        // something the user typed.
        pendingNaming[sessionID] = .rename(trimmed)
        daemon.send(.renameSession(sessionID: sessionID, title: trimmed))
        focusTerminal()
    }

    /// Give a tab back to automatic naming.
    ///
    /// The counterpart to renaming, and not optional: without it the user is
    /// stuck with whatever they typed once, and the only way out is closing the
    /// tab.
    func releaseName(tab: TabModel) {
        tab.setManualName(nil)
        if let card = session(ofTab: tab.tabID) {
            releaseName(session: card.sessionID)
        }
        focusTerminal()
    }

    func releaseName(session sessionID: String) {
        if var card = sessions[sessionID] {
            // Cleared rather than guessed: what the session falls back to is
            // the daemon's to decide, and it is one message away from saying
            // so. Guessing here would put a name on screen the daemon never
            // sent, which is the one thing this app does not do.
            card.title = nil
            card.titleSource = nil
            sessions[sessionID] = card
        }
        pendingNaming[sessionID] = .release
        daemon.send(.releaseSessionTitle(sessionID: sessionID))
        focusTerminal()
    }

    /// A rename the daemon has not confirmed yet, per session.
    ///
    /// Cleared when the echo arrives, replayed on reconnect. It is the only
    /// place the app holds a name the daemon does not, and it holds it for
    /// seconds.
    enum PendingNaming: Equatable {
        case rename(String)
        case release
    }

    private var pendingNaming: [String: PendingNaming] = [:]

    /// Re-send what the daemon may not have heard.
    ///
    /// Called after a snapshot request, which is the point at which the app and
    /// the daemon are otherwise in agreement — so anything still pending here
    /// is something the daemon genuinely missed.
    private func replayPendingNaming() {
        for (sessionID, pending) in pendingNaming {
            switch pending {
            case .rename(let title):
                daemon.send(.renameSession(sessionID: sessionID, title: title))
            case .release:
                daemon.send(.releaseSessionTitle(sessionID: sessionID))
            }
        }
    }

    /// A tab renamed before an agent started in it hands its name over.
    ///
    /// Without this the rename would be silently demoted the moment the session
    /// appeared: the card is named from the daemon, and the daemon was never
    /// told.
    private func promoteTabName(to card: SessionCard) {
        guard let tabID = card.tabID,
              let tab = tabs.first(where: { $0.tabID == tabID }),
              let manual = tab.manualName
        else { return }
        tab.setManualName(nil)
        rename(session: card.sessionID, to: manual)
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
        daemon.onReconcile = { [weak self] in
            MainActor.assumeIsolated { self?.replayPendingNaming() }
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

        installKeyMonitor()
    }

    // MARK: - Keyboard

    /// The local key monitor for Shift+Return. Held so it can be removed.
    private var keyMonitor: Any?

    /// Start translating Shift+Return into the sequence agents understand.
    ///
    /// A monitor rather than a view subclass, for the reason recorded in
    /// `TerminalKeys`. Two guards, and both matter:
    ///
    ///  - the event has to *be* the combination, or every keystroke in the app
    ///    would take this path
    ///  - the terminal has to be first responder, or Shift+Return typed into
    ///    the rename field or the hex field would be swallowed and written to
    ///    a PTY the user was not looking at
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self,
                      let bytes = TerminalKeys.bytes(for: event),
                      let tab = self.selectedTab,
                      let window = tab.session.view.window,
                      window.isKeyWindow,
                      window.firstResponder === tab.session.view
                else { return event }

                tab.session.send(bytes)
                // Swallowed: returning the event as well would send the
                // sequence and then let SwiftTerm send a plain `\r` after it,
                // which submits — the bug, with an extra newline in front.
                return nil
            }
        }
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
        // `exit` closes the tab, the way it does in every other terminal. The
        // hop to the main actor is what lets the tab call us at all: the exit
        // arrives on SwiftTerm's delegate, and `closeTab` touches `tabs` and
        // `selectedTabID`, which are this actor's.
        //
        // `weak tab` and not a captured id, because a tab that has already been
        // removed must not be resurrected by its own dying callback.
        tab.onShellExit = { [weak self, weak tab] in
            guard let tab else { return }
            Task { @MainActor in self?.closeTab(tab.tabID) }
        }
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

    /// Show or hide the sessions sidebar, and give the keyboard back.
    ///
    /// The same reason as `toggleInspector`: the shortcut is pressed while the
    /// terminal has focus, and the layout change is exactly the moment AppKit
    /// might decide focus belongs somewhere else.
    func toggleSidebar() {
        preferences.sidebarVisible.toggle()
        focusTerminal()
    }

    /// Show or hide the right sidebar, and give the keyboard back either way.
    ///
    /// The shortcut is the one path into the panel that starts from the
    /// terminal having focus, so it is also the one most likely to lose it.
    func toggleInspector() {
        preferences.inspectorVisible.toggle()
        focusTerminal()
    }

    /// Show a specific panel, or hide the inspector if it is already showing it.
    ///
    /// A plain toggle was fine with one panel and is a bug with two: ⌘, means
    /// "Settings", and with the Files panel open a toggle would close the
    /// inspector instead of switching to what the user asked for.
    func toggleInspector(showing panel: InspectorPanel) {
        if preferences.inspectorVisible && preferences.inspectorPanel == panel {
            preferences.inspectorVisible = false
        } else {
            preferences.inspectorPanel = panel
            preferences.inspectorVisible = true
        }
        focusTerminal()
    }

    /// Point the Files panel at a session.
    ///
    /// Harmless while the panel is closed, which is what lets the sidebar's tap
    /// gesture do this unconditionally instead of asking what is on screen.
    func inspect(session id: String) {
        inspectedSessionID = id
    }

    // MARK: - What sessions wrote

    /// The files each session has written, keyed by session id.
    ///
    /// Held beside `sessions` rather than inside the card on purpose. The card
    /// is `Equatable` and compared in bulk on every patch — `attachPendingHitl`
    /// and `uniqueTitles` both walk the whole table — and a session that
    /// rewrote a monorepo would make each of those comparisons walk hundreds of
    /// paths for a list no card ever renders.
    @Published private(set) var sessionFiles: [String: SessionFileList] = [:]

    /// Which session the Files panel is showing.
    ///
    /// A UI selection and not a fact about the world, which is why it lives
    /// here and not on a card: the daemon has no opinion about what you are
    /// looking at.
    @Published var inspectedSessionID: String?

    /// The session the Files panel should show: the one clicked, or the
    /// selected tab's, or the first in the list. Falling back rather than
    /// showing nothing means opening the panel is never a dead end.
    var inspectedSession: SessionCard? {
        if let id = inspectedSessionID, let card = sessions[id] { return card }
        if let tabID = selectedTabID,
           let card = orderedSessions.first(where: { $0.tabID == tabID }) {
            return card
        }
        return orderedSessions.first
    }

    /// Fold a patch's file fields into the list we hold for that session.
    ///
    /// Each field moves on its own, because the patch is sparse: the daemon
    /// re-sends the list only when it changes, while the two flags can change
    /// without it — a session becomes non-partial the moment a read catches up,
    /// with the same files in hand.
    private func applyFiles(_ patch: SessionUpdated) {
        guard patch.files != .unchanged
            || patch.filesPartial != .unchanged
            || patch.filesTruncated != .unchanged
        else { return }

        var list = sessionFiles[patch.sessionID] ?? SessionFileList()
        // `.set(nil)` means the daemon explicitly knows nothing, which is an
        // empty list rather than a stale one left on screen.
        list.files = patch.files.applied(to: list.files) ?? []
        list.isPartial = patch.filesPartial.applied(to: list.isPartial)
        list.isTruncated = patch.filesTruncated.applied(to: list.isTruncated)
        sessionFiles[patch.sessionID] = list
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
            if let card = sessions[session.sessionID] {
                promoteTabName(to: card)
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
            applyFiles(patch)
            // The daemon has spoken about this session's name, so whatever we
            // were holding for it has either landed or been superseded. Kept
            // narrow on purpose: a patch that carries no title says nothing
            // about a rename still in flight.
            if patch.titleSource != .unchanged || patch.title != .unchanged {
                pendingNaming.removeValue(forKey: patch.sessionID)
            }
            // A session can be bound to its tab after it registered, and the
            // rename typed before that has to follow it across.
            promoteTabName(to: card)

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
            // The tree goes with the card. Leaving it would keep a dead
            // session's files addressable by an id nothing else knows about.
            sessionFiles.removeValue(forKey: ended.sessionID)
            if inspectedSessionID == ended.sessionID { inspectedSessionID = nil }
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
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        // Give the writes a moment to reach the socket before the process goes
        // away. They are a few hundred bytes on a local socket; this is a
        // flush, not a wait.
        Thread.sleep(forTimeInterval: 0.05)
        daemon.stop()
    }
}
