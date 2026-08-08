// Showing a file that is not text.
//
// # The bug this is really about
//
// Every row in the directory tree opened in the user's editor, including the
// rows that are a PDF, a PNG or a zip. Vim opens those too — as bytes. The
// reader gets a screen of `^@^@^H` for a file they can see the name of, and the
// only way out is quitting an editor they did not want.
//
// # Why QuickLook and not a viewer
//
// macOS already renders these, in a panel every user has opened with the space
// bar since 2007. Reusing it means PDFs, images, video, audio, archives and
// anything a third-party generator supports all work on the first day, and none
// of them are this app's code to maintain.
//
// The alternative — a `PDFView` here, an `NSImageView` there — is a viewer per
// format, each with its own zoom, its own scroll, its own bugs, to reimplement
// something the machine ships.
//
// # What counts as "not text"
//
// A list, not a sniff of the bytes. Reading the head of every file the pointer
// passes to decide how to open it is work done on the chance it is needed, and
// it gets the interesting cases wrong anyway: a `.json` is text, a `.plist` may
// be either, and a file with no extension is usually source. The list holds the
// formats where opening in an editor is *certainly* wrong, and everything else
// keeps the old behaviour — which is the safe direction to be wrong in, since
// an editor on a text file is what the reader asked for.

import AppKit
import QuickLookUI

enum FilePreview {
    /// Formats an editor cannot usefully show.
    ///
    /// Deliberately short. Anything not in here opens in the editor, which is
    /// right for every text format and merely unhelpful for a rare binary one.
    private static let previewable: Set<String> = [
        // Documents.
        "pdf", "rtf", "rtfd", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "pages", "numbers", "key", "epub",
        // Images.
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif",
        "bmp", "ico", "icns", "psd", "svg",
        // Audio and video.
        "mp4", "mov", "m4v", "avi", "mkv", "webm",
        "mp3", "wav", "aac", "flac", "m4a", "aiff",
        // Bundles and archives, where the panel shows what is inside.
        "zip", "dmg", "pkg", "app", "ipa",
        // Fonts.
        "ttf", "otf", "woff", "woff2",
    ]

    /// Whether this file should be previewed rather than edited.
    ///
    /// A pure function of the name, so the rule is testable without a file.
    static func canPreview(_ name: String) -> Bool {
        previewable.contains((name as NSString).pathExtension.lowercased())
    }

    /// Show it in the system's QuickLook panel.
    ///
    /// The panel is shared by the whole system, so this hands it a source and
    /// asks for it — the same thing the Finder does. Closing is the user's
    /// (escape, or the panel's own button); nothing here holds it open.
    @MainActor
    static func show(path: String) {
        guard let panel = QLPreviewPanel.shared() else { return }
        source.url = URL(fileURLWithPath: path)
        panel.dataSource = source
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// One long-lived source, because `QLPreviewPanel` does not retain the one
    /// it is given: a fresh object per call is deallocated while the panel is
    /// still asking it questions, and the panel comes up blank.
    @MainActor private static let source = Source()

    /// `@preconcurrency` because `QLPreviewPanelDataSource` predates Swift
    /// concurrency and is not annotated. The panel only ever calls these on the
    /// main thread — it is AppKit — so the isolation is real; the compiler
    /// simply has no way to be told that by the framework.
    @MainActor
    private final class Source: NSObject, @preconcurrency QLPreviewPanelDataSource {
        var url: URL?

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
            url == nil ? 0 : 1
        }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            url as QLPreviewItem?
        }
    }
}
