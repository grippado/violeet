// The Files panel: what a session wrote, as a tree.
//
// # Why this is worth a panel
//
// The sidebar answers "what is each agent doing"; a `last_action` row answers it
// one tool at a time and forgets the rest. Over an hour a session touches thirty
// files across a repo and the vault, and nothing on screen holds that. This is
// the same argument the sidebar makes for context percentage: the number exists
// in the daemon either way, and not showing it is the only expensive part.
//
// # Two empties, never one
//
// "This session wrote nothing" and "we did not see what it wrote" are different
// facts, and an empty tree that means both is the failure `SessionCardModel`
// spends its whole header refusing. A partial list says so, in words, above the
// files it does have.
//
// # The app computes nothing
//
// Grouping and sorting happen here — presentation over data the daemon sent.
// The counts do not: no `git`, no stat, no diff. `SessionFileList.grouped` is a
// pure function for exactly that reason.
//
// # A list you can act on
//
// A row opens its file in a tab running the user's editor — see
// `AppState.openInEditor`. A panel that only names files makes the reader
// retype a path into the terminal beside it, which is the one errand a terminal
// should never hand back.
//
// The diff marks in that editor are gitsigns' and are the **git** diff: what is
// not yet committed. That is the right answer while reviewing an agent's work
// and an empty one afterwards. The session's own line ranges arrive in
// `structuredPatch` and the daemon sums them away — showing those instead would
// mean carrying every hunk and rebasing its position past every later edit.

import SwiftUI

struct FilesPanel: View {
    @EnvironmentObject private var state: AppState

