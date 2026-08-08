//! The gate: a session waiting on a background agent must not read as free, and
//! a session waiting on a **person** must not read as busy.
//!
//! This is the acceptance criterion for `pending_agents`. It replays every
//! transcript under `~/.claude/projects` through the real reader and the real
//! [`Telemetry`], stops at every point where the `Stop` hook fired, and asserts
//! **both directions** at that instant:
//!
//! 1. a stop point the file proves was waiting on an agent reported a non-zero
//!    count, and
//! 2. a stop point that was waiting on a person reported `0`.
//!
//! Direction 2 is the one that was missing, and its absence was not academic:
//! `pub fn pending_agents(&self) -> u64 { 1 }` passed the old gate comfortably.
//! One assertion measures recall and the other precision, and only a rule that
//! actually reads the file can satisfy both.
//!
//! # The second opinion, and why it does not share the reader
//!
//! Ground truth here is computed by [`second_opinion`], written from the JSON up
//! and deliberately **not** using [`ClaudeCodeReader`]. The old version of this
//! file reused the production reader to decide what a stop point was waiting on,
//! and inherited its blind spot exactly: the reader could not see a notification
//! delivered on an `attachment` line, so 130 of 358 notifications were missing
//! from the *denominator* as well as from the answer. The gate agreed with the
//! bug and reported 99% coverage.
//!
//! A second implementation can be wrong too. What it cannot be is wrong in the
//! same direction for the same reason, which is the only property that makes a
//! gate worth having. Twice now on this project it is what caught the thing the
//! first implementation could not see.
//!
//! # Live corpus, plus fixtures
//!
//! The corpus test skips on a machine with no Claude Code — on CI it proves
//! nothing. [`the_four_shapes_are_read_from_fixtures`] is the part that can fail
//! there: one reduced file per shape, committed, exact expectations. It does not
//! replace the live gate, it makes the CI run non-empty.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde_json::Value;
use violeet_transcript::{claude_projects_dir, ClaudeCodeReader, Telemetry, TranscriptReader};

/// The fewest agent stop points this corpus must offer for the gate to mean
/// anything. The reading when this was written was 173.
const MIN_AGENT_STOPS: usize = 120;

/// How many stop points waiting on an agent may report zero, in percent.
///
/// Measured at **0 of 209** once the `attachment` delivery was read, so the
/// allowance is headroom on a live corpus and not a budget being spent. It is
/// there for one known shape: `SendMessage` resumes an agent that had already
/// reported in, and its result announces the resume in prose with no structural
/// marker at all — no `isAsync`, no `status`, no id beyond the one in the tool's
/// input. Deliberately tight, because a miss reads as a free session that is not.
const MAX_MISS_PERCENT: usize = 2;

/// How many stop points waiting on a **person** may report a positive count, in
/// percent of those stop points.
///
/// This is the cap the field's whole justification rests on. A false positive is
/// a card that says "3 agents running" at a session that is holding the keyboard
/// out to you, and unlike a miss it does not correct itself on the next read —
/// there is no next read, because nothing more is written. Measured at **1 of
/// 664** when this was set — it was 233 of 664 before this branch.
const MAX_FALSE_POSITIVE_PERCENT: usize = 1;

// ---------------------------------------------------------------------------
// The second opinion
// ---------------------------------------------------------------------------

/// What the file itself says about one stop point, decided without the reader.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Truth {
    /// A launch was outstanding here and the file later carries its
    /// notification: this session was demonstrably waiting on an agent.
    WaitingOnAgent,
    /// Nothing was outstanding, or what was outstanding never reports again and
    /// a person spoke next. Either way the honest count is zero — and in the
    /// second case a positive count is a claim that can never be withdrawn.
    WaitingOnHuman,
    /// Neither can be established. Not asserted on in either direction.
    Undecidable,
}

