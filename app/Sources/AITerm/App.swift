// aiterm — native macOS terminal for running several AI coding agents as tabs.
//
// The app is a dumb client of aiterm-daemon: it renders sessions and sends
// commands over the Unix socket at ~/.aiterm/daemon.sock. It computes no token
// counts, no context percentages, and no session state of its own. See
// docs/adr/ADR-002.
//
// Not implemented yet.

import SwiftUI

@main
struct AITermApp: App {
    var body: some Scene {
        WindowGroup {
            Text("aiterm — not implemented yet")
        }
    }
}
