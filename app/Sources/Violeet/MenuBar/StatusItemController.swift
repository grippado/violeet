// The menu bar extra: what is running, visible without the app in front.
//
// # Why this exists
//
// The whole product is "notice that an agent is blocked on you while you are
// doing something else". The sidebar answers that only while you are looking at
// violeet — which is precisely when you did not need answering. The status item
// is the same answer in the one place macOS guarantees is on screen whatever
// app is in front.
//
// # Built on demand, never cached
//
// The menu is assembled in `menuNeedsUpdate(_:)` and nowhere else. Sessions
// appear, change state and end continuously; a menu built once at launch and
// mutated afterwards is a menu that is wrong in the interval between the change
// and whoever remembered to update it. Assembling it at the moment it opens
// costs microseconds for a list this size and cannot go stale by construction.
//
// The *icon* is the opposite case and is updated eagerly: it has to be right
// while nobody is looking at it, which is the whole point.
//
// # What is listed
//
// Tabs of this window first, then sessions the daemon knows about that are not
// tabs of this window. Tabs rather than local *sessions*, deliberately: a tab
// with no agent in it is still somewhere you can go, and a window with two
// shell tabs would otherwise offer an empty menu while plainly having two tabs.
//
// The second section is inert. Focusing a session running in iTerm means asking
// its terminal to raise itself and select the right tab, and neither the
// protocol nor the daemon carries what that would need — origin resolution
// stops at "which app, which tty". An item that looks clickable and does
// nothing teaches the user the menu is broken; a disabled item with a tooltip
// saying why teaches them what the app currently knows.

