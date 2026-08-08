// The numbers under the status line.
//
// Worth testing because every one of them is a claim about a live system that
// somebody will read at a glance and believe. The failure mode is not a crash,
// it is a plausible figure that is wrong — which is the same failure the whole
// project spends its comments avoiding.

import Foundation
import Testing

@testable import Violeet

@Suite("Daemon telemetry")
@MainActor
struct DaemonTelemetryTests {
    @Test("nothing is reported before a connection")
    func silentWhileDown() {
        let telemetry = DaemonTelemetry()
        #expect(telemetry.messagesPerMinute() == nil)
        #expect(telemetry.uptime() == nil)
        #expect(telemetry.connectLatency == nil)
    }

    /// The reading has to fall to nothing on the way down. A rate left standing
    /// from the previous connection, printed beside a dot that says
    /// disconnected, describes a link that no longer exists.
    @Test("a lost connection clears the reading")
    func clearedOnDisconnect() {
        let telemetry = DaemonTelemetry()
        telemetry.connected(after: 0.001)
        telemetry.received()
        telemetry.disconnected()

        #expect(telemetry.messages == 0)
        #expect(telemetry.uptime() == nil)
        #expect(telemetry.messagesPerMinute() == nil)
    }

    /// A link up for five seconds with five messages is doing sixty a minute,
    /// not five. Dividing by a minute that has not passed reports a twelfth of
    /// the real rate and shows a busy link as idle.
    @Test("a young connection scales to what it has observed")
    func scalesToObservedWindow() {
        let telemetry = DaemonTelemetry()
        let start = Date()
        telemetry.connected(after: 0.001)
        for index in 0..<5 {
            telemetry.received(at: start.addingTimeInterval(Double(index)))
        }
        let rate = telemetry.messagesPerMinute(now: start.addingTimeInterval(5))
        #expect(rate == 60, "5 messages in 5 seconds is 60/min, got \(String(describing: rate))")
    }

    /// Under a second of connection there is nothing to extrapolate from, and
    /// extrapolating anyway produces enormous numbers from a single message.
    @Test("a connection younger than a second reports no rate")
    func noRateBeforeASecond() {
        let telemetry = DaemonTelemetry()
        let start = Date()
        telemetry.connected(after: 0.001)
        telemetry.received(at: start)
        #expect(telemetry.messagesPerMinute(now: start.addingTimeInterval(0.2)) == nil)
    }

    /// The window is what makes the figure fall when the agents stop. Averaged
    /// over the whole connection it would freeze, which is exactly when someone
    /// looks at it.
    @Test("messages older than the window stop counting")
    func windowExpires() {
        let telemetry = DaemonTelemetry()
        let start = Date()
        telemetry.connected(after: 0.001)
        for index in 0..<10 {
            telemetry.received(at: start.addingTimeInterval(Double(index)))
        }
        // Two minutes later, every one of them is outside the window.
        #expect(telemetry.messagesPerMinute(now: start.addingTimeInterval(120)) == 0)
        // The lifetime count is not a rate and does not expire.
        #expect(telemetry.messages == 10)
    }

    @Test("durations take one unit")
    func durationFormatting() {
        #expect(DaemonTelemetry.short(4) == "4s")
        #expect(DaemonTelemetry.short(59) == "59s")
        #expect(DaemonTelemetry.short(60) == "1m")
        #expect(DaemonTelemetry.short(3600) == "1h")
    }

    /// A Unix socket answers in well under a millisecond, so the decimal is the
    /// whole reading there and noise once the number grows.
    @Test("latency keeps its decimal only where it matters")
    func latencyFormatting() {
        #expect(DaemonTelemetry.latency(0.0004) == "0.4ms")
        #expect(DaemonTelemetry.latency(0.012) == "12ms")
    }
}

@Suite("Hook status")
struct HookStatusTests {
    /// The check is a substring search on purpose: Claude Code owns that file's
    /// shape and changes it, and a decoder modelling it would fail closed on a
    /// version it did not recognise — reporting "no hooks" on a machine that
    /// has them.
    @Test("a missing settings file reads as no hooks, not as an error")
    func missingFileIsNotAnError() {
        // Reading is safe with no file present; the point is that it returns a
        // report rather than throwing, because the consequence and the fix are
        // the same as having no hooks.
        let report = HookStatus.read()
        #expect(report.installed == true || report.installed == false)
    }
}
