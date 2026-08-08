// A terminal theme as a file you can edit.
//
// # Why a file and not more controls
//
// The Appearance section used to carry three colour editors — background, text,
// cursor — and between them they took more vertical height than the theme list
// they sat under. They were also the wrong shape for the job. A palette is
// twenty colours that have to work *together*: the blue has to separate from the
// background, the bright black has to stay legible because that is where every
// highlighter puts comments. Judging that through twenty separate round trips
// down a 280pt column is judging it one colour at a time, which is the one way
// it cannot be judged.
//
// A file shows all twenty at once, in the editor the user already configured,
// with undo and a diff. It is also the shape the rest of the world already uses:
// every terminal theme anyone has ever downloaded is a file.
//
// # Colours only
//
// Not font, not padding, not opacity. A theme is something you swap, share and
// download, and a "theme" that silently changed the font size when applied would
// be a settings file wearing another name. The panel keeps the rest.
//
// # Named slots, not an array
//
// `ansi` is an object keyed by colour name rather than a sixteen-element list.
// The list form is what the wire and the built-ins use, and it is fine for code
// that never miscounts; a person editing by hand has to know that index 11 is
// bright yellow, and the panel needed a whole helper (`ansiName`) to translate
// that for the same reason. The names are the same ones `violeeter.json`
// publishes, so a theme can be moved between the two by hand.
//
// An array is still *accepted*, because a file that a script generated should
// not be rejected for choosing the other spelling.
//
// # All or nothing
//
// A file that is missing colours is refused rather than half-applied. This is
// the rule `TerminalSettingsCodec` already states for the palette — a terminal
// whose red is from one theme and whose green is from another is worse than one
// that ignored the file — and it matters more here, where the file is being
// edited live and a partial apply would show a palette that exists in no file.

import Foundation

/// What went wrong with a theme file, in words short enough for the panel.
///
/// Every case names the offending field. "Invalid theme" tells the reader to go
/// hunting; `ansi.brightBlue: "#GGG" is not #RRGGBB` tells them where to look
/// and what to type, which is the whole point of editing in a text editor.
enum ThemeFileError: Error, Equatable {
    case unreadable
    case notAnObject
    case missing(String)
    case badColour(field: String, value: String)
    case wrongSlotCount(Int)

    var message: String {
        switch self {
        case .unreadable:
            return "Could not read the file."
        case .notAnObject:
            return "Not JSON. The file must start with { and end with }."
        case .missing(let field):
            return "Missing \(field)."
        case .badColour(let field, let value):
            return "\(field): \(value.isEmpty ? "empty" : "\"\(value)\"") is not #RRGGBB."
        case .wrongSlotCount(let count):
            return "ansi has \(count) colours, needs 16."
        }
    }
}

