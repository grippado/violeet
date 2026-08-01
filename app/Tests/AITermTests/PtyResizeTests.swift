// Does a font change actually reach the program on the other end of the PTY?
//
// This is the one part of the settings panel that is not cosmetic. Font family,
// size and line spacing change the cell size, which changes how many columns
// and rows fit — and the child process cannot see that on its own. Without
// `TIOCSWINSZ`, aiterm redraws at the new size while the program keeps
// composing for the old one, and any full-screen TUI tears on the next repaint.
//
// The mechanism lives inside SwiftTerm, which means it is exactly the kind of
// thing that can be silently lost to a dependency bump. So it is measured here
// rather than trusted: a real view, a real PTY, a real `ioctl` read back from
// the master descriptor.
//
// `docs/validation/settings-focus.md` covers the half a test cannot: whether a
// running agent visibly re-fits. This covers the half a human should not have
// to check by eye.

import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import AITerm

/// Ask the kernel what size it believes the terminal is.
///
/// Read from the master descriptor, which is the same one `TIOCSWINSZ` writes
/// to — so this is the value the child's `SIGWINCH` handler would see.
private func windowSize(of descriptor: Int32) -> winsize? {
    var size = winsize()
    guard ioctl(descriptor, TIOCGWINSZ, &size) == 0 else { return nil }
    return size
}

@MainActor
@Suite("PTY resize", .serialized)
struct PtyResizeTests {
    /// A view with a real frame and a real child, as close to a live tab as a
    /// test can get. The frame matters: SwiftTerm only recomputes the grid when
    /// the view has non-zero bounds.
    private func makeSession() -> TerminalSession? {
        // Deliberately not a size any test applies. `apply` skips the font
        // work when the view already has the font asked for, so a view born at
        // the size under test would never recompute — and the baseline would be
        // whatever `startProcess` guessed. That is how this test first reported
        // a column count moving when only the line spacing had.
        let session = TerminalSession(tabID: "test-tab", font: MonospacedFonts.font(named: "Menlo", size: 9))
        session.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        // `cat` rather than a shell: it holds the PTY open, reads nothing we
        // care about, and has no prompt to race with.
        session.view.startProcess(
            executable: "/bin/cat",
            args: [],
            environment: nil,
            execName: nil,
            currentDirectory: nil
        )

        // Spawning is asynchronous inside SwiftTerm. A short spin beats a fixed
        // sleep: it usually returns on the first pass.
        for _ in 0..<100 where !session.view.process.running {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return session.view.process.running ? session : nil
    }

    private func teardown(_ session: TerminalSession) {
        session.terminate()
    }

    /// The measurement the whole feature rests on: making the font bigger must
    /// make the kernel's idea of the terminal narrower.
    @Test func a_larger_font_narrows_the_grid_the_kernel_knows_about() throws {
        guard let session = makeSession() else {
            // A sandbox that cannot fork gives no signal either way. Reporting
            // a pass would be worse than skipping, and reporting a failure
            // would be blaming the code for the environment.
            Issue.record("could not spawn a child; PTY resize not measured here")
            return
        }
        defer { teardown(session) }

        var settings = TerminalSettings()
        settings.font.name = "Menlo"
        settings.font.size = 11
        session.apply(settings)

        let descriptor = session.view.process.childfd
        let small = try #require(windowSize(of: descriptor))
        #expect(small.ws_col > 0, "the kernel must have a size at all")

        settings.font.size = 22
        session.apply(settings)

        let large = try #require(windowSize(of: descriptor))
        #expect(
            large.ws_col < small.ws_col,
            "doubling the font must halve the columns the child is told about: \(small.ws_col) → \(large.ws_col)"
        )
        #expect(large.ws_row < small.ws_row)
    }

    /// Line spacing changes rows without changing columns, and goes through the
    /// same `resetFont()` path. Worth its own case because it is the one people
    /// forget when they think "font size" is the only metric.
    @Test func line_spacing_changes_the_rows_the_kernel_knows_about() throws {
        guard let session = makeSession() else {
            Issue.record("could not spawn a child; PTY resize not measured here")
            return
        }
        defer { teardown(session) }

        var settings = TerminalSettings()
        settings.font.name = "Menlo"
        settings.font.size = 13
        settings.font.lineSpacing = 1.0
        session.apply(settings)

        let descriptor = session.view.process.childfd
        let tight = try #require(windowSize(of: descriptor))

        settings.font.lineSpacing = 1.8
        session.apply(settings)

        let loose = try #require(windowSize(of: descriptor))
        #expect(
            loose.ws_row < tight.ws_row,
            "more leading must mean fewer rows: \(tight.ws_row) → \(loose.ws_row)"
        )
        #expect(loose.ws_col == tight.ws_col, "leading must not change the column count")
    }

    /// Applying the same settings twice must not disturb anything. The panel
    /// pushes the whole value on every change, so this runs constantly.
    @Test func re_applying_the_same_settings_leaves_the_size_alone() throws {
        guard let session = makeSession() else {
            Issue.record("could not spawn a child; PTY resize not measured here")
            return
        }
        defer { teardown(session) }

        let settings = TerminalSettings()
        session.apply(settings)
        let first = try #require(windowSize(of: session.view.process.childfd))

        session.apply(settings)
        let second = try #require(windowSize(of: session.view.process.childfd))

        #expect(first.ws_col == second.ws_col)
        #expect(first.ws_row == second.ws_row)
    }

    /// A colour change must not resize anything. If it did, every theme click
    /// would send a `SIGWINCH` to every running agent for no reason.
    @Test func a_colour_change_does_not_touch_the_grid() throws {
        guard let session = makeSession() else {
            Issue.record("could not spawn a child; PTY resize not measured here")
            return
        }
        defer { teardown(session) }

        var settings = TerminalSettings()
        session.apply(settings)
        let before = try #require(windowSize(of: session.view.process.childfd))

        settings.apply(theme: TerminalTheme.builtins[2])
        session.apply(settings)
        let after = try #require(windowSize(of: session.view.process.childfd))

        #expect(before.ws_col == after.ws_col)
        #expect(before.ws_row == after.ws_row)
    }
}
