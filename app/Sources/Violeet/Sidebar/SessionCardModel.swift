// What a card knows, and the rules for showing it.
//
// This type is the boundary the sidebar's honesty rests on. The daemon sends
// facts, some of which are unknown; SwiftUI wants values. Everything in between
// happens here, once, so no view has to decide what to do about a `nil` — and
// so no view can quietly decide zero.
//
// Three rules, all of them the same rule wearing different clothes:
//
//  1. **`nil` renders as an em dash, never as zero.** "We do not know" and
//     "it is none" are different facts about the world.
//  2. **An unknown context window is indeterminate, not empty and not full.**
//     An empty bar reads as "plenty of room" — reassurance we have no basis
//     for. A full one reads as alarm. Neither is true; the honest rendering is
//     a third thing that looks like neither.
//  3. **A partial total wears a tilde.** `~8k` for a session that has burned
//     400k is incomplete. `8k` is a lie, and one nothing in the number reveals.

import Foundation
import SwiftUI

/// One agent session, as the sidebar knows it.
struct SessionCard: Identifiable, Equatable {
    let sessionID: String
    var tabID: String?
    var agent: String
    var cwd: String?
    var title: String?
    var model: String?
    var state: String?
    /// `cwd` | `prompt` | `ai_title` | `user`. Who named this session.
    var titleSource: String?
    var gitBranch: String?
    var lastAction: String?
    var lastEventAt: String?

    /// Where a session with no tab is actually running: the terminal
    /// application and, inside it, the tty. Both `nil` for a session violeet
    /// started — the tab already answers "where".
    var originApp: String?
    var originTTY: String?

    var contextUsedTokens: Int?
    var contextSizeTokens: Int?
    var cumulativeInputTokens: Int?
    var cumulativeOutputTokens: Int?
    /// Prompt tokens served from, and written into, the cache. Separate from
    /// the input counter because they are priced differently — see
    /// `SessionUpdated`.
    var cumulativeCacheReadTokens: Int?
    var cumulativeCacheCreationTokens: Int?
    /// See `SessionUpdated.cumulativeTokensPartial`.
    var cumulativeTokensPartial: Bool?

    /// Subscription limits. `nil` until the status line reports them, which it
    /// only does for Claude.ai subscribers after the first API response — so
    /// `nil` is the normal state early on and for API-key users.
    var fiveHourLimitUsedPercent: Double?
    var fiveHourLimitResetsAt: String?
    var sevenDayLimitUsedPercent: Double?
    var sevenDayLimitResetsAt: String?

    /// Set by `AppState` from the pending-HITL table, not by the daemon's
    /// `state` field. Both say the session is blocked; this one is the reason
    /// the card can also show *what* it is blocked on.
    var pendingHitl: HitlPending?

    /// How many background agents this session is waiting on.
    ///
    /// `nil` means the daemon has not said — which is not zero, and is why this
    /// is an optional like every other unknown here. A session with a positive
    /// count reports `state == "idle"`, because the `Stop` hook fires the same
    /// way whether a person or a subagent is expected next; it is idle in the
    /// sense that nothing is computing in the foreground and emphatically not
    /// free. See `lifecycle`.
    var pendingAgents: Int?

    /// The session stopped having *asked* rather than having finished.
    ///
    /// An object means it is asking now; `nil` covers both "no longer asking"
    /// and "this daemon never looked", which is why `lifecycle` tests for
    /// presence and never for `!= nil` on the patch. See `AnswerRequest`.
    ///
    /// No daemon populates this yet — the field is on the wire and in the
    /// decoder, and the producer is still to come. The precedence it takes over
    /// `pendingAgents` is implemented and tested here regardless, so the day the
    /// producer lands the card is already right instead of hiding the question.
    var answerRequest: AnswerRequest?

    var id: String { sessionID }

    init(registered: SessionRegistered) {
        sessionID = registered.sessionID
        tabID = registered.tabID
        agent = registered.agent
        cwd = registered.cwd
        title = registered.title
        model = registered.model
        startedAt = registered.startedAt
    }

    let startedAt: String

