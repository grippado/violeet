// The "Open with" list.
//
// The list itself belongs to the machine, so what is testable here is what this
// code does *to* it: the deduplication, the cap, and the promise that the
// system's own order survives. Asserting which applications appear would be
// asserting what is installed on whoever runs the suite.

import AppKit
import Testing

@testable import Violeet

@Suite("External apps")
struct ExternalAppsTests {
    /// A file type nobody claims still has to answer, because the panel builds
    /// a menu from this and an empty menu is a dead control. `System default`
    /// is added by the caller for exactly this case.
    @Test("an unclaimed type produces a list rather than a crash")
    func unclaimedTypeIsSafe() {
        let choices = ExternalApps.choices(for: "/tmp/violeet-nothing-claims-this.zzqq")
        #expect(choices.count >= 0)
    }

    /// A path that does not exist is an ordinary state here: the file may have
    /// been moved since the tab opened, and the panel still draws.
    @Test("a missing file does not throw")
    func missingFileIsSafe() {
        _ = ExternalApps.choices(for: "/tmp/violeet-does-not-exist-\(UUID().uuidString).txt")
    }

    /// The cap keeps a common type from producing a menu you have to scroll.
    /// `.txt` claims two dozen applications on a working machine.
    @Test("the list is capped")
    func listIsCapped() {
        let choices = ExternalApps.choices(for: "/etc/hosts", limit: 3)
        #expect(choices.count <= 3)
    }

    /// macOS reports the same application twice on machines that have it in
    /// more than one place. Two identical rows in a menu are a coin toss, not
    /// a choice.
    @Test("no two entries share a name")
    func namesAreUnique() {
        let names = ExternalApps.choices(for: "/etc/hosts").map(\.name)
        #expect(Set(names).count == names.count)
    }

    /// `.app` is how the bundle is stored, not what the application is called.
    @Test("names are how a person says them")
    func namesAreHumanReadable() {
        for choice in ExternalApps.choices(for: "/etc/hosts") {
            #expect(!choice.name.hasSuffix(".app"), "\(choice.name) kept its bundle suffix")
            #expect(!choice.name.isEmpty)
        }
    }
}
