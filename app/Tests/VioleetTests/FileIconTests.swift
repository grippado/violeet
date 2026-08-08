// The mapping from a filename to a glyph.
//
// A pure function over a string, tested as one. The cases worth pinning are the
// ones a naive `pathExtension` lookup gets wrong: files whose meaning is in the
// whole name (`Dockerfile`, `Makefile`), files whose name *starts* with the
// meaning (`README.something`), and dotfiles that have no extension at all.

import SwiftUI
import Testing

@testable import Violeet

@Suite("File icons")
struct FileIconTests {
    /// The whole name wins over the extension, because the files that matter
    /// most here have no useful extension.
    @Test("a whole filename beats its extension")
    func wholeNamesWin() {
        #expect(FileIcons.icon(for: "Dockerfile", isDirectory: false).symbol == "shippingbox.fill")
        #expect(FileIcons.icon(for: "Makefile", isDirectory: false).symbol == "hammer")
        #expect(FileIcons.icon(for: "package.json", isDirectory: false).symbol == "shippingbox")
    }

    /// `.gitignore` is all extension and no name as far as `pathExtension` is
    /// concerned, which is exactly how it would get the generic icon.
    @Test("a dotfile is matched by its whole name")
    func dotfilesMatch() {
        #expect(FileIcons.icon(for: ".gitignore", isDirectory: false).symbol == "eye.slash")
        #expect(FileIcons.icon(for: ".env", isDirectory: false).symbol == "key")
    }

    /// `README`, `README.md` and `readme.txt` are the same document.
    @Test("a readme is a readme whatever it is called")
    func readmePrefix() {
        for name in ["README", "README.md", "readme.txt", "Readme.markdown"] {
            #expect(FileIcons.icon(for: name, isDirectory: false).symbol == "book.closed", "\(name)")
        }
    }

    @Test("case does not decide the icon")
    func caseInsensitive() {
        #expect(
            FileIcons.icon(for: "AppState.SWIFT", isDirectory: false).symbol
                == FileIcons.icon(for: "appstate.swift", isDirectory: false).symbol
        )
    }

    /// A directory and a file with the same name are different things.
    @Test("the same name means different icons for a folder and a file")
    func directoriesAreNotFiles() {
        let folder = FileIcons.icon(for: "src", isDirectory: true)
        let file = FileIcons.icon(for: "src", isDirectory: false)
        #expect(folder.symbol != file.symbol)
        #expect(folder.symbol == "folder.badge.gearshape")
    }

    /// Only folders whose name means the same thing everywhere are special.
    /// Anything else gets the plain folder rather than a confident wrong guess.
    @Test("an ordinary folder stays an ordinary folder")
    func unknownFolderIsGeneric() {
        #expect(FileIcons.icon(for: "data", isDirectory: true).symbol == "folder")
        #expect(FileIcons.icon(for: "whatever", isDirectory: true).symbol == "folder")
    }

    /// The plainest file takes no tint. A tree where every row is coloured has
    /// no way left to say "this one is different".
    @Test("an unknown file is untinted")
    func unknownFileHasNoTint() {
        let icon = FileIcons.icon(for: "notes.unknownext", isDirectory: false)
        #expect(icon.symbol == "doc")
        #expect(icon.tint == nil)
    }

    /// Every row has a glyph. A blank cell in the icon column would make the
    /// names ragged, which is the thing the column exists to prevent.
    @Test("nothing comes back without an icon")
    func everythingHasAnIcon() {
        for name in ["", ".", "..", "a", "no-extension", ".hidden", "x.y.z"] {
            #expect(!FileIcons.icon(for: name, isDirectory: false).symbol.isEmpty, "\(name)")
            #expect(!FileIcons.icon(for: name, isDirectory: true).symbol.isEmpty, "\(name) as folder")
        }
    }
}
