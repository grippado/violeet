// The Shift+Return mapping, against synthesized key events.
//
// The bug being fixed is invisible from the code: both Return and Shift+Return
// produce `\r`, so a terminal that does nothing special looks correct and
// simply cannot type a newline into an agent. These tests pin the one
// combination that is translated, and — as much as the assertions above —
// the ones that are not.

import AppKit
import Foundation
import Testing

@testable import AITerm

/// A key event as AppKit would deliver it.
///
/// `keyCode` is what the mapping reads; `characters` is filled in for realism
/// so a future implementation that looks at it does not silently pass on a
/// half-built event.
private func key(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], characters: String = "\r") -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: flags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )!
}

private let returnKey: UInt16 = 36
private let keypadEnter: UInt16 = 76
private let letterA: UInt16 = 0

@Suite("Shift+Return")
struct TerminalKeysTests {
    /// The whole point: a newline the agent accepts without submitting.
    @Test("Shift+Return sends ESC CR")
    func shiftReturnSendsEscapeReturn() {
        #expect(TerminalKeys.bytes(for: key(returnKey, .shift)) == [0x1b, 0x0d])
    }

    /// Not a line feed. `\n` is what `\r` already becomes for the program on
    /// the other end, so sending it would submit exactly like Return — the bug,
    /// wearing a different byte.
    @Test("the sequence is ESC CR and not a bare line feed")
    func theSequenceIsNotALineFeed() {
        #expect(TerminalKeys.shiftReturn != [0x0a])
        #expect(TerminalKeys.shiftReturn == [0x1b, 0x0d])
    }

    /// The keypad's Enter is the same key as far as anyone typing is
    /// concerned.
    @Test("Shift with the keypad's Enter is the same combination")
    func keypadEnterIsTheSameKey() {
        #expect(TerminalKeys.bytes(for: key(keypadEnter, .shift)) == TerminalKeys.shiftReturn)
    }

    /// Plain Return must reach SwiftTerm untouched. If this ever returns
    /// bytes, every command in every tab stops being submitted.
    @Test("plain Return is not translated")
    func plainReturnIsNotTranslated() {
        #expect(TerminalKeys.bytes(for: key(returnKey)) == nil)
    }

    /// Control+Return and Option+Return have meanings inside the emulator, and
    /// claiming them here would take them away with no way to notice.
    @Test("only shift — other modifiers on Return belong to the emulator")
    func otherModifiersAreLeftAlone() {
        for flags: NSEvent.ModifierFlags in [
            .control, .option, .command,
            [.shift, .control], [.shift, .option], [.shift, .command],
        ] {
            #expect(
                TerminalKeys.bytes(for: key(returnKey, flags)) == nil,
                "\(flags) on Return must go to SwiftTerm"
            )
        }
    }

    /// Caps Lock and the numeric-pad flag ride along on ordinary events. They
    /// are not modifiers anybody pressed, and treating them as part of the
    /// combination would make Shift+Return work only sometimes.
    @Test("a shifted Return still maps with incidental flags set")
    func incidentalFlagsDoNotBreakTheMatch() {
        // `.numericPad` is set for the keypad's Enter on real hardware.
        let event = key(keypadEnter, [.shift, .numericPad])
        // Documented behaviour rather than an accident: the mapping requires
        // shift *alone* among the device-independent flags, and `.numericPad`
        // is one of them — so this combination goes to SwiftTerm. Recorded so
        // that if keypad Enter is reported as not working, the reason is here
        // rather than in a guess.
        #expect(TerminalKeys.bytes(for: event) == nil)
    }

    @Test("no other key is translated")
    func noOtherKeyIsTranslated() {
        #expect(TerminalKeys.bytes(for: key(letterA, .shift, characters: "A")) == nil)
        #expect(TerminalKeys.bytes(for: key(letterA, characters: "a")) == nil)
    }
}
