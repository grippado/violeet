// What a diff *is*, before anything draws one.
//
// # Reading, never writing
//
// A diff in this app is a report. It says what changed; it is not a handle on
// the file, and it must not become one. Every property in here is a `let`, no
// type offers a mutating member, and nothing carries a URL or a file handle a
// view could be tempted to write through. The only writes this product will
// ever do to a working tree are "take this side" during conflict resolution,
// and that is a separate surface with its own confirmation — not a side effect
// of looking at a hunk.
//
// The point of spelling it out in the types is that it stops being a rule
// somebody has to remember. There is no API to misuse: a reviewer does not have
// to check whether a view mutated a line, because a line cannot be mutated.
//
// # Where the text comes from, and why not from the daemon
//
// The panel's `+12 −3` comes off the socket, out of the transcript's
// `structuredPatch`, and the daemon sums it to two integers before it ever
// leaves the crate. That is the right shape for a count and the wrong shape for
// content: it says how many lines moved, never which. So it cannot feed this.
//
// The intended producer is `git diff`, run by the app for the file the reader
// has in front of them — the same boundary `FileHistory` already argued for
// when it ran `git log -1` for an editor tab. `SessionFileList`'s rule is about
// the *daemon's numbers*: the app must not become a second opinion on a count
// the daemon watched being made. Asking git what a file's uncommitted change
// looks like is not a second opinion on anything; the daemon was never asked
// and has no answer to disagree with.
//
// Nothing in this file knows that, though, and that is deliberate. It parses
// unified diff text. Whether that text came from `git diff`, from `git diff
// --cached`, from a `.patch` on disk or from a conflict rehearsal in LAB-26,
// the parse is the same and the tests need no repository.

import Foundation

/// Where one line of a diff came from.
///
/// Three cases and no fourth. A "changed" line does not exist in unified diff
/// and inventing one here would mean guessing which removal pairs with which
/// addition at parse time, which is a decision with real trade-offs that
/// belongs in `DiffPairing`, where it can be swapped without touching what the
/// parser recorded.
enum DiffLineOrigin: Equatable {
    /// Present in both sides, unchanged.
    case context
    /// Only in the new side.
    case added
    /// Only in the old side.
    case removed
}

/// One line of one hunk, with its place on both sides.
///
/// Line numbers are `Int?` rather than `0` for "absent" because a removed line
/// genuinely has no number on the new side, and a gutter that prints `0` there
/// is a gutter that lies. Absent is not zero, the same distinction
/// `SessionFileList` draws between a list that is empty and a list we never
/// saw.
struct DiffLine: Equatable {
    let origin: DiffLineOrigin

    /// The line's content, with the `+`, `-` or space prefix already removed.
    ///
    /// Stripped here rather than in a view: the prefix is diff transport, not
    /// content, and a view that has to strip it is a view that will forget to
    /// when it copies to the clipboard.
    let text: String

    /// Its number in the old file, when it has one.
    let oldNumber: Int?

    /// Its number in the new file, when it has one.
    let newNumber: Int?

    /// The file ends here, without a trailing newline.
    ///
    /// Git says this with a `\ No newline at end of file` line *after* the line
    /// it applies to. Carried on the line rather than kept as a pseudo-line
    /// because it is a property of that line, and a pseudo-line would have to
    /// be filtered out by every consumer — pairing, navigation, copy — each of
    /// which is a place to forget.
    let lacksTrailingNewline: Bool

    init(
        origin: DiffLineOrigin,
        text: String,
        oldNumber: Int? = nil,
        newNumber: Int? = nil,
        lacksTrailingNewline: Bool = false
    ) {
        self.origin = origin
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.lacksTrailingNewline = lacksTrailingNewline
    }
}

/// One `@@` block: a stretch of the file the change actually touches.
struct DiffHunk: Equatable {
    /// First line of the block in the old file, 1-based as git counts.
    let oldStart: Int
    /// How many old lines the block spans. `0` for a pure insertion.
    let oldCount: Int
    let newStart: Int
    let newCount: Int

    /// What git prints after the closing `@@` — usually the enclosing
    /// function. Kept because it is the cheapest orientation a reader gets when
    /// a hunk scrolls past its own context, and it costs a string.
    let heading: String

    let lines: [DiffLine]

    init(
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        heading: String = "",
        lines: [DiffLine]
    ) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.heading = heading
        self.lines = lines
    }

    /// Lines that are not context, which is what a `+n −n` for this hunk counts.
    var addedCount: Int { lines.filter { $0.origin == .added }.count }
    var removedCount: Int { lines.filter { $0.origin == .removed }.count }
}

/// What happened to a file, as the diff header declares it.
///
/// Derived from the header and from `/dev/null`, never from the hunks: a patch
/// that replaces every line of a file is a modification, and counting lines to
/// decide would call it a rewrite.
enum DiffFileStatus: Equatable {
    case added
    case removed
    case modified
    /// Moved, possibly with edits. The old path is on `FileDiff.oldPath`.
    case renamed
}

/// A file's diff, or the honest admission that it has none to show.
enum DiffContent: Equatable {
    /// Hunks, in the order the patch listed them.
    case text([DiffHunk])

    /// Git refused to diff it, or emitted an opaque binary patch.
    ///
    /// A case rather than an empty hunk list, because "binary, nothing to show"
    /// and "text, identical" are different sentences and the surface has to say
    /// different things for them. Folding them together is how a reader ends up
    /// staring at an empty pane wondering whether it is broken.
    case binary
}

/// One file, as one diff describes it.
struct FileDiff: Equatable {
    /// Path on the old side. `nil` when the file is new.
    let oldPath: String?
    /// Path on the new side. `nil` when the file was deleted.
    let newPath: String?
    let status: DiffFileStatus
    let content: DiffContent

    init(oldPath: String?, newPath: String?, status: DiffFileStatus, content: DiffContent) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.content = content
    }

    /// The path to put on a header, preferring where the file is now.
    ///
    /// A deleted file only has an old path, and showing an empty header for it
    /// would be the one case where the reader most needs the name.
    var displayPath: String { newPath ?? oldPath ?? "" }

    var hunks: [DiffHunk] {
        if case .text(let hunks) = content { return hunks }
        return []
    }

    var isBinary: Bool { content == .binary }

    var addedCount: Int { hunks.reduce(0) { $0 + $1.addedCount } }
    var removedCount: Int { hunks.reduce(0) { $0 + $1.removedCount } }
}
