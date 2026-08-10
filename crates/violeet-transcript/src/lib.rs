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

use chrono::{DateTime, Utc};

pub mod answer_request;
pub mod claude_code;
pub mod cursor;
pub mod tail;
pub mod title;
pub mod watch;

pub use answer_request::{
    AnswerRequest, AnswerRequestConfig, ContextMessage, Declined, Signal, ANSWER_REQUEST,
};
pub use claude_code::ClaudeCodeReader;
pub use cursor::CursorReader;
pub use tail::{Cursor, TailError};
pub use watch::{
    watch, watch_shared, SharedWatch, TranscriptSession, Update, WatchError, WatchHandle,
};

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
    ///
    /// `text` is the prose of the line, when it has any, and `human` is
    /// [`answer_request::user_line_is_human_stop`] read at parse time — a
    /// `<task-notification>`, a slash command's caveat and an interrupt all
    /// arrive as `user` lines and none of them is a person typing. Both are here
    /// because the excerpt in `answer_request` needs the words and the rule
    /// needs to know who wrote them; deciding it again downstream would be a
    /// second implementation of the same predicate.
    UserTurn {
        at: Option<String>,
        text: Option<String>,
        human: bool,
    },
    /// Claude Code's `Stop` hook fired: the turn ended.
    ///
    /// The `system`/`stop_hook_summary` line, which is the only mark in the file
    /// of the moment a reply was finished rather than merely written. Modelled
    /// rather than left in [`TranscriptEvent::Other`] because `answer_request`
    /// is decided *at* a stop point and nowhere else: the same prose mid-reply
    /// is not a question waiting on anybody.
    StopPoint { at: Option<String> },
    /// A tool was invoked.
    ToolUse(ToolUse),
    /// A tool call came back. Correlates with [`ToolUse::id`].
    ///
    /// `file` is present when the call wrote to a file and said so. See
    /// [`FileChange`] for what "said so" means and what it cannot cover.
    ToolResult {
        tool_use_id: String,
        at: Option<String>,
        file: Option<FileChange>,
    },
    /// A background agent was dispatched and will report back later.
    ///
    /// **This is not a tool going in flight.** The launch of a background agent
    /// is acknowledged *immediately* by an ordinary `tool_result` — measured on
    /// six backgrounded tasks across two sessions, the acknowledgement is the
    /// very next line every time — and the real outcome arrives much later as a
    /// `<task-notification>`. So `in_flight_tool` is empty while the agent runs,
    /// which is exactly why the session looks free while it is not.
    ///
    /// Both ids are optional on the wire, and [`Telemetry`] counts a launch only
    /// when the `task_id` is there: the notification is keyed by `tool-use-id`
    /// in most cases and by `task-id` alone for a dynamic workflow, so a launch
    /// that announced no `agentId` shares no key with the line that would close
    /// it. It is read, reported, and not counted.
    AgentLaunched {
        tool_use_id: Option<String>,
        /// `agentId` from the launch acknowledgement, which is the `task-id` the
        /// notification will carry.
        task_id: Option<String>,
        at: Option<String>,
    },
    /// A background agent reported in — the `<task-notification>` user line.
    ///
    /// Any status closes the wait: `completed`, `failed`, `killed` and `stopped`
    /// were all observed, and a session is no longer waiting on an agent that
    /// died.
    AgentFinished {
        tool_use_id: Option<String>,
        task_id: Option<String>,
        at: Option<String>,
    },
    /// The context window was compacted. Carries the daemon's best evidence
    /// that occupancy fell, straight from the file rather than inferred.
    Compaction(Compaction),
    /// The title Claude Code generated for this session.
    ///
    /// Measured across twelve recent transcripts: it lands on **line 12**, one
    /// exchange in, and every one of those files carried exactly **one**
    /// distinct value for the whole session — it does not churn. It is written
    /// in the language the conversation is in. This is a real name, produced by
    /// the agent for exactly this purpose, and it costs violeet nothing to read.
    AiTitle { text: String, at: Option<String> },
    /// A line we parsed but do not model. Kept so callers can count activity
    /// without this crate having to know every `type` Claude Code emits.
    Other { kind: String, at: Option<String> },
}

