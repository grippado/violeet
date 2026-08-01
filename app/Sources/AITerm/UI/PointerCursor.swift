// The pointing hand, over things that can be clicked.
//
// macOS draws the arrow everywhere by default and leaves it to the application
// to say otherwise. In a window built out of custom controls — plain-styled
// buttons, tappable rows, a card you click to switch tabs — nothing has the
// system's own affordances, so the cursor is most of what is left to say "this
// one does something". Without it every surface reads the same.
//
// # Why push/pop, and why it is guarded
//
// `NSCursor.push()` puts a cursor on a stack and `pop()` takes it off, which is
// the only pairing that survives nested hovers — a button inside a row that is
// itself hoverable would otherwise have the inner exit reset the cursor to the
// arrow while the pointer is still over the outer one.
//
// The stack is also the failure mode. `onHover(false)` is not guaranteed to
// arrive: a view that disappears under the pointer — a card that reorders when
// a session starts waiting, a settings row inside a section being collapsed —
// takes its hover with it and leaves a pushed cursor nobody will ever pop, and
// the app is stuck showing a hand. So the pushed state is tracked, and
// `onDisappear` pops what is still owed.
//
// `.pointerStyle` (macOS 15) is the modern spelling of this and would replace
// the whole file. It is not available on macOS 14, which is what this app
// targets.

import AppKit
import SwiftUI

extension View {
    /// Show the pointing hand while the pointer is over this view.
    ///
    /// `enabled` exists for controls that are conditionally inert — a stepper
    /// at the end of its range is still on screen and still hoverable, and a
    /// hand over a button that will not act is a worse lie than the arrow.
    func pointingHand(_ enabled: Bool = true) -> some View {
        modifier(PointingHandCursor(enabled: enabled))
    }
}

private struct PointingHandCursor: ViewModifier {
    let enabled: Bool

    /// Whether this view currently owns an entry on the cursor stack.
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, enabled {
                    guard !pushed else { return }
                    pushed = true
                    NSCursor.pointingHand.push()
                } else {
                    pop()
                }
            }
            .onDisappear(perform: pop)
            // A control that becomes inert under the pointer gives the arrow
            // back immediately, rather than on the next time the pointer moves.
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled { pop() }
            }
    }

    private func pop() {
        guard pushed else { return }
        pushed = false
        NSCursor.pop()
    }
}
