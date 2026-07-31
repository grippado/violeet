// The only place AppKit meets SwiftUI.
//
// ADR-001: SwiftTerm owns the grid, and SwiftUI owns everything around it. This
// representable is the seam, and it is deliberately the whole seam — no drawing,
// no input handling, no layout maths. It hosts a view that already exists and
// hands it the keyboard when its tab is selected.
//
// The view is created by `TerminalSession` and owned by the tab, not by this
// struct. That matters: SwiftUI recreates representable *values* freely, and a
// terminal whose NSView were rebuilt on each pass would lose its scrollback and
// its PTY along with it.

import AppKit
import SwiftTerm
import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    /// Whether this tab is the visible one. Drives first responder, nothing else.
    let isSelected: Bool

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        guard isSelected else { return }
        // Deferred: during a SwiftUI update pass the view may not be in a
        // window yet, and `makeFirstResponder` on a windowless view is a silent
        // no-op that leaves the user typing into nothing.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if window.firstResponder !== view {
                window.makeFirstResponder(view)
            }
        }
    }
}
