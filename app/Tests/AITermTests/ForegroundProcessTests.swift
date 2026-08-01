// Does `tcgetpgrp` on the master descriptor actually name the program running
// in the tab?
//
// The whole naming chain rests on this answering `cat` while cat is in the
// foreground and something else when it is not. It is a kernel behaviour on a
// descriptor SwiftTerm owns, which makes it exactly the kind of assumption that
// is cheap to state and expensive to be wrong about — so it is measured against
// a real PTY with a real child rather than reasoned about.

import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import AITerm

@MainActor
@Suite("Foreground process", .serialized)
struct ForegroundProcessTests {
    /// A live PTY with a known program in the foreground.
    ///
    /// `cat` for the same reasons `PtyResizeTests` uses it: it holds the PTY
    /// open, has no prompt to race with, and — the part that matters here — it
    /// is its own process group leader, which is what `tcgetpgrp` reports.
    private func makeSession() -> TerminalSession? {
        let session = TerminalSession(tabID: "fg-test", font: MonospacedFonts.font(named: "Menlo", size: 12))
        session.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        session.view.startProcess(
            executable: "/bin/cat",
            args: [],
            environment: nil,
            execName: nil,
            currentDirectory: nil
        )
        for _ in 0..<100 where !session.view.process.running {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return session.view.process.running ? session : nil
    }

    @Test("the kernel names the program in the foreground of a live PTY")
    func theForegroundProgramIsReadable() throws {
        guard let session = makeSession() else {
            Issue.record("could not spawn a child on a PTY")
            return
        }
        defer { session.terminate() }

        // The child is spawned asynchronously and takes a moment to become the
        // foreground group; spin rather than sleep a fixed amount.
        var name: String?
        for _ in 0..<200 {
            name = ForegroundProcess.name(ofPTY: session.view.process.childfd)
            if name == "cat" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        #expect(
            name == "cat",
            """
            tcgetpgrp on the master descriptor must report the program actually \
            running, got \(name.map { "\"\($0)\"" } ?? "nil"). This is the \
            measurement the whole of level 2 rests on.
            """
        )
    }

    /// The property the whole design rests on, stated as a sequence rather
    /// than as a snapshot: **it is exactly the program while the program runs,
    /// and exactly the shell when it stops.**
    ///
    /// This is what OSC titles cannot do. A program that sets a title and exits
    /// leaves the title behind; the kernel's answer changes back on its own,
    /// with no cooperation from anything, which is why level 2 reads it and not
    /// the title.
    ///
    /// Run against a real zsh, driven by writing into the PTY the way a person
    /// would type.
    @Test("a program takes the tab's name while it runs, and gives it back when it exits")
    func theNameFollowsTheProgramInAndOut() throws {
        let session = TerminalSession(tabID: "fg-cycle", font: MonospacedFonts.font(named: "Menlo", size: 12))
        session.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        session.view.startProcess(
            executable: "/bin/zsh",
            // `-f`: no rc files. The user's own zsh configuration is not this
            // test's business, and a theme that runs something on every prompt
            // would put its own process in the foreground.
            args: ["-f"],
            environment: nil,
            execName: nil,
            currentDirectory: nil
        )
        for _ in 0..<100 where !session.view.process.running {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard session.view.process.running else {
            Issue.record("could not spawn a shell on a PTY")
            return
        }
        defer { session.terminate() }

        let descriptor = session.view.process.childfd

        /// Spin until the foreground process is `expected`, up to a limit.
        func settle(on expected: String, within seconds: Double) -> String? {
            var seen: String?
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                seen = ForegroundProcess.name(ofPTY: descriptor)
                if seen == expected { return seen }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            return seen
        }

        #expect(settle(on: "zsh", within: 3) == "zsh", "an idle tab is its shell")

        // Typed, not spawned: this goes through the terminal exactly as a
        // keystroke would, so the process group is the one a real command gets.
        let command = Array("sleep 2\n".utf8)[...]
        session.view.process.send(data: command)

        #expect(
            settle(on: "sleep", within: 3) == "sleep",
            "while a program runs, the tab is that program"
        )
        #expect(
            settle(on: "zsh", within: 5) == "zsh",
            """
            and when it exits the tab goes back to its shell on its own — the \
            thing a title left behind by a program can never do
            """
        )
        // Which is the level-2 rule end to end: `sleep` names the tab, `zsh`
        // hands it back to the level below.
        #expect(SessionName.usefulProcess("sleep") == "sleep")
        #expect(SessionName.usefulProcess("zsh") == nil)
    }

    /// A closed or nonsensical descriptor must produce `nil` rather than a
    /// crash or a stale name: the tab keeps whatever it had.
    @Test("an unreadable descriptor names nothing")
    func anUnreadableDescriptorNamesNothing() {
        #expect(ForegroundProcess.name(ofPTY: -1) == nil)
        // A valid descriptor that is not a terminal. `tcgetpgrp` fails with
        // ENOTTY, which must read as "no answer" and not as an error to show.
        let devNull = open("/dev/null", O_RDONLY)
        defer { close(devNull) }
        #expect(ForegroundProcess.name(ofPTY: devNull) == nil)
    }

    @Test("a pid nobody is running names nothing")
    func anUnknownPidNamesNothing() {
        #expect(ForegroundProcess.name(ofProcess: 0) == nil)
        #expect(ForegroundProcess.name(ofProcess: -1) == nil)
    }

    /// This process names itself. A weak assertion on the exact text — a test
    /// bundle's executable name is the harness's business — but it proves
    /// `proc_name` returns something rather than silently failing on a pid that
    /// definitely exists.
    @Test("proc_name answers for a process that exists")
    func procNameAnswersForALivePid() {
        let name = ForegroundProcess.name(ofProcess: getpid())
        #expect(name != nil)
        #expect(!(name ?? "").isEmpty)
    }

    /// The chain end to end, on a real PTY: the kernel says `cat`, and the
    /// resolver turns that into the tab's name.
    @Test("a live tab running a program is named after it, over its directory")
    func aLiveTabIsNamedAfterItsProgram() throws {
        guard let session = makeSession() else {
            Issue.record("could not spawn a child on a PTY")
            return
        }
        defer { session.terminate() }

        var process: String?
        for _ in 0..<200 {
            process = ForegroundProcess.name(ofPTY: session.view.process.childfd)
            if process == "cat" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        let name = SessionName.resolve(
            NameInputs(foregroundProcess: process, cwd: NSHomeDirectory())
        )
        #expect(name.text == "cat")
        #expect(name.source == .process)
        #expect(name.text != "~", "the program beats the directory, not the other way round")
    }
}
