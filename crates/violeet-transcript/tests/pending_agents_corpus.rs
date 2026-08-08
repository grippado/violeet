//! The gate: a session waiting on a background agent must not read as free.
//!
//! This is the acceptance criterion for `pending_agents`, run against the whole
//! corpus under `~/.claude/projects` rather than against fixtures. It replays
//! every transcript through the real reader and the real [`Telemetry`], stops at
//! every point where the `Stop` hook fired, and asserts that the ones followed
//! by a `<task-notification>` were reporting a **non-zero** count at the moment
//! they went quiet.
//!
//! A stop point is a `system` / `stop_hook_summary` line — the same hook the
//! daemon keys `state: "idle"` off, so the proxy and the product signal are the
//! same event rather than two things that agree most of the time. That is the
//! definition `docs/spikes/2026-08-08-parada-nao-e-pergunta.md` measured with,
//! where the original reading was 185 background-task notifications out of 942
//! stop points.
//!
//! **The corpus is live and the counts drift.** The assertions are on the
//! *rate*, plus a floor on the sample size so a corpus that shrank to nothing
//! cannot pass by having nothing to check. Skips on a machine with no Claude
//! Code, like its sibling `real_transcripts.rs`, and that is a stated weakness:
//! there, this file proves nothing.

use std::collections::HashSet;
use std::path::PathBuf;

use serde_json::Value;
use violeet_transcript::{claude_projects_dir, ClaudeCodeReader, Telemetry, TranscriptReader};

/// The fewest agent stop points this corpus must offer for the gate to mean
/// anything. The reading when this was written was 173.
const MIN_AGENT_STOPS: usize = 120;

/// How many of them may report zero, in percent.
///
/// Not zero, and the reason is one measured shape: `SendMessage` resumes an
/// agent that had already reported in, and its result announces the resume in
/// prose with no structural marker at all — no `isAsync`, no `status`, no id
/// beyond the one in the tool's input. One stop point of 173 on this corpus is
/// that case. Everything else is covered, and the allowance is deliberately
/// tight: it is there to tolerate one known shape, not to leave room for a rule
/// that stopped working.
const MAX_MISS_PERCENT: usize = 2;

fn transcripts() -> Vec<PathBuf> {
    let Some(root) = claude_projects_dir() else {
        return Vec::new();
    };
    let mut files = Vec::new();
    collect(&root, &mut files, 0);
    files.sort();
    files
}

fn collect(dir: &PathBuf, out: &mut Vec<PathBuf>, depth: usize) {
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

fn is_stop_point(line: &Value) -> bool {
    line.get("type").and_then(Value::as_str) == Some("system")
        && line.get("subtype").and_then(Value::as_str) == Some("stop_hook_summary")
}

/// The `<task-notification>` ids on a line, when it is one.
fn notification_ids(line: &Value) -> Option<Vec<String>> {
    let text = line.get("message")?.get("content")?.as_str()?;
    if !text.contains("<task-notification>") {
        return None;
    }
    let tag = |name: &str| -> Option<String> {
        let open = format!("<{name}>");
        let rest = &text[text.find(&open)? + open.len()..];
        let end = rest.find(&format!("</{name}>"))?;
        Some(rest[..end].trim().to_string())
    };
    Some(
        ["tool-use-id", "task-id"]
            .iter()
            .filter_map(|n| tag(n))
            .collect(),
    )
}

/// The next `user` line within five lines, which is how the spike decided what a
/// stop point was followed by.
fn next_user_line(lines: &[Value], from: usize) -> Option<&Value> {
    lines[from + 1..]
        .iter()
        .take(5)
        .find(|l| l.get("type").and_then(Value::as_str) == Some("user"))
}

#[test]
fn a_stop_point_waiting_on_an_agent_reports_a_pending_agent() {
    let files = transcripts();
    if files.is_empty() {
        eprintln!("skipped: no transcripts under ~/.claude/projects");
        return;
    }

    let reader = ClaudeCodeReader::new();
    let (mut stops, mut notification_stops, mut agent_stops, mut misses) = (0, 0, 0, 0);

    for path in &files {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        let lines: Vec<Value> = text
            .lines()
            .map(|l| serde_json::from_str(l).unwrap_or(Value::Null))
            .collect();

        // Replayed through the real fold, one line at a time, so the count read
        // at a stop point is the count the daemon would have published there.
        let mut telemetry = Telemetry::new();
        // Which notifications belong to an agent this file launched, as opposed
        // to a backgrounded shell command. Filled as the replay goes, so a
        // launch is only known once it has been read — the same order the daemon
        // sees.
        let mut launched: HashSet<String> = HashSet::new();

        for (i, line) in lines.iter().enumerate() {
            for event in reader.parse_line(&line.to_string()) {
                if let violeet_transcript::TranscriptEvent::AgentLaunched {
                    tool_use_id,
                    task_id,
                    ..
                } = &event
                {
                    launched.extend(tool_use_id.clone());
                    launched.extend(task_id.clone());
                }
                telemetry.apply(&event);
            }

            if !is_stop_point(line) {
                continue;
            }
            stops += 1;
            let Some(ids) = next_user_line(&lines, i).and_then(notification_ids) else {
                continue;
            };
            notification_stops += 1;
            if !ids.iter().any(|id| launched.contains(id)) {
                // A backgrounded shell command, or an agent launched before the
                // part of the session this file holds. Neither is what this
                // field claims to count.
                continue;
            }
            agent_stops += 1;
            if telemetry.pending_agents() == 0 {
                misses += 1;
            }
        }
    }

    eprintln!(
        "corpus: {} files, {stops} stop points, {notification_stops} followed by a \
         task notification, {agent_stops} of those an agent this session launched",
        files.len()
    );
    eprintln!(
        "agent stop points reporting pending_agents > 0: {} of {agent_stops}",
        agent_stops - misses
    );

    assert!(
        agent_stops >= MIN_AGENT_STOPS,
        "only {agent_stops} agent stop points in the corpus: the gate would pass \
         without checking anything"
    );
    assert!(
        misses * 100 <= agent_stops * MAX_MISS_PERCENT,
        "{misses} of {agent_stops} stop points waiting on an agent reported \
         pending_agents == 0, which renders as free"
    );
}
