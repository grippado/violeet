// One session card.
//
// Dense, but labelled. Five rows in about 92pt, so six agents still fit on a
// laptop sidebar without scrolling.
//
// The first version was denser and got the density wrong: 9pt type and bare
// arrows, no word saying what any number measured. The first question it drew
// was whether the context bar was the plan's 5-hour usage limit — a different
// quantity, from a source aiterm does not have. Unlabelled numbers do not read
// as terse, they read as someone else's dashboard. Every figure here now says
// what it is; the three points of height that cost is the cheapest thing on
// the card.
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
        VStack(alignment: .leading, spacing: 4) {
            titleRow
            pillRow
            contextRow
            // Only when the account actually reports limits. An API-key user
            // has none, and an empty row would read as "0% used".
            if card.fiveHourLimitUsedPercent != nil || card.sevenDayLimitUsedPercent != nil {
                limitsRow
            }
            tokenRow
            if let action = card.lastAction, !action.isEmpty {
                // The path is the informative end, so the middle is what goes.
                Text(action)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(action)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleRow: some View {
        HStack(spacing: 5) {
            Text(card.displayTitle)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            if let branch = card.gitBranch, !branch.isEmpty {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            stateBadge
        }
    }

    private var stateBadge: some View {
        Text(card.lifecycle.label)
            .font(.system(size: 10, weight: waiting ? .bold : .medium))
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
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(border, lineWidth: 1)
            )
            .lineLimit(1)
    }

    // MARK: Context gauge

    /// The context gauge, labelled.
    ///
    /// The label is not decoration. Shipped without one, the first question it
    /// got was "is that my 5-hour session?" — which is a different quantity
    /// entirely, from a source aiterm does not even have. A bar with a
    /// percentage beside it does not say what it measures, and the reader fills
    /// that in with whatever percentage they have been trained to look for.
    ///
    /// The absolute pair earns its place too: `28%` alone cannot distinguish a
    /// small window nearly full from a large one barely touched, and those call
    /// for opposite reactions.
    private var contextRow: some View {
        HStack(spacing: 6) {
            Text("ctx")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)

            ContextGauge(
                fraction: card.contextFraction,
                threshold: compactionThreshold
            )

            Text(contextReadout)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(contextTint)
                .lineLimit(1)
                .fixedSize()
        }
        .help(contextHelp)
    }

    /// `28% · 56k/200k` when the window is known, `56k` when it is not.
    ///
    /// The absolute occupancy is knowledge we actually have, and it is useful on
    /// its own — someone who knows their own window is 1M can read `56k` and
    /// place it. It was previously suppressed along with the percentage, which
    /// threw away a measured number because a *different* number was missing.
    ///
    /// Only the ratio and the percentage depend on the window size, so only
    /// they disappear. The hatched gauge beside this is what says the total is
    /// unknown; this stays a plain count.
    private var contextReadout: String {
        guard let used = card.contextUsedTokens else { return Fmt.unknown }
        guard let size = card.contextSizeTokens else { return Fmt.tokens(used) }
        return "\(Fmt.percent(card.contextFraction)) · \(Fmt.tokens(used))/\(Fmt.tokens(size))"
    }

    private var contextTint: Color {
        guard let fraction = card.contextFraction else { return .secondary }
        return fraction >= compactionThreshold ? CardTheme.gaugeColor(
            fraction: fraction, threshold: compactionThreshold
        ) : .primary
    }

    private var contextHelp: String {
        guard card.contextFraction != nil else {
            return """
            Tokens currently in the model's context window.

            The window's total size is not something aiterm can see for this \
            session, so there is no percentage — the count is measured, the \
            proportion would be invented.

            This is not your plan's usage limit.
            """
        }
        return """
        How full the model's context window is — the conversation it can still \
        see. Falls when the context is compacted.

        This is not your plan's usage limit; aiterm does not have that number.
        """
    }

    // MARK: Subscription limits

    /// The 5-hour and weekly usage, when the account has them.
    ///
    /// A different quantity from the context gauge above, and the reason both
    /// are labelled: shipped unlabelled, the context bar was read as this one.
    /// These come from the status line payload, which is the only place Claude
    /// Code reports them.
    private var limitsRow: some View {
        HStack(spacing: 10) {
            limitStat("5h", card.fiveHourLimitUsedPercent, card.fiveHourLimitResetsAt)
            limitStat("7d", card.sevenDayLimitUsedPercent, card.sevenDayLimitResetsAt)
            Spacer(minLength: 0)
        }
        .help("Your Claude subscription's usage limits, and when each window resets.")
    }

    private func limitStat(_ label: String, _ percent: Double?, _ resetsAt: String?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(percent.map { String(format: "%.0f%%", $0) } ?? Fmt.unknown)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                // Uses the same ramp as the context gauge, because "how full is
                // this thing" is the same question with the same answer colours.
                .foregroundStyle(percent.map {
                    CardTheme.gaugeColor(fraction: $0 / 100, threshold: compactionThreshold)
                } ?? .secondary)
            if let countdown = Fmt.countdown(to: resetsAt) {
                Text(countdown)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Tokens

    /// Cumulative tokens, labelled `in` and `out`.
    ///
    /// Arrows alone were not enough: `↑ 12  ↓ 1.7k` reads as two anonymous
    /// numbers, and the first thing asked about it was what it meant. The word
    /// costs four points of width and removes the question.
    private var tokenRow: some View {
        let partial = card.cumulativeTokensPartial == true
        return HStack(spacing: 10) {
            tokenStat(
                "in", "↑",
                Fmt.tokens(card.cumulativeInputTokens, partial: partial),
                CardTheme.tokenIn
            )
            tokenStat(
                "out", "↓",
                Fmt.tokens(card.cumulativeOutputTokens, partial: partial),
                CardTheme.tokenOut
            )
            Spacer(minLength: 0)
        }
        // The tilde is easy to miss and the tooltip is where "why" lives.
        .help(partial
            ? "Tokens this session has spent, counted from when aiterm started watching it — not from its start, so the real total is higher."
            : "Tokens this session has spent, in total.")
    }

    private func tokenStat(_ label: String, _ arrow: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(arrow).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.primary)
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
        .frame(height: 6)
        .help(fraction == nil
            ? "The window's total size is unknown, so there is no fill level to show. The count beside this bar is real."
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
