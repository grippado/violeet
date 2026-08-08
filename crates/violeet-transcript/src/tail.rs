//! Incremental reading: pick up where we left off, never re-read the file.
//!
//! Transcripts reach tens of megabytes — the largest measured under
//! `~/.claude/projects` is 15 MB — and they are appended to constantly. Parsing
//! from the start on every change is the difference between a background reader
//! and a fan that never stops.
//!
//! # The cursor is an offset plus enough to notice a lie
//!
//! An offset alone is not safe. If the file were replaced, truncated or rotated,
//! a stale offset points into the middle of a different file and every line
//! after it is garbage — or, worse, plausible. So the cursor also carries the
//! length it last saw, and a shrunken file is treated as a new one and read from
//! the beginning.
//!
//! This is not hypothetical bookkeeping: a compaction rewrites history, and a
//! session resumed under the same id is exactly the case where an offset
//! survives longer than the file it describes.
//!
//! # Partial lines
//!
//! The reader may arrive mid-append and see a line with no terminating newline.
//! That line is **not** parsed and **not** consumed — the offset stops at the
//! last complete newline, so the next read sees the whole line. Parsing a half
//! written JSON object would produce a `None` that never gets retried, silently
//! dropping one event forever.

use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

/// Where we stopped, and what the file looked like when we did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Cursor {
    /// Byte offset of the first unread byte. Always just past a newline.
    pub offset: u64,
    /// The file length when that offset was taken.
    pub known_len: u64,
}

impl Cursor {
    /// A cursor for a file we have never read.
    pub fn start() -> Self {
        Self::default()
    }

    /// A cursor positioned at the end of `path`, so only *new* lines are seen.
    ///
    /// This is what a daemon adopting a session already in progress wants: the
    /// backlog of a 15 MB transcript is history, and replaying it as if it were
    /// live would flood the sidebar with an hour of stale actions.
    pub fn at_end_of(path: &Path) -> io::Result<Self> {
        let len = std::fs::metadata(path)?.len();
        Ok(Self {
            offset: len,
            known_len: len,
        })
    }
}

#[derive(Debug)]
pub enum TailError {
    Io(io::Error),
}

impl std::fmt::Display for TailError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for TailError {}

impl From<io::Error> for TailError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

/// What one incremental read produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    /// Complete lines only.
    pub lines: Vec<String>,
    pub cursor: Cursor,
    /// The file shrank, so it was read from the start. Callers that keep
    /// per-session state need to know their accumulated telemetry now describes
    /// a file that no longer exists.
    pub restarted: bool,
}

/// Read whatever is new since `cursor`.
///
/// Returns complete lines only, and a cursor that has advanced exactly as far
/// as those lines.
pub fn read_since(path: &Path, cursor: Cursor) -> Result<Batch, TailError> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();

    // Shorter than we last saw it: truncated, replaced, or rotated. An offset
    // into the old file means nothing in the new one.
    let restarted = len < cursor.known_len;
    let start = if restarted { 0 } else { cursor.offset.min(len) };

    if start == len {
        return Ok(Batch {
            lines: Vec::new(),
            cursor: Cursor {
                offset: start,
                known_len: len,
            },
            restarted,
        });
    }

    file.seek(SeekFrom::Start(start))?;
    let mut reader = BufReader::new(file);

    let mut lines = Vec::new();
    let mut consumed = 0u64;
    let mut buffer = Vec::new();

    loop {
        buffer.clear();
        let read = reader.read_until(b'\n', &mut buffer)?;
        if read == 0 {
            break;
        }
        // No trailing newline: this is a partial line at the end of the file.
        // Leave it, and leave the offset before it, so the next read gets all
        // of it. Consuming it here would drop the event permanently.
        if buffer.last() != Some(&b'\n') {
            break;
        }
        consumed += read as u64;

        // Lossy rather than strict. A transcript is UTF-8 in practice, but a
        // torn write can leave an invalid sequence, and refusing the line would
        // stall the cursor on it forever.
        lines.push(String::from_utf8_lossy(&buffer).trim_end().to_string());
    }

    Ok(Batch {
        lines,
        cursor: Cursor {
            offset: start + consumed,
            known_len: len,
        },
        restarted,
    })
}

