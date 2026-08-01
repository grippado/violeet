// One session card.
//
// Dense on purpose: five rows in about 78pt, so six agents fit on a laptop
// sidebar without scrolling. This is a board somebody glances at for hours
// while working on something else, not a dashboard they open.
//
// # The one thing that has to work without being looked at
//
// A session waiting on a permission request is the reason this product exists.
// The user is in a terminal, in another tab, thinking about something else —
// they are not watching the sidebar. So `waiting for you` is signalled three
// ways at once, on three different perceptual channels:
//
//  1. **A lit bar down the leading edge**, four points wide and the full height
//     of the card. Peripheral vision is poor at detail and good at *edges and
//     motion*, so this is a shape change, not an icon.
//  2. **A pulse**, slow and continuous. Motion is the only channel that
//     reliably recruits attention from outside the fovea. Two seconds, easing
//     both ways, so it reads as breathing rather than blinking — a fast blink
//     is an alarm, and this state can persist for minutes.
//  3. **A colour unused elsewhere on the card.** Amber-gold, deliberately not
//     the gauge's red: two unrelated conditions that look alike in the corner
//     of the eye defeat the purpose.
//
// A small icon was the obvious cheap option and is exactly what does not work
// here — at 12pt, six rows down, unattended, it is invisible.
//
// The pulse respects Reduce Motion. Turning it off leaves the bar and the
// colour, so the signal degrades from three channels to two rather than to
// nothing.

import SwiftUI

struct SessionCardView: View {
    let card: SessionCard
    let isSelected: Bool
    /// Fraction of the window at which compaction is near. From preferences so
    /// the card does not decide policy.
    let compactionThreshold: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    private var tool: Color { CardTheme.toolColor(for: card.agent) }
    private var waiting: Bool { card.lifecycle == .waitingForYou }

    var body: some View {
        HStack(spacing: 0) {
            attentionRail
            content
        }
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(borderColor, lineWidth: waiting ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear { if waiting && !reduceMotion { pulsing = true } }
        .onChange(of: waiting) { _, nowWaiting in
            pulsing = nowWaiting && !reduceMotion
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Attention rail

    /// The lit edge. Present but transparent when not waiting, so a card does
    /// not change width when it starts waiting — a layout shift would move
    /// every card below it and cost more attention than it buys.
    private var attentionRail: some View {
        Rectangle()
            .fill(waiting ? CardTheme.attention : .clear)
            .frame(width: 4)
            .opacity(pulsing ? 0.45 : 1)
            .animation(
                pulsing
                    ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleRow
            pillRow
            contextRow
            tokenRow
            if let action = card.lastAction, !action.isEmpty {
                Text(action)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleRow: some View {
        HStack(spacing: 5) {
            Text(card.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if let branch = card.gitBranch, !branch.isEmpty {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            stateBadge
        }
    }

    private var stateBadge: some View {
        Text(card.lifecycle.label)
            .font(.system(size: 9, weight: waiting ? .bold : .regular))
            .foregroundStyle(waiting ? CardTheme.attention : .secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private var pillRow: some View {
        HStack(spacing: 4) {
            pill(CardTheme.toolLabel(for: card.agent), border: tool)
            // An unknown model is a dash in a pill, not a missing pill: the
            // absence is information, and a row that silently loses an element
            // reads as a different kind of session.
            pill(card.model ?? Fmt.unknown, border: .secondary.opacity(0.45))
            Spacer(minLength: 0)
        }
    }

    private func pill(_ text: String, border: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(border, lineWidth: 1)
            )
            .lineLimit(1)
    }

    // MARK: Context gauge

    private var contextRow: some View {
        HStack(spacing: 5) {
            ContextGauge(
                fraction: card.contextFraction,
                threshold: compactionThreshold
            )
            Text(Fmt.percent(card.contextFraction))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(card.contextFraction == nil ? .secondary : .primary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    // MARK: Tokens

    private var tokenRow: some View {
        let partial = card.cumulativeTokensPartial == true
        return HStack(spacing: 8) {
            tokenStat(
                "↑",
                Fmt.tokens(card.cumulativeInputTokens, partial: partial),
                CardTheme.tokenIn
            )
            tokenStat(
                "↓",
                Fmt.tokens(card.cumulativeOutputTokens, partial: partial),
                CardTheme.tokenOut
            )
            Spacer(minLength: 0)
        }
        // The tilde is easy to miss and the tooltip is where "why" lives.
        .help(partial
            ? "Counted from when aiterm started watching this session, not from its start."
            : "Total for this session.")
    }

    private func tokenStat(_ arrow: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Text(arrow).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text(value).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: Chrome

    private var background: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? CardTheme.surfaceRaised : CardTheme.surface)
    }

    private var borderColor: Color {
        if waiting { return CardTheme.attention }
        return isSelected ? tool.opacity(0.9) : tool.opacity(0.35)
    }

    /// Everything the card shows, in one sentence, for VoiceOver.
    ///
    /// The visual signal for `waiting for you` is colour and motion, and both
    /// are invisible to a screen reader — so the state is spoken first.
    private var accessibilityLabel: String {
        var parts = [card.lifecycle.label, card.displayTitle]
        parts.append("agent \(card.agent)")
        parts.append("model \(card.model ?? "unknown")")
        if let fraction = card.contextFraction {
            parts.append("context \(Fmt.percent(fraction))")
        } else {
            parts.append("context unknown")
        }
        let partial = card.cumulativeTokensPartial == true ? "partial " : ""
        parts.append("\(partial)in \(Fmt.tokens(card.cumulativeInputTokens))")
        parts.append("\(partial)out \(Fmt.tokens(card.cumulativeOutputTokens))")
        if let action = card.lastAction { parts.append("last action \(action)") }
        return parts.joined(separator: ", ")
    }
}

/// The context-window bar.
///
/// Three appearances, not two. `nil` is the one that matters: an unknown window
/// size must not render as an empty bar, because empty reads as *plenty of
/// room* — a reassurance nothing supports — and full reads as alarm. The
/// indeterminate state is a hatched track with no fill, which looks like
/// neither, plus a dash where the percentage goes.
private struct ContextGauge: View {
    let fraction: Double?
    let threshold: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))

                if let fraction {
                    Capsule()
                        .fill(CardTheme.gaugeColor(fraction: fraction, threshold: threshold))
                        .frame(width: max(2, geo.size.width * fraction))
                } else {
                    // Diagonal hatching: unmistakably not a fill level.
                    Hatching()
                        .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                        .clipShape(Capsule())
                }
            }
        }
        .frame(height: 5)
        .help(fraction == nil
            ? "Context window size unknown for this model, so the fill cannot be computed."
            : "Context window \(Fmt.percent(fraction)) full.")
    }
}

/// Diagonal stripes, for the indeterminate gauge.
private struct Hatching: Shape {
    var spacing: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = -rect.height
        while x < rect.width {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
