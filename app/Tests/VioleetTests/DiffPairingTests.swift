// The two-column reading, and the surplus.
//
// The pairing is the part of this feature with an actual decision in it — which
// removal faces which addition, and where the leftovers go — so it is the part
// that has to be pinned down by tests rather than by a comment alone. The rule
// under test is stated in `DiffPairing`: positional inside a change block,
// padding at the end of the block, never interleaved.

import Testing

@testable import Violeet

@Suite("Diff pairing")
struct DiffPairingTests {
    /// Builds a hunk from a compact spelling, so a test reads as a diff.
    private func hunk(_ spec: [String]) -> DiffHunk {
        var lines: [DiffLine] = []
        var old = 1
        var new = 1
        for entry in spec {
            let text = String(entry.dropFirst())
            switch entry.first {
            case "+":
                lines.append(DiffLine(origin: .added, text: text, newNumber: new))
                new += 1
            case "-":
                lines.append(DiffLine(origin: .removed, text: text, oldNumber: old))
                old += 1
            default:
                lines.append(DiffLine(origin: .context, text: text, oldNumber: old, newNumber: new))
                old += 1
                new += 1
            }
        }
        return DiffHunk(
            oldStart: 1, oldCount: old - 1, newStart: 1, newCount: new - 1, lines: lines)
    }

    @Test("context occupies both sides of one row")
    func contextIsShared() {
        let rows = DiffPairing.rows(for: hunk([" a", " b"]))
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.isContext })
        #expect(rows.allSatisfy { $0.left == $0.right })
        #expect(rows.allSatisfy { !$0.isUnbalanced })
    }

    @Test("equal runs pair off in order")
    func balancedBlock() {
        let rows = DiffPairing.rows(for: hunk(["-one", "-two", "+ONE", "+TWO"]))
        #expect(rows.count == 2)
        #expect(rows[0].left?.text == "one")
        #expect(rows[0].right?.text == "ONE")
        #expect(rows[1].left?.text == "two")
        #expect(rows[1].right?.text == "TWO")
        // First faces first: no crossing the reader cannot see.
        #expect(rows.allSatisfy { !$0.isUnbalanced })
    }

    @Test("more additions than removals pad the old side, at the end of the block")
    func surplusAdditions() {
        let rows = DiffPairing.rows(for: hunk([" ctx", "-one", "+ONE", "+extra", "+more", " end"]))
        #expect(rows.count == 5)
        #expect(rows[0].isContext)
        #expect(rows[1].left?.text == "one")
        #expect(rows[1].right?.text == "ONE")
        // The surplus comes after the pair, not spread through it: a blank in
        // the middle of a contiguous edit reads as two edits.
        #expect(rows[2].left == nil)
        #expect(rows[2].right?.text == "extra")
        #expect(rows[3].left == nil)
        #expect(rows[3].right?.text == "more")
        #expect(rows[4].isContext)
    }

    @Test("more removals than additions pad the new side")
    func surplusRemovals() {
        let rows = DiffPairing.rows(for: hunk(["-one", "-two", "-three", "+ONE"]))
        #expect(rows.count == 3)
        #expect(rows[0].right?.text == "ONE")
        #expect(rows[1].right == nil)
        #expect(rows[1].left?.text == "two")
        #expect(rows[2].right == nil)
        #expect(rows[2].left?.text == "three")
    }

    @Test("a pure insertion has an empty left column throughout")
    func pureInsertion() {
        let rows = DiffPairing.rows(for: hunk(["+one", "+two"]))
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.left == nil })
        #expect(rows.allSatisfy { $0.isUnbalanced })
    }

    @Test("a context line closes the block, so runs across it do not pair")
    func contextSeparatesBlocks() {
        let rows = DiffPairing.rows(for: hunk(["-one", " ctx", "+ONE"]))
        // Three rows and not two: `one` and `ONE` are on opposite sides of a
        // line that did not change, which makes them separate edits.
        #expect(rows.count == 3)
        #expect(rows[0].right == nil)
        #expect(rows[1].isContext)
        #expect(rows[2].left == nil)
    }

    @Test("additions listed before removals still pair positionally")
    func additionsFirst() {
        let rows = DiffPairing.rows(for: hunk(["+ONE", "-one"]))
        #expect(rows.count == 1)
        #expect(rows[0].left?.text == "one")
        #expect(rows[0].right?.text == "ONE")
    }

    @Test("no row is empty on both sides, whatever the shape")
    func neverDoublyEmpty() {
        let shapes: [[String]] = [
            [], [" a"], ["+a"], ["-a"], ["-a", "+b"], ["-a", "-b", "+c"],
            [" a", "-b", "+c", "+d", " e"], ["+a", "-b", "-c"],
        ]
        for shape in shapes {
            for row in DiffPairing.rows(for: hunk(shape)) {
                #expect(row.left != nil || row.right != nil, "\(shape) produced an empty row")
            }
        }
    }

    @Test("every line of the hunk survives the pairing, in order")
    func nothingIsLost() {
        let source = hunk([" a", "-b", "-c", "+B", " d", "+e"])
        let rows = DiffPairing.rows(for: source)

        // Context appears once but occupies both columns, so counting the two
        // columns separately is what has to add up.
        let left = rows.compactMap(\.left)
        let right = rows.compactMap(\.right)
        #expect(left.map(\.text) == source.lines.filter { $0.origin != .added }.map(\.text))
        #expect(right.map(\.text) == source.lines.filter { $0.origin != .removed }.map(\.text))
    }

    @Test("a whole file pairs hunk by hunk, and each row knows its hunk")
    func rowsCarryTheirHunk() {
        let file = FileDiff(
            oldPath: "x",
            newPath: "x",
            status: .modified,
            content: .text([hunk(["-a", "+A"]), hunk([" b", "+c"])])
        )
        let rows = DiffPairing.rows(for: file)
        #expect(rows.count == 3)
        #expect(rows.map(\.hunkIndex) == [0, 1, 1])
    }

    @Test("a binary file pairs to nothing rather than to an empty row")
    func binaryPairsToNothing() {
        let file = FileDiff(oldPath: "x.png", newPath: "x.png", status: .modified, content: .binary)
        #expect(DiffPairing.rows(for: file).isEmpty)
    }
}
