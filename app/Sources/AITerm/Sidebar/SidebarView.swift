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

                    if !state.elsewhereSessions.isEmpty {
                        ElsewhereHeader(
                            count: state.elsewhereSessions.count,
                            waiting: state.hasWaitingElsewhere,
                            expanded: preferences.elsewhereExpanded
                        ) {
                            preferences.elsewhereExpanded.toggle()
                        }

                        if preferences.elsewhereExpanded {
                            ForEach(state.elsewhereSessions) { card in
                                SessionCardView(
                                    card: card,
                                    isSelected: false,
                                    compactionThreshold: preferences.compactionThreshold
                                )
                                .help("Running outside aiterm. Shown because it is a real session, but there is no tab here to reveal.")
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
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
                .animation(.easeInOut(duration: 0.18), value: preferences.elsewhereExpanded)
            }

            Spacer(minLength: 0)
            Divider()
            DaemonStatusLine(status: state.daemon.status, sessionCount: state.sessions.count)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
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
private struct ElsewhereHeader: View {
    let count: Int
    let waiting: Bool
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
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(waiting ? CardTheme.attention : Color.secondary.opacity(0.75))
            .padding(.horizontal, 2)
            .padding(.top, 8)
            .padding(.bottom, 2)
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
