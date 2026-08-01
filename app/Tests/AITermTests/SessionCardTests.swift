// Tests for what a card is allowed to claim.
//
// The card's failure mode is not a crash — it is a number on screen that looks
// right and is not. Every test here guards one way that could happen.

import Foundation
import Testing

@testable import AITerm

private func registered(
    id: String = "s1",
    agent: String = "claude-code",
    cwd: String? = "/Users/you/www/repo",
    model: String? = "claude-sonnet-5"
) -> SessionRegistered {
    SessionRegistered(
        sessionID: id,
        tabID: "tab-1",
        agent: agent,
        cwd: cwd,
        title: nil,
        model: model,
        startedAt: "2026-08-01T10:00:00Z"
    )
}

@Suite("Card honesty")
struct CardHonestyTests {
    /// Unknown renders as a dash. Never as zero, never as blank.
    @Test func unknown_numbers_render_as_a_dash_and_never_as_zero() {
        #expect(Fmt.tokens(nil) == "—")
        #expect(Fmt.percent(nil) == "—")
        // And a real zero is still a zero, distinct from unknown.
        #expect(Fmt.tokens(0) == "0")
    }

    /// The distinction the whole flag exists for.
    @Test func a_partial_total_is_marked_and_a_complete_one_is_not() {
        #expect(Fmt.tokens(8_000, partial: false) == "8.0k")
        #expect(Fmt.tokens(8_000, partial: true) == "~8.0k")
        #expect(Fmt.tokens(nil, partial: true) == "—", "unknown outranks partial")
    }

    /// An unknown window size must not become a fraction, because every
    /// fraction renders as a bar and every bar looks like an answer.
    @Test func an_unknown_window_yields_no_fraction_and_no_verdict() {
        var card = SessionCard(registered: registered())
        card.contextUsedTokens = 190_000
        card.contextSizeTokens = nil

        #expect(card.contextFraction == nil)
        #expect(
            card.compactionImminent(threshold: 0.85) == nil,
            "unknown must not render as `plenty of room`"
        )
    }

    @Test func a_known_window_produces_a_fraction_and_a_verdict() {
        var card = SessionCard(registered: registered())
        card.contextUsedTokens = 170_000
        card.contextSizeTokens = 200_000

        #expect(card.contextFraction == 0.85)
        #expect(card.compactionImminent(threshold: 0.85) == true)
        #expect(card.compactionImminent(threshold: 0.90) == false)
    }

    /// Occupancy above the window is clamped for display but not for meaning:
    /// the bar cannot overflow its track, and the number is still true.
    @Test func occupancy_over_the_window_clamps_the_bar_at_full() {
        var card = SessionCard(registered: registered())
        card.contextUsedTokens = 260_000
        card.contextSizeTokens = 200_000
        #expect(card.contextFraction == 1.0)
    }
}

@Suite("Context readout")
struct ContextReadoutTests {
    /// A measured number is not withheld because a different number is missing.
    ///
    /// The occupancy is real whether or not the window size is known. Only the
    /// ratio and the percentage depend on the size, so only those disappear.
    @Test func occupancy_is_shown_even_when_the_window_size_is_unknown() {
        var card = SessionCard(registered: registered())
        card.contextUsedTokens = 48_000
        card.contextSizeTokens = nil

        #expect(card.contextFraction == nil, "no proportion without a total")
        #expect(Fmt.tokens(card.contextUsedTokens) == "48k", "but the count survives")
    }

    /// And nothing at all when there is nothing at all.
    @Test func an_unmeasured_context_is_still_a_dash() {
        var card = SessionCard(registered: registered())
        card.contextUsedTokens = nil
        card.contextSizeTokens = nil
        #expect(Fmt.tokens(card.contextUsedTokens) == "—")
    }
}

@Suite("Card state")
struct CardStateTests {
    /// A pending permission request outranks the `state` field. The two agree
    /// normally; when they disagree the blocking card must win, because it is
    /// the one with an action attached.
    @Test func a_pending_request_outranks_a_stale_state() {
        var card = SessionCard(registered: registered())
        card.state = "working"
        #expect(card.lifecycle == .working)

        card.pendingHitl = HitlPending(
            hitlID: "h1",
            sessionID: "s1",
            tabID: "tab-1",
            toolName: "Bash",
            toolInput: .object(["command": .string("rm -rf build/")]),
            permissionSuggestions: .array([]),
            expiresAt: "2026-08-01T10:05:00Z"
        )
        #expect(card.lifecycle == .waitingForYou)
    }

    /// A state the app has never heard of must not crash or read as an
    /// authoritative label — it falls back rather than being shown raw.
    @Test func an_unrecognized_state_falls_back_instead_of_being_rendered_raw() {
        var card = SessionCard(registered: registered())
        card.state = "quantum-superposition"
        #expect(card.lifecycle == .starting)
    }

