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
    var gitBranch: String?
    var lastAction: String?
    var lastEventAt: String?

    var contextUsedTokens: Int?
    var contextSizeTokens: Int?
    var cumulativeInputTokens: Int?
    var cumulativeOutputTokens: Int?
    /// See `SessionUpdated.cumulativeTokensPartial`.
    var cumulativeTokensPartial: Bool?

    /// Set by `AppState` from the pending-HITL table, not by the daemon's
    /// `state` field. Both say the session is blocked; this one is the reason
    /// the card can also show *what* it is blocked on.
    var pendingHitl: HitlPending?

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
        gitBranch = patch.gitBranch.applied(to: gitBranch)
        lastAction = patch.lastAction.applied(to: lastAction)
        lastEventAt = patch.lastEventAt.applied(to: lastEventAt)
        tabID = patch.tabID.applied(to: tabID)

        contextUsedTokens = patch.contextWindowUsedTokens.applied(to: contextUsedTokens)
        contextSizeTokens = patch.contextWindowSizeTokens.applied(to: contextSizeTokens)
        cumulativeInputTokens = patch.cumulativeInputTokens.applied(to: cumulativeInputTokens)
        cumulativeOutputTokens = patch.cumulativeOutputTokens.applied(to: cumulativeOutputTokens)
        cumulativeTokensPartial = patch.cumulativeTokensPartial.applied(to: cumulativeTokensPartial)
    }
}

// MARK: - Presentation

extension SessionCard {
    /// The headline. The cwd for now; automatic naming is the next task.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        guard let cwd, !cwd.isEmpty else { return "unknown" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// The full path, for the tooltip — the row shows only the leaf.
    var subtitle: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return ProcessDirectory.abbreviated(cwd)
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
        case "idle": return .idle
        case "starting": return .starting
        case "done": return .done
        case "dead": return .dead
        default: return .starting
        }
    }

    /// Sort key. Cards waiting on the user come first — they are the only ones
    /// with an action attached, and burying them under six working sessions is
    /// the failure this product exists to fix.
    var sortRank: Int {
        switch lifecycle {
        case .waitingForYou: return 0
        case .working: return 1
        case .starting: return 2
        case .idle: return 3
        case .done: return 4
        case .dead: return 5
        }
    }
}

enum Lifecycle: Equatable {
    case starting
    case idle
    case working
    case waitingForYou
    case done
    case dead

    var label: String {
        switch self {
        case .starting: return "starting"
        case .idle: return "idle"
        case .working: return "working"
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

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return unknown }
        return String(format: "%.0f%%", fraction * 100)
    }
}
