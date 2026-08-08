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
}
