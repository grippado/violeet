// The Tab menu's contents, against a tab count.
//
// The bug being pinned: the menu was a literal 1…9 and listed eight tabs that
// did not exist beside the one that did.

import Foundation
import Testing

@testable import AITerm

@Test("no tabs, no entries")
func emptyMenu() {
    #expect(TabMenuEntry.entries(count: 0).isEmpty)
    // Not a real state, but the range arithmetic below would trap on it.
    #expect(TabMenuEntry.entries(count: -1).isEmpty)
}

@Test("one entry per open tab, and not one more")
func entriesMatchTabs() {
    let entries = TabMenuEntry.entries(count: 3)
    #expect(entries.map(\.title) == ["Tab 1", "Tab 2", "Tab 3"])
    #expect(entries.map(\.number) == [1, 2, 3])
}

@Test("no Last Tab while every tab already has a number")
func noLastTabBelowNine() {
    for count in 1...8 {
        let entries = TabMenuEntry.entries(count: count)
        #expect(entries.count == count)
        #expect(!entries.contains { $0.title == "Last Tab" })
    }
}

@Test("Last Tab appears from the ninth tab on")
func lastTabFromNine() {
    for count in [9, 12] {
        let entries = TabMenuEntry.entries(count: count)
        // Eight positional entries, then ⌘9.
        #expect(entries.count == 9)
        #expect(entries.last?.title == "Last Tab")
        #expect(entries.last?.number == 9)
    }
}
