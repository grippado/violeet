//! The Claude Code JSONL reader.
//!
//! Every field name here was read out of real files under `~/.claude/projects`.
//! `docs/TRANSCRIPT_FORMAT.md` says which of them were measured, which were
//! inferred, and which could not be determined.
//!
//! # Defensive on purpose
//!
//! Nothing in this file returns an error and nothing can panic on bad input. A
//! line that is not JSON, an object with the wrong shape, a `usage` that is
//! suddenly a string — all of it produces `None` or a partially filled event.
//!
//! That is not defensiveness for its own sake. This format is written by
//! another tool, has no published schema, and has already been observed
//! carrying keys that are absent in older files. A reader that failed hard on
//! an unrecognized line would take out telemetry for an entire session the
//! first time Claude Code adds a field — and it would do it silently, because
//! nobody is watching the transcript reader.

use serde_json::Value;

use crate::{
    AssistantTurn, Compaction, FileChange, ToolUse, TranscriptEvent, TranscriptReader, Usage,
};

/// How long a tool-input summary may get before it is truncated.
///
/// A `Write` input can be a hundred kilobytes of file content and this ends up
/// in a sidebar row.
const SUMMARY_MAX: usize = 80;

#[derive(Debug, Clone, Copy, Default)]
pub struct ClaudeCodeReader;

impl ClaudeCodeReader {
    pub fn new() -> Self {
        Self
    }
}

impl TranscriptReader for ClaudeCodeReader {
    fn harness(&self) -> &'static str {
        "claude-code"
    }

    fn parse_line(&self, line: &str) -> Vec<TranscriptEvent> {
        let line = line.trim();
        if line.is_empty() {
            return Vec::new();
        }
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            return Vec::new();
        };
        let Some(object) = value.as_object() else {
            return Vec::new();
        };

        let at = string_at(object.get("timestamp"));
        let kind = object.get("type").and_then(Value::as_str).unwrap_or("");

        match kind {
            // The turn comes first and always, then any tools it invoked. The
            // turn carries the usage, and dropping it when a tool is present is
            // exactly the bug this shape prevents.
            "assistant" => parse_assistant(object.get("message"), at),

            // Claude Code's own name for the session. Not a content line and it
            // carries no timestamp; the key is camelCase where most of the
            // schema is not, which is why it is read explicitly rather than
            // guessed at.
            "ai-title" => match string_at(object.get("aiTitle")) {
                Some(text) if !text.trim().is_empty() => {
                    vec![TranscriptEvent::AiTitle { text, at }]
                }
                _ => Vec::new(),
            },

            "user" => {
                // A tool result arrives as a user line. Two spellings observed:
                // a `tool_result` content block, and a `sourceToolUseID` on the
                // line itself. Both are handled; neither is assumed.
                // The written file, when there is one, rides on the line rather
                // than inside the content block — same line, different key.
                let file = file_change(object.get("toolUseResult"));
                if let Some(id) = tool_result_id(object.get("message")) {
                    return vec![TranscriptEvent::ToolResult {
                        tool_use_id: id,
                        at,
                        file,
                    }];
                }
                if let Some(id) = object.get("sourceToolUseID").and_then(Value::as_str) {
                    return vec![TranscriptEvent::ToolResult {
                        tool_use_id: id.to_string(),
                        at,
                        file,
                    }];
                }
                vec![TranscriptEvent::UserTurn { at }]
            }

            "system" => {
                // The compaction boundary. `compactMetadata` is the interesting
                // part and `subtype: "compact_boundary"` is the label; the
                // metadata is checked first so a renamed subtype does not lose
                // the numbers.
                if let Some(meta) = object.get("compactMetadata").and_then(Value::as_object) {
                    return vec![TranscriptEvent::Compaction(Compaction {
                        trigger: string_at(meta.get("trigger")),
                        pre_tokens: u64_at(meta.get("preTokens")),
                        post_tokens: u64_at(meta.get("postTokens")),
                        at,
                    })];
                }
                vec![TranscriptEvent::Other {
                    kind: object
                        .get("subtype")
                        .and_then(Value::as_str)
                        .unwrap_or("system")
                        .to_string(),
                    at,
                }]
            }

            "" => Vec::new(),
            other => vec![TranscriptEvent::Other {
                kind: other.to_string(),
                at,
            }],
        }
    }

    fn recognizes(&self, first_lines: &[String]) -> bool {
        // Claude Code lines carry `sessionId` and `uuid` on every record type.
        // Matching on those rather than on `type` values, which are the part
        // most likely to grow new members.
        first_lines.iter().any(|line| {
            serde_json::from_str::<Value>(line.trim())
                .ok()
                .and_then(|v| {
                    let o = v.as_object()?;
                    Some(o.contains_key("sessionId") && o.contains_key("uuid"))
                })
                .unwrap_or(false)
        })
    }
}

