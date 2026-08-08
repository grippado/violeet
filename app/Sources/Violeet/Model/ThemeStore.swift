// The themes on disk, and the loop that makes editing one feel live.
//
// # The loop this exists for
//
// Open the theme, change a hex, `:w`, and the terminal behind the editor is
// already wearing it. That is the whole feature: a palette is judged against
// real output, and any cycle that involves a restart, a reload button or even a
// click is a cycle where the reader has stopped looking at the colours.
//
// So: the file is watched (see `FileWatcher`, and the vim rename problem it
// exists to survive), and a save is applied straight into `Preferences.terminal`
// — which is the one funnel `AppState` already pushes to every live terminal.
// Nothing new had to be wired for the change to reach the screen.
//
// # A broken file is not an emergency
//
// Half a JSON object is the normal state of a file being edited. So a parse
// failure keeps the colours that are already on screen, says what is wrong in
// the panel, and waits — the next save fixes it, and the error clears itself.
// The alternatives are both worse: reverting to a default throws away the theme
// the user is working on, and applying what parsed leaves a palette that exists
// in no file.
//
// # Where they live
//
// `~/.violeet/themes/`, beside `daemon.json` and the socket. The app's own
// directory rather than `Application Support`: this is a file the user is meant
// to open, edit and keep in a dotfiles repository, and a path with a space in it
// that Finder hides by default is not that.

import Foundation

@MainActor
final class ThemeStore: ObservableObject {
    /// A theme file on disk, as the picker needs it.
    struct Entry: Equatable, Identifiable {
        let name: String
        let path: String

        var id: String { path }
    }

    /// Custom themes found on disk, sorted by name.
    @Published private(set) var custom: [Entry] = []

    /// What is wrong with the file being edited, if anything.
    ///
    /// Held rather than logged: the reader is in an editor two panes away, and
    /// an error that only exists in a log is an error they will not see until
    /// they wonder why nothing happened.
    @Published private(set) var lastError: String?

    private let preferences: Preferences
    private var watcher: FileWatcher?

    init(preferences: Preferences) {
        self.preferences = preferences
        refresh()
        // A theme being edited survives a relaunch. Without this the loop works
        // until you quit, and then the file silently stops being live — which
        // reads as the feature having broken rather than as the watcher not
        // having been started.
        if let path = preferences.terminal.appearance.themeFile {
            watch(path)
        }
    }

    // MARK: - The directory

    static var directory: URL {
        Discovery.homeDirectory.appendingPathComponent(".violeet/themes", isDirectory: true)
    }

    /// `~/.violeet/themes/midnight.json` → `midnight`.
    ///
    /// Only ever a fallback: it names a theme whose file does not name itself.
    private static func nameFromFilename(_ path: String) -> String {
        let file = (path as NSString).lastPathComponent
        return file.hasSuffix(".json") ? String(file.dropLast(5)) : file
    }

