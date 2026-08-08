// Settings, as a panel inside the window.
//
// # Collapsible sections, not a grid and a detail page
//
// This started as a two-level grid → detail → back, which is a good shape for a
// wide control panel and a poor one for a 280pt column: every visit costs two
// clicks, and only one category can be on screen, so checking what the cursor
// is set to while looking at the font means navigating twice.
//
// Stacked collapsible sections, in the same idiom as the sidebar's ELSEWHERE
// bar, cost one click, stay how you left them, and let two categories be
// visible at once. The trade is a longer scroll with everything open, which is
// why they start collapsed except the first — and why a collapsed header shows
// its current value rather than only its name.
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

    /// Which sections are open. Appearance starts open because it is what
    /// people come here for; the rest cost no height until asked for.
    @State private var expanded: Set<Section> = [.appearance]
    /// Which ANSI colour the editor below the grid is aimed at.
    @State private var editingAnsi: Int?

    enum Section: String, CaseIterable, Identifiable {
        case appearance, palette, font, cursor, window, terminal, editor

        var id: String { rawValue }

        var title: String {
            switch self {
            case .appearance: return "APPEARANCE"
            case .palette: return "ANSI PALETTE"
            case .font: return "FONT"
            case .cursor: return "CURSOR"
            case .window: return "WINDOW"
            case .terminal: return "TERMINAL"
            case .editor: return "EDITOR"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Section.allCases) { section in
                    DisclosureSection(
                        title: section.title,
                        summary: summary(for: section),
                        isExpanded: expanded.contains(section),
                        toggle: { toggle(section) }
                    ) {
                        body(of: section)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .animation(.easeInOut(duration: 0.16), value: expanded)
    }

    private func toggle(_ section: Section) {
        if expanded.contains(section) {
            expanded.remove(section)
        } else {
            expanded.insert(section)
        }
        if section != .palette { editingAnsi = nil }
        state.focusTerminal()
    }

    /// What a collapsed section says about itself.
    ///
    /// Six closed headers carrying nothing but names is a menu you have to open
    /// to read. The current value on the right is most of why collapsing is
    /// acceptable at all.
    private func summary(for section: Section) -> String {
        switch section {
        case .appearance:
            return settings.appearance.themeName ?? "custom"
        case .palette:
            return "16 colours"
        case .font:
            return "\(settings.font.name) \(Int(settings.font.size))"
        case .cursor:
            return settings.cursor.shape.label.lowercased()
                + (settings.cursor.blinks ? ", blinking" : "")
        case .window:
            let opacity = settings.window.isTranslucent
                ? String(format: "%.0f%%", settings.window.opacity * 100)
                : "opaque"
            return "\(opacity), \(Int(settings.window.interfaceFontSize)) pt"
        case .terminal:
            return "\(settings.behaviour.scrollbackLines / 1000)k lines"
        case .editor:
            return settings.editor.diffMode.label.lowercased()
        }
    }

    @ViewBuilder
    private func body(of section: Section) -> some View {
        switch section {
        case .appearance: appearanceSection
        case .palette: paletteSection
        case .font: fontSection
        case .cursor: cursorSection
        case .window: windowSection
        case .terminal: terminalSection
        case .editor: editorSection
        }
    }

    // MARK: Appearance

    /// The theme list, and the two ways into a text editor.
    ///
    /// # What was removed and why
    ///
    /// Three colour editors — background, text, cursor — used to sit under this
    /// list and take more height than everything else in Settings combined.
    /// They were also the wrong instrument. A palette is twenty colours judged
    /// *against each other*, and three of them edited one at a time down a 280pt
    /// column is the one way that judgement cannot be made. The file below shows
    /// all twenty at once. See `ThemeFile`.
    ///
    /// The ANSI palette section is untouched: sixteen swatches in a grid is a
    /// picker, not three round trips, and it is useful for changing exactly one
    /// colour without opening anything.
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(TerminalTheme.builtins, id: \.name) { theme in
                    themeRow(theme)
                }
                ForEach(state.themes.custom) { entry in
                    customThemeRow(entry)
                }
            }

            if let error = state.themes.lastError {
                themeErrorRow(error)
            }

            VStack(alignment: .leading, spacing: 4) {
                themeAction("Edit current theme", symbol: "pencil") {
                    openTheme(state.themes.fileForCurrentTheme())
                }
                themeAction("Create your own theme", symbol: "plus.square.on.square") {
                    openTheme(state.themes.createTheme())
                }
                Text("Opens in your editor, in a new tab. Saving applies it straight away.")
                    .appFont(.small)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
    }

    /// Open a theme file in the editor, in a tab of its own.
    ///
    /// The same `openInEditor` the Files panel uses, so a theme opens with
    /// whatever `$VISUAL` or `$EDITOR` says and lands beside the terminal it is
    /// about — which is the point. Editing colours in a window that covers the
    /// output you are matching them to is editing them blind.
    private func openTheme(_ path: String?) {
        guard let path else { return }
        state.openInEditor(path: path, session: nil)
        state.focusTerminal()
    }

    private func themeAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        QuietButton(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).appFont(.caption)
                Text(title).appFont(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.14))
            )
            .contentShape(Rectangle())
        }
    }

    /// What is wrong with the file being edited.
    ///
    /// Stated here and not only in a log, because the reader is in an editor two
    /// panes away and an error they cannot see is one they will discover by
    /// wondering why saving did nothing. The colours on screen are untouched
    /// while this shows: see `ThemeStore` on why a broken file is the normal
    /// state of a file being edited.
    private func themeErrorRow(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .appFont(.caption)
            Text(message)
                .appFont(.small)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.12)))
    }

    private func themeRow(_ theme: TerminalTheme) -> some View {
        // A built-in is selected only when no file is driving the colours: a
        // custom theme copied out of Dracula has Dracula's palette on the day it
        // is made, and ticking the built-in would say the file is not in use
        // when it is.
        let isSelected = settings.appearance.themeFile == nil
            && settings.appearance.themeName == theme.name
            && settings.matchesNamedTheme
        return themeRowBody(name: theme.name, swatches: theme.ansi, isSelected: isSelected) {
            preferences.terminal.apply(theme: theme)
            // The file stops being the source, so it stops being watched —
            // otherwise saving it later would silently pull the terminal off the
            // built-in the user just chose.
            state.themes.stopWatching()
            editingAnsi = nil
            applyAndReturnFocus()
        }
    }

    /// A theme from `~/.violeet/themes`.
    ///
    /// Listed beside the built-ins rather than in a section of its own. They are
    /// the same kind of thing to the person choosing one, and the only asymmetry
    /// — that these can be edited — is what the buttons below are for.
    private func customThemeRow(_ entry: ThemeStore.Entry) -> some View {
        let isSelected = settings.appearance.themeFile == entry.path
        // Read from disk for the swatches, because the row is showing what the
        // file says rather than what is in use. The alternative is a row that
        // draws the current palette for every theme in the list.
        let swatches = previewSwatches(for: entry, isSelected: isSelected)
        return themeRowBody(name: entry.name, swatches: swatches, isSelected: isSelected) {
            state.themes.apply(path: entry.path)
            editingAnsi = nil
            applyAndReturnFocus()
        }
    }

    private func previewSwatches(for entry: ThemeStore.Entry, isSelected: Bool) -> [RGB] {
        if isSelected { return settings.appearance.ansi }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: entry.path)),
              case .success(let theme) = ThemeFile.parse(data, fallbackName: entry.name)
        else {
            // A theme that will not parse still gets a row, because the row is
            // how you get back to it after fixing it. It simply has nothing to
            // preview.
            return []
        }
        return theme.ansi
    }

    private func themeRowBody(
        name: String,
        swatches: [RGB],
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        QuietButton(action: action) {
            HStack(spacing: 7) {
                HStack(spacing: 1) {
                    ForEach(Array(swatches.prefix(8).enumerated()), id: \.offset) { _, color in
                        Rectangle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 5, height: 13)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                // Held at the width eight swatches occupy, so a theme with no
                // preview does not shunt its own name left out of the column.
                .frame(width: 47, alignment: .leading)
                Text(name)
                    .appFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark").appFont(.small, weight: .bold)
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

    // MARK: ANSI palette

    /// The sixteen colours, each editable in place.
    ///
    /// The first version made you click a swatch, then find an unlabelled
    /// editor that had appeared somewhere below, and work out for yourself that
    /// "Slot 11" meant bright yellow. Now the swatch names itself and its
    /// editor opens directly under the row it belongs to.
    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ansiRow(offset: 0, label: "Normal")
            ansiRow(offset: 8, label: "Bright")

            if let index = editingAnsi, settings.appearance.ansi.indices.contains(index) {
                ColorField(
                    label: Self.ansiName(index),
                    value: settings.appearance.ansi[index],
                    choices: [],
                    onChange: { color in editing { $0.appearance.ansi[index] = color } },
                    onCommit: state.focusTerminal
                )
                .padding(.top, 2)
            } else {
                Text("Click a colour to edit it.")
                    .appFont(.small)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func ansiRow(offset: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .appFont(.small)
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                ForEach(0..<8, id: \.self) { i in
                    let index = offset + i
                    Swatch(
                        color: settings.appearance.ansi.indices.contains(index)
                            ? settings.appearance.ansi[index]
                            : RGB(0, 0, 0),
                        isSelected: editingAnsi == index,
                        size: 20
                    ) {
                        editingAnsi = editingAnsi == index ? nil : index
                        state.focusTerminal()
                    }
                    .help(Self.ansiName(index))
                }
            }
        }
    }

    private static let ansiNames = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    ]

    /// `11` → `Bright yellow`. A number is not a colour, and the first version
    /// asked people to translate one into the other.
    static func ansiName(_ index: Int) -> String {
        let prefix = index < 8 ? "Normal" : "Bright"
        return "\(prefix) \(ansiNames[index % 8])"
    }

    // MARK: Font

    private var fontSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(
                label: "Family",
                hint: "Monospaced only. A proportional font makes every box-drawing agent UI wrong."
            ) {
                QuietMenu(
                    title: "Choose",
                    options: MonospacedFonts.available,
                    selection: settings.font.name,
                    onSelect: { name in editing { $0.font.name = name } },
                    onCommit: state.focusTerminal
                )
            }
            SettingRow(
                label: "Size",
                hint: "Changes how many columns and rows fit. Every tab's program is told."
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
            SettingRow(
                label: "Padding",
                hint: "Space between the text and the edges of the pane. Costs columns and rows, and every tab's program is told."
            ) {
                QuietStepper(
                    value: Double(settings.padding.horizontal),
                    range: Self.paddingRange,
                    step: 2,
                    format: { String(format: "%.0f ↔", $0) },
                    onChange: { value in editing { $0.padding.horizontal = CGFloat(value) } },
                    onCommit: state.focusTerminal
                )
            }
            SettingRow(label: "Vertical padding") {
                QuietStepper(
                    value: Double(settings.padding.vertical),
                    range: Self.paddingRange,
                    step: 2,
                    format: { String(format: "%.0f ↕", $0) },
                    onChange: { value in editing { $0.padding.vertical = CGFloat(value) } },
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

    // MARK: Cursor

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingRow(label: "Shape") {
                QuietSegmented(
                    options: TerminalSettings.CursorSettings.Shape.allCases.map { ($0, $0.label) },
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
            ColorField(
                label: "Colour",
                value: settings.appearance.cursorColor,
                choices: themeChoices,
                onChange: { color in editing { $0.appearance.cursorColor = color } },
                onCommit: state.focusTerminal
            )
        }
    }

    // MARK: Window

    private var windowSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Above opacity, because it is the one setting here somebody may
            // need before they can comfortably read the rest of this panel.
            SettingRow(
                label: "Text size",
                hint: "The window's own text: this panel, the sidebar, menus. The FONT section above is the terminal's, and ⌘+ / ⌘- move that one."
            ) {
                QuietStepper(
                    value: Double(settings.window.interfaceFontSize),
                    range: Self.interfaceFontSizeRange,
                    step: 1,
                    format: { String(format: "%.0f pt", $0) },
                    onChange: { size in editing { $0.window.interfaceFontSize = CGFloat(size) } },
                    onCommit: state.focusTerminal
                )
            }
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
                hint: settings.window.isTranslucent ? nil : "No effect at 100% opacity."
            ) {
                QuietToggle(
                    isOn: settings.window.blur,
                    onChange: { blur in editing { $0.window.blur = blur } },
                    onCommit: state.focusTerminal
                )
            }
        }
    }

    // MARK: Terminal

    private var terminalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(label: "Scrollback") {
                QuietMenu(
                    title: "Lines",
                    options: TerminalSettings.BehaviourSettings.scrollbackChoices.map(String.init),
                    selection: String(settings.behaviour.scrollbackLines),
                    onSelect: { raw in
                        guard let lines = Int(raw) else { return }
                        editing { $0.behaviour.scrollbackLines = lines }
                    },
                    onCommit: state.focusTerminal
                )
            }
            SettingRow(
                label: "Shell",
                hint: "Applies to tabs opened from now on. A running shell cannot be swapped underneath its session."
            ) {
                QuietMenu(
                    title: "System",
                    options: Self.shellChoices,
                    selection: settings.behaviour.shellOverride.isEmpty
                        ? "System"
                        : settings.behaviour.shellOverride,
                    onSelect: { choice in
                        editing {
                            $0.behaviour.shellOverride = choice.hasPrefix("System") ? "" : choice
                        }
                    },
                    onCommit: state.focusTerminal
                )
            }
            SettingRow(label: "Wrap long lines") {
                QuietToggle(
                    isOn: settings.behaviour.wrapLines,
                    onChange: { wrap in editing { $0.behaviour.wrapLines = wrap } },
                    onCommit: state.focusTerminal
                )
            }
        }
    }

    // MARK: Editor

    /// What happens in the tab the Files panel opens.
    ///
    /// Its own section rather than two more rows under TERMINAL, because these
    /// configure a program this app launches and everything there configures
    /// the terminal this app draws.
    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(
                label: "Diff",
                hint: "\(settings.editor.diffMode.detail) Only vim and Neovim; a new file opens plain either way, having nothing to compare against."
            ) {
                QuietMenu(
                    title: "Diff",
                    options: TerminalSettings.EditorSettings.DiffMode.allCases.map(\.label),
                    selection: settings.editor.diffMode.label,
                    onSelect: { label in
                        guard let mode = TerminalSettings.EditorSettings.DiffMode.allCases
                            .first(where: { $0.label == label }) else { return }
                        editing { $0.editor.diffMode = mode }
                    },
                    onCommit: state.focusTerminal
                )
            }
            SettingRow(
                label: "Minimap",
                hint: "Needs a minimap plugin in your Neovim config — mini.map. Violeet switches it on when it is there and stays quiet when it is not."
            ) {
                QuietToggle(
                    isOn: settings.editor.showMinimap,
                    onChange: { on in editing { $0.editor.showMinimap = on } },
                    onCommit: state.focusTerminal
                )
            }
        }
    }

    /// Shells worth offering, filtered to the ones actually installed. A menu
    /// listing a shell this machine does not have is a menu with a broken entry.
    private static let shellChoices: [String] = {
        let candidates = [
            "/bin/zsh", "/bin/bash", "/bin/sh",
            "/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/opt/homebrew/bin/nu",
        ]
        return ["System (\(TerminalSession.userShell()))"]
            + candidates.filter { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    // MARK: Plumbing

    private var settings: TerminalSettings { preferences.terminal }

    /// One-click colours offered beside every colour field: the theme's own
    /// eight, plus the current background and text.
    private var themeChoices: [RGB] {
        var out = [settings.appearance.background, settings.appearance.foreground]
        out.append(contentsOf: settings.appearance.ansi.prefix(8))
        var seen = Set<RGB>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The bounds, widened to `Double` once. `ClosedRange<CGFloat>` and
    /// `ClosedRange<Double>` are different types, and converting them inline
    /// parses as a range operator applied to a call.
    private static let sizeRange: ClosedRange<Double> =
        Double(TerminalSettings.FontSettings.sizeRange.lowerBound)
            ... Double(TerminalSettings.FontSettings.sizeRange.upperBound)
    private static let paddingRange: ClosedRange<Double> =
        Double(TerminalSettings.PaddingSettings.range.lowerBound)
            ... Double(TerminalSettings.PaddingSettings.range.upperBound)
    private static let lineSpacingRange: ClosedRange<Double> =
        Double(TerminalSettings.FontSettings.lineSpacingRange.lowerBound)
            ... Double(TerminalSettings.FontSettings.lineSpacingRange.upperBound)
    private static let interfaceFontSizeRange: ClosedRange<Double> =
        Double(TerminalSettings.WindowSettings.interfaceFontSizeRange.lowerBound)
            ... Double(TerminalSettings.WindowSettings.interfaceFontSizeRange.upperBound)

    /// Mutate, apply to every terminal, and give the keyboard back.
    ///
    /// One funnel, so no control can change a setting without pushing it to the
    /// terminals, and none can change one without returning focus.
    private func editing(_ change: (inout TerminalSettings) -> Void) {
        let before = preferences.terminal.palette

        var next = preferences.terminal
        change(&next)
        preferences.terminal = next

        // A hand-edited colour stops claiming to be a preset: a theme row still
        // showing a tick after its colours changed asserts something about the
        // screen that is not true.
        //
        // The test is whether *the palette moved*, and it used to be whether the
        // palette still matched a built-in. Those are the same question only
        // while every theme is a built-in. With themes in files they diverge and
        // the old test was wrong in the worst direction: it is false for every
        // custom theme, so changing the font size — a setting with no colour in
        // it — threw away the theme's name and the path the app was watching,
        // and the live-reload loop went quiet for no visible reason.
        if preferences.terminal.palette != before {
            preferences.terminal.appearance.themeName = nil
            // The colours are the user's now, not the file's. Left pointing at
            // it, the next save would overwrite what they just did by hand.
            preferences.terminal.appearance.themeFile = nil
            state.themes.stopWatching()
        }
        applyAndReturnFocus()
    }

    private func applyAndReturnFocus() {
        state.applyTerminalSettings()
        state.focusTerminal()
    }
}