    /// Fold a sparse patch in. Absent leaves the value alone; explicit null
    /// clears it.
    mutating func apply(_ patch: SessionUpdated) {
        if let state = patch.state { self.state = state }
        title = patch.title.applied(to: title)
        model = patch.model.applied(to: model)
        cwd = patch.cwd.applied(to: cwd)
        titleSource = patch.titleSource.applied(to: titleSource)
        gitBranch = patch.gitBranch.applied(to: gitBranch)
        lastAction = patch.lastAction.applied(to: lastAction)
        lastEventAt = patch.lastEventAt.applied(to: lastEventAt)
        originApp = patch.originApp.applied(to: originApp)
        originTTY = patch.originTTY.applied(to: originTTY)
        tabID = patch.tabID.applied(to: tabID)

        contextUsedTokens = patch.contextWindowUsedTokens.applied(to: contextUsedTokens)
        contextSizeTokens = patch.contextWindowSizeTokens.applied(to: contextSizeTokens)
        cumulativeInputTokens = patch.cumulativeInputTokens.applied(to: cumulativeInputTokens)
        cumulativeOutputTokens = patch.cumulativeOutputTokens.applied(to: cumulativeOutputTokens)
        cumulativeCacheReadTokens = patch.cumulativeCacheReadTokens.applied(to: cumulativeCacheReadTokens)
        cumulativeCacheCreationTokens =
            patch.cumulativeCacheCreationTokens.applied(to: cumulativeCacheCreationTokens)
        cumulativeTokensPartial = patch.cumulativeTokensPartial.applied(to: cumulativeTokensPartial)
        fiveHourLimitUsedPercent = patch.fiveHourLimitUsedPercent.applied(to: fiveHourLimitUsedPercent)
        fiveHourLimitResetsAt = patch.fiveHourLimitResetsAt.applied(to: fiveHourLimitResetsAt)
        sevenDayLimitUsedPercent = patch.sevenDayLimitUsedPercent.applied(to: sevenDayLimitUsedPercent)
        sevenDayLimitResetsAt = patch.sevenDayLimitResetsAt.applied(to: sevenDayLimitResetsAt)
        pendingAgents = patch.pendingAgents.applied(to: pendingAgents)
        answerRequest = patch.answerRequest.applied(to: answerRequest)
    }
}

// MARK: - Presentation

extension SessionCard {
    /// The headline from what the daemon knows, before the window makes it
    /// unique and before the tab's own facts are folded in.
    ///
    /// The daemon names a session from its first prompt within a second of it
    /// starting, and upgrades that to Claude Code's own `ai-title` one exchange
    /// later. The working directory is what is left when neither has arrived.
    ///
    /// This is levels 1, 3, 4 and 5 of the chain — everything a card can be
    /// named by without a PTY, which is exactly the situation of a session
    /// running outside violeet. `AppState.name(for:)` adds level 2 for a card
    /// that has a tab. Both go through `SessionName.resolve`: there is one
    /// precedence rule in this app and this is not a second one.
    var baseTitle: String {
        SessionName.resolve(
            NameInputs(agentTitle: title, agentTitleSource: titleSource, cwd: cwd)
        ).text
    }

