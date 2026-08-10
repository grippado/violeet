// The product invariant: a diff is read, never written.
//
// The types are built so that mutating one is not expressible — every stored
// property is a `let`, so its key path is a `KeyPath` and not a
// `WritableKeyPath`, and that difference is observable at runtime. Which makes
// the test almost free, and an almost-free test of the invariant a whole
// feature rests on is a test worth having: the day somebody relaxes a `let` to a
// `var` to make a view easier, this suite says so before a reviewer has to
// notice.
//
// It lives in a file named after itself, and not at the bottom of
// `HunkNavigationTests.swift` where it started, because a suite that guards the
// central invariant should be findable by looking rather than by grepping.

import Testing

@testable import Violeet

@Suite("A diff cannot be edited")
struct DiffImmutabilityTests {
    /// A `var` on a struct nobody ships, whose only job is to be writable.
    ///
    /// Without it `nothingIsWritable` is a test that cannot fail: every
    /// assertion in it is negative, so an `isWritable` that returned `false` for
    /// everything — which is exactly what a change in how Swift spells
    /// `WritableKeyPath` at runtime would produce — passes the whole suite while
    /// guarding nothing.
    private struct MutableProbe: Equatable {
        var value: Int
    }

    @Test("the check can tell a writable property when it sees one")
    func detectsWritable() {
        #expect(isWritable(\MutableProbe.value), "isWritable stopped recognising a `var`")
        // And it is the writability it reads, not merely the presence of a key
        // path: a `let` on the same kind of type must come back false.
        #expect(!isWritable(\DiffLine.text))
    }

    @Test("no line, hunk or file exposes a writable property")
    func nothingIsWritable() {
        let lineKeys: [AnyKeyPath] = [
            \DiffLine.origin, \DiffLine.text, \DiffLine.oldNumber, \DiffLine.newNumber,
            \DiffLine.lacksTrailingNewline,
        ]
        let hunkKeys: [AnyKeyPath] = [
            \DiffHunk.oldStart, \DiffHunk.oldCount, \DiffHunk.newStart, \DiffHunk.newCount,
            \DiffHunk.heading, \DiffHunk.lines, \DiffHunk.isTruncated, \DiffHunk.addedCount,
            \DiffHunk.removedCount,
        ]
        let fileKeys: [AnyKeyPath] = [
            \FileDiff.oldPath, \FileDiff.newPath, \FileDiff.status, \FileDiff.content,
            \FileDiff.addedCount, \FileDiff.removedCount,
        ]
        let rowKeys: [AnyKeyPath] = [\DiffRow.left, \DiffRow.right]
        let navKeys: [AnyKeyPath] = [\HunkNavigation.hunkCount, \HunkNavigation.index]

        for key in lineKeys + hunkKeys + fileKeys + rowKeys + navKeys {
            #expect(!isWritable(key), "a property became writable: \(key)")
        }
    }

    /// A key path erased to `AnyKeyPath` keeps its writability in its dynamic
    /// type, which is how one check covers every root and value type in the
    /// module without having to name either. Reading the type's name rather
    /// than casting is what makes that possible: a cast needs both types
    /// spelled out, and there are two dozen pairs here.
    private func isWritable(_ key: AnyKeyPath) -> Bool {
        let name = String(describing: type(of: key))
        return name.hasPrefix("Writable") || name.hasPrefix("ReferenceWritable")
    }

    /// Reading a diff produces values, and the values a caller already holds do
    /// not change underneath them when it is read again.
    @Test("parsing the same patch twice gives equal, independent values")
    func parsingIsPure() {
        let patch = """
            --- a/x
            +++ b/x
            @@ -1,2 +1,2 @@
             kept
            -a
            +b
            """
        let first = UnifiedDiffParser.parse(patch)
        let second = UnifiedDiffParser.parse(patch)
        #expect(first == second)

        // Nothing downstream can reach back into what it was handed.
        let rows = DiffPairing.rows(for: first[0])
        _ = HunkNavigation(file: first[0]).next()
        #expect(first == UnifiedDiffParser.parse(patch))
        #expect(rows.isEmpty == false)
    }
}
