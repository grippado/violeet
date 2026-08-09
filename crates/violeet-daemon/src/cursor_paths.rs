//! Where Cursor keeps a session's transcript, when the hook does not say.
//!
//! Claude Code hands `transcript_path` to nearly every hook, so the daemon never
//! has to guess. **Cursor sends it on none of them.** Measured 2026-08-09
//! against `~/.violeet/cursor-hook.log` and the payloads in
//! `docs/spikes/2026-08-09-cursor-hooks.md`: `sessionStart`, `beforeSubmitPrompt`,
//! `stop`, `sessionEnd`, `beforeShellExecution` and `beforeMCPExecution` all
//! arrive without it. Without a path there is no `follow`, and without `follow`
//! a Cursor card has no telemetry at all — which is the state LAB-62 opened on.
//!
//! # What the guess rests on
//!
//! Cursor writes each transcript to
//! `~/.cursor/projects/<project>/agent-transcripts/<id>/<id>.jsonl`, where `<id>`
//! is the very `conversation_id` the hooks already carry as `session_id`.
//! Verified on this machine: `~/.violeet/cursor-hook.log` recorded
//! `sid=dd125b00-0463-4b86-9a98-344832fbe590` and
//! `sid=0fa12731-113b-4d47-8c05-f8f4814765e7`, and both exist verbatim as
//! transcript directory names. So the id is not a hint to match — it is the
//! answer, and the only open question is which `<project>` holds it.
//!
//! # Why the project directory is scanned rather than computed
//!
//! The obvious cheaper route is deriving `<project>` from the session's working
//! directory, since the names look like a slugified absolute path
//! (`/Users/me/www/personal/violeet` → `Users-me-www-personal-violeet`). It was
//! tried and rejected on measurement: the transform is not a transform.
//! `/Users/grippado/.notes` becomes `Users-grippado-notes` — the dot is
//! *deleted* — while `/Users/grippado/www/personal/vozes.social/vozes-api`
//! becomes `Users-grippado-www-personal-vozes-social-vozes-api`, where the dot
//! became a dash. Two rules for one character, and no documentation for either.
//!
//! A computed name that is wrong fails silently: it names a file that is not
//! there, `follow` logs and gives up, and the card looks exactly like one whose
//! session never wrote anything. Scanning costs one `read_dir` of a directory
//! holding a few dozen entries, once per session, and it either finds the real
//! file or honestly finds nothing.

use std::path::{Path, PathBuf};

/// A session id we are willing to build a path out of.
///
/// The id arrives over loopback from a process we did not authenticate and is
/// about to become a path component, so it is checked rather than trusted: a
/// `session_id` of `../../../etc/passwd` must not escape the projects root. The
/// ids Cursor mints are UUIDs, so restricting to what a UUID can contain costs
/// nothing real and removes traversal entirely.
fn is_safe_id(session_id: &str) -> bool {
    !session_id.is_empty()
        && session_id.len() <= 128
        && session_id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// `~/.cursor/projects`, or `None` when `HOME` is not set.
pub fn projects_root() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(".cursor").join("projects"))
}

/// The transcript for `session_id`, if one is on disk.
///
/// `None` is a normal, common answer — a session whose first hook fires before
/// Cursor has written a line has no transcript yet. It is not an error and is
/// not logged: the next hook calls this again, and `follow` is idempotent, so a
/// transcript that appears one event later is picked up one event later.
pub fn infer_transcript_path(session_id: &str) -> Option<PathBuf> {
    infer_transcript_path_in(&projects_root()?, session_id)
}

/// The scan itself, against an explicit root so it can be tested without a
/// `$HOME` full of real sessions.
pub fn infer_transcript_path_in(projects_root: &Path, session_id: &str) -> Option<PathBuf> {
    if !is_safe_id(session_id) {
        return None;
    }

    let entries = std::fs::read_dir(projects_root).ok()?;
    for entry in entries.flatten() {
        let candidate = entry
            .path()
            .join("agent-transcripts")
            .join(session_id)
            .join(format!("{session_id}.jsonl"));
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A scratch `projects` root with one transcript in it.
    fn projects_with(session_id: &str, project: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().expect("tempdir");
        let transcripts = dir
            .path()
            .join(project)
            .join("agent-transcripts")
            .join(session_id);
        std::fs::create_dir_all(&transcripts).expect("create");
        std::fs::write(
            transcripts.join(format!("{session_id}.jsonl")),
            "{\"role\":\"user\",\"message\":{\"content\":[]}}\n",
        )
        .expect("write");
        dir
    }

    #[test]
    fn a_transcript_is_found_by_its_session_id_alone() {
        let id = "dd125b00-0463-4b86-9a98-344832fbe590";
        let dir = projects_with(id, "Users-me-www-personal-violeet");

        let found = infer_transcript_path_in(dir.path(), id).expect("the transcript is there");
        assert!(found.is_file());
        assert!(found.ends_with(format!("{id}.jsonl")));
    }

    /// The whole point of scanning: the project directory name is not derivable
    /// from the working directory, so the search must not depend on knowing it.
    #[test]
    fn the_project_directory_name_is_never_needed() {
        let id = "0fa12731-113b-4d47-8c05-f8f4814765e7";
        // A name no slugifier would produce from any cwd.
        let dir = projects_with(id, "1778521768815");

        assert!(infer_transcript_path_in(dir.path(), id).is_some());
    }

    #[test]
    fn a_session_with_no_transcript_yet_is_none_rather_than_a_path_that_does_not_exist() {
        let dir = projects_with("some-other-session", "Users-me-notes");

        assert_eq!(
            infer_transcript_path_in(dir.path(), "not-written-yet"),
            None,
            "a path we have not seen on disk must never be handed to `follow`"
        );
    }

    #[test]
    fn a_missing_projects_root_is_none_rather_than_a_panic() {
        let dir = tempfile::tempdir().expect("tempdir");
        assert_eq!(
            infer_transcript_path_in(&dir.path().join("no-such-dir"), "abc"),
            None
        );
    }

    /// The id becomes a path component, and it arrives from an unauthenticated
    /// local process. Traversal is refused before it reaches the filesystem.
    #[test]
    fn a_session_id_may_not_climb_out_of_the_projects_root() {
        let dir = tempfile::tempdir().expect("tempdir");

        for hostile in [
            "../../../etc/passwd",
            "..",
            "a/b",
            "",
            "with space",
            "semi;colon",
        ] {
            assert!(
                !is_safe_id(hostile),
                "{hostile:?} must not be accepted as a path component"
            );
            assert_eq!(infer_transcript_path_in(dir.path(), hostile), None);
        }

        assert!(is_safe_id("dd125b00-0463-4b86-9a98-344832fbe590"));
    }
}
