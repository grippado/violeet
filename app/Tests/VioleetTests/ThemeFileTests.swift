// Reading and writing a theme file.
//
// Pure functions over bytes and strings, tested as such: every shape below is a
// file somebody could save while editing, and discovering how the app reacts to
// each one by saving it and watching the window is exactly the loop these tests
// exist to replace.
//
// The properties worth protecting are the refusals. A theme is applied to a live
// terminal the moment it parses, so anything that parses when it should not
// leaves the user looking at a palette that exists in no file.

import Foundation
import Testing

@testable import Violeet

@Suite("Theme file")
struct ThemeFileTests {
    private func theme(
        name: String = "Test",
        background: RGB = RGB(0x11, 0x22, 0x33),
        foreground: RGB = RGB(0xEE, 0xDD, 0xCC),
        cursor: RGB = RGB(0xFF, 0x00, 0xFF)
    ) -> TerminalTheme {
        TerminalTheme(
            name: name,
            background: background,
            foreground: foreground,
            cursor: cursor,
            ansi: (0..<16).map { RGB(UInt8($0 * 16), UInt8($0), 0x40) }
        )
    }

    private func parse(_ json: String, name: String = "fallback") -> Result<TerminalTheme, ThemeFileError> {
        ThemeFile.parse(Data(json.utf8), fallbackName: name)
    }

    // MARK: - Round trip

    /// The app writes these files and the user edits them, so what comes out
    /// must go back in unchanged. Without this the first save of an untouched
    /// file could alter the palette.
    @Test("a theme survives being written and read back")
    func roundTrips() throws {
        let original = theme(name: "Midnight")
        let result = ThemeFile.parse(Data(ThemeFile.serialise(original).utf8), fallbackName: "x")
        let parsed = try #require(try? result.get())

        #expect(parsed.name == original.name)
        #expect(parsed.background == original.background)
        #expect(parsed.foreground == original.foreground)
        #expect(parsed.cursor == original.cursor)
        #expect(parsed.ansi == original.ansi)
    }

    /// The colours that decide whether a theme works at all are read first,
    /// above the sixteen-entry palette. Alphabetical order would bury them.
    @Test("the written file reads top down")
    func writtenOrderIsReadable() {
        let text = ThemeFile.serialise(theme())
        let name = try! #require(text.range(of: "\"name\""))
        let background = try! #require(text.range(of: "\"background\""))
        let ansi = try! #require(text.range(of: "\"ansi\""))
        #expect(name.lowerBound < background.lowerBound)
        #expect(background.lowerBound < ansi.lowerBound)
        #expect(text.hasSuffix("\n"), "a file without a trailing newline makes vim say [noeol]")
    }

    /// A name with a quote in it must not produce a file that no longer parses.
    @Test("a name with quotes stays valid JSON")
    func nameIsEscaped() {
        let text = ThemeFile.serialise(theme(name: "My \"Best\" Theme"))
        let parsed = try? ThemeFile.parse(Data(text.utf8), fallbackName: "x").get()
        #expect(parsed?.name == "My \"Best\" Theme")
    }

    // MARK: - The two spellings of the palette

    /// Named slots are the form a person edits: index 11 being bright yellow is
    /// something the panel needed a helper to explain, and a file should not
    /// require the same knowledge.
    @Test("named slots are read in wire order")
    func namedSlots() throws {
        let json = """
        {
          "background": "#000000", "foreground": "#FFFFFF",
          "ansi": {
            "black": "#010101", "red": "#020202", "green": "#030303", "yellow": "#040404",
            "blue": "#050505", "magenta": "#060606", "cyan": "#070707", "white": "#080808",
            "brightBlack": "#090909", "brightRed": "#0A0A0A", "brightGreen": "#0B0B0B",
            "brightYellow": "#0C0C0C", "brightBlue": "#0D0D0D", "brightMagenta": "#0E0E0E",
            "brightCyan": "#0F0F0F", "brightWhite": "#101010"
          }
        }
        """
        let parsed = try #require(try? parse(json).get())
        #expect(parsed.ansi.first == RGB(1, 1, 1))
        #expect(parsed.ansi[11] == RGB(0x0C, 0x0C, 0x0C), "index 11 is bright yellow")
        #expect(parsed.ansi.last == RGB(0x10, 0x10, 0x10))
    }

