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
//
// # Recovering leaves a mark
//
// "Recover, never reject" is only half a rule. The other half, added after the
// LAB-6 review found three ways to violate it, is that recovery has to be
// visible in the result: a hunk that stopped early carries `isTruncated`, and a
// file this parser cannot read at all comes back as `DiffContent.unsupported`
// instead of as an empty hunk list. An empty hunk list is what an unchanged file
// produces, so using it for failure means a conflicted file and an untouched
// file are the same value — the exact shape `docs/PROTOCOL.md` forbids when it
// requires a client to mark a partial answer rather than present it as whole.

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

            if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                // A merge conflict, as `git diff` renders it: one column per
                // parent, `@@@` headers, and body lines with two prefix columns.
                // Reading it properly is a separate feature; what matters here
                // is that it does not come out looking like a file with no
                // changes, which is what it did before — the single worst answer
                // for the one case the reader most needs the truth about.
                flush()
                pending = PendingFile(paths: combinedHeaderPaths(line))
                pending?.markUnsupported(Self.combinedReason)
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
                    // A header we cannot read means changes we cannot show. The
                    // file stays in the result — dropping it would lose the name
                    // too — but it stops claiming to be complete.
                    if pending != nil {
                        pending?.markUnsupported(
                            line.hasPrefix("@@@") ? Self.combinedReason : Self.badHunkHeaderReason)
                    }
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

    // MARK: - What we could not read, said in words

    /// A conflicted merge, `diff --cc` / `diff --combined` / `@@@`.
    static let combinedReason =
        "This is a combined diff from a merge with conflicts. Reading it needs one column per "
        + "parent, which this viewer does not do yet."

    /// An `@@` line whose ranges do not parse.
    static let badHunkHeaderReason =
        "A hunk header in this patch could not be read, so part of the change is missing."

    /// `old mode` / `new mode` and nothing else.
    static let modeOnlyReason =
        "Only this file's mode changed. There is no text difference to show."

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

        // The header's promise, minus what the body actually delivered. Read at
        // every exit rather than at one of them, because there are three and the
        // one that used to be missed — the text simply ending — is the one a
        // truncated patch takes.
        func finish() -> (DiffHunk, Int) {
            (header.hunk(lines: body, isTruncated: oldLeft > 0 || newLeft > 0), index)
        }

        while index < lines.count {
            let line = lines[index]

            // The next file starting is the end of this hunk, however hungry the
            // counts still are.
            if startsAFile(lines, at: index) { return finish() }

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
                return finish()
            }
            index += 1
        }

        // The text itself ran out. Same shortfall, and the exit that used to
        // report it as a complete hunk.
        return finish()
    }

    /// Whether the line at `index` can only be the start of the next file.
    ///
    /// `diff --git`, `diff --cc` and `diff --combined` are unambiguous: a hunk
    /// body line starts with `+`, `-`, a space or a backslash, never a `d`.
    ///
    /// `--- ` and `+++ ` are not, and that is the whole difficulty. Removing a
    /// line that reads `-- x` produces the body line `--- x`; adding `++ x`
    /// produces `+++ x`. Prefix alone cannot separate those from a file header,
    /// which is why the switch below used to read a header as a removal and an
    /// addition and swallow the next file whole — the failure the header of this
    /// file promises not to have, found by the LAB-6 review.
    ///
    /// What is not ambiguous is the *pair*: git emits `---` and `+++` together
    /// and adjacent, always. Requiring the pair costs one line of lookahead and
    /// leaves one wrong answer standing — a patch that removes `-- x` and adds
    /// `++ x` in that order, adjacent, inside one hunk — which is rarer than the
    /// truncated patch this exists to survive, and fails in the visible
    /// direction: the hunk ends early and is marked truncated, rather than
    /// quietly eating a file.
    private static func startsAFile(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ")
            || line.hasPrefix("diff --combined ")
        {
            return true
        }
        if line.hasPrefix("--- ") {
            return index + 1 < lines.count && lines[index + 1].hasPrefix("+++ ")
        }
        if line.hasPrefix("+++ ") {
            return index > 0 && lines[index - 1].hasPrefix("--- ")
        }
        return false
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
    /// this line — git quotes those with control characters in them, but not a
    /// plain space — so an unquoted pair is split on the ` b/` that starts the
    /// second half.
    ///
    /// Splitting on every space, which is what this did until the LAB-6 review,
    /// turns `a/my file.txt b/my file.txt` into `("my", "file.txt")`. Nobody was
    /// being hurt because `---`/`+++` overwrite it, but a comment describing an
    /// algorithm the code does not run is the defect this repository treats as a
    /// defect.
    ///
    /// The residual ambiguity is a path that itself contains ` b/`; the first
    /// occurrence wins, which is right whenever the old path does not contain
    /// one. There is no information on this line to do better with.
    private static func gitHeaderPaths(_ line: String) -> (String, String)? {
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("\"") {
            let parts = rest.split(separator: "\"").map(String.init).filter {
                $0.trimmingCharacters(in: .whitespaces) != ""
            }
            guard parts.count >= 2 else { return nil }
            return (stripPrefix(unquote(parts[0])), stripPrefix(unquote(parts[1])))
        }
        guard let split = rest.range(of: " b/") else {
            let fields = rest.split(separator: " ").map(String.init)
            guard fields.count >= 2 else { return nil }
            return (stripPrefix(fields[0]), stripPrefix(fields[fields.count - 1]))
        }
        let old = String(rest[rest.startIndex..<split.lowerBound])
        let new = String(rest[rest.index(after: split.lowerBound)...])
        return (stripPrefix(old), stripPrefix(new))
    }

    /// The path off a `diff --cc file` / `diff --combined file` line.
    ///
    /// One path, not a pair: a combined diff describes one file against several
    /// parents, and git prints its name once, with no `a/`/`b/` root.
    private static func combinedHeaderPaths(_ line: String) -> (String, String)? {
        let marker = line.hasPrefix("diff --cc ") ? "diff --cc " : "diff --combined "
        var path = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
            path = unquote(String(path.dropFirst().dropLast()))
        }
        guard !path.isEmpty else { return nil }
        return (path, path)
    }

    /// Undoes git's C-style quoting inside a `"…"` path.
    ///
    /// Git escapes bytes outside printable ASCII as `\NNN` octal, one escape per
    /// *byte*, so `src/coração.swift` is written
    /// `"src/cora\303\247\303\243o.swift"`. Stripping the quotes and stopping
    /// there — what this did until the LAB-6 review — puts that literal
    /// backslash sequence in the header a reader uses to know which file they
    /// are looking at, which is a wrong name rather than a missing one.
    ///
    /// Decoded through a byte buffer and not per character: a single UTF-8
    /// scalar is two to four of those escapes, and decoding them one at a time
    /// produces one replacement character each.
    private static func unquote(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var bytes: [UInt8] = []
        var rest = Substring(text)
        while let byte = rest.first {
            guard byte == "\\" else {
                bytes.append(contentsOf: Array(String(byte).utf8))
                rest = rest.dropFirst()
                continue
            }
            let tail = rest.dropFirst()
            guard let escape = tail.first else {
                bytes.append(UInt8(ascii: "\\"))
                break
            }
            if let octal = octalByte(tail) {
                bytes.append(octal)
                rest = tail.dropFirst(3)
                continue
            }
            switch escape {
            case "n": bytes.append(0x0A)
            case "t": bytes.append(0x09)
            case "r": bytes.append(0x0D)
            case "a": bytes.append(0x07)
            case "b": bytes.append(0x08)
            case "f": bytes.append(0x0C)
            case "v": bytes.append(0x0B)
            case "\\": bytes.append(UInt8(ascii: "\\"))
            case "\"": bytes.append(UInt8(ascii: "\""))
            default:
                // Not an escape git produces. Keep both characters rather than
                // guess: a name we do not understand is better whole.
                bytes.append(UInt8(ascii: "\\"))
                bytes.append(contentsOf: Array(String(escape).utf8))
            }
            rest = tail.dropFirst()
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The three octal digits after a backslash, as the byte they name.
    private static func octalByte(_ tail: Substring) -> UInt8? {
        let digits = tail.prefix(3)
        guard digits.count == 3, digits.allSatisfy({ $0 >= "0" && $0 <= "7" }),
            let value = UInt16(digits, radix: 8), value <= 0xFF
        else { return nil }
        return UInt8(value)
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
            text = unquote(String(text.dropFirst().dropLast()))
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

    /// Set once the parser knows it cannot show this file honestly. First
    /// reason wins: the second one is a consequence of the first, and the
    /// reader only needs to be told once.
    var unsupportedReason: String?

    /// The patch changed the file's mode. On its own that is a real change with
    /// no text to show, which without a marker is indistinguishable from a file
    /// nothing happened to.
    var sawModeChange = false

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

    mutating func markUnsupported(_ reason: String) {
        unsupportedReason = unsupportedReason ?? reason
    }

    /// The extended header lines git puts between `diff --git` and `---`.
    mutating func applyMetadata(_ line: String) {
        if line.hasPrefix("old mode ") || line.hasPrefix("new mode ") {
            sawModeChange = true
        } else if line.hasPrefix("new file mode") {
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
            content: content()
        )
    }

    /// Binary first, then anything we failed to read, then the hunks.
    ///
    /// The order matters at one point only, and it is a real trade-off: a file
    /// with three readable hunks and one unreadable `@@` header comes back
    /// `.unsupported`, and those three hunks are not shown. The alternative is
    /// to show them and say nothing about the fourth, which is a file that reads
    /// as a complete, smaller change — the exact lie this whole marker exists to
    /// stop. This file's own rule is that the worst acceptable outcome is a diff
    /// that shows less than it could; it is not a diff that misreports what it
    /// showed. So partial knowledge loses to honesty, and the reason string says
    /// which part we lost.
    private func content() -> DiffContent {
        if isBinary { return .binary }
        if let reason = unsupportedReason { return .unsupported(reason: reason) }
        if hunks.isEmpty && sawModeChange {
            return .unsupported(reason: UnifiedDiffParser.modeOnlyReason)
        }
        return .text(hunks)
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

    func hunk(lines: [DiffLine], isTruncated: Bool) -> DiffHunk {
        DiffHunk(
            oldStart: oldStart,
            oldCount: oldCount,
            newStart: newStart,
            newCount: newCount,
            heading: heading,
            lines: lines,
            isTruncated: isTruncated
        )
    }
}
