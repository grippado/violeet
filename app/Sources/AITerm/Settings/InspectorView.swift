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
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .settings: return "Settings"
        case .files: return "Files"
        }
    }

    var symbol: String {
        switch self {
        case .settings: return "slider.horizontal.3"
        case .files: return "doc.on.doc"
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var preferences: Preferences

    /// Which panel is showing. Held in `Preferences` and not in `@State`,
    /// because `ContentView` removes this view from the hierarchy when the
    /// inspector is hidden — local state would die with it and the panel would
    /// silently snap back to Settings every time the inspector was reopened.
    private var panel: InspectorPanel {
        get { preferences.inspectorPanel }
        nonmutating set { preferences.inspectorPanel = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: preferences.chrome.surfaceResolved.nsColor))
    }

    private var header: some View {
        HStack(spacing: 4) {
            // With one panel this reads as a title. With two it becomes the
            // selector it already is, without the header moving.
            ForEach(InspectorPanel.allCases) { item in
                QuietButton(action: { panel = item }) {
                    HStack(spacing: 4) {
                        Image(systemName: item.symbol).appFont(.caption)
                        Text(item.title).appFont(.body, weight: .semibold)
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
                    .appFont(.body)
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
        case .files:
            FilesPanel()
        }
    }
}
