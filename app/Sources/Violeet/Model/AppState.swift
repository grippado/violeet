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
            // Switching tabs is a change of subject, so the Files panel stops
            // being pinned to whatever card was clicked last. Without this the
            // panel keeps showing one session's files while the window is
            // plainly on something else — a list that outlives its subject
            // reads as a list *about* the new one.
            inspectedSessionID = nil
        }
    }

    /// The user picked this tab. Not the same as "the selection changed".
    ///
    /// # The bug this exists for
    ///
    /// Clearing the pinned session lived in `selectedTabID`'s `didSet`, and
    /// `didSet` does not fire when the value assigned equals the one already
    /// there. So: click a card under ELSEWHERE to pin its changes, then click
    /// the tab that was *already selected* — the assignment is a no-op, nothing
    /// clears, and the panel keeps showing a session's changes while the window
    /// is plainly on a shell. It only came right after visiting some other tab
    /// and coming back, which is what made it look like a redraw problem rather
    /// than a state one.
    ///
    /// The two are genuinely different events. "The selection changed" is a
    /// fact about a variable; "the user asked for this tab" is an intention,
    /// and it means *show me this tab* whether or not the variable moves. Every
    /// click surface goes through here; the internal assignments — opening,
    /// closing, cycling — always do change the value, so their `didSet` is
    /// enough.
    func select(tab tabID: String) {
        // Ordered so the panel cannot flicker through the wrong subject: the
        // pin comes off first, then the selection lands.
        inspectedSessionID = nil
        selectedTabID = tabID
    }

    /// The selected tab's name, for the window's own title bar.
    ///
    /// This window has no tab bar — the sidebar is the tab list — so the title
    /// bar is where a tab's name is stated at full size. It follows the same
    /// chain as everything else, which is the point: one rule, every surface.
    var windowTitle: String {
        guard let tab = selectedTab else { return "violeet" }
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

    /// Sessions violeet did not launch — an agent in iTerm, or another window.
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

    /// True when something outside violeet is blocked on the user.
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

    /// The themes on disk, and the live-reload loop over the one being edited.
    /// See `ThemeStore`.
    let themes: ThemeStore

    /// Puts the bundled daemon under launchd when nothing is answering. See
    /// `DaemonSupervisor` for why the app carries one at all.
    let supervisor = DaemonSupervisor()

    /// Whether Claude Code's hooks point at this daemon. A daemon with no hooks
    /// is running and blind, which looks identical to a daemon that is down
    /// until you notice the board never fills.
    @Published private(set) var hooksInstalled = true

    private var cancellables = Set<AnyCancellable>()

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        self.themes = ThemeStore(preferences: preferences)

        // Before the client connects, so the first attempt has something to
        // reach. It is a no-op when a daemon is already listening, which is
        // what makes it safe on every launch rather than only on first run.
        supervisor.ensureRunning()
        refreshHookStatus()

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

        // Same for the theme store, and for the same reason. Without it a parse
        // error from a save would sit in the store unread, because nothing in
        // the view tree is watching the object it lives on.
        themes.objectWillChange
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
    func newTab(directory: String? = nil, command: String? = nil) -> TabModel {
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
            shell: preferences.terminal.behaviour.shellOverride,
            command: command
        )

        tabs.append(tab)
        selectedTabID = tab.tabID
        return tab
    }

    /// Open a file the Files panel is showing, in a tab of its own.
    ///
    /// # Why a new tab and not the session's own
    ///
    /// The obvious version writes `:e <path>` into the tab the session is
    /// running in. That tab is almost always running the agent — it is a
    /// session card, that is what a session is — so the obvious version types a
    /// vim command into Claude Code's prompt. A file opened in a new tab cannot
    /// do that to anything.
    ///
    /// # Why the editor and not `open`
    ///
    /// `open` hands the file to whatever the Finder has bound to the extension,
    /// which for a `.swift` is an IDE and for a `.md` may be a note-taking app.
    /// This is a terminal; the editor the user configured is the one they meant.
    ///
    /// The tab closes when the editor exits, which is the same rule tabs
    /// already follow for a shell that exits.
    /// Clicking a row a second time goes back to the tab rather than opening a
    /// rival one. Two editors on one file is how a buffer gets overwritten by an
    /// older copy of itself, and a panel that answers every click with a new tab
    /// buries the terminal under editors within a morning — which is what
    /// happened before this check existed.
    func openInEditor(path: String, session sessionID: String?) {
        if let open = tabs.first(where: { $0.editing?.path == path }) {
            selectedTabID = open.tabID
            return
        }
        let directory = (path as NSString).deletingLastPathComponent
        let tab = newTab(
            directory: directory.isEmpty ? nil : directory,
            command: Self.editorCommand(forFileAt: path, settings: preferences.terminal.editor)
        )
        tab.editing = EditorTab(path: path, sessionID: sessionID)
        // `editing` is not `@Published` — it is set once, here, before anything
        // has drawn this tab. The sidebar reads it through `tabs`, which did
        // change, so the grouping lands on the same pass that adds the row.
        objectWillChange.send()
    }

    /// The editor tabs a session owns, in the order they were opened.
    func editorTabs(forSession sessionID: String) -> [TabModel] {
        tabs.filter { $0.editing?.sessionID == sessionID }
    }

    /// Whether a path is already open in some tab. Drives the mark in the Files
    /// panel, which is the other half of "this row opened that tab".
    func isOpenInEditor(path: String) -> Bool {
        tabs.contains { $0.editing?.path == path }
    }

    /// The shell command that opens one file for editing.
    ///
    /// `$VISUAL` then `$EDITOR` first, because a user who set either has said
    /// what they want. Neither is set on a stock macOS account, though, and
    /// falling straight to `vi` there would open the system vim on a machine
    /// with Neovim installed — the honoured convention producing the least
    /// wanted answer. So the fallback searches, and only reaches `vi` when it
    /// is genuinely all there is.
    ///
    /// The search runs in the shell rather than here because *this* process
    /// does not have the user's `PATH` — an app launched from Finder inherits
    /// almost none of it, which is why tabs spawn login shells at all. Asking
    /// `command -v` from inside that shell asks the environment that will run
    /// the editor, not the one that built the string.
    ///
    /// `exec` so the editor replaces the shell: no shell survives it, so
    /// quitting the editor exits the tab's process and the tab closes, which is
    /// the rule tabs already follow.
    /// # Showing the diff, not just marking it
    ///
    /// A vim-family editor opens on the first uncommitted hunk, in whichever of
    /// two shapes the user chose — see `EditorSettings.DiffMode`. All of it is
    /// gitsigns' and vim's; there is nothing here that draws.
    ///
    /// **Side by side** is one call, `diffthis`, which opens a vertical split
    /// against the index and lets vim's own diff mode place the cursor. Nothing
    /// below applies to it: no jump, because the split arrives on the first
    /// change, and no displays, because they would mark up one half of a window
    /// that is already showing both.
    ///
    /// **Inline** is the default and the rest of this comment. It is the one
    /// that cannot be too narrow to read — a split in an 80-column tab leaves
    /// 40 a side, and that is where a terminal usually is.
    ///
    /// # What a new file does
    ///
    /// Nothing, in either mode, and correctly. `attach_to_untracked` is `false`
    /// in gitsigns by default, so a file git has never seen gets no attach and
    /// `get_hunks` answers `nil` rather than an empty list — the poll below runs
    /// out its twenty tries and the file opens plain. That is the honest answer:
    /// the diff of a new file is the file, which is already on screen. The Files
    /// panel marks these with an `A` for the same reason.
    ///
    /// The sign column alone marks *that* a line changed and never what it
    /// replaced, so a rewritten line and a brand new one look identical and a
    /// deleted block leaves no trace at all. The three fill exactly those gaps:
    ///
    ///  · `toggle_deleted` puts the removed lines back, as virtual text. This is
    ///    the one that matters — without it a deletion is invisible, and the
    ///    file reads as if nothing was ever there.
    ///  · `toggle_word_diff` narrows a changed line to the words that changed,
    ///    which is the difference between "this line is different" and "this
    ///    identifier was renamed".
    ///  · `toggle_linehl` tints the changed lines themselves, so the shape of
    ///    the change survives scrolling past the sign column.
    ///
    /// Set with an explicit `true` rather than toggled. A toggle assumes it
    /// knows the current value, and would switch these *off* for a user whose
    /// config already turns them on.
    ///
    /// Only when there are hunks, so a clean file opens as a plain file rather
    /// than one dressed for a review that has nothing to show.
    ///
    /// **The jump goes first.** Switching a display on makes gitsigns recompute,
    /// and during that recompute the hunk list is empty — so a `nav_hunk` issued
    /// after the toggles finds nothing and says `No hunks`, on a file with six
    /// of them. Measured both orders on the same file: toggles first leaves the
    /// cursor on line 1, jump first reports `Hunk 1 of 6`.
    ///
    /// # Which diff this is
    ///
    /// The **git** diff, not the session's: it shows what has not been
    /// committed, so it is exactly right while reviewing an agent's work and
    /// empty once that work is committed. The session's own line ranges exist
    /// in `structuredPatch` but the daemon sums them away, and carrying them
    /// would mean rebasing every earlier hunk's position past every later edit.
    ///
    /// # Waiting for the hunks, and giving up on purpose
    ///
    /// The jump polls for hunks rather than firing on `User GitSignsUpdate`,
    /// which was the first attempt and is wrong twice. That event fires more
    /// than once, and the first fire is before the hunks are computed — so a
    /// `++once` handler burns on the empty one and never runs again. Measured:
    /// the event fires, `nav_hunk` returns cleanly, and the cursor stays on
    /// line 1.
    ///
    /// The obvious repair — an autocmd that stays until it finds hunks — is
    /// worse. It would still be armed later, so the first edit that made
    /// gitsigns recompute would yank the cursor to the top of the file while
    /// the user was typing somewhere else. Opening a file is a moment, not a
    /// mode.
    ///
    /// So: twenty tries, 100ms apart, then it stops caring. Two seconds is far
    /// past a local attach, and the failure mode is a file that opens at the
    /// top — which is what it did before any of this.
    ///
    /// Only for `nvim` and `vim`. `-c` is theirs; handing it to an `$EDITOR` of
    /// `code` or `emacs` would be passing a flag that means something else.
    nonisolated static func editorCommand(
        forFileAt path: String,
        settings: TerminalSettings.EditorSettings = TerminalSettings.EditorSettings()
    ) -> String {
        // What to do once the hunks exist. The wait around it is identical
        // either way — the difference is one call against four, and it is the
        // reason the poll is written as a body it drops in rather than as two
        // commands.
        let onHunks: String
        switch settings.diffMode {
        case .inline:
            // The cursor is placed from the hunk we already have, not by asking
            // gitsigns to navigate. `nav_hunk("first")` treats a cursor that is
            // *inside* the first hunk as a reason to move to its far edge, and
            // a brand new file is one hunk covering every line — so opening one
            // landed on the last line of the file. Measured: a 114-line new
            // file put the cursor on 114, a modified file on 28, which is why
            // it looked correct for months.
            //
            // `added.start` is 0 for a hunk that only deletes, where it means
            // "after this line". `math.max` keeps that from being an invalid
            // cursor position rather than pretending it is a real line.
            onHunks = """
                pcall(vim.api.nvim_win_set_cursor,0,{math.max(1,h[1].added.start),0}) \
                pcall(gs.toggle_deleted,true) \
                pcall(gs.toggle_word_diff,true) \
                pcall(gs.toggle_linehl,true)
                """
        case .sideBySide:
            // `diffthis` opens the split itself, against the index, and vim's
            // own diff mode lands the cursor on the first change — so there is
            // no `nav_hunk` here and no toggle either. The inline displays
            // would be drawn *inside* one half of a diff that is already
            // showing both, which is the same information twice at half the
            // width.
            onHunks = "pcall(gs.diffthis)"
        }

        // Only when the user's config has one. See `EditorSettings.showMinimap`
        // for why this detects rather than installs.
        //
        // Deferred like the jump is, and for a weaker version of the same
        // reason: the map is drawn from the buffer, and asking for it before
        // the file is in one gets an empty strip. It does not poll, though —
        // unlike the hunks, there is nothing here that arrives late. One delay
        // past the load is enough, and a map that missed it is a missing
        // sidebar rather than a wrong one.
        let minimap = settings.showMinimap
            ? """
             vim.defer_fn(function() \
            local mok,mm=pcall(require,"mini.map") \
            if mok then pcall(mm.open) end end,150)
            """
            : ""

        let showTheDiff = """
            lua local t=0 local function go() t=t+1 \
            local ok,gs=pcall(require,"gitsigns") \
            if ok then local h=gs.get_hunks() \
            if h and #h>0 then \
            \(onHunks) \
            return end end \
            if t<20 then vim.defer_fn(go,100) end end vim.defer_fn(go,100)\(minimap)
            """

        return """
        editor=${VISUAL:-${EDITOR:-}}
        if [ -z "$editor" ]; then
          for candidate in nvim vim vi; do
            if command -v "$candidate" >/dev/null 2>&1; then
              editor=$candidate
              break
            fi
          done
        fi
        case "${editor##*/}" in
          nvim|nvim\\ *|vim|vim\\ *)
            exec $editor -c \(shellQuoted(showTheDiff)) \(shellQuoted(path))
            ;;
          *)
            exec $editor \(shellQuoted(path))
            ;;
        esac
        """
    }

    /// A string the shell will read back as exactly these bytes.
    ///
    /// Single quotes disable every expansion the shell has, so the only case to
    /// handle is a single quote in the path itself — closed, escaped, reopened.
    /// A path is user data and reaches a shell here; nothing else in it may be
    /// interpreted.
    /// `nonisolated` because it is a function of its argument and nothing else
    /// — it touches no state, so it has no reason to be on the main actor.
    nonisolated static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Close a tab: kill the shell, tell the daemon, pick a neighbour.
    ///
    /// `close_tab` is the only way the daemon can learn a tab is gone —
    /// everything else would be inferring it from silence, which the protocol
    /// refuses on purpose.
    func closeTab(_ tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.tabID == tabID }) else { return }
        let tab = tabs.remove(at: index)

        // An editor gets asked to leave before it is signalled, so it does not
        // preserve a swap file for a session that did not crash. The row is
        // already off screen — the wait is the editor's, not the user's. See
        // `TerminalSession.askEditorToQuit`.
        if tab.editing != nil {
            tab.askEditorToQuit()
            // `tab` captured strongly on purpose: the list no longer holds it,
            // and it must outlive this delay or nothing gets signalled at all.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.editorQuitGrace) {
                tab.terminate()
            }
        } else {
            tab.terminate()
        }
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

    // MARK: - Daemon plumbing

    /// Re-read whether Claude Code's hooks point here.
    func refreshHookStatus() {
        hooksInstalled = HookStatus.read().installed
    }

    /// Install the hooks with the bundled CLI, then re-check rather than
    /// assuming: the status line should report what is on disk, not what was
    /// attempted.
    @discardableResult
    func installHooks() -> HookInstaller.Result {
        let result = HookInstaller.install()
        refreshHookStatus()
        return result
    }

    /// Point the Files panel at a session.
    ///
    /// Harmless while the panel is closed, which is what lets the sidebar's tap
    /// gesture do this unconditionally instead of asking what is on screen.
    /// Point the panel at a session, and go to its tab if it has one.
    ///
    /// Both halves, in this order, because they fight otherwise. Selecting a tab
    /// clears the pinned session — that is `selectedTabID`'s whole `didSet`, and
    /// it is right for every other caller — so pinning first and revealing
    /// second undid the pin on the way out. The bug was invisible for sessions
    /// running elsewhere, which have no tab to reveal and so never reached the
    /// line that cleared it; a local session's card was quietly failing to fill
    /// the panel this entire time.
    ///
    /// Ordering rather than a flag: the sequence *is* the intention. "Show me
    /// this session" means be on its tab and be pinned to it, and a caller
    /// should not have to know which of the two to ask for first.
    func inspect(session id: String) {
        if let tabID = sessions[id]?.tabID {
            selectedTabID = tabID
        }
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

    /// The session the Files panel should show: the one clicked, else the
    /// selected tab's, else none.
    ///
    /// It used to fall back to the first session in the list, on the reasoning
    /// that a panel showing nothing is a dead end. That was wrong, and worse
    /// than a dead end: selecting a tab with no session left the panel showing
    /// *some other* session's files, under a header naming that session, while
    /// the window was plainly on something else. A file list is a claim about
    /// whose files these are, and a claim that follows the wrong subject is not
    /// a fallback — it is a wrong answer. Now it says which tab you are on
    /// instead.
    var inspectedSession: SessionCard? {
        if let id = inspectedSessionID, let card = sessions[id] { return card }
        guard let tabID = selectedTabID else { return nil }
        if let card = orderedSessions.first(where: { $0.tabID == tabID }) {
            return card
        }
        // An editor tab keeps its session's file list on screen.
        //
        // Switching tabs otherwise means changing the subject, and the panel
        // follows. Opening files from a tree is the exception: it is *reading
        // that session*, one file at a time, and blanking the list at the first
        // click made the panel unusable for the thing it exists for — you lost
        // the list precisely by using it, and had to go back to the card to get
        // it again before opening the next file.
        //
        // The list still goes when the subject genuinely changes: another
        // session's card, a shell tab, a new tab.
        if let tab = tabs.first(where: { $0.tabID == tabID }),
           let owner = tab.editing?.sessionID,
           let card = sessions[owner] {
            return card
        }
        return nil
    }

    /// The selected tab, when it is not an agent session — what the Files panel
    /// names instead of a file list.
    var inspectedTab: TabModel? {
        guard inspectedSession == nil, let tabID = selectedTabID else { return nil }
        return tabs.first { $0.tabID == tabID }
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

    /// How long an editor gets to act on `:qa` before it is signalled.
    ///
    /// It only has to parse three keystrokes and close buffers it has already
    /// written, which is milliseconds. The margin is for a cold Neovim with a
    /// plugin manager still settling — the case where the swap file would
    /// otherwise be planted anyway.
    ///
    /// Deliberately much shorter than `TerminalSession.killGrace`: this is a
    /// delay a user could feel on quit, and that one is a deadline nobody
    /// waits on.
    static let editorQuitGrace: TimeInterval = 0.25

    // MARK: - Shutdown

    /// Close every tab properly on quit.
    ///
    /// Without this the daemon learns nothing and each session sits in the
    /// registry until it times out for inactivity — reported as
    /// `process_exited`, which is true but late and less specific than
    /// `tab_closed`.
    func shutdown() {
        // Every editor is asked to leave first, then all of them are given the
        // one grace period together — `n` tabs cost one wait, not `n`.
        //
        // This wait is **blocking**, and it is the one place that is
        // unavoidable: `applicationWillTerminate` is the last thing that runs,
        // so anything scheduled for later never happens and the editors are
        // reaped mid-sentence. A quarter of a second inside a quit is not
        // perceptible; the recovery prompt it prevents on the next open is.
        let editors = tabs.filter { $0.editing != nil }
        if !editors.isEmpty {
            for tab in editors { tab.askEditorToQuit() }
            // The run loop, not `sleep`: the PTY writes above are delivered by
            // this thread, and sleeping would hold the bytes we just queued.
            RunLoop.current.run(until: Date().addingTimeInterval(Self.editorQuitGrace))
        }

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
