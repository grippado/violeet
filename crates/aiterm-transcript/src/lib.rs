//! Reading agent transcripts.
//!
//! A library and nothing else: it takes a path, hands back typed events and a
//! telemetry snapshot, and knows nothing about sockets, registries or the
//! daemon's runtime.
//!
//! # The measurements this crate exists to get right
//!
//! Everything here was derived by reading real transcripts under
//! `~/.claude/projects`, not from documentation. `docs/TRANSCRIPT_FORMAT.md`
//! records what was measured, what was inferred, and what could not be
//! determined at all — in three separate sections, on purpose.
//!
//! Two findings shape the whole design, and both are counter-intuitive enough
//! that a reasonable implementation gets them wrong:
//!
//! **One assistant reply is several JSONL lines, each repeating the same
//! `usage`.** Claude Code writes one line per content block — `thinking`,
//! `text`, `tool_use` — and every one of them carries the *whole message's*
//! usage. In a measured file: 803 assistant lines, 344 distinct `message.id`,
//! and 227 + 252 + 324 content blocks summing to exactly 803. Summing usage per
//! line inflates cumulative output by 2.8x. So usage is counted once per
//! `message.id`.
//!
//! **Window occupancy and cumulative cost are different quantities.** See
//! [`Telemetry`], where the temptation to add them lives.

#![forbid(unsafe_code)]

use std::path::{Path, PathBuf};

pub mod claude_code;
pub mod tail;
pub mod watch;

pub use claude_code::ClaudeCodeReader;
pub use tail::{Cursor, TailError};
pub use watch::{watch, watch_shared, TranscriptSession, Update, WatchError, WatchHandle};

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// One thing that happened in a session.
///
/// Deliberately coarse. This is what a sidebar needs, not a faithful
/// reconstruction of the conversation — a transcript reader that modelled every
/// field would be a second implementation of a format that changes without
/// notice.
#[derive(Debug, Clone, PartialEq)]
pub enum TranscriptEvent {
    /// An assistant turn completed, with its usage reading.
    ///
    /// Emitted once per `message.id`, however many lines the reply spanned.
    AssistantTurn(AssistantTurn),
    /// The user said something.
    UserTurn { at: Option<String> },
    /// A tool was invoked.
    ToolUse(ToolUse),
    /// A tool call came back. Correlates with [`ToolUse::id`].
    ToolResult { tool_use_id: String, at: Option<String> },
    /// The context window was compacted. Carries the daemon's best evidence
    /// that occupancy fell, straight from the file rather than inferred.
    Compaction(Compaction),
    /// A line we parsed but do not model. Kept so callers can count activity
    /// without this crate having to know every `type` Claude Code emits.
    Other { kind: String, at: Option<String> },
}

