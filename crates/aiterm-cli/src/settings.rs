//! Reading, merging and writing `~/.claude/settings.json`.
//!
//! This is the module that can do real damage. It edits a file the user did not
//! give us, that other tools also write, and that breaks their agent entirely if
//! it comes back malformed. Three rules follow from that, and they are not
//! negotiable:
//!
//! 1. **Merge, never overwrite.** We add and remove our own entries and touch
//!    nothing else — not other hooks on the same event, not other top-level
//!    keys, not key order.
//! 2. **Refuse what we cannot round-trip.** Claude Code accepts JSONC, with
//!    comments and trailing commas. `serde_json` does not, and a parser that
//!    silently dropped a comment would be deleting the user's notes. So a file
//!    we cannot parse losslessly is a hard stop with an explanation, never a
//!    best-effort rewrite.
//! 3. **Back up before writing.** Timestamped, alongside the original, and the
//!    path is printed.
//!
//! Key order is preserved by `serde_json`'s `preserve_order` feature — see the
//! note in `Cargo.toml`, where it is a correctness requirement rather than a
//! nicety.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value};

use crate::hooks;

/// Why we will not touch a settings file.
#[derive(Debug)]
pub enum SettingsError {
    Io(io::Error),
    /// The file is JSONC, or otherwise not something we can rewrite without
    /// losing information the user put there on purpose.
    NotRoundTrippable { path: PathBuf, why: String },
    /// Parsed, but the shape is not what settings.json is.
    Unexpected { path: PathBuf, why: String },
}

impl std::fmt::Display for SettingsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "{e}"),
            Self::NotRoundTrippable { path, why } => write!(
                f,
                "{} cannot be edited safely: {why}\n\n\
                 aiterm will not rewrite a file it would have to reformat. Claude Code \
                 accepts comments and trailing commas in settings files; rewriting one \
                 would silently delete them. Add the hooks by hand, or move the comments \
                 out and re-run.",
                path.display()
            ),
            Self::Unexpected { path, why } => {
                write!(f, "{} is not shaped like a settings file: {why}", path.display())
            }
        }
    }
}

impl From<io::Error> for SettingsError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

/// A settings file we have read and are allowed to write back.
pub struct Settings {
    pub path: PathBuf,
    /// The exact bytes we read, or `None` when the file did not exist.
    pub original: Option<String>,
    pub value: Value,
}

/// `~/.claude/settings.json`.
pub fn default_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".claude/settings.json"))
}

impl Settings {
    /// Read the file, or start an empty one if it is not there.
    pub fn load(path: &Path) -> Result<Self, SettingsError> {
        let original = match fs::read_to_string(path) {
            Ok(text) => Some(text),
            Err(e) if e.kind() == io::ErrorKind::NotFound => None,
            Err(e) => return Err(SettingsError::Io(e)),
        };

        let value = match original.as_deref() {
            // A missing or blank file is an empty object, not an error. This is
            // the first-run path and it must be boring.
            None => Value::Object(Map::new()),
            Some(text) if text.trim().is_empty() => Value::Object(Map::new()),
            Some(text) => match serde_json::from_str::<Value>(text) {
                Ok(v) => v,
                Err(e) => {
                    return Err(SettingsError::NotRoundTrippable {
                        path: path.to_path_buf(),
                        why: describe_parse_failure(text, &e),
                    })
                }
            },
        };

        if !value.is_object() {
            return Err(SettingsError::Unexpected {
                path: path.to_path_buf(),
                why: "the top-level value is not a JSON object".into(),
            });
        }

        Ok(Self {
            path: path.to_path_buf(),
            original,
            value,
        })
    }

    /// What the file would contain if written now.
    ///
    /// Indented the way the file on disk is indented, not the way we would
    /// choose. This started as a hardcoded four spaces on the assumption that
    /// Claude Code writes four; the round-trip test against a real settings
    /// file said two. Rather than swap one guess for another, the indent is
    /// measured — which is also the only version of this that survives a user
    /// who indents with tabs.
    pub fn rendered(&self) -> String {
        let indent = self
            .original
            .as_deref()
            .and_then(detect_indent)
            .unwrap_or_else(|| "  ".to_string());

        let mut out = to_string_with_indent(&self.value, &indent);
        // A trailing newline, because every editor and every `git diff` expects
        // one and the file we read had one.
        out.push('\n');
        out
    }

    /// True when writing would change nothing. Drives the idempotence promise.
    pub fn is_unchanged(&self) -> bool {
        self.original.as_deref() == Some(self.rendered().as_str())
    }