/// One `assistant` line: always a turn, plus any tools it invoked.
///
/// The turn is emitted even when `usage` is missing or malformed — the model
/// and the timestamp are still worth having, and the [`Usage`] simply stays
/// unknown. It is emitted even when the line is *only* a `tool_use`, because
/// that line still carries the whole message's usage, and a reply that called a
/// tool without also emitting text would otherwise cost nothing at all.
///
/// Double counting is not a risk here: [`crate::Telemetry`] bills once per
/// `message.id`, and every line of a multi-block reply repeats the same id.
fn parse_assistant(message: Option<&Value>, at: Option<String>) -> Vec<TranscriptEvent> {
    let message = message.and_then(Value::as_object);

    let mut events = vec![TranscriptEvent::AssistantTurn(AssistantTurn {
        message_id: message.and_then(|m| string_at(m.get("id"))),
        model: message.and_then(|m| string_at(m.get("model"))),
        usage: message
            .and_then(|m| m.get("usage"))
            .map(parse_usage)
            .unwrap_or_default(),
        at: at.clone(),
    })];

    // Every `tool_use` in the line, not just the first. One block per line is
    // what was measured, but the format permits more and dropping the rest
    // would lose tool calls rather than merely mis-order them.
    events.extend(
        tool_uses(message.and_then(|m| m.get("content")), at)
            .into_iter()
            .map(TranscriptEvent::ToolUse),
    );
    events
}

/// `usage`, field by field, tolerating anything.
///
/// Only the four quantities that matter are read. `cache_creation`,
/// `server_tool_use`, `iterations` and the rest are left alone — modelling them
/// would be modelling a format we do not control for no gain.
fn parse_usage(value: &Value) -> Usage {
    let Some(o) = value.as_object() else {
        return Usage::default();
    };
    Usage {
        input_tokens: u64_at(o.get("input_tokens")),
        cache_creation_input_tokens: u64_at(o.get("cache_creation_input_tokens")),
        cache_read_input_tokens: u64_at(o.get("cache_read_input_tokens")),
        output_tokens: u64_at(o.get("output_tokens")),
    }
}

fn tool_uses(content: Option<&Value>, at: Option<String>) -> Vec<ToolUse> {
    let Some(blocks) = content.and_then(Value::as_array) else {
        return Vec::new();
    };
    blocks
        .iter()
        .filter_map(|block| {
            let o = block.as_object()?;
            if o.get("type").and_then(Value::as_str) != Some("tool_use") {
                return None;
            }
            // A tool_use with no name is not a tool call we can show or
            // correlate; dropping it beats inventing a name for it.
            let name = o.get("name").and_then(Value::as_str)?.to_string();
            // Decided here, with the untruncated input in hand. `summary` is
            // cut to 80 characters and one line, so a redirect at the end of a
            // long command would be gone by the time anyone downstream looked.
            let writes_untracked = name == "Bash"
                && o.get("input")
                    .and_then(|i| i.get("command"))
                    .and_then(Value::as_str)
                    .is_some_and(command_may_write);
            Some(ToolUse {
                id: string_at(o.get("id")),
                summary: summarize_input(o.get("input")),
                name,
                at: at.clone(),
                writes_untracked,
            })
        })
        .collect()
}

