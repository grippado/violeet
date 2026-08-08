//! Run the real parser over a real transcript and print the file tree.
//!
//! The check that no unit test can make: unit tests assert against shapes
//! someone typed, and this asserts against what Claude Code actually wrote.
//! Sibling of `measure.rs`, which does the same for token counts.
//!
//!     cargo run --example files_probe -p violeet-transcript -- ~/.claude/projects/<enc>/<id>.jsonl
use violeet_transcript::{ClaudeCodeReader, Telemetry, TranscriptReader};
use std::io::BufRead;

fn main() {
    let path = std::env::args().nth(1).expect("usage: files_probe <transcript.jsonl>");
    let file = std::fs::File::open(&path).expect("open");
    let mut reader = ClaudeCodeReader::new();
    let mut t = Telemetry::new();
    for line in std::io::BufReader::new(file).lines().map_while(Result::ok) {
        for ev in reader.parse_line(&line) {
            t.apply(&ev);
        }
    }
    let (mut a, mut r) = (0u64, 0u64);
    for (path, stat) in &t.files {
        println!("{:>6} {:>6}  {}{}", format!("+{}", stat.added), format!("-{}", stat.removed), if stat.created { "NEW " } else { "" }, path);
        a += stat.added;
        r += stat.removed;
    }
    println!("\n{} arquivos · +{} -{}", t.files.len(), a, r);
}
