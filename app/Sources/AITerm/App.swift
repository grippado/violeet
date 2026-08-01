// aiterm — native macOS terminal for running several AI coding agents as tabs.
//
// The app is a dumb client of aiterm-daemon: it renders sessions and sends
// commands over the Unix socket at ~/.aiterm/daemon.sock. It computes no token
// counts, no context percentages, and no session state of its own. See
// docs/adr/ADR-002.
//
// This file is the shell of that: one window, the menu commands, and the
// AppKit-level details SwiftUI has no vocabulary for — the window's autosaved
// frame, and reclaiming ⌘W for tabs.

import AppKit
import SwiftUI

@main
struct AITermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(preferences: state.preferences)
                .environmentObject(state)
                .onAppear {
                    delegate.state = state
                    // One tab, always, on launch. Sessions are not restored —
                    // see the note in Preferences.
                    if state.tabs.isEmpty { state.newTab() }
                }
        }
        .defaultSize(width: 1100, height: 700)
        .commands { AITermCommands(state: state) }
    }
}

// MARK: - Menu commands

private struct AITermCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        // Replaces "New Window"/"New" wholesale: this app has one window, and a
        // ⌘N that opened a second one would give every shortcut below two
        // possible meanings.
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { state.newTab() }
                .keyboardShortcut("t", modifiers: .command)

            // Deliberately never `.disabled`. A disabled menu item does not
            // fire its key equivalent, and SwiftUI evaluates a command's
            // `disabled` against a snapshot of state that is not reliably
            // refreshed — so a `.disabled(state.selectedTabID == nil)` here
            // latches on the empty state the menu was first built in and ⌘W
            // stops working for the rest of the session. Guarding inside the
            // action costs a no-op and cannot latch.
            Button("Close Tab") { state.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
        }

        // `⌘,` is where every macOS user looks for settings, so it has to work
        // — but SwiftUI's `Settings` scene opens a *window*, which is the one
        // thing this panel exists not to be: a separate window takes key status
        // from the terminal and the session stops receiving keystrokes.
        //
        // Replacing the standard item is what lets the familiar shortcut do the
        // right thing. `.appSettings` is the group AppKit puts "Settings…" in,
        // so replacing it swaps the behaviour without leaving a dead menu entry
        // that opens an empty window beside the working one.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { state.toggleInspector() }
                .keyboardShortcut(",", modifiers: .command)
        }

        // The About panel is the app's own, not AppKit's. `.appInfo` is the
        // group the standard "About <App>" sits in, so replacing it swaps the
        // panel without leaving a second entry beside it.
        CommandGroup(replacing: .appInfo) {
            Button("About aiterm") { AboutWindow.show(state: state) }
        }

        // Nothing in this app has a help book, so the standard "<App> Help"
        // item opens the Help Viewer onto an error. Replaced with nothing —
        // see `pruneStandardMenus` for why the empty menu is then removed
        // outright rather than left as an empty title in the bar.
        CommandGroup(replacing: .help) {}

        CommandGroup(after: .sidebar) {
            // "Sessions" and not "Sidebar": this window has two of them, and
            // the item directly below this one toggles the other.
            Button(state.preferences.sidebarVisible ? "Hide Sessions" : "Show Sessions") {
                state.toggleSidebar()
            }
            // `⌘.` rather than the old `⌥⌘S`: this is a sidebar people collapse
            // to read a wide diff and open again a second later, and it should
            // be one hand. SwiftUI binds one shortcut per item, so it is a
            // replacement and not an addition.
            //
            // The classic Mac meaning of `⌘.` is "cancel", but nothing in this
            // window cancels — interrupting the program in the terminal is
            // `Ctrl-C`, which never reaches the menu bar.
            .keyboardShortcut(".", modifiers: .command)

            Button(state.preferences.inspectorVisible ? "Hide Settings" : "Show Settings") {
                state.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Button("Bigger Text") { state.preferences.adjustFontSize(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { state.preferences.adjustFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
            // ⌘0 is where every browser and editor puts "back to normal", and
            // without it the only way back from twelve presses of ⌘- is twelve
            // presses of ⌘+.
            Button("Actual Size") { state.preferences.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
        }

        CommandMenu("Tab") {
            Button("Next Tab") { state.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { state.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            // ⌘1…⌘8 are positional; ⌘9 is "the last one", which is what every
            // browser trained everybody to expect and is more useful than an
            // eighth-and-ninth distinction nobody counts to.
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") {
                    state.selectTab(number: number)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
    }
}

// MARK: - AppKit glue

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the scene once the window exists. Weak-by-convention: the app
    /// state outlives the delegate's interest in it.
    ///
    /// The status item is created here rather than in `applicationDidFinish
    /// Launching` because it needs the state, and the state arrives with the
    /// scene — which is after launch. Guarded so a second `onAppear` (SwiftUI
    /// makes no promise it happens once) cannot put two icons in the menu bar.
    var state: AppState? {
        didSet {
            guard let state, statusItem == nil else { return }
            MainActor.assumeIsolated {
                statusItem = StatusItemController(state: state)
            }
        }
    }

    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { Self.pruneStandardMenus() }
        watchMenuRebuilds()
    }

    /// Run again once the app is actually in front.
    ///
    /// SwiftUI builds the menu bar lazily and rebuilds it when the scene
    /// changes, both of which can happen after `applicationDidFinishLaunching`
    /// — so a single pass there is a race that is lost quietly, leaving two
    /// items claiming ⌘W and the wrong one winning. The pass is idempotent, so
    /// running it more than once costs nothing.
    func applicationDidBecomeActive(_ notification: Notification) {
        Self.pruneStandardMenus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            state?.shutdown()
        }
    }

    /// Prune again whenever anything puts an item back.
    ///
    /// Measured, not anticipated: a single pass in `applicationDidBecomeActive`
    /// left the Edit menu clean and the Help menu still in the bar — SwiftUI
    /// rebuilds the menu bar after the delegate callbacks have run, and the
    /// rebuild restores what was taken out. Anything scheduled by hand is a
    /// race against a rebuild whose timing is not ours; reacting to the rebuild
    /// itself is not.
    ///
    /// Coalesced through one flag: the notification fires once per item added,
    /// which during a rebuild is a few dozen times in a row, and pruning on
    /// each would be quadratic for no benefit. Pruning is idempotent, so the
    /// only cost of the extra passes is the passes.
    private func watchMenuRebuilds() {
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.prunePending else { return }
            self.prunePending = true
            DispatchQueue.main.async {
                self.prunePending = false
                Self.pruneStandardMenus()
            }
        }
    }

    private var menuObserver: NSObjectProtocol?
    private var prunePending = false

    /// Take out the standard items this app has no business offering.
    ///
    /// # Why by selector, never by title
    ///
    /// AppKit **localizes** the standard menus. On this machine, in Portuguese,
    /// the File menu is "Arquivo" and Close is "Fechar" — so a title match
    /// finds nothing, silently, and the item it was meant to remove stays. That
    /// was learned the expensive way with ⌘W: two live Close items, one
    /// shortcut, and the winner decided by whichever the responder chain
    /// reached first. Every removal below identifies its target by the action
    /// it sends, which is the same in every language.
    ///
    /// A few of these selectors have no public Swift symbol (`closeAll:`, and
    /// AutoFill's `_handleInsertFrom…`). Those are matched by name, and matched
    /// *defensively*: a selector that no longer exists simply matches nothing,
    /// so a future macOS that renames one costs a stale menu item and not a
    /// crash.
    ///
    /// # What goes, and why
    ///
    /// Every item here is one of three things: dead (nothing implements it),
    /// misleading (it promises something the app does not have), or actively
    /// dangerous in a terminal. Nothing is removed for being merely unused.
    private static func pruneStandardMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Dead or misleading, one selector each.
        var doomed: Set<Selector> = [
            // ⌘W has to mean "close tab", and two items claiming it resolve
            // unpredictably. The window is still closable from its traffic
            // light and from ⌘Q.
            #selector(NSWindow.performClose(_:)),
            // ⌥⌘W, one finger from ⌘W, closing every window — which here means
            // every tab and every PTY behind them, with no confirmation.
            NSSelectorFromString("closeAll:"),
            // A PTY has already swallowed the bytes. There is nothing to undo
            // and there never will be.
            //
            // By name, and measured: `#selector(UndoManager.undo)` is `undo`,
            // with no sender, and the menu item sends `undo:`. The two are
            // different selectors, and the first pass at this quietly removed
            // nothing.
            NSSelectorFromString("undo:"),
            NSSelectorFromString("redo:"),
            // Measured: SwiftTerm implements `copy:`, `paste:` and
            // `selectAll:`, and neither of these. Permanently grey.
            #selector(NSText.cut(_:)),
            #selector(NSText.delete(_:)),
            // Dictating shell commands.
            NSSelectorFromString("startDictation:"),
            // This app has one window; the item exists for apps that have
            // several.
            #selector(NSApplication.arrangeInFront(_:)),
            // There is no help book in the bundle, so this opens the Help
            // Viewer onto "help isn't available". The SwiftUI side already
            // replaced the group; this catches the item AppKit installs
            // directly.
            #selector(NSApplication.showHelp(_:)),
        ]
        // Injected into the Help menu by AppKit, claiming ⌥⌘S and sending a
        // message nothing in this app implements — while the real sidebar
        // toggle is ⌘. So: a dead item whose shortcut competes with a live one.
        doomed.insert(NSSelectorFromString("toggleSidebar:"))

        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            for item in submenu.items {
                if let action = item.action, doomed.contains(action) {
                    submenu.removeItem(item)
                    continue
                }
                // AutoFill: inserts a contact, a **password** or a credit card
                // into the responder. In a terminal that types the secret into
                // a PTY that echoes it, and it lands in the scrollback. There
                // is no public selector for the submenu itself, so it is
                // identified by what its children send.
                if let sub = item.submenu, isAutoFill(sub) {
                    submenu.removeItem(item)
                }
            }
            tidySeparators(in: submenu)
        }

        // A menu emptied by the above should not stay in the bar as a title
        // that opens onto nothing. In practice this is Help.
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            if submenu.items.allSatisfy({ $0.isSeparatorItem }) {
                mainMenu.removeItem(top)
            }
        }
    }

    private static func isAutoFill(_ menu: NSMenu) -> Bool {
        !menu.items.isEmpty && menu.items.allSatisfy { item in
            guard let action = item.action else { return false }
            return NSStringFromSelector(action).hasPrefix("_handleInsertFrom")
        }
    }

    /// Collapse the gaps a removal leaves behind.
    ///
    /// Removing an item between two separators leaves them adjacent, which
    /// AppKit draws as two rules with nothing between them — the File menu had
    /// exactly that after the Close item went. Also drops separators that have
    /// ended up at either end.
    private static func tidySeparators(in menu: NSMenu) {
        var previousWasSeparator = true
        for item in menu.items {
            guard item.isSeparatorItem else {
                previousWasSeparator = false
                continue
            }
            if previousWasSeparator {
                menu.removeItem(item)
            } else {
                previousWasSeparator = true
            }
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}

/// Gives the window an autosave name, which is how its frame survives a quit.
///

