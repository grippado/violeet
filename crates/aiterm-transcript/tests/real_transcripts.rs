//! Runs the parser over the transcripts actually on this machine.
//!
//! Synthetic fixtures are written by the same person who wrote the parser and
//! share its assumptions; they cannot catch a field this crate never imagined.
//! These tests read `~/.claude/projects` and assert properties that must hold
//! for every real file.
//!
//! They **skip** rather than fail when the directory is absent, so CI on a
//! machine with no Claude Code installation stays green. That is a deliberate
//! weakness and worth stating: on such a machine this file proves nothing.

use std::path::PathBuf;

use aiterm_transcript::{
    claude_projects_dir, ClaudeCodeReader, Telemetry, TranscriptEvent, TranscriptReader,
};

/// Up to `limit` transcripts, largest first — the big ones exercise compaction
/// and multi-block replies, which the small ones do not.
fn sample_transcripts(limit: usize) -> Vec<PathBuf> {
    let Some(root) = claude_projects_dir() else {
        return Vec::new();
    };
    let mut files = Vec::new();
    collect(&root, &mut files, 0);
    files.sort_by_key(|(size, _)| std::cmp::Reverse(*size));
    files.into_iter().take(limit).map(|(_, p)| p).collect()
}

fn collect(dir: &PathBuf, out: &mut Vec<(u64, PathBuf)>, depth: usize) {
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
            if let Ok(meta) = entry.metadata() {
                out.push((meta.len(), path));
            }
        }
    }
}

/// The headline property: whatever is in these files, the parser survives it.
///
/// No panic, no error, no unwrap on a shape that turned out different. This is
/// the guarantee the daemon relies on to keep a format change from taking out
/// telemetry for every session at once.
#[test]
fn every_real_transcript_parses_without_panicking() {
    let files = sample_transcripts(12);
    if files.is_empty() {
        eprintln!("skipped: no transcripts under ~/.claude/projects");
        return;
    }

    let reader = ClaudeCodeReader::new();
    let mut lines_seen = 0usize;
    let mut events_seen = 0usize;

    for path in &files {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        for line in text.lines() {
            lines_seen += 1;
            events_seen += reader.parse_line(line).len();
        }
    }

    assert!(lines_seen > 0, "the sampled files were all empty");
    assert!(
        events_seen > 0,
        "{lines_seen} real lines produced no events at all — the format moved"
    );
    eprintln!("parsed {lines_seen} real lines from {} files", files.len());
}

/// Occupancy and cumulative cost must not coincide on real data.
///
/// The whole point of keeping them apart is that they are different numbers.
/// If a real session ever produced the same value for both, either the data is
/// degenerate or the implementation has quietly collapsed them.
#[test]
fn on_real_data_occupancy_is_not_the_cumulative_sum() {
    let files = sample_transcripts(6);
    if files.is_empty() {
        eprintln!("skipped: no transcripts under ~/.claude/projects");
        return;
    }

    let reader = ClaudeCodeReader::new();
    let mut checked = 0;

    for path in &files {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        let mut telemetry = Telemetry::new();
        for line in text.lines() {
            for event in reader.parse_line(line) {
                telemetry.apply(&event);
            }
        }

        let (Some(used), Some(input), Some(output)) = (
            telemetry.context_window_used_tokens,
            telemetry.cumulative_input_tokens,
            telemetry.cumulative_output_tokens,
        ) else {
            continue;
        };
        checked += 1;

        assert_ne!(
            used,
            input.saturating_add(output),
            "{}: occupancy equalled the cumulative sum, which is the exact \
             confusion this crate exists to prevent",
            path.display()
        );
    }

    assert!(checked > 0, "no sampled session had all three numbers");
    eprintln!("checked {checked} real sessions");
}

/// Deduplication has to bite on real files, not just synthetic ones.
///
/// A real session writes one line per content block. If the number of assistant
/// turns folded in equals the number of distinct message ids, deduplication is
/// working; if the parser had counted per line, the two would diverge sharply.
#[test]
fn multi_line_replies_are_deduplicated_on_real_files() {
    let files = sample_transcripts(6);
    if files.is_empty() {
        eprintln!("skipped: no transcripts under ~/.claude/projects");
        return;
    }

    let reader = ClaudeCodeReader::new();
    let mut found_a_file_with_repeats = false;

    for path in &files {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };

        let mut turn_lines = 0usize;
        let mut ids = std::collections::HashSet::new();
        let mut deduped = Telemetry::new();
        let mut naive_output: u64 = 0;

        for line in text.lines() {
            for event in reader.parse_line(line) {
                if let TranscriptEvent::AssistantTurn(turn) = &event {
                    turn_lines += 1;
                    if let Some(id) = &turn.message_id {
                        ids.insert(id.clone());
                    }
                    naive_output =
                        naive_output.saturating_add(turn.usage.output_tokens.unwrap_or(0));
                }
                deduped.apply(&event);
            }
        }

        if turn_lines <= ids.len() || ids.is_empty() {
            continue; // no repeats in this file, nothing to prove here
        }
        found_a_file_with_repeats = true;

        let counted = deduped.cumulative_output_tokens.unwrap_or(0);
        assert!(
            counted < naive_output,
            "{}: {turn_lines} assistant lines over {} messages, but deduplicated \
             output ({counted}) was not below the naive per-line sum ({naive_output})",
            path.display(),
            ids.len()
        );
        eprintln!(
            "{}: {turn_lines} lines / {} messages — naive {naive_output} vs counted {counted}",
            path.file_name().unwrap_or_default().to_string_lossy(),
            ids.len()
        );
    }

    assert!(
        found_a_file_with_repeats,
        "no sampled file had a multi-line reply, so this test proved nothing"
    );
}

/// Compaction, if any real file has one, must show occupancy falling.
#[test]
fn real_compactions_report_a_drop() {
    let files = sample_transcripts(20);
    if files.is_empty() {
        eprintln!("skipped: no transcripts under ~/.claude/projects");
        return;
    }

    let reader = ClaudeCodeReader::new();
    let mut seen = 0;

    for path in &files {
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        for line in text.lines() {
            for event in reader.parse_line(line) {
                let TranscriptEvent::Compaction(c) = event else {
                    continue;
                };
                if let (Some(pre), Some(post)) = (c.pre_tokens, c.post_tokens) {
                    seen += 1;
                    assert!(
                        post < pre,
                        "{}: a compaction that did not reduce occupancy ({pre} -> {post})",
                        path.display()
                    );
                }
            }
        }
    }

    if seen == 0 {
        eprintln!("skipped: no compaction found in the sampled files");
    } else {
        eprintln!("checked {seen} real compactions");
    }
}
