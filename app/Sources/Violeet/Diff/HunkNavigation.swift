// Where the reader is in a diff, as a value.
//
// # No wrapping, and that is the whole design
//
// Next at the last hunk stays at the last hunk. The temptation is to wrap to
// the first, because it makes the key always do something — and that is exactly
// why it is wrong here. This surface exists to review a change: "I have seen
// all of it" is the state the reader is trying to reach, and a key that silently
// sends them back to hunk 1 makes reaching it unobservable. They re-read what
// they cleared, and nothing on screen says they looped.
//
// Refusing instead gives the surface something to say — `canGoNext` is false,
// so the button dims and the key can thud — and that refusal *is* the signal.
//
// # A value, not an object
//
// Every move returns a new navigation rather than mutating one. That keeps the
// whole thing testable without a view and without a store: a test asserts the
// result of a sequence of moves, not the side effects of them. It is also what
// lets the eventual view hold this in `@State` and let SwiftUI diff it, instead
// of reaching into a controller.

import Foundation

/// The reader's position in a file's hunks.
struct HunkNavigation: Equatable {
    /// How many hunks there are to move between.
    let hunkCount: Int

    /// Which one is current, or `nil` when there are none.
    ///
    /// `nil` and not `0`, because a file with no hunks — a binary file, or an
    /// identical one — has no current hunk, and `0` would be a position that
    /// does not exist. Same reason `DiffLine` numbers its absent side `nil`.
    let index: Int?

    /// Starts at the first hunk, which is where a reader opening a diff looks.
    init(hunkCount: Int) {
        self.hunkCount = max(0, hunkCount)
        index = self.hunkCount > 0 ? 0 : nil
    }

    private init(hunkCount: Int, index: Int?) {
        self.hunkCount = hunkCount
        self.index = index
    }

    /// The position for a file, whatever its content turns out to be.
    init(file: FileDiff) {
        self.init(hunkCount: file.hunks.count)
    }

    var canGoNext: Bool {
        guard let index else { return false }
        return index + 1 < hunkCount
    }

    var canGoPrevious: Bool {
        guard let index else { return false }
        return index > 0
    }

    /// The next hunk, or the same position when there is none.
    func next() -> HunkNavigation {
        guard canGoNext, let index else { return self }
        return HunkNavigation(hunkCount: hunkCount, index: index + 1)
    }

    func previous() -> HunkNavigation {
        guard canGoPrevious, let index else { return self }
        return HunkNavigation(hunkCount: hunkCount, index: index - 1)
    }

    /// Jump straight to one, for a click on a hunk in a list.
    ///
    /// Out of range is refused rather than clamped: a caller asking for hunk 9
    /// of 3 has a stale count, and landing them on hunk 3 hides that from both
    /// of us. Refusing leaves the position where the reader left it.
    func moving(to target: Int) -> HunkNavigation {
        guard hunkCount > 0, target >= 0, target < hunkCount else { return self }
        return HunkNavigation(hunkCount: hunkCount, index: target)
    }

    /// `2 of 7`, in the numbers a person counts with.
    ///
    /// The index is 0-based because arrays are; the label is 1-based because
    /// readers are. Doing the conversion here means the view cannot forget it
    /// and no two surfaces can disagree about whether the first hunk is 0 or 1.
    var positionLabel: String? {
        guard let index else { return nil }
        return "\(index + 1) of \(hunkCount)"
    }
}
