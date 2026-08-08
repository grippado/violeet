// The one thing about a drafted answer that cannot be allowed to regress:
// inserting it must never submit it.
//
// These assertions are the executable form of the rule in `CLAUDE.md` —
// automation does not press Enter — applied to text that came out of a language
// model, where "it will not contain a newline" is not a property anyone holds.

import Foundation
import Testing

@testable import Violeet

@Suite("Draft insertion")
struct DraftInsertionTests {
    @Test("no bare CR or LF reaches the PTY, whatever the draft contains")
    func neverSubmits() {
        let drafts = [
            "vai pelo primeiro",
            "sim.\nmas roda a suite antes",
            "windows\r\nline endings",
            "bare\rcarriage return",
            "trailing newline\n",
            "\n\n\nleading newlines",
            "acentuação é byte multi-octeto\né",
            String(repeating: "a\n", count: 200),
        ]
        for draft in drafts {
            let bytes = DraftInsertion.bytes(for: draft)
            #expect(DraftInsertion.carriesNoBareReturn(bytes), "draft: \(draft.debugDescription)")
            // Stated the blunt way as well, so the guard's own logic being
            // wrong cannot make this suite pass: every 0x0D is preceded by ESC,
            // and there is no 0x0A at all.
            #expect(!bytes.contains(0x0A))
        }
    }

    @Test("a line break becomes ESC CR, the sequence that does not submit")
    func lineBreakIsShiftReturn() {
        #expect(DraftInsertion.bytes(for: "a\nb") == [0x61, 0x1B, 0x0D, 0x62])
        // Shares the mapping with the Shift+Return key rather than repeating it.
        #expect(TerminalKeys.shiftReturn == [0x1B, 0x0D])
    }

    @Test("CRLF is one break, not two")
    func crlfIsOneBreak() {
        #expect(DraftInsertion.bytes(for: "a\r\nb") == [0x61, 0x1B, 0x0D, 0x62])
        #expect(DraftInsertion.bytes(for: "a\n\nb").count == 6)
    }

    @Test("a whitespace-only draft inserts nothing")
    func emptyInsertsNothing() {
        #expect(DraftInsertion.bytes(for: "").isEmpty)
        #expect(DraftInsertion.bytes(for: "   \n\t\n ").isEmpty)
    }

    @Test("the guard rejects what it is there to reject")
    func guardCatchesBareReturns() {
        #expect(!DraftInsertion.carriesNoBareReturn([0x61, 0x0A]))
        #expect(!DraftInsertion.carriesNoBareReturn([0x61, 0x0D]))
        #expect(!DraftInsertion.carriesNoBareReturn([0x0D]))
        #expect(DraftInsertion.carriesNoBareReturn([0x61, 0x1B, 0x0D]))
        #expect(DraftInsertion.carriesNoBareReturn([]))
    }
}