enum ThemeFile {
    /// The sixteen ANSI names, in wire order: eight normal, then eight bright.
    ///
    /// The same names `violeeter.json` uses, so a palette can be carried between
    /// the two by hand without a translation table.
    static let ansiSlots = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow",
        "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
    ]

    // MARK: - Reading

    /// Parse a theme, or say precisely what is wrong with it.
    ///
    /// `fallbackName` is used when the file has no `name`, and is normally the
    /// filename: a theme is identified by where it lives, and making the reader
    /// keep two names in step for one file is a way to end up with a theme
    /// called "Untitled" in a file called `midnight.json`.
    ///
    /// A pure function over bytes, so every shape below is a test rather than
    /// something to discover by saving a broken file and watching the app.
    static func parse(_ data: Data, fallbackName: String) -> Result<TerminalTheme, ThemeFileError> {
        guard let any = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.notAnObject)
        }
        guard let json = any as? [String: Any] else {
            return .failure(.notAnObject)
        }

        func colour(_ key: String, in object: [String: Any]) -> Result<RGB, ThemeFileError> {
            guard let raw = object[key] else { return .failure(.missing(key)) }
            let text = raw as? String ?? ""
            guard let parsed = RGB(hex: text) else {
                return .failure(.badColour(field: key, value: text))
            }
            return .success(parsed)
        }

        let background: RGB
        switch colour("background", in: json) {
        case .success(let value): background = value
        case .failure(let error): return .failure(error)
        }

        let foreground: RGB
        switch colour("foreground", in: json) {
        case .success(let value): foreground = value
        case .failure(let error): return .failure(error)
        }

        // The one colour with a defensible default. Plenty of published themes
        // omit it, and a cursor the colour of the text is what a terminal does
        // when nobody says otherwise — so the choice is between accepting the
        // file and rejecting it over a field its author never considered.
        let cursor: RGB
        if json["cursor"] == nil {
            cursor = foreground
        } else {
            switch colour("cursor", in: json) {
            case .success(let value): cursor = value
            case .failure(let error): return .failure(error)
            }
        }

        let ansi: [RGB]
        switch parseAnsi(json["ansi"]) {
        case .success(let value): ansi = value
        case .failure(let error): return .failure(error)
        }

        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(
            TerminalTheme(
                name: (name?.isEmpty ?? true) ? fallbackName : name!,
                background: background,
                foreground: foreground,
                cursor: cursor,
                ansi: ansi
            )
        )
    }

    /// Both spellings of the palette: named slots, or sixteen in wire order.
    private static func parseAnsi(_ raw: Any?) -> Result<[RGB], ThemeFileError> {
        guard let raw else { return .failure(.missing("ansi")) }

        if let named = raw as? [String: Any] {
            var out: [RGB] = []
            for slot in ansiSlots {
                guard let value = named[slot] else {
                    return .failure(.missing("ansi.\(slot)"))
                }
                let text = value as? String ?? ""
                guard let parsed = RGB(hex: text) else {
                    return .failure(.badColour(field: "ansi.\(slot)", value: text))
                }
                out.append(parsed)
            }
            return .success(out)
        }

        if let list = raw as? [Any] {
            guard list.count == 16 else { return .failure(.wrongSlotCount(list.count)) }
            var out: [RGB] = []
            for (index, value) in list.enumerated() {
                let text = value as? String ?? ""
                guard let parsed = RGB(hex: text) else {
                    return .failure(.badColour(field: "ansi[\(index)]", value: text))
                }
                out.append(parsed)
            }
            return .success(out)
        }

        return .failure(.missing("ansi"))
    }

    // MARK: - Writing

    /// A theme as text, in the order a person reads it.
    ///
    /// Hand-built rather than handed to `JSONSerialization`. Its `.sortedKeys`
    /// is alphabetical, which puts the sixteen-entry palette above the three
    /// colours that decide whether the theme works at all, and its output with
    /// `.prettyPrinted` alone has no stable order between runs — so a file
    /// rewritten by the app would produce a diff that is entirely reordering.
    ///
    /// The result is valid JSON and round-trips through `parse`, which is a
    /// test.
    static func serialise(_ theme: TerminalTheme) -> String {
        var lines: [String] = ["{"]
        lines.append("  \"name\": \(quoted(theme.name)),")
        lines.append("  \"background\": \"\(theme.background.hex)\",")
        lines.append("  \"foreground\": \"\(theme.foreground.hex)\",")
        lines.append("  \"cursor\": \"\(theme.cursor.hex)\",")
        lines.append("  \"ansi\": {")
        for (index, slot) in ansiSlots.enumerated() {
            let colour = index < theme.ansi.count ? theme.ansi[index] : RGB(0, 0, 0)
            let comma = index == ansiSlots.count - 1 ? "" : ","
            lines.append("    \"\(slot)\": \"\(colour.hex)\"\(comma)")
        }
        lines.append("  }")
        lines.append("}")
        // A trailing newline, because the file is opened in an editor and a file
        // without one makes vim say `[noeol]` about something the app wrote.
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quoted(_ text: String) -> String {
        var escaped = ""
        for character in text.unicodeScalars {
            switch character {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    // MARK: - Names

    /// A filename for a theme called `name`.
    ///
    /// Lowercased, spaces to hyphens, and anything that is not a letter, digit
    /// or hyphen dropped. Not decoration: this string becomes a path, and a
    /// theme called `../../etc/hosts` or `My "Best" Theme` must not be able to
    /// write outside the themes directory or produce a name a shell mangles.
    static func slug(_ name: String) -> String {
        var out = ""
        var lastWasHyphen = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasHyphen = false
            } else if !lastWasHyphen, !out.isEmpty {
                out.append("-")
                lastWasHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        // A name made entirely of punctuation still needs a file to live in.
        return out.isEmpty ? "theme" : out
    }

    /// `taken` already holds `midnight`, so the next one is `midnight-2`.
    ///
    /// Counting rather than a timestamp or a UUID: the filename is shown to the
    /// user and typed by them, and `midnight-2` is a name while
    /// `midnight-9F3A21C4` is an identifier that happens to be a name.
    static func uniqueSlug(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    /// The same idea for the name a human reads, which is a separate string
    /// from the slug and needs the same guarantee.
    ///
    /// Only the filename was made unique, so a second copy landed in
    /// `...-copy-2.json` carrying the name "Violeeter Dark (edited) copy" —
    /// the same name the first one had. The picker then drew two identical
    /// rows, and the only way to tell which was which was to pick one and see
    /// what happened. Seen on screen with three of them.
    ///
    /// Numbered in words rather than by slug, because this string is read:
    /// "... copy 2" is what the Finder does and what a person expects.
    static func uniqueName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}
