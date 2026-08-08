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
    var editor = EditorSettings()

    // MARK: Appearance

    struct Appearance: Equatable {
        /// The named palette this was last set from, so the panel can show
        /// which preset is active. `nil` once any colour is edited by hand —
        /// a preset that still claims to be selected after being altered is
        /// lying about what is on screen.
        var themeName: String? = TerminalTheme.builtins[0].name

        /// The file these colours came from, when they came from one.
        ///
        /// `nil` for a built-in, which has no file until somebody edits it. It
        /// is what tells the app which theme to keep watching across a relaunch,
        /// and what the picker ticks so a custom theme can be told from the
        /// built-in it was copied out of.
        ///
        /// Carried beside `themeName` rather than encoded into it — a name is
        /// what the theme is called and a path is where it lives, and one string
        /// meaning either depending on whether it contains a slash is a string
        /// that eventually gets parsed wrong.
        var themeFile: String?

        var background: RGB = TerminalTheme.builtins[0].background
        var foreground: RGB = TerminalTheme.builtins[0].foreground
        var cursorColor: RGB = TerminalTheme.builtins[0].cursor
        /// The 16 ANSI colours, in the standard order: eight normal, eight
        /// bright.
        var ansi: [RGB] = TerminalTheme.builtins[0].ansi
    }

    /// Every colour a theme sets, in one fixed order.
    ///
    /// Exists so "did the palette change?" is one comparison rather than
    /// nineteen, and so the panel can ask that question without asking the
    /// different question `matchesNamedTheme` answers.
    ///
    /// The two are not interchangeable, and conflating them was a bug: the panel
    /// cleared the theme name whenever the colours failed to match a **built-in**,
    /// which is always true for a theme loaded from a file. Nudging the font size
    /// with a custom theme active would therefore have thrown its name away, and
    /// with it the file the app was watching.
    var palette: [RGB] {
        [appearance.background, appearance.foreground, appearance.cursorColor] + appearance.ansi
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

        /// Body size for the window's own text: the sidebar, this panel, the
        /// About box. Everything else in the chrome is an offset from it — see
        /// `AppFont`.
        ///
        /// Deliberately *not* the terminal's font size, which lives in
        /// `FontSettings` and is what ⌘+ and ⌘- move. The two were one control
        /// by accident of there being only one, and they answer different
        /// questions: the terminal's size reflows the child process and is
        /// changed to fit a diff on screen; this one is changed once, because
        /// of a display or a pair of eyes, and should not move when the first
        /// one does.
        var interfaceFontSize: CGFloat = defaultInterfaceFontSize

        static let opacityRange: ClosedRange<Double> = 0.3...1.0
        /// The system's own body size, which is what the rest of macOS uses for
        /// the same kind of text.
        static let defaultInterfaceFontSize: CGFloat = 13
        static let interfaceFontSizeRange: ClosedRange<CGFloat> = 10...20

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

    // MARK: Editor

    /// How a file opens when the Files panel hands it to the user's editor.
    ///
    /// Its own group rather than a field on `BehaviourSettings`: everything
    /// there is about the terminal this app draws, and this is about a program
    /// it launches. The two happen to be configured on the same panel and are
    /// not the same subject.
    ///
    /// Only vim and Neovim read any of this — see `AppState.editorCommand` for
    /// why `-c` is not handed to an `$EDITOR` of `code` or `emacs`.
    struct EditorSettings: Equatable {
        var diffMode: DiffMode = .inline

        /// Applications offered by the editor panel's "Open with", chosen by
        /// the user, as absolute paths.
        ///
        /// Empty means "ask the system", which is the behaviour without this
        /// setting and the right default: a fresh install cannot know which
        /// editor somebody uses, and a list nobody curated is better supplied
        /// by Launch Services than guessed here.
        ///
        /// Paths rather than names, because a name is not an identity: two
        /// applications can share one, and the name is what gets rendered from
        /// the path anyway. Paths rot when an app moves, and `ExternalApps.
        /// resolve` drops the dead ones at read time rather than trusting them.
        var openWith: [String] = []
        /// Switch on a minimap, when the user's config has one.
        ///
        /// Off by default and useless without a plugin, which this app does not
        /// install: editing the rc files of another program is the surface
        /// ADR-003 already declined for tab binding, and a terminal that
        /// rewrites your Neovim config to draw a sidebar has overstepped by a
        /// wide margin. So this is detection, on the same `pcall` pattern the
        /// gitsigns calls use: present means switch it on, absent means carry
        /// on quietly.
        var showMinimap: Bool = false

        /// How the uncommitted change is put on screen.
        ///
        /// Neither is more correct. Inline keeps one buffer, which is the whole
        /// file with the change marked in it — right when the change is small
        /// and the surrounding code is what you need. Side by side spends half
        /// the width on what the line used to be, which is right when the
        /// change is a rewrite and wrong when the tab is 80 columns.
        ///
        /// Inline is the default because it is the one that cannot be too
        /// narrow to read.
        enum DiffMode: String, CaseIterable, Equatable, Identifiable {
            /// Jump to the first hunk, with the gitsigns displays switched on.
            case inline
            /// `Gitsigns diffthis`: a vertical split against the index.
            case sideBySide

            var id: String { rawValue }

            var label: String {
                switch self {
                case .inline: return "Inline"
                case .sideBySide: return "Side by side"
                }
            }

            var detail: String {
                switch self {
                case .inline: return "Marks the change in the file itself."
                case .sideBySide: return "Splits the window against the last commit."
                }
            }
        }
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
        // Violeeter, the house palette. Published on its own under `theme/`,
        // where `violeeter.json` is the source and everything else is
        // generated from it — including these values, which are transcribed
        // from that file and verified by `theme/build.py --check`.
        //
        // The base asked for was `#222240`, and it is `R=34 G=34 B=64`: with
        // red and green equal, the eye reads cold blue-violet rather than
        // purple. `#24203F` puts red a step above green at the same luminance,
        // which is what makes it read as purple without making it louder.
        //
        // Two things follow from a violet background and neither is optional.
        // **Blue has to move**: the default terminal blue sits a few degrees
        // from this background and the two stop separating, so it is lifted and
        // pulled toward cyan. **Neutral grey text reads yellow** against a cold
        // ground, so the foreground carries a trace of the same hue.
        TerminalTheme(
            name: "Violeeter Dark",
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
                // Bright. `brightBlack` is `#8B84BC` and not the `#554F7E` this
                // palette grew up with: that measured 2.07 against this ground,
                // and this slot is where nearly every highlighter puts
                // *comments*. Unreadable comments are not a style.
                RGB(0x8B, 0x84, 0xBC), RGB(0xFF, 0x93, 0xA4), RGB(0x96, 0xF0, 0xB8),
                RGB(0xF7, 0xDA, 0x9E), RGB(0xA6, 0xC7, 0xFF), RGB(0xDC, 0xA9, 0xFF),
                RGB(0x96, 0xEF, 0xEF), RGB(0xF3, 0xF1, 0xFF),
            ]
        ),
        // The same hue family on a pale ground, and not the dark one with its
        // lightness flipped — flipping produces pastels on white, which are
        // inverted in theory and unreadable in practice. Every colour was
        // re-picked at a luminance that clears AA on `#FAF8FE`.
        //
        // `white` and `brightWhite` are legible text here, not the palest thing
        // available, and that is a correction rather than a preference. They
        // were `#C9C3DE` and `#FFFFFF` on the reasoning that colour 7 means "the
        // palest thing" and so is a surface. Correct about the name, wrong about
        // the use: colour 7 is the default foreground of a large share of
        // terminal programs. Under btop it measured 1.61 against this ground and
        // the memory labels were simply absent.
        TerminalTheme(
            name: "Violeeter Light",
            background: RGB(0xFA, 0xF8, 0xFE),
            foreground: RGB(0x2A, 0x24, 0x40),
            cursor: RGB(0x7C, 0x3A, 0xED),
            ansi: [
                RGB(0x2A, 0x24, 0x40), RGB(0xC0, 0x2A, 0x47), RGB(0x14, 0x7A, 0x52),
                RGB(0x8A, 0x5A, 0x0B), RGB(0x2B, 0x4A, 0xCB), RGB(0x7C, 0x3A, 0xED),
                RGB(0x0F, 0x6E, 0x80), RGB(0x55, 0x50, 0x6E),
                RGB(0x6B, 0x66, 0x85), RGB(0xA8, 0x1E, 0x39), RGB(0x0F, 0x64, 0x44),
                RGB(0x74, 0x49, 0x0A), RGB(0x20, 0x39, 0xA8), RGB(0x64, 0x25, 0xC9),
                RGB(0x0B, 0x5A, 0x69), RGB(0x2A, 0x24, 0x40),
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
        // Dracula, transcribed from the published specification rather than
        // from any one port. The spec fixes all twenty values, which is why the
        // theme looks the same in fifty editors — approximating it here would
        // make this the one place it does not.
        //
        // `black` is `#21222C` and sits *below* the `#282A36` background, which
        // is the opposite of the rule the house palette follows. Kept as
        // published: Dracula puts the readable dark tone in `brightBlack`
        // (`#6272A4`, its comment colour), so nothing legible lands on colour 0.
        TerminalTheme(
            name: "Dracula",
            background: RGB(0x28, 0x2A, 0x36),
            foreground: RGB(0xF8, 0xF8, 0xF2),
            cursor: RGB(0xF8, 0xF8, 0xF2),
            ansi: [
                RGB(0x21, 0x22, 0x2C), RGB(0xFF, 0x55, 0x55), RGB(0x50, 0xFA, 0x7B),
                RGB(0xF1, 0xFA, 0x8C), RGB(0xBD, 0x93, 0xF9), RGB(0xFF, 0x79, 0xC6),
                RGB(0x8B, 0xE9, 0xFD), RGB(0xF8, 0xF8, 0xF2),
                RGB(0x62, 0x72, 0xA4), RGB(0xFF, 0x6E, 0x6E), RGB(0x69, 0xFF, 0x94),
                RGB(0xFF, 0xFF, 0xA5), RGB(0xD6, 0xAC, 0xFF), RGB(0xFF, 0x92, 0xDF),
                RGB(0xA4, 0xFF, 0xFF), RGB(0xFF, 0xFF, 0xFF),
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
