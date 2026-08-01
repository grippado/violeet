// The window: sidebar on the left, terminals on the right, a drag handle
// between them.
//
// # Why this is an HStack and not a NavigationSplitView
//
// `NavigationSplitView` owns its column widths and its collapse behaviour, and
// negotiates both with the system. This app needs to own them: the sidebar's
// width is a persisted preference, collapse is a keyboard shortcut with no
// animation the user has to wait through, and neither should change because a
// future macOS refined its split-view heuristics. Two views and a divider is
// less machinery than fighting one.
//
// # Why every terminal is in the hierarchy at once
//
// The terminals live in a `ZStack`, all of them, with the unselected ones at
// zero opacity. A tab that left the hierarchy would have its NSView torn down
// and its PTY with it — which is to say switching tabs would kill agents. So
// they all stay mounted, laid out at the same size, and only visibility moves.
// That also means a background tab keeps rendering at the right dimensions, so
// an agent that writes while you are looking elsewhere is not reflowing text
// into a stale grid.

import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var preferences: Preferences

    /// Width while a drag is in flight. Committed to preferences on release, so
    /// dragging writes `UserDefaults` once instead of sixty times a second.
    @State private var dragWidth: CGFloat?
    @State private var inspectorDragWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            if preferences.sidebarVisible {
                SidebarView(preferences: preferences)
                    .frame(width: dragWidth ?? preferences.sidebarWidth)
                SidebarResizeHandle(
                    width: dragWidth ?? preferences.sidebarWidth,
                    onDrag: { dragWidth = $0 },
                    onCommit: { width in
                        dragWidth = nil
                        preferences.setSidebarWidth(width)
                    }
                )
            }
            terminals

            if preferences.inspectorVisible {
                // Dragged from the left edge, so the gesture grows the panel by
                // moving *towards* it — the mirror of the left handle rather
                // than a copy of it.
                SidebarResizeHandle(
                    width: inspectorDragWidth ?? preferences.inspectorWidth,
                    inverted: true,
                    onDrag: { inspectorDragWidth = $0 },
                    onCommit: { width in
                        inspectorDragWidth = nil
                        preferences.setInspectorWidth(width)
                    }
                )
                InspectorView(preferences: preferences)
                    .frame(width: inspectorDragWidth ?? preferences.inspectorWidth)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        // Configured from here, not from the `App` body: this view observes
        // `preferences`, so it re-renders when translucency changes. The scene
        // body does not, and the backdrop would only appear on relaunch.
        .background(WindowConfigurator(settings: preferences.terminal))
    }

    private var terminals: some View {
        ZStack {
            // The window's own background, so the gap below the last row of
            // cells is the terminal's colour and not the sidebar material.
            //
            // Not painted at all when the window is translucent: a filled
            // rectangle behind the terminal is exactly what would make the
            // translucency invisible, and this is the layer people forget.
            if !preferences.terminal.window.isTranslucent {
                Color(nsColor: preferences.terminal.appearance.background.nsColor)
            }

            ForEach(state.tabs) { tab in
                let isSelected = tab.tabID == state.selectedTabID
                TerminalHostView(session: tab.session, isSelected: isSelected)
                    .opacity(isSelected ? 1 : 0)
                    // A hidden terminal must not eat clicks meant for the one
                    // on top of it.
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
            }

            if state.tabs.isEmpty {
                EmptyWindowView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The draggable seam between sidebar and terminal.
private struct SidebarResizeHandle: View {
    let width: CGFloat
    /// The right-hand handle grows its panel as the drag moves left, so the
    /// translation is subtracted rather than added.
    var inverted: Bool = false
    let onDrag: (CGFloat) -> Void
    let onCommit: (CGFloat) -> Void

    var body: some View {
        Divider()
            // Wider than it looks: a one-pixel target is a one-pixel target.
            .frame(width: 1)
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .gesture(
                        DragGesture(coordinateSpace: .global)
                            .onChanged { value in
                                onDrag(clamp(width + delta(value.translation.width)))
                            }
                            .onEnded { value in
                                onCommit(clamp(width + delta(value.translation.width)))
                            }
                    )
            )
    }

    private func delta(_ translation: CGFloat) -> CGFloat {
        inverted ? -translation : translation
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, Preferences.minimumSidebarWidth), Preferences.maximumSidebarWidth)
    }
}

/// What the window shows when the last tab is closed.
///
/// The window stays open rather than closing itself. Closing it would be a
/// second, invisible meaning for `⌘W` — sometimes a tab, sometimes everything —
/// and the difference would only be discovered by losing something.
private struct EmptyWindowView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 10) {
            Text("No tabs")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Button("New Tab") { state.newTab() }
                .keyboardShortcut("t", modifiers: .command)
        }
    }
}


/// AppKit persists the rectangle in `UserDefaults` under this name, restores it
/// on the next launch, and keeps it on-screen when the display arrangement
/// changed in between. Storing the frame by hand would be a second source of
/// truth for the same rectangle, and a worse one.
private struct WindowConfigurator: NSViewRepresentable {
    /// Only the window-level settings are read here. Passed in rather than
    /// observed so this view updates when translucency changes and at no other
    /// time.
    let settings: TerminalSettings

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            window.setFrameAutosaveName("aiterm.main")
            window.title = "aiterm"
            window.tabbingMode = .disallowed
            apply(to: window)
        }
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        apply(to: window)
    }

    /// Make the window able to show what is behind it.
    ///
    /// Three things have to agree or the effect does not appear at all, which
    /// is why this is one function and not three call sites:
    ///
    ///  1. **The window** must be non-opaque with a clear background colour.
    ///     `isOpaque = true` is the default and it short-circuits everything
    ///     downstream — AppKit will not composite through an opaque window
    ///     however transparent its contents are.
    ///  2. **The backdrop** is an `NSVisualEffectView` behind the content, and
    ///     it is what turns "clear" into "frosted". Without it, translucency is
    ///     a plain window into whatever is behind, which is unreadable over
    ///     anything busy.
    ///  3. **The terminal's own background** must be translucent too, which
    ///     `TerminalSession.apply` does. A fully painted terminal over a
    ///     perfectly transparent window is still opaque.
    private func apply(to window: NSWindow) {
        let translucent = settings.window.isTranslucent
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : .windowBackgroundColor

        guard let contentView = window.contentView else { return }
        let existing = contentView.subviews.compactMap { $0 as? BackdropView }.first

        guard translucent, settings.window.blur else {
            existing?.removeFromSuperview()
            return
        }

        let backdrop = existing ?? {
            let view = BackdropView()
            view.blendingMode = .behindWindow
            view.material = .hudWindow
            view.state = .active
            view.autoresizingMask = [.width, .height]
            // Index 0: behind everything the app draws, in front of nothing.
            contentView.addSubview(view, positioned: .below, relativeTo: nil)
            return view
        }()
        backdrop.frame = contentView.bounds
    }
}

/// Tagged so the configurator can find its own backdrop again rather than
/// guessing at subview positions.
private final class BackdropView: NSVisualEffectView {}
