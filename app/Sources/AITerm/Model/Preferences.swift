// The little that survives a relaunch.
//
// Scope is the point here: window frame, sidebar width and collapse, font. Not
// tabs, not scrollback, not the daemon's view of the world. A terminal that
// restored tabs would have to restore *processes*, and a tab whose shell is
// gone is a lie about state the user can act on. So the app opens with exactly
// one fresh tab, every time, and only the chrome remembers anything.
//
// The window frame is not here because AppKit already persists it, keyed by an
// autosave name — see `WindowConfigurator`. Reimplementing that in
// `UserDefaults` would be a second source of truth for the same rectangle.

import AppKit
import Foundation

final class Preferences: ObservableObject {
    private enum Key {
        static let sidebarWidth = "sidebar.width"
        static let sidebarVisible = "sidebar.visible"
        static let fontName = "terminal.font.name"
        static let fontSize = "terminal.font.size"
    }

    /// Bounds for the drag handle. The lower one is where the cwd column stops
    /// being readable; the upper one keeps the terminal from being squeezed
    /// into a shape no agent's output survives.
    static let minimumSidebarWidth: CGFloat = 160
    static let maximumSidebarWidth: CGFloat = 480

    static let minimumFontSize: CGFloat = 8
    static let maximumFontSize: CGFloat = 32

    private let defaults: UserDefaults

    @Published var sidebarWidth: CGFloat {
        didSet { defaults.set(Double(sidebarWidth), forKey: Key.sidebarWidth) }
    }

    @Published var sidebarVisible: Bool {
        didSet { defaults.set(sidebarVisible, forKey: Key.sidebarVisible) }
    }

    @Published var fontName: String {
        didSet { defaults.set(fontName, forKey: Key.fontName) }
    }

    @Published var fontSize: CGFloat {
        didSet { defaults.set(Double(fontSize), forKey: Key.fontSize) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedWidth = defaults.object(forKey: Key.sidebarWidth) as? Double
        sidebarWidth = Self.clampWidth(CGFloat(storedWidth ?? 240))

        // `object(forKey:)` rather than `bool(forKey:)`: the latter cannot tell
        // "the user hid the sidebar" from "there is no preference yet", and the
        // default is visible.
        sidebarVisible = defaults.object(forKey: Key.sidebarVisible) as? Bool ?? true

        fontName = defaults.string(forKey: Key.fontName) ?? "SF Mono"
        let storedSize = defaults.object(forKey: Key.fontSize) as? Double
        fontSize = Self.clampFontSize(CGFloat(storedSize ?? 13))
    }

    /// The font every terminal view uses.
    ///
    /// Falls back rather than failing: a font name that was valid when it was
    /// written can stop resolving, and a terminal with no font is not a state
    /// worth supporting.
    var terminalFont: NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    func adjustFontSize(by delta: CGFloat) {
        fontSize = Self.clampFontSize(fontSize + delta)
    }

    func setSidebarWidth(_ width: CGFloat) {
        sidebarWidth = Self.clampWidth(width)
    }

    private static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumSidebarWidth), maximumSidebarWidth)
    }

    private static func clampFontSize(_ size: CGFloat) -> CGFloat {
        min(max(size, minimumFontSize), maximumFontSize)
    }
}