    /// Copy the current file next to itself before we write.
    ///
    /// Returns `None` when there was no file to back up. The name carries a
    /// timestamp so a second run never clobbers the first backup — which would
    /// otherwise turn "I have a backup" into "I have a backup of the broken
    /// state".
    pub fn back_up(&self) -> Result<Option<PathBuf>, SettingsError> {
        let Some(original) = &self.original else {
            return Ok(None);
        };
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let backup = self
            .path
            .with_extension(format!("json.aiterm-bak-{stamp}"));
        fs::write(&backup, original)?;
        Ok(Some(backup))
    }

    pub fn write(&self) -> Result<(), SettingsError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        // Written via a temporary file and renamed, so a crash mid-write cannot
        // leave the user with half a settings file and no agent.
        let tmp = self.path.with_extension("json.aiterm-tmp");
        fs::write(&tmp, self.rendered())?;
        fs::rename(&tmp, &self.path)?;
        Ok(())
    }

    fn hooks_mut(&mut self) -> &mut Map<String, Value> {
        let root = self.value.as_object_mut().expect("checked on load");
        root.entry("hooks")
            .or_insert_with(|| Value::Object(Map::new()));
        // If `hooks` was there but not an object, replace it: an array or a
        // string in that slot is already broken for Claude Code.
        if !root["hooks"].is_object() {
            root.insert("hooks".into(), Value::Object(Map::new()));
        }
        root["hooks"].as_object_mut().expect("just ensured")
    }

    /// Every hook currently registered for `event`, ours and everyone else's.
    pub fn groups_for(&self, event: &str) -> Vec<&Value> {
        self.value
            .get("hooks")
            .and_then(|h| h.get(event))
            .and_then(Value::as_array)
            .map(|groups| groups.iter().collect())
            .unwrap_or_default()
    }

    /// Hooks on `event` that are not ours.
    pub fn foreign_groups_for(&self, event: &str) -> Vec<&Value> {
        self.groups_for(event)
            .into_iter()
            .filter(|g| !hooks::group_is_ours(g))
            .collect()
    }

    /// Add our entry for `event`, replacing any previous aiterm entry.
    ///
    /// Replacing rather than appending is what makes a second `install-hooks`
    /// idempotent — and what lets it fix a stale port without the user having to
    /// uninstall first.
    pub fn upsert_ours(&mut self, event: &str, port: u16) {
        let entry = hooks::entry_for(event, port);
        let hooks_map = self.hooks_mut();

        let list = hooks_map
            .entry(event.to_string())
            .or_insert_with(|| Value::Array(Vec::new()));
        if !list.is_array() {
            *list = Value::Array(Vec::new());
        }
        let groups = list.as_array_mut().expect("just ensured");

        groups.retain(|g| !hooks::group_is_ours(g));
        groups.push(entry);
    }

    /// Remove our entries for `event`. Returns how many groups went.
    ///
    /// Leaves the event key behind only if somebody else still uses it; an event
    /// whose last hook was ours is removed entirely, so uninstall can restore
    /// the file to exactly what it was.
    pub fn remove_ours(&mut self, event: &str) -> usize {
        let Some(hooks_map) = self
            .value
            .get_mut("hooks")
            .and_then(Value::as_object_mut)
        else {
            return 0;
        };
        let Some(list) = hooks_map.get_mut(event).and_then(Value::as_array_mut) else {
            return 0;
        };

        let before = list.len();
        list.retain(|g| !hooks::group_is_ours(g));
        let removed = before - list.len();

        if list.is_empty() {
            hooks_map.remove(event);
        }
        // And if that was the last event, drop `hooks` too — it is the
        // difference between restoring the file and leaving `"hooks": {}`
        // behind in a file that never had the key.
        if hooks_map.is_empty() {
            self.value
                .as_object_mut()
                .expect("checked on load")
                .remove("hooks");
        }
        removed
    }

    /// Drop a specific foreign group, matched structurally.
    ///
    /// Used by `install-hooks --replace` to evict a competing
    /// `PermissionRequest` hook. Structural equality rather than an index
    /// because the file may have changed since we showed it to the user.
    pub fn remove_group(&mut self, event: &str, group: &Value) -> bool {
        let Some(hooks_map) = self
            .value
            .get_mut("hooks")
            .and_then(Value::as_object_mut)
        else {
            return false;
        };
        let Some(list) = hooks_map.get_mut(event).and_then(Value::as_array_mut) else {
            return false;
        };

        let before = list.len();
        list.retain(|g| g != group);
        let removed = list.len() != before;

        if list.is_empty() {
            hooks_map.remove(event);
        }
        if hooks_map.is_empty() {
            self.value
                .as_object_mut()
                .expect("checked on load")
                .remove("hooks");
        }
        removed
    }

    /// Put a previously removed group back, at the front.
    ///
    /// Front, because a hook that was there before aiterm arrived should not be
    /// demoted behind ours on the way back.
    pub fn restore_group(&mut self, event: &str, group: Value) {
        let hooks_map = self.hooks_mut();
        let list = hooks_map
            .entry(event.to_string())
            .or_insert_with(|| Value::Array(Vec::new()));
        if !list.is_array() {
            *list = Value::Array(Vec::new());
        }
        let groups = list.as_array_mut().expect("just ensured");
        if !groups.iter().any(|g| g == &group) {
            groups.insert(0, group);
        }
    }
}

