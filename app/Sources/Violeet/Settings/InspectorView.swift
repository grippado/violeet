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
/// The enum is the seam: adding a panel is a case, a title, a symbol and a
/// view, with nothing else to touch.
///
/// Declaration order is tab order, and `files` comes first on purpose. The
/// inspector is open while an agent works, and what the agent is writing is a
/// thing to watch; a colour scheme is a thing to set once. Settings earned the
/// first slot only by being the panel that existed first.
enum InspectorPanel: String, CaseIterable, Identifiable {
    case files
    case settings

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

    /// What the files panel is currently showing, as a name and a symbol.
    ///
    /// One panel, three subjects. It was called "Files" for all of them, which
    /// is true and useless: the reader already knows they are looking at files.
    /// What they cannot tell at a glance is *which* files — everything an agent
    /// touched, everything in a directory, or the one file open in this tab.
    ///
    /// The tab is a label for what is under it, so it says that instead:
    ///
    ///  · **Changes** — what a session wrote. The word the reader is already
    ///    thinking in when they open this beside a working agent.
    ///  · **Tree** — the working directory of a plain shell.
    ///  · **File** — the single file an editor tab is on.
    ///
    /// The symbol moves with the word, because a label that changes under a
    /// fixed icon reads as a glitch rather than as a different subject.
    private var filesSubject: (title: String, symbol: String) {
        if state.inspectedSession != nil {
            return ("Changes", "plus.forwardslash.minus")
        }
        if let tab = state.inspectedTab {
            // The open file's own icon, not a generic page. The tab strip and
            // the panel row already show it, and this header sitting above the
            // file's name was the one place still calling it "a document".
            if let editing = tab.editing {
                return ("File", FileIcons.icon(for: editing.name, isDirectory: false).symbol)
            }
            return ("Tree", "folder")
        }
        return (InspectorPanel.files.title, InspectorPanel.files.symbol)
    }

    private func label(for item: InspectorPanel) -> (title: String, symbol: String) {
        item == .files ? filesSubject : (item.title, item.symbol)
    }

    /// One tab of the selector, with or without its label.
    ///
    /// The symbol is never dropped and the word is, which is the right way
    /// round: the icon is what the eye finds after the first day, and the word
    /// is what teaches it on the first.
    private func tab(_ item: InspectorPanel, showingLabel: Bool) -> some View {
        let label = label(for: item)
        return QuietButton(action: { panel = item }) {
            HStack(spacing: 4) {
                Image(systemName: label.symbol).appFont(.caption)
                if showingLabel {
                    Text(label.title).appFont(.body, weight: .semibold)
                }
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
        // The word leaves the screen, not the meaning: a hover and a screen
        // reader still get the full name once the label is gone.
        .help(label.title)
        .accessibilityLabel(label.title)
    }

    private var header: some View {
        HStack(spacing: 4) {
            // With one panel this reads as a title. With two it becomes the
            // selector it already is, without the header moving.
            //
            // Labels while they fit, icons once they do not. Dragged narrow,
            // "Files" and "Settings" plus the hide button ran out of room and
            // the row broke rather than shrinking — and a selector that wraps
            // has stopped being a row of tabs. `ViewThatFits` takes the first
            // layout with room, so the panel degrades a step at a time instead
            // of at once.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    ForEach(InspectorPanel.allCases) { tab($0, showingLabel: true) }
                }
                HStack(spacing: 4) {
                    ForEach(InspectorPanel.allCases) { tab($0, showingLabel: false) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

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
