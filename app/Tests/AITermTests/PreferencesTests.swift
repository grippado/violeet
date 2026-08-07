// What a fresh install opens with, and what it must not forget.
//
// These are product decisions with no compiler behind them: nothing breaks if
// the inspector opens on the wrong panel, it just stops being the panel that
// was chosen. A test is the only thing that notices.

import Foundation
import Testing

@testable import AITerm

@Suite("Preferences defaults")
struct PreferencesTests {
    /// A suite of its own per test, so nothing leaks between them or into the
    /// defaults of the machine running the suite.
    private func emptyDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("the inspector opens on Files, not on Settings")
    func inspectorDefaultsToFiles() {
        let preferences = Preferences(defaults: emptyDefaults())
        #expect(preferences.inspectorPanel == .files)
    }

    @Test("a chosen panel outlives the default")
    func storedPanelWins() {
        let name = UUID().uuidString
        let defaults = emptyDefaults(name)

        Preferences(defaults: defaults).inspectorPanel = .settings

        // A second Preferences over the same defaults is what relaunching is.
        #expect(Preferences(defaults: defaults).inspectorPanel == .settings)
    }

    /// Tab order is declaration order, and the first tab is the one a new user
    /// lands on when the stored panel is gone.
    @Test("Files is the first tab")
    func filesLeadsTheTabs() {
        #expect(InspectorPanel.allCases.first == .files)
    }
}

@Suite("Sidebar spans")
struct SidebarSpanTests {
    typealias Span = Preferences.SidebarSpan

    /// Every rung has to be a width the sidebar will actually accept, or the
    /// button would set one thing and the clamp would store another.
    @Test("no rung falls outside the sidebar's own bounds")
    func rungsAreLegalWidths() {
        for span in Span.allCases {
            #expect(span.width >= Preferences.minimumSidebarWidth)
            #expect(span.width <= Preferences.maximumSidebarWidth)
        }
    }

    /// The narrow rung is the narrowest the sidebar goes. 33% of 480 is 158.4,
    /// which the clamp lifts to the minimum — so this is an assertion about the
    /// clamp firing, not about arithmetic.
    @Test("the narrow rung is the minimum width")
    func narrowRungIsTheMinimum() {
        #expect(Span.third.width == Preferences.minimumSidebarWidth)
        #expect(Span.full.width == Preferences.maximumSidebarWidth)
    }

    @Test("cycling visits every rung and comes back")
    func cyclingWraps() {
        var span = Span.third
        var seen: [Span] = [span]
        for _ in 1..<Span.allCases.count {
            span = span.next
            seen.append(span)
        }
        #expect(Set(seen).count == Span.allCases.count, "a cycle that repeats a rung skips another")
        #expect(span.next == .third, "the last rung wraps to the first")
    }

    @Test("a dragged width reads as the rung it is closest to")
    func nearestRounds() {
        #expect(Span.nearest(to: Preferences.minimumSidebarWidth) == .third)
        #expect(Span.nearest(to: Preferences.maximumSidebarWidth) == .full)
        #expect(Span.nearest(to: Span.twoThirds.width) == .twoThirds)
        // One point under the widest is the widest, not the middle rung.
        #expect(Span.nearest(to: Preferences.maximumSidebarWidth - 1) == .full)
    }

    @Test("the label is the rung, in whole percent")
    func labelsReadAsPercentages() {
        #expect(Span.third.label == "33%")
        #expect(Span.twoThirds.label == "66%")
        #expect(Span.full.label == "100%")
    }
}
