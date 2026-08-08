// What the link to the daemon is actually doing.
//
// # Measured here, not asked for
//
// Every number below is something this side already observes: when the socket
// answered, how long the connect took, how many lines have arrived since. None
// of it needs a protocol change, and none of it is a number the daemon reports
// about itself — which is the point. A daemon claiming its own health is a
// daemon that says it is fine right up until it stops answering.
//
// # Why not IOPS
//
// It was asked for by that name and it would be a lie. The daemon does no disk
// I/O worth counting: it tails transcripts and holds a table in memory. A figure
// labelled IOPS would be either zero or invented, and a made-up number on a
// status line is worse than an empty one, because it gets believed. These are
// the honest equivalents — throughput, latency and uptime of the one link this
// app has.

import Foundation

@MainActor
final class DaemonTelemetry: ObservableObject {
    /// When the current connection was established. `nil` while down.
    @Published private(set) var connectedAt: Date?
    /// How long the socket took to answer, in seconds.
    @Published private(set) var connectLatency: TimeInterval?
    /// Lines received on the current connection.
    @Published private(set) var messages: Int = 0

    /// A short window rather than the whole connection.
    ///
    /// Averaged over hours, a busy minute and a dead one are the same number,
    /// and the reading stops moving — which is precisely when someone looks at
    /// it. Sixty seconds is long enough to be steady between messages and short
    /// enough to fall when the agents stop.
    private var recent: [Date] = []
    private static let window: TimeInterval = 60

    func connected(after latency: TimeInterval) {
        connectedAt = Date()
        connectLatency = latency
        messages = 0
        recent.removeAll()
    }

    func disconnected() {
        connectedAt = nil
        connectLatency = nil
        messages = 0
        recent.removeAll()
    }

    func received(at now: Date = Date()) {
        messages += 1
        recent.append(now)
        trim(now: now)
    }

    private func trim(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.window)
        // The list only grows at the rate lines arrive, so a prefix drop is
        // enough; nothing here justifies a ring buffer.
        if let first = recent.firstIndex(where: { $0 >= cutoff }), first > 0 {
            recent.removeFirst(first)
        } else if recent.allSatisfy({ $0 < cutoff }) {
            recent.removeAll()
        }
    }

    /// Messages per minute over the window.
    ///
    /// While the connection is younger than the window, the rate is scaled to
    /// what has actually been observed rather than divided by a minute that has
    /// not passed. Without that, a link up for five seconds reports a twelfth of
    /// its real rate and looks idle at exactly the moment it is busiest.
    func messagesPerMinute(now: Date = Date()) -> Int? {
        guard let connectedAt else { return nil }
        let observed = min(now.timeIntervalSince(connectedAt), Self.window)
        guard observed >= 1 else { return nil }
        let counted = recent.filter { $0 >= now.addingTimeInterval(-Self.window) }.count
        return Int((Double(counted) * Self.window / observed).rounded())
    }

    func uptime(now: Date = Date()) -> TimeInterval? {
        connectedAt.map { now.timeIntervalSince($0) }
    }

    /// `4s`, `12m`, `3h`. One unit, because the status line has room for one.
    static func short(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    /// `0.4ms`, `12ms`. Sub-millisecond is the normal case for a Unix socket,
    /// so it keeps a decimal there and drops it once the number is big enough
    /// for the decimal to be noise.
    static func latency(_ interval: TimeInterval) -> String {
        let ms = interval * 1000
        return ms < 10 ? String(format: "%.1fms", ms) : "\(Int(ms.rounded()))ms"
    }
}
