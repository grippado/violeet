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
                    fill: Color(nsColor: terminalBackground),
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
                    fill: Color(nsColor: terminalBackground),
                    inverted: true,
                    showsRule: false,
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
        // One place the chrome's type scale enters the hierarchy. Every label
        // below reads it out of the environment, so moving the setting moves
        // all of them together — and the terminal, whose font is its own
        // setting entirely, does not move at all.
        .environment(\.appFont, AppFont(body: preferences.terminal.window.interfaceFontSize))
        // Configured from here, not from the `App` body: this view observes
        // `preferences`, so it re-renders when translucency changes. The scene
        // body does not, and the backdrop would only appear on relaunch.
        .background(WindowConfigurator(settings: preferences.terminal, title: state.windowTitle))
    }

    /// The terminal's background, carrying the window's alpha when translucent.
    private var terminalBackground: NSColor {
        let base = preferences.terminal.appearance.background.nsColor
        guard preferences.terminal.window.isTranslucent else { return base }
        return base.withAlphaComponent(preferences.terminal.window.opacity)
    }

    private var terminals: some View {
        ZStack {
            // A background, **always**, carrying the same alpha the terminal
            // itself uses.
            //
            // It was skipped when translucent, on the theory that a filled
            // rectangle behind the terminal would hide what was behind the
            // window. That was wrong twice over. The colour is translucent too,
            // so it hides nothing — and removing it took away the only child of
            // this `ZStack` that expands, which left the terminal at its
            // intrinsic size inside a stack stretched to fill. The gap that
            // opened beside it was reported as a seam, and the clue that solved
            // it was that it existed at 99% opacity and vanished at 100%.
            //
            // It also matters for the honest reason it was added: a character
            // grid is a whole number of cells, so the last row and column never
            // land exactly on the edge, and those few points have to be the
            // terminal's colour rather than whatever is behind.
            if preferences.terminal.window.isTranslucent, preferences.terminal.window.blur {
                WindowBackdrop(material: .hudWindow)
            }
            Color(nsColor: terminalBackground)

            ForEach(state.tabs) { tab in
                let isSelected = tab.tabID == state.selectedTabID
                TerminalHostView(session: tab.session, isSelected: isSelected)
                    // Padding shrinks the pane, which shrinks the grid, which
                    // the child is told about through the same TIOCSWINSZ path
                    // a font change uses — SwiftTerm recomputes on any frame
                    // change, so nothing extra is needed here.
                    .padding(.horizontal, preferences.terminal.padding.horizontal)
                    .padding(.vertical, preferences.terminal.padding.vertical)
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
    /// What the seam is painted with.
    ///
    /// Not `Color.clear`, and that was the whole bug behind a bright line
    /// beside the settings panel. Below 100% opacity the window is non-opaque,
    /// so a column with nothing drawn in it does not fall back to the window's
    /// background — it shows the **desktop**. One point of wallpaper between
    /// the terminal and the panel, gone at 100% because an opaque window fills
    /// whatever its views do not.
    ///
    /// Measured after three wrong answers: the terminal host sits at
    /// x=241…819 and the panel starts at x=820, so the layout was never off by
    /// more than the single point this view occupies.
    let fill: Color
    /// The right-hand handle grows its panel as the drag moves left, so the
    /// translation is subtracted rather than added.
    var inverted: Bool = false
    /// Whether to draw a line. The drag area is the same either way.
    var showsRule: Bool = true
    let onDrag: (CGFloat) -> Void
    let onCommit: (CGFloat) -> Void

    var body: some View {
        Group {
            if showsRule {
                Divider()
            } else {
                Color.clear
            }
        }
        // Wider than it looks: a one-pixel target is a one-pixel target.
        .frame(width: 1)
        .background(fill)
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
                .appFont(.headline, weight: .medium)
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

    /// The selected tab's name. The window has no tab bar, so the title bar is
    /// where a tab says what it is at full size — and it follows the same
    /// precedence chain as the sidebar rather than a second rule of its own.
    let title: String

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            window.setFrameAutosaveName("violeet.main")
            window.tabbingMode = .disallowed
            apply(to: window)
        }
        return probe
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let window = view.window else { return }
        apply(to: window)
    }

    /// Let the window composite what is behind it.
    ///
    /// This is only half the job, and deliberately the half that has to be done
    /// on the `NSWindow`: AppKit will not composite through a window whose
    /// `isOpaque` is `true`, however transparent its contents are. The frosting
    /// itself is `WindowBackdrop`, which lives inside the SwiftUI hierarchy —
    /// see the note there for why it is not a subview of `contentView`.
    private func apply(to window: NSWindow) {
        if window.title != title {
            window.title = title
        }
        let translucent = settings.window.isTranslucent
        window.isOpaque = !translucent
        // The terminal's own background, not `.windowBackgroundColor`.
        //
        // A character grid is a whole number of cells wide, so the last cell
        // almost never lands exactly on the edge and a few points are left
        // over. Whatever the window is filled with shows through there — and
        // the system colour is a light grey that reads as a seam between the
        // terminal and whatever is beside it. Invisible while that edge was the
        // window's own; obvious the moment a sidebar was put next to it.
        window.backgroundColor = translucent
            ? .clear
            : settings.appearance.background.nsColor
    }
}

/// The frosted layer behind everything the app draws.
///
/// # Why this is a SwiftUI view and not a subview of `window.contentView`
///
/// It was the latter first, and it painted over the entire window: the sidebar,
/// the terminal, all of it, leaving a blurred empty rectangle. Under SwiftUI
/// the window's `contentView` **is** the `NSHostingView`, and inserting a view
/// into it puts that view inside a hierarchy SwiftUI owns and reorders at will.
/// `positioned: .below` buys nothing there, because the ordering is not ours to
/// set.
///
/// Placed as the bottom of the app's own `ZStack` instead, where the layering
/// is expressed in the same system that enforces it.
private struct WindowBackdrop: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // `behindWindow`, not `withinWindow`: the point is what is behind the
        // *window*, not what is behind this view inside it.
        view.blendingMode = .behindWindow
        view.material = material
        // `.active` rather than `.followsWindowActiveState`, so an unfocused
        // window keeps the appearance it was configured with instead of going
        // flat the moment you look at something else.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
