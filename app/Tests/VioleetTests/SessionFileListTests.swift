// Tests for the Files panel's data, which is the half of it that can be wrong
// without looking wrong.
//
// Two things are worth testing here and nothing else is. The **grouping** turns
// a flat list of absolute paths into the tree on screen, and a bad grouping
// reads as a real state of the world — "this session touched two projects" —
// rather than as a bug. And the **two empties** are the panel's whole reason to
// distinguish "wrote nothing" from "we did not see", which is a distinction that
// disappears silently the moment someone folds them into `files.isEmpty`.
//
// The counts themselves are not tested here on purpose: the app does not
// compute them. They come off the socket, and the arithmetic that produces them
// is tested in `violeet-transcript`, where it happens.

import Foundation
import Testing

@testable import Violeet

@Suite("Session file list")
struct SessionFileListTests {
    private func change(_ path: String, _ added: Int = 1, _ removed: Int = 0, created: Bool = false)
        -> FileChange
    {
        FileChange(path: path, added: added, removed: removed, created: created)
    }

    @Test("files under one project fold into a single root")
    func oneRoot() {
        let list = SessionFileList(files: [
            change("/repo/src/main.rs"),
            change("/repo/src/model/tab.rs"),
            change("/repo/README.md"),
        ])

        let roots = list.grouped(homeDirectory: "/Users/nobody")
        #expect(roots.count == 1, "one project is one root, not one per directory")
        #expect(roots[0].root == "/repo")
        #expect(roots[0].entries.map(\.relativePath) == [
            "README.md", "src/main.rs", "src/model/tab.rs",
        ])
    }

    /// The case the whole grouping exists for: code and notes side by side,
    /// without inventing `/Users/you` as a shared ancestor nobody thinks in.
    @Test("a repo and the vault are two roots, not one home directory")
    func twoRoots() {
        let list = SessionFileList(files: [
            change("/Users/nobody/www/app/src/main.rs"),
            change("/Users/nobody/.notes/0-inbox/note.md"),
        ])

        let roots = list.grouped(homeDirectory: "/Users/nobody")
        #expect(roots.count == 2)
        #expect(roots.map(\.root) == ["~/.notes/0-inbox", "~/www/app/src"])
        // The home prefix is abbreviated, because a column 280pt wide spends
        // half of itself on `/Users/nobody` otherwise.
        #expect(roots.allSatisfy { $0.root.hasPrefix("~") })
    }

    @Test("a row shows its directory apart from its name")
    func rowSplitsDirectoryFromName() {
        let list = SessionFileList(files: [
            change("/repo/src/model/tab.rs"),
            change("/repo/top.rs"),
        ])

        let entries = list.grouped(homeDirectory: "/Users/nobody")[0].entries
        let nested = try! #require(entries.first { $0.name == "tab.rs" })
        #expect(nested.directory == "src/model/")
        let top = try! #require(entries.first { $0.name == "top.rs" })
        #expect(top.directory.isEmpty, "a file at the root has no directory to show")
    }

    @Test("totals add up across roots")
    func totals() {
        let list = SessionFileList(files: [
            change("/repo/a.rs", 10, 2),
            change("/other/b.rs", 5, 3),
        ])
        #expect(list.totalAdded == 15)
        #expect(list.totalRemoved == 5)
    }

    /// The distinction the panel is built around. Both lists are empty; only
    /// one of them means the session wrote nothing.
    @Test("an empty list and an unknown list are not the same fact")
    func emptyIsNotUnknown() {
        let wroteNothing = SessionFileList(files: [], isPartial: false)
        let didNotSee = SessionFileList(files: [], isPartial: true)

        #expect(wroteNothing.isEmpty)
        #expect(didNotSee.isEmpty)
        #expect(!wroteNothing.isQualified, "a complete empty list carries no caveat")
        #expect(didNotSee.isQualified, "an unseen list must say so")
    }

    @Test("a truncated list is qualified even when it is complete-looking")
    func truncatedIsQualified() {
        let list = SessionFileList(files: [change("/repo/a.rs")], isPartial: false, isTruncated: true)
        #expect(list.isQualified)
    }

    @Test("no files means no roots, and not one empty root")
    func emptyGroupsToNothing() {
        #expect(SessionFileList().grouped(homeDirectory: "/Users/nobody").isEmpty)
    }
}