impl TranscriptEvent {
    pub fn timestamp(&self) -> Option<&str> {
        match self {
            Self::AssistantTurn(t) => t.at.as_deref(),
            Self::UserTurn { at } => at.as_deref(),
            Self::ToolUse(t) => t.at.as_deref(),
            Self::ToolResult { at, .. } => at.as_deref(),
            Self::Compaction(c) => c.at.as_deref(),
            Self::Other { at, .. } => at.as_deref(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct AssistantTurn {
    /// `message.id`. The deduplication key — see the module note.
    pub message_id: Option<String>,
    pub model: Option<String>,
    pub usage: Usage,
    pub at: Option<String>,
}

/// A `usage` block, exactly as measured.
///
/// Every field is `Option` and an absent one stays `None`. A zero that was
/// actually written stays `Some(0)` and remains distinguishable from unknown —
/// which matters because "this turn read no cache" and "we could not tell" are
/// different facts and the second must never be rendered as the first.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Usage {
    pub input_tokens: Option<u64>,
    pub cache_creation_input_tokens: Option<u64>,
    pub cache_read_input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
}

impl Usage {
    /// Everything that was in the prompt for this call.
    ///
    /// `input + cache_creation + cache_read`. For the **most recent** assistant
    /// turn this is the current occupancy of the context window, because the
    /// prompt of the latest call *is* the conversation as the model currently
    /// sees it.
    ///
    /// Returns `None` when no component was present: a prompt size of zero is
    /// not a plausible reading, and reporting one would be inventing a number.
    pub fn prompt_tokens(&self) -> Option<u64> {
        let parts = [
            self.input_tokens,
            self.cache_creation_input_tokens,
            self.cache_read_input_tokens,
        ];
        if parts.iter().all(Option::is_none) {
            return None;
        }
        Some(parts.iter().flatten().sum())
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ToolUse {
    pub id: Option<String>,
    pub name: String,
    /// A short, human-readable rendering of the input. Never the whole thing:
    /// a `Write` tool's input can be a hundred kilobytes of file content, and
    /// this ends up in a sidebar row.
    pub summary: Option<String>,
    pub at: Option<String>,
}

/// A compaction, as reported by the file itself.
///
/// `pre_tokens` and `post_tokens` are **measured**, not inferred: Claude Code
/// writes them into `compactMetadata` on a `system` line with
/// `subtype: "compact_boundary"`. A real observed pair is 337228 → 15850.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Compaction {
    /// `auto` or `manual`, both observed.
    pub trigger: Option<String>,
    pub pre_tokens: Option<u64>,
    pub post_tokens: Option<u64>,
    pub at: Option<String>,
}

// ---------------------------------------------------------------------------
// Telemetry
// ---------------------------------------------------------------------------

/// Everything a sidebar needs about one session, accumulated from its events.
///
/// # The mistake this type is arranged to prevent
///
/// There are two pairs of token numbers here and they measure different things:
///
/// - [`context_window_used_tokens`](Self::context_window_used_tokens) is how
///   full the window is **right now**. It is the prompt size of the latest
///   assistant turn, it is not a running total, and it **falls** on compaction —
///   measured falling from 337228 to 15850 in a real session.
/// - [`cumulative_input_tokens`](Self::cumulative_input_tokens) and
///   [`cumulative_output_tokens`](Self::cumulative_output_tokens) are what the
///   session has **cost since it started**. They only ever climb.
///
/// **Adding the cumulative pair to estimate occupancy is wrong.** It is the one
/// error worth naming in a doc comment, because the result is not obviously
/// broken: it is a plausible-looking number, in the right units, that grows
/// smoothly and is simply false. In the measured session above the cumulative
/// output alone was 404098 while the window held 662536 — neither derivable
/// from the other. A percentage built that way would cross 100% and keep going,
/// and would never fall on a compaction that genuinely emptied the window.
///
/// The two are computed in different places on purpose: occupancy is
/// last-write-wins from one turn, cost is a sum over turns.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Telemetry {
    /// Monotonic. For cost.
    pub cumulative_input_tokens: Option<u64>,
    /// Monotonic. For cost.
    pub cumulative_output_tokens: Option<u64>,

    /// Current occupancy. Falls on compaction. NOT a running total.
    pub context_window_used_tokens: Option<u64>,
    /// The model's window size.
    ///
    /// **Not measured.** No transcript field carries it — searching every file
    /// under `~/.claude/projects` for a window/limit key found nothing. It is
    /// filled in from [`window_size_for_model`], which is a lookup table, which
    /// is a guess that ages. `None` when the model is unknown to that table,
    /// and `None` is the honest answer.
    pub context_window_size_tokens: Option<u64>,

    pub model: Option<String>,
    /// Last tool invoked, with a short summary of its input.
    pub last_action: Option<String>,
    /// A tool call with no result yet.
    ///
    /// **This is not "the pending HITL", and must not be rendered as one.** The
    /// transcript carries no permission-request signal at all — measured: zero
    /// occurrences of any permission marker across the sampled files, and every
    /// `tool_use` in a completed session had a matching `tool_result`. An
    /// in-flight tool is a tool that has not returned; whether it is blocked on
    /// a human, blocked on the network, or simply slow is not knowable here.
    /// The pending-HITL signal comes from the daemon's hook (ADR-004).
    pub in_flight_tool: Option<String>,

    pub turn_count: u64,
    pub last_event_at: Option<String>,
    /// How many compactions this session has been through.
    pub compaction_count: u64,

    /// `message.id`s already counted, so a replayed or re-read line cannot
    /// double the cost.
    seen_messages: std::collections::HashSet<String>,
    /// Tool calls awaiting a result, in order.
    open_tools: Vec<(String, String)>,
}

impl Telemetry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Fold one event in. Idempotent per `message.id` for the cost counters.
    pub fn apply(&mut self, event: &TranscriptEvent) {
        if let Some(at) = event.timestamp() {
            self.last_event_at = Some(at.to_string());
        }

        match event {
            TranscriptEvent::AssistantTurn(turn) => {
                self.turn_count += 1;
                if turn.model.is_some() {
                    self.model = turn.model.clone();
                }

                // Occupancy: last write wins. This is a *reading*, not an
                // accumulation, which is exactly why it can go down.
                if let Some(prompt) = turn.usage.prompt_tokens() {
                    self.context_window_used_tokens = Some(prompt);
                }
                self.context_window_size_tokens = self
                    .model
                    .as_deref()
                    .and_then(window_size_for_model);

                // Cost: a sum, and the one place double counting is possible.
                // Every line of a multi-block reply repeats the same usage, so
                // without this guard a three-block answer is billed three times.
                let already_counted = match &turn.message_id {
                    Some(id) => !self.seen_messages.insert(id.clone()),
                    // No id to deduplicate on. Counting it is the lesser error:
                    // skipping would under-report cost permanently, where
                    // double counting is bounded by how often the id is absent
                    // (never, in every file measured).
                    None => false,
                };
                if !already_counted {
                    add_into(&mut self.cumulative_input_tokens, turn.usage.input_tokens);
                    add_into(&mut self.cumulative_output_tokens, turn.usage.output_tokens);
                }
            }

            TranscriptEvent::UserTurn { .. } => {
                self.turn_count += 1;
            }

            TranscriptEvent::ToolUse(tool) => {
                let label = match &tool.summary {
                    Some(s) => format!("{} {}", tool.name, s),
                    None => tool.name.clone(),
                };
                self.last_action = Some(label.clone());
                if let Some(id) = &tool.id {
                    self.open_tools.push((id.clone(), label));
                }
                self.refresh_in_flight();
            }

            TranscriptEvent::ToolResult { tool_use_id, .. } => {
                self.open_tools.retain(|(id, _)| id != tool_use_id);
                self.refresh_in_flight();
            }

            TranscriptEvent::Compaction(compaction) => {
                self.compaction_count += 1;
                // The file's own number beats ours. `post_tokens` is what the
                // window holds after the compaction, measured and written by
                // Claude Code; the next assistant turn will confirm it, but
                // until then this is the only correct value.
                if let Some(post) = compaction.post_tokens {
                    self.context_window_used_tokens = Some(post);
                }
                // Cost does not fall. Compaction drops context, not spend.
            }

            TranscriptEvent::Other { .. } => {}
        }
    }

    fn refresh_in_flight(&mut self) {
        self.in_flight_tool = self.open_tools.last().map(|(_, label)| label.clone());
    }

    /// Fraction of the window in use, `0.0..=1.0`.
    ///
    /// `None` unless both halves are known. There is deliberately no
    /// `context_pct` on the wire — this is presentation, computed where it is
    /// displayed, so the number and its inputs cannot drift apart.
    pub fn context_fraction(&self) -> Option<f64> {
        let used = self.context_window_used_tokens? as f64;
        let size = self.context_window_size_tokens? as f64;
        if size <= 0.0 {
            return None;
        }
        Some(used / size)
    }

    /// Tokens left before the window is full.
    pub fn context_tokens_remaining(&self) -> Option<u64> {
        let used = self.context_window_used_tokens?;
        let size = self.context_window_size_tokens?;
        Some(size.saturating_sub(used))
    }

    /// Is a compaction close?
    ///
    /// `None` when the window size is unknown, which is not the same as `false`
    /// — an unknown window cannot be nearly full *or* comfortably empty, and
    /// returning `false` would render as reassurance we have no basis for.
    pub fn compaction_imminent(&self, threshold: f64) -> Option<bool> {
        Some(self.context_fraction()? >= threshold)
    }
}

/// The default threshold for [`Telemetry::compaction_imminent`].
pub const DEFAULT_COMPACTION_THRESHOLD: f64 = 0.85;

/// Add `delta` into an optional accumulator, without inventing a zero.
///
/// `None + None` stays `None`: a session that has reported no usage has an
/// unknown cost, not a cost of zero.
fn add_into(slot: &mut Option<u64>, delta: Option<u64>) {
    if let Some(d) = delta {
        *slot = Some(slot.unwrap_or(0).saturating_add(d));
    }
}

/// Context window size for a model name.
///
/// **This table is not measured and it will age.** No transcript field carries
/// the window size — every file under `~/.claude/projects` was searched for one
/// and there is none. So this is external knowledge encoded in a lookup, which
/// is the kind of thing that is quietly wrong six months from now.
///
/// It is a function rather than a constant map so a caller can ignore it and
/// supply their own. Unknown models return `None`, and `None` is honest: a
/// wrong window size produces a wrong percentage, and a wrong percentage is
/// worse than a missing one because it looks like an answer.
///
/// The `[1m]` suffix on a model id denotes the one-million-token variant. A
/// real session was measured holding 662536 tokens of occupancy, which is by
/// itself proof that assuming 200000 everywhere is wrong.
pub fn window_size_for_model(model: &str) -> Option<u64> {
    const K: u64 = 1000;
    let m = model.to_ascii_lowercase();

    if m.contains("[1m]") || m.contains("-1m") {
        return Some(1000 * K);
    }
    if m.contains("opus") || m.contains("sonnet") || m.contains("haiku") || m.contains("fable") {
        return Some(200 * K);
    }
    None
}

// ---------------------------------------------------------------------------
// The reader trait
// ---------------------------------------------------------------------------

/// A transcript format.
///
/// Implemented for Claude Code today. Codex and opencode are why this is a
/// trait: both write their own transcript format, and the daemon should not
/// grow a `match` on harness at every call site.
///
/// The trait is line-oriented rather than file-oriented because that is the
/// only shape all three can share — the incremental tailing in [`tail`] is
/// format-independent and is deliberately *not* part of this.
///
/// `Send` is a supertrait because a reader is handed to the watcher thread.
/// Readers are stateless in practice, so this costs nothing and saves every
/// caller from writing `Box<dyn TranscriptReader + Send>`.
pub trait TranscriptReader: Send {
    /// Which harness this reads. `claude-code`, `codex`, `opencode`.
    fn harness(&self) -> &'static str;

    /// Parse one line into zero or more events.
    ///
    /// A `Vec` rather than an `Option` because **one line can carry more than
    /// one fact**. An `assistant` line holding a `tool_use` block also holds
    /// that message's `usage`, and an earlier version of this trait returned
    /// only the tool — silently dropping the cost of every reply that called a
    /// tool without also emitting text. Real transcripts made the gap visible:
    /// counted output came out ~6% below an independent measurement of the same
    /// file, entirely from tool-only replies.
    ///
    /// An empty `Vec` means "nothing worth reporting", including for a line
    /// that is not valid JSON. **This must never panic and must never return an
    /// error for malformed input**: the format changes without notice, and a
    /// reader that failed on an unrecognized line would take out telemetry for
    /// the whole session the first time Claude Code adds a field.
    fn parse_line(&self, line: &str) -> Vec<TranscriptEvent>;

    /// Does this file look like ours?
    ///
    /// Used to pick a reader when the harness is not already known.
    fn recognizes(&self, first_lines: &[String]) -> bool;
}

/// Where Claude Code keeps transcripts.
pub fn claude_projects_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".claude/projects"))
}

