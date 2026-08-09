// What is in a directory, ready to be drawn as a tree.
//
// # Why this one reads the disk when the Files panel refuses to
//
// `SessionFileList` is emphatic that the app computes nothing: no `git`, no
// stat, no diff. That rule is about *the daemon's data* — a second place
// deriving a diffstat is a second place for it to disagree with the one that
// watched the edits happen.
//
// A tab with no session has no daemon data at all. Nobody is watching a plain
// shell, and nobody should start: that would mean the daemon tailing every
// directory any tab ever `cd`s into, to answer a question the filesystem
// answers in one syscall. So this reads the disk, and the boundary holds — the
// app still derives nothing the daemon knows.
//
// # Unreadable is not empty
//
// Same distinction the Files panel is built around, one layer down. An empty
// directory and a directory the account cannot open are different facts, and a
// tree that draws both as nothing tells the reader the first one when the truth
// is the second. `contentsOfDirectory` signals the difference by throwing, and
// dropping that into `[]` is where it would be lost.
//
// # Hidden means a dotfile
//
// Not `FileManager`'s `.skipsHiddenFiles`, which also honours the Finder's
// hidden flag and the `.hidden` file. This is a terminal, the button sits next
// to a shell prompt, and what "hidden" means there is `ls` versus `ls -a`.

import Foundation

/// One row of a directory: a name, where it is, and whether it opens.
struct DirectoryEntry: Identifiable, Equatable {
    let name: String
    let path: String
    let isDirectory: Bool

    var id: String { path }

    /// A dotfile. See the note above on why this and not the Finder's flag.
    var isHidden: Bool { name.hasPrefix(".") }
}

/// A directory's contents, and whether we were able to read them at all.
struct DirectoryContents: Equatable {
    var entries: [DirectoryEntry] = []

    /// The directory refused to open — permissions, a broken mount, a path that
    /// stopped existing between the `cd` and the read. Carried beside the
    /// entries rather than folded into "there are none", because the panel says
    /// different things for the two.
    var unreadable = false

    var isEmpty: Bool { entries.isEmpty }
}

enum DirectoryListing {
    /// Read `directory`, filtered and ordered for display.
    ///
    /// Blocking, and called off the main actor by the view — a directory on a
    /// slow mount takes as long as it takes, and the window must not wait on it.
    static func read(
        _ directory: String,
        includingHidden: Bool,
        fileManager: FileManager = .default
    ) -> DirectoryContents {
        let url = URL(fileURLWithPath: directory)
        let contents: [URL]
        do {
            // No properties prefetched. `.isDirectoryKey` used to be asked for
            // here, to feed the `resourceValues` read below. Nothing below
            // reads a resource value now, so keeping it would populate a cache
            // nobody consults — and, worse, leave a hint pointing the next
            // reader back at the call that got the symlink wrong.
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            return DirectoryContents(unreadable: true)
        }

        let entries = contents.map { child -> DirectoryEntry in
            // A link to a directory opens like the directory it points at —
            // what the name in the tree looks like it should do. So the answer
            // we want is the *target's*, not the link's.
            //
            // This used to read `child.resourceValues(forKeys: [.isDirectoryKey])`
            // under a comment asserting that the call resolves the link. It does
            // not, and never did. Measured three ways — inside the test host,
            // in a compiled binary, and in a `swift` script — it answers `false`
            // for every symlink: to a directory, to a file, through a chain, or
            // dangling. It makes no difference whether the URL still carries the
            // cache `contentsOfDirectory(at:includingPropertiesForKeys:)`
            // populates or is rebuilt fresh from the path; that cache was
            // suspected first and cleared by measurement.
            //
            // What hid it was the test, not the cache. `#expect(x == true)` is
            // swallowed by the `swift-testing` package version pinned here, so
            // the guarding test could not fail; a `stderr` probe printed
            // `isDirectory -> false` for a link to a directory while that test
            // reported a pass. See the long note in DirectoryListingTests for
            // the measurement and for the assertion shape that replaced it.
            //
            // `fileExists(atPath:isDirectory:)` is `stat(2)`: it follows the
            // link, and follows a chain of them, and answers about whatever it
            // lands on. That gets every case right at one syscall per entry:
            //
            //   - broken link      → does not exist → `false`. Not a directory,
            //                        and not an error either: a dangling link
            //                        is a real thing to show in a tree, it just
            //                        does not open.
            //   - cycle, self-loop → the kernel gives up at MAXSYMLINKS and
            //                        returns ELOOP, which arrives here as "does
            //                        not exist" → `false`. The bound is the
            //                        kernel's, so no loop of ours to hang in.
            //   - link to a file   → `false`, unchanged.
            //   - relative target  → resolved against the link's own directory
            //                        by the kernel, same as absolute. Nothing
            //                        for us to join by hand.
            //
            // `false` is also the conservative answer for anything unforeseen:
            // an entry we mislabel as a file is a row that will not expand, and
            // an entry we mislabel as a directory is a row that expands into a
            // lie. `resolvingSymlinksInPath()` was the other candidate and is
            // worse — it is a path transformation, not a lookup, so it answers
            // for a path that may not exist and would still need this `stat`
            // afterwards.
            var isDirectoryFlag: ObjCBool = false
            let exists = fileManager.fileExists(atPath: child.path, isDirectory: &isDirectoryFlag)
            let isDirectory = exists && isDirectoryFlag.boolValue
            return DirectoryEntry(
                name: child.lastPathComponent,
                path: child.path,
                isDirectory: isDirectory
            )
        }

        return DirectoryContents(
            entries: ordered(includingHidden ? entries : entries.filter { !$0.isHidden })
        )
    }

    /// A path written relative to the tree's own root.
    ///
    /// Relative to **what the reader is looking at**, not to a repository root
    /// or to `$PWD`. The tree announces its root in its header, so a path
    /// measured from there is one the reader can check against the screen; a
    /// path measured from a git root they cannot see would be shorter and
    /// unverifiable.
    ///
    /// Falls back to the absolute path rather than to `../..` climbing: if the
    /// entry is not under the root, something is wrong with the caller's
    /// assumptions, and a correct long answer beats a plausible short one.
    ///
    /// A pure function of two strings, so the edge cases below are tests rather
    /// than something to reproduce with a mouse.
    static func relativePath(of path: String, under root: String) -> String {
        guard !root.isEmpty, path != root else { return path }
        // The separator matters: without it, `/a/bc` reads as being under `/a/b`.
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }

    /// Directories first, then by name the way a person reads it.
    ///
    /// A pure function over its argument, so the ordering can be tested without
    /// a directory on disk — the same split `SessionFileList.grouped` makes.
    ///
    /// `localizedStandardCompare` and not `<`: the latter sorts `v10` before
    /// `v2` and puts every capital letter ahead of every lowercase one, which
    /// is a listing nobody scans successfully. This is the comparison the Finder
    /// uses, and the tree sits beside a shell whose completion sorts the same
    /// way.
    static func ordered(_ entries: [DirectoryEntry]) -> [DirectoryEntry] {
        entries.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}
