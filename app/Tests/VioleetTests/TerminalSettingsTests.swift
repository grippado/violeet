// Tests for the settings value and its storage.
//
// The failure mode here is not a crash on screen — it is a preferences file
// that stops the app from starting, or one that silently loses a setting a
// different build wrote. Both are invisible until someone loses work.

import Foundation
import Testing

@testable import Violeet

@Suite("Colour")
struct RGBTests {
    @Test func hex_round_trips_exactly() {
        let color = RGB(0x2E, 0x34, 0x40)
        #expect(color.hex == "#2E3440")
        #expect(RGB(hex: color.hex) == color)
    }

    @Test func hex_accepts_both_spellings_and_any_case() {
        #expect(RGB(hex: "#2e3440") == RGB(0x2E, 0x34, 0x40))
        #expect(RGB(hex: "2E3440") == RGB(0x2E, 0x34, 0x40))
        #expect(RGB(hex: "  #2E3440  ") == RGB(0x2E, 0x34, 0x40))
    }

    /// Anything that is not exactly six digits is rejected rather than guessed
    /// at. The three-digit form is unambiguous to write and ambiguous to read
    /// back, and a half-typed value must not be applied.
    @Test func anything_else_is_rejected_rather_than_guessed() {
        #expect(RGB(hex: "#2E4") == nil)
        #expect(RGB(hex: "") == nil)
        #expect(RGB(hex: "#GGGGGG") == nil)
        #expect(RGB(hex: "#2E344001") == nil)
    }

    /// White must come out `0xFFFF` per channel, not `0xFF00`. A left shift
    /// would make every bright colour slightly dim, which is the kind of wrong
    /// that never gets reported because it just looks like the theme.
    @Test func widening_to_sixteen_bits_reaches_full_scale() {
        #expect(RGB(0xFF, 0xFF, 0xFF).swiftTerm.red == 0xFFFF)
        #expect(RGB(0x00, 0x00, 0x00).swiftTerm.red == 0)
    }

    @Test func brightness_decides_which_tick_a_swatch_needs() {
        #expect(RGB(0xFA, 0xFA, 0xFA).isLight)
        #expect(!RGB(0x11, 0x13, 0x16).isLight)
    }
}

@Suite("Settings storage")
struct TerminalSettingsCodecTests {
    /// The rule this file exists for: a stored value must never be able to stop
    /// the app. Every one of these is nonsense of a different shape, and every
    /// one has to produce a usable settings value.
    @Test func garbage_falls_back_field_by_field_instead_of_failing() {
        let cases: [[String: Any]] = [
            [:],
            ["font": "not an object"],
            ["font": ["size": "thirteen"]],
            ["appearance": ["background": "not a colour"]],
            ["cursor": ["shape": "spiral"]],
            ["window": ["opacity": "half"]],
            ["behaviour": ["scrollback": "lots"]],
        ]
        let fallback = TerminalSettings()
        for json in cases {
            let loaded = TerminalSettings(json: json)
            #expect(loaded.font.size == fallback.font.size, "for \(json)")
            #expect(loaded.cursor.shape == fallback.cursor.shape, "for \(json)")
        }
    }

    @Test func a_full_round_trip_preserves_every_field() {
        var settings = TerminalSettings()
        settings.appearance.background = RGB(0x01, 0x02, 0x03)
        settings.appearance.foreground = RGB(0x04, 0x05, 0x06)
        settings.appearance.cursorColor = RGB(0x07, 0x08, 0x09)
        settings.font.name = "Menlo"
        settings.font.size = 15
        settings.font.lineSpacing = 1.25
        settings.padding.horizontal = 12
        settings.padding.vertical = 8
        settings.cursor.shape = .underline
        settings.cursor.blinks = false
        settings.window.opacity = 0.75
        settings.window.blur = false
        settings.window.interfaceFontSize = 16
        settings.behaviour.scrollbackLines = 50_000
        settings.behaviour.shellOverride = "/bin/bash"
        settings.behaviour.wrapLines = false

        let restored = TerminalSettings(json: settings.json())
        #expect(restored == settings)
    }

