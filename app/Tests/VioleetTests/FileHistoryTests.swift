// Turning a git remote into a link, and a `git log` record into a commit.
//
// Both are pure functions over text, which is the whole reason they are written
// as functions over text: every remote spelling in here is a test rather than
// something to try against a live repository.
//
// The property that matters most is the refusal. A commit link that 404s is
// worse than a hash the reader can paste, so anything unrecognised must produce
// no link at all — never a plausible one.

import Foundation
import Testing

@testable import Violeet

@Suite("File history")
struct FileHistoryTests {
    // MARK: - Remotes

    /// The two spellings every host offers for the same repository must reach
    /// the same page.
    @Test("ssh and https forms of one remote agree")
    func bothFormsAgree() {
        let ssh = GitRemote.webURL(from: "git@github.com:grippado/violeet.git")
        let https = GitRemote.webURL(from: "https://github.com/grippado/violeet.git")
        #expect(ssh?.absoluteString == "https://github.com/grippado/violeet")
        #expect(ssh == https)
    }

    @Test("the .git suffix and a trailing slash are not part of the address")
    func suffixesAreStripped() {
        for remote in [
            "https://github.com/grippado/violeet.git",
            "https://github.com/grippado/violeet/",
            "https://github.com/grippado/violeet",
        ] {
            #expect(
                GitRemote.webURL(from: remote)?.absoluteString == "https://github.com/grippado/violeet",
                "\(remote) did not normalise"
            )
        }
    }

    /// A remote can carry a token. It must never reach a link on screen.
    @Test("credentials in a remote are dropped")
    func credentialsAreDropped() {
        let url = GitRemote.webURL(from: "https://ghp_secrettoken@github.com/grippado/violeet.git")
        #expect(url?.absoluteString == "https://github.com/grippado/violeet")
        #expect(url?.absoluteString.contains("secrettoken") == false)
    }

    @Test("the ssh:// form is understood too")
    func sshSchemeForm() {
        #expect(
            GitRemote.webURL(from: "ssh://git@github.com/grippado/violeet.git")?.absoluteString
                == "https://github.com/grippado/violeet"
        )
    }

    @Test("nonsense yields no address")
    func nonsenseYieldsNothing() {
        for remote in ["", "   ", "not-a-remote", "/Users/me/local-clone"] {
            #expect(GitRemote.webURL(from: remote) == nil, "\(remote) produced an address")
        }
    }

    // MARK: - Commit pages

    /// Each host's own spelling, and no invention for the rest.
    @Test("known hosts get their own commit path")
    func knownHostsLinkCorrectly() {
        #expect(
            GitRemote.commitURL(remote: "git@github.com:grippado/violeet.git", hash: "abc123")?
                .absoluteString == "https://github.com/grippado/violeet/commit/abc123"
        )
        #expect(
            GitRemote.commitURL(remote: "git@bitbucket.org:team/repo.git", hash: "abc123")?
                .absoluteString == "https://bitbucket.org/team/repo/commits/abc123",
            "bitbucket spells it /commits/"
        )
    }

    /// The refusal, and the point of the whole exercise. Self-hosted GitLab and
    /// Gitea are common and would probably work — probably is not good enough
    /// for a link.
    @Test("an unknown host gets no link rather than a guess")
    func unknownHostRefuses() {
        #expect(GitRemote.commitURL(remote: "git@git.internal.example:team/repo.git", hash: "abc") == nil)
        #expect(GitRemote.commitURL(remote: "not-a-remote", hash: "abc") == nil)
    }

    // MARK: - Parsing

    @Test("a record becomes a commit")
    func parsesARecord() {
        let record = """
            8f3a2b1c9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a
            Gabriel Gripp
            2026-08-07T14:32:11-03:00
            fix(app): the panel stops inventing a session
            """
        let commit = FileHistory.parse(record, remote: "git@github.com:grippado/violeet.git")
        #expect(commit?.shortHash == "8f3a2b1")
        #expect(commit?.author == "Gabriel Gripp")
        #expect(commit?.subject == "fix(app): the panel stops inventing a session")
        #expect(commit?.url?.absoluteString.hasSuffix("/commit/8f3a2b1c9d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a") == true)
    }

    /// No remote is not an error — it is a repository nobody has pushed. The
    /// commit still shows; only the link is absent.
    @Test("a repository with no remote still has history")
    func noRemoteStillParses() {
        let record = "abc1234def\nSomeone\n2026-08-07T14:32:11Z\nfirst commit"
        let commit = FileHistory.parse(record, remote: nil)
        #expect(commit?.shortHash == "abc1234")
        #expect(commit?.url == nil)
    }

    /// The subject is last on purpose, so one containing a newline belongs to
    /// itself rather than breaking the fields after it.
    @Test("a multi-line subject does not derail the parse")
    func multiLineSubject() {
        let record = "abc1234def\nSomeone\n2026-08-07T14:32:11Z\nfirst line\nsecond line"
        #expect(FileHistory.parse(record, remote: nil)?.subject == "first line\nsecond line")
    }

    @Test("garbage parses to nothing rather than to a wrong commit")
    func garbageIsRefused() {
        #expect(FileHistory.parse("", remote: nil) == nil)
        #expect(FileHistory.parse("one\ntwo", remote: nil) == nil, "too few fields")
        #expect(
            FileHistory.parse("not-a-hash\nname\n2026-08-07T14:32:11Z\nsubject", remote: nil) == nil,
            "a hash that is not hexadecimal is not a hash"
        )
        #expect(
            FileHistory.parse("abc1234\nname\nnot-a-date\nsubject", remote: nil) == nil,
            "an unparseable date must not become today"
        )
    }
}
