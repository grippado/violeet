// The house palette, and the one way it can go wrong.
//
// Violeeter is developed in its own repository and vendored here as
// `vendor/violeeter/violeeter.json` — see that directory's README. These
// values are transcribed into Swift, which means there are two copies, which
// means they can disagree — and a palette that is *almost* the same in the app
// and in the file people download is worse than two different palettes, because
// the difference reads as a rendering bug rather than a choice.
//
// So the test reads the JSON off disk and compares. It is skipped rather than
// failed when the file cannot be found, because a test binary run from
// somewhere without the repository beside it has learned nothing about the
// palette.

import Foundation
import Testing

@testable import Violeet

@Suite("Violeeter palette")
struct VioleeterTests {
    /// Walk up from this file to the repository, since the test's working
    /// directory is not something to rely on.
    private var themeFile: URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("vendor/violeeter/violeeter.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private struct Variant: Decodable {
        let name: String
        let background: String
        let foreground: String
        let cursor: String
        let ansi: [String: String]
    }

    private struct File: Decodable {
        let variants: [String: Variant]
    }

    private static let order = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow",
        "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
    ]

    private func hex(_ colour: RGB) -> String {
        String(format: "#%02X%02X%02X", colour.r, colour.g, colour.b)
    }

    @Test("the built-in palette matches the published one")
    func matchesPublishedTheme() throws {
        guard let themeFile, let data = try? Data(contentsOf: themeFile) else { return }
        let file = try JSONDecoder().decode(File.self, from: data)

        for (_, variant) in file.variants {
            guard let builtin = TerminalTheme.named(variant.name) else {
                Issue.record("\(variant.name) is published but not built in")
                continue
            }
            #expect(hex(builtin.background) == variant.background.uppercased(), "\(variant.name) background")
            #expect(hex(builtin.foreground) == variant.foreground.uppercased(), "\(variant.name) foreground")
            #expect(hex(builtin.cursor) == variant.cursor.uppercased(), "\(variant.name) cursor")
            #expect(builtin.ansi.count == 16, "\(variant.name) needs 16 ANSI entries")
            for (index, slot) in Self.order.enumerated() where index < builtin.ansi.count {
                #expect(
                    hex(builtin.ansi[index]) == variant.ansi[slot]?.uppercased(),
                    "\(variant.name) \(slot)"
                )
            }
        }
    }

    /// The dark variant is what opens on a fresh install. It is the reason the
    /// terminal has the name it has.
    @Test("Violeeter Dark is the default")
    func darkIsDefault() {
        #expect(TerminalTheme.builtins.first?.name == "Violeeter Dark")
    }

    @Test("both variants are built in")
    func bothVariantsPresent() {
        #expect(TerminalTheme.named("Violeeter Dark") != nil)
        #expect(TerminalTheme.named("Violeeter Light") != nil)
    }
}
