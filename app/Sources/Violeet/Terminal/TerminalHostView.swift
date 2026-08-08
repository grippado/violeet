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
        Self.dumpLayout(view)
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

    /// Print where the terminal actually ended up, when `VIOLEET_DEBUG_LAYOUT` is
    /// set.
    ///
    /// Added after two wrong guesses at a visible gap between the terminal and
    /// the right sidebar — first blamed on the scroller gutter, then on the
    /// panel's padding, neither measured. A screenshot shows that something is
    /// wrong and never which view owns the pixels; this prints the frames so
    /// the next answer comes from numbers.
    /// One line per view: class, frame, opacity. Two levels is enough to see
    /// who is beside whom without printing SwiftUI's entire internal tree.
    private static func describe(_ view: NSView, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        var out = """
            \(pad)[view] \(type(of: view)) frame=\(view.frame) \
            opaque=\(view.isOpaque) hidden=\(view.isHidden)

            """
        if depth < 4 {
            for sub in view.subviews {
                out += describe(sub, depth: depth + 1)
            }
        }
        return out
    }

    private static func dumpLayout(_ view: LocalProcessTerminalView) {
        guard ProcessInfo.processInfo.environment["VIOLEET_DEBUG_LAYOUT"] != nil else { return }
        DispatchQueue.main.async {
            let cell = view.getOptimalFrameSize()
            let superBounds = view.superview?.bounds ?? .zero
            var report = """
                [layout] terminal=\(view.frame) super=\(superBounds) \
                optimal=\(cell.size) cols=\(view.getTerminal().cols) \
                window=\(view.window?.frame.size ?? .zero)

                """
            // The whole tree, because the question that keeps going unanswered
            // is not how big the terminal is — it is which view owns the pixels
            // beside it.
            if let content = view.window?.contentView {
                report += describe(content, depth: 0)
            }
            FileHandle.standardError.write(Data(report.utf8))
        }
    }
}