/// Turn a parse failure into something a human can act on.
///
/// Distinguishing "you have comments in here" from "this is corrupt" matters:
/// the first is a supported Claude Code feature and the user's own doing, the
/// second is a problem they need to know about.
fn describe_parse_failure(text: &str, error: &serde_json::Error) -> String {
    if looks_like_jsonc(text) {
        format!(
            "it uses JSONC syntax (comments and/or trailing commas), which \
             Claude Code accepts but which aiterm cannot rewrite without \
             discarding — {error}"
        )
    } else {
        format!("it is not valid JSON — {error}")
    }
}

/// Cheap, string-aware scan for `//`, `/*` and trailing commas.
///
/// Deliberately not a parser. It only has to be right often enough to give a
/// better error message; the refusal to write has already happened either way.
fn looks_like_jsonc(text: &str) -> bool {
    let bytes = text.as_bytes();
    let mut in_string = false;
    let mut escaped = false;
    let mut i = 0;

    while i < bytes.len() {
        let b = bytes[i];
        if in_string {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                in_string = false;
            }
            i += 1;
            continue;
        }
        match b {
            b'"' => in_string = true,
            b'/' if i + 1 < bytes.len() && (bytes[i + 1] == b'/' || bytes[i + 1] == b'*') => {
                return true
            }
            b',' => {
                // A comma whose next non-whitespace character closes a
                // container is a trailing comma.
                let rest = text[i + 1..].trim_start();
                if rest.starts_with('}') || rest.starts_with(']') {
                    return true;
                }
            }
            _ => {}
        }
        i += 1;
    }
    false
}

/// The indent unit this file uses, read off its first indented line.
///
/// Returns `None` for a single-line file, where there is nothing to measure and
/// the default is as good as any answer.
fn detect_indent(text: &str) -> Option<String> {
    for line in text.lines().skip(1) {
        let trimmed = line.trim_start_matches([' ', '\t']);
        if trimmed.is_empty() {
            continue;
        }
        let lead = &line[..line.len() - trimmed.len()];
        if !lead.is_empty() {
            return Some(lead.to_string());
        }
    }
    None
}

