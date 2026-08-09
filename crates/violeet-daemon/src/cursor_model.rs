//! Which model a Cursor session is running, read from Cursor's own bookkeeping.
//!
//! Every other harness tells us this directly. Claude Code puts `model` on each
//! assistant line of the transcript and repeats it on the status line payload;
//! Cursor puts it in neither. Measured across six real transcripts on
//! 2026-08-09: zero `model` fields, zero `usage`, zero `tool_result`. The card
//! for a Cursor session was the only one in the sidebar with a blank model line.
//!
//! Cursor does record it, just somewhere else. `~/.cursor/ai-tracking/
//! ai-code-tracking.db` is a SQLite database Cursor maintains for its own
//! "how much of this code was written by AI" reporting, and its `ai_code_hashes`
//! table carries `model` alongside a `conversationId`. That id is the same
//! string the hooks already hand us as `session_id` — verified by cross-checking
//! `~/.violeet/cursor-hook.log` against the table:
//!
//! ```text
//! dd125b00-0463-4b86-9a98-344832fbe590 | composer-2.5 | 1786310670843
//! 0fa12731-113b-4d47-8c05-f8f4814765e7 | composer-2.5 | 1786309057994
//! ```
//!
//! # Reading someone else's database
//!
//! This file belongs to Cursor, which writes to it while we read. Three rules,
//! and all three are about not being the reason another program breaks:
//!
//! 1. **Read-only, enforced by the open flags** rather than by intent. A bug
//!    here must not be able to corrupt a user's Cursor state.
//! 2. **Opened and closed per query.** Holding the handle would keep a file
//!    lock alive against a process that expects to own the file.
//! 3. **Every failure is silence.** A missing file, a schema that changed, a
//!    locked database — all of it leaves the model unknown, which is what the
//!    card already shows today. Telemetry is the only thing allowed to be lost.
//!
//! `journal_mode` was measured as `delete`, not `wal`, so a read-only open needs
//! no sidecar files to see current data. If Cursor ever switches to WAL, a
//! read-only connection can fail to open — which lands in rule 3, not in a crash.

use std::path::{Path, PathBuf};

/// How long to wait on a locked database before giving up.
///
/// Short on purpose. This runs on a hook path, and a model name is worth a few
/// milliseconds of patience and not one more — Cursor is actively writing here,
/// and a hook that stalls is felt by the user as a slow agent.
const BUSY_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(150);

/// `~/.cursor/ai-tracking/ai-code-tracking.db`, or `None` without a `HOME`.
pub fn tracking_db_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| {
        PathBuf::from(home)
            .join(".cursor")
            .join("ai-tracking")
            .join("ai-code-tracking.db")
    })
}

/// The model this session was last seen using, if Cursor recorded one.
pub fn model_for_session(session_id: &str) -> Option<String> {
    model_for_session_in(&tracking_db_path()?, session_id)
}