    /// The titles to render for `cards`, made unique among themselves.
    ///
    /// Two sessions genuinely can be called the same thing — two checkouts of
    /// one repository, or the same task started twice — and a sidebar with two
    /// identical rows is one you cannot act on: the whole point of the name is
    /// to pick the right card. A colliding pair is qualified with what
    /// distinguishes it, which is usually the parent directory.
    ///
    /// Done here rather than in the daemon deliberately. The daemon holds the
    /// session's real name; adding a qualifier there would mean rewriting the
    /// title of a session the user never touched, emitting a rename nobody
    /// asked for, and persisting a name that is only correct for as long as the
    /// other session happens to exist.
    ///
    /// A free function over the cards rather than a method on `AppState`
    /// because it depends on nothing else — which is also what makes it
    /// testable without standing up a main-actor view model.
    /// `named` supplies each card's resolved name. It defaults to what the
    /// card alone can say, and `AppState` passes the fuller answer — the one
    /// that knows what is running in the tab. Collisions have to be computed
    /// over the names actually on screen, or two tabs both showing `btop`
    /// would go unqualified while their agent titles, which nobody can see,
    /// differed.
    static func uniqueTitles(
        for cards: some Collection<SessionCard>,
        named: (SessionCard) -> String = { $0.baseTitle }
    ) -> [String: String] {
        var byTitle: [String: [SessionCard]] = [:]
        for card in cards {
            byTitle[named(card), default: []].append(card)
        }

        var titles: [String: String] = [:]
        for (title, colliding) in byTitle {
            guard colliding.count > 1 else { continue }

            // The parent directory only helps if it actually separates them.
            // Two sessions in the *same* checkout collide on the parent too,
            // and `violeet · personal` twice is the problem this is here to
            // solve, wearing a longer name. When it does not separate, the
            // whole group falls to session ids — all of it, so the qualifiers
            // stay of one kind and the rows read as a set.
            let parents = colliding.map(\.parentDirectory)
            let separates = Set(parents.compactMap { $0 }).count == colliding.count

            for card in colliding {
                let qualifier = separates ? (card.parentDirectory ?? card.shortID) : card.shortID
                titles[card.sessionID] = "\(title) · \(qualifier)"
            }
        }
        return titles
    }

    /// The directory containing `cwd`, when there is one worth naming.
    ///
    /// `personal/violeet` against `isaac/violeet` is the collision that actually
    /// happens, and the parent is what a person would say out loud to tell the
    /// two apart. `nil` when there is no cwd, or when the parent repeats the
    /// title and so distinguishes nothing.
    var parentDirectory: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard !parent.isEmpty, parent != baseTitle else { return nil }
        return parent
    }

    /// The last resort. It identifies without describing, which is why it is
    /// last.
    var shortID: String {
        String(sessionID.prefix(4))
    }

    /// The working directory, with `$HOME` abbreviated to `~`.
    ///
    /// Shown on the card in its own right, not only as a tooltip. The title is
    /// the path's last component, and a last component is not an address: two
    /// checkouts of the same repository produce the same title, and a folder
    /// named after an application produces a title that reads as that
    /// application.
    var pathLabel: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return ProcessDirectory.abbreviated(cwd)
    }

    /// Where this session is running, for a card with no tab to switch to.
    ///
    /// `nil` when the daemon could not resolve it, and the card then says
    /// nothing rather than "unknown terminal" — an origin we did not measure is
    /// not a place. The tty rides along because two agents in the same terminal
    /// are otherwise indistinguishable, which is the common case.
    var originLabel: String? {
        switch (originApp, originTTY) {
        case let (app?, tty?): return "\(app) · \(tty)"
        case let (app?, nil): return app
        case let (nil, tty?): return tty
        case (nil, nil): return nil
        }
    }

    /// How full the context window is, `0...1`.
    ///
    /// `nil` when either half is unknown, and that `nil` must reach the view
    /// rather than being defaulted here. The whole point of rule 2 is that the
    /// bar has a third appearance for it.
    var contextFraction: Double? {
        guard let used = contextUsedTokens, let size = contextSizeTokens, size > 0 else {
            return nil
        }
        return min(Double(used) / Double(size), 1.0)
    }

    /// Whether compaction is close. `nil` when the window size is unknown —
    /// which is not the same as "no".
    func compactionImminent(threshold: Double) -> Bool? {
        guard let fraction = contextFraction else { return nil }
        return fraction >= threshold
    }

    var lifecycle: Lifecycle {
        // A pending permission request outranks whatever `state` says. The two
        // agree in normal operation; when they disagree it is because the HITL
        // arrived first, and the card that is blocking the user is the one that
        // must be right.
        if pendingHitl != nil { return .waitingForYou }
        switch state {
        case "working": return .working
        case "hitl": return .waitingForYou
        case "idle":
            // **A question outranks a count, always.** A session with agents out
            // *and* something asked on screen is waiting on the human: the agents
            // are somebody else's problem, the question is the only thing here
            // with an action attached to it. Reporting it as busy hides that, and
            // hiding it is the exact failure this product exists to prevent —
            // `docs/PROTOCOL.md` § `pending_agents` decides this case and this is
            // the line that obeys it.
            //
            // Presence, not `!= nil` on the patch: an absent `answer_request`
            // means unchanged, which includes "this daemon never looked", and a
            // card must not claim a question it has never seen.
            if answerRequest != nil { return .waitingForYou }
            // `idle` plus a positive count is the one reading the wire cannot
            // express in `state` alone, and it is the reason this case exists:
            // the session stopped, nothing is computing, and nobody needs to
            // look at it. Rendering it as plain `idle` put a busy card in the
            // same place as one holding a question.
            //
            // A `nil` count is not zero. An old daemon, or one that has not read
            // the transcript yet, says nothing — and a session we know nothing
            // about must not be promoted out of `idle` on a guess.
            if let pending = pendingAgents, pending > 0 { return .waitingOnAgents(pending) }
            return .idle
        case "starting": return .starting
        case "done": return .done
        case "dead": return .dead
        default: return .starting
        }
    }

    /// Sort key. Cards waiting on the user come first — they are the only ones
    /// with an action attached, and burying them under six working sessions is
    /// the failure this product exists to fix.
    ///
    /// A session waiting on background agents sits with the busy ones, directly
    /// below `working`: it must not compete for attention with a card that has a
    /// question on it, and it must not sink into the free pile either, because
    /// sorting it there is what made a session running five agents look like the
    /// most available one on the board.
    var sortRank: Int {
        switch lifecycle {
        case .waitingForYou: return 0
        case .working: return 1
        case .waitingOnAgents: return 2
        case .starting: return 3
        case .idle: return 4
        case .done: return 5
        case .dead: return 6
        }
    }
}

