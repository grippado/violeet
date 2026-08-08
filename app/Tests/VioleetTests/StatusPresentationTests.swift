// The two things the status bar and the About panel say that a test can hold.
//
// Not the menu itself: building it needs a real `NSStatusBar`, a real window
// and a main-actor app state, and a test that stands all three up tests AppKit
// rather than this app. What is left is where a mistake would be *silent* —
// the strings, which are duplicated across two surfaces and would otherwise
// drift apart unnoticed.

import Testing

@testable import Violeet

@Suite("Daemon status, said the same way everywhere")
struct StatusPresentationTests {
    @Test("the session count is pluralised")
    func pluralisesSessions() {
        #expect(DaemonClient.Status.connected.summary(sessionCount: 1) == "daemon · 1 session")
        #expect(DaemonClient.Status.connected.summary(sessionCount: 0) == "daemon · 0 sessions")
        #expect(DaemonClient.Status.connected.summary(sessionCount: 4) == "daemon · 4 sessions")
    }

    /// A count belongs to the connected state and to no other: "connecting · 3
    /// sessions" would state a number the app has not been told yet.
    @Test("no count is claimed while the link is not up")
    func countIsOnlyForConnected() {
        #expect(DaemonClient.Status.connecting.summary(sessionCount: 3) == "connecting…")
        #expect(DaemonClient.Status.disconnected.summary(sessionCount: 3) == "daemon offline")
    }

    /// The mismatch has to name the version. It is the one status the user can
    /// act on, and "offline" would send them to restart a daemon that is up.
    @Test("a protocol mismatch says which version the daemon speaks")
    func mismatchNamesTheVersion() {
        let status = DaemonClient.Status.protocolMismatch(daemonVersion: 7)
        #expect(status.summary(sessionCount: 0) == "daemon speaks v7")
        #expect(status.shortLabel == "daemon speaks v7")
    }

    @Test("the short label always names the daemon, so it reads on its own")
    func shortLabelIsSelfContained() {
        let all: [DaemonClient.Status] = [
            .connected, .connecting, .disconnected, .protocolMismatch(daemonVersion: 2),
        ]
        for status in all {
            #expect(status.shortLabel.contains("daemon"))
        }
    }
}

@Suite("Which build this is")
struct BuildInfoTests {
    /// The panel must never show a hash that is not one. `unknown` is what the
    /// committed plist carries, and a bundle assembled without
    /// `scripts/package.sh` keeps it — rendering it would send a bug report to
    /// a revision that does not exist.
    @Test("a placeholder commit is treated as no commit")
    func placeholderCommitIsDropped() {
        // The test bundle has no `VioleetGitCommit`, which is the same absence
        // the placeholder stands for.
        #expect(BuildInfo.commit == nil)
        #expect(BuildInfo.versionLine == "version \(BuildInfo.version)")
        #expect(!BuildInfo.versionLine.contains("unknown"))
    }
}
