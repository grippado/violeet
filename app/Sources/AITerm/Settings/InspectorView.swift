// The right sidebar: a container for panels, of which settings is the first.
//
// # Why a container and not just "the settings sidebar"
//
// The left sidebar is what the window is *about* — sessions, always there. This
// side is a workbench: things you open, use, and close. Settings is the first
// tenant and will not be the last, so the selector exists from the start even
// though it currently has one entry. Retrofitting a chrome around a panel that
// assumed it was alone is the expensive version of this.
//
// It is deliberately *not* symmetric in behaviour, only in shape. The left side
// is visible by default and the right is not, because a panel that is always
// open is a panel that is always taking width from the terminal.

import SwiftUI

/// What the right sidebar can show.
///
/// One case today. The enum is the seam: adding a panel is a case, a title, a
/// symbol and a view, with nothing else to touch.
enum InspectorPanel: String, CaseIterable, Identifiable {
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var preferences: Preferences

    @State private var panel: InspectorPanel = .settings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 4) {
            // With one panel this reads as a title. With two it becomes the
            // selector it already is, without the header moving.
            ForEach(InspectorPanel.allCases) { item in
                QuietButton(action: { panel = item }) {
                    HStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 10))
                        Text(item.title).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(panel == item ? Color.primary : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(panel == item && InspectorPanel.allCases.count > 1
                                ? Color.secondary.opacity(0.15)
                                : Color.clear)
                    )
                }
            }

            Spacer(minLength: 0)

            QuietButton(action: {
                preferences.inspectorVisible = false
                state.focusTerminal()
            }) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .help("Hide this panel (⌥⌘I)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .settings:
            SettingsPanel(preferences: preferences)
        }
    }
}