    /// Rescan the themes directory.
    func refresh() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: Self.directory.path) else {
            custom = []
            return
        }
        custom = names
            .filter { $0.hasSuffix(".json") }
            .map { name -> Entry in
                let path = Self.directory.appendingPathComponent(name).path
                let fallback = String(name.dropLast(".json".count))
                // The name inside the file wins over the filename, because that
                // is the one the author chose to be read. Reading each file to
                // list them costs a few kilobytes for a directory that holds
                // themes, not photographs.
                let named = (try? Data(contentsOf: URL(fileURLWithPath: path)))
                    .flatMap { data -> String? in
                        guard case .success(let theme) = ThemeFile.parse(data, fallbackName: fallback) else {
                            return nil
                        }
                        return theme.name
                    }
                return Entry(name: named ?? fallback, path: path)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Applying

    /// Adopt a theme file, and keep watching it.
    ///
    /// Returns whether it parsed; the error is on `lastError` either way, so a
    /// caller that does not care can ignore the result.
    @discardableResult
    func apply(path: String) -> Bool {
        let applied = reload(path)
        // Watched even when it failed to parse. The reason to watch a broken
        // theme is precisely that it is broken: the user is about to fix it, and
        // stopping here would mean the fix does nothing.
        watch(path)
        return applied
    }

    /// Read the file and put it on screen, or record why not.
    @discardableResult
    private func reload(_ path: String) -> Bool {
        let name = Self.nameFromFilename(path)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            lastError = ThemeFileError.unreadable.message
            return false
        }
        switch ThemeFile.parse(data, fallbackName: name) {
        case .success(let theme):
            lastError = nil
            // Straight into the settings value, which `AppState` is already
            // subscribed to. The terminals repaint from that subscription.
            preferences.terminal.apply(theme: theme, from: path)
            refresh()
            return true
        case .failure(let error):
            lastError = error.message
            return false
        }
    }

    private func watch(_ path: String) {
        watcher?.stop()
        watcher = FileWatcher(path: path) { [weak self] in
            self?.reload(path)
        }
    }

    /// Let go of the file. Called when a built-in theme is chosen: the palette
    /// on screen no longer comes from that file, so a save to it must not
    /// silently take the terminal back.
    func stopWatching() {
        watcher?.stop()
        watcher = nil
        lastError = nil
    }

    // MARK: - Creating

    /// The file for the theme in use, written from the current colours if it
    /// does not exist yet.
    ///
    /// A built-in has no file until this is called, and that is deliberate:
    /// shipping six files into the user's home so that one of them might be
    /// edited is six files to keep in step with the code that also defines them.
    /// The first edit is what makes one real.
    ///
    /// The copy is called "<Name> (edited)" rather than "<Name>". It is a
    /// different thing from the built-in it started as — that one cannot be
    /// changed and this one can — and giving both the same name puts two
    /// identical-looking rows in the picker. The suffix also says the original
    /// is still there to go back to.
    ///
    /// Returns the path to open, or `nil` if it could not be written.
    func fileForCurrentTheme() -> String? {
        if let existing = preferences.terminal.appearance.themeFile,
           FileManager.default.fileExists(atPath: existing) {
            // Re-watched rather than assumed to be watched: the user may have
            // picked a built-in and come back, which stopped the watcher.
            watch(existing)
            return existing
        }
        let current = currentAsTheme()
        return write(current, called: "\(current.name) (edited)")
    }

    /// A new theme file, starting from whatever is on screen.
    ///
    /// Starting from the current palette rather than from a blank or a default:
    /// somebody making their own theme is nearly always adjusting the one they
    /// are looking at, and an empty file makes them fetch twenty values by hand
    /// before they can change one.
    func createTheme() -> String? {
        let current = currentAsTheme()
        return write(current, called: "\(current.name) copy")
    }

    /// The colours on screen, as a theme.
    private func currentAsTheme() -> TerminalTheme {
        let appearance = preferences.terminal.appearance
        return TerminalTheme(
            name: appearance.themeName ?? "Custom",
            background: appearance.background,
            foreground: appearance.foreground,
            cursor: appearance.cursorColor,
            ansi: appearance.ansi
        )
    }

    /// Write `theme` under a new name, in the next free file.
    /// Send a custom theme to the Trash.
    ///
    /// # Why the Trash and not `removeItem`
    ///
    /// A theme is somebody's afternoon of picking colours, and this is a
    /// right-click away in a list where the row above it is the one they are
    /// using. `rm` makes that mistake final; the Trash makes it an undo. macOS
    /// has a place for "I think I am done with this" and it is not oblivion.
    ///
    /// It also means there is no confirmation dialog, which would be the other
    /// way to make this safe and a worse one: a sheet takes key status from the
    /// terminal, and this panel refuses to do that for anything.
    ///
    /// # When the deleted theme is the one in use
    ///
    /// The colours stay exactly as they are. They are already stored in
    /// settings, so nothing on screen changes, and the app stops watching a
    /// file that is no longer there. The alternative — snapping back to a
    /// built-in — would repaint the terminal as a side effect of tidying up a
    /// list, which is a surprise nobody asked for.
    @discardableResult
    func deleteTheme(_ entry: Entry) -> Bool {
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(
                at: URL(fileURLWithPath: entry.path),
                resultingItemURL: &trashed
            )
        } catch {
            lastError = "Could not delete \(entry.name)."
            return false
        }

        if preferences.terminal.appearance.themeFile == entry.path {
            // Keep the colours, drop the link. See above.
            preferences.terminal.appearance.themeFile = nil
            watcher = nil
        }
        lastError = nil
        refresh()
        return true
    }

    private func write(_ theme: TerminalTheme, called name: String) -> String? {
        // Both strings need uniqueness, and only the slug had it. See
        // `ThemeFile.uniqueName`.
        let name = ThemeFile.uniqueName(name, taken: Set(custom.map(\.name)))
        let renamed = TerminalTheme(
            name: name,
            background: theme.background,
            foreground: theme.foreground,
            cursor: theme.cursor,
            ansi: theme.ansi
        )
        let slug = ThemeFile.uniqueSlug(ThemeFile.slug(name), taken: Set(existingSlugs()))
        return write(renamed, slug: slug, claimIt: true)
    }

    private func existingSlugs() -> [String] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: Self.directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
    }

    /// Write a theme and, when asked, make it the one in use.
    private func write(_ theme: TerminalTheme, slug: String, claimIt: Bool) -> String? {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        let url = Self.directory.appendingPathComponent("\(slug).json")
        do {
            try ThemeFile.serialise(theme).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Could not write \(url.lastPathComponent)."
            return nil
        }

        if claimIt {
            lastError = nil
            preferences.terminal.apply(theme: theme, from: url.path)
            watch(url.path)
        }
        refresh()
        return url.path
    }
}
