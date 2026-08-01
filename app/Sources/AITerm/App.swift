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

        CommandGroup(after: .sidebar) {
            Button(state.preferences.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                state.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])

            Button(state.preferences.inspectorVisible ? "Hide Settings" : "Show Settings") {
                state.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])

            Divider()

            Button("Bigger Text") { state.preferences.adjustFontSize(by: 1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller Text") { state.preferences.adjustFontSize(by: -1) }
                .keyboardShortcut("-", modifiers: .command)
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
    var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { Self.removeStandardCloseItem() }
    }

    /// Run again once the app is actually in front.
    ///
    /// SwiftUI builds the menu bar lazily and rebuilds it when the scene
    /// changes, both of which can happen after `applicationDidFinishLaunching`
    /// — so a single removal there is a race that is lost quietly, leaving two
    /// items claiming ⌘W and the wrong one winning. The removal is idempotent,
    /// so running it more than once costs nothing.
    func applicationDidBecomeActive(_ notification: Notification) {
        Self.removeStandardCloseItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            state?.shutdown()
        }
    }

    /// Take ⌘W away from AppKit so it can mean "close tab".
    ///
    /// SwiftUI's File menu inherits AppKit's standard Close item, and two menu
    /// items sharing one key equivalent resolve by whichever the responder
    /// chain reaches first — which is to say unpredictably. Removing it is
    /// blunter than it looks but it is the only way to leave exactly one
    /// meaning for the shortcut, and the window is still closable from its
    /// traffic light and from ⌘Q.
    private static func removeStandardCloseItem() {
        guard let mainMenu = NSApp.mainMenu else { return }

        // Searched by selector across every submenu rather than by looking up a
        // menu called "File". AppKit localizes its standard menus, so on a
        // Portuguese system that menu is "Arquivo" and the item is "Fechar" —
        // and a title match would quietly find nothing, leaving two live ⌘W
        // items and a shortcut whose meaning depends on the responder chain.
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            for item in submenu.items where item.action == #selector(NSWindow.performClose(_:)) {
                submenu.removeItem(item)
            }
        }
    }
}

/// Gives the window an autosave name, which is how its frame survives a quit.
///

