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

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var preferences: Preferences

    /// Width while a drag is in flight. Committed to preferences on release, so
    /// dragging writes `UserDefaults` once instead of sixty times a second.
    @State private var dragWidth: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            if preferences.sidebarVisible {
                SidebarView()
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
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    private var terminals: some View {
        ZStack {
            // The window's own background, so the gap below the last row of
            // cells is the terminal's colour and not the sidebar material.
            Color(nsColor: .textBackgroundColor)

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
                                onDrag(clamp(width + value.translation.width))
                            }
                            .onEnded { value in
                                onCommit(clamp(width + value.translation.width))
                            }
                    )
            )
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
