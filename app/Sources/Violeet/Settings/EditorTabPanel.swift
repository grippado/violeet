// What the panel says over a tab that is editing one file.
//
// It names the file rather than going blank, because "no files" and "this is not
// a thing that has files" are different facts — the same distinction the Files
// panel is built around, one level up. A blank panel here would read as a
// session that wrote nothing.
//
// # The three ways out
//
// A tab opened from a file list is a place you went, and every place you go
// needs a way back. There are three, and which ones appear depends on how you
// arrived:
//
//  · **Close** is always there. It is what the reader wanted when they asked
//    for a back button: the file is read, the tab has served its purpose.
//  · **Its session's files**, when the file came from a session's tree and that
//    session still exists.
//  · **The commit**, when the file is in a repository whose remote is one whose
//    web layout is known.
//
// # Why the history is here at all
//
// A file open in an editor is being read, and the first questions about a line
// you did not write are who wrote it and when. The panel beside the editor is
// where those belong; the alternative is leaving the editor to run `git log`
// on a file that is already on screen.
//
// See `FileHistory` for why the app is allowed to run git here when the Files
// panel refuses to, and for what happens to a file that has no history.

import AppKit
import SwiftUI

struct EditorTabPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var tab: TabModel
    let editing: EditorTab

    /// `nil` while the lookup is in flight and for every file that has no
    /// history — the two are the same to this view, which shows nothing either
    /// way. See `FileHistory` for why "no history" is ordinary.
    @State private var commit: FileCommit?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // The same icon the header, the tab and the panel row carry.
                // The name was the last place in the chain still bare, and it
                // is the largest rendering of it.
                let icon = FileIcons.icon(for: editing.name, isDirectory: false)
                Image(systemName: icon.symbol)
                    .appFont(.caption)
                    .foregroundStyle(icon.tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                Text(editing.name)
                    .appFont(.body, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(ProcessDirectory.abbreviated(editing.path))
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .help(editing.path)

            if let commit {
                Divider().padding(.vertical, 6)
                history(commit)
            }

            Divider().padding(.vertical, 6)
            ways(out: editing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        // Keyed on the path so opening a different file in the same panel looks
        // it up again rather than showing the previous file's commit.
        .task(id: editing.path) {
            let path = editing.path
            // Off the main actor: this spawns a process, and the window must
            // not be inside that wait.
            commit = await Task.detached(priority: .userInitiated) {
                FileHistory.lastCommit(forFileAt: path)
            }.value
        }
    }

    // MARK: - History

    /// The last commit that touched this file.
    ///
    /// The subject first and largest, because it is the sentence that says what
    /// happened; the hash, author and date are how you find it again. That is
    /// the same order a commit is read in everywhere else.
    private func history(_ commit: FileCommit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.subject)
                .appFont(.caption)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                // The hash is a link when the remote is one we recognise, and
                // plain text when it is not — never a link that guesses. See
                // `GitRemote.commitURL`.
                if let url = commit.url {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            hostMark(for: url.host)
                            Text(commit.shortHash)
                                .appFont(.small)
                                .monospaced()
                        }
                    }
                    .pointingHand()
                    .help("Open \(commit.shortHash) at \(url.host ?? "the remote")")
                } else {
                    Text(commit.shortHash)
                        .appFont(.small)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .help("This repository has no remote whose commit pages are known.")
                }

                Text(commit.author)
                    .appFont(.small)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                // The date itself, not "last year".
                //
                // Relative reads well for something that happened this week and
                // stops meaning anything past that: "last year" covers thirteen
                // months and is the answer to a question nobody asked. A commit
                // date is a fact you look up in order to go and find something
                // else — a release, a ticket, another commit near it — and for
                // that the date is the useful form.
                //
                // Abbreviated month rather than numeric: `7 Aug 2026` is
                // unambiguous in every locale, which `08/07` is not.
                //
                // With the time, because a day is not fine enough on the days
                // that matter. Several commits land on one date and the
                // question is which came first — release, revert, follow-up
                // fix — and a date alone cannot answer it. The seconds stay in
                // the tooltip; a minute is as close as anyone reads.
                Text(commit.date.formatted(
                    .dateTime.day().month(.abbreviated).year().hour().minute()
                ))
                    .appFont(.small)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(commit.date.formatted(date: .complete, time: .standard))
            }
        }
    }

    /// Whose forge this commit lives on.
    ///
    /// Says where the link goes before it is followed, which a bare hash cannot:
    /// the same seven characters mean a different page depending on the remote,
    /// and this row is often the only place the remote is named at all.
    ///
    /// Real artwork where there is real artwork, and an honest generic where
    /// there is not — a made-up glyph standing in for a host is the same class
    /// of lie as a made-up commit URL. GitHub ships its octicon in the project's
    /// own pages, so that one is the mark; everything else gets the link glyph
    /// and names the host on hover.
    @ViewBuilder
    private func hostMark(for host: String?) -> some View {
        if host == "github.com", let mark = Self.githubMark {
            Image(nsImage: mark)
        } else {
            Image(systemName: "link")
                .appFont(.small)
        }
    }

    /// Loaded once. `isTemplate` so macOS recolours it to match the row in
    /// both appearances — the artwork is black, and black on a dark panel is a
    /// hole where an icon should be.
    private static let githubMark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "host-github", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        // Points, not pixels: the file is 256px so it stays sharp on Retina,
        // and this is the size it draws at beside the commit line.
        //
        // Sized with that line rather than fixed. The whole row sits one rung
        // up the type scale from where it started — a hash you may want to read
        // out and a name you may want to recognise are not glyph-sized things —
        // and a mark that stayed put while the text around it grew would read
        // as having shrunk.
        image.size = NSSize(width: 13, height: 13)
        image.isTemplate = true
        return image
    }()

    // MARK: - Ways out

    @ViewBuilder
    private func ways(out editing: EditorTab) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Closing the tab is `AppState.closeTab`, the same path ⌘W takes —
            // so the editor is asked to quit cleanly and the daemon is told the
            // tab is gone. A button that only removed the row would leave both
            // a live process and a daemon believing in a tab that is not there.
            QuietButton(action: { state.closeTab(tab.tabID) }) {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle")
                        .appFont(.micro)
                    Text("Close this tab")
                }
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
            .pointingHand()
            .help("Close the tab and return to what you were doing (⌘W)")

            // Reveal, not open. `activateFileViewerSelecting` puts the file on
            // screen *selected in its folder*, which is what someone asking for
            // Finder wants: the neighbours, the size, the ability to drag it
            // somewhere. `NSWorkspace.open` would hand it to whichever app owns
            // the extension — for a `.swift` an IDE, for a `.md` a note-taking
            // app — which is the same wrong turn `openInEditor` documents
            // refusing to take.
            QuietButton(action: {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: editing.path)
                ])
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .appFont(.micro)
                    Text("Reveal in Finder")
                }
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
            .pointingHand()
            .help("Show \(editing.name) in its folder.")

            if let owner = editing.sessionID, let card = state.sessions[owner] {
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
            } else if editing.sessionID != nil {
                // Named a session, and it is gone. Only sayable when there was
                // one: a file opened from a directory tree never had a session,
                // and telling that reader a session ended would be inventing one
                // for them to wonder about.
                Text("Opened from a session that has since ended.")
                    .appFont(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
