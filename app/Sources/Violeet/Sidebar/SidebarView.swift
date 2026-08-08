// The sidebar: one card per agent session, plus the tabs that have none yet.
//
// Everything a card shows comes off the socket. The app computes exactly one
// thing — the context percentage, from two numbers the daemon sends — and the
// protocol deliberately omits `context_pct` for that reason: a percentage
// derived in two places is a percentage that can disagree with itself.
//
// # Order
//
// Sessions waiting on the user come first. They are the only cards with an
// action attached, and burying one under six working agents is precisely the
// failure this product exists to fix. Ordering lives in `AppState` so there is
// one rank and one place to change it.
//
// # Tabs without sessions
//
// A tab whose shell has not started an agent has no session and therefore no
// card. It still appears, in a thin secondary list below the cards, because a
// tab you opened and cannot see is worse than a tab with nothing to say.

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var preferences: Preferences

    /// How tall the expanded outside-sessions panel may grow.
    private static let elsewhereMaxHeight: CGFloat = 320
    @State private var elsewhereContentHeight: CGFloat = 0

    /// Tabs that no session has claimed, and that are not editors.
    ///
    /// An editor tab is claimed too, just not by running an agent: it was opened
    /// from a session's file tree and is drawn under that session's card. Left
    /// in this list it would appear twice, and in the place that means "nothing
    /// knows why this tab exists" — which is the opposite of what is known
    /// about it.
    private var unclaimedTabs: [TabModel] {
        let claimed = Set(state.sessions.values.compactMap(\.tabID))
        return state.tabs.filter { tab in
            guard !claimed.contains(tab.tabID) else { return false }
            // An editor whose session has since gone falls back here rather
            // than disappearing: the tab is still open and still needs a way
            // back to it.
            guard let editing = tab.editing, let owner = editing.sessionID else { return true }
            return state.sessions[owner] == nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(state.localSessions) { card in
                        SessionCardView(
                            card: card,
                            title: state.displayTitle(for: card),
                            name: state.name(for: card),
                            isSelected: card.tabID != nil && card.tabID == state.selectedTabID,
                            onRename: { state.rename(session: card.sessionID, to: $0) },
                            onRelease: { state.releaseName(session: card.sessionID) },
                            onFinish: { state.focusTerminal() },
                            compactionThreshold: preferences.compactionThreshold,
                            chrome: preferences.chrome,
                            density: .forSidebar(width: preferences.sidebarWidth)
                        )
                        .contentShape(Rectangle())
                        // Two effects, one gesture: go to the tab, and point
                        // the Files panel at this session. The second is
                        // harmless while that panel is closed.
                        .onTapGesture {
                            state.inspect(session: card.sessionID)
                            reveal(card)
                        }
                        .pointingHand(card.tabID != nil)
                        .help(card.tabID == nil
                            ? "Running outside violeet. Shown because it is a real session, but there is no tab to reveal."
                            : "Click to switch to this session's tab.")
                        // Cards can reorder — a session that starts waiting
                        // jumps to the top. Animated, so the jump reads as
                        // movement rather than as the list redrawing.
                        .transition(.opacity.combined(with: .move(edge: .top)))

                        editorTabs(under: card)
                    }

                    if !unclaimedTabs.isEmpty {
                        sectionLabel("tabs")
                        ForEach(unclaimedTabs) { tab in
                            TabRow(
                                tab: tab,
                                isSelected: tab.tabID == state.selectedTabID,
                                name: state.name(for: tab),
                                onRename: { state.rename(tab: tab, to: $0) },
                                onRelease: { state.releaseName(tab: tab) },
                                onFinish: { state.focusTerminal() }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { state.selectedTabID = tab.tabID }
                            .pointingHand()
                        }
                    }

                    if state.localSessions.isEmpty
                        && state.elsewhereSessions.isEmpty
                        && unclaimedTabs.isEmpty {
                        emptyHint
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .animation(.easeInOut(duration: 0.22), value: state.orderedSessions.map(\.id))
            }
            .frame(maxHeight: .infinity)

            elsewhereSection

            Divider()
            DaemonStatusLine(status: state.daemon.status, sessionCount: state.sessions.count)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: preferences.chrome.surfaceResolved.nsColor))
    }

    /// Sessions running outside violeet, pinned to the foot of the sidebar.
    ///
    /// Anchored at the bottom rather than mixed into the list above, because
    /// the two halves answer different questions: above is what you opened here
    /// and can switch to, below is what else is running on the machine. A
    /// collapsed section is a single bar sitting on the status line, and
    /// expanding it grows upward — the same way a bottom panel behaves in an
    /// editor sidebar.
    ///
    /// It never takes more than `elsewhereMaxHeight`, and scrolls inside that,
    /// so a machine with many outside sessions cannot squeeze the tabs you
    /// actually opened off the screen.
    @ViewBuilder
    private var elsewhereSection: some View {
        if !state.elsewhereSessions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                ElsewhereHeader(
                    count: state.elsewhereSessions.count,
                    waiting: state.hasWaitingElsewhere,
                    apps: state.elsewhereApps,
                    expanded: preferences.elsewhereExpanded
                ) {
                    preferences.elsewhereExpanded.toggle()
                }
                .padding(.horizontal, 7)

                if preferences.elsewhereExpanded {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(state.elsewhereSessions) { card in
                                SessionCardView(
                                    card: card,
                                    title: state.displayTitle(for: card),
                                    name: state.name(for: card),
                                    isSelected: false,
                                    onRename: { state.rename(session: card.sessionID, to: $0) },
                                    onRelease: { state.releaseName(session: card.sessionID) },
                                    onFinish: { state.focusTerminal() },
                                    compactionThreshold: preferences.compactionThreshold,
                                    chrome: preferences.chrome,
                                    density: .forSidebar(width: preferences.sidebarWidth)
                                )
                                // These cards stay unrevealable — there is no
                                // tab to switch to, and the disabled row in the
                                // status menu says why. But their files are
                                // just as inspectable as anyone's, and this is
                                // the first thing a click here has ever done.
                                .contentShape(Rectangle())
                                .onTapGesture { state.inspect(session: card.sessionID) }
                                .pointingHand()
                                .transition(.opacity.combined(with: .move(edge: .bottom)))

                                // An outside session cannot be revealed, but the
                                // editors *this* app opened for it can. They are
                                // the one part of an elsewhere card that is
                                // local, and clicking them works.
                                editorTabs(under: card)
                            }
                        }
                        .padding(.horizontal, 7)
                        .padding(.bottom, 6)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ElsewhereHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        )
                    }
                    // Sized to its content up to the cap, so one card does not
                    // reserve the room of five.
                    .frame(height: min(elsewhereContentHeight, Self.elsewhereMaxHeight))
                    .onPreferenceChange(ElsewhereHeightKey.self) { elsewhereContentHeight = $0 }
                }
            }
            .animation(.easeInOut(duration: 0.18), value: preferences.elsewhereExpanded)
        }
    }

    /// Bring the tab a card belongs to to the front.
    ///
    /// A session with no tab cannot be revealed — an agent started in iTerm is
    /// a supported state (ADR-003), so the tap is a no-op rather than an error.
    private func reveal(_ card: SessionCard) {
        guard let tabID = card.tabID else { return }
        state.selectedTabID = tabID
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Sessions")
                .appFont(.body, weight: .semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            // Beside the title, not out at the trailing edge. This control
            // moves the edge it would otherwise sit on: parked on the right, it
            // jumps under the cursor the moment it is used, so choosing 33%
            // then 66% means chasing it across the screen. Anchored to the
            // title, its position does not depend on the width it sets.
            spanMenu
            Spacer(minLength: 0)
            Button { state.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .pointingHand()
                .foregroundStyle(.secondary)
                .help("New tab (⌘T)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// Picks the sidebar width from a menu of three.
    ///
    /// A menu rather than a button that cycles: cycling makes the two widths
    /// you are not at unreachable except by passing through, and it cannot say
    /// what the options are without being clicked. Here they are all listed,
    /// with the current one ticked.
    ///
    /// Labelled with the width it is at, so the control and the sidebar beside
    /// it never disagree.
    private var spanMenu: some View {
        let span = Preferences.SidebarSpan.nearest(to: state.preferences.sidebarWidth)
        return Menu {
            ForEach(Preferences.SidebarSpan.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        state.preferences.setSidebarWidth(option.width)
                    }
                } label: {
                    // A tick rather than a disabled row: the current width stays
                    // choosable, which is what makes the menu safe to open just
                    // to read.
                    if option == span {
                        Label(option.menuLabel, systemImage: "checkmark")
                    } else {
                        Text(option.menuLabel)
                    }
                }
            }
        } label: {
            Text(span.label)
                .appFont(.small, weight: .medium, monospacedDigit: true)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHand()
        .help("Sidebar width — \(span.label) of its widest. Click to choose another.")
        .accessibilityLabel("Sidebar width, \(span.label)")
    }

    /// The editor tabs a card owns, drawn under it.
    ///
    /// Indented and quiet: these are not peers of the card, they are things the
    /// card's file tree opened. A session that wrote thirty files can have three
    /// editors under it without the sidebar reading as six sessions.
    @ViewBuilder
    private func editorTabs(under card: SessionCard) -> some View {
        let tabs = state.editorTabs(forSession: card.sessionID)
        if !tabs.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(tabs) { tab in
                    EditorTabRow(
                        tab: tab,
                        isSelected: tab.tabID == state.selectedTabID
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { state.selectedTabID = tab.tabID }
                    .pointingHand()
                }
            }
            .padding(.leading, 10)
            .padding(.top, 1)
            .transition(.opacity)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .appFont(.small, weight: .semibold)
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
            .padding(.leading, 2)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No sessions yet")
                .appFont(.body, weight: .medium)
                .foregroundStyle(.secondary)
            Text("Run an agent in a tab. Cards appear when its hooks reach the daemon.")
                .appFont(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
        .padding(.top, 8)
    }
}

/// The clickable bar that opens and closes the elsewhere section.
///
/// It carries the count when collapsed, so the section is never a silent
/// omission — "3 elsewhere" says there is something there without spending the
/// rows to show it.
///
/// And it turns amber when one of the hidden sessions is waiting on the user.
/// A collapsed section that could hide a blocked agent would defeat the one
/// thing this product exists to do, so the header itself carries the signal
/// upward.
/// Measures the outside-sessions list so the panel can size to it.
private struct ElsewhereHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ElsewhereHeader: View {
    let count: Int
    let waiting: Bool
    /// The distinct terminal applications behind the hidden cards. Shown only
    /// while collapsed: it is the one piece of "where" worth paying for when
    /// the cards themselves are not on screen, and once they are, each says it
    /// for itself.
    let apps: [String]
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .appFont(.micro, weight: .semibold)
                Text("ELSEWHERE")
                    .appFont(.small, weight: .semibold)
                Text("\(count)")
                    .appFont(.small, weight: .medium, monospacedDigit: true)
                    .padding(.horizontal, 4)
                    .background(
                        Capsule().fill(waiting
                            ? CardTheme.attention.opacity(0.25)
                            : Color.secondary.opacity(0.18))
                    )
                if waiting {
                    Text("waiting for you")
                        .appFont(.small, weight: .bold)
                        .foregroundStyle(CardTheme.attention)
                } else if !expanded, !apps.isEmpty {
                    Text(apps.joined(separator: ", "))
                        .appFont(.small)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(waiting ? CardTheme.attention : Color.secondary.opacity(0.75))
            // Symmetric: this is a bar sitting on the status line now, not a
            // heading introducing the list below it.
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .help(expanded
            ? "Hide sessions running outside violeet"
            : "\(count) session(s) running outside violeet — click to show")
    }
}

/// A tab with no session behind it yet.
///
/// Renameable like any card. A tab with no agent in it is still a tab the user
/// may be keeping for a reason, and "you can name this one but not that one"
/// is a rule nobody would guess.
private struct TabRow: View {
    @ObservedObject var tab: TabModel
    let isSelected: Bool
    let name: ResolvedName
    let onRename: (String) -> Void
    let onRelease: () -> Void
    let onFinish: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tab.hasExited ? Color.secondary.opacity(0.4) : Color.secondary)
                .frame(width: 5, height: 5)
            EditableName(
                name: name,
                display: name.text,
                step: .body,
                weight: isSelected ? .semibold : .regular,
                colour: .primary,
                onRename: onRename,
                onRelease: onRelease,
                onFinish: onFinish
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        )
        .help(tab.currentDirectory)
    }
}

/// A tab the Files panel opened, drawn under the session it belongs to.
///
/// Deliberately not a `TabRow`. That row is for a tab nothing has claimed, and
/// its affordances follow from that: it is renameable, because a tab with no
/// session has no other name than the one you give it. This one is named by the
/// file it opened, and renaming it would be naming the file — so it does not
/// offer to.
///
/// The filename, not the path: the row sits under the card whose tree the file
/// came from, and that tree already showed where it lives. The full path is in
/// the tooltip.
private struct EditorTabRow: View {
    @ObservedObject var tab: TabModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            // The same glyph the Files panel puts on an open row, so the pair
            // reads as one relationship seen from two ends.
            Image(systemName: "macwindow")
                .appFont(.micro)
                .foregroundStyle(tab.hasExited ? .tertiary : .secondary)
            Text(tab.editing?.name ?? tab.currentDirectory)
                .appFont(.caption, weight: isSelected ? .semibold : .regular)
                .foregroundStyle(tab.hasExited ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        )
        .help(tab.editing.map { "Editing \($0.path)" } ?? tab.currentDirectory)
    }
}

/// Whether the daemon is there, said plainly.
///
/// ADR-002 makes "daemon not running" an ordinary state rather than an error,
/// which means it needs somewhere honest to be shown. This is that place: no
/// alert, no modal, no red — the terminal is fine and the user need do nothing.
private struct DaemonStatusLine: View {
    let status: DaemonClient.Status
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // Both come from `DaemonClient.Status` itself, so the status-bar menu and
    // this footer cannot come to describe the same state differently.
    private var color: Color { status.indicatorColor }

    private var label: String { status.summary(sessionCount: sessionCount) }
}
