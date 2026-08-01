//! Print what the reader makes of a transcript, for cross-checking against an
//! independent implementation.
//!
//! `cargo run -p aiterm-transcript --example measure -- <path>`

use aiterm_transcript::{claude_code::ClaudeCodeReader, TranscriptSession};

fn main() {
    let path = std::env::args().nth(1).expect("a transcript path");
    let mut session = TranscriptSession::from_start(&path, Box::new(ClaudeCodeReader::default()));
    session.read().expect("read");
    let t = session.telemetry();
    println!("input          = {:?}", t.cumulative_input_tokens);
    println!("cache_read     = {:?}", t.cumulative_cache_read_tokens);
    println!("cache_creation = {:?}", t.cumulative_cache_creation_tokens);
    println!("output         = {:?}", t.cumulative_output_tokens);
    println!("occupancy      = {:?}", t.context_window_used_tokens);
    println!("title          = {:?}", t.ai_title);

    let head = aiterm_transcript::claude_code::scan_head(std::path::Path::new(&path)).unwrap();
    println!("head.ai_title  = {:?}", head.ai_title);
    println!("head.derived   = {:?}", head.first_prompt.as_deref().and_then(aiterm_transcript::title::from_prompt));
}