    /// A partial palette would silently mix two themes. A terminal whose red is
    /// Nord's and whose green is Gruvbox's is worse than one that ignored the
    /// file.
    @Test func a_palette_is_all_sixteen_colours_or_none_of_them() {
        let short = TerminalSettings(json: ["appearance": ["ansi": ["#000000", "#FFFFFF"]]])
        #expect(short.appearance.ansi == TerminalSettings().appearance.ansi)

        var broken = TerminalTheme.builtins[1].ansi.map(\.hex)
        broken[7] = "nope"
        let mixed = TerminalSettings(json: ["appearance": ["ansi": broken]])
        #expect(mixed.appearance.ansi == TerminalSettings().appearance.ansi)

        let whole = TerminalSettings(
            json: ["appearance": ["ansi": TerminalTheme.builtins[1].ansi.map(\.hex)]]
        )
        #expect(whole.appearance.ansi == TerminalTheme.builtins[1].ansi)
    }

    /// A release build and a dev build share one preferences domain, and this
    /// project runs both daily. Without preservation, whichever saved last
    /// would delete the other's fields.
    @Test func a_field_this_build_does_not_know_survives_a_save() {
        let fromTheFuture: [String: Any] = [
            "font": ["name": "Menlo", "size": 14.0, "ligatures": true],
            "somethingEntirelyNew": ["enabled": true],
        ]
        let settings = TerminalSettings(json: fromTheFuture)
        let saved = settings.json(preserving: fromTheFuture)

        #expect(saved["somethingEntirelyNew"] != nil, "an unknown section must not be dropped")
        let font = saved["font"] as? [String: Any]
        #expect(font?["ligatures"] as? Bool == true, "an unknown key inside a known section too")
        #expect(font?["name"] as? String == "Menlo", "and what we do know is still written")
    }

    /// Out-of-range values are clamped rather than rejected, because a file
    /// carrying `size: 400` should give a very large font, not no font.
    @Test func out_of_range_values_are_clamped_into_something_usable() {
        let huge = TerminalSettings(json: ["font": ["size": 400.0], "window": ["opacity": 4.0]])
        #expect(huge.font.size == TerminalSettings.FontSettings.sizeRange.upperBound)
        #expect(huge.window.opacity == TerminalSettings.WindowSettings.opacityRange.upperBound)

        #expect(
            TerminalSettings(json: ["window": ["interfaceFontSize": 99.0]]).window.interfaceFontSize
                == TerminalSettings.WindowSettings.interfaceFontSizeRange.upperBound
        )
        #expect(
            TerminalSettings(json: ["window": ["interfaceFontSize": 1.0]]).window.interfaceFontSize
                == TerminalSettings.WindowSettings.interfaceFontSizeRange.lowerBound
        )

        let tiny = TerminalSettings(json: ["font": ["size": -3.0], "window": ["opacity": 0.0]])
        #expect(tiny.font.size == TerminalSettings.FontSettings.sizeRange.lowerBound)
        #expect(tiny.window.opacity == TerminalSettings.WindowSettings.opacityRange.lowerBound)
    }
}

@Suite("Themes")
struct ThemeTests {
    @Test func every_builtin_theme_has_a_full_palette() {
        for theme in TerminalTheme.builtins {
            #expect(theme.ansi.count == 16, "\(theme.name)")
        }
    }

    /// A preset that still shows as selected after its colours were edited is
    /// claiming something about the screen that is not true.
    @Test func editing_a_colour_stops_the_preset_from_claiming_to_be_selected() {
        var settings = TerminalSettings()
        settings.apply(theme: TerminalTheme.builtins[1])
        #expect(settings.matchesNamedTheme)

        settings.appearance.ansi[3] = RGB(0x12, 0x34, 0x56)
        #expect(!settings.matchesNamedTheme)
    }

    /// Dracula is fixed by a published specification, which is why it looks the
    /// same in fifty editors. Approximating it here would make this the one
    /// place it does not.
    @Test func dracula_matches_its_published_values() {
        let dracula = try! #require(TerminalTheme.named("Dracula"))
        #expect(dracula.background == RGB(0x28, 0x2A, 0x36))
        #expect(dracula.foreground == RGB(0xF8, 0xF8, 0xF2))
        #expect(dracula.ansi.count == 16)
        #expect(dracula.ansi[1] == RGB(0xFF, 0x55, 0x55), "red")
        #expect(dracula.ansi[2] == RGB(0x50, 0xFA, 0x7B), "green")
        #expect(dracula.ansi[8] == RGB(0x62, 0x72, 0xA4), "brightBlack, its comment colour")
    }

