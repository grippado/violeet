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

use crate::{AssistantTurn, Compaction, ToolUse, TranscriptEvent, TranscriptReader, Usage};

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

            "user" => {
                // A tool result arrives as a user line. Two spellings observed:
                // a `tool_result` content block, and a `sourceToolUseID` on the
                // line itself. Both are handled; neither is assumed.
                if let Some(id) = tool_result_id(object.get("message")) {
                    return vec![TranscriptEvent::ToolResult { tool_use_id: id, at }];
                }
                if let Some(id) = object.get("sourceToolUseID").and_then(Value::as_str) {
                    return vec![TranscriptEvent::ToolResult {
                        tool_use_id: id.to_string(),
                        at,
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
            Some(ToolUse {
                id: string_at(o.get("id")),
                summary: summarize_input(o.get("input")),
                name,
                at: at.clone(),
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

/// A short, human-readable rendering of a tool's input.
///
/// Prefers the fields that identify *what* the call is about, in the order a
/// person would read them. Falls back to nothing rather than to a JSON blob:
/// an unreadable summary is worse than no summary in a one-line sidebar row.
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
}
