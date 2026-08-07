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