/// Ground truth per stop point, keyed by line index.
///
/// Independent of [`ClaudeCodeReader`] on purpose — see the module note. It
/// reaches into the JSON directly and makes its own decisions about what a
/// launch, a notification and a human turn are.
fn second_opinion(lines: &[Value]) -> Vec<(usize, Truth)> {
    // Every notification id anywhere in the file, and where it appeared.
    let mut notified: HashMap<String, usize> = HashMap::new();
    for (i, line) in lines.iter().enumerate() {
        for id in notification_ids(line) {
            notified.entry(id).or_insert(i);
        }
    }

    let mut out = Vec::new();
    // key -> the ids that would close it
    let mut open: HashMap<String, Vec<String>> = HashMap::new();

    for (i, line) in lines.iter().enumerate() {
        if let Some((tool_use_id, agent_id)) = launch(line) {
            // An `agentId` is required: without it the notification may arrive
            // carrying only a task id this launch never announced, and the two
            // ends share no key. Same call the production rule makes, reached
            // independently.
            open.insert(
                tool_use_id.clone().unwrap_or_else(|| agent_id.clone()),
                vec![tool_use_id.unwrap_or_default(), agent_id],
            );
        }
        for id in notification_ids(line) {
            open.retain(|key, ids| *key != id && !ids.contains(&id));
        }

        if !is_stop_point(line) {
            continue;
        }
        if open.is_empty() {
            out.push((i, Truth::WaitingOnHuman));
            continue;
        }
        // Does the file later prove any of these were genuinely out? A
        // notification *after* this line is the proof.
        let proven = open
            .values()
            .flatten()
            .any(|id| notified.get(id).is_some_and(|at| *at > i));
        if proven {
            out.push((i, Truth::WaitingOnAgent));
        } else if next_turn_is_human(lines, i) {
            // Nothing outstanding here ever reports, and a person spoke next.
            // A positive count at this point is the permanent lie.
            out.push((i, Truth::WaitingOnHuman));
        } else {
            out.push((i, Truth::Undecidable));
        }
    }
    out
}

