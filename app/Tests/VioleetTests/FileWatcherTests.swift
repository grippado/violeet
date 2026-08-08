// The watcher, against the two ways a file changes.
//
// This is the test the whole live-reload feature rests on, and the second case
// is the one that matters: vim's default save does not write into the file it
// opened. It writes a new one beside it and renames it over the top, which
// unlinks the inode a naive watcher is holding. That watcher then fires once,
// ever, and every save after it is silent.
//
// So the rename case is simulated exactly as vim performs it — write a sibling,
// `rename(2)` it into place — rather than by touching the original. A test that
// only wrote in place would pass against the broken implementation.
//
// Timing is real here, because the thing under test is the file system telling
// us something. The waits are bounded and poll rather than sleep a fixed span,
// so a fast machine finishes fast and a slow one still passes.

import Foundation
import Testing

@testable import Violeet

@Suite("File watcher")
struct FileWatcherTests {
    /// Counts callbacks on the main actor, which is where the watcher delivers.
    @MainActor
    private final class Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    /// Wait until `condition` holds, or give up. Polling rather than one long
    /// sleep: the events arrive in milliseconds on a warm machine and the test
    /// should not spend a fixed second proving it.
    @MainActor
    private func wait(
        upTo seconds: Double = 5,
        for condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    private func inTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("violeet-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    /// The easy half: `backupcopy=yes`, a shell redirect, anything that writes
    /// into the file that is already there.
    @Test("a write in place is noticed")
    @MainActor
    func writeInPlace() async throws {
        try await inTemporaryDirectory { root in
            let file = root.appendingPathComponent("theme.json")
            try Data("first".utf8).write(to: file)

            let counter = Counter()
            let watcher = FileWatcher(path: file.path) { counter.bump() }
            defer { watcher.stop() }

            // The sources are armed asynchronously, so give them the moment
            // before making the change they are meant to catch.
            _ = await wait(upTo: 1) { false }

            try Data("second".utf8).write(to: file)
            let noticed = await wait { counter.count > 0 }
            #expect(noticed, "an in-place write produced no callback")
        }
    }

    /// The half that breaks naive watchers, and the reason this class exists.
    ///
    /// `Data.write(to:)` with `.atomic` and vim's default `:w` both do this:
    /// the bytes land in a new inode and the name is moved onto it. A watcher
    /// holding the old descriptor is now watching an unlinked file that nobody
    /// can reach, and it will never fire again.
    @Test("a file replaced by rename is still watched, and stays watched")
    @MainActor
    func atomicReplaceKeepsWorking() async throws {
        try await inTemporaryDirectory { root in
            let file = root.appendingPathComponent("theme.json")
            try Data("first".utf8).write(to: file)

            let counter = Counter()
            let watcher = FileWatcher(path: file.path) { counter.bump() }
            defer { watcher.stop() }
            _ = await wait(upTo: 1) { false }

            // Exactly what vim does: a sibling, renamed over the top.
            func replace(with text: String) throws {
                let staging = root.appendingPathComponent("theme.json~")
                try Data(text.utf8).write(to: staging)
                _ = try FileManager.default.replaceItemAt(file, withItemAt: staging)
            }

            try replace(with: "second")
            let first = await wait { counter.count > 0 }
            #expect(first, "the first replace produced no callback")

            // The one that fails against a watcher that does not re-arm. The
            // first save always works; it is the second that tells you whether
            // the descriptor followed the name.
            let afterFirst = counter.count
            try replace(with: "third")
            let second = await wait { counter.count > afterFirst }
            #expect(
                second,
                "the watcher stopped after one save: it is holding the unlinked inode"
            )

            let afterSecond = counter.count
            try replace(with: "fourth")
            let third = await wait { counter.count > afterSecond }
            #expect(third, "the watcher survived two saves but not three")
        }
    }

    /// A theme that does not exist yet is the normal case for "create your own":
    /// the watcher is pointed at a path before anything is written there.
    @Test("a file that does not exist yet is picked up when it arrives")
    @MainActor
    func fileCreatedLater() async throws {
        try await inTemporaryDirectory { root in
            let file = root.appendingPathComponent("later.json")

            let counter = Counter()
            let watcher = FileWatcher(path: file.path) { counter.bump() }
            defer { watcher.stop() }
            _ = await wait(upTo: 1) { false }

            try Data("hello".utf8).write(to: file)
            let arrived = await wait { counter.count > 0 }
            #expect(arrived, "the file arriving produced no callback")
        }
    }

    /// One save is several events — truncate, write, rename — and a callback per
    /// event means parsing a half-written file and flashing an error that
    /// corrects itself. The coalescing window is what prevents that.
    @Test("a burst of writes collapses into few callbacks")
    @MainActor
    func burstsAreCoalesced() async throws {
        try await inTemporaryDirectory { root in
            let file = root.appendingPathComponent("theme.json")
            try Data("0".utf8).write(to: file)

            let counter = Counter()
            let watcher = FileWatcher(path: file.path) { counter.bump() }
            defer { watcher.stop() }
            _ = await wait(upTo: 1) { false }

            for index in 1...12 {
                try Data("\(index)".utf8).write(to: file)
            }
            let fired = await wait { counter.count > 0 }
            #expect(fired)

            // Let anything still queued land before counting.
            try? await Task.sleep(nanoseconds: 400_000_000)
            #expect(counter.count < 12, "twelve writes produced \(counter.count) callbacks")
        }
    }

    /// Stopping means stopping. A watcher per theme edit that kept firing would
    /// have the terminal repainted by a file the user has moved on from.
    @Test("a stopped watcher goes quiet")
    @MainActor
    func stopIsFinal() async throws {
        try await inTemporaryDirectory { root in
            let file = root.appendingPathComponent("theme.json")
            try Data("first".utf8).write(to: file)

            let counter = Counter()
            let watcher = FileWatcher(path: file.path) { counter.bump() }
            _ = await wait(upTo: 1) { false }
            watcher.stop()
            // The stop is queued behind whatever the sources are doing, so let
            // it take effect before testing that it did.
            try? await Task.sleep(nanoseconds: 300_000_000)

            let afterStop = counter.count
            try Data("second".utf8).write(to: file)
            try? await Task.sleep(nanoseconds: 400_000_000)
            #expect(counter.count == afterStop, "a stopped watcher still fired")
        }
    }
}
