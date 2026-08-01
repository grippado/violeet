// Everything the terminal looks and behaves like, as one value.
//
// # Why a struct and not fields on `Preferences`
//
// Scope for v0 is **global**: one set of settings, every tab. Per-tab settings
// with inheritance were considered and rejected for now, and not because of the
// storage. Every control would grow a third state — inherited, overridden, and
// the affordance to go back to inherited — and the panel would have to answer a
// question the product has not answered: *which* tab is it editing? The
// selected one, presumably, which means the same slider silently retargets when
// you switch tabs, with nothing on screen saying so. That is exactly the hidden
// coupling the focus requirement is trying to avoid elsewhere.
//
// But it is kept as a value type so that decision stays cheap to revisit. A tab
// holding its own copy later is a change to where the struct comes from, not a
// rewrite of the panel.
//
// # Migration
//
// Every field decodes independently, and a missing one falls back to the
// default rather than failing the whole load. A settings file written by an
// older build — or a newer one — must never be able to stop the app from
// starting. `Codable` synthesis would give the opposite behaviour, so the
// decoding is written out.

import AppKit
import Foundation
import SwiftTerm

struct TerminalSettings: Equatable {
    var appearance = Appearance()
    var font = FontSettings()
    var padding = PaddingSettings()
    var cursor = CursorSettings()
    var window = WindowSettings()
    var behaviour = BehaviourSettings()

    // MARK: Appearance

    struct Appearance: Equatable {
        /// The named palette this was last set from, so the panel can show
        /// which preset is active. `nil` once any colour is edited by hand —
        /// a preset that still claims to be selected after being altered is
        /// lying about what is on screen.
        var themeName: String? = TerminalTheme.builtins[0].name
        var background: RGB = TerminalTheme.builtins[0].background
        var foreground: RGB = TerminalTheme.builtins[0].foreground
        var cursorColor: RGB = TerminalTheme.builtins[0].cursor
        /// The 16 ANSI colours, in the standard order: eight normal, eight
        /// bright.
        var ansi: [RGB] = TerminalTheme.builtins[0].ansi
    }

    // MARK: Font

    struct FontSettings: Equatable {
        var name: String = "SF Mono"
        var size: CGFloat = 13
        /// A multiplier, as SwiftTerm defines it: 1.0 is the font's own
        /// leading, 1.1 is iTerm2's "110% vertical spacing".
        var lineSpacing: CGFloat = 1.0

        static let sizeRange: ClosedRange<CGFloat> = 8...32
        static let lineSpacingRange: ClosedRange<CGFloat> = 0.8...2.0
    }

    /// Breathing room between the grid and the edges of its pane.
    ///
    /// Its own thing rather than part of `FontSettings`, because it costs
    /// columns and rows the same way the font does but for a different reason:
    /// the font decides how big a cell is, this decides how much of the pane is
    /// not cells at all. Both end at the same place — the child has to be told.
    struct PaddingSettings: Equatable {
        var horizontal: CGFloat = 0
        var vertical: CGFloat = 0

        static let range: ClosedRange<CGFloat> = 0...32
    }

    // MARK: Cursor

    struct CursorSettings: Equatable {
        var shape: Shape = .block
        var blinks: Bool = true

        enum Shape: String, CaseIterable, Equatable {
            case block, bar, underline

            var label: String {
                switch self {
                case .block: return "Block"
                case .bar: return "Bar"
                case .underline: return "Underline"
                }
            }

            /// SwiftTerm carries blink in the same enum, so the pair is
            /// resolved together rather than stored together.
            func swiftTermStyle(blinking: Bool) -> CursorStyle {
                switch (self, blinking) {
                case (.block, true): return .blinkBlock
                case (.block, false): return .steadyBlock
                case (.bar, true): return .blinkBar
                case (.bar, false): return .steadyBar
                case (.underline, true): return .blinkUnderline
                case (.underline, false): return .steadyUnderline
                }
            }
        }
    }

    // MARK: Window

    struct WindowSettings: Equatable {
        /// 1.0 is opaque. Below 1, the terminal's background is drawn
        /// translucent and whatever is behind the window shows through.
        var opacity: Double = 1.0
        /// Frost the translucency instead of leaving it clear. Only has an
        /// effect below full opacity — a blur behind an opaque surface is work
        /// nobody can see.
        var blur: Bool = true

        static let opacityRange: ClosedRange<Double> = 0.3...1.0

