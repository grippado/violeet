// Controls that do not steal the terminal's keyboard.
//
// # The requirement
//
// Changing a setting must never cost the user the session they were typing in.
// Not "the terminal comes back when you click it" — it must not leave. This is
// a terminal for watching agents work; the moment you notice focus is gone is
// the moment after you typed a line into nothing.
//
// That is harder than it sounds, because AppKit gives focus to whatever was
// clicked, and SwiftUI's stock controls are AppKit controls. So every control
// here does two things:
//
//  1. **Declines the key view loop** (`focusable(false)`), so tabbing and
//     clicking do not route the keyboard here in the first place.
//  2. **Hands focus back explicitly** after it acts, through `onCommit`, which
//     the panel wires to `AppState.focusTerminal()`.
//
// # What is banned, and why
//
// - **`ColorPicker`.** It opens `NSColorPanel`, which is a separate window.
//   A separate window takes key status from the terminal's window, which ends
//   the session's keyboard input entirely — not just first responder within the
//   window. There is no way to use it and satisfy the requirement, so the
//   colour surface here is a curated grid plus a hex field.
// - **Free text where a stepper, slider or picker fits.** A text field holds
//   focus by definition, for as long as it is being typed into.
//
// The hex field is the one unavoidable text field: there is no gesture that
// expresses "#2E3440". It commits on Return and gives the keyboard straight
// back.

import AppKit
import SwiftUI

// MARK: - Layout

/// One labelled row. Label left, control right, both baseline-aligned.
struct SettingRow<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                content
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }
}

/// A titled group of rows.
struct SettingGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            content
        }
        .padding(.bottom, 10)
    }
}

// MARK: - Buttons

/// A button that never becomes first responder.
///
/// Every interactive thing in the panel is built on this, so there is one place
/// the focus contract is implemented and one place it can be got wrong.
struct QuietButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .focusable(false)
    }
}

// MARK: - Stepper

/// A number with `−` and `+`, and no text field.
///
/// The value is shown, not typed. Font size, line spacing and scrollback are
/// all bounded and all fine to nudge, so the text field they would otherwise
/// need buys nothing and costs the keyboard.
struct QuietStepper: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    /// How to render the number. Line spacing wants `1.10`, font size wants
    /// `13`, and a shared formatter would be wrong for one of them.
    let format: (Double) -> String
    let onChange: (Double) -> Void
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            stepButton("minus", enabled: value > range.lowerBound) {
                set(value - step)
            }
            Text(format(value))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .frame(minWidth: 42)
            stepButton("plus", enabled: value < range.upperBound) {
                set(value + step)
            }
        }
    }

    private func set(_ next: Double) {
        onChange(min(max(next, range.lowerBound), range.upperBound))
        onCommit()
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        QuietButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.14))
                )
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        }
        .disabled(!enabled)
    }
}

// MARK: - Slider

/// A slider that commits on release.
///
/// `onEditingChanged` is what returns the keyboard: a slider held down is a
/// legitimate reason for focus to be elsewhere, and giving it back on every
/// intermediate value would fight the drag.
struct QuietSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onChange: (Double) -> Void
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range,
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
            .controlSize(.small)
            .focusable(false)
            Text(format(value))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

// MARK: - Segmented

/// A row of mutually exclusive options, built from `QuietButton`.
///
/// Not `Picker(.segmented)`: that is an `NSSegmentedControl`, which joins the
/// key view loop and takes focus on click.
struct QuietSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value
    let onSelect: (Value) -> Void
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                QuietButton(action: {
                    onSelect(option.value)
                    onCommit()
                }) {
                    Text(option.label)
                        .font(.system(size: 10, weight: selection == option.value ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selection == option.value
                                    ? Color.accentColor.opacity(0.28)
                                    : Color.secondary.opacity(0.12))
                        )
                        .foregroundStyle(selection == option.value ? Color.primary : Color.secondary)
                }
            }
        }
    }
}