    private var session: SessionCard? { state.inspectedSession }
    private var list: SessionFileList? {
        session.flatMap { state.sessionFiles[$0.sessionID] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session {
                header(for: session)
                Divider()
                body(for: list ?? SessionFileList())
            } else if let tab = state.inspectedTab {
                notASession(tab)
            } else {
                hint("No session selected", detail: "Run an agent in a tab, then click its card.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What the panel says when the selected tab is not an agent.
    ///
    /// It names the tab rather than going blank, because "no files" and "this is
    /// not a thing that has files" are different facts — the same distinction
    /// the two empties below are built around, one level up. A blank panel here
    /// would read as a session that wrote nothing.
    ///
    /// An editor tab knows which session sent it, and says so: it is the one
    /// tab that can point back at a file list, and a dead end that knows the way
    /// out should offer it.
    @ViewBuilder
    private func notASession(_ tab: TabModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let editing = tab.editing {
                Text(editing.name)
                    .appFont(.body, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ProcessDirectory.abbreviated(editing.path))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .help(editing.path)

                if let owner = editing.sessionID, let card = state.sessions[owner] {
                    Divider().padding(.vertical, 4)
                    QuietButton(action: { state.inspect(session: owner) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .appFont(.micro)
                            Text("Files of \(state.displayTitle(for: card))")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .pointingHand()
                    .help("Show what that session wrote.")
                } else {
                    Text("Opened from a session that has since ended.")
                        .appFont(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            } else {
                Text(state.name(for: tab).text)
                    .appFont(.body, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(ProcessDirectory.abbreviated(tab.currentDirectory))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .help(tab.currentDirectory)
                Text("No agent is running in this tab, so there are no files to list.")
                    .appFont(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    // MARK: - Header

    /// Whose tree this is, and the one number most glances are after.
    ///
    /// The name comes from `AppState.displayTitle`, the same resolver the card
    /// uses, so the panel and the card can never disagree about what a session
    /// is called.
    private func header(for session: SessionCard) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(state.displayTitle(for: session))
                .appFont(.body, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)

            // Where the session is running, above everything it wrote.
            //
            // The tree groups by root, so a panel without this reads as if the
            // roots were the whole story — and they are not: an agent working
            // in one checkout and writing to the vault shows two roots, neither
            // of which is where it was launched. `truncationMode(.head)`
            // because the tail of a path is the part that identifies it.
            //
            // Same `pathLabel` the card shows, so the two cannot disagree.
            if let path = session.pathLabel {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .appFont(.micro)
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .help(session.cwd ?? path)
            }

            if let list, !list.isEmpty {
                HStack(spacing: 6) {
                    Text("\(list.files.count) file\(list.files.count == 1 ? "" : "s")")
                    DiffStat(added: list.totalAdded, removed: list.totalRemoved, approximate: list.isQualified)
                }
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for list: SessionFileList) -> some View {
        if list.isEmpty {
            // The distinction this panel exists to keep. A session we only
            // started watching midway has not "written nothing" — we simply
            // cannot say, and saying nothing would read as the former.
            if list.isPartial == true {
                hint(
                    "File changes unknown",
                    detail: "This session was already running when the daemon started watching it."
                )
            } else {
                hint(
                    "Nothing written yet",
                    detail: "Files appear here as the agent edits them."
                )
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if list.isQualified {
                        caveat(for: list)
                    }
                    ForEach(list.grouped()) { root in
                        RootSection(root: root, sessionID: session?.sessionID)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    /// Said above the files, not below: a caveat under a long list is a caveat
    /// nobody scrolls to.
    private func caveat(for list: SessionFileList) -> some View {
        let text: String
        if list.isTruncated == true {
            text = "Long list — only the first files are shown."
        } else {
            text = "Partial: files written before the daemon started, or written by shell commands, are missing."
        }
        return Text(text)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
    }

    private func hint(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).appFont(.body, weight: .semibold)
            Text(detail)
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

// MARK: - One root

/// A root and its files, collapsible.
///
/// Collapsed shows the aggregate rather than hiding it, the same discipline the
/// outside-sessions header follows: a section that folds away silently is an
/// omission, and one that folds away carrying its numbers is a summary.
private struct RootSection: View {
    let root: FileRoot
    /// Passed through to the rows, which hand it to the tab they open.
    let sessionID: String?
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            QuietButton(action: { expanded.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .appFont(.micro)
                        .foregroundStyle(.secondary)
                    Text(root.root)
                        .appFont(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 4)
                    if !expanded {
                        DiffStat(added: root.added, removed: root.removed, approximate: false)
                            .appFont(.micro)
                    }
                }
            }

            if expanded {
                ForEach(root.entries) { entry in
                    FileRow(entry: entry, sessionID: sessionID)
                }
            }
        }
        .padding(.bottom, 6)
    }
}

/// One file, and a way into it.
///
/// Clicking opens the file in a tab running the user's editor. The row was
/// inert before, which made the panel a place to read a filename and then type
/// it somewhere else — the one thing a terminal is already good at was the
/// thing it would not do.
private struct FileRow: View {
    @EnvironmentObject private var state: AppState
    let entry: FileRoot.Entry
    /// Whose tree this row is in. Travels to the tab so the sidebar can put the
    /// two together.
    let sessionID: String?
    @State private var hovering = false

    private var isOpen: Bool { state.isOpenInEditor(path: entry.change.path) }

    /// Whether the file is still where the session wrote it.
    ///
    /// Reading a transcript from the start means the list can name paths that
    /// have since moved: a rename, a `git mv`, a directory renamed under all of
    /// them. Clicking one used to open an editor on nothing — a blank buffer
    /// with the old path in the status line, which reads as the editor being
    /// broken rather than as the file being gone.
    ///
    /// Checked at render rather than cached, because the answer changes while
    /// the panel is open: the agent is moving these files.
    private var stillThere: Bool {
        FileManager.default.fileExists(atPath: entry.change.path)
    }

    var body: some View {
        QuietButton(action: {
            guard stillThere else { return }
            state.openInEditor(path: entry.change.path, session: sessionID)
        }) {
            HStack(spacing: 6) {
                if entry.change.created {
                    // A letter and not only a colour: the same two-channel rule
                    // the menu bar icon follows, for the same reader.
                    Text("A")
                        .appFont(.micro, weight: .semibold)
                        .foregroundStyle(.green)
                        .frame(width: 9)
                } else {
                    Text(" ").appFont(.micro).frame(width: 9)
                }

                HStack(spacing: 0) {
                    if !entry.directory.isEmpty {
                        Text(entry.directory)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(!stillThere, color: .secondary)
                }
                .appFont(.caption)
                .foregroundStyle(stillThere ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))

                // Gone. A glyph and not only the dimming, the same two-channel
                // rule the `A` follows: a row that says "missing" in weight
                // alone says nothing to a reader who cannot see the difference.
                if !stillThere {
                    Image(systemName: "questionmark.circle")
                        .appFont(.micro)
                        .foregroundStyle(.tertiary)
                }

                // Open in a tab. A glyph and not only the tint, because a row
                // that says "open" in colour alone says nothing to a reader who
                // cannot see the difference — the same two-channel rule the `A`
                // above follows.
                if isOpen {
                    Image(systemName: "macwindow")
                        .appFont(.micro)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)
                DiffStat(added: entry.change.added, removed: entry.change.removed, approximate: false)
                    .appFont(.micro)
            }
            .padding(.vertical, 1)
            .padding(.leading, 4)
            .padding(.trailing, 4)
            // Two different facts on one surface. Hover says "this is a click
            // target", which the panel needs because a list of filenames does
            // not otherwise look like one. The open tint persists after the
            // pointer leaves and is what pairs this row with the tab beside its
            // session in the sidebar.
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        hovering
                            ? Color.primary.opacity(0.08)
                            : (isOpen ? Color.primary.opacity(0.045) : .clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .onHover { hovering = $0 }
        .pointingHand(stillThere)
        .help(!stillThere
            ? "\(entry.change.path)\n\nNot there any more. The session wrote it at this path, and it has since been moved, renamed or deleted."
            : isOpen
            ? "\(entry.change.path)\n\nOpen in a tab. Click to go to it."
            : "\(entry.change.path)\n\nClick to open in a new tab.")
        .accessibilityLabel(entry.name)
        .accessibilityValue(isOpen ? "open in a tab" : "")
        .accessibilityHint(isOpen
            ? "Goes to the tab editing \(entry.change.path)."
            : "Opens \(entry.change.path) in a new tab.")
    }
}

/// `+12 −3`, in figures that do not jitter as they change.
private struct DiffStat: View {
    let added: Int
    let removed: Int
    /// Prefix with `~`, the same way a partial token total is marked.
    var approximate: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 {
                Text("\(approximate ? "~" : "")+\(added)").foregroundStyle(.green)
            }
            if removed > 0 {
                Text("\(approximate && added == 0 ? "~" : "")−\(removed)").foregroundStyle(.red)
            }
            if added == 0 && removed == 0 {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }
}
