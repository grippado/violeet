// Reading and writing `TerminalSettings`, tolerantly.
//
// # The rule
//
// **A settings file must never be able to stop the app from starting.** Not one
// written by an older build, not one written by a newer build, not one a user
// hand-edited and got wrong, not one truncated by a crash mid-write.
//
// Synthesised `Codable` gives exactly the opposite guarantee: one field of the
// wrong type and the whole decode throws, which here would mean a terminal that
// will not open because somebody typed a colour wrong. So every field is read
// independently and falls back to its default. The failure mode is losing one
// setting, which is visible and fixable, rather than losing the app.
//
// The same rule going forward: a field this version does not know is **kept**
// and written back out. Two builds sharing a home directory — a release and a
// dev build, which is the normal state of this project — must not erase each
// other's settings by taking turns saving.

import Foundation

extension TerminalSettings {
    /// Read from a plain JSON object. Anything unreadable falls back.
    init(json: [String: Any]) {
        self.init()

        if let appearance = json["appearance"] as? [String: Any] {
            self.appearance.themeName = appearance["theme"] as? String
            self.appearance.background =
                RGB(hexOrNil: appearance["background"]) ?? self.appearance.background
            self.appearance.foreground =
                RGB(hexOrNil: appearance["foreground"]) ?? self.appearance.foreground
            self.appearance.cursorColor =
                RGB(hexOrNil: appearance["cursor"]) ?? self.appearance.cursorColor
            // The palette is all-or-nothing: a partial one would silently mix
            // two themes, and a terminal whose red is from one palette and
            // whose green is from another is worse than one that ignored the
            // file.
            if let raw = appearance["ansi"] as? [String], raw.count == 16 {
                let parsed = raw.compactMap { RGB(hex: $0) }
                if parsed.count == 16 { self.appearance.ansi = parsed }
            }
        }

        if let font = json["font"] as? [String: Any] {
            if let name = font["name"] as? String, !name.isEmpty { self.font.name = name }
            if let size = font["size"] as? Double {
                self.font.size = clamp(CGFloat(size), to: FontSettings.sizeRange)
            }
            if let spacing = font["lineSpacing"] as? Double {
                self.font.lineSpacing = clamp(CGFloat(spacing), to: FontSettings.lineSpacingRange)
            }
        }

        if let padding = json["padding"] as? [String: Any] {
            if let h = padding["horizontal"] as? Double {
                self.padding.horizontal = clamp(CGFloat(h), to: PaddingSettings.range)
            }
            if let v = padding["vertical"] as? Double {
                self.padding.vertical = clamp(CGFloat(v), to: PaddingSettings.range)
            }
        }

        if let cursor = json["cursor"] as? [String: Any] {
            if let shape = cursor["shape"] as? String,
               let parsed = CursorSettings.Shape(rawValue: shape) {
                self.cursor.shape = parsed
            }
            if let blinks = cursor["blinks"] as? Bool { self.cursor.blinks = blinks }
        }

        if let window = json["window"] as? [String: Any] {
            if let opacity = window["opacity"] as? Double {
                self.window.opacity = clamp(opacity, to: WindowSettings.opacityRange)
            }
            if let blur = window["blur"] as? Bool { self.window.blur = blur }
            if let size = window["interfaceFontSize"] as? Double {
                self.window.interfaceFontSize = clamp(
                    CGFloat(size),
                    to: WindowSettings.interfaceFontSizeRange
                )
            }
        }

        if let behaviour = json["behaviour"] as? [String: Any] {
            if let lines = behaviour["scrollback"] as? Int {
                self.behaviour.scrollbackLines = min(max(lines, 100), 1_000_000)
            }
            if let shell = behaviour["shell"] as? String { self.behaviour.shellOverride = shell }
            if let wrap = behaviour["wrapLines"] as? Bool { self.behaviour.wrapLines = wrap }
        }
    }

    /// Write to a plain JSON object, preserving anything `previous` carried
    /// that this version does not model.
    ///
    /// The preservation is not politeness. A release build and a dev build
    /// share `~/Library/Preferences`, and this project runs both daily: without
    /// it, whichever saved last would delete the other's fields.
    func json(preserving previous: [String: Any] = [:]) -> [String: Any] {
        var out = previous

        var appearanceOut = previous["appearance"] as? [String: Any] ?? [:]
        appearanceOut["theme"] = appearance.themeName as Any?
        appearanceOut["background"] = appearance.background.hex
        appearanceOut["foreground"] = appearance.foreground.hex
        appearanceOut["cursor"] = appearance.cursorColor.hex
        appearanceOut["ansi"] = appearance.ansi.map(\.hex)
        // `themeName` is genuinely optional and `nil` means "edited by hand".
        // Writing `NSNull` would come back as a non-String and read as absent,
        // which happens to be the same thing — but removing the key says it.
        if appearance.themeName == nil { appearanceOut.removeValue(forKey: "theme") }
        out["appearance"] = appearanceOut

        var fontOut = previous["font"] as? [String: Any] ?? [:]
        fontOut["name"] = font.name
        fontOut["size"] = Double(font.size)
        fontOut["lineSpacing"] = Double(font.lineSpacing)
        out["font"] = fontOut

        var paddingOut = previous["padding"] as? [String: Any] ?? [:]
        paddingOut["horizontal"] = Double(padding.horizontal)
        paddingOut["vertical"] = Double(padding.vertical)
        out["padding"] = paddingOut

        var cursorOut = previous["cursor"] as? [String: Any] ?? [:]
        cursorOut["shape"] = cursor.shape.rawValue
        cursorOut["blinks"] = cursor.blinks
        out["cursor"] = cursorOut

        var windowOut = previous["window"] as? [String: Any] ?? [:]
        windowOut["opacity"] = window.opacity
        windowOut["blur"] = window.blur
        windowOut["interfaceFontSize"] = Double(window.interfaceFontSize)
        out["window"] = windowOut

        var behaviourOut = previous["behaviour"] as? [String: Any] ?? [:]
        behaviourOut["scrollback"] = behaviour.scrollbackLines
        behaviourOut["shell"] = behaviour.shellOverride
        behaviourOut["wrapLines"] = behaviour.wrapLines
        out["behaviour"] = behaviourOut

        return out
    }

    /// Adopt a theme wholesale, and remember which one it was.
    mutating func apply(theme: TerminalTheme) {
        appearance.themeName = theme.name
        appearance.background = theme.background
        appearance.foreground = theme.foreground
        appearance.cursorColor = theme.cursor
        appearance.ansi = theme.ansi
    }

    /// True when the colours still match the named preset exactly.
    ///
    /// Editing one swatch clears the name, because a preset that still shows as
    /// selected after being altered is claiming something about the screen that
    /// is not true.
    var matchesNamedTheme: Bool {
        guard let name = appearance.themeName, let theme = TerminalTheme.named(name) else {
            return false
        }
        return theme.background == appearance.background
            && theme.foreground == appearance.foreground
            && theme.cursor == appearance.cursorColor
            && theme.ansi == appearance.ansi
    }
}

private func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> T {
    min(max(value, range.lowerBound), range.upperBound)
}

private extension RGB {
    init?(hexOrNil value: Any?) {
        guard let text = value as? String else { return nil }
        self.init(hex: text)
    }
}