/// A yes/no, as two segments rather than a `Toggle`.
struct QuietToggle: View {
    let isOn: Bool
    let onChange: (Bool) -> Void
    let onCommit: () -> Void

    var body: some View {
        QuietSegmented(
            options: [(true, "On"), (false, "Off")],
            selection: isOn,
            onSelect: onChange,
            onCommit: onCommit
        )
    }
}

// MARK: - Menu

/// A long list, as a pull-down.
///
/// A menu is a separate *window* while it is open, which would break the rule —
/// except that AppKit restores key status to the window it came from when it
/// closes, and `onCommit` then puts first responder back inside it. Measured to
/// be the one popup that behaves; a `Picker` in the default style wraps this
/// same machinery but keeps focus on the button afterwards.
struct QuietMenu: View {
    let title: String
    let options: [String]
    let selection: String
    let onSelect: (String) -> Void
    let onCommit: () -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) {
                    onSelect(option)
                    onCommit()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.isEmpty ? title : selection)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.14)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
    }
}

// MARK: - Colour

/// One colour swatch.
struct Swatch: View {
    let color: RGB
    let isSelected: Bool
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        QuietButton(action: action) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: color.nsColor))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.18),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .overlay(
                    // Drawn in whichever of black or white the swatch is not,
                    // so the tick is visible on a palette that spans both.
                    isSelected
                        ? Image(systemName: "checkmark")
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundStyle(color.isLight ? Color.black : Color.white)
                        : nil
                )
        }
        .help(color.hex)
    }
}

/// A colour, edited without opening a window.
///
/// The swatch grid is the primary surface and the hex field is the escape
/// hatch. This is the whole replacement for `ColorPicker`: the system picker is
/// a panel, a panel is a window, and a window takes key status away from the
/// terminal — which is not "focus moved within the window", it is the session
/// no longer receiving keystrokes at all.
struct ColorControl: View {
    let value: RGB
    /// Colours offered as one-click choices. Usually the current palette, so
    /// picking a background that matches the theme takes one click.
    let palette: [RGB]
    let onChange: (RGB) -> Void
    let onCommit: () -> Void

    @State private var draft: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 5) {
                Swatch(color: value, isSelected: false, size: 18) {}
                    .allowsHitTesting(false)

                TextField("#RRGGBB", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 68)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.14)))
                    .focused($editing)
                    // Return commits and leaves. Nothing is applied while
                    // typing: `#2` on the way to `#2E3440` is a valid-looking
                    // prefix of nothing, and repainting the terminal per
                    // keystroke would be both wrong and unpleasant.
                    .onSubmit(commit)
                    .onChange(of: editing) { _, focused in
                        if focused {
                            draft = value.hex
                        } else {
                            // Clicking away is a cancel, not a commit. The
                            // field goes back to the truth rather than keeping
                            // a half-typed value that was never applied.
                            draft = value.hex
                            onCommit()
                        }
                    }
            }

            if !palette.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                        Swatch(color: color, isSelected: color == value, size: 13) {
                            onChange(color)
                            onCommit()
                        }
                    }
                }
            }
        }
        .onAppear { draft = value.hex }
    }

    private func commit() {
        if let parsed = RGB(hex: draft) {
            onChange(parsed)
        }
        draft = value.hex
        editing = false
        onCommit()
    }
}

/// The 16 ANSI colours as a grid: normal on top, bright below.
struct AnsiPaletteGrid: View {
    let colors: [RGB]
    let selected: Int?
    let onSelect: (Int) -> Void

    private static let names = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(offset: 0, label: "normal")
            row(offset: 8, label: "bright")
        }
    }

    private func row(offset: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { i in
                    let index = offset + i
                    Swatch(
                        color: colors.indices.contains(index) ? colors[index] : RGB(0, 0, 0),
                        isSelected: selected == index,
                        size: 18
                    ) {
                        onSelect(index)
                    }
                    .help("\(label) \(Self.names[i])")
                }
            }
        }
    }
}
