// Settings, as a panel inside the window.
//
// # Two levels, not a list of everything
//
// A grid of categories that opens into one category, with a way back — the
// shape the old Deepin control center used, and the reason to copy it is that
// it fits a narrow column. A single scrolling list of every control is fine at
// 700pt of window width and unusable at 280pt of sidebar, which is what this
// is. The grid also means the first thing shown is a map, so nothing is found
// by scrolling past it.
//
// # Never a window
//
// No sheet, no separate window, no `NSColorPanel`. Every one of those takes key
// status from the terminal's window, and a terminal whose window is not key is
// a session that has stopped receiving what you type. See `SettingsControls`.
//
// # Live, with no save button
//
// Every change applies as it is made, so there is no moment at which the screen
// and the stored value disagree — which is the only thing a save button is for.

import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var preferences: Preferences

    @State private var category: Category?
    /// Which ANSI slot the palette editor is aimed at.
    @State private var editingAnsi: Int?

    enum Category: String, CaseIterable, Identifiable {
        case appearance, font, cursor, window, terminal

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .font: return "Font"
            case .cursor: return "Cursor"
            case .window: return "Window"
            case .terminal: return "Terminal"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "paintpalette"
            case .font: return "textformat"
            case .cursor: return "cursorarrow"
            case .window: return "macwindow"
            case .terminal: return "terminal"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let category {
                detailHeader(category)
                Divider()
                ScrollView {
                    detail(category)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            } else {
                grid
            }
        }
        .animation(.easeInOut(duration: 0.16), value: category)
    }

    // MARK: Level one

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                spacing: 8
            ) {
                ForEach(Category.allCases) { item in
                    QuietButton(action: { category = item }) {
                        VStack(spacing: 6) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 17, weight: .light))
                            Text(item.title)
                                .font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 66)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.secondary.opacity(0.10))
                        )
                        .foregroundStyle(.primary)
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: Level two

    private func detailHeader(_ category: Category) -> some View {
        HStack(spacing: 6) {
            QuietButton(action: { self.category = nil; editingAnsi = nil }) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                    Text("All").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(category.title)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func detail(_ category: Category) -> some View {
        switch category {
        case .appearance: appearanceDetail
        case .font: fontDetail
        case .cursor: cursorDetail
        case .window: windowDetail
        case .terminal: terminalDetail
        }
    }

    // MARK: Appearance

    private var appearanceDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingGroup(title: "Theme") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(TerminalTheme.builtins, id: \.name) { theme in
                        themeRow(theme)
                    }
                    if !settings.matchesNamedTheme {
                        Text("Edited — no preset matches these colours.")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
            }

            SettingGroup(title: "Colours") {
                SettingRow(label: "Background") {
                    ColorControl(
                        value: settings.appearance.background,
                        palette: paletteChoices,
                        onChange: { color in editing { $0.appearance.background = color } },
                        onCommit: state.focusTerminal
                    )
                }
                SettingRow(label: "Text") {
                    ColorControl(
                        value: settings.appearance.foreground,
                        palette: paletteChoices,
                        onChange: { color in editing { $0.appearance.foreground = color } },
                        onCommit: state.focusTerminal
                    )
                }
                SettingRow(label: "Cursor") {
                    ColorControl(
                        value: settings.appearance.cursorColor,
                        palette: paletteChoices,
                        onChange: { color in editing { $0.appearance.cursorColor = color } },
                        onCommit: state.focusTerminal
                    )
                }
            }

            SettingGroup(title: "ANSI palette") {
                AnsiPaletteGrid(
                    colors: settings.appearance.ansi,
                    selected: editingAnsi,
                    onSelect: { editingAnsi = editingAnsi == $0 ? nil : $0 }
                )
                if let index = editingAnsi, settings.appearance.ansi.indices.contains(index) {
                    SettingRow(label: "Slot \(index)") {
                        ColorControl(
                            value: settings.appearance.ansi[index],
                            palette: [],
                            onChange: { color in
                                editing { $0.appearance.ansi[index] = color }
                            },
                            onCommit: state.focusTerminal
                        )
                    }
                }
            }
        }
    }

    private func themeRow(_ theme: TerminalTheme) -> some View {
        let isSelected = settings.appearance.themeName == theme.name && settings.matchesNamedTheme
        return QuietButton(action: {
            preferences.terminal.apply(theme: theme)
            editingAnsi = nil
            applyAndReturnFocus()
        }) {
            HStack(spacing: 6) {
                HStack(spacing: 1) {
                    ForEach(Array(theme.ansi.prefix(8).enumerated()), id: \.offset) { _, color in
                        Rectangle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 5, height: 14)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                Text(theme.name).font(.system(size: 10))
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.08))
            )
            .foregroundStyle(.primary)
        }
    }

    /// One-click colours: the current palette, plus the background and
    /// foreground themselves, so "make the cursor the same as the text" is a
    /// click rather than a hex string.
    private var paletteChoices: [RGB] {
        var out = [settings.appearance.background, settings.appearance.foreground]
        out.append(contentsOf: settings.appearance.ansi.prefix(8))
        var seen = Set<RGB>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: Font

    private var fontDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingGroup(title: "Family") {
                SettingRow(
                    label: "Font",
                    hint: "Monospaced families only. A proportional font makes every box-drawing agent UI wrong."
                ) {
                    QuietMenu(
                        title: "Choose",
                        options: MonospacedFonts.available,
                        selection: settings.font.name,
                        onSelect: { name in editing { $0.font.name = name } },
                        onCommit: state.focusTerminal
                    )
                }
            }

            SettingGroup(title: "Metrics") {
                SettingRow(
                    label: "Size",
                    hint: "Changes the number of columns and rows. Programs running in every tab are told."
                ) {
                    QuietStepper(
                        value: Double(settings.font.size),
                        range: Self.sizeRange,
                        step: 1,
                        format: { String(format: "%.0f pt", $0) },
                        onChange: { size in editing { $0.font.size = CGFloat(size) } },
                        onCommit: state.focusTerminal
                    )
                }
                SettingRow(label: "Line spacing") {
                    QuietStepper(
                        value: Double(settings.font.lineSpacing),
                        range: Self.lineSpacingRange,
                        step: 0.05,
                        format: { String(format: "%.2f×", $0) },
                        onChange: { spacing in editing { $0.font.lineSpacing = CGFloat(spacing) } },
                        onCommit: state.focusTerminal
                    )
                }
            }
        }
    }

    // MARK: Cursor

    private var cursorDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingGroup(title: "Shape") {
                SettingRow(label: "Style") {
                    QuietSegmented(
                        options: TerminalSettings.CursorSettings.Shape.allCases
                            .map { ($0, $0.label) },
                        selection: settings.cursor.shape,
                        onSelect: { shape in editing { $0.cursor.shape = shape } },
                        onCommit: state.focusTerminal
                    )
                }
                SettingRow(label: "Blink") {
                    QuietToggle(
                        isOn: settings.cursor.blinks,
                        onChange: { blinks in editing { $0.cursor.blinks = blinks } },
                        onCommit: state.focusTerminal
                    )
                }
            }
            SettingGroup(title: "Colour") {
                SettingRow(label: "Cursor") {
                    ColorControl(
                        value: settings.appearance.cursorColor,
                        palette: paletteChoices,
                        onChange: { color in editing { $0.appearance.cursorColor = color } },
                        onCommit: state.focusTerminal
                    )
                }
            }
        }
    }

    // MARK: Window

    private var windowDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingGroup(title: "Translucency") {
                SettingRow(
                    label: "Opacity",
                    hint: "Below 100% the terminal's background lets what is behind the window through. Text stays fully opaque."
                ) {
                    QuietSlider(
                        value: settings.window.opacity,
                        range: TerminalSettings.WindowSettings.opacityRange,
                        format: { String(format: "%.0f%%", $0 * 100) },
                        onChange: { opacity in editing { $0.window.opacity = opacity } },
                        onCommit: state.focusTerminal
                    )
                }
                SettingRow(
                    label: "Blur",
                    hint: settings.window.isTranslucent
                        ? nil
                        : "No effect at 100% opacity."
                ) {
                    QuietToggle(
                        isOn: settings.window.blur,
                        onChange: { blur in editing { $0.window.blur = blur } },
                        onCommit: state.focusTerminal
                    )
                }
            }
        }
    }

    // MARK: Terminal

    private var terminalDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingGroup(title: "Scrollback") {
                SettingRow(label: "Lines") {
                    QuietMenu(
                        title: "Lines",
                        options: TerminalSettings.BehaviourSettings.scrollbackChoices
                            .map(String.init),
                        selection: String(settings.behaviour.scrollbackLines),
                        onSelect: { raw in
                            guard let lines = Int(raw) else { return }
                            editing { $0.behaviour.scrollbackLines = lines }
                        },
                        onCommit: state.focusTerminal
                    )
                }
            }

            SettingGroup(title: "Shell") {
                SettingRow(
                    label: "Default",
                    hint: "Applies to tabs opened from now on. A running shell cannot be swapped underneath its session."
                ) {
                    QuietMenu(
                        title: "System",
                        options: Self.shellChoices,
                        selection: settings.behaviour.shellOverride.isEmpty
                            ? "System (\(TerminalSession.userShell()))"
                            : settings.behaviour.shellOverride,
                        onSelect: { choice in
                            editing {
                                $0.behaviour.shellOverride = choice.hasPrefix("System") ? "" : choice
                            }
                        },
                        onCommit: state.focusTerminal
                    )
                }
            }

            SettingGroup(title: "Text") {
                SettingRow(label: "Wrap long lines") {
                    QuietToggle(
                        isOn: settings.behaviour.wrapLines,
                        onChange: { wrap in editing { $0.behaviour.wrapLines = wrap } },
                        onCommit: state.focusTerminal
                    )
                }
            }
        }
    }

    /// Shells worth offering, filtered to the ones actually installed. A menu
    /// that lists a shell this machine does not have is a menu with a broken
    /// entry in it.
    private static let shellChoices: [String] = {
        let candidates = ["/bin/zsh", "/bin/bash", "/bin/sh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/opt/homebrew/bin/nu"]
        return ["System (\(TerminalSession.userShell()))"]
            + candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// The bounds, widened to `Double` once. `ClosedRange<CGFloat>` and
    /// `ClosedRange<Double>` are different types and converting them inline
    /// reads as a range operator applied to a call, which is a parse error
    /// rather than the type error it looks like.
    private static let sizeRange: ClosedRange<Double> =
        Double(TerminalSettings.FontSettings.sizeRange.lowerBound)
            ... Double(TerminalSettings.FontSettings.sizeRange.upperBound)
    private static let lineSpacingRange: ClosedRange<Double> =
        Double(TerminalSettings.FontSettings.lineSpacingRange.lowerBound)
            ... Double(TerminalSettings.FontSettings.lineSpacingRange.upperBound)

    // MARK: Plumbing

    private var settings: TerminalSettings { preferences.terminal }

    /// Mutate, apply to every terminal, and give the keyboard back.
    ///
    /// One funnel, so no control can accidentally change a setting without
    /// pushing it to the terminals, and none can change one without returning
    /// focus.
    private func editing(_ change: (inout TerminalSettings) -> Void) {
        var next = preferences.terminal
        change(&next)
        // Any hand-edited colour stops claiming to be a preset. A theme row
        // that still shows a tick after its colours were changed is asserting
        // something about the screen that is not true.
        preferences.terminal = next
        if !preferences.terminal.matchesNamedTheme {
            preferences.terminal.appearance.themeName = nil
        }
        applyAndReturnFocus()
    }

    private func applyAndReturnFocus() {
        state.applyTerminalSettings()
        state.focusTerminal()
    }
}
