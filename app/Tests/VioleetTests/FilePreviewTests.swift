// Which files go to the preview panel instead of to the editor.
//
// The rule is a pure function of the name, so the list is a test rather than
// something to discover by opening a PDF in vim.
//
// The direction of the errors matters more than the list itself. Being wrong
// towards the editor is a text file opened in a text editor — which is what the
// reader asked for. Being wrong towards the panel means a source file that
// cannot be edited from the tree at all.

import Testing

@testable import Violeet

@Suite("File preview")
struct FilePreviewTests {
    /// The bug this exists for: these opened as bytes in vim.
    @Test("documents, images and media are previewed")
    func binariesPreview() {
        for name in [
            "report.pdf", "screenshot.png", "photo.JPG", "clip.mov",
            "song.mp3", "archive.zip", "Violeet.app", "icon.icns",
        ] {
            #expect(FilePreview.canPreview(name), "\(name) should preview")
        }
    }

    /// Everything a person edits keeps the old behaviour.
    @Test("source and prose still open in the editor")
    func textEdits() {
        for name in [
            "AppState.swift", "main.rs", "index.html", "styles.css",
            "README.md", "Cargo.toml", "notes.txt", "data.json",
            "Dockerfile", "Makefile", ".gitignore", "script.sh",
        ] {
            #expect(!FilePreview.canPreview(name), "\(name) should edit")
        }
    }

    /// A file with no extension is nearly always source, and the safe way to be
    /// wrong is towards the editor.
    @Test("no extension means the editor")
    func noExtensionEdits() {
        #expect(!FilePreview.canPreview("LICENSE"))
        #expect(!FilePreview.canPreview("some-file"))
        #expect(!FilePreview.canPreview(""))
    }

    /// `.PDF` off a camera or a Windows share is the same file as `.pdf`.
    @Test("the extension is matched whatever its case")
    func caseInsensitive() {
        #expect(FilePreview.canPreview("Report.PDF"))
        #expect(FilePreview.canPreview("IMAGE.PnG"))
    }

    /// Only the last extension decides, so `notes.pdf.md` is markdown.
    @Test("only the final extension counts")
    func lastExtensionWins() {
        #expect(!FilePreview.canPreview("notes.pdf.md"), "this is markdown about a pdf")
        #expect(FilePreview.canPreview("archive.tar.zip"))
    }
}
