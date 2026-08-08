//! Run the real rule over the real corpus and print the trigger rate.
//!
//! The numbers in the `answer_request` module note came from here. Sibling of
//! `measure.rs` and `files_probe.rs`: a unit test asserts against fixtures
//! someone typed, and this asserts against what Claude Code actually wrote.
//!
//! A stop point is a `system`/`stop_hook_summary` line — the moment the `Stop`
//! hook fired — paired with the last assistant message before it. Human or not
//! is decided from the next `user` line.
//!
//!     cargo run --release --example answer_request_probe -p violeet-transcript
//!
//! # Inspecting instead of counting
//!
//! A rate is not reviewable. `32.7%` says nothing about whether the button would
//! have appeared where a person wanted it, and that judgement is the only one
//! that matters for a feature whose false positives are cheap and whose false
//! negatives are the whole cost. So the probe can also print the tail of each
//! decision it made, newest first, labelled `FIRE` or `quiet`:
//!
//!     cargo run --release --example answer_request_probe -p violeet-transcript -- --show 40
//!     … -- --show 40 --only fire
//!     … -- --show 40 --only quiet
//!
//! The lines come from the same `ANSWER_REQUEST.evaluate` the daemon will call,
//! not from a reimplementation, so what you read is what would have happened.

use serde_json::Value;
use std::io::BufRead;
use violeet_transcript::answer_request::{
    user_line_is_human_stop, Declined, Signal, ANSWER_REQUEST,
};

/// The last `n` characters of a message, on one line.
///
/// One line because a decision per line is what makes a list of them skimmable,
/// and the tail because the rule looks at the end of the message: showing the
/// opening would be showing the part that did not decide anything.
fn tail_of(text: &str, n: usize) -> String {
    let flat = text.trim().replace('\n', " ⏎ ");
    let chars: Vec<char> = flat.chars().collect();
    if chars.len() <= n {
        return flat;
    }
    format!("…{}", chars[chars.len() - n..].iter().collect::<String>())
}

/// One decision, kept only when the probe was asked to show its work.
struct Shown {
    fired: bool,
    human: bool,
    signal: &'static str,
    tail: String,
}

