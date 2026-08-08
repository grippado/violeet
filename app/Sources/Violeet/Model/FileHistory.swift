// The last commit that touched a file, and a way to open it.
//
// # Why the app runs git here
//
// `SessionFileList` is emphatic that the app computes nothing: no git, no stat,
// no diff. That rule is about **the daemon's numbers** — a second place deriving
// a diffstat is a second place for it to disagree with the one that watched the
// edits happen.
//
// This is not that. The daemon has never heard of the file open in an editor
// tab, and asking it to tail every repository any tab ever visits would be a
// protocol grown to answer a question `git log -1` answers in milliseconds. The
// boundary holds: nothing here is a second opinion about something the daemon
// already knows.
//
// # Absent, not blank
//
// A file outside a repository, a repository with no commits, a git that will not
// run — all end the same way, with `nil`, and the panel simply shows nothing
// extra. There is no error state because there is no failure: "this file has no
// history to show" is an ordinary fact about most files on a machine.
//
// # The URL is derived, never guessed
//
// A remote is turned into a web address only when its shape is recognised.
// Anything else yields no link rather than a plausible one, because a commit
// link that 404s is worse than a hash you can copy.

import Foundation

/// What git says about the last commit to touch one file.
struct FileCommit: Equatable {
    /// Abbreviated, as git prints it. The short hash is what people read out
    /// and paste; the full one is in the link.
    let shortHash: String
    let fullHash: String
    let author: String
    let date: Date
    /// The commit's first line.
    let subject: String
    /// Where to open it, when the remote is one whose web layout is known.
    let url: URL?
}

enum GitRemote {
    /// The web address of a remote, when its shape is recognised.
    ///
    /// Handles the two spellings every host uses — SSH (`git@host:owner/repo`)
    /// and HTTPS (`https://host/owner/repo`) — and normalises away the `.git`
    /// suffix and any embedded credentials. A remote it does not recognise
    /// returns `nil`, and the panel shows a hash with no link.
    ///
    /// A pure function of its argument on purpose, so every one of these shapes
    /// is a test rather than something to try against a live repository.
    static func webURL(from remote: String) -> URL? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasSuffix("/") { text.removeLast() }

        // `ssh://git@host/owner/repo` and `https://host/owner/repo`.
        if let scheme = text.range(of: "://") {
            var rest = String(text[scheme.upperBound...])
            // Credentials, which must never reach a link shown on screen.
            if let at = rest.firstIndex(of: "@") {
                rest = String(rest[rest.index(after: at)...])
            }
            guard rest.contains("/") else { return nil }
            return URL(string: "https://" + rest)
        }

        // `git@host:owner/repo`, the scp-like form that is not a URL at all.
        if let at = text.firstIndex(of: "@"), let colon = text.firstIndex(of: ":") {
            guard at < colon else { return nil }
            let host = text[text.index(after: at)..<colon]
            let path = text[text.index(after: colon)...]
            guard !host.isEmpty, !path.isEmpty else { return nil }
            return URL(string: "https://\(host)/\(path)")
        }

        return nil
    }

    /// The page for one commit.
    ///
    /// GitHub, GitLab and Gitea all spell this `/commit/<hash>`; Bitbucket
    /// spells it `/commits/`. Anything unrecognised gets no link rather than a
    /// guess that leads to a 404.
    static func commitURL(remote: String, hash: String) -> URL? {
        guard let base = webURL(from: remote), let host = base.host else { return nil }
        let segment: String
        switch host {
        case "bitbucket.org":
            segment = "commits"
        case "github.com", "gitlab.com", "codeberg.org":
            segment = "commit"
        default:
            // Self-hosted GitLab and Gitea are common and both use `/commit/`,
            // but "common" is not "known" — and a wrong link is worse than a
            // hash the reader can paste themselves.
            return nil
        }
        return base.appendingPathComponent(segment).appendingPathComponent(hash)
    }
}

enum FileHistory {
    /// Parse the record `lastCommit` asks git for.
    ///
    /// The format is four fields on their own lines, in a fixed order, so the
    /// parsing is positional and testable without running anything. A subject
    /// containing a newline cannot break it: the subject is last, and the rest
    /// of the input belongs to it.
    static func parse(_ output: String, remote: String?) -> FileCommit? {
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 4 else { return nil }

        let full = lines[0].trimmingCharacters(in: .whitespaces)
        let author = lines[1].trimmingCharacters(in: .whitespaces)
        let iso = lines[2].trimmingCharacters(in: .whitespaces)
        let subject = lines[3...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !full.isEmpty, full.allSatisfy(\.isHexDigit) else { return nil }
        guard let date = ISO8601DateFormatter().date(from: iso) else { return nil }

        return FileCommit(
            shortHash: String(full.prefix(7)),
            fullHash: full,
            author: author,
            date: date,
            subject: subject,
            url: remote.flatMap { GitRemote.commitURL(remote: $0, hash: full) }
        )
    }

    /// Ask git about a file. Blocking; call it off the main actor.
    ///
    /// `nil` for a file outside a repository, a repository with no commits, or
    /// a git that will not run — all ordinary, none an error.
    static func lastCommit(forFileAt path: String) -> FileCommit? {
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return nil }

        // `%H` full hash, author name, author date in ISO 8601, subject.
        guard let record = run(
            ["-C", directory, "log", "-1", "--format=%H%n%an%n%aI%n%s", "--", path]
        ), !record.isEmpty else { return nil }

        let remote = run(["-C", directory, "remote", "get-url", "origin"])
        return parse(record, remote: remote)
    }

    /// `/usr/bin/git`, by absolute path.
    ///
    /// An app launched from the Finder inherits almost none of the user's
    /// `PATH` — the same fact that makes tabs spawn login shells — so looking
    /// git up by name would find it when run from a terminal and not when the
    /// app is double-clicked, which is the worst of both.
    private static let gitPath = "/usr/bin/git"

    private static func run(_ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: gitPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        // Discarded rather than inherited: git's complaints about a directory
        // that is not a repository are expected here, and they would otherwise
        // land in the app's log as if something had gone wrong.
        process.standardError = FileHandle.nullDevice
        // Without this, git in a repository with a pager configured can block
        // for ever waiting on a terminal that does not exist.
        process.environment = ["GIT_PAGER": "cat", "GIT_TERMINAL_PROMPT": "0"]

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
