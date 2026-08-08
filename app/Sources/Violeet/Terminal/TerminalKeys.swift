// The one key this app translates, and why it has to.
//
// # Shift+Return
//
// A terminal has no way to say "shift and return" on the wire. The PTY carries
// bytes, and both Return and Shift+Return produce the same byte — `\r`. So a
// program that wants a *newline without submitting* has to agree with the
// terminal on a sequence that means it, and the agreement Claude Code, Codex
// and friends settled on is `ESC` followed by `CR`.
//
// That is what `claude /terminal-setup` writes into iTerm2's key map, and it is
// why Shift+Return does nothing in a terminal nobody has configured: the shell
// and the agent both received a plain `\r` and both did what `\r` means.
//
// violeet ships the mapping instead of asking the user to install it. A terminal
// built for agents that cannot type a newline into one is a terminal missing
// the thing it was built for.
//
// # Why only this key
//
// Every other keystroke belongs to SwiftTerm, which implements a decade of
// xterm behaviour that this app has no business second-guessing (ADR-001). The
// override is one `if`, on one key combination, and everything else goes to
// `super` untouched. That is deliberate: an input layer that grows here is an
// input layer that will disagree with the emulator about something subtle,
// months from now, in a way that is very hard to attribute.

import AppKit
import Foundation
import SwiftTerm

/// Key translations violeet performs before SwiftTerm sees the event.
enum TerminalKeys {
    /// `ESC` `CR`. Sent for Shift+Return.
    ///
    /// Not `\n`: a bare line feed is what `\r` already becomes for a shell, so
    /// it would submit exactly like Return does. The escape prefix is what
    /// makes the two distinguishable at all.
    static let shiftReturn: [UInt8] = [0x1b, 0x0d]

    /// The bytes to send for `event`, or `nil` to let SwiftTerm handle it.
    ///
    /// A free function over the event rather than logic inside `keyDown`, so
    /// the mapping can be tested without a window, a PTY, or a running app.
    static func bytes(for event: NSEvent) -> [UInt8]? {
        guard isReturn(event) else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Shift, and *only* shift. Control+Return and Option+Return have their
        // own meanings in the emulator, and claiming them here would take them
        // away silently.
        guard flags == .shift else { return nil }
        return shiftReturn
    }

    /// Return or the numeric keypad's Enter.
    ///
    /// Matched on `keyCode` rather than on the character, because
    /// `characters` for Return is `\r` and comparing strings would also match
    /// a Control+M someone typed deliberately.
    private static func isReturn(_ event: NSEvent) -> Bool {
        // 36 is Return, 76 is the keypad's Enter. Both are `\r` on the wire and
        // both are "the key you press to send a line".
        event.keyCode == 36 || event.keyCode == 76
    }
}

// # Why a monitor and not a subclass
//
// The obvious shape is a `LocalProcessTerminalView` subclass overriding
// `keyDown`. It does not compile: SwiftTerm declares the method `public` and
// not `open`, so it cannot be overridden outside its module. Patching the
// dependency to widen it would put a local fork between this app and every
// future SwiftTerm release, for one key.
//
// `NSEvent.addLocalMonitorForEvents` sees the event before it is dispatched to
// the responder chain and can swallow it by returning `nil`. The cost is that
// it sees *every* key event in the app, so the guard has to be exact: the right
// key combination, and the terminal actually being first responder. Anything
// else is returned untouched, including every keystroke typed into the rename
// field or the settings panel.
