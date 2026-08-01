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
        static let compactionThreshold = "context.compaction.threshold"
        static let elsewhereExpanded = "sidebar.elsewhere.expanded"
        static let inspectorWidth = "inspector.width"
        static let inspectorVisible = "inspector.visible"
        static let terminalSettings = "terminal.settings"
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

    /// Fraction of the context window at which the gauge turns red.
    ///
    /// Matches `aiterm_transcript::DEFAULT_COMPACTION_THRESHOLD`. Kept as a
    /// preference rather than a constant because the useful value depends on
    /// how the user works — someone who compacts by hand wants warning earlier
    /// than someone who lets it happen.
    @Published var compactionThreshold: Double {
        didSet { defaults.set(compactionThreshold, forKey: Key.compactionThreshold) }
    }

    /// Whether the "elsewhere" section — sessions running outside aiterm — is
    /// open. Collapsed by default: they are real and worth showing, but they
    /// are not what this window is for, and they should not push the sessions
    /// you opened here off the screen.
    @Published var elsewhereExpanded: Bool {
        didSet { defaults.set(elsewhereExpanded, forKey: Key.elsewhereExpanded) }
    }

    /// The right sidebar. Its own width and its own visibility, stored under
    /// its own keys: the two sides are independent panels that happen to be
    /// symmetric, and sharing a width would mean opening one resizes the other.
    @Published var inspectorWidth: CGFloat {
        didSet { defaults.set(Double(inspectorWidth), forKey: Key.inspectorWidth) }
    }

    @Published var inspectorVisible: Bool {
        didSet { defaults.set(inspectorVisible, forKey: Key.inspectorVisible) }
    }

    /// How the terminal looks and behaves. Global for every tab in v0 — see
    /// `TerminalSettings` for why, and for what keeps that cheap to revisit.
    ///
    /// Written on every change, with no save button: the panel applies live, so
    /// there is no moment at which the screen and the stored value disagree and
    /// therefore no moment a save button would be for.
    @Published var terminal: TerminalSettings {
        didSet {
            guard terminal != oldValue else { return }
            persistTerminalSettings()
        }
    }

    /// Whatever the settings file carried that this build does not model, kept
    /// so saving cannot delete a newer build's fields.
    private var unknownTerminalKeys: [String: Any] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedWidth = defaults.object(forKey: Key.sidebarWidth) as? Double
        sidebarWidth = Self.clampWidth(CGFloat(storedWidth ?? 240))

        // `object(forKey:)` rather than `bool(forKey:)`: the latter cannot tell
        // "the user hid the sidebar" from "there is no preference yet", and the
        // default is visible.
        sidebarVisible = defaults.object(forKey: Key.sidebarVisible) as? Bool ?? true

        let legacyFontName = defaults.string(forKey: Key.fontName) ?? "SF Mono"
        let storedSize = defaults.object(forKey: Key.fontSize) as? Double
        let legacyFontSize = Self.clampFontSize(CGFloat(storedSize ?? 13))
        fontName = legacyFontName
        fontSize = legacyFontSize

        let storedThreshold = defaults.object(forKey: Key.compactionThreshold) as? Double
        compactionThreshold = min(max(storedThreshold ?? 0.85, 0.1), 1.0)

        elsewhereExpanded = defaults.object(forKey: Key.elsewhereExpanded) as? Bool ?? false

        let storedInspector = defaults.object(forKey: Key.inspectorWidth) as? Double
        inspectorWidth = Self.clampWidth(CGFloat(storedInspector ?? 280))
        // Hidden until asked for. The left sidebar is what the window is about;
        // this one is a tool you open, use and close.
        inspectorVisible = defaults.object(forKey: Key.inspectorVisible) as? Bool ?? false

        let storedSettings = defaults.dictionary(forKey: Key.terminalSettings) ?? [:]
        unknownTerminalKeys = storedSettings
        var loaded = TerminalSettings(json: storedSettings)

        // The font used to live in two flat keys. Adopt them once, so an
        // existing install does not silently reset to the default font the
        // first time it runs a build that has this panel.
        if storedSettings["font"] == nil {
            loaded.font.name = legacyFontName
            loaded.font.size = legacyFontSize
        }
        terminal = loaded

        // Keep the legacy flat keys in step: `⌘+` / `⌘-` and anything else
        // still reading them must not disagree with the panel. One source of
        // truth, two spellings, until the flat keys can be dropped.
        fontName = loaded.font.name
        fontSize = loaded.font.size
    }

    private func persistTerminalSettings() {
        let encoded = terminal.json(preserving: unknownTerminalKeys)
        unknownTerminalKeys = encoded
        defaults.set(encoded, forKey: Key.terminalSettings)
    }

    /// The font every terminal view uses.
    ///
    /// Falls back rather than failing: a font name that was valid when it was
    /// written can stop resolving, and a terminal with no font is not a state
    /// worth supporting.
    var terminalFont: NSFont {
        MonospacedFonts.font(named: terminal.font.name, size: terminal.font.size)
    }

    func adjustFontSize(by delta: CGFloat) {
        let next = Self.clampFontSize(terminal.font.size + delta)
        terminal.font.size = next
        fontSize = next
    }

    func setInspectorWidth(_ width: CGFloat) {
        inspectorWidth = Self.clampWidth(width)
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
