// Putting a drafted answer into the agent's prompt without answering it.
//
// # The invariant
//
// **No byte this path writes is a `\n` or a `\r`.** Enter is the user's, always,
// and it is the same rule as the `keystroke` rule in `CLAUDE.md` for the same
// reason: text typed into the wrong box is recoverable, and Enter in the wrong
// box is not. A drafted answer that submits itself is a draft that was never
// reviewed, whatever the panel showed a moment earlier.
//
// The rule is enforced here rather than trusted to callers, because a draft is
// arbitrary text from a language model and "it will not contain a newline" is
// not a property anyone can hold.
//
// # A newline in the draft is not a submit
//
// A multi-paragraph draft still needs its line breaks. They are sent as
// `TerminalKeys.shiftReturn` — `ESC` `CR`, the sequence Claude Code and Codex
// already agreed means *newline without submitting* (see `TerminalKeys`). So the
// draft arrives with its shape intact and the prompt stays open.
//
// A `\r\n` pair is one break, not two: a model that emits Windows line endings
// should not double-space the prompt.

import Foundation

/// Turning a reviewed draft into PTY input.
enum DraftInsertion {
    /// The bytes to write for `draft`, with every line break translated.
    ///
    /// Returns an empty array for a draft that is only whitespace: writing
    /// nothing is the honest outcome, and an "inserted" that inserted a space is
    /// a lie the user has to squint at the prompt to catch.
    static func bytes(for draft: String) -> [UInt8] {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var out: [UInt8] = []
        var pendingCR = false
        for byte in Array(trimmed.utf8) {
            switch byte {
            case 0x0D:  // CR
                out.append(contentsOf: TerminalKeys.shiftReturn)
                pendingCR = true
            case 0x0A:  // LF
                // Second half of a CRLF pair: the break was already written.
                if !pendingCR { out.append(contentsOf: TerminalKeys.shiftReturn) }
                pendingCR = false
            default:
                out.append(byte)
                pendingCR = false
            }
        }
        return out
    }

    /// True when `bytes` is safe to write as typed input on this path.
    ///
    /// The assertion the invariant above is made of. `ESC CR` contains a `\r`
    /// *as its second byte*, which is the whole point of it, so the check is
    /// "no `\r` that is not preceded by `ESC`" rather than "no `\r`".
    static func carriesNoBareReturn(_ bytes: [UInt8]) -> Bool {
        for (index, byte) in bytes.enumerated() {
            if byte == 0x0A { return false }
            if byte == 0x0D {
                guard index > 0, bytes[index - 1] == 0x1B else { return false }
            }
        }
        return true
    }
}

extension TerminalSession {
    /// Type a reviewed draft into this tab's prompt, and stop there.
    ///
    /// Deliberately has no "and send" variant, and must not grow one. The caller
    /// should hand keyboard focus back to the terminal after this — a panel that
    /// keeps first responder leaves the user typing their edit into the draft
    /// they just inserted.
    func insertDraft(_ draft: String) {
        let bytes = DraftInsertion.bytes(for: draft)
        guard !bytes.isEmpty else { return }
        // Belt and braces: the translation above is the guarantee, and this is
        // the assertion that it held. A draft is model output, and the failure
        // this guards is silent and unrecoverable.
        guard DraftInsertion.carriesNoBareReturn(bytes) else {
            assertionFailure("draft insertion produced a bare CR or LF")
            return
        }
        send(bytes)
    }
}