/// The query itself, against an explicit path so it can be tested against a
/// fixture rather than against whatever this machine happens to have.
pub fn model_for_session_in(db: &Path, session_id: &str) -> Option<String> {
    if session_id.is_empty() || !db.is_file() {
        return None;
    }

    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
        | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
        | rusqlite::OpenFlags::SQLITE_OPEN_URI;
    let connection = rusqlite::Connection::open_with_flags(db, flags).ok()?;
    connection.busy_timeout(BUSY_TIMEOUT).ok()?;

    // The most recent row wins. A session whose model was switched mid-way has
    // rows for both, and the current one is the one the card should name.
    //
    // `timestamp` is nullable in this schema, so it is coalesced rather than
    // ordered on directly: a NULL sorts unpredictably and would let an old row
    // outrank a new one. `createdAt` is NOT NULL and moves the same direction.
    let model: String = connection
        .query_row(
            "SELECT model FROM ai_code_hashes \
             WHERE conversationId = ?1 AND model IS NOT NULL AND model <> '' \
             ORDER BY COALESCE(timestamp, createdAt) DESC LIMIT 1",
            [session_id],
            |row| row.get(0),
        )
        .ok()?;

    let model = model.trim();
    (!model.is_empty()).then(|| model.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A stand-in for Cursor's database, with the columns this module reads.
    ///
    /// Written with the real schema's nullability, because that is what the
    /// query has to survive: `timestamp` and `model` are both nullable there.
    fn tracking_db(rows: &[(&str, Option<&str>, Option<i64>, i64)]) -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("ai-code-tracking.db");
        let c = rusqlite::Connection::open(&path).expect("create db");
        c.execute_batch(
            "CREATE TABLE ai_code_hashes (
                hash TEXT PRIMARY KEY, source TEXT NOT NULL, fileExtension TEXT,
                fileName TEXT, requestId TEXT, conversationId TEXT,
                timestamp INTEGER, createdAt INTEGER NOT NULL, model TEXT);",
        )
        .expect("schema");
        for (i, (conversation, model, timestamp, created)) in rows.iter().enumerate() {
            c.execute(
                "INSERT INTO ai_code_hashes
                 (hash, source, conversationId, model, timestamp, createdAt)
                 VALUES (?1, 'cli', ?2, ?3, ?4, ?5)",
                rusqlite::params![format!("h{i}"), conversation, model, timestamp, created],
            )
            .expect("insert");
        }
        drop(c);
        dir
    }

    fn db_in(dir: &tempfile::TempDir) -> PathBuf {
        dir.path().join("ai-code-tracking.db")
    }

    #[test]
    fn the_model_of_a_session_is_found_by_its_conversation_id() {
        let dir = tracking_db(&[("sess-a", Some("composer-2.5"), Some(1000), 1000)]);

        assert_eq!(
            model_for_session_in(&db_in(&dir), "sess-a").as_deref(),
            Some("composer-2.5")
        );
    }

    /// A session that switched models mid-way has rows for both, and the card
    /// should name the one it is running now.
    #[test]
    fn the_most_recent_row_wins() {
        let dir = tracking_db(&[
            ("sess-a", Some("composer-2.5"), Some(1000), 1000),
            ("sess-a", Some("claude-opus-5"), Some(5000), 5000),
            ("sess-a", Some("composer-2"), Some(2000), 2000),
        ]);

        assert_eq!(
            model_for_session_in(&db_in(&dir), "sess-a").as_deref(),
            Some("claude-opus-5")
        );
    }

    /// `timestamp` is nullable in the real schema. A NULL there must not let a
    /// stale row outrank a current one.
    #[test]
    fn a_null_timestamp_does_not_outrank_a_newer_row() {
        let dir = tracking_db(&[
            ("sess-a", Some("old-model"), None, 1000),
            ("sess-a", Some("new-model"), Some(9000), 9000),
        ]);

        assert_eq!(
            model_for_session_in(&db_in(&dir), "sess-a").as_deref(),
            Some("new-model")
        );
    }

    #[test]
    fn another_sessions_rows_are_never_borrowed() {
        let dir = tracking_db(&[("sess-b", Some("composer-2.5"), Some(1000), 1000)]);

        assert_eq!(
            model_for_session_in(&db_in(&dir), "sess-a"),
            None,
            "a card must not be named after a model from someone else's session"
        );
    }

    /// `model` is nullable too, and an empty string is not a model name.
    #[test]
    fn rows_without_a_usable_model_are_skipped_rather_than_rendered_blank() {
        let dir = tracking_db(&[
            ("sess-a", Some("composer-2.5"), Some(1000), 1000),
            ("sess-a", None, Some(9000), 9000),
            ("sess-a", Some(""), Some(8000), 8000),
        ]);

        assert_eq!(
            model_for_session_in(&db_in(&dir), "sess-a").as_deref(),
            Some("composer-2.5"),
            "an empty model would render as a card with a blank model line"
        );
    }

    /// Every failure is silence, because the alternative is the daemon caring
    /// about a file that belongs to another program.
    #[test]
    fn a_database_we_cannot_use_leaves_the_model_unknown() {
        let dir = tempfile::tempdir().expect("tempdir");

        // Absent.
        assert_eq!(model_for_session_in(&dir.path().join("nope.db"), "s"), None);

        // Present but not a database.
        let garbage = dir.path().join("garbage.db");
        std::fs::write(&garbage, b"this is not a database").expect("write");
        assert_eq!(model_for_session_in(&garbage, "s"), None);

        // A real database whose schema is not the one we expect — which is what
        // a Cursor update is allowed to do to us.
        let wrong = dir.path().join("wrong.db");
        let c = rusqlite::Connection::open(&wrong).expect("create");
        c.execute_batch("CREATE TABLE something_else (x INTEGER);")
            .expect("schema");
        drop(c);
        assert_eq!(model_for_session_in(&wrong, "s"), None);
    }

    #[test]
    fn an_empty_session_id_asks_nothing() {
        let dir = tracking_db(&[("sess-a", Some("composer-2.5"), Some(1000), 1000)]);
        assert_eq!(model_for_session_in(&db_in(&dir), ""), None);
    }

    /// The session id goes into a bound parameter, never into the SQL text.
    /// It arrives over loopback from a process we did not authenticate.
    #[test]
    fn a_hostile_session_id_is_data_and_not_sql() {
        let dir = tracking_db(&[("sess-a", Some("composer-2.5"), Some(1000), 1000)]);

        assert_eq!(
            model_for_session_in(&db_in(&dir), "' OR 1=1 --"),
            None,
            "a session id is a value, and a value cannot select another row"
        );
        // And the table is still there afterwards.
        assert_eq!(
            model_for_session_in(&db_in(&dir), "sess-a").as_deref(),
            Some("composer-2.5")
        );
    }

    /// The query against the real thing, on a machine that has one.
    ///
    /// Skipped rather than failed elsewhere, the same way the transcript suite
    /// treats a machine without Claude Code installed: this asserts about
    /// Cursor's schema, and a machine with no Cursor has no opinion to offer.
    ///
    /// What it catches is the failure the fixture cannot: Cursor changing the
    /// table, the column, or the journal mode under us. The fixture will keep
    /// passing forever; this one stops.
    #[test]
    fn the_real_database_still_has_the_shape_we_read() {
        let Some(db) = tracking_db_path() else { return };
        if !db.is_file() {
            eprintln!("skipping: no Cursor tracking database on this machine");
            return;
        }

        let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
            | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
            | rusqlite::OpenFlags::SQLITE_OPEN_URI;
        let Ok(c) = rusqlite::Connection::open_with_flags(&db, flags) else {
            eprintln!("skipping: the tracking database would not open read-only");
            return;
        };

        // A session id Cursor recorded, whichever is most recent. If the table
        // or its columns are gone, this is where it shows.
        let newest: Option<String> = c
            .query_row(
                "SELECT conversationId FROM ai_code_hashes \
                 WHERE conversationId IS NOT NULL AND model IS NOT NULL \
                 ORDER BY COALESCE(timestamp, createdAt) DESC LIMIT 1",
                [],
                |row| row.get(0),
            )
            .ok();
        drop(c);

        let Some(session_id) = newest else {
            eprintln!("skipping: the tracking database has no rows yet");
            return;
        };

        let model = model_for_session_in(&db, &session_id);
        assert!(
            model.is_some(),
            "the real database has a model for {session_id} and the query missed it"
        );
    }

    /// The connection must not be able to write, whatever the code above it
    /// asks for. Enforced by the open flags rather than by intent.
    #[test]
    fn the_database_is_opened_in_a_mode_that_cannot_write() {
        let dir = tracking_db(&[("sess-a", Some("composer-2.5"), Some(1000), 1000)]);
        let path = db_in(&dir);

        let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
            | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
            | rusqlite::OpenFlags::SQLITE_OPEN_URI;
        let c = rusqlite::Connection::open_with_flags(&path, flags).expect("open");

        assert!(
            c.execute("DELETE FROM ai_code_hashes", []).is_err(),
            "a bug in violeet must not be able to damage the user's Cursor state"
        );
    }
}
