// Making sure there is a daemon to talk to.
//
// # The hole this fills
//
// Until this existed, the app was shipped without one. There was no installer,
// the README said "run it", and the only machine where the board ever filled up
// was the one where somebody had put a binary under `launchd` by hand. Anyone
// downloading the .dmg got a permanently empty sidebar and a status line saying
// `daemon offline`, with nothing on screen suggesting what to do about it. That
// is not a missing feature, it is a broken product.
//
// So the daemon travels inside the bundle (see `app/scripts/package.sh`) and
// this puts it under `launchd` on first run.
//
// # Why launchd and not a child process
//
// The daemon has to outlive the app. Its whole reason to exist is watching
// sessions that are *not* running in Violeet — an agent in iTerm, in another
// window, in a terminal that was open before this one launched. A daemon that
// died with the app would go blind exactly when nobody is looking, and the
// hooks Claude Code fires would hit a closed port.
//
// # Why a LaunchAgent plist and not SMAppService
//
// `SMAppService.daemon` is the modern answer and needs the helper to be inside
// a bundle signed with a Developer ID: it refuses to register otherwise. These
// builds are ad-hoc signed. A LaunchAgent plist in `~/Library/LaunchAgents`
// works either way, needs no privilege escalation, and is removable by hand by
// anyone who wants it gone — which, for something that starts itself, matters.
//
// # Why the plist points into /Applications
//
// The `Program` is the copy inside the installed bundle, so replacing the app
// replaces the daemon. Copying the binary elsewhere would create a second one
// to keep in sync, and an app that updates while its daemon does not is how a
// protocol mismatch happens on a machine nobody touched.

import Foundation

@MainActor
final class DaemonSupervisor {
    static let label = "digital.opengateway.violeet.daemon"

    /// What was tried, for the status line to be specific rather than sorry.
    enum Outcome: Equatable {
        /// Already answering on the socket. Nothing was done.
        case alreadyRunning
        /// The job was written and loaded.
        case started
        /// No daemon binary in the bundle: a development build run from
        /// SwiftPM rather than from `package.sh`.
        case noBundledDaemon
        /// `launchctl` refused. Carries its stderr, because the terse ones
        /// ("Input/output error") mean nothing without it.
        case failed(String)
    }

    private(set) var lastOutcome: Outcome?

    /// The daemon inside the running app, if this is a packaged build.
    static var bundledDaemon: URL? {
        guard let url = Bundle.main.url(forResource: "violeet-daemon", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url
    }

    /// The bundled CLI, which is what installs the Claude Code hooks.
    static var bundledCLI: URL? {
        guard let url = Bundle.main.url(forResource: "violeet", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path)
        else { return nil }
        return url
    }

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".violeet")
    }

    /// Start the daemon if nothing is answering.
    ///
    /// Safe to call on every launch: the socket probe is what decides, so a
    /// daemon somebody started by hand is left alone rather than fought with.
    @discardableResult
    func ensureRunning() -> Outcome {
        if DaemonProbe.isListening() {
            lastOutcome = .alreadyRunning
            return .alreadyRunning
        }
        guard let daemon = Self.bundledDaemon else {
            lastOutcome = .noBundledDaemon
            return .noBundledDaemon
        }

        do {
            try Self.writePlist(program: daemon)
            try Self.load()
            lastOutcome = .started
            return .started
        } catch {
            let outcome = Outcome.failed(error.localizedDescription)
            lastOutcome = outcome
            return outcome
        }
    }

    /// Stop the job and remove it. For an uninstall, and for a user who wants
    /// the thing off their machine without hunting for the plist.
    static func unload() throws {
        _ = try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    // MARK: - launchd

    private static func writePlist(program: URL) throws {
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logDirectory, withIntermediateDirectories: true
        )

        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [program.path],
            // Start now and on login. `KeepAlive` restarts it if it crashes,
            // which is the behaviour that makes "is the daemon up" stop being a
            // question the user has to ask.
            "RunAtLoad": true,
            "KeepAlive": true,
            // Its own log, not the unified log: the daemon's own failures are
            // what someone debugging an empty sidebar needs, and `log show` is
            // a poor place to find them.
            "StandardOutPath": logDirectory.appendingPathComponent("daemon.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("daemon.log").path,
            // A Finder-launched app has almost no PATH, and the job inherits
            // this app's environment. The daemon shells out for `git` and for
            // the transcript directory, so it is given a usable one.
            "EnvironmentVariables": [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            ],
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: job, format: .xml, options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private static func load() throws {
        let target = "gui/\(getuid())"
        // Boot it out first, ignoring failure. Without this, a plist that
        // changed — because the app moved, or was updated — is ignored:
        // `bootstrap` on an already-loaded label is an error and leaves the old
        // job, pointing at the old binary, running.
        _ = try? run("/bin/launchctl", ["bootout", "\(target)/\(label)"])
        _ = try run("/bin/launchctl", ["bootstrap", target, plistURL.path])
        // `bootstrap` returning does not mean the process is up yet.
        _ = try? run("/bin/launchctl", ["kickstart", "\(target)/\(label)"])
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: output, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SupervisorError.commandFailed(
                "\(([tool] + arguments).joined(separator: " ")) exited \(process.terminationStatus): \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return text
    }

    enum SupervisorError: LocalizedError {
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let detail): return detail
            }
        }
    }
}

/// Is anything listening on the socket?
///
/// Connecting is the only honest test. The discovery file can be left behind by
/// a daemon that died, and a stale socket file stays on disk after a crash — so
/// both exist in exactly the situation where the answer is "no".
enum DaemonProbe {
    static func isListening() -> Bool {
        let path = Discovery.socketPath()
        guard FileManager.default.fileExists(atPath: path) else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let size = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < size else { return false }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, size - 1)
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addr in
                connect(fd, addr, length) == 0
            }
        }
        return connected
    }
}
