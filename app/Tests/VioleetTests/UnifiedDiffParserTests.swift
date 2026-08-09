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

    @Test("a malformed hunk header is skipped, not fatal")
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
        #expect(file.hunks.count == 1)
        #expect(file.hunks[0].lines.count == 2)
    }
}
