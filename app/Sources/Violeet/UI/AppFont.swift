// One type scale for the window chrome, anchored to a size the user picks.
//
// # Why a scale and not sixty literals
//
// Every label in the sidebar, the settings panel and the About box used to name
// its own point size: 7 here, 9 there, 11 for a heading. That is fine until
// somebody wants the interface a size bigger — then it is sixty edits, and any
// one of them missed leaves a label that no longer belongs to the paragraph
// around it. The sizes were never independent anyway; they were a hierarchy
// somebody held in their head.
//
// So the hierarchy is written down. Each step is an **offset from the body
// size**, not a multiple of it: a `body` of 11 and a `body` of 18 both want a
// badge roughly four points smaller, and a proportional scale would make the
// small end illegible at one end and the large end shouty at the other.
//
// # Why the offsets are what they are
//
// They are the sizes the app already used, re-expressed against a body of 13.
// The old literals ran 7, 8, 9, 10, 11, 13, 15, 20 — so `body` was 11, and
// everything else sat a fixed distance from it. Naming that distance changed no
// pixel on the day it was written and made the whole scale movable afterwards.
//
// # Why the terminal is not in here
//
// The terminal has its own font, its own size, and its own reason to change —
// ⌘+ and ⌘- move the *grid*, which reflows the child process. The chrome around
// it must not move when that happens, and this scale is what keeps the two
// independent. See `TerminalSettings.FontSettings` for the other one.

import SwiftUI

/// The window chrome's type scale.
struct AppFont: Equatable {
    /// The size of body text. Everything else is an offset from it.
    let body: CGFloat

    static let `default` = AppFont(body: TerminalSettings.WindowSettings.defaultInterfaceFontSize)

    /// A rung on the scale, named for what it is used for rather than for how
    /// big it is — the point of the type being a size the user chooses.
    enum Step {
        /// Digits in a pill: a count, a percentage.
        case badge
        /// Disclosure chevrons and other glyphs that sit beside small text.
        case micro
        /// Metrics under a card, section labels, hints.
        case small
        /// Secondary text: values, status lines, help.
        case caption
        /// The default. Names, labels, anything read rather than glanced at.
        case body
        /// A session's name on its card.
        case title
        /// The largest thing in a pane.
        case headline
        /// The About box, and nothing else so far.
        case display

        /// Points away from `body`.
        var offset: CGFloat {
            switch self {
            case .badge: return -5
            case .micro: return -4
            case .small: return -3
            case .caption: return -2
            case .body: return 0
            case .title: return 2
            case .headline: return 4
            case .display: return 9
            }
        }
    }

    /// The point size for `step`.
    ///
    /// Floored at 6: the badge step of a body already at the bottom of its
    /// range is still legible there, and a font that has gone to zero or
    /// negative is a crash rather than a small label.
    func size(_ step: Step) -> CGFloat {
        max(6, body + step.offset)
    }

    func font(_ step: Step, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size(step), weight: weight, design: design)
    }
}

// MARK: - Environment

private struct AppFontKey: EnvironmentKey {
    static let defaultValue = AppFont.default
}

extension EnvironmentValues {
    var appFont: AppFont {
        get { self[AppFontKey.self] }
        set { self[AppFontKey.self] = newValue }
    }
}

extension View {
    /// Set text on this view to a step of the scale.
    ///
    /// A modifier rather than a `Font` returned from somewhere, because the
    /// scale lives in the environment and a call site that wanted a `Font`
    /// value would have to declare an `@Environment` property to reach it —
    /// which is the boilerplate this exists to avoid, in every one of the
    /// thirty-odd views that show text.
    func appFont(
        _ step: AppFont.Step,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(AppFontModifier(
            step: step,
            weight: weight,
            design: design,
            monospacedDigit: monospacedDigit
        ))
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.appFont) private var scale

    let step: AppFont.Step
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let font = scale.font(step, weight: weight, design: design)
        return content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}