/// Was this line a background launch acknowledgement, and with which ids?
///
/// `None` unless the result is marked async **and** carries an `agentId`.
fn launch(line: &Value) -> Option<(Option<String>, String)> {
    let result = line.get("toolUseResult")?.as_object()?;
    let is_async = result.get("isAsync").and_then(Value::as_bool) == Some(true)
        || result.get("status").and_then(Value::as_str) == Some("async_launched");
    if !is_async {
        return None;
    }
    let agent_id = result.get("agentId")?.as_str()?.trim();
    if agent_id.is_empty() {
        return None;
    }
    let tool_use_id = line
        .get("message")?
        .get("content")?
        .as_array()?
        .iter()
        .find(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
        .and_then(|b| b.get("tool_use_id")?.as_str())
        .map(str::to_string);
    Some((tool_use_id, agent_id.to_string()))
}

/// Every id a `<task-notification>` on this line carries — from either delivery.
///
/// Both shapes are read here, because the point of the second opinion is to know
/// about the `attachment` delivery *whether or not* the reader does.
fn notification_ids(line: &Value) -> Vec<String> {
    let mut texts: Vec<String> = Vec::new();
    if let Some(text) = line
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(Value::as_str)
    {
        texts.push(text.to_string());
    }
    if let Some(prompt) = line.get("attachment").and_then(|a| a.get("prompt")) {
        match prompt {
            Value::String(s) => texts.push(s.clone()),
            Value::Array(blocks) => texts.push(
                blocks
                    .iter()
                    .filter_map(|b| b.get("text")?.as_str())
                    .collect(),
            ),
            _ => {}
        }
    }

    let mut ids = Vec::new();
    for text in texts {
        if !text.contains("<task-notification>") {
            continue;
        }
        for name in ["tool-use-id", "task-id"] {
            let open = format!("<{name}>");
            if let Some(start) = text.find(&open) {
                let rest = &text[start + open.len()..];
                if let Some(end) = rest.find(&format!("</{name}>")) {
                    let value = rest[..end].trim();
                    if !value.is_empty() {
                        ids.push(value.to_string());
                    }
                }
            }
        }
    }
    ids
}

fn is_stop_point(line: &Value) -> bool {
    line.get("type").and_then(Value::as_str) == Some("system")
        && line.get("subtype").and_then(Value::as_str) == Some("stop_hook_summary")
}

/// Did a **person** speak next?
///
/// The next user-ish line within five, and only if it is neither a tool result
/// nor a notification in either delivery. Five lines is the window the spike
/// `docs/spikes/2026-08-08-parada-nao-e-pergunta.md` measured with.
fn next_turn_is_human(lines: &[Value], from: usize) -> bool {
    for line in lines.iter().skip(from + 1).take(5) {
        if !notification_ids(line).is_empty() {
            return false;
        }
        if line.get("type").and_then(Value::as_str) != Some("user") {
            continue;
        }
        let is_tool_result = line.get("sourceToolUseID").is_some()
            || line
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(Value::as_array)
                .is_some_and(|blocks| {
                    blocks
                        .iter()
                        .any(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
                });
        if is_tool_result {
            continue;
        }
        return true;
    }
    false
}

/// The count the daemon would have published at `stop`, from the real reader.
///
/// `now` is the stop line's own timestamp, which is what wall clock read at that
/// instant — so the age limit is exercised exactly as it would have been live.
fn replay(lines: &[Value]) -> HashMap<usize, u64> {
    let reader = ClaudeCodeReader::new();
    let mut telemetry = Telemetry::new();
    let mut readings = HashMap::new();

    for (i, line) in lines.iter().enumerate() {
        for event in reader.parse_line(&line.to_string()) {
            telemetry.apply(&event);
        }
        if !is_stop_point(line) {
            continue;
        }
        let now = line
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(|t| DateTime::parse_from_rfc3339(t).ok())
            .map(|t| t.with_timezone(&Utc))
            .unwrap_or_else(Utc::now);
        readings.insert(i, telemetry.pending_agents(now));
    }
    readings
}

fn parse(text: &str) -> Vec<Value> {
    text.lines()
        .map(|l| serde_json::from_str(l).unwrap_or(Value::Null))
        .collect()
}

// ---------------------------------------------------------------------------
// The live gate
// ---------------------------------------------------------------------------

fn transcripts() -> Vec<PathBuf> {
    let Some(root) = claude_projects_dir() else {
        return Vec::new();
    };
    let mut files = Vec::new();
    collect(&root, &mut files, 0);
    files.sort();
    files
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>, depth: usize) {
    if depth > 3 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect(&path, out, depth + 1);
        } else if path.extension().is_some_and(|e| e == "jsonl") {
            out.push(path);
        }
    }
}

#[derive(Default)]
struct Tally {
    agent_stops: usize,
    misses: usize,
    human_stops: usize,
    false_positives: usize,
    undecidable: usize,
}

fn tally(lines: &[Value], into: &mut Tally) {
    let readings = replay(lines);
    for (i, truth) in second_opinion(lines) {
        let reading = readings.get(&i).copied().unwrap_or(0);
        match truth {
            Truth::WaitingOnAgent => {
                into.agent_stops += 1;
                if reading == 0 {
                    into.misses += 1;
                }
            }
            Truth::WaitingOnHuman => {
                into.human_stops += 1;
                if reading > 0 {
                    into.false_positives += 1;
                }
            }
            Truth::Undecidable => into.undecidable += 1,
        }
    }
}