fn tool_result_id(message: Option<&Value>) -> Option<String> {
    for block in message?.as_object()?.get("content")?.as_array()? {
        let o = block.as_object()?;
        if o.get("type").and_then(Value::as_str) == Some("tool_result") {
            return string_at(o.get("tool_use_id"));
        }
    }
    None
}

/// The file a tool wrote, read out of `toolUseResult`.
///
/// Two shapes, both measured on this machine across every transcript under
/// `~/.claude/projects`:
///
/// - **edit** — `{filePath, oldString, newString, originalFile, replaceAll,
///   structuredPatch, userModified}`, 1256 of them. The counts come from the
///   patch.
/// - **create** — `{type: "create", filePath, content, originalFile,
///   structuredPatch, userModified}`, 452 of them, of which 387 were genuine
///   creates. Every single one carried an **empty** `structuredPatch`, so the
///   count comes from `content` instead.
///
/// Anything else returns `None`. `structuredPatch` is an undocumented field of
/// a format that changes without notice, so every step here is a question and
/// not an assumption — nothing in this file may panic on bad input, and a shape
/// this function does not recognise is simply a call that wrote no file.
fn file_change(result: Option<&Value>) -> Option<FileChange> {
    let o = result?.as_object()?;
    let path = o.get("filePath").and_then(Value::as_str)?.trim();
    if path.is_empty() {
        return None;
    }

    let created = o.get("type").and_then(Value::as_str) == Some("create");
    let (added, removed) = match o.get("structuredPatch").and_then(Value::as_array) {
        Some(hunks) if !hunks.is_empty() => count_patch(hunks),
        // A create has no patch to read: the file had no previous version to
        // diff against. Its whole content is what was added.
        _ if created => (line_count(o.get("content")), 0),
        // A recognised path with neither a patch nor content is a call that
        // touched a file without changing it — a read, or an edit that matched
        // nothing. Reporting `0/0` would put a row in a tree for a file this
        // session did not write.
        _ => return None,
    };

    Some(FileChange {
        path: path.to_string(),
        added,
        removed,
        created,
    })
}

/// Sum the `+` and `-` lines of unified-diff hunks.
///
/// A hunk's `lines` are the diff body verbatim: `+` added, `-` removed, a
/// leading space for context. Anything else — an empty line, a `\` marker for a
/// missing trailing newline — is neither, and counting it would inflate both
/// sides of a file that merely lacks a final newline.
fn count_patch(hunks: &[Value]) -> (u64, u64) {
    let mut added = 0;
    let mut removed = 0;
    for hunk in hunks {
        let Some(lines) = hunk.get("lines").and_then(Value::as_array) else {
            continue;
        };
        for line in lines.iter().filter_map(Value::as_str) {
            match line.as_bytes().first() {
                Some(b'+') => added += 1,
                Some(b'-') => removed += 1,
                _ => {}
            }
        }
    }
    (added, removed)
}

/// How many lines a written file has.
///
/// A file that does not end in a newline still has a last line, and a file that
/// does must not be counted as having an empty one after it — which is exactly
/// what `split('\n').count()` would do.
fn line_count(content: Option<&Value>) -> u64 {
    let Some(text) = content.and_then(Value::as_str) else {
        return 0;
    };
    if text.is_empty() {
        return 0;
    }
    text.lines().count() as u64
}

