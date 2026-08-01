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
    /// The name as the window decided to show it — qualified when another
    /// session carries the same one. See `AppState.displayTitle(for:)`.
    let title: String
    /// The same name with its provenance, which the row needs in order to say
    /// whether automatic naming is switched off.
    let name: ResolvedName
    let isSelected: Bool
    let onRename: (String) -> Void
    let onRelease: () -> Void
    /// Editing ended, one way or another. Hands the keyboard back.
    let onFinish: () -> Void
    /// Fraction of the window at which compaction is near. From preferences so
    /// the card does not decide policy.
    let compactionThreshold: Double
    /// The window's surfaces for the active theme, so a card belongs to the
    /// palette rather than to a fixed near-black.
    let chrome: WindowChrome

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
            // The working directory, on every card. The title is only its last
            // component, which is not an address: two checkouts of the same
            // repository, or a folder whose name matches an app's, are
            // indistinguishable without this line.
            if let path = card.pathLabel {
                pathRow(path)
            }
            // Only for a card with no tab, and only when the origin was
            // actually resolved. A session in a tab already answers "where" —
            // the tab is the answer.
            if card.tabID == nil, let origin = card.originLabel {
                originRow(origin)
            }
            pillRow
            contextRow
            usageRow
            if let action = card.lastAction, !action.isEmpty {
                // Wrapped over up to three lines rather than truncated to one.
                // A single line of `Bash git commit -m "$(cat <<'EOF'…` says
                // that a command ran and nothing about which one; three lines
                // is where the tool call usually becomes readable.
                Text(action)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(action)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The working directory.
    ///
    /// Truncated at the **head**: the tail is the part that identifies the
    /// session, and a path that loses its end loses everything.
    private func pathRow(_ path: String) -> some View {
        Label(path, systemImage: "folder")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
            .help(card.cwd ?? path)
    }

    /// Where this session lives, for one aiterm did not start.
    ///
    /// Reads as an address, not as a status: same weight as the working
    /// directory line, no colour of its own. It is there to be found when the
    /// user goes looking, not to compete with the attention signal.
    private func originRow(_ origin: String) -> some View {
        Label(origin, systemImage: "terminal")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("This session is running in \(origin), outside aiterm.")
    }

    private var titleRow: some View {
        HStack(spacing: 5) {
            // A session with no tab is one aiterm did not launch — an agent
            // running in iTerm, or in another window. ADR-003 makes that a
            // supported state rather than an error, so it is shown; but it
            // cannot be revealed in a tab, and clicking it does nothing. The
            // badge is what stops that from being a card that silently ignores
            // you.
            //
            // Only when the origin row is not there to say it: with a resolved
            // origin the card already carries a terminal icon naming the
            // application, and two glyphs for one fact read as two facts.
            if card.tabID == nil, card.originLabel == nil {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help("Running outside aiterm — there is no tab to switch to.")
            }
            EditableName(
                name: name,
                display: title,
                font: .system(size: 13, weight: .semibold),
                colour: .primary,
                onRename: onRename,
                onRelease: onRelease,
                onFinish: onFinish
            )

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
    /// The limits and the token totals, on one line when they fit.
    ///
    /// Vertical room is the sidebar's scarcest resource, and these two groups
    /// are both small and both read left-to-right, so they share a line. They
    /// fall back to two lines rather than truncating: a clipped `~14k` is worse
    /// than a second row, and how narrow the sidebar gets is the user's choice,
    /// not something the card can assume.
    /// Tokens on the left, limits pushed to the right edge. What this session
    /// spent belongs with the rest of the session's own numbers; the account's
    /// limits are a different subject and sit apart from them.
    private var usageRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                tokens
                Spacer(minLength: 8)
                limits
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { tokens; Spacer(minLength: 0) }
                if hasLimits {
                    HStack(spacing: 10) { limits; Spacer(minLength: 0) }
                }
            }
        }
    }

    /// True only when the account actually reports limits. An API-key user has
    /// none, and an empty pair would read as "0% used".
    private var hasLimits: Bool {
        card.fiveHourLimitUsedPercent != nil || card.sevenDayLimitUsedPercent != nil
    }

    @ViewBuilder
    private var limits: some View {
        if hasLimits {
            HStack(spacing: 10) {
                limitStat("5h", card.fiveHourLimitUsedPercent, card.fiveHourLimitResetsAt)
                limitStat("7d", card.sevenDayLimitUsedPercent, card.sevenDayLimitResetsAt)
            }
            .fixedSize()
            .help("Your Claude subscription's usage limits, and when each window resets.")
        }
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
    private var tokens: some View {
        let partial = card.cumulativeTokensPartial == true
        return HStack(spacing: 10) {
            tokenStat(
                "in", "↑",
                Fmt.tokens(card.cumulativeInputTokens, partial: partial),
                CardTheme.tokenIn
            )
            // The number that was missing, and the one that dominates. Measured
            // on real sessions, cache reads are 99.5% of everything the prompt
            // side consumed: `in` alone read 628 where the true figure was 121
            // million. A card without this one is not showing a rounded total,
            // it is showing a different quantity.
            //
            // Cache *creation* is on the wire but not on the card — it is
            // priced differently, so it cannot be added to this, and it ran
            // under 1% of cache reads in every session measured. It is in the
            // tooltip, where a number that small belongs.
            tokenStat(
                "cache", "⟳",
                Fmt.tokens(card.cumulativeCacheReadTokens, partial: partial),
                CardTheme.tokenCache
            )
            tokenStat(
                "out", "↓",
                Fmt.tokens(card.cumulativeOutputTokens, partial: partial),
                CardTheme.tokenOut
            )
        }
        .fixedSize()
        // The tilde is easy to miss and the tooltip is where "why" lives. The
        // breakdown is here too, because the three are priced differently and
        // adding them together is the mistake this card is arranged to avoid.
        .help(tokenHelp(partial: partial))
    }

    private func tokenHelp(partial: Bool) -> String {
        let scope = partial
            ? "Counted from when aiterm started watching this session, not from its start — the real totals are higher."
            : "Totals for this session."
        return """
        \(scope)

        in — fresh prompt tokens, neither read from nor written to the cache
        cache — prompt tokens served from the cache, priced well below fresh input
        out — tokens the model produced
        cache written — \(Fmt.tokens(card.cumulativeCacheCreationTokens, partial: partial))

        The three are priced differently, which is why they are three numbers \
        and not one.
        """
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
            .fill(Color(nsColor: (isSelected ? chrome.raisedResolved : chrome.surfaceResolved).nsColor))
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
        var parts = [card.lifecycle.label, title]
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
