// Two columns out of one list of lines.
//
// # The judgement call, stated once
//
// Unified diff is a single column: a run of removals followed by a run of
// additions. Side by side needs rows, and the two runs are rarely the same
// length — three lines out, five in. Something has to decide which removal sits
// beside which addition, and what happens to the surplus.
//
// **This pairs positionally within a change block, and pads the shorter side.**
// The first removal faces the first addition, the second the second, and when
// one run runs out the remaining lines of the other get rows with an empty
// opposite side, kept at the end of that block.
//
// The alternative is similarity matching: score every removal against every
// addition and pair the closest. It reads better in exactly one case — a block
// where lines were reordered — and worse in the common one, because a "closest"
// pair chosen by score can put line 4 beside line 1 and leave the reader
// tracking a crossing they cannot see. It also needs a scoring function, a
// threshold, and a tie-break, each of which is a parameter nobody can tune
// without a corpus. Positional pairing has no parameters, is what every diff
// tool the reader already uses does at this altitude, and is wrong in a way
// that is obvious on screen rather than subtly misleading.
//
// The padding goes at the **end** of the block, never interleaved. Spreading
// the gaps to keep the columns balanced would put blank rows in the middle of a
// contiguous edit, which reads as two edits.
//
// # Why a function and not a view
//
// Because this is the part with a decision in it, and a decision that cannot be
// tested is a decision that quietly changes. The output is a plain array; the
// view that eventually draws it has no logic left to get wrong.

import Foundation

/// One row of the two-column reading: what is on the left, what is on the
/// right. Either side may be absent, never both.
struct DiffRow: Equatable {
    /// The old file's line, or `nil` where the new side added something.
    let left: DiffLine?
    /// The new file's line, or `nil` where the old side lost something.
    let right: DiffLine?

    /// Both sides carry the same unchanged line.
    var isContext: Bool { left?.origin == .context && right?.origin == .context }

    /// Nothing to compare against on the other side.
    var isUnbalanced: Bool { left == nil || right == nil }
}

enum DiffPairing {
    /// A hunk as rows for side-by-side reading.
    ///
    /// Pure, total, and order-preserving: rows come out in the order the hunk
    /// listed its lines, so a reader scrolling the pairing and a reader
    /// scrolling the raw hunk are looking at the same file in the same
    /// direction.
    static func rows(for hunk: DiffHunk) -> [DiffRow] {
        var rows: [DiffRow] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []

        // A change block ends at the first context line, or at the end of the
        // hunk. Additions before removals happen (`+` then `-` inside one
        // block is legal), and collecting both runs before emitting means the
        // order they arrived in does not change the pairing.
        func flushBlock() {
            let paired = min(removed.count, added.count)
            for index in 0..<paired {
                rows.append(DiffRow(left: removed[index], right: added[index]))
            }
            for line in removed.dropFirst(paired) {
                rows.append(DiffRow(left: line, right: nil))
            }
            for line in added.dropFirst(paired) {
                rows.append(DiffRow(left: nil, right: line))
            }
            removed.removeAll()
            added.removeAll()
        }

        for line in hunk.lines {
            switch line.origin {
            case .removed: removed.append(line)
            case .added: added.append(line)
            case .context:
                flushBlock()
                rows.append(DiffRow(left: line, right: line))
            }
        }
        flushBlock()
        return rows
    }

    /// Every hunk of a file, paired, with the hunk each row belongs to.
    ///
    /// The index travels with the row because navigation works in hunks while
    /// scrolling works in rows, and something has to translate. Recomputing it
    /// by counting rows at the call site is the kind of arithmetic that goes
    /// wrong once and stays wrong.
    static func rows(for file: FileDiff) -> [(hunkIndex: Int, row: DiffRow)] {
        file.hunks.enumerated().flatMap { index, hunk in
            rows(for: hunk).map { (hunkIndex: index, row: $0) }
        }
    }
}
