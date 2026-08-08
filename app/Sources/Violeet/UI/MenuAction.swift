// An `NSMenuItem` that runs a closure.
//
// AppKit menu items call a selector on a target, which is a fine design for a
// menu owned by a controller and a poor one for a menu built inside a SwiftUI
// view: there is no long-lived object to be the target, and the obvious
// workaround is a controller invented solely to hold three selectors.
//
// So the item is its own target, and holds the closure. It stays alive because
// the menu retains its items and the menu is retained while it is up.

import AppKit

final class MenuAction: NSMenuItem {
    private let run: () -> Void

    private init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not from a nib")
    }

    /// A menu item that calls `run` when chosen.
    static func item(_ title: String, run: @escaping () -> Void) -> NSMenuItem {
        MenuAction(title: title, run: run)
    }

    @objc private func fire() {
        run()
    }
}
