// Where a tab is, as a tree you can open files from.
//
// # The empty state this replaces
//
// A tab with no agent used to get a sentence: its name, its path, and "no files
// to list". True about the daemon and useless to the reader — the panel had the
// one fact that matters (a directory) and drew nothing with it. The Files panel
// beside a session is a list you can act on; beside a shell it was a label.
//
// So: the same rows, the same click, over the filesystem instead of over a
// session's writes. Clicking a file opens it in a tab running the user's editor
// through `AppState.openInEditor` — the identical path the session tree uses,
// including the gitsigns jump, because "open this file" should not mean two
// different things one panel apart.
//
// # Following the `cd`
//
// `TabModel.currentDirectory` is `@Published` and kept current by the session's
// poller, so the tree redraws on every `cd` for free. The root is rebuilt
// rather than diffed — `.id` on the path — because a different directory is a
// different tree, and carrying the old expansion state into it would leave
// folders open that the new root does not have.
//
// # Lazy, and why it has to be
//
// Each folder reads its own children when it is first shown, not when its
// parent is. The eager version walks the tree at `cd`, which for `~` means
// stat-ing a machine's worth of files to draw twelve rows — and the directory a
// terminal opens in is very often exactly that big.
//
// # When it re-reads
//
// On `cd`, and when the tab's foreground process changes. The second is the
// cheap version of watching the filesystem: a command that creates a file is a
// program that started and then exited, and both edges land here. It costs one
// read of the folders currently on screen, and it means `touch x` in the
// terminal puts `x` in the tree beside it.
//
// Not an `FSEvents` stream. That is a watcher per open folder, torn down and
// rebuilt on every expansion, to catch the writes that happen while nothing is
// running — which in a terminal is nearly none of them.

import AppKit
import SwiftUI

struct DirectoryTree: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var tab: TabModel
    /// Observed, not read through `AppState`: `preferences` is a `let` there, so
    /// a change inside it does not redraw anything that only holds the state.
    @ObservedObject var preferences: Preferences

    /// Bumped to make the visible folders read themselves again. See the note
    /// above on what counts as a reason to.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                // `VStack` and **not** `LazyVStack`, which is the difference
                // between a tree and an empty panel.
                //
                // A lazy stack only materialises children that have height, and
                // the root branch has none until its read returns — so the read
                // waited for a layout that was waiting for the read, and the
                // panel stayed blank for ever. Measured on screen: header
                // drawn, eye button drawn, nothing under them.
                //
                // Nothing is lost by dropping it. The laziness that matters is
                // per folder — each one reads itself when it is opened, and a
                // collapsed folder costs a row.
                VStack(alignment: .leading, spacing: 2) {
                    DirectoryBranch(
                        tab: tab,
                        path: tab.currentDirectory,
                        root: tab.currentDirectory,
                        depth: 0,
                        includingHidden: preferences.showHiddenFiles,
                        generation: generation
                    )
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                // A different directory, or a different rule about what is in
                // one, is a different tree. Rebuilding drops the expansion
                // state on purpose: it belonged to the old root.
                .id("\(tab.currentDirectory)#\(preferences.showHiddenFiles)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: tab.foregroundProcess) { generation += 1 }
    }

    // MARK: - Header

    /// Whose directory this is, and the one control the tree has.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(state.name(for: tab).text)
                .appFont(.body, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .appFont(.micro)
                Text(ProcessDirectory.abbreviated(tab.currentDirectory))
                    .lineLimit(1)
                    // The tail of a path is the part that identifies it — the
                    // same choice the session header makes.
                    .truncationMode(.head)

                Spacer(minLength: 6)

                QuietButton(action: { preferences.showHiddenFiles.toggle() }) {
                    Image(systemName: preferences.showHiddenFiles ? "eye" : "eye.slash")
                        .appFont(.caption)
                        .foregroundStyle(preferences.showHiddenFiles ? Color.primary : Color.secondary)
                }
                .help(preferences.showHiddenFiles
                    ? "Hiding dotfiles."
                    : "Showing dotfiles.")
                .accessibilityLabel("Hidden files")
                .accessibilityValue(preferences.showHiddenFiles ? "shown" : "hidden")
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .help(tab.currentDirectory)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - One folder's children

/// The contents of one directory, read when this view first appears.
private struct DirectoryBranch: View {
    @ObservedObject var tab: TabModel
    let path: String
    /// The tree's root, carried down so a nested row can still say where it
    /// sits relative to what the reader is looking at.
    let root: String
    let depth: Int
    let includingHidden: Bool
    let generation: Int

    /// `nil` until the first read returns. Distinct from an empty
    /// `DirectoryContents`, which means the read finished and found nothing.
    @State private var contents: DirectoryContents?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let contents {
                if contents.unreadable {
                    note("Cannot be read")
                } else if contents.isEmpty {
                    note(includingHidden ? "Empty" : "Nothing but dotfiles")
                } else {
                    ForEach(contents.entries) { entry in
                        DirectoryRow(
                            tab: tab,
                            entry: entry,
                            root: root,
                            depth: depth,
                            includingHidden: includingHidden,
                            generation: generation
                        )
                    }
                }
            } else {
                // Invisible, and not absent. This branch used to be empty while
                // the read was in flight, which produced an `EmptyView` — and
                // SwiftUI does not run modifiers on one, so the `.task` below
                // never fired and the read never happened. The panel drew its
                // header, its path and its eye button, and nothing else, for
                // ever. Measured on screen twice before the cause was found.
                //
                // A zero-height `Color.clear` is a real view with a real
                // lifecycle, so the task attaches to something. It occupies no
                // space, which is what the loading state should look like: a
                // spinner for a syscall that returns in microseconds is a flash
                // of chrome, and on the slow mount where it would be honest the
                // row it replaces is not what is being waited for anyway.
                Color.clear.frame(height: 0)
            }
        }
        // Re-runs when the generation changes, without tearing down the rows —
        // so a folder the user opened stays open across a re-read.
        .task(id: generation) {
            let path = path
            let includingHidden = includingHidden
            // Off the main actor: a directory on a slow mount takes as long as
            // it takes, and the window must not be inside that call.
            contents = await Task.detached(priority: .userInitiated) {
                DirectoryListing.read(path, includingHidden: includingHidden)
            }.value
        }
    }

    /// Said in the tree rather than beside it, at the depth it applies to, so a
    /// folder that opens onto nothing says so where the reader is looking.
    private func note(_ text: String) -> some View {
        Text(text)
            .appFont(.micro)
            .foregroundStyle(.tertiary)
            .padding(.leading, indent(for: depth) + 15)
            .padding(.vertical, 1)
    }
}

