// What the Tab menu should show, given how many tabs are open.
//
// Split out of the menu declaration so the rule can be tested without a window
// or a menu bar. The rule itself is small and the reason for it is not: a menu
// listing "Tab 7" when six tabs exist teaches the shortcut and then breaks the
// promise, and the item cannot be `.disabled` into honesty — a disabled item
// stops firing its key equivalent, and SwiftUI evaluates `disabled` against a
// snapshot that latches (the same trap recorded on ⌘W in App.swift). So the
// entries themselves come and go.

import SwiftUI

/// One item in the Tab menu.
struct TabMenuEntry: Identifiable {
    /// The argument for `AppState.selectTab(number:)`. 9 means "the last one".
    let number: Int
    let title: String

    var id: Int { number }

    var shortcut: KeyEquivalent { KeyEquivalent(Character("\(number)")) }

    /// The entries for `count` open tabs.
    ///
    /// ⌘1…⌘8 are positional and exist only while the tab behind them does. ⌘9
    /// is "the last tab" and appears from the ninth onwards — below that it
    /// would be a second name for a tab that already has a number, and the menu
    /// would list the same tab twice.
    static func entries(count: Int) -> [TabMenuEntry] {
        guard count > 0 else { return [] }
        var entries = (1...min(count, 8)).map {
            TabMenuEntry(number: $0, title: "Tab \($0)")
        }
        if count > 8 {
            entries.append(TabMenuEntry(number: 9, title: "Last Tab"))
        }
        return entries
    }
}
