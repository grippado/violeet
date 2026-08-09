// Turning `git diff` output into something a surface can walk.
//
// # Lenient on purpose
//
// This parser never throws and never returns an error. Unified diff is a format
// with a dozen producers — `git diff`, `git format-patch`, `diff -u`, whatever
// a tool pasted into a transcript — and they disagree at the edges: some emit
// `diff --git`, some only `---`/`+++`; some carry timestamps after the paths,
// some carry index lines, some carry neither. A parser that rejected the ones
// it did not recognise would turn a cosmetic difference into an empty pane.
//
// So the rule is: recover, never reject. A malformed `@@` header ends the hunk
// and the scan continues; unknown header lines are skipped; text before the
// first file header is ignored. The worst outcome is a diff that shows less
// than it could, which is a reader scrolling to the file in the tree — not a
// reader looking at a blank panel and concluding the feature is broken.
//
// # Counts are read but not trusted
//
// The `@@ -a,b +c,d @@` counts say how long the hunk is, and this uses them to
// know when to stop. It also stops on anything that cannot belong to a hunk,
// because a truncated patch — and the daemon truncates lists, so truncation is
// a fact of life here — has counts that outlive its lines. Believing the header
// over the text would swallow the next file's header into this file's hunk.

import Foundation

enum UnifiedDiffParser {
    /// Every file described by one patch, in the order it listed them.
    ///
    /// Pure over its argument, which is the whole reason it takes a `String`
    /// and not a path: every awkward shape in the tests is a literal, and none
    /// of them need a repository to exist.
    static func parse(_ patch: String) -> [FileDiff] {
        var files: [FileDiff] = []
        // `git diff` on a CRLF working tree carries the `\r` into the patch. It
        // is transport, like the `+` prefix, and belongs to neither the content
        // nor the comparison — so it goes before anything is split.
        //
        // Folded rather than trimmed per line because Swift reads `\r\n` as one
        // `Character`: splitting on `"\n"` does not see it, and a CRLF patch
        // arrives as a single line that matches no header at all.
        let normalised = patch.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalised.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }

        var pending: PendingFile?
        var index = 0

        // Close whatever file is open and add it, if it says anything at all.
        func flush() {
            if let file = pending?.finished() { files.append(file) }
            pending = nil
        }

        while index < lines.count {
            let line = lines[index]

            if line.hasPrefix("diff --git ") {
                flush()
                pending = PendingFile(paths: gitHeaderPaths(line))
                index += 1
                continue
            }

            if line.hasPrefix("--- ") {
                // A patch with no `diff --git` line — `diff -u` output, or a
                // hand-rolled patch. The `---` is the only file boundary there
                // is, so it has to open a file when one is not already open on
                // its own header.
                if pending == nil || pending?.sawOldPath == true {
                    flush()
                    pending = PendingFile(paths: nil)
                }
                pending?.applyOldPath(headerPath(line.dropFirst(4)))
                index += 1
                continue
            }

            if line.hasPrefix("+++ ") {
                pending?.applyNewPath(headerPath(line.dropFirst(4)))
                index += 1
                continue
            }

            if line.hasPrefix("@@") {
                guard var file = pending, let header = HunkHeader(line) else {
                    index += 1
                    continue
                }
                let (hunk, next) = readHunk(header: header, lines: lines, from: index + 1)
                file.hunks.append(hunk)
                pending = file
                index = next
                continue
            }

            if pending != nil {
                pending?.applyMetadata(line)
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                // Bare `Binary files a/x and b/x differ`, with no `diff --git`
                // above it. Rare, but it is all the information there is about
                // that file and dropping it loses the file entirely.
                var file = PendingFile(paths: binaryHeaderPaths(line))
                file.applyMetadata(line)
                pending = file
            }
            index += 1
        }