    /// The list form is what the built-ins and the wire use, so a generated file
    /// should not be rejected for choosing it.
    @Test("a sixteen-entry list is accepted too")
    func listForm() throws {
        let list = (0..<16).map { String(format: "\"#%02X0000\"", $0) }.joined(separator: ",")
        let parsed = try #require(try? parse("""
        {"background": "#000000", "foreground": "#FFFFFF", "ansi": [\(list)]}
        """).get())
        #expect(parsed.ansi.count == 16)
        #expect(parsed.ansi[3] == RGB(3, 0, 0))
    }

    @Test("a list of the wrong length is refused, and says how long it was")
    func listWrongLength() {
        let result = parse("""
        {"background": "#000000", "foreground": "#FFFFFF", "ansi": ["#000000", "#111111"]}
        """)
        #expect(result == .failure(.wrongSlotCount(2)))
    }

    // MARK: - Refusals

    /// All or nothing. A half-applied palette is a terminal whose red comes from
    /// one theme and whose green comes from another, which is the case
    /// `TerminalSettingsCodec` already refuses for the same reason.
    @Test("a missing colour is refused rather than defaulted")
    func missingColoursRefused() {
        #expect(parse("""
        {"foreground": "#FFFFFF", "ansi": {}}
        """) == .failure(.missing("background")))

        #expect(parse("""
        {"background": "#000000", "ansi": {}}
        """) == .failure(.missing("foreground")))

        #expect(parse("""
        {"background": "#000000", "foreground": "#FFFFFF"}
        """) == .failure(.missing("ansi")))
    }

    /// A missing slot names itself, so the reader knows which line to fix
    /// without counting.
    @Test("a missing slot is named")
    func missingSlotIsNamed() {
        let result = parse("""
        {"background": "#000000", "foreground": "#FFFFFF", "ansi": {"black": "#000000"}}
        """)
        #expect(result == .failure(.missing("ansi.red")))
    }

    /// The error carries the value as well as the field: "not a colour" sends
    /// the reader hunting, `"#GGG"` tells them what they typed.
    @Test("a bad colour names the field and the value")
    func badColourIsSpecific() {
        let result = parse("""
        {"background": "#GGGGGG", "foreground": "#FFFFFF", "ansi": {}}
        """)
        #expect(result == .failure(.badColour(field: "background", value: "#GGGGGG")))
        if case .failure(let error) = result {
            #expect(error.message.contains("background"))
            #expect(error.message.contains("#GGGGGG"))
        }
    }

    /// Half a JSON object is the normal state of a file mid-save, so it has to
    /// fail cleanly rather than throw.
    @Test("truncated or empty input fails without crashing")
    func brokenInputFails() {
        #expect(parse("") == .failure(.notAnObject))
        #expect(parse("{\"background\": ") == .failure(.notAnObject))
        #expect(parse("[1, 2, 3]") == .failure(.notAnObject))
        #expect(parse("null") == .failure(.notAnObject))
    }

    // MARK: - Defaults

    /// Plenty of published themes omit the cursor, and a cursor the colour of
    /// the text is what a terminal does when nobody says otherwise. Rejecting
    /// the file over a field its author never considered helps nobody.
    @Test("an absent cursor takes the foreground")
    func cursorDefaultsToForeground() throws {
        let list = Array(repeating: "\"#123456\"", count: 16).joined(separator: ",")
        let parsed = try #require(try? parse("""
        {"background": "#000000", "foreground": "#ABCDEF", "ansi": [\(list)]}
        """).get())
        #expect(parsed.cursor == RGB(0xAB, 0xCD, 0xEF))
    }

    /// A present but broken cursor is still an error: the author meant to set
    /// it, so silently substituting something else hides their mistake.
    @Test("a present but invalid cursor is still refused")
    func brokenCursorRefused() {
        let list = Array(repeating: "\"#123456\"", count: 16).joined(separator: ",")
        let result = parse("""
        {"background": "#000000", "foreground": "#FFFFFF", "cursor": "nope", "ansi": [\(list)]}
        """)
        #expect(result == .failure(.badColour(field: "cursor", value: "nope")))
    }

    /// A theme is identified by where it lives. Making the reader keep a `name`
    /// field in step with the filename is how you end up with "Untitled" in
    /// `midnight.json`.
    @Test("a file with no name is called after itself")
    func nameFallsBackToFilename() throws {
        let list = Array(repeating: "\"#123456\"", count: 16).joined(separator: ",")
        let json = """
        {"background": "#000000", "foreground": "#FFFFFF", "ansi": [\(list)]}
        """
        #expect((try? parse(json, name: "midnight").get())?.name == "midnight")
        // A blank name is the same as no name, not a theme called nothing.
        let blank = try #require(try? ThemeFile.parse(
            Data(json.replacingOccurrences(of: "{", with: "{\"name\": \"  \",").utf8),
            fallbackName: "midnight"
        ).get())
        #expect(blank.name == "midnight")
    }

    // MARK: - Slugs

    /// The slug becomes a path. This is the test that keeps a theme name from
    /// writing outside the themes directory.
    @Test("a slug cannot escape its directory")
    func slugIsSafe() {
        #expect(!ThemeFile.slug("../../etc/hosts").contains("/"))
        #expect(!ThemeFile.slug("../../etc/hosts").contains("."))
        #expect(!ThemeFile.slug("~/.zshrc").contains("/"))
        #expect(!ThemeFile.slug("a\u{0000}b").contains("\u{0000}"))
    }

    @Test("a slug is a readable filename")
    func slugIsReadable() {
        #expect(ThemeFile.slug("My Best Theme") == "my-best-theme")
        #expect(ThemeFile.slug("Violeeter Dark") == "violeeter-dark")
        #expect(ThemeFile.slug("  spaced  out  ") == "spaced-out")
        #expect(ThemeFile.slug("Solarized (Dark)") == "solarized-dark")
    }

    /// A name made entirely of punctuation still needs somewhere to live.
    @Test("a slug is never empty")
    func slugNeverEmpty() {
        #expect(!ThemeFile.slug("").isEmpty)
        #expect(!ThemeFile.slug("!!!").isEmpty)
        #expect(!ThemeFile.slug("   ").isEmpty)
    }

    /// Counting rather than a UUID: the filename is shown to the user and typed
    /// by them, and `midnight-2` is a name where `midnight-9F3A21C4` is not.
    @Test("a taken slug counts up")
    func uniqueSlugCounts() {
        #expect(ThemeFile.uniqueSlug("midnight", taken: []) == "midnight")
        #expect(ThemeFile.uniqueSlug("midnight", taken: ["midnight"]) == "midnight-2")
        #expect(ThemeFile.uniqueSlug("midnight", taken: ["midnight", "midnight-2"]) == "midnight-3")
        // Gaps are not filled: the next free number is what matters, not the
        // lowest one.
        #expect(ThemeFile.uniqueSlug("midnight", taken: ["midnight", "midnight-3"]) == "midnight-2")
    }

    // MARK: - The loop, end to end

    /// The feature as the user performs it: open the file the app wrote, change
    /// a colour, save the way vim saves, and see the change arrive.
    ///
    /// Exercised through `ThemeStore` rather than through the parser alone,
    /// because every part that could break sits between them — the write, the
    /// watcher, the re-parse, and the hand-off into `Preferences.terminal` that
    /// the terminals are subscribed to. Testing the parser proves the file is
    /// legible; this proves the loop is closed.
    @Test("saving an edited theme reaches the settings")
    @MainActor
    func savingAppliesToSettings() async throws {
        let defaults = UserDefaults(suiteName: "violeet-theme-loop-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        let store = ThemeStore(preferences: preferences)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("violeet-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("mine.json")
        let start = TerminalTheme(
            name: "Mine",
            background: RGB(0x10, 0x10, 0x10),
            foreground: RGB(0xF0, 0xF0, 0xF0),
            cursor: RGB(0xFF, 0x00, 0x00),
            ansi: Array(repeating: RGB(0x33, 0x33, 0x33), count: 16)
        )
        try ThemeFile.serialise(start).write(to: file, atomically: true, encoding: .utf8)

        store.apply(path: file.path)
        #expect(preferences.terminal.appearance.background == RGB(0x10, 0x10, 0x10))
        #expect(preferences.terminal.appearance.themeFile == file.path)
        #expect(store.lastError == nil)

        // The save, performed the way vim performs it.
        let edited = TerminalTheme(
            name: "Mine",
            background: RGB(0x00, 0x33, 0x66),
            foreground: start.foreground,
            cursor: start.cursor,
            ansi: start.ansi
        )
        let staging = root.appendingPathComponent("mine.json~")
        try ThemeFile.serialise(edited).write(to: staging, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: staging)

        let arrived = await waitForMain(upTo: 5) {
            preferences.terminal.appearance.background == RGB(0x00, 0x33, 0x66)
        }
        #expect(arrived, "the save never reached the settings")

        store.stopWatching()
    }

    /// A file mid-edit is broken most of the time it is being edited, so a
    /// parse failure must leave the colours alone and say what is wrong. The
    /// alternative — reverting to a default — throws away the theme the user is
    /// in the middle of writing.
    @Test("a broken save keeps the colours and reports the problem")
    @MainActor
    func brokenSaveIsHeld() async throws {
        let defaults = UserDefaults(suiteName: "violeet-theme-broken-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        let store = ThemeStore(preferences: preferences)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("violeet-broken-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("mine.json")
        let good = TerminalTheme(
            name: "Mine",
            background: RGB(0x10, 0x10, 0x10),
            foreground: RGB(0xF0, 0xF0, 0xF0),
            cursor: RGB(0xFF, 0x00, 0x00),
            ansi: Array(repeating: RGB(0x33, 0x33, 0x33), count: 16)
        )
        try ThemeFile.serialise(good).write(to: file, atomically: true, encoding: .utf8)
        store.apply(path: file.path)

        try Data("{ \"background\": ".utf8).write(to: file)
        let reported = await waitForMain(upTo: 5) { store.lastError != nil }
        #expect(reported, "a broken file produced no error")
        #expect(
            preferences.terminal.appearance.background == RGB(0x10, 0x10, 0x10),
            "the colours moved while the file was unparseable"
        )

        // And it clears itself when the file is fixed, without anything being
        // clicked. An error that needs dismissing is an error the reader has to
        // remember to dismiss.
        try ThemeFile.serialise(good).write(to: file, atomically: true, encoding: .utf8)
        let cleared = await waitForMain(upTo: 5) { store.lastError == nil }
        #expect(cleared, "the error outlived the mistake")

        store.stopWatching()
    }

    @MainActor
    private func waitForMain(upTo seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    // MARK: - Unique names

    /// Only the slug was made unique, so a second copy landed in a different
    /// file carrying the same name, and the picker drew two identical rows. The
    /// only way to tell them apart was to pick one and see what happened.
    @Test("a second copy does not reuse the first one's name")
    func namesAreMadeUnique() {
        let taken: Set<String> = ["Violeeter Dark (edited) copy"]
        #expect(ThemeFile.uniqueName("Violeeter Dark (edited) copy", taken: taken)
            == "Violeeter Dark (edited) copy 2")
    }

    /// A name nobody has is left exactly as it is. Numbering the first one
    /// would put a "1" on a theme that has no sibling.
    @Test("a free name is not decorated")
    func freeNameIsUntouched() {
        #expect(ThemeFile.uniqueName("Midnight", taken: []) == "Midnight")
        #expect(ThemeFile.uniqueName("Midnight", taken: ["Other"]) == "Midnight")
    }

    /// Keeps counting rather than colliding again at 2.
    @Test("the counter climbs past an occupied number")
    func counterClimbs() {
        let taken: Set<String> = ["Base", "Base 2", "Base 3"]
        #expect(ThemeFile.uniqueName("Base", taken: taken) == "Base 4")
    }

    /// Spaces, not hyphens. This string is read by a person; the slug is the
    /// one that has to survive a filesystem.
    @Test("a read name is numbered the way the Finder numbers one")
    func namesUseSpacesNotSlugPunctuation() {
        let name = ThemeFile.uniqueName("Base", taken: ["Base"])
        #expect(name == "Base 2")
        #expect(!name.contains("-"))
    }
}
