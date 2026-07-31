// The sidebar, in its deliberately boring first form.
//
// One row per tab, showing the working directory. That is the whole thing. The
// session cards — state, context window, the HITL prompt that is the reason
// this product exists — come next, and they are not stubbed here: a placeholder
// card would be a shape we designed before we had the data to design it
// against.
//
// What this version is for is proving the plumbing underneath it: that tabs and
// PTYs behave, that the socket connects and reconnects, and that a missing
// daemon costs the sidebar its data and costs the terminal nothing. The status
// line at the bottom is the visible half of that last claim.

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(state.tabs) { tab in
                        TabRow(tab: tab, isSelected: tab.tabID == state.selectedTabID)
                            .contentShape(Rectangle())
                            .onTapGesture { state.selectedTabID = tab.tabID }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Spacer(minLength: 0)
            Divider()
            DaemonStatusLine(status: state.daemon.status, sessionCount: state.sessions.count)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            Text("Tabs")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                state.newTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New tab (⌘T)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

private struct TabRow: View {
    /// Observed directly, so a `cd` in one tab redraws one row rather than the
    /// whole list.
    @ObservedObject var tab: TabModel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tab.hasExited ? Color.secondary.opacity(0.4) : Color.accentColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(tab.shortName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text(tab.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    // The interesting end of a path is the right-hand end.
                    .truncationMode(.head)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .help(tab.currentDirectory)
    }
}

/// Whether the daemon is there, said plainly.
///
/// ADR-002 makes "daemon not running" an ordinary state rather than an error,
/// which means it needs somewhere honest to be shown. This is that place: no
/// alert, no modal, no red — the terminal is fine and the user does not need to
/// do anything.
private struct DaemonStatusLine: View {
    let status: DaemonClient.Status
    let sessionCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
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
        case .connecting:
            return "connecting…"
        case .disconnected:
            return "daemon offline"
        case .protocolMismatch(let version):
            return "daemon speaks v\(version)"
        }
    }
}