// MARK: - One row

/// A file or a folder. A file opens; a folder unfolds.
private struct DirectoryRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var tab: TabModel
    let entry: DirectoryEntry
    let root: String
    let depth: Int
    let includingHidden: Bool
    let generation: Int

    @State private var hovering = false

    /// Read from the tab rather than held here. See `TabModel.expandedFolders`
    /// for why: a `@State` here was destroyed every time the panel showed
    /// something else, which is what shut the tree on every file opened.
    private var expanded: Bool { tab.expandedFolders.contains(entry.path) }

    private var isOpen: Bool { state.isOpenInEditor(path: entry.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            QuietButton(action: activate) {
                HStack(spacing: 6) {
                    // The disclosure column, kept for files too. Without it the
                    // names in a folder do not line up with the names beside
                    // it, and the tree reads as two columns that drifted.
                    if entry.isDirectory {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .appFont(.micro)
                            .foregroundStyle(.secondary)
                            .frame(width: 9)
                    } else {
                        Text(" ").appFont(.micro).frame(width: 9)
                    }

                    // What kind of thing this is, before the name says which.
                    // Fixed width so the names line up into a column: an icon
                    // that sized itself to its own glyph would leave the
                    // filenames ragged, and a ragged column is one you read
                    // instead of scan. See `FileIcons` for what the colours
                    // mean and why there is no per-language mark.
                    icon
                        .frame(width: 14)

                    Text(entry.name)
                        .appFont(.caption)
                        // A folder is the structure and a file is the content;
                        // weight is what separates them at a glance without
                        // spending a second glyph on every row.
                        .fontWeight(entry.isDirectory ? .semibold : .regular)
                        .foregroundStyle(entry.isHidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Open in a tab. A glyph and not only the tint, the same
                    // two-channel rule the session tree's rows follow.
                    if isOpen {
                        Image(systemName: "macwindow")
                            .appFont(.micro)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)
                }
                .padding(.vertical, 1)
                .padding(.leading, indent(for: depth) + 4)
                .padding(.trailing, 4)
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
            .contextMenu { contextMenu }
            .help(helpText)
            .accessibilityLabel(entry.name)
            .accessibilityValue(entry.isDirectory ? (expanded ? "expanded folder" : "collapsed folder") : (isOpen ? "open in a tab" : ""))
            .accessibilityHint(entry.isDirectory
                ? "Shows what is in \(entry.name)."
                : FilePreview.canPreview(entry.name)
                ? "Previews \(entry.path)."
                : "Opens \(entry.path) in a new tab.")

            if entry.isDirectory, expanded {
                DirectoryBranch(
                    tab: tab,
                    path: entry.path,
                    root: root,
                    depth: depth + 1,
                    includingHidden: includingHidden,
                    generation: generation
                )
            }
        }
    }

    /// The right-click menu.
    ///
    /// # What is in it, and what is not
    ///
    /// Everything here either **reads** the row or **opens** it somewhere else.
    /// Nothing renames, moves or deletes, and that is a decision rather than a
    /// gap: this is a terminal, the shell one pane over does those better, and a
    /// destructive action a stray right-click can reach is a bad trade for a
    /// panel whose job is to show you where you are.
    ///
    /// The primary action leads, named for what it actually does — "Preview" for
    /// a PDF, "Open in Editor" for source — so the menu teaches what the click
    /// already does instead of duplicating it silently.
    ///
    /// Two paths, not one. Absolute is what another program needs; relative is
    /// what goes in a commit message, an issue or a sentence to a colleague, and
    /// picking one for the reader means they trim the other by hand every time.
    @ViewBuilder
    private var contextMenu: some View {
        if entry.isDirectory {
            Button(expanded ? "Collapse" : "Expand") { tab.toggleFolder(entry.path) }
            // A folder is somewhere you may want to *be*, not just look at. The
            // click never does this — moving the shell from a panel would be a
            // click over here silently changing what `ls` means over there —
            // but a menu item asked for by name is not a surprise.
            Button("New Tab Here") { _ = state.newTab(directory: entry.path) }
        } else if FilePreview.canPreview(entry.name) {
            Button("Preview") { FilePreview.show(path: entry.path) }
        } else {
            Button(isOpen ? "Go to Tab" : "Open in Editor") {
                state.openInEditor(path: entry.path, session: nil)
            }
        }

        Divider()

        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }

        Divider()

        Button("Copy Name") { copy(entry.name) }
        Button("Copy Relative Path") {
            copy(DirectoryListing.relativePath(of: entry.path, under: root))
        }
        Button("Copy Absolute Path") { copy(entry.path) }
    }

    /// Replace the pasteboard contents, which is what every other Copy on the
    /// system does — appending would make the second copy produce something
    /// nobody asked for.
    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// A folder unfolds in place; a file goes to the editor.
    ///
    /// A folder does **not** `cd` the tab. The tab's directory is the shell's,
    /// and the shell is where the user is typing — moving it from a panel would
    /// mean a click over here silently changing what `ls` means over there.
    private func activate() {
        if entry.isDirectory {
            tab.toggleFolder(entry.path)
        } else if FilePreview.canPreview(entry.name) {
            // A PDF or a PNG handed to vim is a screen of bytes and an editor
            // the reader has to quit. See `FilePreview`.
            FilePreview.show(path: entry.path)
        } else {
            state.openInEditor(path: entry.path, session: nil)
        }
    }

    /// The glyph for this entry, tinted by category.
    ///
    /// A dimmed row keeps its icon and loses its colour: the tint is a category
    /// and dotfiles are not a category, they are a row that is quieter than the
    /// rest.
    @ViewBuilder
    private var icon: some View {
        let file = FileIcons.icon(for: entry.name, isDirectory: entry.isDirectory)
        Image(systemName: file.symbol)
            .appFont(.caption)
            .foregroundStyle(entry.isHidden
                ? AnyShapeStyle(.tertiary)
                : (file.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)))
    }

    private var helpText: String {
        if entry.isDirectory { return entry.path }
        if FilePreview.canPreview(entry.name) {
            return "\(entry.path)\n\nClick to preview."
        }
        return isOpen
            ? "\(entry.path)\n\nOpen in a tab. Click to go to it."
            : "\(entry.path)\n\nClick to open in a new tab."
    }
}

/// How far in a row at this depth sits.
///
/// Bounded, because the tree has no depth limit and an unbounded indent turns a
/// deep folder into a column of whitespace with the names off the right edge.
/// Past the cap the nesting is carried by the chevrons alone, which is still
/// the structure, just not the ruler.
private func indent(for depth: Int) -> CGFloat {
    CGFloat(min(depth, 8)) * 10
}