    /// Waiting cards sort above everything. This is the ordering the product
    /// exists for: a blocked agent buried under six busy ones is the failure.
    @Test func waiting_sorts_above_every_other_state() {
        var waiting = SessionCard(registered: registered(id: "waiting"))
        waiting.state = "hitl"
        var working = SessionCard(registered: registered(id: "working"))
        working.state = "working"
        var idle = SessionCard(registered: registered(id: "idle"))
        idle.state = "idle"
        var done = SessionCard(registered: registered(id: "done"))
        done.state = "done"

        let ranks = [waiting, working, idle, done].map(\.sortRank)
        #expect(ranks == ranks.sorted(), "declared order must match sorted order")
        #expect(waiting.sortRank < working.sortRank)
        #expect(working.sortRank < idle.sortRank)
    }
}

@Suite("Card patching")
struct CardPatchTests {
    /// A sparse patch leaves absent fields alone and clears nulled ones — the
    /// three-way distinction, carried all the way to the card.
    @Test func absent_leaves_alone_and_null_clears() {
        var card = SessionCard(registered: registered())
        card.model = "claude-opus-5"
        card.gitBranch = "main"
        card.cumulativeOutputTokens = 1_000

        card.apply(SessionUpdated(
            sessionID: "s1",
            state: nil,
            title: .unchanged,
            model: .unchanged,          // absent: keep opus
            cwd: .unchanged,
            contextWindowUsedTokens: .value(500),
            contextWindowSizeTokens: .unchanged,
            cumulativeInputTokens: .unchanged,
            cumulativeOutputTokens: .unchanged,
            cumulativeTokensPartial: .unchanged,
            gitBranch: .unknown,        // explicit null: branch became unknown
            lastAction: .unchanged,
            lastEventAt: .unchanged,
            tabID: .unchanged
        ))

        #expect(card.model == "claude-opus-5", "an absent field must not be read as null")
        #expect(card.gitBranch == nil, "an explicit null must clear")
        #expect(card.contextUsedTokens == 500)
        #expect(card.cumulativeOutputTokens == 1_000)
    }

    /// The tilde has to be able to turn off again: a session followed from its
    /// start reports complete totals, and the card must stop qualifying them.
    @Test func partiality_can_be_cleared_by_the_daemon() {
        var card = SessionCard(registered: registered())
        card.cumulativeTokensPartial = true

        card.apply(SessionUpdated(
            sessionID: "s1", state: nil, title: .unchanged, model: .unchanged,
            cwd: .unchanged, contextWindowUsedTokens: .unchanged,
            contextWindowSizeTokens: .unchanged, cumulativeInputTokens: .unchanged,
            cumulativeOutputTokens: .unchanged,
            cumulativeTokensPartial: .value(false),
            gitBranch: .unchanged, lastAction: .unchanged,
            lastEventAt: .unchanged, tabID: .unchanged
        ))

        #expect(card.cumulativeTokensPartial == false)
        #expect(Fmt.tokens(8_000, partial: card.cumulativeTokensPartial == true) == "8.0k")
    }
}

@Suite("Card theme")
struct CardThemeTests {
    /// The per-tool colours are aitop's, and they have to stay distinct — the
    /// border is the identity channel before any text is read.
    @Test func each_known_tool_gets_its_own_colour() {
        let tools = ["claude-code", "codex", "cursor", "cursor-agent", "opencode"]
        let colors = tools.map { CardTheme.toolColor(for: $0).description }
        #expect(Set(colors).count == tools.count, "two tools sharing a colour defeats the channel")
    }

    /// An agent nobody has enumerated still gets a card, per the protocol:
    /// unknown agents are "rendered generically, not dropped".
    @Test func an_unknown_tool_renders_generically_rather_than_failing() {
        let color = CardTheme.toolColor(for: "some-future-agent")
        #expect(color == CardTheme.toolColor(for: "unknown"))
        #expect(CardTheme.toolLabel(for: "some-future-agent") == "some-future-agent")
    }

    /// The gauge ramp has to change colour at the threshold, or the warning is
    /// not a warning.
    @Test func the_gauge_changes_colour_across_the_threshold() {
        let under = CardTheme.gaugeColor(fraction: 0.30, threshold: 0.85)
        let near = CardTheme.gaugeColor(fraction: 0.75, threshold: 0.85)
        let over = CardTheme.gaugeColor(fraction: 0.92, threshold: 0.85)

        #expect(under.description != near.description)
        #expect(near.description != over.description)
    }

    /// Attention must not reuse the gauge's alarm colour: in peripheral vision
    /// two unrelated conditions that look alike are one condition.
    @Test func the_attention_colour_is_not_the_gauge_alarm_colour() {
        let alarm = CardTheme.gaugeColor(fraction: 1.0, threshold: 0.85)
        #expect(CardTheme.attention.description != alarm.description)
    }
}
