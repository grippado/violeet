// What one session wrote, ready to be drawn as a tree.
//
// # The boundary, again
//
// Same rule as `SessionCardModel`: everything here came off the socket. The app
// groups and sorts — presentation over data the daemon sent — and computes no
// number. It does not run `git`, does not stat a file, does not diff anything.
// A second place deriving a diffstat is a second place for it to disagree, and
// the daemon is the one that watched the edits happen.
//
// # Absent is not empty
//
// A session that wrote nothing and a session whose writes we did not see are
// different facts, and the panel says different things for them. That is why
// `isPartial` and `isTruncated` are carried next to the entries rather than
// being folded into "the list is short".

import Foundation

/// The files one session wrote, with the caveats that came with them.
struct SessionFileList: Equatable {
    /// Ordered by path, as the daemon sends it.
    var files: [FileChange] = []

    /// The list covers only part of the session.
    ///
    /// Two causes, and neither is visible in the list itself: the daemon may
    /// have met the session already running, and anything written by `Bash`
    /// leaves no tool result naming a path. `nil` means we were never told.
    var isPartial: Bool?

    /// The daemon cut the list to fit the line.
    var isTruncated: Bool?

    var isEmpty: Bool { files.isEmpty }

    var totalAdded: Int { files.reduce(0) { $0 + $1.added } }
    var totalRemoved: Int { files.reduce(0) { $0 + $1.removed } }

    /// Whether anything about this list is less than the whole truth.
    var isQualified: Bool { isPartial == true || isTruncated == true }
}

/// A group of files sharing a root, which is how the tree is drawn.
///
/// Grouping by root rather than showing absolute paths is what keeps notes in
/// `~/.notes` legible beside code in a repo: two roots, each with short paths
/// under it, instead of one column of `../../../` prefixes.
struct FileRoot: Identifiable, Equatable {
    /// The common directory, abbreviated with `~` where it applies.
    let root: String
    /// Entries under it, each with `root` stripped from the front.
    let entries: [Entry]

    var id: String { root }

    struct Entry: Identifiable, Equatable {
        /// Relative to the root, with separators intact: `src/main.rs`.
        let relativePath: String
        let change: FileChange

        var id: String { change.path }

        /// Just the file name, for the row's leading text.
        var name: String {
            (relativePath as NSString).lastPathComponent
        }

        /// The directory part, shown dimmed before the name. Empty at the root.
        var directory: String {
            let dir = (relativePath as NSString).deletingLastPathComponent
            return dir.isEmpty ? "" : dir + "/"
        }
    }

    var added: Int { entries.reduce(0) { $0 + $1.change.added } }
    var removed: Int { entries.reduce(0) { $0 + $1.change.removed } }
}

extension SessionFileList {
    /// Group the flat list into roots.
    ///
    /// A pure function over data the daemon sent, deliberately free of the main
    /// actor and of `AppState`, so the grouping can be tested without a running
    /// app — the same argument `SessionCardModel` makes for its own helpers.
    ///
    /// The roots are the deepest directories that still hold more than one
    /// file, falling back to each file's own directory. That is what puts a
    /// repo and the vault side by side without inventing a shared ancestor like
    /// `/Users/you` that no one thinks in.
    func grouped(homeDirectory: String = NSHomeDirectory()) -> [FileRoot] {
        guard !files.isEmpty else { return [] }

        var byDirectory: [String: [FileChange]] = [:]
        for file in files {
            let dir = (file.path as NSString).deletingLastPathComponent
            byDirectory[dir, default: []].append(file)
        }

        // Fold directories into the shallowest ancestor that is itself a
        // directory we saw. Without this, `src/` and `src/model/` would be two
        // roots for one repo, and the tree would read as two projects.
        let directories = byDirectory.keys.sorted()
        var rootFor: [String: String] = [:]
        for dir in directories {
            var root = dir
            for candidate in directories where candidate != dir {
                if dir.hasPrefix(candidate + "/"), candidate.count < root.count {
                    root = candidate
                }
            }
            rootFor[dir] = root
        }

        var grouped: [String: [FileChange]] = [:]
        for (dir, changes) in byDirectory {
            grouped[rootFor[dir] ?? dir, default: []].append(contentsOf: changes)
        }

        return grouped
            .map { root, changes in
                FileRoot(
                    root: abbreviate(root, home: homeDirectory),
                    entries: changes
                        .sorted { $0.path < $1.path }
                        .map { change in
                            FileRoot.Entry(
                                relativePath: relative(change.path, to: root),
                                change: change
                            )
                        }
                )
            }
            .sorted { $0.root < $1.root }
    }

    private func relative(_ path: String, to root: String) -> String {
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