        var isTranslucent: Bool { opacity < 0.999 }
    }

    // MARK: Behaviour

    struct BehaviourSettings: Equatable {
        var scrollbackLines: Int = 10_000
        /// Empty means "whatever the account's shell is", resolved at spawn.
        /// Stored rather than resolved so a machine that changes its shell is
        /// followed rather than pinned.
        var shellOverride: String = ""
        /// Long lines wrap to the next row instead of being clipped.
        var wrapLines: Bool = true

        static let scrollbackChoices = [1_000, 5_000, 10_000, 50_000, 100_000]
    }
}

// MARK: - Colour

/// A colour as eight bits per channel, which is how every terminal palette in
/// the world is written down.
///
/// Not `SwiftUI.Color` and not `NSColor`: both are device- and
/// colour-space-dependent, neither round-trips through a hex string exactly,
/// and a palette that shifts slightly every time it is saved and loaded is a
/// palette nobody can share.
struct RGB: Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `#RRGGBB` or `RRGGBB`, case-insensitive. `nil` for anything else —
    /// including the three-digit form, which is unambiguous to write and
    /// ambiguous to read back.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        )
    }

    var hex: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }

    /// SwiftTerm stores 16 bits per channel. `× 257` rather than `<< 8` so
    /// `0xFF` becomes `0xFFFF` and not `0xFF00` — the shift would make white
    /// slightly grey and every bright colour slightly dim.
    var swiftTerm: SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(r) * 257,
            green: UInt16(g) * 257,
            blue: UInt16(b) * 257
        )
    }

    /// This colour mixed `amount` of the way toward white.
    ///
    /// How every surface of the window chrome is derived from the terminal's
    /// background, so the sidebar and the settings panel belong to whatever
    /// theme is active instead of being a fixed grey beside it.
    func lightened(by amount: Double) -> RGB {
        func mix(_ channel: UInt8) -> UInt8 {
            let value = Double(channel) + (255 - Double(channel)) * amount
            return UInt8(min(max(value.rounded(), 0), 255))
        }
        return RGB(mix(r), mix(g), mix(b))
    }

    /// And toward black, for the recess behind everything.
    func darkened(by amount: Double) -> RGB {
        func mix(_ channel: UInt8) -> UInt8 {
            UInt8(min(max((Double(channel) * (1 - amount)).rounded(), 0), 255))
        }
        return RGB(mix(r), mix(g), mix(b))
    }

    /// Perceived brightness, for deciding whether a swatch needs a light or
    /// dark check mark drawn on it.
    var isLight: Bool {
        (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255 > 0.55
    }
}

/// The window's own surfaces, derived from the terminal's background.
///
/// Not a second palette to keep in sync. The sidebar used a system material,
/// which is a fixed grey: beside a violet terminal it reads as a different
/// application sharing a window. Deriving instead means every theme — including
/// one the user mixes by hand — gets a window that belongs to it, and there is
/// no theme that can be chosen and then look wrong.
///
/// The steps are small on purpose. Chrome that contrasts with the terminal
/// competes with it, and the terminal is what the window is for.
struct WindowChrome {
    let base: RGB

    init(background: RGB) {
        self.base = background
    }

    /// Behind the sidebars.
    var surface: RGB { base.lightened(by: 0.06) }
    /// Cards, and anything that sits on the surface.
    var raised: RGB { base.lightened(by: 0.12) }
    /// Hairlines.
    var border: RGB { base.lightened(by: 0.22) }
    /// The recess behind everything, for gaps that must not glow.
    var recess: RGB { base.darkened(by: 0.25) }

    /// A light theme has to go the other way: lightening an almost-white
    /// background produces surfaces nobody can tell apart.
    var isLight: Bool { base.isLight }

    var surfaceResolved: RGB { isLight ? base.darkened(by: 0.04) : surface }
    var raisedResolved: RGB { isLight ? base.darkened(by: 0.08) : raised }
    var borderResolved: RGB { isLight ? base.darkened(by: 0.18) : border }
}

// MARK: - Themes

/// A named palette. Curated, and deliberately a small list: the panel has no
/// colour *picker*, so these plus a hex field are the whole surface.
struct TerminalTheme: Equatable {
    let name: String
    let background: RGB
    let foreground: RGB
    let cursor: RGB
    /// 16 entries: eight normal, then eight bright.
    let ansi: [RGB]