    /// Every theme in the picker must be reachable by name, since that is how
    /// the stored preference finds it again after a relaunch.
    @Test func every_builtin_is_reachable_by_name() {
        for theme in TerminalTheme.builtins {
            #expect(TerminalTheme.named(theme.name) != nil, "\(theme.name)")
        }
    }

    // MARK: - Palette identity

    /// The question the panel actually needs answered, and the one it used to
    /// get wrong by asking `matchesNamedTheme` instead.
    ///
    /// The two agree only while every theme is a built-in. A theme loaded from a
    /// file never matches a built-in, so the old test was false for it always —
    /// and changing the font size, a setting with no colour in it, would throw
    /// away the theme's name and the file the app was watching.
    @Test func the_palette_only_moves_when_a_colour_moves() {
        var settings = TerminalSettings()
        settings.apply(theme: TerminalTheme.builtins[0])
        let before = settings.palette

        settings.font.size = 20
        settings.window.opacity = 0.8
        settings.behaviour.scrollbackLines = 500
        #expect(settings.palette == before, "no colour was touched")

        settings.appearance.ansi[3] = RGB(0x12, 0x34, 0x56)
        #expect(settings.palette != before)
    }

    /// All twenty, so a change to any one of them is caught.
    @Test func the_palette_covers_every_colour_a_theme_sets() {
        let settings = TerminalSettings()
        #expect(settings.palette.count == 19, "background, foreground, cursor and sixteen ANSI")
    }

    // MARK: - Theme files

    /// The path is what lets the app keep watching the file across a relaunch,
    /// so it has to survive the round trip through preferences.
    @Test func a_theme_file_path_is_remembered() {
        var settings = TerminalSettings()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("violeet-theme-test-\(UUID().uuidString).json")
        try? Data("{}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        settings.apply(theme: TerminalTheme.builtins[0], from: file.path)
        #expect(settings.appearance.themeFile == file.path)

        let restored = TerminalSettings(json: settings.json())
        #expect(restored.appearance.themeFile == file.path)
    }

    /// A path that no longer resolves is dropped rather than restored. Kept, it
    /// would leave the app watching nothing while the picker insists a custom
    /// theme is selected — and a synced preferences file carries paths from
    /// machines this one has never seen.
    @Test func a_theme_file_that_is_gone_is_forgotten() {
        var settings = TerminalSettings()
        settings.apply(theme: TerminalTheme.builtins[0], from: "/nowhere/at/all/theme.json")

        let restored = TerminalSettings(json: settings.json())
        #expect(restored.appearance.themeFile == nil)
        #expect(restored.appearance.background == settings.appearance.background,
                "the colours are stored here too, so nothing on screen changes")
    }

    /// Choosing a built-in lets go of the file, so a later save to it cannot
    /// silently pull the terminal back off the built-in.
    @Test func applying_a_builtin_releases_the_file() {
        var settings = TerminalSettings()
        settings.apply(theme: TerminalTheme.builtins[0], from: "/tmp/whatever.json")
        settings.apply(theme: TerminalTheme.builtins[1])
        #expect(settings.appearance.themeFile == nil)
    }

    @Test func the_default_theme_is_dark() {
        let settings = TerminalSettings()
        #expect(!settings.appearance.background.isLight)
        #expect(settings.appearance.foreground.isLight)
    }

    /// Translucency is off unless asked for, and asking for it is what makes
    /// the blur worth compositing.
    @Test func a_window_is_opaque_until_told_otherwise() {
        #expect(!TerminalSettings().window.isTranslucent)
        var translucent = TerminalSettings()
        translucent.window.opacity = 0.8
        #expect(translucent.window.isTranslucent)
    }
}

@Suite("Window chrome")
struct WindowChromeTests {
    /// The chrome is derived so that every theme — including one mixed by hand
    /// — gets a window that belongs to it. A fixed grey beside a violet
    /// terminal reads as two applications sharing a window.
    @Test func surfaces_step_away_from_the_background_in_order() {
        let chrome = WindowChrome(background: RGB(0x24, 0x20, 0x3F))
        let steps = [chrome.surfaceResolved, chrome.raisedResolved, chrome.borderResolved]
        let luminance = steps.map { Double($0.r) + Double($0.g) + Double($0.b) }
        #expect(luminance == luminance.sorted(), "each step must be lighter than the last")
        #expect(chrome.surfaceResolved != chrome.base, "the surface must be distinguishable")
    }

