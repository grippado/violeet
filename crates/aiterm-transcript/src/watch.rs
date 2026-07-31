//! Watching a transcript and turning appends into telemetry.
//!
//! The one place the pieces meet: `notify` says a file changed, [`tail`] reads
//! what is new, the [`TranscriptReader`] parses it, and [`Telemetry`] folds it
//! in. No socket, no registry — the caller gets a channel of updates and
//! decides what to do with them.
//!
//! # Why the watcher is debounced
//!
//! An agent writing a reply appends several lines in quick succession, one per
//! content block. Reacting to each filesystem event separately would parse the
//! same reply three times and publish three snapshots that differ only in how
//! complete they are. Coalescing events over a short window means the caller
//! sees one update per burst.
//!
//! [`tail`]: crate::tail

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::Duration;

use notify::{Event, RecursiveMode, Watcher};

use crate::tail::{self, Cursor};
use crate::{Telemetry, TranscriptEvent, TranscriptReader};

/// How long to wait for a burst of appends to settle.
///
/// Long enough to coalesce the lines of one reply, short enough that a sidebar
/// still feels live.
const DEBOUNCE: Duration = Duration::from_millis(150);

/// One session's transcript, read incrementally.
///
/// Holds the cursor and the accumulated telemetry. Deliberately not `Send`-shy
/// and not tied to any runtime: it is a struct with a `read` method, and the
/// caller decides whether that happens on a thread, in a task, or on a timer.
pub struct TranscriptSession {
    path: PathBuf,
    reader: Box<dyn TranscriptReader>,
    cursor: Cursor,
    telemetry: Telemetry,
}

impl TranscriptSession {
    /// Start reading `path` from the beginning.
    pub fn from_start(path: impl Into<PathBuf>, reader: Box<dyn TranscriptReader>) -> Self {
        Self {
            path: path.into(),
            reader,
            cursor: Cursor::start(),
            telemetry: Telemetry::new(),
        }
    }

    /// Start reading `path` from its current end.
    ///
    /// For adopting a session already in progress: the backlog is history, and
    /// replaying a 15 MB transcript as if it were live would fill the sidebar
    /// with an hour of stale actions. The cost is that telemetry starts partial
    /// — cumulative counters begin at whatever happens next, not at the true
    /// session total — and that is the honest trade, stated rather than hidden.
    pub fn from_end(
        path: impl Into<PathBuf>,
        reader: Box<dyn TranscriptReader>,
    ) -> std::io::Result<Self> {
        let path = path.into();
        let cursor = Cursor::at_end_of(&path)?;
        Ok(Self {
            path,
            reader,
            cursor,
            telemetry: Telemetry::new(),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn telemetry(&self) -> &Telemetry {
        &self.telemetry
    }

    pub fn harness(&self) -> &'static str {
        self.reader.harness()
    }

    /// Read whatever is new and fold it in.
    ///
    /// Returns the events parsed from this batch, so a caller that wants the
    /// stream rather than the snapshot can have it.
    pub fn read(&mut self) -> Result<Vec<TranscriptEvent>, tail::TailError> {
        let batch = tail::read_since(&self.path, self.cursor)?;
        self.cursor = batch.cursor;

        // The file was replaced or truncated, so the telemetry we accumulated
        // describes a file that no longer exists. Starting over is the only
        // correct answer: keeping the counters would mix two sessions' costs.
        if batch.restarted {
            self.telemetry = Telemetry::new();
        }

        let mut events = Vec::with_capacity(batch.lines.len());
        for line in &batch.lines {
            for event in self.reader.parse_line(line) {
                self.telemetry.apply(&event);
                events.push(event);
            }
        }
        Ok(events)
    }
}

/// A change on a watched transcript.
#[derive(Debug, Clone)]
pub struct Update {
    pub path: PathBuf,
    pub events: Vec<TranscriptEvent>,
    pub telemetry: Telemetry,
}

/// Watch one transcript and send an [`Update`] on every settled burst.
///
/// The returned [`WatchHandle`] owns the watcher; dropping it stops the watch.
/// The first read happens immediately, so a caller that starts watching a file
/// with content already in it gets a snapshot without waiting for a change.
pub fn watch(
    path: impl Into<PathBuf>,
    reader: Box<dyn TranscriptReader>,
    from_end: bool,
) -> Result<(WatchHandle, Receiver<Update>), WatchError> {
    let path = path.into();

    let mut session = if from_end {
        TranscriptSession::from_end(&path, reader)?
    } else {
        TranscriptSession::from_start(&path, reader)
    };

    let (raw_tx, raw_rx) = mpsc::channel::<notify::Result<Event>>();
    let mut watcher =
        notify::recommended_watcher(raw_tx).map_err(|e| WatchError::Notify(e.to_string()))?;

    // The parent directory, not the file. A file watch is on an inode, and a
    // transcript that is replaced rather than appended to — which is what a
    // rotation looks like — leaves the watch pointing at an inode nothing
    // writes to any more, with no error to say so.
    let watch_target = path.parent().unwrap_or(&path).to_path_buf();
    watcher
        .watch(&watch_target, RecursiveMode::NonRecursive)
        .map_err(|e| WatchError::Notify(e.to_string()))?;

    let (tx, rx) = mpsc::channel::<Update>();
    let thread_path = path.clone();

    let handle = std::thread::Builder::new()
        .name("aiterm-transcript".into())
        .spawn(move || {
            // Immediate first read, before waiting on any event. If the
            // receiver is already gone there is nothing to do at all.
            if !emit(&mut session, &tx, &thread_path) {
                return;
            }

            loop {
                match raw_rx.recv() {
                    Ok(_) => {
                        // Coalesce the burst: keep draining until the file has
                        // been quiet for DEBOUNCE.
                        while let Err(RecvTimeoutError::Timeout) | Ok(_) =
                            raw_rx.recv_timeout(DEBOUNCE)
                        {
                            if raw_rx.try_recv().is_err() {
                                break;
                            }
                        }
                        if !emit(&mut session, &tx, &thread_path) {
                            // The receiver is gone; nobody is listening.
                            return;
                        }
                    }
                    // The watcher was dropped.
                    Err(_) => return,
                }
            }
        })
        ?;

    Ok((
        WatchHandle {
            _watcher: Box::new(watcher),
            _thread: handle,
        },
        rx,
    ))
}

/// Read and publish. Returns `false` once the receiver is gone.
///
/// A `bool` rather than a `Result<(), SendError<Update>>`: the error variant
/// carries the whole undelivered `Update` back, which is far larger than the
/// success case and which no caller can do anything with — if nobody is
/// listening, the only move is to stop.
fn emit(session: &mut TranscriptSession, tx: &mpsc::Sender<Update>, path: &Path) -> bool {
    // A read failure is not fatal and is not reported: the file may be mid
    // rotation, or briefly absent. The next event retries, and the cursor has
    // not moved, so nothing is lost.
    let Ok(events) = session.read() else {
        return true;
    };
    if events.is_empty() {
        return true;
    }
    tx.send(Update {
        path: path.to_path_buf(),
        events,
        telemetry: session.telemetry().clone(),
    })
    .is_ok()
}

/// Keeps a watch alive. Dropping it stops the watch.
pub struct WatchHandle {
    _watcher: Box<dyn Watcher + Send>,
    _thread: std::thread::JoinHandle<()>,
}

/// Boxed because `notify`'s error type is large, and an `Err` variant far
/// bigger than the `Ok` one makes every `Result` in the call chain pay for a
/// failure that almost never happens.
#[derive(Debug)]
pub enum WatchError {
    Io(Box<std::io::Error>),
    Notify(String),
}

impl From<std::io::Error> for WatchError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(Box::new(e))
    }
}

