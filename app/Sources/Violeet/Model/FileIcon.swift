// A glyph and a colour for a row in the directory tree.
//
// # Why SF Symbols and not an icon set
//
// The obvious reference is VS Code's file icons, and the obvious way to get
// them is to vendor Seti or Material Icons: several hundred SVGs, a licence
// file, and a build step to turn them into something `NSImage` can read.
//
// SF Symbols is already on the machine, scales as vector to any size the user's
// interface font asks for, and recolours itself for light and dark without a
// second cut of every file. It is also the vocabulary the rest of this window
// already speaks — the sidebar, the menu bar, the settings panel — and a tree
// drawn in a different icon language reads as a component someone pasted in.
//
// The trade is real and worth naming: SF Symbols has no logo for Rust or Swift
// or Go, so those languages share `curlybraces` and are told apart by colour
// and by the filename that is right there. An icon set would give each its own
// mark. That is a nicer tree and a much larger app, and the filename is doing
// most of the work either way.
//
// # Colour carries the category, never the meaning
//
// Two files with the same glyph and different colours are still two files whose
// names you can read. Nothing here is only-colour: the name is always present
// and always the primary signal, which is the same two-channel rule the `A`/`U`/
// `D` marks follow one panel over.

import SwiftUI

/// What to draw beside a name in the tree.
struct FileIcon: Equatable {
    let symbol: String
    /// `nil` means "take the row's own colour" — used for the plainest files,
    /// so a tree of unremarkable text does not turn into a colour chart.
    let tint: Color?

    init(_ symbol: String, _ tint: Color? = nil) {
        self.symbol = symbol
        self.tint = tint
    }
}

enum FileIcons {
    /// The icon for one entry.
    ///
    /// A pure function of the name and one boolean, so every mapping in here is
    /// testable without a filesystem — the same split `DirectoryListing.ordered`
    /// makes for the same reason.
    static func icon(for name: String, isDirectory: Bool) -> FileIcon {
        if isDirectory { return folderIcon(named: name) }
        return fileIcon(named: name)
    }

    // MARK: - Folders

    /// Named folders first, then the generic one.
    ///
    /// Only folders whose name means the same thing across projects are
    /// special-cased. A `src` is a `src` everywhere; a folder called `data`
    /// could be anything, so it stays generic rather than being given a
    /// confident wrong icon.
    private static func folderIcon(named name: String) -> FileIcon {
        switch name.lowercased() {
        case ".git":
            return FileIcon("point.3.filled.connected.trianglepath.dotted", .orange)
        case ".github", ".gitlab":
            return FileIcon("checkmark.seal", .secondary)
        case "node_modules", "vendor", "pods", ".venv", "venv", "target", ".build":
            // Dependencies and build output: things you scroll past, not into.
            return FileIcon("shippingbox", .secondary)
        case "src", "sources", "lib", "app", "crates":
            return FileIcon("folder.badge.gearshape", .blue)
        case "test", "tests", "spec", "__tests__":
            return FileIcon("checkmark.circle", .green)
        case "docs", "doc", "documentation":
            return FileIcon("book", .cyan)
        case "assets", "images", "img", "public", "static":
            return FileIcon("photo.on.rectangle", .pink)
        case "scripts", "bin", "tools":
            return FileIcon("terminal", .yellow)
        case ".claude", ".ai":
            return FileIcon("sparkles", .purple)
        default:
            return FileIcon("folder", .blue)
        }
    }

    // MARK: - Files

    /// Whole filenames beat extensions, because the ones that matter have no
    /// useful extension: `Dockerfile`, `Makefile`, `README`.
    private static func fileIcon(named name: String) -> FileIcon {
        let lower = name.lowercased()

        switch lower {
        case "dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml":
            return FileIcon("shippingbox.fill", .blue)
        case "makefile", "justfile", "rakefile":
            return FileIcon("hammer", .orange)
        case "license", "license.md", "licence", "copying":
            return FileIcon("scroll", .yellow)
        case ".gitignore", ".gitattributes", ".gitmodules":
            return FileIcon("eye.slash", .orange)
        case "package.json", "cargo.toml", "package.swift", "go.mod", "pyproject.toml", "gemfile":
            return FileIcon("shippingbox", .red)
        case ".env", ".env.local", ".env.example":
            return FileIcon("key", .yellow)
        default:
            break
        }

        if lower.hasPrefix("readme") { return FileIcon("book.closed", .cyan) }
        if lower.hasPrefix("changelog") { return FileIcon("clock.arrow.circlepath", .cyan) }

        let ext = (lower as NSString).pathExtension
        switch ext {
        // Code. One glyph, told apart by colour and by the name beside it —
        // see the note at the top on why there is no per-language mark.
        case "swift":
            return FileIcon("swift", .orange)
        case "rs":
            return FileIcon("curlybraces", .orange)
        case "go":
            return FileIcon("curlybraces", .cyan)
        case "py":
            return FileIcon("curlybraces", .blue)
        case "rb":
            return FileIcon("curlybraces", .red)
        case "js", "mjs", "cjs":
            return FileIcon("curlybraces", .yellow)
        case "ts", "tsx":
            return FileIcon("curlybraces", .blue)
        case "jsx", "vue", "svelte":
            return FileIcon("curlybraces", .green)
        case "c", "h", "cpp", "hpp", "cc", "m", "mm", "java", "kt", "cs", "php":
            return FileIcon("curlybraces", .purple)
        case "lua", "vim":
            return FileIcon("curlybraces", .green)

        // Shell.
        case "sh", "bash", "zsh", "fish", "command":
            return FileIcon("terminal", .green)

        // Data and configuration.
        case "json", "yaml", "yml", "toml", "ini", "conf", "cfg", "plist", "xml":
            return FileIcon("list.bullet.rectangle", .yellow)
        case "sql", "db", "sqlite":
            return FileIcon("cylinder.split.1x2", .blue)
        case "csv", "tsv":
            return FileIcon("tablecells", .green)

        // Prose.
        case "md", "markdown", "mdx":
            return FileIcon("text.alignleft", .cyan)
        case "txt", "log":
            return FileIcon("doc.text", .secondary)
        case "pdf":
            return FileIcon("doc.richtext", .red)

        // Web.
        case "html", "htm":
            return FileIcon("chevron.left.forwardslash.chevron.right", .orange)
        case "css", "scss", "sass", "less":
            return FileIcon("paintbrush", .blue)

        // Media.
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "icns", "ico", "heic":
            return FileIcon("photo", .pink)
        case "mp4", "mov", "avi", "mkv", "webm":
            return FileIcon("film", .pink)
        case "mp3", "wav", "flac", "m4a", "aiff":
            return FileIcon("waveform", .pink)
        case "ttf", "otf", "woff", "woff2":
            return FileIcon("textformat", .purple)

        // Archives and binaries: things you do not open by reading.
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "dmg", "pkg":
            return FileIcon("archivebox", .secondary)
        case "lock":
            return FileIcon("lock", .secondary)

        default:
            // The plainest case takes no tint at all. A tree where every row is
            // coloured has no way left to say "this one is different".
            return FileIcon("doc")
        }
    }
}