/// Pretty-print with an arbitrary indent unit.
///
/// `serde_json::to_string_pretty` hardcodes two spaces, so anything else goes
/// through the formatter directly.
fn to_string_with_indent(value: &Value, indent: &str) -> String {
    use serde::Serialize;

    let formatter = serde_json::ser::PrettyFormatter::with_indent(indent.as_bytes());
    let mut buffer = Vec::new();
    let mut serializer = serde_json::Serializer::with_formatter(&mut buffer, formatter);

    match value.serialize(&mut serializer) {
        Ok(()) => String::from_utf8(buffer).unwrap_or_default(),
        // Serializing a `Value` cannot fail in practice; falling back keeps
        // this total rather than adding an error path nobody can trigger.
        Err(_) => serde_json::to_string_pretty(value).unwrap_or_default(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings_from(text: &str) -> Settings {
        Settings {
            path: PathBuf::from("/nowhere/settings.json"),
            original: Some(text.to_string()),
            value: serde_json::from_str(text).unwrap(),
        }
    }

    /// The promise the user is being asked to trust. Not "the same data" —
    /// the same bytes.
    #[test]
    fn install_then_uninstall_restores_the_file_byte_for_byte() {
        let original = concat!(
            "{\n",
            "    \"hooks\": {\n",
            "        \"Stop\": [\n",
            "            {\n",
            "                \"matcher\": \"\",\n",
            "                \"hooks\": [\n",
            "                    {\n",
            "                        \"type\": \"command\",\n",
            "                        \"command\": \"$HOME/notify.sh\"\n",
            "                    }\n",
            "                ]\n",
            "            }\n",
            "        ]\n",
            "    },\n",
            "    \"theme\": \"dark\"\n",
            "}\n"
        );

        let mut s = settings_from(original);
        assert_eq!(s.rendered(), original, "reading and re-rendering must be a no-op");

        for event in hooks::all_events() {
            s.upsert_ours(event, 9847);
        }
        assert_ne!(s.rendered(), original);

        for event in hooks::all_events() {
            s.remove_ours(event);
        }
        assert_eq!(
            s.rendered(),
            original,
            "uninstall must return the file to exactly what it was"
        );
    }

    /// A file that never had a `hooks` key must not acquire an empty one.
    #[test]
    fn a_file_without_hooks_gets_none_back_after_uninstall() {
        let original = "{\n    \"theme\": \"dark\"\n}\n";
        let mut s = settings_from(original);

        for event in hooks::all_events() {
            s.upsert_ours(event, 9847);
        }
        for event in hooks::all_events() {
            s.remove_ours(event);
        }

        assert_eq!(s.rendered(), original);
        assert!(s.value.get("hooks").is_none(), "no empty `hooks: {{}}` left behind");
    }

    /// Running install twice must not double anything. This is the check that
    /// catches an append where an upsert was meant.
    #[test]
    fn installing_twice_is_the_same_as_installing_once() {
        let mut once = settings_from("{}");
        for event in hooks::all_events() {
            once.upsert_ours(event, 9847);
        }

        let mut twice = settings_from("{}");
        for _ in 0..2 {
            for event in hooks::all_events() {
                twice.upsert_ours(event, 9847);
            }
        }

        assert_eq!(once.rendered(), twice.rendered());
        assert_eq!(twice.groups_for("Stop").len(), 1);
    }

    /// Re-running against a different port replaces rather than accumulates —
    /// which is what makes a stale-port fix a re-run and not a manual edit.
    #[test]
    fn reinstalling_on_a_new_port_replaces_the_old_entry() {
        let mut s = settings_from("{}");
        s.upsert_ours("Stop", 9847);
        s.upsert_ours("Stop", 51234);

        let groups = s.groups_for("Stop");
        assert_eq!(groups.len(), 1);
        assert!(groups[0]["hooks"][0]["url"]
            .as_str()
            .unwrap()
            .contains("51234"));
    }

    /// Other people's hooks on the same event survive everything we do.
    #[test]
    fn foreign_hooks_on_the_same_event_are_untouched() {
        let original = concat!(
            "{\n",
            "    \"hooks\": {\n",
            "        \"PermissionRequest\": [\n",
            "            {\n",
            "                \"matcher\": \"*\",\n",
            "                \"hooks\": [\n",
            "                    {\n",
            "                        \"type\": \"command\",\n",
            "                        \"command\": \"notify.sh\"\n",
            "                    }\n",
            "                ]\n",
            "            }\n",
            "        ]\n",
            "    }\n",
            "}\n"
        );
        let mut s = settings_from(original);

        s.upsert_ours("PermissionRequest", 9847);
        assert_eq!(s.groups_for("PermissionRequest").len(), 2);
        assert_eq!(s.foreign_groups_for("PermissionRequest").len(), 1);

        s.remove_ours("PermissionRequest");
        assert_eq!(s.rendered(), original);
    }

    #[test]
    fn a_removed_foreign_group_can_be_put_back() {
        let original = concat!(
            "{\n",
            "    \"hooks\": {\n",
            "        \"PermissionRequest\": [\n",
            "            {\n",
            "                \"hooks\": [\n",
            "                    {\n",
            "                        \"type\": \"command\",\n",
            "                        \"command\": \"notify.sh\"\n",
            "                    }\n",
            "                ]\n",
            "            }\n",
            "        ]\n",
            "    }\n",
            "}\n"
        );
        let mut s = settings_from(original);
        let group = s.foreign_groups_for("PermissionRequest")[0].clone();

        assert!(s.remove_group("PermissionRequest", &group));
        assert_eq!(s.rendered(), "{}\n");

        s.restore_group("PermissionRequest", group);
        assert_eq!(s.rendered(), original);
    }

    /// Key order is the thing `preserve_order` buys, and it is worth asserting
    /// so that dropping the feature fails a test instead of quietly rewriting
    /// everybody's settings.
    #[test]
    fn key_order_survives_a_round_trip() {
        let original = "{\n    \"zeta\": 1,\n    \"alpha\": 2,\n    \"middle\": 3\n}\n";
        assert_eq!(settings_from(original).rendered(), original);
    }

    /// The file's own indentation wins over ours.
    ///
    /// This is the assertion that caught the real bug: the code hardcoded four
    /// spaces because "that is what Claude Code writes", and the actual file on
    /// disk used two. Every settings file the tool touches would have been
    /// reindented end to end on first install — a diff touching every line, for
    /// a change that adds eleven.
    #[test]
    fn the_files_own_indentation_is_preserved() {
        let two = "{\n  \"a\": {\n    \"b\": 1\n  }\n}\n";
        let four = "{\n    \"a\": {\n        \"b\": 1\n    }\n}\n";
        let tabs = "{\n\t\"a\": {\n\t\t\"b\": 1\n\t}\n}\n";

        for original in [two, four, tabs] {
            assert_eq!(
                settings_from(original).rendered(),
                original,
                "indentation was not preserved for:\n{original}"
            );
        }
    }

    #[test]
    fn indentation_is_detected_from_the_first_indented_line() {
        assert_eq!(detect_indent("{\n  \"a\": 1\n}").as_deref(), Some("  "));
        assert_eq!(detect_indent("{\n    \"a\": 1\n}").as_deref(), Some("    "));
        assert_eq!(detect_indent("{\n\t\"a\": 1\n}").as_deref(), Some("\t"));
        // Nothing to measure: a one-line file has no indented line.
        assert_eq!(detect_indent("{}"), None);
        assert_eq!(detect_indent("{\"a\":1}"), None);
    }

    /// Shapes a hand-edited settings file actually contains.
    ///
    /// The unit tests above use files this code wrote. These do not: escapes,
    /// non-ASCII, empty containers, deep nesting and large numbers are where a
    /// round trip that "works" starts quietly rewriting things.
    #[test]
    fn awkward_but_valid_json_round_trips_unchanged() {
        let cases = [
            "{\n    \"a\": \"tab\\there\"\n}\n",
            "{\n    \"a\": \"quote\\\"inside\"\n}\n",
            "{\n    \"a\": \"acentuação e emoji 🪿\"\n}\n",
            "{\n    \"empty_obj\": {},\n    \"empty_arr\": []\n}\n",
            "{\n    \"n\": 9007199254740991\n}\n",
            "{\n    \"neg\": -0.5,\n    \"t\": true,\n    \"z\": null\n}\n",
            "{\n    \"deep\": {\n        \"er\": {\n            \"est\": [\n                1,\n                2\n            ]\n        }\n    }\n}\n",
            "{\n    \"slash\": \"a/b\",\n    \"back\": \"a\\\\b\"\n}\n",
        ];

        for original in cases {
            let s = settings_from(original);
            assert_eq!(
                s.rendered(),
                original,
                "round trip changed this file:\n{original}"
            );
        }
    }

    /// The real thing, when there is one.
    ///
    /// Strictly read-only — it parses and re-renders in memory and asserts the
    /// bytes match. Skipped when the file is absent or is JSONC, because both
    /// are handled elsewhere; this is here to catch the case the synthetic
    /// fixtures cannot invent, which is whatever the developer's own settings
    /// happen to contain.
    #[test]
    fn the_real_settings_file_round_trips_if_it_is_present() {
        let Some(path) = default_path() else { return };
        let Ok(text) = fs::read_to_string(&path) else {
            return;
        };
        if looks_like_jsonc(&text) {
            return;
        }
        let Ok(settings) = Settings::load(&path) else {
            return;
        };

        assert_eq!(
            settings.rendered(),
            text,
            "reading and re-rendering {} changed it. Writing hooks into it would \
             reformat the user's file.",
            path.display()
        );
    }

    #[test]
    fn jsonc_is_refused_rather_than_reformatted() {
        assert!(looks_like_jsonc("{ // a note\n \"a\": 1 }"));
        assert!(looks_like_jsonc("{ /* block */ \"a\": 1 }"));
        assert!(looks_like_jsonc("{ \"a\": [1, 2,] }"));

        // A slash or a comma *inside a string* is not JSONC.
        assert!(!looks_like_jsonc(r#"{"command": "sh -c 'a // b'"}"#));
        assert!(!looks_like_jsonc(r#"{"url": "http://x/y", "a": 1}"#));
        assert!(!looks_like_jsonc(r#"{"a": "trailing,", "b": 1}"#));
    }
}
