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

    /// Tabs that no session has claimed.
    private var unclaimedTabs: [TabModel] {
        let claimed = Set(state.sessions.values.compactMap(\.tabID))
        return state.tabs.filter { !claimed.contains($0.tabID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(state.localSessions) { card in
                        SessionCardView(
                            card: card,
                            isSelected: card.tabID != nil && card.tabID == state.selectedTabID,
                            compactionThreshold: preferences.compactionThreshold
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { reveal(card) }
                        .help(card.tabID == nil
                            ? "Running outside aiterm. Shown because it is a real session, but there is no tab to reveal."
                            : "Click to switch to this session's tab.")
                        // Cards can reorder — a session that starts waiting
                        // jumps to the top. Animated, so the jump reads as
                        // movement rather than as the list redrawing.
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    if !unclaimedTabs.isEmpty {
                        sectionLabel("tabs")
                        ForEach(unclaimedTabs) { tab in
                            TabRow(tab: tab, isSelected: tab.tabID == state.selectedTabID)
                                .contentShape(Rectangle())
                                .onTapGesture { state.selectedTabID = tab.tabID }
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
        .background(.ultraThinMaterial)
    }

    /// Sessions running outside aiterm, pinned to the foot of the sidebar.
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
                                    isSelected: false,
                                    compactionThreshold: preferences.compactionThreshold
                                )
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
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
        HStack {
            Text("Sessions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button { state.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New tab (⌘T)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 6)
            .padding(.leading, 2)
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No sessions yet")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Run an agent in a tab. Cards appear when its hooks reach the daemon.")
                .font(.system(size: 10))
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
                    .font(.system(size: 8, weight: .semibold))
                Text("ELSEWHERE")
                    .font(.system(size: 9, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 4)
                    .background(
                        Capsule().fill(waiting
                            ? CardTheme.attention.opacity(0.25)
                            : Color.secondary.opacity(0.18))
                    )
                if waiting {
                    Text("waiting for you")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(CardTheme.attention)
                } else if !expanded, !apps.isEmpty {
                    Text(apps.joined(separator: ", "))
                        .font(.system(size: 9))
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
        .help(expanded
            ? "Hide sessions running outside aiterm"
            : "\(count) session(s) running outside aiterm — click to show")
    }
}

/// A tab with no session behind it yet.
private struct TabRow: View {
    @ObservedObject var tab: TabModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tab.hasExited ? Color.secondary.opacity(0.4) : Color.secondary)
                .frame(width: 5, height: 5)
            Text(tab.shortName)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
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
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .secondary
        case .protocolMismatch: return .orange
        }
    }

    private var label: String {
        switch status {
        case .connected:
            return sessionCount == 1 ? "daemon · 1 session" : "daemon · \(sessionCount) sessions"
        case .connecting: return "connecting…"
        case .disconnected: return "daemon offline"
        case .protocolMismatch(let version): return "daemon speaks v\(version)"
        }
    }
}