/// Pick a reader for a file by sniffing its first lines.
///
/// Only one reader exists, so this is a one-armed choice today. It is here so
/// that adding Codex is adding a reader rather than editing every caller.
pub fn reader_for(path: &Path) -> Option<Box<dyn TranscriptReader>> {
    let head = tail::read_first_lines(path, 5).ok()?;
    let claude = ClaudeCodeReader::new();
    claude.recognizes(&head).then(|| Box::new(claude) as Box<dyn TranscriptReader>)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn turn(id: &str, input: u64, cache_read: u64, output: u64) -> TranscriptEvent {
        TranscriptEvent::AssistantTurn(AssistantTurn {
            message_id: Some(id.into()),
            model: Some("claude-sonnet-5".into()),
            usage: Usage {
                input_tokens: Some(input),
                cache_creation_input_tokens: None,
                cache_read_input_tokens: Some(cache_read),
                output_tokens: Some(output),
            },
            at: Some("2026-07-31T22:00:00Z".into()),
        })
    }

    /// The measured shape of the file: one reply, three lines, one usage.
    ///
    /// This is the test that would have caught the 2.8x cost inflation.
    #[test]
    fn a_reply_spanning_several_lines_is_billed_once() {
        let mut t = Telemetry::new();
        for _ in 0..3 {
            t.apply(&turn("msg_1", 100, 900, 50));
        }

        assert_eq!(t.cumulative_output_tokens, Some(50), "billed once, not three times");
        assert_eq!(t.cumulative_input_tokens, Some(100));
        assert_eq!(
            t.context_window_used_tokens,
            Some(1000),
            "occupancy is a reading, so repeating it changes nothing"
        );
    }

    /// The distinction the whole type exists for.
    #[test]
    fn occupancy_falls_on_compaction_while_cost_keeps_climbing() {
        let mut t = Telemetry::new();
        t.apply(&turn("m1", 1_000, 300_000, 5_000));
        let cost_before = t.cumulative_output_tokens;
        assert_eq!(t.context_window_used_tokens, Some(301_000));

        t.apply(&TranscriptEvent::Compaction(Compaction {
            trigger: Some("auto".into()),
            pre_tokens: Some(301_000),
            post_tokens: Some(15_850),
            at: Some("2026-07-31T22:01:00Z".into()),
        }));

        assert_eq!(t.context_window_used_tokens, Some(15_850), "occupancy fell");
        assert_eq!(t.cumulative_output_tokens, cost_before, "cost did not");
        assert_eq!(t.compaction_count, 1);
    }

    /// Guards the specific wrong answer: cumulative summed as if it were
    /// occupancy. Kept as an assertion rather than only a comment, because a
    /// comment cannot fail.
    #[test]
    fn cumulative_and_occupancy_are_not_derivable_from_each_other() {
        let mut t = Telemetry::new();
        t.apply(&turn("m1", 1_000, 50_000, 4_000));
        t.apply(&turn("m2", 1_200, 60_000, 4_500));

        assert_eq!(t.cumulative_input_tokens, Some(2_200));
        assert_eq!(t.context_window_used_tokens, Some(61_200));
        assert_ne!(
            t.context_window_used_tokens,
            t.cumulative_input_tokens
                .zip(t.cumulative_output_tokens)
                .map(|(a, b)| a + b),
            "if these ever coincide the test is lying, not passing"
        );
    }

    /// A real zero is a reading and survives as one.
    #[test]
    fn a_real_zero_stays_some_zero_and_unknown_stays_none() {
        let mut t = Telemetry::new();
        t.apply(&TranscriptEvent::AssistantTurn(AssistantTurn {
            message_id: Some("m1".into()),
            model: None,
            usage: Usage {
                input_tokens: Some(0),
                cache_creation_input_tokens: None,
                cache_read_input_tokens: None,
                output_tokens: Some(0),
            },
            at: None,
        }));

        assert_eq!(t.cumulative_input_tokens, Some(0));
        assert_eq!(t.context_window_used_tokens, Some(0));
        assert_eq!(t.model, None, "an absent model is not a model called \"\"");

        // And a turn carrying no usage at all leaves the counters unknown.
        let mut empty = Telemetry::new();
        empty.apply(&TranscriptEvent::AssistantTurn(AssistantTurn {
            message_id: Some("m1".into()),
            model: None,
            usage: Usage::default(),
            at: None,
        }));
        assert_eq!(empty.cumulative_input_tokens, None);
        assert_eq!(empty.context_window_used_tokens, None);
    }

    #[test]
    fn an_unknown_window_makes_the_imminent_signal_unknown_not_false() {
        let mut t = Telemetry::new();
        t.apply(&TranscriptEvent::AssistantTurn(AssistantTurn {
            message_id: Some("m1".into()),
            model: Some("some-model-we-have-never-heard-of".into()),
            usage: Usage {
                input_tokens: Some(190_000),
                ..Usage::default()
            },
            at: None,
        }));

        assert_eq!(t.context_window_size_tokens, None);
        assert_eq!(t.context_fraction(), None);
        assert_eq!(
            t.compaction_imminent(DEFAULT_COMPACTION_THRESHOLD),
            None,
            "an unknown window must not render as `plenty of room`"
        );
    }

    #[test]
    fn the_imminent_signal_fires_at_the_threshold() {
        let mut t = Telemetry::new();
        t.apply(&turn("m1", 170_000, 0, 10));
        assert_eq!(t.context_window_size_tokens, Some(200_000));
        // 170000 / 200000 is exactly the default threshold, and the comparison
        // is `>=`, so the boundary itself fires.
        assert_eq!(t.compaction_imminent(0.85), Some(true));
        assert_eq!(t.compaction_imminent(0.90), Some(false));
        assert_eq!(t.context_tokens_remaining(), Some(30_000));
    }

    #[test]
    fn an_in_flight_tool_clears_when_its_result_arrives() {
        let mut t = Telemetry::new();
        t.apply(&TranscriptEvent::ToolUse(ToolUse {
            id: Some("toolu_1".into()),
            name: "Bash".into(),
            summary: Some("cargo test".into()),
            at: None,
        }));
        assert_eq!(t.in_flight_tool.as_deref(), Some("Bash cargo test"));
        assert_eq!(t.last_action.as_deref(), Some("Bash cargo test"));

        t.apply(&TranscriptEvent::ToolResult {
            tool_use_id: "toolu_1".into(),
            at: None,
        });
        assert_eq!(t.in_flight_tool, None, "returned, so no longer in flight");
        assert_eq!(
            t.last_action.as_deref(),
            Some("Bash cargo test"),
            "the last action is still the last action"
        );
    }

    #[test]
    fn the_one_million_variant_is_recognized() {
        assert_eq!(window_size_for_model("claude-opus-5[1m]"), Some(1_000_000));
        assert_eq!(window_size_for_model("claude-sonnet-5"), Some(200_000));
        assert_eq!(window_size_for_model("gpt-something"), None);
    }
}