    /// Dark first, and dark by default. This is a terminal for watching agents
    /// work, which people do for hours.
    static let builtins: [TerminalTheme] = [
        // The house palette, built from one base colour.
        //
        // The base asked for was `#222240`, and it is `R=34 G=34 B=64`: with red
        // and green equal, the eye reads cold blue-violet rather than purple.
        // `#24203F` puts red a step above green at the same luminance, which is
        // what makes it read as purple without making it louder.
        //
        // Two things follow from a violet background and neither is optional.
        // **Blue has to move**: the default terminal blue sits a few degrees
        // from this background and the two stop separating, so it is lifted and
        // pulled toward cyan. **Neutral grey text reads yellow** against a cold
        // ground, so the foreground carries a trace of the same hue.
        TerminalTheme(
            name: "aiterm violet",
            background: RGB(0x24, 0x20, 0x3F),
            foreground: RGB(0xD9, 0xD6, 0xEC),
            cursor: RGB(0xC7, 0x8B, 0xF7),
            ansi: [
                // Normal. "Black" is a step *above* the background, not below:
                // a terminal that prints black on black is a terminal with
                // invisible text, and plenty of tools use colour 0.
                RGB(0x3A, 0x35, 0x5E), RGB(0xFF, 0x6B, 0x81), RGB(0x6F, 0xE3, 0x9B),
                RGB(0xF2, 0xC9, 0x7B), RGB(0x7F, 0xAE, 0xFF), RGB(0xC7, 0x8B, 0xF7),
                RGB(0x6F, 0xE0, 0xE0), RGB(0xD9, 0xD6, 0xEC),
                // Bright.
                RGB(0x55, 0x4F, 0x7E), RGB(0xFF, 0x93, 0xA4), RGB(0x96, 0xF0, 0xB8),
                RGB(0xF7, 0xDA, 0x9E), RGB(0xA6, 0xC7, 0xFF), RGB(0xDC, 0xA9, 0xFF),
                RGB(0x96, 0xEF, 0xEF), RGB(0xF3, 0xF1, 0xFF),
            ]
        ),
        TerminalTheme(
            name: "aiterm dark",
            background: RGB(0x11, 0x13, 0x16),
            foreground: RGB(0xD8, 0xDE, 0xE9),
            cursor: RGB(0xE8, 0xB1, 0x39),
            ansi: [
                RGB(0x2E, 0x34, 0x36), RGB(0xFF, 0x6B, 0x6B), RGB(0x5F, 0xD7, 0x5F),
                RGB(0xE8, 0xB1, 0x39), RGB(0x6F, 0xB7, 0xFF), RGB(0xC7, 0x8B, 0xF7),
                RGB(0x5F, 0xD7, 0xD7), RGB(0xD8, 0xDE, 0xE9),
                RGB(0x55, 0x5F, 0x66), RGB(0xFF, 0x8A, 0x8A), RGB(0x8A, 0xE8, 0x8A),
                RGB(0xF2, 0xC9, 0x6B), RGB(0x94, 0xCB, 0xFF), RGB(0xDA, 0xAE, 0xFA),
                RGB(0x8A, 0xE8, 0xE8), RGB(0xFF, 0xFF, 0xFF),
            ]
        ),
        TerminalTheme(
            name: "Solarized Dark",
            background: RGB(0x00, 0x2B, 0x36),
            foreground: RGB(0x83, 0x94, 0x96),
            cursor: RGB(0x93, 0xA1, 0xA1),
            ansi: [
                RGB(0x07, 0x36, 0x42), RGB(0xDC, 0x32, 0x2F), RGB(0x85, 0x99, 0x00),
                RGB(0xB5, 0x89, 0x00), RGB(0x26, 0x8B, 0xD2), RGB(0xD3, 0x36, 0x82),
                RGB(0x2A, 0xA1, 0x98), RGB(0xEE, 0xE8, 0xD5),
                RGB(0x00, 0x2B, 0x36), RGB(0xCB, 0x4B, 0x16), RGB(0x58, 0x6E, 0x75),
                RGB(0x65, 0x7B, 0x83), RGB(0x83, 0x94, 0x96), RGB(0x6C, 0x71, 0xC4),
                RGB(0x93, 0xA1, 0xA1), RGB(0xFD, 0xF6, 0xE3),
            ]
        ),
        TerminalTheme(
            name: "Nord",
            background: RGB(0x2E, 0x34, 0x40),
            foreground: RGB(0xD8, 0xDE, 0xE9),
            cursor: RGB(0xD8, 0xDE, 0xE9),
            ansi: [
                RGB(0x3B, 0x42, 0x52), RGB(0xBF, 0x61, 0x6A), RGB(0xA3, 0xBE, 0x8C),
                RGB(0xEB, 0xCB, 0x8B), RGB(0x81, 0xA1, 0xC1), RGB(0xB4, 0x8E, 0xAD),
                RGB(0x88, 0xC0, 0xD0), RGB(0xE5, 0xE9, 0xF0),
                RGB(0x4C, 0x56, 0x6A), RGB(0xBF, 0x61, 0x6A), RGB(0xA3, 0xBE, 0x8C),
                RGB(0xEB, 0xCB, 0x8B), RGB(0x81, 0xA1, 0xC1), RGB(0xB4, 0x8E, 0xAD),
                RGB(0x8F, 0xBC, 0xBB), RGB(0xEC, 0xEF, 0xF4),
            ]
        ),
        TerminalTheme(
            name: "Gruvbox Dark",
            background: RGB(0x28, 0x28, 0x28),
            foreground: RGB(0xEB, 0xDB, 0xB2),
            cursor: RGB(0xFE, 0x80, 0x19),
            ansi: [
                RGB(0x28, 0x28, 0x28), RGB(0xCC, 0x24, 0x1D), RGB(0x98, 0x97, 0x1A),
                RGB(0xD7, 0x99, 0x21), RGB(0x45, 0x85, 0x88), RGB(0xB1, 0x62, 0x86),
                RGB(0x68, 0x9D, 0x6A), RGB(0xA8, 0x99, 0x84),
                RGB(0x92, 0x83, 0x74), RGB(0xFB, 0x49, 0x34), RGB(0xB8, 0xBB, 0x26),
                RGB(0xFA, 0xBD, 0x2F), RGB(0x83, 0xA5, 0x98), RGB(0xD3, 0x86, 0x9B),
                RGB(0x8E, 0xC0, 0x7C), RGB(0xEB, 0xDB, 0xB2),
            ]
        ),
        TerminalTheme(
            name: "Light",
            background: RGB(0xFA, 0xFA, 0xFA),
            foreground: RGB(0x24, 0x29, 0x2E),
            cursor: RGB(0x00, 0x5C, 0xC5),
            ansi: [
                RGB(0x24, 0x29, 0x2E), RGB(0xD1, 0x34, 0x38), RGB(0x1A, 0x7F, 0x37),
                RGB(0x95, 0x36, 0x00), RGB(0x00, 0x5C, 0xC5), RGB(0x81, 0x50, 0xB4),
                RGB(0x1B, 0x7C, 0x83), RGB(0x6E, 0x77, 0x81),
                RGB(0x57, 0x60, 0x6A), RGB(0xA4, 0x0E, 0x26), RGB(0x11, 0x6A, 0x2E),
                RGB(0x7A, 0x2C, 0x00), RGB(0x03, 0x4C, 0xA3), RGB(0x62, 0x39, 0xA5),
                RGB(0x15, 0x66, 0x6B), RGB(0x24, 0x29, 0x2E),
            ]
        ),
    ]

    static func named(_ name: String) -> TerminalTheme? {
        builtins.first { $0.name == name }
    }
}

// MARK: - Fonts

enum MonospacedFonts {
    /// Every monospaced family installed, plus the system's own.
    ///
    /// Filtered rather than hard-coded so a font the user installed today is
    /// available today. The system monospaced font has no family name that
    /// `NSFontManager` reports as fixed-pitch, so it is added by hand.
    static let available: [String] = {
        let manager = NSFontManager.shared
        var names = Set<String>()
        for family in manager.availableFontFamilies {
            guard let members = manager.availableMembers(ofFontFamily: family) else { continue }
            let isFixedPitch = members.contains { member in
                guard let name = member[0] as? String, let font = NSFont(name: name, size: 12) else {
                    return false
                }
                return font.isFixedPitch
            }
            if isFixedPitch { names.insert(family) }
        }
        names.insert("SF Mono")
        return names.sorted()
    }()

    /// Resolve a family to a usable font, falling back rather than failing: a
    /// name that resolved when it was written can stop resolving, and a
    /// terminal with no font is not a state worth supporting.
    static func font(named name: String, size: CGFloat) -> NSFont {
        NSFont(name: name, size: size)
            ?? NSFont(name: "\(name)-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