import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let state: AppState
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    /// What the icon last rendered. Compared before touching the button so a
    /// state change that does not affect the icon — a token count ticking up,
    /// which happens several times a second — does not redraw the menu bar.
    private var renderedAttention: Int?

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        // Autoenabling would ask a validator about every item on every open, and
        // this menu decides enablement itself — the elsewhere rows are disabled
        // on purpose and must stay that way.
        menu.autoenablesItems = false
        statusItem.menu = menu

        statusItem.button?.setAccessibilityLabel("violeet sessions")

        // The icon tracks state without the menu ever being opened. That is the
        // requirement, not a refinement: the user is in another app.
        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIcon() }
            .store(in: &cancellables)

        refreshIcon(force: true)
    }

    deinit {
        // Captured before the closure so `deinit` does not touch main-actor
        // state; removing the item is what keeps a stale icon from being left
        // in the menu bar if the controller is ever torn down.
        let item = statusItem
        Task { @MainActor in NSStatusBar.system.removeStatusItem(item) }
    }

    // MARK: - The icon

    /// Sessions blocked on a human decision, wherever they are running.
    ///
    /// Counted across both sections: an agent waiting in iTerm is exactly as
    /// blocked as one waiting in a tab here, and the icon is the only surface
    /// that can say so while violeet is not in front.
    private var waitingCount: Int {
        state.sessions.values.count { $0.lifecycle == .waitingForYou }
    }

    /// The Violeeter mark, sized for the menu bar. Loaded once.
    ///
    /// A PDF and not a PNG: `NSImage` scales vector art without resampling, so
    /// one file is right on every display instead of an @1x/@2x/@3x set that is
    /// still soft on the next one. The size below is in **points** — setting it
    /// is what makes the vector render at menu bar height rather than at the
    /// 858×992 the artboard happens to be.
    ///
    /// 16pt tall, which is what the system's own menu bar symbols occupy inside
    /// a 22pt bar. The width follows the artwork's proportion rather than being
    /// chosen, so the glyph cannot be subtly stretched.
    ///
    /// `isTemplate` is the whole reason this works in both appearances: macOS
    /// throws the colour away and redraws the shape in whatever the bar needs,
    /// including the inverted state while the menu is open. Artwork that
    /// carried its own colour would be a white mark on a white bar in light
    /// mode.
    ///
    /// `nil` when the bundle has no artwork — a dev build run straight from
    /// `swift run` has no `Contents/Resources`. The caller falls back to the
    /// old symbol rather than showing nothing.
    private static let markImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "violeet-menubar", withExtension: "pdf"),
              let image = NSImage(contentsOf: url)
        else { return nil }

        let height: CGFloat = 16
        let aspect = image.size.width / max(image.size.height, 1)
        image.size = NSSize(width: (height * aspect).rounded(), height: height)
        image.isTemplate = true
        return image
    }()

    private func refreshIcon(force: Bool = false) {
        let waiting = waitingCount
        guard force || waiting != renderedAttention else { return }
        renderedAttention = waiting

        guard let button = statusItem.button else { return }

        let description = waiting > 0
            ? "violeet — \(waiting) waiting for you"
            : "violeet"

        // The mark, not a stock terminal glyph. `terminal` is the symbol every
        // terminal in the menu bar uses, which made this one unfindable in a
        // row of them — an icon whose job is to be spotted while the app is not
        // in front cannot be the same shape as its neighbours.
        //
        // Two channels are still two channels. They used to be shape
        // (outline → filled) and tint; they are now the count and the tint.
        // That is a straight upgrade rather than a concession: "something is
        // waiting" and "four things are waiting" are different decisions about
        // whether to switch apps now, and a digit says which without relying on
        // the amber being distinguishable.
        let image = Self.markImage ?? NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: description
        )
        image?.accessibilityDescription = description
        button.image = image
        button.imagePosition = waiting > 0 ? .imageLeading : .imageOnly
        // The count, because "something is waiting" and "four things are
        // waiting" are different decisions about whether to switch apps now.
        button.title = waiting > 0 ? " \(waiting)" : ""
        button.contentTintColor = waiting > 0 ? NSColor(CardTheme.attention) : nil
        button.toolTip = description
    }

    // MARK: - Building the menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let tabs = state.tabs
        let elsewhere = state.elsewhereSessions

        if tabs.isEmpty && elsewhere.isEmpty {
            // Never a blank menu. A menu that opens onto nothing reads as a
            // broken app; "no sessions" reads as an idle one.
            menu.addItem(disabledRow("No sessions"))
        }

        if !tabs.isEmpty {
            menu.addItem(sectionHeader("In this window"))
            for tab in tabs {
                menu.addItem(tabItem(for: tab))
            }
        }

        if !elsewhere.isEmpty {
            if !tabs.isEmpty { menu.addItem(.separator()) }
            menu.addItem(sectionHeader("Elsewhere"))
            for card in elsewhere {
                menu.addItem(elsewhereItem(for: card))
            }
        }

        menu.addItem(.separator())
        menu.addItem(footerRow())
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open violeet", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit violeet", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    /// A row for a tab of this window. Always actionable — the tab exists here,
    /// so selecting it is something this process can actually do.
    private func tabItem(for tab: TabModel) -> NSMenuItem {
        let card = state.session(ofTab: tab.tabID)
        let title = card.map { state.displayTitle(for: $0) } ?? state.name(for: tab).text
        let lifecycle = card?.lifecycle
        let agent = card?.agent

        let item = NSMenuItem(title: title, action: #selector(selectTab(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = tab.tabID
        item.attributedTitle = rowTitle(title, detail: lifecycle?.label, waiting: lifecycle == .waitingForYou)
        item.image = swatch(for: agent)
        item.state = tab.tabID == state.selectedTabID ? .on : .off
        item.toolTip = tab.currentDirectory
        return item
    }

    /// A row for a session the daemon knows about that is not a tab here.
    ///
    /// Disabled, and the tooltip says why. See the file comment.
    private func elsewhereItem(for card: SessionCard) -> NSMenuItem {
        let title = state.displayTitle(for: card)
        let waiting = card.lifecycle == .waitingForYou
        let detail = [card.lifecycle.label, card.originLabel]
            .compactMap { $0 }
            .joined(separator: " · ")

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = rowTitle(title, detail: detail, waiting: waiting, dimmed: true)
        item.image = swatch(for: card.agent, dimmed: true)
        item.toolTip = card.originApp.map {
            "Running in \($0). violeet cannot focus it yet — it did not start this session."
        } ?? "violeet did not start this session and cannot focus it."
        return item
    }

    /// `name — detail`, with the detail lit when the session is blocked on you.
    ///
    /// A colour and not only a word: this menu is read at a glance, and the one
    /// row that needs finding has to be findable before the list is read.
    private func rowTitle(
        _ name: String,
        detail: String?,
        waiting: Bool,
        dimmed: Bool = false
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: dimmed ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
        )
        guard let detail, !detail.isEmpty else { return text }
        text.append(NSAttributedString(
            string: "  \(detail)",
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: waiting ? NSColor(CardTheme.attention) : NSColor.secondaryLabelColor,
            ]
        ))
        return text
    }

    /// The tool's colour as a small dot, matching the card border in the
    /// sidebar. Discreet on purpose: it is a second way to recognise a row you
    /// already know, not a label.
    private func swatch(for agent: String?, dimmed: Bool = false) -> NSImage {
        let side: CGFloat = 10
        let color = NSColor(agent.map { CardTheme.toolColor(for: $0) } ?? CardTheme.toolColor(for: "unknown"))
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            (dimmed ? color.withAlphaComponent(0.45) : color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        // Not a template: the whole point is the colour.
        image.isTemplate = false
        return image
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
        return item
    }

    private func disabledRow(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Count and daemon state, said the way the sidebar says them.
    private func footerRow() -> NSMenuItem {
        let count = state.sessions.count
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        return disabledRow("\(sessions) · \(state.daemon.status.shortLabel)")
    }

    // MARK: - Actions

    @objc private func selectTab(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? String else { return }
        state.select(tab: tabID)
        bringForward()
    }

    @objc private func openApp() {
        bringForward()
        state.focusTerminal()
    }

    @objc private func openSettings() {
        bringForward()
        if !state.preferences.inspectorVisible {
            state.toggleInspector()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Activate the app and get the window actually on screen.
    ///
    /// Three separate things, and each covers a case the others do not.
    /// `activate` alone leaves a minimised window minimised; `deminiaturize`
    /// alone raises a window belonging to a background app; and a window on
    /// another Space is only reached because `makeKeyAndOrderFront` on an
    /// active app is what makes the system switch Spaces to it.
    private func bringForward() {
        NSApp.activate()
        guard let window = mainWindow else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// The one window this app has. Found by autosave name rather than by
    /// `NSApp.mainWindow`, which is `nil` while the app is in the background —
    /// exactly the state every path into this file starts from.
    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.frameAutosaveName == "violeet.main" }
            ?? NSApp.windows.first { $0.canBecomeMain }
    }
}
