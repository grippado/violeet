// How the daemon's status is said, in one place.
//
// Two surfaces show it now — the sidebar's footer and the status-bar menu's —
// and a third will want it eventually. Written twice, the two drift: one says
// "daemon offline" while the other says "disconnected", and a user reading both
// at once has to work out whether they are the same fact. They are.

import SwiftUI

extension DaemonClient.Status {
    /// The dot beside the label. Grey for offline on purpose: the daemon being
    /// down is an ordinary state (ADR-002), not an error, and red would say
    /// otherwise.
    var indicatorColor: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .secondary
        case .protocolMismatch: return .orange
        }
    }

    /// The status with the session count folded in, for a surface that has room
    /// for one line and not two.
    func summary(sessionCount: Int) -> String {
        switch self {
        case .connected:
            return sessionCount == 1 ? "daemon · 1 session" : "daemon · \(sessionCount) sessions"
        case .connecting: return "connecting…"
        case .disconnected: return "daemon offline"
        case .protocolMismatch(let version): return "daemon speaks v\(version)"
        }
    }

    /// The status on its own, for a surface that states the count separately.
    var shortLabel: String {
        switch self {
        case .connected: return "daemon connected"
        case .connecting: return "daemon connecting…"
        case .disconnected: return "daemon offline"
        case .protocolMismatch(let version): return "daemon speaks v\(version)"
        }
    }
}