    /// Lightening an almost-white background produces surfaces nobody can tell
    /// apart, so a light theme has to step the other way.
    @Test func a_light_theme_steps_darker_rather_than_lighter() {
        let chrome = WindowChrome(background: RGB(0xFA, 0xFA, 0xFA))
        #expect(chrome.isLight)
        let surface = chrome.surfaceResolved
        #expect(Int(surface.r) < 0xFA, "a light theme's surface must be darker than its background")
    }

    /// Mixing must saturate rather than wrap. A channel at 0xFF lightened
    /// further has to stay 0xFF, not roll over to black.
    @Test func mixing_saturates_at_both_ends() {
        #expect(RGB(0xFF, 0xFF, 0xFF).lightened(by: 0.5) == RGB(0xFF, 0xFF, 0xFF))
        #expect(RGB(0x00, 0x00, 0x00).darkened(by: 0.5) == RGB(0x00, 0x00, 0x00))
    }
}

@Suite("The house palette")
struct HousePaletteTests {
    /// The base is purple, not blue: red must sit above green. `#222240` has
    /// them equal, which the eye reads as cold blue-violet.
    @Test func the_default_background_reads_as_purple() {
        let theme = TerminalTheme.builtins[0]
        #expect(theme.name == "Violeeter Dark")
        #expect(theme.background.r > theme.background.g, "red above green is what makes it purple")
        #expect(theme.background.b > theme.background.r)
    }

    /// Colour 0 is used as a foreground by plenty of tools. On a dark theme it
    /// has to be a step *above* the background, or that text is invisible.
    @Test func ansi_black_is_visible_against_the_background() {
        let theme = TerminalTheme.builtins[0]
        let sum = { (c: RGB) in Int(c.r) + Int(c.g) + Int(c.b) }
        #expect(sum(theme.ansi[0]) > sum(theme.background))
    }

    /// A violet background sits close to the usual terminal blue. If they do
    /// not separate, blue output disappears into the page.
    @Test func blue_separates_from_a_violet_background() {
        let theme = TerminalTheme.builtins[0]
        for blue in [theme.ansi[4], theme.ansi[12]] {
            let distance = abs(Int(blue.r) - Int(theme.background.r))
                + abs(Int(blue.g) - Int(theme.background.g))
                + abs(Int(blue.b) - Int(theme.background.b))
            #expect(distance > 300, "blue \(blue.hex) is too close to \(theme.background.hex)")
        }
    }
}

@Suite("Cursor")
struct CursorTests {
    /// SwiftTerm carries shape and blink in one enum, so every combination has
    /// to resolve to a distinct style — a mapping that collapsed two of them
    /// would silently ignore the blink toggle for one shape.
    @Test func every_shape_and_blink_combination_is_distinct() {
        var seen = Set<String>()
        for shape in TerminalSettings.CursorSettings.Shape.allCases {
            for blinking in [true, false] {
                let style = shape.swiftTermStyle(blinking: blinking)
                #expect(seen.insert("\(style)").inserted, "\(shape) blinking=\(blinking)")
            }
        }
        #expect(seen.count == 6)
    }
}

@Suite("Fonts")
struct FontTests {
    /// A font name that resolved when it was written can stop resolving. A
    /// terminal with no font is not a state worth supporting.
    @Test func an_unresolvable_family_falls_back_to_a_monospaced_system_font() {
        let font = MonospacedFonts.font(named: "This Font Does Not Exist", size: 13)
        #expect(font.pointSize == 13)
        #expect(font.isFixedPitch)
    }

    @Test func the_default_family_resolves_on_this_machine() {
        let font = MonospacedFonts.font(named: "SF Mono", size: 13)
        #expect(font.isFixedPitch)
    }

    /// The list is what the panel offers. An empty one would be a menu with
    /// nothing in it.
    @Test func at_least_one_monospaced_family_is_offered() {
        #expect(!MonospacedFonts.available.isEmpty)
    }
}
