//! Session names that survive a daemon restart.
//!
//! # Why anything is persisted at all
//!
//! The registry is in-memory on purpose: a session is a live thing, and a
//! daemon that came back to a list of dead cards would be worse than one that
//! came back empty. Hooks re-announce every session that is still alive within
//! seconds, so the list rebuilds itself.
//!
//! The **name** does not rebuild itself. It came from the first prompt, which
//! was submitted an hour ago and will not be submitted again, or from a human
//! who typed it once. Losing it on restart would rename every card in the
//! sidebar to its working directory, and the user who renamed one would have to
//! do it again — which is the kind of small betrayal that teaches people not to
//! bother renaming.
//!
//! So exactly one thing is persisted: what a session is called, and who called
//! it that. The source travels with the title because the precedence rules are
//! meaningless without it — restoring a name without knowing it was the user's
//! would let the next `ai-title` quietly overwrite a manual rename.
//!
//! # Failure is not fatal
//!
//! Every operation here degrades to doing nothing. An unreadable file, a full
//! disk, a home directory that does not exist: all of them cost the titles and
//! none of them stop the daemon. A name is worth keeping, not worth crashing
//! over.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::registry::TitleSource;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StoredTitle {
    pub title: String,
    /// `cwd` | `prompt` | `ai_title` | `user`.
    pub source: String,
}

/// The persisted names, keyed by session id.
#[derive(Debug, Default)]
pub struct TitleStore {
    entries: HashMap<String, StoredTitle>,
    path: Option<PathBuf>,
}

/// `~/.aiterm/titles.json`.
///
/// `AITERM_STATE_DIR` overrides the directory, and exists because of a bug this
/// file caused the first time it ran: a test that renamed a session wrote
/// `"s1": "my run"` into the developer's real store. A test suite that can
/// reach into `$HOME` will eventually write something worse than a stray key,
/// so the tests point this somewhere disposable instead.
pub fn store_path() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("AITERM_STATE_DIR") {
        return Some(PathBuf::from(dir).join("titles.json"));
    }
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".aiterm").join("titles.json"))
}

impl TitleStore {
    /// Load whatever is on disk. A missing or corrupt file is an empty store,
    /// never an error: the worst case is that names start over, and that is the
    /// same place the daemon was before this file existed.
    pub fn load() -> Self {
        let path = store_path();
        let entries = path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|raw| serde_json::from_str::<HashMap<String, StoredTitle>>(&raw).ok())
            .unwrap_or_default();
        Self { entries, path }
    }

    pub fn get(&self, session_id: &str) -> Option<(&str, TitleSource)> {
        let entry = self.entries.get(session_id)?;
        Some((entry.title.as_str(), parse_source(&entry.source)))
    }

    /// Record a name and write the file. A failed write is silent — see the
    /// module note.
    pub fn put(&mut self, session_id: &str, title: &str, source: TitleSource) {
        let Some(wire) = source.as_wire() else { return };
        self.entries.insert(
            session_id.to_string(),
            StoredTitle {
                title: title.to_string(),
                source: wire.to_string(),
            },
        );
        self.flush();
    }

    /// Forget a session. Called when one ends, so the file does not grow for
    /// the life of the machine.
    pub fn forget(&mut self, session_id: &str) {
        if self.entries.remove(session_id).is_some() {
            self.flush();
        }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn flush(&self) {
        let Some(path) = &self.path else { return };
        let Ok(raw) = serde_json::to_string_pretty(&self.entries) else {
            return;
        };
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        // Write-and-rename, so a daemon killed mid-write leaves the previous
        // file intact rather than a truncated one that loads as empty.
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, raw).is_ok() {
            let _ = std::fs::rename(&tmp, path);
        }
    }
}

/// An unrecognised source is `Cwd` — the weakest rank there is.
///
/// Deliberately not `User`: a file written by a future version, or corrupted,
/// must not be able to hand a title the one rank that nothing can overwrite.
/// The failure then is a name that gets upgraded when it should not have been,
/// which is recoverable; the other way round is a session the user can never
/// rename back.
fn parse_source(raw: &str) -> TitleSource {
    match raw {
        "user" => TitleSource::User,
        "ai_title" => TitleSource::AiTitle,
        "prompt" => TitleSource::Prompt,
        _ => TitleSource::Cwd,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> TitleStore {
        TitleStore {
            entries: HashMap::new(),
            path: None,
        }
    }

    #[test]
    fn a_stored_title_comes_back_with_the_source_that_set_it() {
        let mut s = store();
        s.put("s1", "Arrumar o parser", TitleSource::User);
        assert_eq!(s.get("s1"), Some(("Arrumar o parser", TitleSource::User)));
    }

    /// The point of persisting the source: a restored manual rename must still
    /// outrank everything, or the next `ai-title` silently undoes the user's
    /// choice.
    #[test]
    fn a_restored_user_title_still_outranks_a_generated_one() {
        let mut s = store();
        s.put("s1", "meu nome", TitleSource::User);
        let (_, source) = s.get("s1").unwrap();
        assert!(source.rank() > TitleSource::AiTitle.rank());
    }

    #[test]
    fn an_unrecognized_source_gets_the_weakest_rank_and_not_the_strongest() {
        assert_eq!(parse_source("something-from-the-future"), TitleSource::Cwd);
        assert_eq!(parse_source(""), TitleSource::Cwd);
    }

    #[test]
    fn a_session_that_ended_is_forgotten() {
        let mut s = store();
        s.put("s1", "x", TitleSource::Prompt);
        s.forget("s1");
        assert!(s.is_empty());
    }

    /// A store with no path is a working store that simply does not persist.
    /// That is the degraded mode when there is no home directory, and it must
    /// not panic.
    #[test]
    fn a_store_with_nowhere_to_write_still_works_in_memory() {
        let mut s = store();
        s.put("s1", "x", TitleSource::Prompt);
        assert_eq!(s.len(), 1);
    }
}
