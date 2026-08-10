// Moving through hunks.
//
// What is pinned here is the boundary behaviour: this navigation refuses at the
// ends instead of wrapping, because "I have seen all of it" is the state a
// reviewer is trying to reach and a silent wrap makes reaching it unobservable.
//
// The product invariant that a diff is read and never written used to be tested
// at the bottom of this file, where its name did not appear on anything a
// reader browses. It lives in `DiffImmutabilityTests.swift` now.

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

    @Test("a file with no name at all still has a path to show, even an empty one")
    func displayPathWithNeitherSide() {
        // Not reachable from the parser — it refuses a file with no path — but
        // `FileDiff` is constructible by hand and a crash here would be a crash
        // in a header.
        let nameless = FileDiff(
            oldPath: nil, newPath: nil, status: .modified, content: .text([]))
        #expect(nameless.displayPath == "")
        #expect(HunkNavigation(file: nameless).index == nil)
    }

    @Test("jumping inside an empty diff refuses instead of inventing a hunk")
    func movingWithNoHunks() {
        let nav = HunkNavigation(hunkCount: 0)
        #expect(nav.moving(to: 0) == nav)
        #expect(nav.moving(to: 1) == nav)
        #expect(nav.moving(to: 0).index == nil)
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