impl TranscriptEvent {
    pub fn timestamp(&self) -> Option<&str> {
        match self {
            Self::AssistantTurn(t) => t.at.as_deref(),
            Self::UserTurn { at, .. } => at.as_deref(),
            Self::StopPoint { at } => at.as_deref(),
            Self::ToolUse(t) => t.at.as_deref(),
            Self::ToolResult { at, .. } => at.as_deref(),
            Self::AgentLaunched { at, .. } => at.as_deref(),
            Self::AgentFinished { at, .. } => at.as_deref(),
            Self::Compaction(c) => c.at.as_deref(),
            Self::AiTitle { at, .. } => at.as_deref(),
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
    /// The `text` blocks of *this line*, joined, when it has any.
    ///
    /// One reply is several lines sharing a `message.id`, so this is a fragment
    /// of a message and not a message: [`Telemetry`] joins the fragments back
    /// together by id. `None` for a line that carried only `thinking` or
    /// `tool_use`, which is a different fact from an empty reply.
    pub text: Option<String>,
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

/// A file a tool wrote, and by how much.
///
/// # Measured, not inferred
///
/// Claude Code writes the diff itself. The `toolUseResult` of an `Edit` carries
/// `structuredPatch`: unified-diff hunks whose `lines` are prefixed `+`, `-` or
/// space. Counting those prefixes gives the same numbers `git diff --numstat`
/// would, with no I/O and no guessing. Measured across every transcript under
/// `~/.claude/projects`: 1256 `Edit` results and 452 `Write` results in that
/// shape.
///
/// A `Write` that creates a file is the one case with no patch to read — all
/// 387 measured creates carried an **empty** `structuredPatch` — so its `added`
/// is the line count of the content it wrote, and `created` says which case
/// this was.
///
/// # What this cannot see
///
/// Files written by `Bash` — `sed -i`, `mv`, a heredoc, a `git checkout`. They
/// leave no tool result naming a path, so they are absent, and a list built
/// from this is "files edited by tool" rather than "files that changed". That
/// limit is why the wire carries a partial flag: an incomplete list that looks
/// complete is the failure this crate already refuses for token counts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileChange {
    /// Absolute, as the transcript writes it. Relativising is a display
    /// decision and belongs to whoever knows what the paths are relative *to*.
    pub path: String,
    pub added: u64,
    pub removed: u64,
    /// The tool created this file rather than editing one that existed.
    pub created: bool,
}

/// What one session did to one file, summed over every edit of it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FileStat {
    pub added: u64,
    pub removed: u64,
    /// True when this session created the file. Sticky: a file created and then
    /// edited five times was still created here.
    pub created: bool,
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
    /// This call looks like it wrote a file the file list cannot see.
    ///
    /// True only for a `Bash` whose command looks like it writes — see
    /// `command_may_write`. It is what turns "nothing written yet" into "file
    /// changes unknown", which are different claims and only one of them can be
    /// made about a session that shelled out.
    pub writes_untracked: bool,
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
    /// Monotonic. Fresh input only — the part of the prompt that was neither
    /// read from nor written to the cache.
    ///
    /// **On its own this is not what the session cost.** Measured across four
    /// real transcripts, it is between 628 and 58 565 tokens while the prompt
    /// side actually consumed 121–267 *million*: a factor of 3 607x to
    /// 214 723x. Reported alone it produced a card reading `in ~170` for a
    /// session holding 187k in its window, which is what exposed the bug.
    pub cumulative_input_tokens: Option<u64>,
    /// Monotonic. For cost.
    pub cumulative_output_tokens: Option<u64>,
    /// Monotonic. Prompt tokens served from the cache.
    ///
    /// Kept apart from `cumulative_input_tokens` rather than summed into it,
    /// for two reasons. It is priced differently — a tenth of base input — so
    /// one merged number cannot be turned into money by anyone. And it
    /// dominates the sum so completely (99.5% in the measured sessions) that
    /// merging would hide fresh input entirely, which is the same failure as
    /// today's, only mirrored.
    pub cumulative_cache_read_tokens: Option<u64>,
    /// Monotonic. Prompt tokens written into the cache, priced *above* base
    /// input. Separate for the same reason.
    pub cumulative_cache_creation_tokens: Option<u64>,

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

    /// The title Claude Code generated for this session, if it has generated
    /// one yet. See [`TranscriptEvent::AiTitle`].
    pub ai_title: Option<String>,

    /// Every file this session wrote, keyed by absolute path.
    ///
    /// A `BTreeMap` so the order is the same on every read: this ends up on a
    /// wire and in a tree, and a set that reorders itself would make every
    /// publish look like a change.
    pub files: std::collections::BTreeMap<String, FileStat>,

    /// The session ran a shell command that looks like it wrote something.
    ///
    /// Sticky, and deliberately: one such command anywhere in the session means
    /// the file list has a hole in it from then on, and a flag that cleared on
    /// the next tracked edit would say the list is complete when it is not.
    ///
    /// This is the second of the two reasons a list is partial. The first — the
    /// daemon having met the session already running — is about *when* we
    /// started looking; this one is about *what we cannot see* however early we
    /// arrived.
    pub wrote_untracked: bool,

    pub turn_count: u64,
    pub last_event_at: Option<String>,
    /// How many compactions this session has been through.
    pub compaction_count: u64,

    /// `message.id`s already counted, so a replayed or re-read line cannot
    /// double the cost.
    seen_messages: std::collections::HashSet<String>,
    /// `tool_use_id`s whose file change is already in `files`.
    ///
    /// Keyed on the tool call and not on the path, deliberately: the same file
    /// edited twice is two calls and must count twice, while the same call seen
    /// twice — a re-read after a truncated tail, a resumed session — is one
    /// edit. Getting this backwards is how the token counters once inflated
    /// 2.8x, and a diffstat is no less re-readable than a usage block.
    seen_tool_results: std::collections::HashSet<String>,
    /// Tool calls awaiting a result, in order.
    open_tools: Vec<(String, String)>,

    /// Correlation keys of the background agent launches read so far.
    ///
    /// **A set difference, not a counter**, and the distinction is the whole
    /// design: [`Telemetry::pending_agents`] is
    /// `launched.difference(&finished)`, so the value is *recomputed from the
    /// transcript* on every read. A counter incremented on dispatch and
    /// decremented on completion would be wrong from the first lost event until
    /// the session ended.
    ///
    /// Two sets and not one list with removals, and that is not a style
    /// preference. Removing the key on completion made the fold idempotent only
    /// for a *suffix* replay: replaying a launch line whose completion had
    /// already been consumed re-inserted it, and the count went back up. Sets
    /// that only ever grow make the answer independent of the order the lines
    /// are read in, which is the property a tail that re-reads actually needs.
    launched: std::collections::HashSet<String>,
    /// Keys whose `<task-notification>` has been read. Never removed either.
    finished: std::collections::HashSet<String>,
    /// The detector has run at least once on this session.
    ///
    /// The difference between "not asking" and "never looked", which is the
    /// difference the wire field is built around. It turns `true` at the first
    /// stop point and never back: a daemon that met the session already stopped
    /// sees no stop point, keeps this `false`, and says nothing rather than
    /// claiming the session is quiet.
    answer_observed: bool,
    /// The question on screen right now, if there is one.
    answer_pending: Option<PendingAnswer>,
    /// The assistant message being assembled: its `message.id` and its prose so
    /// far. One reply is several lines, and only the whole of it is the
    /// question.
    current_assistant: Option<(Option<String>, String)>,
    /// The turns before it, oldest first, bounded to what an excerpt can use.
    recent_turns: std::collections::VecDeque<ContextMessage>,
    /// Something older than `recent_turns` was dropped, so an excerpt built from
    /// it cannot claim to cover the conversation.
    recent_dropped: bool,
    /// `task-id` → the key its launch was filed under.
    ///
    /// A launch is keyed by its `tool-use-id` when it has one, and a dynamic
    /// workflow's notification arrives carrying only the `task-id`. Translating
    /// through this is what keeps both ends in one namespace, so the difference
    /// above can be a plain set difference over strings.
    agent_aliases: std::collections::HashMap<String, String>,
    /// When each launch was read, for the age limit. RFC 3339, as written.
    launched_at: std::collections::HashMap<String, String>,
}

/// How long a launch may stay open with no notification before it stops being
/// counted.
///
/// **Measured, not chosen for roundness.** Latency from a launch to its first
/// notification, over the 227 correlated pairs on the reference corpus that this
/// field actually counts — launches carrying an `agentId`, first notification
/// only:
///
/// | p50 | p75 | p90 | p95 | p98 | p99 | max |
/// |---|---|---|---|---|---|---|
/// | 157 s | 280 s | 635 s | 1006 s | 1563 s | 2524 s | 2543 s |
///
/// Thirty minutes sits above p98 with about 15% of headroom, and 4 of 227 waits
/// (1.8%) ran longer — the longest at 42 minutes, which is what the margin is
/// measured against rather than against a round number.
///
/// Giving up early is the deliberate direction. An expired launch under-reports,
/// and under-reporting reads as an idle card that is actually busy — recoverable
/// the moment anything else moves. Over-reporting is a card that says "3 agents
/// running" forever, which is the failure this whole field was rewritten to
/// avoid: with this limit the error is bounded at thirty minutes instead of
/// being unbounded in time.
///
/// What it is worth is honestly small and it is still required. On the corpus,
/// where every stop point is followed by more file, the limit removes **no**
/// stale reading that the other two closures did not already remove: correlating
/// the `attachment` notifications and refusing the uncorrelatable launches
/// account for all of it. Its case is the one a replay cannot show — the session
/// that stops writing altogether, where "the next read is simply right" never
/// arrives because there is no next line.
pub const AGENT_WAIT_MAX_SECS: i64 = 30 * 60;

/// A question the session is waiting on an answer to, and which rule saw it.
///
/// The signal travels with the request rather than being derived again by
/// whoever publishes it: `docs/PROTOCOL.md` says clients must not re-derive it,
/// and a producer that recomputed it here would be the first client to break
/// that rule.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PendingAnswer {
    pub signal: Signal,
    pub request: AnswerRequest,
}

