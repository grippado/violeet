// The directory tree's model: what is in a folder, in what order, and what it
// says when it cannot look.
//
// `ordered` is a pure function and tested as one. `read` touches the disk, so
// it is tested against a directory this file builds and removes — the syscall
// is the thing under test, and a fixture of fake `DirectoryEntry`s would test
// the sorting a second time instead.

import Foundation
import Testing

@testable import Violeet

@Suite("Directory listing")
struct DirectoryListingTests {
    /// A directory of our own, so no test depends on what is on the machine.
    private func inTemporaryDirectory(_ body: (String) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("violeet-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path)
    }

    private func makeFile(_ name: String, in directory: String) throws {
        try Data().write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func makeDirectory(_ name: String, in directory: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory).appendingPathComponent(name),
            withIntermediateDirectories: true
        )
    }

    /// A link with a *relative* destination, which is what `ln -s` writes and
    /// what the symlink cases below need: an absolute destination would hide
    /// whether resolution happens against the link's own directory.
    /// `destination` is stored verbatim and is not required to exist — that is
    /// how the broken and circular cases are built.
    private func makeSymlink(_ name: String, to destination: String, in directory: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: URL(fileURLWithPath: directory).appendingPathComponent(name).path,
            withDestinationPath: destination
        )
    }

    // MARK: - Ordering

    /// Structure before content. A listing that interleaves them makes the
    /// reader scan the whole thing to find out what can be opened.
    @Test("directories come before files")
    func directoriesFirst() {
        let entries = [
            DirectoryEntry(name: "a.swift", path: "/x/a.swift", isDirectory: false),
            DirectoryEntry(name: "zebra", path: "/x/zebra", isDirectory: true),
        ]
        let ordered = DirectoryListing.ordered(entries)
        #expect(ordered.map(\.name) == ["zebra", "a.swift"], "a folder sorts above a file even when its name sorts below")
    }

    /// `localizedStandardCompare`, not `<`. Byte order puts `v10` before `v2`
    /// and every capital ahead of every lowercase, which is a listing nobody
    /// scans successfully.
    @Test("names sort the way a person reads them")
    func humanOrdering() {
        let entries = ["v2", "v10", "Beta", "alpha"].map {
            DirectoryEntry(name: $0, path: "/x/\($0)", isDirectory: false)
        }
        let names = DirectoryListing.ordered(entries).map(\.name)
        #expect(names == ["alpha", "Beta", "v2", "v10"])
    }

    // MARK: - Hidden

    /// Hidden means a dotfile, because the button sits beside a shell prompt and
    /// that is what it means there.
    @Test("dotfiles are out unless asked for")
    func hiddenAreFilteredByDefault() throws {
        try inTemporaryDirectory { root in
            try makeFile("visible.txt", in: root)
            try makeFile(".hidden", in: root)
            try makeDirectory(".git", in: root)

            let plain = DirectoryListing.read(root, includingHidden: false)
            #expect(plain.entries.map(\.name) == ["visible.txt"])

            let all = DirectoryListing.read(root, includingHidden: true)
            #expect(all.entries.map(\.name) == [".git", ".hidden", "visible.txt"], "and the folder still sorts first")
        }
    }

    @Test("a dotfile knows it is one")
    func hiddenFlag() {
        #expect(DirectoryEntry(name: ".zshrc", path: "/x/.zshrc", isDirectory: false).isHidden)
        #expect(!DirectoryEntry(name: "zshrc", path: "/x/zshrc", isDirectory: false).isHidden)
    }

    // MARK: - Reading

    @Test("a directory is read with its folders marked")
    func readsAndMarksDirectories() throws {
        try inTemporaryDirectory { root in
            try makeDirectory("src", in: root)
            try makeFile("README.md", in: root)

            let contents = DirectoryListing.read(root, includingHidden: false)
            #expect(!contents.unreadable)
            #expect(contents.entries.count == 2)
            #expect(contents.entries[0].name == "src")
            #expect(contents.entries[0].isDirectory)
            #expect(!contents.entries[1].isDirectory)
            #expect(contents.entries[1].path.hasSuffix("/README.md"), "the path is absolute, because the editor gets it")
        }
    }

    /// The distinction the whole panel is built around, one layer down. An
    /// empty directory and one the account cannot open are different facts, and
    /// a tree that draws both as nothing tells the reader the wrong one.
    @Test("unreadable is not empty")
    func unreadableIsNotEmpty() throws {
        try inTemporaryDirectory { root in
            let empty = DirectoryListing.read(root, includingHidden: true)
            #expect(empty.isEmpty)
            #expect(!empty.unreadable, "an empty directory was read successfully")

            let missing = DirectoryListing.read(root + "/nowhere", includingHidden: true)
            #expect(missing.isEmpty)
            #expect(missing.unreadable, "a directory that will not open must say so")
        }
    }

    /// A symlink to a directory expands like the directory it points at, which
    /// is what the name in the tree looks like it should do.
    ///
    /// # This test passed by accident for months. Do not simplify it back.
    ///
    /// It was written as `#expect(link?.isDirectory == true)`, and under the
    /// `swift-testing` package this repository still depends on, **that form
    /// cannot fail**. Measured, in this very package: `#expect(x == true)` and
    /// `#expect(x == false)` are swallowed for *any* operand — optional or not,
    /// `#expect(true == false)` passes — while `#expect(n == 2)` on an `Int` and
    /// a bare `#expect(b)` report failure correctly. Comparing against a `Bool`
    /// literal was the trap.
    ///
    /// So this test never checked anything. The production code it guarded was
    /// wrong the whole time: a `stderr` probe inside the test host printed
    /// `isDirectory -> false` for this exact link while the test reported a
    /// pass, and `URL.resourceValues(forKeys: [.isDirectoryKey])` answers
    /// `false` for every symlink in every process we tried — test host,
    /// compiled binary, and `swift` script alike. The Files panel really was
    /// drawing a link to a directory as a file, on main, for real users.
    ///
    /// Hence the shape below, in every symlink case in this file: unwrap with
    /// `#require`, then assert a plain `Bool`. Both steps fail loudly in both
    /// harnesses. Never reach for `== true` here again — it reads better and
    /// checks nothing.
    @Test("a link to a directory reads as a directory")
    func symlinkToDirectory() throws {
        try inTemporaryDirectory { root in
            try makeDirectory("real", in: root)
            try FileManager.default.createSymbolicLink(
                at: URL(fileURLWithPath: root).appendingPathComponent("link"),
                withDestinationURL: URL(fileURLWithPath: root).appendingPathComponent("real")
            )

            let contents = DirectoryListing.read(root, includingHidden: false)
            let link = try #require(contents.entries.first { $0.name == "link" })
            #expect(link.isDirectory)
        }
    }

    /// A relative target is resolved against the link's own directory, not
    /// against the process's working directory. Worth its own case because it
    /// is the form `ln -s real link` produces, so it is the one on disk in
    /// practice, and a hand-rolled resolution is exactly where it would break.
    @Test("a relative link to a directory reads as a directory")
    func relativeSymlinkToDirectory() throws {
        try inTemporaryDirectory { root in
            try makeDirectory("real", in: root)
            try makeSymlink("link", to: "real", in: root)

            let contents = DirectoryListing.read(root, includingHidden: false)
            let link = try #require(contents.entries.first { $0.name == "link" })
            #expect(link.isDirectory)
        }
    }

    /// The answer is the target's, so a link to a file stays a file. The half
    /// of the fix that no one notices until it is wrong: "follow the link"
    /// implemented as "a link is a directory" would pass the two cases above
    /// and break every file in the tree.
    @Test("a link to a file is still a file")
    func symlinkToFile() throws {
        try inTemporaryDirectory { root in
            try makeFile("real.txt", in: root)
            try makeSymlink("link", to: "real.txt", in: root)

            let contents = DirectoryListing.read(root, includingHidden: false)
            let link = try #require(contents.entries.first { $0.name == "link" })
            #expect(!link.isDirectory)
        }
    }

    /// A dangling link points at nothing, and nothing is not a directory.
    ///
    /// It still gets a row: a broken link is a real entry, and a tree that
    /// hides it answers "there is nothing here" to a reader who can see the
    /// name in `ls`. It just does not open — `false` is the conservative
    /// answer, because a row that expands into a directory that does not exist
    /// is the plausible-and-wrong outcome this panel refuses to produce.
    @Test("a broken link is neither a directory nor an error")
    func brokenSymlink() throws {
        try inTemporaryDirectory { root in
            try makeSymlink("dangling", to: "nowhere", in: root)

            let contents = DirectoryListing.read(root, includingHidden: false)
            #expect(!contents.unreadable, "one dead link does not make the directory unreadable")
            let dangling = try #require(
                contents.entries.first { $0.name == "dangling" },
                "it is still an entry the reader can see in the shell"
            )
            #expect(!dangling.isDirectory)
        }
    }

    /// A cycle must not hang. Resolution is `stat(2)`'s, so the kernel stops at
    /// MAXSYMLINKS and reports ELOOP, which reads here as "does not exist" and
    /// lands on the same conservative `false` as a broken link — which is what
    /// a cycle is, once you stop walking it.
    ///
    /// The mutual pair and the self-loop are both here because they fail
    /// differently in a hand-rolled resolver: a naive "resolve until it is not
    /// a link" loop spins forever on either, while a "resolve once and stop"
    /// shortcut survives the self-loop and still spins on the pair.
    @Test("a circular link resolves to not-a-directory instead of hanging")
    func circularSymlink() throws {
        try inTemporaryDirectory { root in
            try makeSymlink("a", to: "b", in: root)
            try makeSymlink("b", to: "a", in: root)
            try makeSymlink("self", to: "self", in: root)

            let contents = DirectoryListing.read(root, includingHidden: true)
            #expect(contents.entries.map(\.name) == ["a", "b", "self"])
            #expect(contents.entries.allSatisfy { !$0.isDirectory })
        }
    }

    /// A chain of links ends where the last one lands. `stat(2)` walks the
    /// whole chain, so `link -> hop -> real` is a directory; anything that
    /// resolved a single hop and stopped would call it a file.
    @Test("a chain of links reads as whatever it ends at")
    func symlinkChain() throws {
        try inTemporaryDirectory { root in
            try makeDirectory("real", in: root)
            try makeFile("real.txt", in: root)
            try makeSymlink("hopToDir", to: "real", in: root)
            try makeSymlink("linkToDir", to: "hopToDir", in: root)
            try makeSymlink("hopToFile", to: "real.txt", in: root)
            try makeSymlink("linkToFile", to: "hopToFile", in: root)

            let contents = DirectoryListing.read(root, includingHidden: false)
            let toDir = try #require(contents.entries.first { $0.name == "linkToDir" })
            let toFile = try #require(contents.entries.first { $0.name == "linkToFile" })
            #expect(toDir.isDirectory)
            #expect(!toFile.isDirectory)
        }
    }

    // MARK: - Relative paths

    /// What the context menu copies. Measured from the tree's own root, which
    /// is the one the reader can see in the header above it.
    @Test("a path under the root is written relative to it")
    func relativeUnderRoot() {
        #expect(
            DirectoryListing.relativePath(of: "/Users/me/repo/src/main.rs", under: "/Users/me/repo")
                == "src/main.rs"
        )
    }

    /// The separator is the whole trick: without it `/a/bc` reads as being
    /// under `/a/b` and comes back as the nonsense `c`.
    @Test("a sibling whose name merely starts the same is not inside")
    func siblingIsNotInside() {
        #expect(
            DirectoryListing.relativePath(of: "/Users/me/repo-two/x", under: "/Users/me/repo")
                == "/Users/me/repo-two/x",
            "not under the root, so the absolute path is the honest answer"
        )
    }

    /// A trailing slash on the root is the same root.
    @Test("a trailing slash changes nothing")
    func trailingSlashIsIgnored() {
        #expect(
            DirectoryListing.relativePath(of: "/a/b/c.txt", under: "/a/b/")
                == DirectoryListing.relativePath(of: "/a/b/c.txt", under: "/a/b")
        )
    }

    /// Anything not under the root falls back to absolute rather than climbing
    /// with `../..`: a correct long answer beats a plausible short one.
    @Test("something outside the root keeps its full path")
    func outsideKeepsAbsolute() {
        #expect(DirectoryListing.relativePath(of: "/etc/hosts", under: "/Users/me") == "/etc/hosts")
        #expect(DirectoryListing.relativePath(of: "/a/b", under: "") == "/a/b")
    }

    /// The root itself is not "" — an empty string is not a path anyone can use.
    @Test("the root itself is not the empty string")
    func rootIsNotEmpty() {
        #expect(DirectoryListing.relativePath(of: "/a/b", under: "/a/b") == "/a/b")
    }
}