/// A short, human-readable rendering of a tool's input.
///
/// Prefers the fields that identify *what* the call is about, in the order a
/// person would read them. Falls back to nothing rather than to a JSON blob:
/// an unreadable summary is worse than no summary in a one-line sidebar row.
/// Whether a shell command looks like it writes files.
///
/// # Why this exists
///
/// The file list is built from `Edit` and `Write` tool results, which carry the
/// path they touched. A `Bash` that redirects into a file carries no path
/// anywhere, so those edits are invisible — and the panel, seeing an empty
/// list, used to say "nothing written yet". That is the one thing it must not
/// say: *wrote nothing* and *we did not see what it wrote* are different facts,
/// and the app already has a separate screen for the second. This is what tells
/// it which one is true.
///
/// # Why a heuristic, and why not every `Bash`
///
/// Marking the list partial on *any* `Bash` is defensible — technically any
/// command can write — and it is the wrong trade. Nearly every session runs a
/// test or a `git status`, so the caveat would be permanently on, and a caveat
/// that is always on is one nobody reads. Narrowing it to commands that look
/// like they write keeps the warning meaning something on the sessions where it
/// appears.
///
/// It errs in both directions and that is understood: `awk '$1 > 2'` trips it
/// with no write, and a script whose name gives nothing away slips past. The
/// costs are asymmetric, which is what makes the trade acceptable — a false
/// positive is a caveat on a session that did not need one, a false negative is
/// the state we are already in today.
///
/// Run on the **whole** command, before `summarize_input` truncates it to 80
/// characters and one line. A redirect at the end of a long pipeline is exactly
/// the case that matters, and it lives past the cut.
fn command_may_write(command: &str) -> bool {
    // `>` and `>>` cover redirection, including `2>` and `&>`. `<` is not here:
    // reading from a file writes nothing.
    if command.contains('>') {
        return true;
    }

    // Programs whose job is to put bytes somewhere. Matched as whole words so
    // `remove` does not match on `mv` and a path containing `cp` does not
    // count.
    const WRITERS: &[&str] = &[
        "tee", "mv", "cp", "rm", "mkdir", "touch", "install", "rsync", "ln",
        "dd", "truncate", "patch", "tar", "unzip", "curl", "wget",
    ];

    // `sed -i`, `perl -i` and friends edit in place; the same programs without
    // the flag only print, so the flag is the whole signal.
    if command.contains("-i") {
        for editor in ["sed", "perl", "ruby"] {
            if words(command).any(|w| w == editor) {
                return true;
            }
        }
    }

    words(command).any(|w| WRITERS.contains(&w))
}

/// Split on shell punctuation as well as whitespace, so `foo|tee` and
/// `(mkdir x)` are seen as the words they are rather than as one token.
fn words(command: &str) -> impl Iterator<Item = &str> {
    command
        .split(|c: char| c.is_whitespace() || "|;&()`$\"'".contains(c))
        .filter(|w| !w.is_empty())
}

fn summarize_input(input: Option<&Value>) -> Option<String> {
    let o = input?.as_object()?;

    for key in ["command", "file_path", "path", "pattern", "query", "url", "description"] {
        if let Some(text) = o.get(key).and_then(Value::as_str) {
            let text = text.trim();
            if !text.is_empty() {
                return Some(truncate(text, SUMMARY_MAX));
            }
        }
    }
    None
}

/// Truncate on a character boundary, never mid-codepoint.
///
/// Slicing bytes would panic on a multi-byte character, and tool inputs are
/// full of paths and prompts that are not ASCII.
fn truncate(text: &str, max: usize) -> String {
    let mut out: String = text.chars().take(max).collect();
    // First line only: a multi-line command rendered into a sidebar row would
    // break the layout, and the first line is the informative one.
    if let Some(newline) = out.find('\n') {
        out.truncate(newline);
        out.push('…');
        return out;
    }
    if text.chars().count() > max {
        out.push('…');
    }
    out
}

/// What a look at the *start* of a transcript can tell us about its name.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HeadScan {
    /// Claude Code's own title, if it had already generated one.
    pub ai_title: Option<String>,
    /// The text of the session's first user message.
    pub first_prompt: Option<String>,
}

impl HeadScan {
    pub fn is_empty(&self) -> bool {
        self.ai_title.is_none() && self.first_prompt.is_none()
    }
}

/// How far into a transcript to look for a name.
///
/// `ai-title` was measured landing on line 12 of every transcript that has one,
/// and one case at 127 after a resume. 512 covers both with room to spare while
/// staying a bounded read on a file that can be 15 MB.
const HEAD_SCAN_LINES: usize = 512;

