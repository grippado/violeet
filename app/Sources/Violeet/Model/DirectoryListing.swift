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
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            return DirectoryContents(unreadable: true)
        }

        let entries = contents.map { child -> DirectoryEntry in
            // `resourceValues` resolves the symlink, so a link to a directory
            // expands like the directory it points at — which is what the name
            // in the tree looks like it should do. Loops are possible in
            // principle and harmless in practice: nothing here walks, so a
            // cycle costs a click per level rather than a hang.
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
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
