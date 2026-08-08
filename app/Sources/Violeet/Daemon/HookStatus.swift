// Whether Claude Code is actually pointed at this daemon.
//
// # Why this is on screen at all
//
// A daemon with no hooks is running, connected, and blind. The status line said
// `daemon offline` when there was no daemon and nothing at all when there was
// one, so the state in between — daemon up, hooks missing, board permanently
// empty — had no way to be seen. You learned about it by noticing that sessions
// never appeared, which is the slowest possible way to find out.
//
// It came up for real: renaming the app from aiterm to Violeet moved the socket,
// the state directory and every `AITERM_*` variable, and left the hooks in
// `~/.claude/settings.json` pointing at a daemon that no longer existed. Every
// piece worked. Nothing was reported.
//
// # Why the check is a string search
//
// Not a schema. Claude Code owns that file's shape and changes it; a decoder
// that models it would need updating on their schedule, and would fail closed on
// a version it did not recognise — reporting "no hooks" for a machine that has
// them. Searching for the daemon's own hook URL is a question about *our* end,
// and it stays true whatever else moves around it.

import Foundation

enum HookStatus {
    /// Where Claude Code keeps its settings.
    static var settingsPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// The marker the CLI writes into each hook it installs.
    private static let marker = "src=violeet"

    /// Hooks belonging to the name this app used to have. Their presence is the
    /// signal for a migration rather than a first install, and it changes what
    /// the user is offered: absorbing beats adding a second set that races the
    /// first for the same events.
    private static let legacyMarker = "src=aiterm"

    struct Report: Equatable {
        var installed: Bool
        var legacyPresent: Bool
    }

    static func read() -> Report {
        guard let text = try? String(contentsOf: settingsPath, encoding: .utf8) else {
            // No settings file is not the same as no hooks, but it has the same
            // consequence — nothing reaches the daemon — and the same fix.
            return Report(installed: false, legacyPresent: false)
        }
        return Report(
            installed: text.contains(marker),
            legacyPresent: text.contains(legacyMarker)
        )
    }
}

/// Running the bundled CLI on the user's behalf.
///
/// The CLI already knows how to install hooks, and knows how to absorb or
/// replace ones left by the old name — `violeet doctor` reports the clash and
/// `install-hooks` resolves it. Shelling out to it means that logic lives in one
/// place and is the same whether it was reached from a terminal or from a
/// button.
@MainActor
enum HookInstaller {
    enum Result: Equatable {
        case installed
        case noBundledCLI
        case failed(String)
    }

    static func install() -> Result {
        guard let cli = DaemonSupervisor.bundledCLI else { return .noBundledCLI }

        let process = Process()
        process.executableURL = cli
        // `--yes` because the confirmation already happened: the user pressed a
        // button that said what it would do. A CLI prompt here would block a
        // process nobody can see the output of.
        //
        // `--on-conflict=absorb` is the one that makes the button work at all.
        // `--yes` deliberately does not cover the conflict question — it is
        // about somebody else's hook, and "yes" is not an answer to it — so
        // without this the CLI reached that prompt, found no terminal, printed
        // "nobody to ask" and aborted. It exited 0 while doing it, so the app
        // reported success and the status line went on saying hooks were
        // missing. Absorb rather than replace: the other hook is moved aside
        // and `uninstall-hooks` puts it back, which is the only choice here
        // that is reversible.
        process.arguments = ["install-hooks", "--yes", "--on-conflict=absorb"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let text = String(data: output, encoding: .utf8) ?? ""
                return .failed(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// What the previous name left behind.
///
/// Moved to the Trash, never deleted. This walks paths derived from a name
/// rather than paths the user pointed at, and a mistake in that derivation is
/// recoverable if it moves and permanent if it removes. The same rule the app
/// installer already follows for stray bundles.
@MainActor
enum LegacyState {
    /// `~/.aiterm` and the daemon binary the old install left in `~/.local/bin`.
    static var leftovers: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".aiterm"),
            home.appendingPathComponent(".local/bin/aiterm-daemon"),
            home.appendingPathComponent("Library/LaunchAgents/digital.opengateway.aiterm.daemon.plist"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var isPresent: Bool { !leftovers.isEmpty }

    /// Stop the old job, then move what it left to the Trash.
    @discardableResult
    static func clean() -> [URL] {
        // Bootout first: moving a running daemon's directory leaves it running
        // against a path that no longer exists, which is a worse state than
        // either end of the migration.
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/digital.opengateway.aiterm.daemon"]
        try? bootout.run()
        bootout.waitUntilExit()

        var moved: [URL] = []
        for url in leftovers {
            var trashed: NSURL?
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil {
                moved.append(url)
            }
        }
        return moved
    }
}