        flush()
        return files
    }

    // MARK: - One hunk

    /// Reads lines until the hunk is spent, and says where it stopped.
    private static func readHunk(
        header: HunkHeader,
        lines: [String],
        from start: Int
    ) -> (DiffHunk, Int) {
        var body: [DiffLine] = []
        var oldNumber = header.oldStart
        var newNumber = header.newStart
        var oldLeft = header.oldCount
        var newLeft = header.newCount
        var index = start

        while index < lines.count {
            let line = lines[index]

            if oldLeft <= 0 && newLeft <= 0 {
                // Spent, except for a trailing no-newline marker, which git
                // prints after the last line and which the header never counts.
                if line.hasPrefix("\\") {
                    markLastLineUnterminated(&body)
                    index += 1
                }
                break
            }

            if line.hasPrefix("\\") {
                markLastLineUnterminated(&body)
                index += 1
                continue
            }

            let first = line.first
            let text = line.isEmpty ? "" : String(line.dropFirst())

            switch first {
            case "+":
                body.append(
                    DiffLine(origin: .added, text: text, oldNumber: nil, newNumber: newNumber))
                newNumber += 1
                newLeft -= 1
            case "-":
                body.append(
                    DiffLine(origin: .removed, text: text, oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
                oldLeft -= 1
            case " ", nil:
                // `nil` is an empty line. Some producers strip the trailing
                // space off an empty context line, and treating that as the end
                // of the hunk would cut every hunk at its first blank line.
                body.append(
                    DiffLine(
                        origin: .context, text: text, oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1
                newNumber += 1
                oldLeft -= 1
                newLeft -= 1
            default:
                // Not a hunk line. The counts lied — truncated patch, or the
                // next file's header. Give the hunk what it got and let the
                // outer scan re-read this line as a header.
                return (header.hunk(lines: body), index)
            }
            index += 1
        }

        return (header.hunk(lines: body), index)
    }

    /// `\ No newline at end of file` applies to the line above it.
    private static func markLastLineUnterminated(_ body: inout [DiffLine]) {
        guard let last = body.last else { return }
        body[body.count - 1] = DiffLine(
            origin: last.origin,
            text: last.text,
            oldNumber: last.oldNumber,
            newNumber: last.newNumber,
            lacksTrailingNewline: true
        )
    }

    // MARK: - Headers

    /// The `a/x b/y` pair off a `diff --git` line.
    ///
    /// Best-effort, and only a fallback: `---`/`+++` are authoritative when the
    /// patch carries them. A path with a space in it is genuinely ambiguous on
    /// this line — git quotes those, and the quoted form is handled — so an
    /// unquoted pair is split on the `b/` that starts the second half.
    private static func gitHeaderPaths(_ line: String) -> (String, String)? {
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("\"") {
            let parts = rest.split(separator: "\"").map(String.init).filter { $0 != " " }
            guard parts.count >= 2 else { return nil }
            return (stripPrefix(parts[0]), stripPrefix(parts[1]))
        }
        let fields = rest.split(separator: " ").map(String.init)
        guard fields.count >= 2 else { return nil }
        return (stripPrefix(fields[0]), stripPrefix(fields[fields.count - 1]))
    }

    private static func binaryHeaderPaths(_ line: String) -> (String, String)? {
        let rest = line.dropFirst("Binary files ".count)
        guard let range = rest.range(of: " and ") else { return nil }
        let old = String(rest[rest.startIndex..<range.lowerBound])
        var new = String(rest[range.upperBound...])
        if new.hasSuffix(" differ") { new.removeLast(" differ".count) }
        return (stripPrefix(old), stripPrefix(new))
    }

    /// A `---`/`+++` path: prefix off, trailing timestamp off, `/dev/null` as
    /// the absence it means.
    private static func headerPath(_ raw: Substring) -> String? {
        var text = String(raw)
        // `diff -u` appends a tab and a timestamp. Git does not, so splitting
        // on the tab is safe for both and is the only separator that cannot
        // appear unescaped inside a path git printed.
        if let tab = text.firstIndex(of: "\t") { text = String(text[text.startIndex..<tab]) }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        guard text != "/dev/null", !text.isEmpty else { return nil }
        return stripPrefix(text)
    }

    /// Drops git's synthetic `a/` and `b/` roots.
    ///
    /// Only those two spellings, and only at the front: a real directory named
    /// `a` exists in plenty of repositories, but git writes it as `a/a/…`, so
    /// removing exactly one leading component is right in both cases.
    private static func stripPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }
}

// MARK: - Accumulators

/// A file being read, before it knows everything about itself.
///
/// Separate from `FileDiff` because a `FileDiff` is immutable by design and
/// parsing is inherently incremental: the status arrives on one line, the paths
/// on the next two, the hunks after that. Rather than weaken the shipped type
/// to suit the parser, the parser keeps its own scratch and builds the real
/// thing once, at the end.
private struct PendingFile {
    var oldPath: String?
    var newPath: String?
    var sawOldPath = false
    var declaredStatus: DiffFileStatus?
    var isBinary = false
    var hunks: [DiffHunk] = []

    init(paths: (String, String)?) {
        oldPath = paths?.0
        newPath = paths?.1
    }

    mutating func applyOldPath(_ path: String?) {
        sawOldPath = true
        oldPath = path
        if path == nil { declaredStatus = declaredStatus ?? .added }
    }

    mutating func applyNewPath(_ path: String?) {
        newPath = path
        if path == nil { declaredStatus = declaredStatus ?? .removed }
    }

    /// The extended header lines git puts between `diff --git` and `---`.
    mutating func applyMetadata(_ line: String) {
        if line.hasPrefix("new file mode") {
            declaredStatus = .added
        } else if line.hasPrefix("deleted file mode") {
            declaredStatus = .removed
        } else if line.hasPrefix("rename from ") {
            declaredStatus = .renamed
            oldPath = String(line.dropFirst("rename from ".count))
        } else if line.hasPrefix("rename to ") {
            declaredStatus = .renamed
            newPath = String(line.dropFirst("rename to ".count))
        } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
            isBinary = true
        }
    }

    /// `nil` when the header said nothing at all — a stray `diff --git` with no
    /// body and no paths is noise, not a file.
    func finished() -> FileDiff? {
        guard oldPath != nil || newPath != nil else { return nil }
        let status: DiffFileStatus
        if let declared = declaredStatus {
            status = declared
        } else if oldPath == nil {
            status = .added
        } else if newPath == nil {
            status = .removed
        } else if let old = oldPath, let new = newPath, old != new {
            status = .renamed
        } else {
            status = .modified
        }
        return FileDiff(
            oldPath: oldPath,
            newPath: newPath,
            status: status,
            content: isBinary ? .binary : .text(hunks)
        )
    }
}

/// `@@ -oldStart,oldCount +newStart,newCount @@ heading`.
private struct HunkHeader {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let heading: String

    init?(_ line: String) {
        guard let close = line.range(of: "@@", range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex)
        else { return nil }
        let ranges = line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound]
            .split(separator: " ")
            .map(String.init)
        guard ranges.count >= 2,
            let old = HunkHeader.range(ranges[0], sign: "-"),
            let new = HunkHeader.range(ranges[1], sign: "+")
        else { return nil }
        oldStart = old.start
        oldCount = old.count
        newStart = new.start
        newCount = new.count
        heading = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// `-12,4`, or `-12` when the count is 1 and git leaves it out.
    private static func range(_ field: String, sign: Character) -> (start: Int, count: Int)? {
        guard field.first == sign else { return nil }
        let body = field.dropFirst()
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let start = Int(parts[0]) else { return nil }
        if parts.count == 1 { return (start, 1) }
        guard let count = Int(parts[1]) else { return nil }
        return (start, count)
    }

    func hunk(lines: [DiffLine]) -> DiffHunk {
        DiffHunk(
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            heading: heading,
            lines: lines
        )
    }
}