/// The first `n` lines, for sniffing which reader a file needs.
pub fn read_first_lines(path: &Path, n: usize) -> io::Result<Vec<String>> {
    let file = File::open(path)?;
    // Bounded: sniffing must not read a 15 MB file, and a single absurdly long
    // line must not be buffered whole.
    let mut reader = BufReader::new(file.take(64 * 1024));
    let mut out = Vec::new();
    let mut buffer = String::new();

    while out.len() < n {
        buffer.clear();
        if reader.read_line(&mut buffer)? == 0 {
            break;
        }
        let trimmed = buffer.trim();
        if !trimmed.is_empty() {
            out.push(trimmed.to_string());
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// A disposable file. std has no temp-file API and this is not worth a
    /// dependency; the pid and a counter are enough to avoid collisions.
    struct Temp(std::path::PathBuf);

    impl Temp {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "violeet-transcript-{}-{}-{name}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            ));
            let _ = std::fs::remove_file(&path);
            Self(path)
        }
        fn path(&self) -> &Path {
            &self.0
        }
        fn write(&self, text: &str) {
            std::fs::write(&self.0, text).unwrap();
        }
        fn append(&self, text: &str) {
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&self.0)
                .unwrap();
            f.write_all(text.as_bytes()).unwrap();
        }
    }

    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    #[test]
    fn a_second_read_returns_only_what_was_appended() {
        let f = Temp::new("append");
        f.write("one\ntwo\n");

        let first = read_since(f.path(), Cursor::start()).unwrap();
        assert_eq!(first.lines, ["one", "two"]);

        // Nothing new: no lines, and the cursor does not move.
        let idle = read_since(f.path(), first.cursor).unwrap();
        assert!(idle.lines.is_empty());
        assert_eq!(idle.cursor.offset, first.cursor.offset);

        f.append("three\n");
        let second = read_since(f.path(), idle.cursor).unwrap();
        assert_eq!(second.lines, ["three"], "only the new line, not the whole file");
    }

    /// The case that silently loses an event if it is got wrong.
    #[test]
    fn a_partial_line_is_left_alone_until_it_is_complete() {
        let f = Temp::new("partial");
        f.write("complete\n{\"half\": ");

        let first = read_since(f.path(), Cursor::start()).unwrap();
        assert_eq!(first.lines, ["complete"], "the partial line is not returned");
        assert_eq!(
            first.cursor.offset, 9,
            "and the cursor stops before it, so the rest is not skipped"
        );

        f.append("\"written\"}\n");
        let second = read_since(f.path(), first.cursor).unwrap();
        assert_eq!(second.lines, [r#"{"half": "written"}"#], "now it arrives whole");
    }

    /// A shrunken file is a different file. An offset into the old one would
    /// land mid-line in the new one and produce plausible garbage.
    #[test]
    fn a_truncated_file_is_read_from_the_start_and_says_so() {
        let f = Temp::new("truncate");
        f.write("aaaa\nbbbb\ncccc\n");
        let first = read_since(f.path(), Cursor::start()).unwrap();
        assert_eq!(first.lines.len(), 3);
        assert!(!first.restarted);

        f.write("x\n");
        let second = read_since(f.path(), first.cursor).unwrap();
        assert!(second.restarted, "the caller has to know its state is stale");
        assert_eq!(second.lines, ["x"]);
    }

    /// Growth without shrinking is not a restart, even across many appends.
    #[test]
    fn ordinary_growth_is_never_reported_as_a_restart() {
        let f = Temp::new("growth");
        f.write("a\n");
        let mut cursor = read_since(f.path(), Cursor::start()).unwrap().cursor;

        for i in 0..20 {
            f.append(&format!("line {i}\n"));
            let batch = read_since(f.path(), cursor).unwrap();
            assert!(!batch.restarted);
            assert_eq!(batch.lines, [format!("line {i}")]);
            cursor = batch.cursor;
        }
    }

    #[test]
    fn a_cursor_at_the_end_skips_the_backlog() {
        let f = Temp::new("at-end");
        f.write("history\nhistory\nhistory\n");

        let cursor = Cursor::at_end_of(f.path()).unwrap();
        let batch = read_since(f.path(), cursor).unwrap();
        assert!(batch.lines.is_empty(), "the backlog is history, not news");

        f.append("live\n");
        assert_eq!(read_since(f.path(), batch.cursor).unwrap().lines, ["live"]);
    }

    #[test]
    fn invalid_utf8_does_not_stall_the_cursor() {
        let f = Temp::new("utf8");
        std::fs::write(f.path(), b"good\n\xff\xfe bad\nafter\n").unwrap();

        let batch = read_since(f.path(), Cursor::start()).unwrap();
        assert_eq!(batch.lines.len(), 3, "the bad line is replaced, not skipped");
        assert_eq!(batch.lines[0], "good");
        assert_eq!(batch.lines[2], "after");
    }

    #[test]
    fn a_missing_file_is_an_error_rather_than_a_panic() {
        let missing = std::env::temp_dir().join("violeet-transcript-does-not-exist.jsonl");
        assert!(read_since(&missing, Cursor::start()).is_err());
    }
}