#[test]
fn a_stop_point_reports_what_it_was_actually_waiting_on() {
    let files = transcripts();
    if files.is_empty() {
        eprintln!("skipped: no transcripts under ~/.claude/projects");
        return;
    }

    let mut t = Tally::default();
    for path in &files {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        tally(&parse(&text), &mut t);
    }

    eprintln!(
        "corpus: {} files, {} stop points waiting on an agent, {} waiting on a person, \
         {} undecidable",
        files.len(),
        t.agent_stops,
        t.human_stops,
        t.undecidable
    );
    eprintln!(
        "waiting on an agent and said so: {} of {}",
        t.agent_stops - t.misses,
        t.agent_stops
    );
    eprintln!(
        "waiting on a person and claimed an agent: {} of {}",
        t.false_positives, t.human_stops
    );

    assert!(
        t.agent_stops >= MIN_AGENT_STOPS,
        "only {} agent stop points in the corpus: the gate would pass without \
         checking anything",
        t.agent_stops
    );
    assert!(
        t.misses * 100 <= t.agent_stops * MAX_MISS_PERCENT,
        "{} of {} stop points waiting on an agent reported 0, which renders as free",
        t.misses,
        t.agent_stops
    );
    assert!(
        t.false_positives * 100 <= t.human_stops * MAX_FALSE_POSITIVE_PERCENT,
        "{} of {} stop points waiting on a person reported a running agent, which \
         is the error that never corrects itself",
        t.false_positives,
        t.human_stops
    );
}

// ---------------------------------------------------------------------------
// Fixtures: the part that can fail on CI
// ---------------------------------------------------------------------------

/// One reduced file per shape, with the exact count each must produce.
///
/// The live gate above is a no-op wherever `~/.claude/projects` does not exist,
/// which is every CI machine — it prints "skipped" and passes, and a gate that
/// cannot fail is not a gate. These four are committed so the rule has something
/// to break against anywhere.
///
/// Exact numbers rather than rates, because a fixture is not a sample.
#[test]
fn the_four_shapes_are_read_from_fixtures() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/pending_agents");

    // (file, count at the stop point, why)
    let cases = [
        (
            "agent_launch_then_notification.jsonl",
            0,
            "the notification arrived on a user line and closed the wait",
        ),
        (
            "agent_launch_still_running.jsonl",
            1,
            "launched, acknowledged, nothing back yet",
        ),
        (
            "notification_in_attachment.jsonl",
            0,
            "the notification arrived as a queued command and still closed the wait",
        ),
        (
            "workflow_launch_without_agent_id.jsonl",
            0,
            "no agentId: the two ends share no key, so this launch is not counted",
        ),
        (
            "backgrounded_shell.jsonl",
            0,
            "a backgrounded shell command is not an agent",
        ),
        (
            "agent_launch_abandoned.jsonl",
            0,
            "older than the age limit and never reported: the backstop fires",
        ),
    ];

    for (name, expected, why) in cases {
        let text = std::fs::read_to_string(dir.join(name))
            .unwrap_or_else(|e| panic!("fixture {name}: {e}"));
        let lines = parse(&text);
        let readings = replay(&lines);
        assert_eq!(readings.len(), 1, "{name}: expected exactly one stop point");
        let reading = *readings.values().next().unwrap();
        assert_eq!(reading, expected, "{name}: {why}");

        // And the second opinion agrees about what the file was waiting on, so a
        // fixture cannot drift into asserting something neither rule believes.
        let truth = second_opinion(&lines);
        assert_eq!(truth.len(), 1, "{name}: one stop point, one verdict");
        let expected_truth = if expected > 0 {
            Truth::WaitingOnAgent
        } else {
            Truth::WaitingOnHuman
        };
        assert_eq!(truth[0].1, expected_truth, "{name}: {why}");
    }

    let mut t = Tally::default();
    for (name, _, _) in cases {
        let text = std::fs::read_to_string(dir.join(name)).unwrap();
        tally(&parse(&text), &mut t);
    }
    assert_eq!(t.misses, 0, "a fixture waiting on an agent read as free");
    assert_eq!(
        t.false_positives, 0,
        "a fixture waiting on a person claimed a running agent"
    );
    assert_eq!(t.agent_stops, 1, "one fixture has an agent genuinely out");
    assert_eq!(t.human_stops, 5);
}