/// Read the head of a transcript for the two things that can name a session.
///
/// This is what answers the adopted-session case. A session already running
/// when violeet first saw it has no first `UserPromptSubmit` to hook — but its
/// first prompt is still sitting in the file, and so, usually, is Claude Code's
/// own title. Reading them gives an adopted session **the same name by the same
/// rules** as one violeet started, which is what keeps the sidebar to a single
/// register instead of two kinds of card.
///
/// Deliberately separate from the tail reader, which starts at the end on
/// purpose (replaying a 15 MB backlog as if it were live would flood the
/// sidebar). This reads forward from the start, stops at
/// [`HEAD_SCAN_LINES`] or as soon as it has both answers, and is run once.
pub fn scan_head(path: &std::path::Path) -> std::io::Result<HeadScan> {
    use std::io::BufRead;

    let file = std::fs::File::open(path)?;
    let mut found = HeadScan::default();

    for line in std::io::BufReader::new(file).lines().take(HEAD_SCAN_LINES) {
        let Ok(line) = line else { continue };
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let Some(object) = value.as_object() else { continue };

        match object.get("type").and_then(Value::as_str) {
            Some("ai-title") => {
                if let Some(t) = string_at(object.get("aiTitle")) {
                    if !t.trim().is_empty() {
                        found.ai_title = Some(t);
                    }
                }
            }
            Some("user") if found.first_prompt.is_none() => {
                // A tool result also arrives as a `user` line. It is not a
                // prompt, and naming a session after one would be naming it
                // after its own output.
                if tool_result_id(object.get("message")).is_some()
                    || object.get("sourceToolUseID").is_some()
                {
                    continue;
                }
                if let Some(text) = user_text(object.get("message")) {
                    found.first_prompt = Some(text);
                }
            }
            _ => {}
        }

        if found.ai_title.is_some() && found.first_prompt.is_some() {
            break;
        }
    }
    Ok(found)
}

/// The text of a user message, whether the content is a bare string or the
/// block form.
fn user_text(message: Option<&Value>) -> Option<String> {
    let content = message?.get("content")?;
    if let Some(s) = content.as_str() {
        return (!s.trim().is_empty()).then(|| s.to_string());
    }
    let blocks = content.as_array()?;
    for block in blocks {
        if block.get("type").and_then(Value::as_str) == Some("text") {
            if let Some(t) = string_at(block.get("text")) {
                if !t.trim().is_empty() {
                    return Some(t);
                }
            }
        }
    }
    None
}

fn string_at(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?;
    // An empty string is not a value. It renders as a blank where the truth is
    // "we do not know", which is the same fabrication `null` exists to avoid.
    (!text.is_empty()).then(|| text.to_string())
}

