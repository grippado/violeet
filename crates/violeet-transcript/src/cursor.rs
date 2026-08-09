//! The Cursor agent JSONL reader.
//!
//! Cursor writes one JSON object per line under
//! `~/.cursor/projects/.../agent-transcripts/`, with `role` and `message`
//! rather than Claude Code's `type`/`sessionId` shape.
//!
//! # Defensive on purpose
//!
//! Same contract as [`crate::claude_code::ClaudeCodeReader`]: malformed input
//! yields empty or partial events, never a panic and never an error.

use serde_json::Value;

use crate::{
    AssistantTurn, ToolUse, TranscriptEvent, TranscriptReader, Usage,
};

const SUMMARY_MAX: usize = 80;

#[derive(Debug, Clone, Copy, Default)]
pub struct CursorReader;

impl CursorReader {
    pub fn new() -> Self {
        Self
    }
}

impl TranscriptReader for CursorReader {
    fn harness(&self) -> &'static str {
        "cursor"
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

        let at = string_at(object.get("timestamp"))
            .or_else(|| message_field(object.get("message"), "timestamp"));

        match object.get("role").and_then(Value::as_str) {
            Some("assistant") => parse_assistant(object.get("message"), at),
            Some("user") => vec![TranscriptEvent::UserTurn { at }],
            Some("") | None => Vec::new(),
            other => vec![TranscriptEvent::Other {
                kind: other.unwrap_or("unknown").to_string(),
                at,
            }],
        }
    }

    fn recognizes(&self, first_lines: &[String]) -> bool {
        first_lines.iter().any(|line| {
            serde_json::from_str::<Value>(line.trim())
                .ok()
                .and_then(|v| {
                    let o = v.as_object()?;
                    Some(o.contains_key("role") && o.contains_key("message"))
                })
                .unwrap_or(false)
        })
    }
}

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

    events.extend(
        tool_uses(message.and_then(|m| m.get("content")), at)
            .into_iter()
            .map(TranscriptEvent::ToolUse),
    );
    events
}

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
            let name = o.get("name").and_then(Value::as_str)?.to_string();
            let writes_untracked = (name == "Shell" || name == "Bash")
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

fn message_field(message: Option<&Value>, key: &str) -> Option<String> {
    string_at(message?.as_object()?.get(key))
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

fn command_may_write(command: &str) -> bool {
    if command.contains('>') {
        return true;
    }
    const WRITERS: &[&str] = &[
        "tee", "mv", "cp", "rm", "mkdir", "touch", "install", "rsync", "ln",
    ];
    if command.contains("-i") {
        for editor in ["sed", "perl", "ruby"] {
            if words(command).any(|w| w == editor) {
                return true;
            }
        }
    }
    words(command).any(|w| WRITERS.contains(&w))
}

fn words(command: &str) -> impl Iterator<Item = &str> {
    command
        .split(|c: char| c.is_whitespace() || "|;&()`$\"'".contains(c))
        .filter(|w| !w.is_empty())
}

fn truncate(text: &str, max: usize) -> String {
    let mut out: String = text.chars().take(max).collect();
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

fn string_at(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?;
    (!text.is_empty()).then(|| text.to_string())
}

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
    use std::path::Path;

    fn reader() -> CursorReader {
        CursorReader::new()
    }

    #[test]
    fn an_assistant_line_yields_usage_model_and_tools() {
        let line = r#"{"role":"assistant","timestamp":"2026-08-09T20:00:00Z","message":{"id":"gen-1","model":"composer-2","usage":{"input_tokens":1000,"cache_read_input_tokens":50000,"output_tokens":40},"content":[{"type":"text","text":"ok"},{"type":"tool_use","name":"Shell","input":{"command":"cargo test","description":"run tests"}}]}}"#;

        let events = reader().parse_line(line);
        let Some(TranscriptEvent::AssistantTurn(turn)) = events.first() else {
            panic!("expected an assistant turn, got {events:?}");
        };
        assert_eq!(turn.message_id.as_deref(), Some("gen-1"));
        assert_eq!(turn.model.as_deref(), Some("composer-2"));
        assert_eq!(turn.usage.output_tokens, Some(40));
        assert_eq!(turn.usage.prompt_tokens(), Some(51_000));

        let Some(TranscriptEvent::ToolUse(tool)) = events.get(1) else {
            panic!("expected a tool use, got {events:?}");
        };
        assert_eq!(tool.name, "Shell");
        assert_eq!(tool.summary.as_deref(), Some("cargo test"));
    }

    #[test]
    fn a_user_line_is_a_turn() {
        let line = r#"{"role":"user","message":{"content":[{"type":"text","text":"hello"}]}}"#;
        let events = reader().parse_line(line);
        assert!(matches!(events.as_slice(), [TranscriptEvent::UserTurn { .. }]));
    }

    #[test]
    fn malformed_input_never_panics() {
        for case in [
            "",
            "not json",
            r#"{"role":"assistant"}"#,
            r#"{"role":"assistant","message":"nope"}"#,
            r#"{"role":"assistant","message":{"usage":"bad"}}"#,
        ] {
            let _ = reader().parse_line(case);
        }
    }

    #[test]
    fn recognition_keys_on_role_and_message() {
        let cursor = vec![r#"{"role":"user","message":{"content":[]}}"#.to_string()];
        let claude = vec![r#"{"type":"user","sessionId":"s","uuid":"u"}"#.to_string()];

        assert!(reader().recognizes(&cursor));
        assert!(!reader().recognizes(&claude));
    }

    #[test]
    fn fixture_file_parses_like_inline_samples() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/cursor_minimal.jsonl");
        let text = std::fs::read_to_string(path).expect("fixture readable");
        let mut turns = 0;
        let mut tools = 0;
        for line in text.lines() {
            for event in reader().parse_line(line) {
                match event {
                    TranscriptEvent::AssistantTurn(_) => turns += 1,
                    TranscriptEvent::ToolUse(_) => tools += 1,
                    _ => {}
                }
            }
        }
        assert_eq!(turns, 1);
        assert_eq!(tools, 1);
    }
}