impl std::fmt::Display for WatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "{e}"),
            Self::Notify(e) => write!(f, "watch failed: {e}"),
        }
    }
}

impl std::error::Error for WatchError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ClaudeCodeReader;
    use std::io::Write;

    fn temp(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "aiterm-watch-{}-{}-{name}.jsonl",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_file(&p);
        p
    }

    fn append(path: &Path, text: &str) {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap();
        f.write_all(text.as_bytes()).unwrap();
    }

    fn assistant(id: &str, input: u64, cache: u64, out: u64) -> String {
        format!(
            r#"{{"type":"assistant","uuid":"u","sessionId":"s","message":{{"id":"{id}","model":"claude-sonnet-5","usage":{{"input_tokens":{input},"cache_read_input_tokens":{cache},"output_tokens":{out}}}}}}}
"#
        )
    }

    /// Reading twice must not re-count what was already read.
    #[test]
    fn incremental_reads_do_not_recount_earlier_turns() {
        let path = temp("incremental");
        append(&path, &assistant("m1", 100, 900, 50));

        let mut session =
            TranscriptSession::from_start(&path, Box::new(ClaudeCodeReader::new()));
        assert_eq!(session.read().unwrap().len(), 1);
        assert_eq!(session.telemetry().cumulative_output_tokens, Some(50));

        // Nothing new.
        assert!(session.read().unwrap().is_empty());
        assert_eq!(session.telemetry().cumulative_output_tokens, Some(50));

        append(&path, &assistant("m2", 200, 1000, 70));
        assert_eq!(session.read().unwrap().len(), 1);
        assert_eq!(session.telemetry().cumulative_output_tokens, Some(120));
        assert_eq!(
            session.telemetry().context_window_used_tokens,
            Some(1200),
            "occupancy is the latest reading, not a sum of readings"
        );

        let _ = std::fs::remove_file(&path);
    }

    /// The measured file shape: one reply, three lines, one usage.
    #[test]
    fn a_multi_line_reply_is_counted_once_end_to_end() {
        let path = temp("dedup");
        for _ in 0..3 {
            append(&path, &assistant("msg_same", 100, 900, 50));
        }

        let mut session =
            TranscriptSession::from_start(&path, Box::new(ClaudeCodeReader::new()));
        session.read().unwrap();

        assert_eq!(
            session.telemetry().cumulative_output_tokens,
            Some(50),
            "three lines of one reply are one reply"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_truncated_file_resets_the_accumulated_telemetry() {
        let path = temp("reset");
        append(&path, &assistant("m1", 100, 900, 50));

        let mut session =
            TranscriptSession::from_start(&path, Box::new(ClaudeCodeReader::new()));
        session.read().unwrap();
        assert_eq!(session.telemetry().cumulative_output_tokens, Some(50));

        std::fs::write(&path, assistant("m9", 1, 1, 7)).unwrap();
        session.read().unwrap();
        assert_eq!(
            session.telemetry().cumulative_output_tokens,
            Some(7),
            "the old counters described a file that no longer exists"
        );

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn starting_from_the_end_ignores_the_backlog() {
        let path = temp("from-end");
        for i in 0..5 {
            append(&path, &assistant(&format!("old{i}"), 100, 900, 50));
        }

        let mut session =
            TranscriptSession::from_end(&path, Box::new(ClaudeCodeReader::new())).unwrap();
        assert!(session.read().unwrap().is_empty());
        assert_eq!(session.telemetry().cumulative_output_tokens, None);

        append(&path, &assistant("new", 10, 20, 5));
        assert_eq!(session.read().unwrap().len(), 1);
        assert_eq!(session.telemetry().cumulative_output_tokens, Some(5));

        let _ = std::fs::remove_file(&path);
    }
}
