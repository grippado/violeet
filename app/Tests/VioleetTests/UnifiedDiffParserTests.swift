// Parsing a patch, with the awkward shapes as literals.
//
// Every case in here is a string, not a repository. That is the point of the
// parser taking text: the file with no trailing newline, the binary blob, the
// deletion — each is a fixture somebody can read, instead of a `git init` in a
// temporary directory that has to be built before it can be believed.
//
// The cases that earn their place are the ones a naive parser gets wrong: a new
// file (no old side), a deletion (no new side), a missing newline marker that
// belongs to the line above it, two hunks with no context between them, and a
// binary file that has no lines at all.

import Testing

@testable import Violeet

@Suite("Unified diff parsing")
struct UnifiedDiffParserTests {
    // MARK: - The ordinary case

    @Test("a modification yields hunks with numbers on both sides")
    func modification() {
        let patch = """
            diff --git a/src/main.rs b/src/main.rs
            index 1111111..2222222 100644
            --- a/src/main.rs
            +++ b/src/main.rs
            @@ -10,3 +10,4 @@ fn main() {
                 let a = 1;
            -    let b = 2;
            +    let b = 3;
            +    let c = 4;
                 println!("{a}");
            """

        let files = UnifiedDiffParser.parse(patch)
        #expect(files.count == 1)
        let file = files[0]
        #expect(file.oldPath == "src/main.rs")
        #expect(file.newPath == "src/main.rs")
        #expect(file.status == .modified)
        #expect(file.hunks.count == 1)

        let hunk = file.hunks[0]
        #expect(hunk.oldStart == 10)
        #expect(hunk.newStart == 10)
        #expect(hunk.heading == "fn main() {")
        #expect(hunk.lines.count == 5)
        #expect(hunk.addedCount == 2)
        #expect(hunk.removedCount == 1)

        // The prefix is transport and must not survive into the content.
        #expect(hunk.lines.map(\.text) == [
            "    let a = 1;",
            "    let b = 2;",
            "    let b = 3;",
            "    let c = 4;",
            "    println!(\"{a}\");",
        ])

        // A removed line has no number on the new side, and vice versa.
        let removed = hunk.lines[1]
        #expect(removed.origin == .removed)
        #expect(removed.oldNumber == 11)
        #expect(removed.newNumber == nil)
        let added = hunk.lines[2]
        #expect(added.origin == .added)
        #expect(added.oldNumber == nil)
        #expect(added.newNumber == 11)
        // Context after two insertions has advanced further on the new side.
        #expect(hunk.lines[4].oldNumber == 12)
        #expect(hunk.lines[4].newNumber == 13)
    }

    @Test("a hunk header with no count means one line")
    func impliedSingleLineCount() {
        let patch = """
            --- a/x
            +++ b/x
            @@ -1 +1 @@
            -old
            +new
            """
        let hunk = UnifiedDiffParser.parse(patch)[0].hunks[0]
        #expect(hunk.oldCount == 1)
        #expect(hunk.newCount == 1)
        #expect(hunk.lines.count == 2)
    }

    // MARK: - The awkward shapes

    @Test("a new file has no old path and says so")
    func newFile() {
        let patch = """
            diff --git a/notes/new.md b/notes/new.md
            new file mode 100644
            index 0000000..3333333
            --- /dev/null
            +++ b/notes/new.md
            @@ -0,0 +1,2 @@
            +one
            +two
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.status == .added)
        #expect(file.oldPath == nil)
        #expect(file.newPath == "notes/new.md")
        #expect(file.displayPath == "notes/new.md")
        #expect(file.hunks[0].lines.allSatisfy { $0.origin == .added })
        #expect(file.hunks[0].lines.allSatisfy { $0.oldNumber == nil })
    }

    @Test("a deleted file keeps the only path it has")
    func deletedFile() {
        let patch = """
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            index 4444444..0000000
            --- a/gone.txt
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -one
            -two
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.status == .removed)
        #expect(file.newPath == nil)
        // The header still has a name to show, which is when the reader most
        // needs one.
        #expect(file.displayPath == "gone.txt")
        #expect(file.removedCount == 2)
    }

    @Test("the no-newline marker lands on the line above it, not on a line of its own")
    func missingTrailingNewline() {
        let patch = """
            --- a/x
            +++ b/x
            @@ -1,2 +1,2 @@
             kept
            -last
            \\ No newline at end of file
            +last!
            \\ No newline at end of file
            """
        let hunk = UnifiedDiffParser.parse(patch)[0].hunks[0]
        // Three lines, not five: the marker is a property, not content.
        #expect(hunk.lines.count == 3)
        #expect(hunk.lines[0].lacksTrailingNewline == false)
        #expect(hunk.lines[1].text == "last")
        #expect(hunk.lines[1].lacksTrailingNewline)
        #expect(hunk.lines[2].text == "last!")
        #expect(hunk.lines[2].lacksTrailingNewline)
    }

    @Test("adjacent hunks stay two hunks")
    func adjacentHunks() {
        let patch = """
            --- a/x
            +++ b/x
            @@ -1,1 +1,1 @@
            -a
            +A
            @@ -2,1 +2,1 @@
            -b
            +B
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.hunks.count == 2)
        #expect(file.hunks[0].lines.count == 2)
        #expect(file.hunks[1].oldStart == 2)
        #expect(file.hunks[1].lines.map(\.text) == ["b", "B"])
    }

    @Test("a binary file is a different sentence from an empty diff")
    func binaryFile() {
        let patch = """
            diff --git a/logo.png b/logo.png
            index 5555555..6666666 100644
            Binary files a/logo.png and b/logo.png differ
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.isBinary)
        #expect(file.content == .binary)
        #expect(file.hunks.isEmpty)
        #expect(file.displayPath == "logo.png")

        // A text file with no hunks must not be mistaken for it.
        let empty = FileDiff(oldPath: "x", newPath: "x", status: .modified, content: .text([]))
        #expect(empty.isBinary == false)
        #expect(empty.hunks.isEmpty)
        #expect(empty.content != file.content)
    }

    @Test("an opaque git binary patch counts as binary too")
    func gitBinaryPatch() {
        let patch = """
            diff --git a/blob.bin b/blob.bin
            index 7777777..8888888 100644
            GIT binary patch
            literal 12
            TcmZQzU|?
            """
        #expect(UnifiedDiffParser.parse(patch)[0].isBinary)
    }

    @Test("a rename carries both names")
    func rename() {
        let patch = """
            diff --git a/old/name.swift b/new/name.swift
            similarity index 92%
            rename from old/name.swift
            rename to new/name.swift
            --- a/old/name.swift
            +++ b/new/name.swift
            @@ -1,1 +1,1 @@
            -a
            +b
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.status == .renamed)
        #expect(file.oldPath == "old/name.swift")
        #expect(file.newPath == "new/name.swift")
    }

    // MARK: - Several files, and producers that are not git

    @Test("one patch, several files, in the order it listed them")
    func severalFiles() {
        let patch = """
            diff --git a/first.txt b/first.txt
            --- a/first.txt
            +++ b/first.txt
            @@ -1,1 +1,1 @@
            -a
            +A
            diff --git a/second.txt b/second.txt
            deleted file mode 100644
            --- a/second.txt
            +++ /dev/null
            @@ -1,1 +0,0 @@
            -gone
            diff --git a/third.png b/third.png
            Binary files a/third.png and b/third.png differ
            """
        let files = UnifiedDiffParser.parse(patch)
        #expect(files.map(\.displayPath) == ["first.txt", "second.txt", "third.png"])
        #expect(files.map(\.status) == [.modified, .removed, .modified])
        #expect(files[2].isBinary)
    }

    @Test("plain diff -u output, with timestamps and no git header")
    func plainUnifiedDiff() {
        let patch = """
            --- old/x.txt\t2026-08-09 10:00:00.000000000 -0300
            +++ new/x.txt\t2026-08-09 10:01:00.000000000 -0300
            @@ -1,2 +1,2 @@
             kept
            -a
            +b
            --- old/y.txt\t2026-08-09 10:00:00.000000000 -0300
            +++ new/y.txt\t2026-08-09 10:01:00.000000000 -0300
            @@ -1,1 +1,1 @@
            -c
            +d
            """
        let files = UnifiedDiffParser.parse(patch)
        // Two `---` lines with no `diff --git` between them are two files, and
        // the timestamp is not part of either name.
        #expect(files.count == 2)
        #expect(files.map(\.displayPath) == ["new/x.txt", "new/y.txt"])
    }

    @Test("an empty context line is context, not the end of the hunk")
    func emptyContextLine() {
        // Some producers strip the trailing space from a blank context line.
        let patch = "--- a/x\n+++ b/x\n@@ -1,3 +1,3 @@\n one\n\n-two\n+TWO\n"
        let hunk = UnifiedDiffParser.parse(patch)[0].hunks[0]
        #expect(hunk.lines.count == 4)
        #expect(hunk.lines[1].origin == .context)
        #expect(hunk.lines[1].text == "")
    }

    @Test("carriage returns are transport, not content")
    func carriageReturns() {
        let patch = "--- a/x\r\n+++ b/x\r\n@@ -1,1 +1,1 @@\r\n-a\r\n+b\r\n"
        let hunk = UnifiedDiffParser.parse(patch)[0].hunks[0]
        #expect(hunk.lines.map(\.text) == ["a", "b"])
    }

    // MARK: - Recovering rather than rejecting

    @Test("nothing that looks like a diff yields nothing, and does not crash")
    func nonsenseYieldsNothing() {
        for text in ["", "   ", "just some prose\nover two lines", "@@ -1,1 +1,1 @@\n-a\n+b"] {
            _ = UnifiedDiffParser.parse(text)
        }
        #expect(UnifiedDiffParser.parse("").isEmpty)
        #expect(UnifiedDiffParser.parse("just some prose").isEmpty)
        // A hunk with no file header above it has no file to belong to.
        #expect(UnifiedDiffParser.parse("@@ -1,1 +1,1 @@\n-a\n+b").isEmpty)
    }

    @Test("a truncated hunk keeps what it got and does not eat the next file")
    func truncatedHunk() {
        // The header promises four old lines; the patch was cut after one.
        let patch = """
            --- a/x
            +++ b/x
            @@ -1,4 +1,4 @@
             one
            diff --git a/y b/y
            --- a/y
            +++ b/y
            @@ -1,1 +1,1 @@
            -c
            +d
            """
        let files = UnifiedDiffParser.parse(patch)
        #expect(files.count == 2)
        #expect(files[0].hunks[0].lines.count == 1)
        #expect(files[1].displayPath == "y")
        #expect(files[1].hunks[0].lines.count == 2)
    }

    @Test("a malformed hunk header is not fatal, and not silent either")
    func malformedHunkHeader() {
        let patch = """
            --- a/x
            +++ b/x
            @@ nonsense @@
            @@ -1,1 +1,1 @@
            -a
            +b
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        // The file survives, with its name. What it does not do is come back
        // looking like a complete diff of one hunk when the patch described two:
        // showing the readable half without saying the other half was lost is
        // the failure this marker exists for.
        #expect(file.displayPath == "x")
        #expect(file.isPartial)
        #expect(file.unsupportedReason != nil)
        #expect(file.hunks.isEmpty)
    }

    @Test("several malformed headers in a row still produce one honest file")
    func severalMalformedHunkHeaders() {
        let patch = """
            --- a/x
            +++ b/x
            @@ nonsense @@
            @@ also nonsense @@
            @@ -oops +oops @@
            """
        let files = UnifiedDiffParser.parse(patch)
        #expect(files.count == 1)
        #expect(files[0].isPartial)
        // First reason wins; a reader does not need to be told three times.
        #expect(files[0].unsupportedReason == UnifiedDiffParser.badHunkHeaderReason)
    }

    // MARK: - Saying "we could not read this"

    @Test("a conflicted merge is not a file without changes")
    func combinedDiff() {
        // Verbatim `git diff` output from a merge that conflicted.
        let patch = """
            diff --cc f.txt
            index 797be14,0c02ccc..0000000
            --- a/f.txt
            +++ b/f.txt
            @@@ -1,3 -1,3 +1,7 @@@
              a
            ++<<<<<<< HEAD
             +Y
            ++=======
            + X
            ++>>>>>>> side
              c
            """
        let files = UnifiedDiffParser.parse(patch)
        #expect(files.count == 1)
        let file = files[0]
        #expect(file.displayPath == "f.txt")
        // The whole point: this must not be `.text([])`, which is what an
        // unchanged file produces.
        #expect(file.content != .text([]))
        #expect(file.content == .unsupported(reason: UnifiedDiffParser.combinedReason))
        #expect(file.isPartial)
        #expect(file.isBinary == false)
    }

    @Test("a combined hunk header alone is enough to know we cannot show it")
    func combinedHunkHeaderWithoutCcHeader() {
        // `git diff -c` and pasted fragments reach us without the `diff --cc`.
        let patch = """
            --- a/f.txt
            +++ b/f.txt
            @@@ -1,3 -1,3 +1,7 @@@
              a
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.content == .unsupported(reason: UnifiedDiffParser.combinedReason))
    }

    @Test("a mode change is a change, and does not read as an identical file")
    func modeOnlyChange() {
        let patch = """
            diff --git a/run.sh b/run.sh
            old mode 100644
            new mode 100755
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.displayPath == "run.sh")
        #expect(file.content == .unsupported(reason: UnifiedDiffParser.modeOnlyReason))
    }

    @Test("a rename with no hunk at all is an empty text diff, not a failure")
    func renameWithoutHunks() {
        // git omits the `@@` entirely at 100% similarity. This is the shape that
        // used to be indistinguishable from "we could not read the file".
        let patch = """
            diff --git a/old/name.swift b/new/name.swift
            similarity index 100%
            rename from old/name.swift
            rename to new/name.swift
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.status == .renamed)
        #expect(file.oldPath == "old/name.swift")
        #expect(file.newPath == "new/name.swift")
        // Empty *and* honest: the patch really said the text did not change.
        #expect(file.content == .text([]))
        #expect(file.isPartial == false)
        #expect(file.unsupportedReason == nil)
        #expect(file.addedCount == 0)

        // And it is a different value from a file we failed to read, which is
        // the whole distinction.
        let unreadable = FileDiff(
            oldPath: "old/name.swift", newPath: "new/name.swift", status: .renamed,
            content: .unsupported(reason: "nope"))
        #expect(unreadable.content != file.content)
        #expect(unreadable.isPartial)
    }

    @Test("a hunk cut off by the end of the text says it was cut off")
    func truncatedByEndOfText() {
        let patch = """
            --- a/x
            +++ b/x
            @@ -1,4 +1,4 @@
             one
            -two
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.hunks.count == 1)
        #expect(file.hunks[0].lines.count == 2)
        // The header promised four lines each side and the text ended. Before
        // this flag existed, that returned a hunk indistinguishable from a
        // complete one.
        #expect(file.hunks[0].isTruncated)
        #expect(file.isPartial)
    }

    @Test("a hunk that spends its counts exactly is not truncated")
    func completeHunkIsNotTruncated() {
        let patch = """
            --- a/x
            +++ b/x
            @@ -1,2 +1,2 @@
             kept
            -a
            +b
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.hunks[0].isTruncated == false)
        #expect(file.isPartial == false)
    }

    @Test("a truncated hunk does not eat the next file in a patch with no git header")
    func truncatedHunkWithoutGitHeader() {
        // The `diff -u` form of `truncatedHunk`. `--- ` and `+++ ` begin with
        // `-` and `+`, so before the fix they were read as a removal and an
        // addition: file `y` vanished and its header became two lines of `x`.
        let patch = """
            --- old/x\t2026-08-09 12:00:00
            +++ new/x\t2026-08-09 12:00:00
            @@ -1,4 +1,4 @@
             one
            --- old/y\t2026-08-09 12:00:00
            +++ new/y\t2026-08-09 12:00:00
            @@ -1 +1 @@
            -c
            +d
            """
        let files = UnifiedDiffParser.parse(patch)
        #expect(files.count == 2)
        #expect(files.map(\.displayPath) == ["new/x", "new/y"])
        #expect(files[0].hunks[0].lines.map(\.text) == ["one"])
        #expect(files[0].hunks[0].isTruncated)
        #expect(files[1].hunks[0].lines.map(\.text) == ["c", "d"])
        #expect(files[1].hunks[0].isTruncated == false)
    }

    @Test("a removed line that looks like a header is still a removed line")
    func bodyLineLookingLikeAHeader() {
        // `-- x` removed arrives as `--- x`. Only the `---`/`+++` *pair* means a
        // file boundary, so this must stay content.
        let patch = """
            --- a/q.sql
            +++ b/q.sql
            @@ -1,2 +1,2 @@
            --- a comment
             select 1
            +++ a comment
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.displayPath == "q.sql")
        #expect(file.hunks.count == 1)
        #expect(file.hunks[0].lines.map(\.text) == ["-- a comment", "select 1", "++ a comment"])
    }

    // MARK: - Paths that are not simple

    @Test("a quoted path with a space keeps its space")
    func quotedPathWithSpace() {
        let patch = """
            diff --git "a/dir/my file.txt" "b/dir/my file.txt"
            --- "a/dir/my file.txt"
            +++ "b/dir/my file.txt"
            @@ -1 +1 @@
            -a
            +b
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.displayPath == "dir/my file.txt")
        #expect(file.oldPath == "dir/my file.txt")
    }

    @Test("an unquoted path with a space is split on the b/, as the comment says")
    func unquotedPathWithSpace() {
        // No `---`/`+++` here, so the `diff --git` line is the only source and
        // its splitting is observable.
        let patch = "diff --git a/my file.txt b/my file.txt\nnew file mode 100644\n"
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.displayPath == "my file.txt")
        #expect(file.oldPath == "my file.txt")
    }

    @Test("an accented path arrives with its accents, not with git's octal escapes")
    func quotedPathWithOctalEscapes() {
        // What `git diff` writes for `src/coração.swift`.
        let patch = """
            diff --git "a/src/cora\\303\\247\\303\\243o.swift" "b/src/cora\\303\\247\\303\\243o.swift"
            --- "a/src/cora\\303\\247\\303\\243o.swift"
            +++ "b/src/cora\\303\\247\\303\\243o.swift"
            @@ -1 +1 @@
            -a
            +b
            """
        let file = UnifiedDiffParser.parse(patch)[0]
        #expect(file.displayPath == "src/coração.swift")
    }

    @Test("a real directory named a keeps its name")
    func pathBeginningWithA() {
        // `stripPrefix` removes exactly one leading component, which is right
        // because git writes a real `a/` directory as `a/a/…`. Pinned so the
        // known-wrong case — a bare `--- a/thing` for a file genuinely at
        // `a/thing` in a patch with no git header — is documented rather than
        // discovered.
        let patch = """
            diff --git a/a/thing.txt b/a/thing.txt
            --- a/a/thing.txt
            +++ b/a/thing.txt
            @@ -1 +1 @@
            -x
            +y
            """
        #expect(UnifiedDiffParser.parse(patch)[0].displayPath == "a/thing.txt")
    }

    // MARK: - Headers that arrive alone

    @Test("a +++ with no --- above it belongs to nothing and loses nothing")
    func orphanNewPath() {
        let patch = """
            +++ b/x
            @@ -1 +1 @@
            -a
            +b
            """
        // No file was ever opened, so there is nothing to attach the hunk to and
        // nothing is invented.
        #expect(UnifiedDiffParser.parse(patch).isEmpty)
    }

    @Test("two --- in a row are two files, the first with nothing to show")
    func twoOldPathsInARow() {
        let patch = """
            --- a/x
            --- a/y
            +++ b/y
            @@ -1 +1 @@
            -a
            +b
            """
        let files = UnifiedDiffParser.parse(patch)
        #expect(files.count == 2)
        #expect(files[0].oldPath == "x")
        #expect(files[0].newPath == nil)
        #expect(files[0].status == .removed)
        #expect(files[1].displayPath == "y")
        #expect(files[1].hunks.count == 1)
    }
}