/// What a card is doing, as the *client* understands it.
///
/// Not a projection of the wire's `state`, and the difference matters:
/// `waitingForYou` already merges `state == "hitl"` with a pending permission
/// request the app knows about, and `waitingOnAgents` is `state == "idle"`
/// combined with `pending_agents > 0`. Both are presentation, decided here,
/// once, so no view has to combine two fields on its own.
enum Lifecycle: Equatable {
    case starting
    case idle
    case working
    /// Stopped, with background agents still out. Carries how many, because
    /// "waiting on one" and "waiting on five" are different situations and the
    /// count is already on the wire.
    case waitingOnAgents(Int)
    case waitingForYou
    case done
    case dead

    var label: String {
        switch self {
        case .starting: return "starting"
        case .idle: return "idle"
        case .working: return "working"
        // Deliberately not the word "waiting": on a card, "waiting" is the
        // vocabulary of `waiting for you`, and reusing it here would be asking
        // for attention on behalf of a session that needs none. What it says
        // instead is who is working — someone is, and it is not you.
        case .waitingOnAgents(let count):
            return count == 1 ? "1 agent running" : "\(count) agents running"
        case .waitingForYou: return "waiting for you"
        case .done: return "done"
        case .dead: return "dead"
        }
    }
}

// MARK: - Formatting

enum Fmt {
    /// The em dash that stands for "unknown".
    ///
    /// One constant rather than a literal at each call site, so that "unknown
    /// renders as a dash" is a property of the app rather than a habit that
    /// holds until somebody types `0` instead.
    static let unknown = "—"

    /// `8k`, `1.2M`, `940`. Compact because a card is a glanceable row.
    static func tokens(_ value: Int?, partial: Bool = false) -> String {
        guard let value else { return unknown }
        let prefix = partial ? "~" : ""
        switch value {
        case ..<1_000:
            return prefix + "\(value)"
        case ..<1_000_000:
            let k = Double(value) / 1_000
            return prefix + (k < 10 ? String(format: "%.1fk", k) : String(format: "%.0fk", k))
        default:
            return prefix + String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }

    /// `3h41m`, from an RFC 3339 instant. `nil` when it has passed or is
    /// unreadable — a countdown that has run out is not a countdown.
    static func countdown(to iso: String?, from now: Date = Date()) -> String? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return unknown }
        return String(format: "%.0f%%", fraction * 100)
    }
}