/// A `u64` from a JSON number, tolerating a float and refusing a negative.
///
/// A negative token count is not a small number, it is a broken reading, and
/// clamping it to zero would turn corruption into a plausible value.
fn u64_at(value: Option<&Value>) -> Option<u64> {
    let n = value?.as_f64()?;
    if !n.is_finite() || n < 0.0 {
        return None;
    }
    Some(n as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reader() -> ClaudeCodeReader {
        ClaudeCodeReader::new()
    }

    /// The exact shape measured in a real file, usage block included.
    #[test]
    fn an_assistant_line_yields_its_usage_and_model() {
        let line = r#"{"type":"assistant","timestamp":"2026-07-31T22:00:00Z","uuid":"u1","sessionId":"s1","message":{"id":"msg_01","model":"claude-sonnet-5","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":26111,"cache_creation_input_tokens":16189,"cache_read_input_tokens":25153,"output_tokens":3491}}}"#;

        let events = reader().parse_line(line);
        let Some(TranscriptEvent::AssistantTurn(turn)) = events.first() else {
            panic!("expected an assistant turn, got {events:?}");
        };
        assert_eq!(turn.message_id.as_deref(), Some("msg_01"));
        assert_eq!(turn.model.as_deref(), Some("claude-sonnet-5"));
        assert_eq!(turn.usage.output_tokens, Some(3491));
        // The measured definition of occupancy: the three prompt components.
        assert_eq!(turn.usage.prompt_tokens(), Some(26111 + 16189 + 25153));
    }

    /// Straight from an observed `compact_boundary` line.
    #[test]
    fn a_compaction_boundary_yields_the_measured_before_and_after() {
        let line = r#"{"type":"system","subtype":"compact_boundary","timestamp":"2026-07-31T22:00:00Z","compactMetadata":{"trigger":"manual","preTokens":337228,"postTokens":15850,"cumulativeDroppedTokens":321378}}"#;

        let events = reader().parse_line(line);
        let Some(TranscriptEvent::Compaction(c)) = events.first() else {
            panic!("expected a compaction, got {events:?}");
        };
        assert_eq!(c.trigger.as_deref(), Some("manual"));
        assert_eq!(c.pre_tokens, Some(337_228));
        assert_eq!(c.post_tokens, Some(15_850));
    }

    #[test]
    fn a_tool_use_block_becomes_a_tool_event_with_a_short_summary() {
        let line = r#"{"type":"assistant","message":{"id":"m1","model":"claude-sonnet-5","content":[{"type":"tool_use","id":"toolu_9","name":"Bash","input":{"command":"cargo test --all","description":"run tests"}}],"usage":{"output_tokens":5}}}"#;

        let events = reader().parse_line(line);
        let Some(TranscriptEvent::ToolUse(tool)) = events.get(1) else {
            panic!("expected a turn then a tool use, got {events:?}");
        };
        assert_eq!(tool.name, "Bash");
        assert_eq!(tool.id.as_deref(), Some("toolu_9"));
        assert_eq!(tool.summary.as_deref(), Some("cargo test --all"));
    }

    #[test]
    fn both_observed_spellings_of_a_tool_result_are_recognized() {
        let block = r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_9"}]}}"#;
        let field = r#"{"type":"user","sourceToolUseID":"toolu_9","message":{"content":"ok"}}"#;

        for line in [block, field] {
            match reader().parse_line(line).first() {
                Some(TranscriptEvent::ToolResult { tool_use_id, .. }) => {
                    assert_eq!(tool_use_id, "toolu_9")
                }
                other => panic!("expected a tool result, got {other:?}"),
            }
        }
    }

    /// The property the whole module is built around: garbage in, `None` out,
    /// never a panic and never an `Err`.
    #[test]
    fn malformed_input_never_panics_and_never_errors() {
        let cases = [
            "",
            "   ",
            "not json at all",
            "[1,2,3]",
            "null",
            "42",
            r#"{"type":"assistant"}"#,
            r#"{"type":"assistant","message":"a string, not an object"}"#,
            r#"{"type":"assistant","message":{"usage":"also a string"}}"#,
            r#"{"type":"assistant","message":{"usage":{"input_tokens":"nope"}}}"#,
            r#"{"type":"assistant","message":{"usage":{"input_tokens":-5}}}"#,
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use"}]}}"#,
            r#"{"type":"system","compactMetadata":[]}"#,
            r#"{"type":"user","message":{"content":[{"type":"tool_result"}]}}"#,
            r#"{"invented_by_a_future_version":true}"#,
        ];

        for case in cases {
            // The assertion is that this line returns at all.
            let _ = reader().parse_line(case);
        }
    }

    /// A negative count is corruption, not a small number.
    #[test]
    fn a_negative_token_count_is_unknown_rather_than_clamped_to_zero() {
        let line = r#"{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":-5,"output_tokens":10}}}"#;
        let events = reader().parse_line(line);
        let Some(TranscriptEvent::AssistantTurn(turn)) = events.first() else {
            panic!("expected a turn, got {events:?}");
        };
        assert_eq!(turn.usage.input_tokens, None, "not Some(0)");
        assert_eq!(turn.usage.output_tokens, Some(10));
    }

    #[test]
    fn a_summary_is_cut_on_a_character_boundary() {
        let long = "ç".repeat(200);
        let line = format!(
            r#"{{"type":"assistant","message":{{"content":[{{"type":"tool_use","name":"Bash","input":{{"command":"{long}"}}}}]}}}}"#
        );
        let events = reader().parse_line(&line);
        let Some(TranscriptEvent::ToolUse(tool)) = events.get(1) else {
            panic!("expected a turn then a tool use, got {events:?}");
        };
        let summary = tool.summary.clone().unwrap();
        assert!(summary.chars().count() <= SUMMARY_MAX + 1);
        assert!(summary.ends_with('…'));
    }

    #[test]
    fn a_multiline_command_is_reduced_to_its_first_line() {
        let line = r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cd /tmp\nrm -rf x\necho done"}}]}}"#;
        let events = reader().parse_line(line);
        let Some(TranscriptEvent::ToolUse(tool)) = events.get(1) else {
            panic!("expected a turn then a tool use, got {events:?}");
        };
        assert_eq!(tool.summary.as_deref(), Some("cd /tmp…"));
    }

    #[test]
    fn recognition_keys_on_fields_present_in_every_record_type() {
        let claude = vec![r#"{"type":"mode","uuid":"u","sessionId":"s"}"#.to_string()];
        let foreign = vec![r#"{"role":"assistant","content":"hi"}"#.to_string()];

        assert!(reader().recognizes(&claude));
        assert!(!reader().recognizes(&foreign));
    }

    #[test]
    fn an_empty_string_field_is_unknown_and_not_an_empty_value() {
        let line = r#"{"type":"assistant","message":{"id":"","model":"","usage":{}}}"#;
        let events = reader().parse_line(line);
        let Some(TranscriptEvent::AssistantTurn(turn)) = events.first() else {
            panic!("expected a turn, got {events:?}");
        };
        assert_eq!(turn.message_id, None);
        assert_eq!(turn.model, None);
    }

    // ---- file changes ---------------------------------------------------

    fn file_of(line: &str) -> Option<FileChange> {
        match reader().parse_line(line).into_iter().next() {
            Some(TranscriptEvent::ToolResult { file, .. }) => file,
            other => panic!("expected a tool result, got {other:?}"),
        }
    }

    /// The `Edit` shape, verbatim from a measured result: hunk lines prefixed
    /// `+`, `-` and space.
    #[test]
    fn an_edit_counts_the_lines_of_its_patch() {
        let line = r#"{"type":"user","uuid":"u1","sessionId":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]},"toolUseResult":{"filePath":"/repo/src/main.rs","oldString":"a","newString":"b","replaceAll":false,"userModified":false,"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":4,"lines":[" ctx","-gone","+new","+also new"]}]}}"#;

        let file = file_of(line).expect("an edit writes a file");
        assert_eq!(file.path, "/repo/src/main.rs");
        assert_eq!(file.added, 2);
        assert_eq!(file.removed, 1);
        assert!(!file.created, "editing is not creating");
    }

    /// Every one of the 387 measured creates carried an empty patch, so the
    /// count has to come from the content or it comes from nowhere.
    #[test]
    fn a_created_file_is_counted_from_its_content_because_the_patch_is_empty() {
        let line = r#"{"type":"user","uuid":"u1","sessionId":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]},"toolUseResult":{"type":"create","filePath":"/repo/notes/new.md","content":"one\ntwo\nthree\n","structuredPatch":[],"userModified":false}}"#;

        let file = file_of(line).expect("a create writes a file");
        assert_eq!(file.path, "/repo/notes/new.md");
        assert_eq!(file.added, 3, "a trailing newline does not add a fourth line");
        assert_eq!(file.removed, 0);
        assert!(file.created);
    }

    /// The failure this guards is a tree with a row per shell command.
    #[test]
    fn a_bash_result_writes_no_file() {
        let line = r#"{"type":"user","uuid":"u1","sessionId":"s1","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]},"toolUseResult":{"stdout":"ok","stderr":"","interrupted":false,"isImage":false}}"#;
        assert_eq!(file_of(line), None);
    }

    /// An unknown shape is a call that wrote nothing, never a panic and never a
    /// `0/0` row — `structuredPatch` is undocumented and may change.
    #[test]
    fn an_unrecognised_result_shape_is_not_a_file_and_not_a_panic() {
        for line in [
            // A path with neither patch nor content: a read, or an edit that
            // matched nothing.
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]},"toolUseResult":{"filePath":"/repo/a.rs"}}"#,
            // The patch is not the shape we expect.
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]},"toolUseResult":{"filePath":"/repo/a.rs","structuredPatch":"nope"}}"#,
            // An empty path names no file.
            r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]},"toolUseResult":{"filePath":"   ","structuredPatch":[{"lines":["+x"]}]}}"#,
        ] {
            assert_eq!(file_of(line), None, "line: {line}");
        }
    }

    /// Neither a context line nor the `\ No newline` marker is a change.
    #[test]
    fn only_plus_and_minus_lines_count() {
        let line = r#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]},"toolUseResult":{"filePath":"/repo/a.rs","structuredPatch":[{"lines":[" ctx","","\\ No newline at end of file","+one"]}]}}"#;

        let file = file_of(line).expect("there is a plus line");
        assert_eq!((file.added, file.removed), (1, 0));
    }

    // ---- shell writes ---------------------------------------------------

    /// The command that exposed the bug, verbatim from the session that found
    /// it: a hundred files appended to through a redirect, none of which could
    /// ever reach the file list.
    #[test]
    fn the_command_that_found_this_bug_is_caught() {
        let line = r#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"while IFS= read -r f; do printf '\\n' >> \"$f\"; done < /tmp/list"}}]}}"#;
        let events = reader().parse_line(line);
        let tool = events
            .iter()
            .find_map(|e| match e {
                TranscriptEvent::ToolUse(t) => Some(t),
                _ => None,
            })
            .expect("a tool use");
        assert!(tool.writes_untracked);
    }

    /// The redirect can sit past the 80-character cut that `summary` makes,
    /// which is why the verdict is taken from the untruncated input.
    #[test]
    fn a_redirect_beyond_the_summary_cut_still_counts() {
        let long = format!("echo {} > out.txt", "a".repeat(200));
        assert!(command_may_write(&long));
        assert!(truncate(&long, SUMMARY_MAX).chars().count() <= SUMMARY_MAX + 1);
        assert!(!truncate(&long, SUMMARY_MAX).contains('>'), "the cut hides it");
    }

    /// The commands a session runs constantly. If these tripped it, the caveat
    /// would be permanently on, and a caveat that is always on is one nobody
    /// reads.
    #[test]
    fn ordinary_commands_do_not_count_as_writes() {
        for command in [
            "cargo test --all",
            "git status --porcelain",
            "ls -la",
            "grep -rn foo src/",
            "swift build",
            "cat README.md",
            "git diff HEAD",
        ] {
            assert!(!command_may_write(command), "{command}");
        }
    }

    #[test]
    fn writing_commands_count() {
        for command in [
            "echo hi > file.txt",
            "printf x >> log",
            "cat a | tee b",
            "mv old new",
            "cp -r src dst",
            "mkdir -p a/b",
            "sed -i '' 's/a/b/' file",
            "curl -o out.zip https://example.com",
        ] {
            assert!(command_may_write(command), "{command}");
        }
    }

    /// Whole words only. A path that merely contains a writer's name is not a
    /// call to it — this is what keeps `grep` over a directory called `cp/`
    /// from marking the session.
    #[test]
    fn a_writers_name_inside_a_word_is_not_a_write() {
        assert!(!command_may_write("grep -rn foo src/cpp/"));
        assert!(!command_may_write("cargo test --lib remove_stale"));
        assert!(!command_may_write("./scripts/movies.sh"));
    }

    /// `sed` without `-i` prints and writes nothing; the flag is the signal.
    #[test]
    fn sed_only_counts_in_place() {
        assert!(!command_may_write("sed 's/a/b/' file"));
        assert!(command_may_write("sed -i.bak 's/a/b/' file"));
    }

    /// Shell punctuation separates words, so a writer glued to a pipe is still
    /// found.
    #[test]
    fn punctuation_separates_words() {
        assert!(command_may_write("cat a|tee b"));
        assert!(command_may_write("(mkdir x)"));
        assert!(command_may_write("false; mv a b"));
    }

    /// Only `Bash` is judged. A `Write` reports its own path and belongs in the
    /// list, so flagging it would caveat a session whose writes are all visible.
    #[test]
    fn only_bash_is_judged() {
        let line = r#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"/tmp/a > b"}}]}}"#;
        let tool = reader()
            .parse_line(line)
            .iter()
            .find_map(|e| match e {
                TranscriptEvent::ToolUse(t) => Some(t.clone()),
                _ => None,
            })
            .expect("a tool use");
        assert!(!tool.writes_untracked);
    }
}
