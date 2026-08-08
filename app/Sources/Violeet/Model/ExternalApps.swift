// Which applications can open a file, and opening it in one.
//
// # Why ask the system instead of listing editors
//
// The obvious version hard-codes a list — VS Code, Cursor, Sublime, Zed — and
// is wrong on every machine in a different way: it names apps that are not
// installed, misses the one this user actually reaches for, and goes stale
// every time somebody's habits change.
//
// `NSWorkspace` already answers this. It is the same list the Finder's own
// "Open With" is built from, in the same order, and it is right about a machine
// nobody here has seen. An app that appears in this menu is an app that is
// installed and claims the file's type.
//
// # Why this is not `openInEditor`
//
// `AppState.openInEditor` runs the user's `$EDITOR` inside a tab, which is what
// a terminal should do with a text file and is deliberate. This is the other
// question: "take this out of here". They are different intentions and the
// panel offers both, rather than one pretending to be the other.

import AppKit
import UniformTypeIdentifiers

enum ExternalApps {
    /// One application that can open a file.
    struct Choice: Identifiable, Equatable {
        let name: String
        let url: URL

        var id: String { url.path }
    }

    /// Applications that claim this file's type, the default one first.
    ///
    /// `urlsForApplications` returns them in the system's own preference order,
    /// which is what the Finder shows, so no sorting is applied on top — a list
    /// reordered here would disagree with the menu next door for no reason the
    /// reader could see.
    ///
    /// Deduplicated by name. macOS reports the same app twice on machines that
    /// have it in more than one place, most often a copy in `~/Applications`
    /// beside the one in `/Applications`, and two identical rows in a menu are
    /// a coin toss rather than a choice.
    ///
    /// Capped, because a common type like `.txt` can claim two dozen apps and a
    /// menu that long is a scroll. The cap is generous enough that the app
    /// anybody is looking for is in it, and `Other…` is there for the rest.
    static func choices(for path: String, limit: Int = 12) -> [Choice] {
        let url = URL(fileURLWithPath: path)
        var seen = Set<String>()
        var out: [Choice] = []

        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) {
            let name = FileManager.default.displayName(atPath: app.path)
                .replacingOccurrences(of: ".app", with: "")
            guard seen.insert(name).inserted else { continue }
            out.append(Choice(name: name, url: app))
            if out.count >= limit { break }
        }
        return out
    }

    /// Open a file in a named application.
    static func open(path: String, with app: URL) {
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Hand the file to whatever the system would use.
    ///
    /// The fallback for a file no application claims, where the panel would
    /// otherwise have an empty menu. macOS answers this with its own picker,
    /// which is the right place for the question at that point.
    static func openWithDefault(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Applications worth offering as "the editor I use", for the settings list.
    ///
    /// Asked by **type**, not by file. The first version probed with paths
    /// under `/tmp` that did not exist, and Launch Services answered nothing
    /// for every one of them: `urlsForApplications(toOpen: URL)` wants a file
    /// that is there. The list came back empty on a machine full of editors,
    /// and a test asserting the section is not a heading over nothing is what
    /// caught it.
    ///
    /// Plain text, markdown, JSON and source code, unioned. That is a proxy for
    /// "is an editor" and a deliberately loose one: an IDE claims all of them,
    /// a note-taking app claims markdown, and both are things somebody might
    /// genuinely want here. Guessing narrower would be this file's own opening
    /// argument in reverse.
    static func editorCandidates() -> [Choice] {
        var seen = Set<String>()
        var out: [Choice] = []

        // `markdown` has no constant in `UniformTypeIdentifiers`, so it is
        // named by its identifier. Anything unknown to this system resolves to
        // `nil` and is skipped rather than crashing a settings panel.
        let types = [UTType.plainText, .json, .sourceCode, .yaml]
            + [UTType("net.daringfireball.markdown")].compactMap { $0 }

        for type in types {
            for app in NSWorkspace.shared.urlsForApplications(toOpen: type) {
                let name = FileManager.default.displayName(atPath: app.path)
                    .replacingOccurrences(of: ".app", with: "")
                guard seen.insert(name).inserted else { continue }
                out.append(Choice(name: name, url: app))
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The chosen applications, dropping any that are no longer installed.
    ///
    /// A path is stored and a path can rot: an app is moved to the Trash,
    /// renamed, or lives on a machine this synced preferences file has never
    /// seen. A stale entry would be a menu item that silently does nothing, so
    /// it is filtered at read time rather than trusted.
    ///
    /// The stored order is kept. It is the order the user built the list in,
    /// and re-sorting it here would move the single-app case's button label
    /// out from under them.
    static func resolve(_ paths: [String]) -> [Choice] {
        paths.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let name = FileManager.default.displayName(atPath: path)
                .replacingOccurrences(of: ".app", with: "")
            return Choice(name: name, url: URL(fileURLWithPath: path))
        }
    }
}