/// How much of one turn is kept for the excerpt, in characters.
///
/// A message longer than the whole excerpt budget can never be taken by
/// [`AnswerRequestConfig::build_request`], which refuses to split one — so
/// keeping more of it than the length that makes it refuse is memory spent to
/// change nothing. One character over the budget preserves the decision exactly
/// while bounding what a session can hold.
///
/// ## What one live session can hold, and what is not bounded
///
/// This is the field that made `Telemetry` big, and `Telemetry` is cloned once
/// per debounce window per session (`watch.rs`, and again in the daemon's
/// `finalize`), so the ceiling is worth writing down. **Derived from the caps in
/// this file, not measured on a heap profile** — no allocation profiling was
/// run, and the numbers below are upper bounds on the strings, not on the
/// process.
///
/// Bounded:
///
/// - `recent_turns` — at most `context_max_messages` (12) entries of
///   `KEPT_CHARS_PER_TURN` (6001) **characters** each. Characters, because
///   [`Telemetry::remember_turn`] cuts with `chars().take(…)`, so the byte
///   ceiling is 4× that: 12 × 6001 × 4 ≈ **281 KiB** worst case, and roughly a
///   quarter of it for the Portuguese and English prose this actually holds.
/// - `answer_pending.request.context` — a copy of a prefix of `recent_turns`,
///   itself capped at `context_char_budget` (6000) characters in total by
///   [`AnswerRequestConfig::build_request`]: ≤ 24 KiB worst case.
///
/// Not bounded here, and stated rather than glossed:
///
/// - `current_assistant` and `answer_pending.request.question` both hold one
///   whole assistant message, capped by nothing in this crate. `MAX_QUESTION_BYTES`
///   (128 KiB) is a *wire* cap applied on the way out, in the daemon's
///   `wire_answer`, so the in-memory copy may legitimately exceed it. What
///   limits them in practice is how long one reply can be, which was not
///   measured.
///
/// So: the ring is the part with a number, and it is small enough that a clone
/// per debounce is not what would justify an `Arc` — if the clone ever shows up
/// in a profile, the message being assembled is the part to look at first.
const KEPT_CHARS_PER_TURN: usize = ANSWER_REQUEST.context_char_budget + 1;

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
                // Only ever *fills in* a size, never clears one. The
                // authoritative value arrives from outside this crate (the
                // status line payload), and a turn that says nothing about the
                // window must not erase what something better already told us.
                if self.context_window_size_tokens.is_none() {
                    self.context_window_size_tokens =
                        self.model.as_deref().and_then(window_size_for_model);
                }

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
                    add_into(
                        &mut self.cumulative_cache_read_tokens,
                        turn.usage.cache_read_input_tokens,
                    );
                    add_into(
                        &mut self.cumulative_cache_creation_tokens,
                        turn.usage.cache_creation_input_tokens,
                    );
                }

                // Prose, joined by `message.id`. Also the moment a question
                // stops being open: the agent is writing again, so whatever it
                // asked before belongs to a turn that is over.
                self.note_assistant_text(turn.message_id.as_deref(), turn.text.as_deref());
            }

            TranscriptEvent::UserTurn { text, human, .. } => {
                self.turn_count += 1;
                // A user line ends the wait whoever wrote it. A person answered,
                // or a notification arrived and the stop was never a person's to
                // begin with — the two are different reasons and the same
                // outcome, which is why `human` only decides whether the words
                // go into the excerpt as a turn worth showing.
                self.close_assistant_message();
                if *human {
                    if let Some(text) = text {
                        self.remember_turn("user", text);
                    }
                }
                self.answer_pending = None;
            }

            TranscriptEvent::StopPoint { .. } => self.decide_answer_request(),

            TranscriptEvent::AiTitle { text, .. } => {
                self.ai_title = Some(text.clone());
            }

            TranscriptEvent::ToolUse(tool) => {
                self.wrote_untracked |= tool.writes_untracked;
                let label = match &tool.summary {
                    Some(s) => format!("{} {}", tool.name, s),
                    None => tool.name.clone(),
                };
                self.last_action = Some(label.clone());
                if let Some(id) = &tool.id {
                    self.open_tools.push((id.clone(), label));
                }
                self.refresh_in_flight();
                // A tool call is the agent back at work, and an agent at work is
                // not waiting on an answer. Erring towards clearing is the
                // asymmetry this field is calibrated on: a question dropped too
                // early comes back on the next stop point, a question left up
                // never corrects itself.
                self.answer_pending = None;
            }

            TranscriptEvent::ToolResult {
                tool_use_id, file, ..
            } => {
                self.open_tools.retain(|(id, _)| id != tool_use_id);
                self.refresh_in_flight();

                if let Some(change) = file {
                    // The same guard the usage block gets, for the same reason.
                    if self.seen_tool_results.insert(tool_use_id.clone()) {
                        let stat = self.files.entry(change.path.clone()).or_default();
                        stat.added = stat.added.saturating_add(change.added);
                        stat.removed = stat.removed.saturating_add(change.removed);
                        // Sticky: created once is created, however many edits
                        // followed.
                        stat.created |= change.created;
                    }
                }
            }

            TranscriptEvent::AgentLaunched {
                tool_use_id,
                task_id,
                at,
            } => {
                // **Both ends have to share a key, and a launch with no
                // `agentId` cannot promise that.** Measured: every `Workflow`
                // launch on the corpus announces none — 47 of 282, no
                // exceptions — while part of its notifications carry only the
                // `task-id`, which is precisely the id such a launch never gave
                // us. Opening a wait nothing can close is the one error that
                // never corrects itself, so those 47 are given up on
                // deliberately.
                let Some(alias) = task_id.clone() else {
                    return;
                };
                let key = tool_use_id.clone().unwrap_or_else(|| alias.clone());
                if alias != key {
                    self.agent_aliases.insert(alias, key.clone());
                }
                if let Some(at) = at {
                    self.launched_at.entry(key.clone()).or_insert(at.clone());
                }
                self.launched.insert(key);
            }

            TranscriptEvent::AgentFinished {
                tool_use_id,
                task_id,
                ..
            } => {
                // Both ids are recorded, each also translated through the alias
                // table: the notification may name the launch's own key, or the
                // `task-id` the launch was acknowledged with, and either one
                // closes the same wait.
                for id in [tool_use_id, task_id].into_iter().flatten() {
                    if let Some(key) = self.agent_aliases.get(id) {
                        self.finished.insert(key.clone());
                    }
                    self.finished.insert(id.clone());
                }
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

    // ---- answer_request -------------------------------------------------
    //
    // The producer side of `docs/PROTOCOL.md` § `answer_request`, as a state
    // machine over the same events everything else here folds. The rule itself
    // is not reimplemented: it is [`ANSWER_REQUEST`], calibrated and measured in
    // `answer_request.rs`, called once, at a stop point.

    /// What this session is asking, if it is asking, if we ever looked.
    ///
    /// **Three states, and the outer `Option` is the one that is easy to lose.**
    /// `None` means no stop point has been read for this session, so there is
    /// nothing to claim in either direction — a session met already stopped, or
    /// one running without the `Stop` hook that writes the line, lands here.
    /// `Some(None)` is the positive claim "stopped, and asked nothing";
    /// `Some(Some(_))` is a question on screen.
    pub fn answer_request(&self) -> Option<Option<&PendingAnswer>> {
        self.answer_observed.then(|| self.answer_pending.as_ref())
    }

    /// Fold one assistant line's prose into the message being assembled.
    fn note_assistant_text(&mut self, message_id: Option<&str>, text: Option<&str>) {
        let same_message = match &self.current_assistant {
            // A line with no id cannot be correlated with anything, so it opens
            // its own message rather than joining whatever came before it.
            Some((current, _)) => message_id.is_some() && current.as_deref() == message_id,
            None => false,
        };
        if !same_message {
            self.close_assistant_message();
            self.current_assistant = Some((message_id.map(str::to_string), String::new()));
        }
        if let (Some((_, buffer)), Some(text)) = (self.current_assistant.as_mut(), text) {
            if !text.trim().is_empty() {
                if !buffer.is_empty() {
                    buffer.push_str("\n\n");
                }
                buffer.push_str(text);
            }
        }
        // The agent is writing, so whatever it asked before is answered, taken
        // back, or superseded.
        self.answer_pending = None;
    }

    /// Move the assembled assistant message into the excerpt history.
    fn close_assistant_message(&mut self) {
        if let Some((_, text)) = self.current_assistant.take() {
            if !text.trim().is_empty() {
                self.remember_turn("assistant", &text);
            }
        }
    }

    /// Keep one turn for the excerpt, dropping the oldest when full.
    fn remember_turn(&mut self, role: &'static str, text: &str) {
        if self.recent_turns.len() >= ANSWER_REQUEST.context_max_messages {
            self.recent_turns.pop_front();
            self.recent_dropped = true;
        }
        self.recent_turns.push_back(ContextMessage {
            role,
            text: text.chars().take(KEPT_CHARS_PER_TURN).collect(),
        });
    }

    /// Run the rule at a stop point, which is the only place it runs.
    ///
    /// `human_stop` is passed as `true`, and that is a decision rather than an
    /// oversight. Live, the line that says whether a person got the keyboard has
    /// not been written yet — the probe that measured this rule defaults the
    /// same way when no `user` line follows. What corrects it is the next line:
    /// a `<task-notification>` is a `UserTurn` and clears the question, and the
    /// reader folds a whole batch of new lines before publishing, so a stop that
    /// was never a person's is normally corrected before it reaches the wire.
    fn decide_answer_request(&mut self) {
        self.answer_observed = true;
        let question = self
            .current_assistant
            .as_ref()
            .map(|(_, text)| text.clone())
            .unwrap_or_default();

        self.answer_pending = match ANSWER_REQUEST.evaluate(&question, true) {
            Ok(signal) => {
                let earlier: Vec<ContextMessage> = self.recent_turns.iter().cloned().collect();
                // `cwd` is for the drafting payload and has no wire field; the
                // daemon knows the directory and does not need it from here.
                let mut request = ANSWER_REQUEST.build_request(&question, &earlier, None);
                // What the ring dropped is missing from the excerpt too, and
                // only this side knows it happened.
                request.context_truncated |= self.recent_dropped;
                Some(PendingAnswer { signal, request })
            }
            Err(_) => None,
        };
    }

    /// How many background agents this session is waiting on, **derived**.
    ///
    /// Launches seen minus notifications seen, over the transcript as read so
    /// far, minus the ones that have been open longer than
    /// [`AGENT_WAIT_MAX_SECS`]. Never incremented and never stored on the wire's
    /// behalf: the daemon asks this question again on every read, so the answer
    /// cannot drift further than one read away from the file.
    ///
    /// `now` is wall-clock time and comes from the caller, deliberately. The
    /// last line of the transcript will not do: a session that stopped with an
    /// agent that never reports writes **nothing more**, so an age measured
    /// against the file's own last timestamp would freeze at the very moment the
    /// backstop is needed.
    ///
    /// A session stopped with this above zero is busy without computing:
    /// `state` is `idle` because the `Stop` hook fired, and nobody needs to look
    /// at it. See `docs/PROTOCOL.md` § `pending_agents`.
    pub fn pending_agents(&self, now: DateTime<Utc>) -> u64 {
        self.launched
            .difference(&self.finished)
            .filter(|key| !self.expired(key, now))
            .count() as u64
    }

    /// Has this launch been open long enough to stop believing in it?
    ///
    /// A launch whose line carried no timestamp, or one this build cannot parse,
    /// counts as expired rather than as ageless. It is the same asymmetry as
    /// everywhere else in this field: an under-count corrects itself, and a
    /// launch that can never age out is exactly the permanent lie the age limit
    /// exists to prevent.
    fn expired(&self, key: &str, now: DateTime<Utc>) -> bool {
        let Some(at) = self.launched_at.get(key) else {
            return true;
        };
        let Ok(at) = DateTime::parse_from_rfc3339(at) else {
            return true;
        };
        now.signed_duration_since(at.with_timezone(&Utc))
            .num_seconds()
            > AGENT_WAIT_MAX_SECS
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
/// **Always `None`, deliberately.** This function is kept as the one place the
/// question is asked, and its answer is that it cannot be answered here.
///
/// It used to be a lookup table: `opus`/`sonnet` → 200k, a `[1m]` suffix → 1M.
/// That was wrong the day it shipped. A real session was measured running
/// `claude-opus-5` — no suffix — against a **one-million** token window, while
/// the table said 200k. The card read 24% where the agent's own status line
/// read 5%.
///
/// The reason is structural, not a missing entry: **the window is a property of
/// the account and the model together, not of the model name.** The same
/// `claude-opus-5` is 200k for one user and 1M for another depending on what
/// their plan enables. No table keyed on the name can be right for everyone,
/// and a table that is right for the author is the most dangerous kind, because
/// it looks correct in every test they run.
///
/// The authoritative source exists: Claude Code passes `context_window_size` to
/// the status line command on stdin, alongside `used_percentage` and the
/// account's rate limits. Wiring that up is a separate piece of work —
/// installing a status line means wrapping whatever the user already has.
/// Until then the size is genuinely unknown, the gauge renders indeterminate,
/// and `violeet doctor` says which models are affected.
///
/// Returning `None` costs the gauge. Returning a plausible wrong number costs
/// the user's trust in every number on the card, which is worth more.
pub fn window_size_for_model(_model: &str) -> Option<u64> {
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
            text: None,
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
            text: None,
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
            text: None,
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
            text: None,
        }));

        assert_eq!(t.context_window_size_tokens, None);
        assert_eq!(t.context_fraction(), None);
        assert_eq!(
            t.compaction_imminent(DEFAULT_COMPACTION_THRESHOLD),
            None,
            "an unknown window must not render as `plenty of room`"
        );
    }

    /// The threshold logic, given a window size from somewhere.
    ///
    /// Set by hand, because `window_size_for_model` no longer invents one — the
    /// size has to arrive from the status line payload, and until it does the
    /// signal is `None` rather than a guess. The arithmetic still has to be
    /// right for when it does arrive.
    #[test]
    fn the_imminent_signal_fires_at_the_threshold_once_a_size_is_known() {
        let mut t = Telemetry::new();
        t.apply(&turn("m1", 170_000, 0, 10));
        assert_eq!(
            t.context_window_size_tokens, None,
            "nothing has told us the window size yet"
        );
        assert_eq!(t.compaction_imminent(0.85), None);

        t.context_window_size_tokens = Some(200_000);
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
            writes_untracked: false,
        }));
        assert_eq!(t.in_flight_tool.as_deref(), Some("Bash cargo test"));
        assert_eq!(t.last_action.as_deref(), Some("Bash cargo test"));

        t.apply(&TranscriptEvent::ToolResult {
            tool_use_id: "toolu_1".into(),
            at: None,
            file: None,
        });
        assert_eq!(t.in_flight_tool, None, "returned, so no longer in flight");
        assert_eq!(
            t.last_action.as_deref(),
            Some("Bash cargo test"),
            "the last action is still the last action"
        );
    }

    /// The window size is not derivable from the model name, and this asserts
    /// that we no longer pretend otherwise.
    ///
    /// Guards a regression that already happened once: a table said
    /// `claude-opus-5` was 200k, a real session ran it at 1M, and the card
    /// reported 24% where the truth was 5%. The same name means different
    /// windows for different accounts.
    #[test]
    fn the_window_size_is_never_guessed_from_the_model_name() {
        for model in ["claude-opus-5", "claude-opus-5[1m]", "claude-sonnet-5", "anything"] {
            assert_eq!(
                window_size_for_model(model),
                None,
                "{model}: a guessed window produces a plausible, wrong percentage"
            );
        }
    }

    // ---- accumulating file changes --------------------------------------

    fn wrote(tool_use_id: &str, path: &str, added: u64, removed: u64) -> TranscriptEvent {
        TranscriptEvent::ToolResult {
            tool_use_id: tool_use_id.into(),
            at: Some("2026-07-31T22:00:00Z".into()),
            file: Some(FileChange {
                path: path.into(),
                added,
                removed,
                created: false,
            }),
        }
    }

    #[test]
    fn editing_one_file_twice_sums_both_edits() {
        let mut t = Telemetry::new();
        t.apply(&wrote("t1", "/repo/a.rs", 10, 2));
        t.apply(&wrote("t2", "/repo/a.rs", 5, 1));

        assert_eq!(t.files.len(), 1);
        let stat = t.files["/repo/a.rs"];
        assert_eq!((stat.added, stat.removed), (15, 3));
    }

    /// The guard that matters. A tail that re-reads, a resumed session, a
    /// truncated file: the same call arrives twice and must count once. This is
    /// the diffstat's version of the 2.8x cost inflation.
    #[test]
    fn the_same_tool_call_seen_twice_counts_once() {
        let mut t = Telemetry::new();
        let event = wrote("t1", "/repo/a.rs", 10, 2);
        t.apply(&event);
        t.apply(&event);

        let stat = t.files["/repo/a.rs"];
        assert_eq!(
            (stat.added, stat.removed),
            (10, 2),
            "dedup keys on the tool call, not the path"
        );
    }

    #[test]
    fn creating_a_file_and_then_editing_it_leaves_it_created() {
        let mut t = Telemetry::new();
        t.apply(&TranscriptEvent::ToolResult {
            tool_use_id: "t1".into(),
            at: None,
            file: Some(FileChange {
                path: "/repo/new.md".into(),
                added: 40,
                removed: 0,
                created: true,
            }),
        });
        t.apply(&wrote("t2", "/repo/new.md", 3, 1));

        let stat = t.files["/repo/new.md"];
        assert!(stat.created, "created once is created, however many edits follow");
        assert_eq!((stat.added, stat.removed), (43, 1));
    }

    #[test]
    fn a_tool_result_with_no_file_leaves_the_list_alone() {
        let mut t = Telemetry::new();
        t.apply(&TranscriptEvent::ToolResult {
            tool_use_id: "t1".into(),
            at: None,
            file: None,
        });
        assert!(t.files.is_empty());
    }

    /// The flag is sticky. One shell write leaves a hole in the list from then
    /// on, and a tracked edit afterwards does not fill it — a flag that cleared
    /// would claim the list is complete when it is not.
    #[test]
    fn an_untracked_write_marks_the_session_for_good() {
        let mut t = Telemetry::new();
        assert!(!t.wrote_untracked, "a fresh session has seen nothing");

        t.apply(&TranscriptEvent::ToolUse(ToolUse {
            id: Some("t1".into()),
            name: "Bash".into(),
            summary: Some("echo x > f".into()),
            at: None,
            writes_untracked: true,
        }));
        assert!(t.wrote_untracked);

        // A perfectly visible edit lands afterwards. The hole is still there.
        t.apply(&TranscriptEvent::ToolUse(ToolUse {
            id: Some("t2".into()),
            name: "Edit".into(),
            summary: Some("/repo/a.rs".into()),
            at: None,
            writes_untracked: false,
        }));
        assert!(t.wrote_untracked, "one shell write is not undone by a tracked one");
    }

    // ---- pending agents: a set difference, not a counter -----------------

    fn launched(tool_use_id: &str, task_id: &str) -> TranscriptEvent {
        TranscriptEvent::AgentLaunched {
            tool_use_id: Some(tool_use_id.into()),
            task_id: Some(task_id.into()),
            at: Some("2026-08-08T10:00:00Z".into()),
        }
    }

    /// The moment the count is asked for. Five minutes after the launches
    /// above, which is inside [`AGENT_WAIT_MAX_SECS`] and just above the
    /// measured p50.
    fn now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-08-08T10:05:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }

    fn later(secs: i64) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-08-08T10:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
            + chrono::Duration::seconds(secs)
    }

    fn finished(tool_use_id: Option<&str>, task_id: Option<&str>) -> TranscriptEvent {
        TranscriptEvent::AgentFinished {
            tool_use_id: tool_use_id.map(Into::into),
            task_id: task_id.map(Into::into),
            at: Some("2026-08-08T10:05:00Z".into()),
        }
    }

    #[test]
    fn a_session_waiting_on_two_agents_says_two() {
        let mut t = Telemetry::new();
        assert_eq!(
            t.pending_agents(now()),
            0,
            "nothing dispatched, nothing pending"
        );
        t.apply(&launched("toolu_a", "agent_a"));
        t.apply(&launched("toolu_b", "agent_b"));
        assert_eq!(t.pending_agents(now()), 2);
        t.apply(&finished(Some("toolu_a"), Some("agent_a")));
        assert_eq!(t.pending_agents(now()), 1);
    }

    /// The one a launch acknowledgement leaves nothing in flight, which is the
    /// reason this field exists at all: the tool *returned*, the work did not.
    #[test]
    fn a_launched_agent_is_pending_while_no_tool_is_in_flight() {
        let mut t = Telemetry::new();
        t.apply(&TranscriptEvent::ToolUse(ToolUse {
            id: Some("toolu_a".into()),
            name: "Agent".into(),
            summary: Some("pr-reviewer".into()),
            at: None,
            writes_untracked: false,
        }));
        t.apply(&TranscriptEvent::ToolResult {
            tool_use_id: "toolu_a".into(),
            at: None,
            file: None,
        });
        t.apply(&launched("toolu_a", "agent_a"));

        assert_eq!(
            t.in_flight_tool, None,
            "the acknowledgement closed the call"
        );
        assert_eq!(t.pending_agents(now()), 1, "and the agent is still working");
    }

    /// **The test that proves deriving beats counting.**
    ///
    /// A notification that never arrives — a lost `SubagentStop`, a session
    /// killed mid-flight — leaves a wrong reading for exactly as long as the file
    /// is missing the line. The moment the transcript carries it, the next read
    /// is right, with no repair step and nothing to reset. A counter would have
    /// stayed wrong until the session ended.
    #[test]
    fn a_lost_completion_costs_one_read_and_corrects_itself_on_the_next() {
        // Read 1: two launched, one reported in — and the other's notification
        // was lost, so the file simply does not have it yet.
        let lines_read_1 = vec![
            launched("toolu_a", "agent_a"),
            launched("toolu_b", "agent_b"),
            finished(Some("toolu_a"), Some("agent_a")),
        ];
        let mut first = Telemetry::new();
        for event in &lines_read_1 {
            first.apply(event);
        }
        assert_eq!(
            first.pending_agents(now()),
            1,
            "stale by one, and only by one"
        );

        // Read 2 is the same fold over the file as it now stands. Nothing
        // decrements: the count is the set difference all over again.
        let mut second = Telemetry::new();
        for event in lines_read_1
            .iter()
            .chain(std::iter::once(&finished(Some("toolu_b"), Some("agent_b"))))
        {
            second.apply(event);
        }
        assert_eq!(
            second.pending_agents(now()),
            0,
            "the next read is simply right"
        );
    }

    /// Re-reading is how a tail recovers from a truncated line, so the fold has
    /// to survive seeing the same lines twice. A counter would double.
    #[test]
    fn replaying_the_same_lines_does_not_move_the_count() {
        let events = [
            launched("toolu_a", "agent_a"),
            launched("toolu_b", "agent_b"),
            finished(Some("toolu_a"), Some("agent_a")),
        ];
        let mut t = Telemetry::new();
        for event in events.iter().chain(events.iter()) {
            t.apply(event);
        }
        assert_eq!(t.pending_agents(now()), 1);
    }

    /// A dynamic workflow's notification carries only `task-id`. Correlating on
    /// `tool-use-id` alone would leave it pending forever.
    #[test]
    fn a_notification_with_only_a_task_id_still_closes_the_wait() {
        let mut t = Telemetry::new();
        t.apply(&launched("toolu_a", "agent_a"));
        t.apply(&finished(None, Some("agent_a")));
        assert_eq!(t.pending_agents(now()), 0);
    }

    /// A launch with no id at all cannot be correlated, so counting it would
    /// produce a number that never comes back down — the exact failure the
    /// derived design exists to avoid.
    #[test]
    fn a_launch_with_no_id_is_not_counted() {
        let mut t = Telemetry::new();
        t.apply(&TranscriptEvent::AgentLaunched {
            tool_use_id: None,
            task_id: None,
            at: None,
        });
        assert_eq!(t.pending_agents(now()), 0);
    }

    /// The `Workflow` shape, and the 47 launches given up on by decision.
    ///
    /// The launch has a `tool-use-id` and no `agentId`; part of its
    /// notifications carry only a `task-id`. Keyed on the `tool-use-id` it would
    /// be opened by the launch and closed by nothing.
    #[test]
    fn a_launch_with_no_agent_id_is_not_counted_even_though_it_has_a_tool_use_id() {
        let mut t = Telemetry::new();
        t.apply(&TranscriptEvent::AgentLaunched {
            tool_use_id: Some("toolu_w".into()),
            task_id: None,
            at: Some("2026-08-08T10:00:00Z".into()),
        });
        assert_eq!(
            t.pending_agents(now()),
            0,
            "the two ends share no key, so this wait could never be closed"
        );

        // And the notification that only names the task id changes nothing,
        // which is the whole reason the launch was refused.
        t.apply(&finished(None, Some("wf_1")));
        assert_eq!(t.pending_agents(now()), 0);
    }

    /// The backstop. An agent that never reports — user interrupt, killed
    /// process, session ended mid-flight — stops counting once it is older than
    /// [`AGENT_WAIT_MAX_SECS`], instead of poisoning the card for good.
    #[test]
    fn a_launch_that_never_reports_stops_counting_once_it_is_too_old() {
        let mut t = Telemetry::new();
        t.apply(&launched("toolu_a", "agent_a"));

        assert_eq!(
            t.pending_agents(later(60)),
            1,
            "a minute in, still believed"
        );
        assert_eq!(
            t.pending_agents(later(AGENT_WAIT_MAX_SECS)),
            1,
            "the limit itself is still inside it"
        );
        assert_eq!(
            t.pending_agents(later(AGENT_WAIT_MAX_SECS + 1)),
            0,
            "past the limit the card stops claiming an agent is running"
        );
    }

    /// A launch whose line carried no timestamp cannot be aged out, so it is not
    /// counted at all. The alternative is an entry that lives forever, which is
    /// the failure the age limit was added to close.
    #[test]
    fn a_launch_with_no_timestamp_is_not_counted() {
        let mut t = Telemetry::new();
        t.apply(&TranscriptEvent::AgentLaunched {
            tool_use_id: Some("toolu_a".into()),
            task_id: Some("agent_a".into()),
            at: None,
        });
        assert_eq!(t.pending_agents(now()), 0);
    }

    /// The property two `Vec`s with `retain` did not have.
    ///
    /// A tail re-reads to recover from a truncated line, and a re-read is not
    /// guaranteed to start before the completion it already consumed. With
    /// removal, replaying the *launch* after its notification put the agent back:
    /// the count went up and stayed up. As a set difference the answer does not
    /// depend on the order at all.
    #[test]
    fn replaying_a_launch_after_its_completion_does_not_reopen_the_wait() {
        let mut t = Telemetry::new();
        t.apply(&launched("toolu_a", "agent_a"));
        t.apply(&finished(Some("toolu_a"), Some("agent_a")));
        assert_eq!(t.pending_agents(now()), 0);

        t.apply(&launched("toolu_a", "agent_a"));
        assert_eq!(
            t.pending_agents(now()),
            0,
            "the launch was already answered, whatever order it is read in"
        );
    }

    // ---- answer_request: the three states --------------------------------

    fn said(id: &str, text: &str) -> TranscriptEvent {
        TranscriptEvent::AssistantTurn(AssistantTurn {
            message_id: Some(id.into()),
            model: None,
            usage: Usage::default(),
            at: None,
            text: Some(text.into()),
        })
    }

    fn typed(text: &str) -> TranscriptEvent {
        TranscriptEvent::UserTurn {
            at: None,
            text: Some(text.into()),
            human: true,
        }
    }

    fn stopped() -> TranscriptEvent {
        TranscriptEvent::StopPoint { at: None }
    }

    /// Absent is not `null`, and this is the distinction the whole field is
    /// built on: a session no stop point has been read for is one the daemon
    /// knows nothing about, and it must not claim there is no question.
    #[test]
    fn a_session_never_stopped_says_nothing_about_a_question() {
        let mut t = Telemetry::new();
        assert!(t.answer_request().is_none(), "nothing read yet");

        t.apply(&typed("compara as duas rotas"));
        t.apply(&said("m1", "Achei dois caminhos. Sigo pelo primeiro?"));
        assert!(
            t.answer_request().is_none(),
            "the words are written but the turn has not ended: nothing is waiting on anybody yet"
        );
    }

    /// A question in prose, at a stop point, with the conversation that led to
    /// it — the case `state: idle` cannot express.
    #[test]
    fn a_question_at_a_stop_point_becomes_a_request_with_its_context() {
        let mut t = Telemetry::new();
        t.apply(&typed("compara as duas rotas"));
        t.apply(&said("m1", "A primeira lê do fim do arquivo."));
        t.apply(&typed("e a segunda?"));
        t.apply(&said("m2", "A segunda relê tudo.\n\nSigo pela primeira?"));
        t.apply(&stopped());

        let pending = t
            .answer_request()
            .expect("observed")
            .expect("asking")
            .clone();
        assert_eq!(pending.signal, Signal::QuestionMark);
        assert_eq!(
            pending.request.question,
            "A segunda relê tudo.\n\nSigo pela primeira?"
        );
        assert_eq!(
            pending
                .request
                .context
                .iter()
                .map(|m| m.role)
                .collect::<Vec<_>>(),
            vec!["user", "assistant", "user"],
            "oldest first, and the asking message is not repeated in its own excerpt"
        );
        assert!(!pending.request.context_truncated);
    }

    /// Observed and quiet is a claim worth making: it is what closes a panel the
    /// app opened, and it is not the same as never having looked.
    #[test]
    fn a_stop_with_nothing_asked_is_an_explicit_no_question() {
        let mut t = Telemetry::new();
        t.apply(&typed("faz o corte"));
        t.apply(&said("m1", "Feito. Os dois arquivos foram atualizados."));
        t.apply(&stopped());

        assert_eq!(
            t.answer_request().map(|p| p.is_none()),
            Some(true),
            "observed, and asking nothing"
        );
    }

    /// The three readings side by side, on one session, in the order they
    /// happen. Absent, then an object, then `null` — and the test exists because
    /// the wire field is worthless if any two of them collapse.
    #[test]
    fn the_three_states_follow_one_another_and_stay_distinct() {
        let mut t = Telemetry::new();
        assert!(t.answer_request().is_none(), "1. never looked");

        t.apply(&said("m1", "Sigo pelo primeiro?"));
        t.apply(&stopped());
        assert!(
            t.answer_request().flatten().is_some(),
            "2. a question on screen"
        );

        t.apply(&typed("sim, pode seguir"));
        assert_eq!(
            t.answer_request().map(|p| p.is_none()),
            Some(true),
            "3. answered: still observed, no longer asking"
        );
    }

    /// The agent going back to work ends the wait as surely as an answer does.
    #[test]
    fn the_agent_picking_the_work_back_up_closes_the_question() {
        let mut t = Telemetry::new();
        t.apply(&said("m1", "Quer que eu siga?"));
        t.apply(&stopped());
        assert!(t.answer_request().flatten().is_some());

        t.apply(&TranscriptEvent::ToolUse(ToolUse {
            id: Some("toolu_1".into()),
            name: "Edit".into(),
            summary: None,
            at: None,
            writes_untracked: false,
        }));
        assert_eq!(
            t.answer_request().map(|p| p.is_none()),
            Some(true),
            "a tool in flight is an agent working, not one waiting"
        );
    }

    /// A background agent reporting in is a `user` line and not a person. It
    /// closes the wait — the stop was never a human's — and its text does not
    /// enter the excerpt as something somebody said.
    #[test]
    fn a_notification_closes_the_wait_without_joining_the_conversation() {
        let mut t = Telemetry::new();
        t.apply(&typed("dispara os agentes"));
        t.apply(&said("m1", "Disparei. Quer que eu acompanhe?"));
        t.apply(&stopped());
        assert!(t.answer_request().flatten().is_some());

        t.apply(&TranscriptEvent::UserTurn {
            at: None,
            text: Some("<task-notification>done</task-notification>".into()),
            human: false,
        });
        assert_eq!(t.answer_request().map(|p| p.is_none()), Some(true));

        t.apply(&said("m2", "E aí, sigo?"));
        t.apply(&stopped());
        let pending = t.answer_request().flatten().expect("asking again");
        assert!(
            !pending
                .request
                .context
                .iter()
                .any(|m| m.text.contains("task-notification")),
            "a notification is not a turn of the conversation"
        );
    }

    /// One reply is several lines under one `message.id`, and only the whole of
    /// it is the question: the `?` lands on the last line.
    #[test]
    fn one_reply_written_over_several_lines_is_read_as_one_question() {
        let mut t = Telemetry::new();
        t.apply(&said("m1", "Achei dois caminhos para o corte."));
        t.apply(&said("m1", "Sigo pelo primeiro?"));
        t.apply(&stopped());

        let pending = t.answer_request().flatten().expect("asking");
        assert_eq!(
            pending.request.question,
            "Achei dois caminhos para o corte.\n\nSigo pelo primeiro?"
        );
    }

    /// An excerpt that lost the beginning of the conversation says so. The ring
    /// is what dropped it, and only the ring knows.
    #[test]
    fn an_excerpt_over_a_dropped_history_is_marked_truncated() {
        let mut t = Telemetry::new();
        for i in 0..ANSWER_REQUEST.context_max_messages + 4 {
            t.apply(&typed(&format!("turno {i}")));
        }
        t.apply(&said("m1", "Sigo?"));
        t.apply(&stopped());

        let pending = t.answer_request().flatten().expect("asking");
        assert!(
            pending.request.context_truncated,
            "older turns were dropped before the excerpt was built"
        );
    }
}
