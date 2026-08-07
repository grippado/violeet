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
            } else {
                hint("No session selected", detail: "Run an agent in a tab, then click its card.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                        RootSection(root: root)
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
                    FileRow(entry: entry)
                }
            }
        }
        .padding(.bottom, 6)
    }
}

private struct FileRow: View {
    let entry: FileRoot.Entry

    var body: some View {
        HStack(spacing: 6) {
            if entry.change.created {
                // A letter and not only a colour: the same two-channel rule the
                // menu bar icon follows, for the same reader.
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
            }
            .appFont(.caption)

            Spacer(minLength: 6)
            DiffStat(added: entry.change.added, removed: entry.change.removed, approximate: false)
                .appFont(.micro)
        }
        .padding(.leading, 4)
        .help(entry.change.path)
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
