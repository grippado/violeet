// Moving through hunks, and the invariant that nothing moves the file.
//
// Two things are pinned here. The first is the boundary behaviour: this
// navigation refuses at the ends instead of wrapping, because "I have seen all
// of it" is the state a reviewer is trying to reach and a silent wrap makes
// reaching it unobservable.
//
// The second is the product invariant, and it is the reason the last suite in
// this file exists at all: **a diff is read, never written**. The types are
// built so that mutating one is not expressible — every stored property is a
// `let`, so its key path is a `KeyPath` and not a `WritableKeyPath`, and that
// difference is observable at runtime. Which makes the test almost free, and an
// almost-free test of the invariant a whole feature rests on is a test worth
// having: the day somebody relaxes a `let` to a `var` to make a view easier,
// this suite says so before a reviewer has to notice.

import Testing

@testable import Violeet

@Suite("Hunk navigation")
struct HunkNavigationTests {
    @Test("a fresh navigation starts at the first hunk")
    func startsAtTheFirst() {
        let nav = HunkNavigation(hunkCount: 3)
        #expect(nav.index == 0)
        #expect(nav.canGoPrevious == false)
        #expect(nav.canGoNext)
        #expect(nav.positionLabel == "1 of 3")
    }

    @Test("a file with no hunks has no position at all")
    func noHunksNoPosition() {
        let nav = HunkNavigation(hunkCount: 0)
        // `nil` and not `0`: there is no hunk 1 to be at.
        #expect(nav.index == nil)
        #expect(nav.positionLabel == nil)
        #expect(nav.canGoNext == false)
        #expect(nav.canGoPrevious == false)
        #expect(nav.next() == nav)
        #expect(nav.previous() == nav)
    }

    @Test("next and previous walk the hunks")
    func walking() {
        var nav = HunkNavigation(hunkCount: 3)
        nav = nav.next()
        #expect(nav.index == 1)
        #expect(nav.positionLabel == "2 of 3")
        nav = nav.next()
        #expect(nav.index == 2)
        nav = nav.previous().previous()
        #expect(nav.index == 0)
    }

    @Test("the ends refuse rather than wrap")
    func endsRefuse() {
        let last = HunkNavigation(hunkCount: 2).next()
        #expect(last.index == 1)
        #expect(last.canGoNext == false)
        // Wrapping here would send the reader back to hunk 1 with nothing on
        // screen saying they looped.
        #expect(last.next() == last)

        let first = HunkNavigation(hunkCount: 2)
        #expect(first.previous() == first)
    }

    @Test("a single hunk is both ends at once")
    func singleHunk() {
        let nav = HunkNavigation(hunkCount: 1)
        #expect(nav.positionLabel == "1 of 1")
        #expect(nav.canGoNext == false)
        #expect(nav.canGoPrevious == false)
    }

    @Test("jumping out of range leaves the reader where they were")
    func jumpingOutOfRange() {
        let nav = HunkNavigation(hunkCount: 3).next()
        #expect(nav.moving(to: 2).index == 2)
        // A caller with a stale count is a bug to surface, not to clamp away.
        #expect(nav.moving(to: 9) == nav)
        #expect(nav.moving(to: -1) == nav)
    }

    @Test("a negative count is an empty diff, not a crash")
    func negativeCount() {
        let nav = HunkNavigation(hunkCount: -4)
        #expect(nav.hunkCount == 0)
        #expect(nav.index == nil)
    }

    @Test("navigation takes its count from the file, binary included")
    func fromAFile() {
        let text = FileDiff(
            oldPath: "x",
            newPath: "x",
            status: .modified,
            content: .text([
                DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, lines: []),
                DiffHunk(oldStart: 5, oldCount: 1, newStart: 5, newCount: 1, lines: []),
            ])
        )
        #expect(HunkNavigation(file: text).hunkCount == 2)

        let binary = FileDiff(oldPath: "x", newPath: "x", status: .modified, content: .binary)
        #expect(HunkNavigation(file: binary).index == nil)
    }

    @Test("moving does not touch what came before it")
    func movingIsAValue() {
        let start = HunkNavigation(hunkCount: 3)
        let moved = start.next().next()
        // Value semantics, asserted rather than assumed: a view holding the
        // old position must keep it.
        #expect(start.index == 0)
        #expect(moved.index == 2)
    }
}

@Suite("A diff cannot be edited")
struct DiffImmutabilityTests {
    /// A `let` property's key path is a `KeyPath`; a `var`'s is a
    /// `WritableKeyPath`. The cast is the assertion.
    @Test("no line, hunk or file exposes a writable property")
    func nothingIsWritable() {
        let lineKeys: [AnyKeyPath] = [
            \DiffLine.origin, \DiffLine.text, \DiffLine.oldNumber, \DiffLine.newNumber,
            \DiffLine.lacksTrailingNewline,
        ]
        let hunkKeys: [AnyKeyPath] = [
            \DiffHunk.oldStart, \DiffHunk.oldCount, \DiffHunk.newStart, \DiffHunk.newCount,
            \DiffHunk.heading, \DiffHunk.lines,
        ]
        let fileKeys: [AnyKeyPath] = [
            \FileDiff.oldPath, \FileDiff.newPath, \FileDiff.status, \FileDiff.content,
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
    /// spelled out, and there are eighteen pairs here.
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
