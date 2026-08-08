// The sidebar's palette, inherited from aitop.
//
// The per-tool colours are read off `aitop/internal/ui/theme/theme.go`, where
// the comment calls per-tool border identity "violeet's primary visual
// language". Same product family, same at-a-glance vocabulary: if a coral
// border means Claude Code in the TUI, it must not mean something else here.
//
// aitop's values are xterm-256 indices, translated to their standard hex:
//
//     209 coral   → #ff875f   Claude Code
//      36 teal    → #00af87   Codex
//     141 purple  → #af87ff   Cursor
//     213 pink    → #ff87ff   Cursor Agent
//     220 gold    → #ffd700   opencode
//     245 grey    → #8a8a8a   unknown
//
// # Dark first
//
// The stated primary case is dark mode, and these are tuned for it: saturated
// accents on a near-black surface. They are legible on light, but that is the
// secondary reading — SwiftUI's semantic colours carry the surfaces, so light
// mode is correct rather than designed.
//
// # Density
//
// This is a board somebody stares at for hours while doing something else, not
// a dashboard they visit. Type is 10–12pt, rows are tight, and whitespace is
// spent only where it separates one card from the next. Anything that grows a
// card by a line has to earn it against the cards it pushes off screen.

import SwiftUI

enum CardTheme {
    // MARK: Tool identity

    /// The border colour that says which tool this is, before any text is read.
    static func toolColor(for agent: String) -> Color {
        switch agent.lowercased() {
        case "claude-code", "claude": return Color(hex: 0xFF875F)
        case "codex": return Color(hex: 0x00AF87)
        case "cursor": return Color(hex: 0xAF87FF)
        case "cursor-agent": return Color(hex: 0xFF87FF)
        case "opencode": return Color(hex: 0xFFD700)
        default: return Color(hex: 0x8A8A8A)
        }
    }

    /// A short label for the harness pill. Long enough to identify, short
    /// enough not to push the model pill off the row.
    static func toolLabel(for agent: String) -> String {
        switch agent.lowercased() {
        case "claude-code", "claude": return "claude"
        case "cursor-agent": return "cursor-a"
        case "unknown": return "?"
        default: return agent.lowercased()
        }
    }

    // MARK: Gauge

    /// Green below the threshold, amber approaching it, red past it.
    ///
    /// aitop's btop-classic gauge ramp, in the same order and for the same
    /// reason: it is the convention every system monitor has trained people on,
    /// and a sidebar is not the place to be inventive about what red means.
    static func gaugeColor(fraction: Double, threshold: Double) -> Color {
        if fraction >= threshold { return Color(hex: 0xFF5F5F) }
        if fraction >= threshold * 0.82 { return Color(hex: 0xFFD75F) }
        return Color(hex: 0x5FD75F)
    }

    // MARK: Tokens

    /// `IN ↑` green, `OUT ↓` red, exactly as aitop renders them.
    static let tokenIn = Color(hex: 0x5FD75F)
    static let tokenOut = Color(hex: 0xFF8787)
    /// `CACHE ⟳`. Blue rather than a shade of the green: cache reads are not a
    /// larger `in`, they are a differently-priced quantity, and giving them a
    /// family resemblance to input would invite exactly the addition the four
    /// separate fields exist to prevent.
    static let tokenCache = Color(hex: 0x6FB7FF)

    // MARK: Attention

    /// The colour of "this one is waiting for you".
    ///
    /// Deliberately not red. Red is the gauge's "nearly full" and reusing it
    /// would make two unrelated conditions look alike in peripheral vision,
    /// which is the exact channel this colour has to work in. Amber-gold is
    /// unused elsewhere on the card.
    static let attention = Color(hex: 0xFFB454)

    static let surface = Color(hex: 0x16161A)
    static let surfaceRaised = Color(hex: 0x1E1E24)
}

extension Color {
    /// `0xRRGGBB`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