fn main() {
    // Hand-rolled rather than a dependency: an example that needs a CLI parser
    // to read two flags is an example nobody runs.
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let flag = |name: &str| argv.iter().position(|a| a == name);
    let show: usize = flag("--show")
        .and_then(|i| argv.get(i + 1))
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let only = flag("--only")
        .and_then(|i| argv.get(i + 1))
        .map(String::as_str);
    let mut shown: Vec<Shown> = Vec::new();

    let root = violeet_transcript::claude_projects_dir().expect("~/.claude/projects");
    let mut files = Vec::new();
    for project in std::fs::read_dir(&root).expect("read projects").flatten() {
        let dir = project.path();
        if !dir.is_dir() {
            continue;
        }
        for entry in std::fs::read_dir(&dir).expect("read project").flatten() {
            let path = entry.path();
            if path.extension().is_some_and(|e| e == "jsonl") {
                files.push(path);
            }
        }
    }
    files.sort();

    let (mut stops, mut human, mut fired, mut fired_human) = (0usize, 0usize, 0usize, 0usize);
    let (mut not_human, mut guarded) = (0usize, 0usize);

    for path in &files {
        let file = std::fs::File::open(path).expect("open");
        let lines: Vec<Value> = std::io::BufReader::new(file)
            .lines()
            .map_while(Result::ok)
            .filter_map(|l| serde_json::from_str(&l).ok())
            .collect();

        for (i, line) in lines.iter().enumerate() {
            let is_stop = line.get("type").and_then(Value::as_str) == Some("system")
                && line.get("subtype").and_then(Value::as_str) == Some("stop_hook_summary");
            if !is_stop {
                continue;
            }
            let Some(text) = assistant_text_before(&lines, i) else {
                continue;
            };
            if text.trim().is_empty() {
                continue;
            }
            stops += 1;
            let is_human = lines[i + 1..]
                .iter()
                .take(5)
                .find(|l| l.get("type").and_then(Value::as_str) == Some("user"))
                .map(user_line_is_human_stop)
                .unwrap_or(true);
            if !is_human {
                not_human += 1;
            }
            let verdict = ANSWER_REQUEST.evaluate(&text, is_human);
            match &verdict {
                Ok(_) => {
                    fired += 1;
                    if is_human {
                        fired_human += 1;
                    }
                }
                Err(Declined::NoResponseRequested) | Err(Declined::ApiError) => guarded += 1,
                Err(_) => {}
            }
            if show > 0 {
                let fired_here = verdict.is_ok();
                let wanted = match only {
                    Some("fire") => fired_here,
                    Some("quiet") => !fired_here,
                    _ => true,
                };
                if wanted {
                    shown.push(Shown {
                        fired: fired_here,
                        human: is_human,
                        // The signal comes off the verdict rather than being
                        // decided again here: two implementations of "which rule
                        // fired" is how a probe starts disagreeing with the rule
                        // it exists to report on.
                        signal: match &verdict {
                            Ok(Signal::QuestionMark) => "question_mark",
                            Ok(Signal::Lexicon) => "lexicon",
                            Err(_) => "-",
                        },
                        tail: tail_of(&text, 180),
                    });
                }
            }
            if is_human {
                human += 1;
            }
        }
    }

    let pct = |n: usize, d: usize| {
        if d == 0 {
            0.0
        } else {
            100.0 * n as f64 / d as f64
        }
    };
    println!("sessions: {}", files.len());
    println!("stop points with assistant text: {stops}");
    println!(
        "  not a human stop: {not_human} ({:.1}%)",
        pct(not_human, stops)
    );
    println!("  suppressed by a text guard: {guarded}");
    println!("  human stop points: {human}");
    println!("fires: {fired} = {:.1}% of stop points", pct(fired, stops));
    println!(
        "fires on a human stop: {fired_human} = {:.1}% of human stops",
        pct(fired_human, human)
    );

    if show > 0 {
        // Newest first: the sessions you remember are the ones you can judge.
        println!("\nlast {show} decisions, newest first:\n");
        for s in shown.iter().rev().take(show) {
            println!(
                "{} {:<14} {}{}",
                if s.fired { "FIRE " } else { "quiet" },
                s.signal,
                if s.human { "" } else { "[not a human stop] " },
                s.tail
            );
        }
    }
}

/// Every `text` block of the assistant message that closed the turn, joined in
/// order. One reply spans several lines and they share a `message.id` — see
/// `docs/TRANSCRIPT_FORMAT.md`.
fn assistant_text_before(lines: &[Value], stop_at: usize) -> Option<String> {
    let mut j = stop_at.checked_sub(1)?;
    loop {
        if lines[j].get("type").and_then(Value::as_str) == Some("assistant") {
            break;
        }
        j = j.checked_sub(1)?;
    }
    let id = lines[j]
        .pointer("/message/id")
        .and_then(Value::as_str)?
        .to_string();
    let mut blocks: Vec<String> = Vec::new();
    let mut k = j as i64;
    while k >= 0 {
        let line = &lines[k as usize];
        if line.get("type").and_then(Value::as_str) != Some("assistant") {
            break;
        }
        if line.pointer("/message/id").and_then(Value::as_str) != Some(id.as_str()) {
            break;
        }
        if let Some(Value::Array(content)) = line.pointer("/message/content") {
            for block in content.iter().rev() {
                if block.get("type").and_then(Value::as_str) == Some("text") {
                    if let Some(t) = block.get("text").and_then(Value::as_str) {
                        if !t.trim().is_empty() {
                            blocks.push(t.to_string());
                        }
                    }
                }
            }
        }
        k -= 1;
    }
    blocks.reverse();
    Some(blocks.join("\n\n"))
}
