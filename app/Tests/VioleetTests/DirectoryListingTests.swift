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
    @Test("a link to a directory reads as a directory")
    func symlinkToDirectory() throws {
        try inTemporaryDirectory { root in
            try makeDirectory("real", in: root)
            try FileManager.default.createSymbolicLink(
                at: URL(fileURLWithPath: root).appendingPathComponent("link"),
                withDestinationURL: URL(fileURLWithPath: root).appendingPathComponent("real")
            )

            let contents = DirectoryListing.read(root, includingHidden: false)
            let link = contents.entries.first { $0.name == "link" }
            #expect(link?.isDirectory == true)
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
