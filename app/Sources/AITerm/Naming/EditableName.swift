// A name you can rename in place: the sidebar card's headline, and the row of
// a tab that has no session.
//
// # The keyboard, again
//
// The settings panel's rule holds here and is harder to keep: a control that
// takes first responder must give it back, or the user types their next
// command into nothing and the terminal looks exactly as it did when it was
// working. The difference is that this control *has* to take focus — it is a
// text field, that is the point — so the discipline moves to the exits.
//
// There are four ways out and all four end in `onCommit`:
//
//  - Return commits the name
//  - Escape cancels and restores what was there
//  - clicking elsewhere cancels (the same as Escape, deliberately: a name
//    half-typed and abandoned is not a name)
//  - the row going away underneath the field
//
// `onCommit` is what calls `AppState.focusTerminal()`. Nothing else in this
// file touches the responder chain.
//
// # The lock
//
// A renamed tab is locked: nothing automatic overwrites it. That has to be
// visible, or the user cannot tell why a tab that is running `btop` is not
// called btop — and, worse, cannot guess that "back to automatic" is the thing
// they want. It is a small filled pin, at the same weight as the surrounding
// secondary text: present, not shouting. The full explanation is in the
// tooltip, where a sentence fits.

import SwiftUI

struct EditableName: View {
    let name: ResolvedName
    /// The text to show. Not always `name.text`: the sidebar qualifies
    /// colliding names, and what the user sees is what they should be editing.
    let display: String
    let font: Font
    let colour: Color

    /// Commit a new name. Empty means the user cleared the field, which is
    /// treated as a cancel rather than as a rename to nothing.
    let onRename: (String) -> Void
    /// Back to automatic naming.
    let onRelease: () -> Void
    /// Called on every exit from editing, committed or not. Hands the keyboard
    /// back to the terminal.
    let onFinish: () -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                field
            } else {
                label
            }
        }
        .contextMenu {
            Button("Rename…") { beginEditing() }
            Button("Use automatic name") { onRelease() }
                // A tab that is already automatic has nothing to go back to,
                // and an enabled menu item that does nothing is a worse answer
                // than a disabled one.
                .disabled(!name.isLocked)
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Text(display)
                .font(font)
                .foregroundStyle(colour)
                .lineLimit(1)
                .truncationMode(.middle)
            if name.isLocked {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .help("Renamed by you. Automatic naming will not change it — right-click for “Use automatic name”.")
            }
        }
        .contentShape(Rectangle())
        // A double click, on the name itself. Single click belongs to the row
        // — it switches tabs — and stealing it would mean every click into a
        // session opened an editor.
        .onTapGesture(count: 2) { beginEditing() }
    }

    private var field: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
            .focused($focused)
            .onSubmit { commit() }
            // Escape. `onExitCommand` is the SwiftUI spelling and it only
            // arrives while the field has focus, which is exactly when it
            // should.
            .onExitCommand { cancel() }
            .onChange(of: focused) { _, hasFocus in
                // Clicking away without pressing Return. Cancel rather than
                // commit: the user moved on, and committing a half-typed name
                // would lock the tab to it.
                if !hasFocus, editing { cancel() }
            }
            .onAppear { focused = true }
    }

    private func beginEditing() {
        // Seeded with the name in force, so renaming an automatic name is an
        // edit of it rather than typing from nothing.
        draft = name.text
        editing = true
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        if !trimmed.isEmpty, trimmed != name.text {
            onRename(trimmed)
        }
        onFinish()
    }

    private func cancel() {
        editing = false
        onFinish()
    }
}
