//! Did the agent stop *asking the user something*?
//!
//! A session that goes idle has not necessarily asked for anything. It may have
//! finished a report, been interrupted, or handed off to a background task. Only
//! some idle moments are an invitation to type a reply, and those are the only
//! ones worth offering a drafted answer for.
//!
//! # This is measured, not guessed
//!
//! The rule below was run against every transcript under
//! `~/.claude/projects` on the reference machine: **112 sessions, 835 stop
//! points** carrying assistant text, where a stop point is a
//! `system`/`stop_hook_summary` line — the moment Claude Code's `Stop` hook
//! fired — paired with the last assistant message before it.
//!
//! | figure | measured |
//! |---|---|
//! | stop points with assistant text | 835 |
//! | not a human stop (background, local command, interrupt) | 247 (29.6%) |
//! | human stop points | 588 |
//! | rule fires | 268 = **32.1%** of all stop points |
//! | rule fires on a human stop | 268 = **45.6%** of human stops |
//!
//! Reproduce with `cargo run --release --example answer_request_probe -p
//! violeet-transcript`. A second implementation, written in Python against the
//! same files, agreed to within one stop point (32.0% / 45.1%) — the same
//! two-implementation discipline `docs/TRANSCRIPT_FORMAT.md` uses.
//!
//! The two text guards below suppressed **zero** stop points in this corpus:
//! neither `No response requested.` nor an `API Error:` was the closing message
//! at a stop. They are cheap insurance against a shape that is known to exist,
//! not a measured contributor, and this note says which.
//!
//! Two variants were measured and rejected. Widening the lexicon scope from the
//! **last** paragraph to the last two raised the false-positive rate from ~3% to
//! ~10% on a hand-read sample: closing sentences of a long report routinely say
//! "prefere" about something the agent already decided. Dropping the `?` signal
//! and keeping only the lexicon lost most explicit questions, which are the
//! cheapest case to get right.
//!
//! The calibration target is deliberately asymmetric. A false positive costs an
//! ignored button; a false negative costs the feature. But a rule that fires on
//! every stop is a rule that says nothing, so ~1 stop in 3 is the intended
//! shape, and an implementation that drifts far from the table above is wrong
//! rather than differently tuned.
//!
//! # Not a permission request
//!
//! This has nothing to do with HITL. A `PermissionRequest` is a blocked tool
//! call with its own hook, its own `hitl_id` and its own path through the
//! daemon; see `docs/PROTOCOL.md`. This module looks only at prose the assistant
//! wrote, and never at a pending tool call.

use serde_json::Value;

// ---------------------------------------------------------------------------
// The parameters, in one place
// ---------------------------------------------------------------------------

/// Every tunable of the rule, so there is exactly one thing to audit.
///
/// The fields are not defaults scattered across call sites: [`ANSWER_REQUEST`]
/// is the calibrated instance, the numbers in the module note describe *it*, and
/// a caller that builds its own is on its own for the rates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AnswerRequestConfig {
    /// How many trailing paragraphs the `?` signal may look at. Measured at 2.
    pub question_mark_paragraphs: usize,
    /// How many trailing paragraphs the lexicon may look at. Measured at 1, and
    /// this is the parameter that holds the false-positive rate down.
    pub lexicon_paragraphs: usize,
    /// How far after a conditional opener a first-person verb still counts, in
    /// characters, and vice versa.
    pub near_window_chars: usize,
    /// Ceiling on the context excerpt sent to a provider, in characters.
    pub context_char_budget: usize,
    /// Ceiling on the number of messages in that excerpt.
    pub context_max_messages: usize,
}

/// The calibrated rule. The rates in the module note are this instance's.
pub const ANSWER_REQUEST: AnswerRequestConfig = AnswerRequestConfig {
    question_mark_paragraphs: 2,
    lexicon_paragraphs: 1,
    near_window_chars: 60,
    context_char_budget: 6000,
    context_max_messages: 12,
};

/// Plain substrings, matched against diacritic-folded lowercase text.
///
/// Folding rather than listing every accented spelling: real transcripts carry
/// both "você" and "voce" and neither is a typo worth a second entry.
const LEXICON: &[&str] = &[
    "quer que eu",
    "voce quer",
    "vc quer",
    // Covers "ou prefere" and "prefere" alike.
    "prefere",
    "me diga",
    "me diz",
    "me fala",
    "me avisa",
    "me avise",
    "me confirma",
    "me manda",
    "me chama",
    "e so dizer",
    "e so falar",
    "e so avisar",
    "e so me chamar",
    "e so pedir",
    "aguardo",
    "aguardando seu",
    "aguardando sua",
    "aguardando teu",
    "aguardando tua",
    "sua palavra",
    "tua palavra",
    "quando voce mandar",
    "salvo instrucao em contrario",
    "o que voce acha",
    "o que voce prefere",
    "o que voce quer",
    "o que voce decide",
    "decisao e sua",
    "decisao e tua",
];

/// "se quiser" / "se preferir" — an offer, but only when a first-person verb is
/// near it. On its own the phrase appears in plain narration.
const CONDITIONAL_OPENERS: &[&str] = &["se quiser", "se preferir"];

/// First-person present verbs. The offer is the agent volunteering to act.
const FIRST_PERSON_VERBS: &[&str] = &[
    "posso", "faco", "abro", "rodo", "conserto", "separo", "limpo", "instalo", "reverto", "mostro",
    "troco", "digo", "ajusto", "deixo", "subo", "commito", "mando",
];

/// Exact text that is a stop but never a question. Claude Code writes it itself.
const NO_RESPONSE_REQUESTED: &str = "No response requested.";

/// Prefix of an API failure rendered into the transcript as assistant text.
const API_ERROR_MARKER: &str = "API Error:";

/// Markers on the *user* side that mean the stop was not a human being asked.
///
/// A background task reporting in, a slash command's caveat, or an interrupt.
/// Offering a draft there is offering to answer a machine.
///
/// Measured shares of the 835 stop points: `<task-notification>` 185 (22%),
/// the local-command caveat 58 (7%). The interrupt marker was not observed at a
/// stop point in this corpus and is kept because it is the same class of event.
const NON_HUMAN_USER_MARKERS: &[&str] = &[
    "<task-notification>",
    "Caveat: The messages below were generated by the user while running local commands",
    "[Request interrupted by user",
];

// ---------------------------------------------------------------------------
// Text handling
// ---------------------------------------------------------------------------

/// Lowercase and drop Portuguese diacritics, so the lexicon can be plain ASCII.
fn fold(text: &str) -> String {
    text.chars()
        .flat_map(|c| c.to_lowercase())
        .map(|c| match c {
            'á' | 'à' | 'â' | 'ã' | 'ä' => 'a',
            'é' | 'è' | 'ê' | 'ë' => 'e',
            'í' | 'ì' | 'î' | 'ï' => 'i',
            'ó' | 'ò' | 'ô' | 'õ' | 'ö' => 'o',
            'ú' | 'ù' | 'û' | 'ü' => 'u',
            'ç' => 'c',
            'ñ' => 'n',
            other => other,
        })
        .collect()
}

/// Blocks separated by a blank line, empties dropped.
///
/// A paragraph is the unit the rule reasons in: the last one is where a request
/// lives, and a whole message is too coarse to tell a closing offer from a
/// mention halfway through a report.
pub fn paragraphs(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0usize;
    let bytes = text.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'\n' {
            // A run of whitespace containing a second newline ends the block.
            let mut j = i + 1;
            let mut saw_second_newline = false;
            while j < bytes.len() && (bytes[j] as char).is_whitespace() {
                if bytes[j] == b'\n' {
                    saw_second_newline = true;
                }
                j += 1;
            }
            if saw_second_newline {
                let block = text[start..i].trim();
                if !block.is_empty() {
                    out.push(block);
                }
                start = j;
                i = j;
                continue;
            }
            i = j;
            continue;
        }
        i += 1;
    }
    let block = text[start..].trim();
    if !block.is_empty() {
        out.push(block);
    }
    out
}

fn near_offer(folded: &str, window: usize) -> bool {
    for opener in CONDITIONAL_OPENERS {
        for (at, _) in folded.match_indices(opener) {
            let after_start = at + opener.len();
            let after = &folded[after_start..folded.len().min(after_start + window)];
            if FIRST_PERSON_VERBS.iter().any(|v| after.contains(v)) {
                return true;
            }
            let before_start = at.saturating_sub(window);
            let before = &folded[before_start..at];
            if FIRST_PERSON_VERBS.iter().any(|v| before.contains(v)) {
                return true;
            }
        }
    }
    false
}

// ---------------------------------------------------------------------------
// The rule
// ---------------------------------------------------------------------------

/// Why the rule declined, when it did. Named so a caller can log it instead of
/// reporting a bare `false`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Declined {
    /// The message had no prose at all — `thinking` and `tool_use` only.
    NoText,
    /// Claude Code's own "nothing to answer" text.
    NoResponseRequested,
    /// The assistant text is an API failure.
    ApiError,
    /// The stop was a background task, a local command, or an interrupt.
    NotAHumanStop,
    /// Prose, human, and no request in it.
    NoRequest,
}

/// Which signal fired. Kept for logging and for the fixture tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    /// A `?` in the trailing paragraphs.
    QuestionMark,
    /// A first-person request phrase in the last paragraph.
    Lexicon,
}

impl Signal {
    /// The name this signal goes on the wire under.
    ///
    /// Here and not at the producer: `docs/PROTOCOL.md` says clients must not
    /// re-derive the signal, and a spelling that lived next to the wire type
    /// would be a second name for the rule that fired, free to drift from the
    /// one the rule calls itself.
    pub fn as_wire(self) -> &'static str {
        match self {
            Self::QuestionMark => "question_mark",
            Self::Lexicon => "lexicon",
        }
    }
}

impl AnswerRequestConfig {
    /// Run the rule over the prose of one assistant message.
    ///
    /// `human_stop` is the caller's answer to "did a person get handed the
    /// keyboard here?". Live, the daemon does not know yet — the line that would
    /// say so has not been written — so it passes `true` at the stop point and
    /// lets the next event correct it (see
    /// `violeet_transcript::Telemetry::decide_answer_request`, which holds the
    /// rationale). A caller reading a file that is already complete can answer
    /// it properly, from [`user_line_is_human_stop`] over the following `user`
    /// line; that is what `examples/answer_request_probe.rs` does.
    pub fn evaluate(&self, text: &str, human_stop: bool) -> Result<Signal, Declined> {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return Err(Declined::NoText);
        }
        if trimmed == NO_RESPONSE_REQUESTED {
            return Err(Declined::NoResponseRequested);
        }
        // Bounded prefix: the marker opens the message when it is the message.
        // Searching the whole text would let a *discussion* of an API error
        // suppress a real question.
        let head_end = trimmed
            .char_indices()
            .map(|(i, c)| i + c.len_utf8())
            .take_while(|i| *i <= 200)
            .last()
            .unwrap_or(trimmed.len());
        if trimmed[..head_end].contains(API_ERROR_MARKER) {
            return Err(Declined::ApiError);
        }
        if !human_stop {
            return Err(Declined::NotAHumanStop);
        }

        let paras = paragraphs(trimmed);
        if paras.is_empty() {
            return Err(Declined::NoText);
        }

        let tail = &paras[paras.len().saturating_sub(self.question_mark_paragraphs)..];
        if tail.iter().any(|p| p.contains('?')) {
            return Ok(Signal::QuestionMark);
        }

        let lex_tail = &paras[paras.len().saturating_sub(self.lexicon_paragraphs)..];
        for para in lex_tail {
            let folded = fold(para);
            if LEXICON.iter().any(|needle| folded.contains(needle))
                || near_offer(&folded, self.near_window_chars)
            {
                return Ok(Signal::Lexicon);
            }
        }
        Err(Declined::NoRequest)
    }
}

/// Does this `user` transcript line look like a person typing?
///
/// `false` for the three shapes measured in the corpus: a background task
/// reporting in (a hash followed by `toolu_` ids), a slash command's caveat, and
/// an interrupt. Tool results are not a stop at all and are `false` too.
pub fn user_line_is_human_stop(line: &Value) -> bool {
    let content = line.get("message").and_then(|m| m.get("content"));
    if line.get("sourceToolUseID").is_some() {
        return false;
    }
    let mut text = String::new();
    match content {
        Some(Value::String(s)) => text.push_str(s),
        Some(Value::Array(blocks)) => {
            for block in blocks {
                if block.get("type").and_then(Value::as_str) == Some("tool_result") {
                    return false;
                }
                if let Some(t) = block.get("text").and_then(Value::as_str) {
                    text.push_str(t);
                    text.push('\n');
                }
            }
        }
        _ => {}
    }
    // A tool-use id plus an opaque hash. Scanned as a *run* rather than as a
    // whitespace-delimited token, because the measured shape wraps both in XML
    // tags with no spaces around them.
    if text.contains("toolu_") && has_hex_run(&text, 8) {
        return false;
    }
    !NON_HUMAN_USER_MARKERS
        .iter()
        .any(|marker| text.contains(marker))
}

fn has_hex_run(text: &str, min_len: usize) -> bool {
    let mut run = 0usize;
    for c in text.chars() {
        if c.is_ascii_hexdigit() {
            run += 1;
            if run >= min_len {
                return true;
            }
        } else {
            run = 0;
        }
    }
    false
}

// ---------------------------------------------------------------------------
// The payload
// ---------------------------------------------------------------------------

/// One message in the excerpt sent to a provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextMessage {
    /// `user` or `assistant`.
    pub role: &'static str,
    pub text: String,
}

/// Everything that leaves the machine, assembled once.
///
/// The panel shows this rendered by [`AnswerRequest::render_payload`], which is
/// the *same* string the provider receives — not a summary of it. A summary
/// would make the disclosure unfalsifiable, which defeats its only purpose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AnswerRequest {
    /// The assistant message that asked, whole.
    pub question: String,
    /// Older turns, oldest first.
    pub context: Vec<ContextMessage>,
    pub cwd: Option<String>,
    /// The excerpt was cut to fit the budget. The panel says so.
    pub context_truncated: bool,
}

impl AnswerRequestConfig {
    /// Build the payload from the conversation, newest last.
    ///
    /// # The cut, stated once
    ///
    /// Walk backwards from the newest message, taking whole messages, and stop
    /// at the first one that would push the total over
    /// [`AnswerRequestConfig::context_char_budget`] or past
    /// [`AnswerRequestConfig::context_max_messages`]. Never split a message: a
    /// half sentence read as a whole one is worse than a shorter excerpt. The
    /// asking message is always included in full, even when it alone exceeds the
    /// budget — without it there is nothing to answer.
    pub fn build_request(
        &self,
        question: &str,
        earlier: &[ContextMessage],
        cwd: Option<String>,
    ) -> AnswerRequest {
        let mut budget = self
            .context_char_budget
            .saturating_sub(question.chars().count());
        let mut taken: Vec<ContextMessage> = Vec::new();
        let mut truncated = false;
        for message in earlier.iter().rev() {
            if taken.len() >= self.context_max_messages {
                truncated = true;
                break;
            }
            let cost = message.text.chars().count();
            if cost > budget {
                truncated = true;
                break;
            }
            budget -= cost;
            taken.push(message.clone());
        }
        if taken.len() < earlier.len() {
            truncated = true;
        }
        taken.reverse();
        AnswerRequest {
            question: question.to_string(),
            context: taken,
            cwd,
            context_truncated: truncated,
        }
    }
}

impl AnswerRequest {
    /// The exact bytes a provider is asked to complete.
    ///
    /// One function, so "what the panel discloses" and "what was sent" cannot
    /// drift apart.
    pub fn render_payload(&self) -> String {
        let mut out = String::new();
        out.push_str(
            "Rascunhe uma resposta curta e direta, em primeira pessoa, para a \
             pergunta do agente abaixo. Responda apenas com o texto da resposta.\n\n",
        );
        if let Some(cwd) = &self.cwd {
            out.push_str("## cwd\n");
            out.push_str(cwd);
            out.push_str("\n\n");
        }
        if !self.context.is_empty() {
            out.push_str("## contexto recente");
            if self.context_truncated {
                out.push_str(" (recortado)");
            }
            out.push('\n');
            for message in &self.context {
                out.push_str("### ");
                out.push_str(message.role);
                out.push('\n');
                out.push_str(message.text.trim());
                out.push_str("\n\n");
            }
        }
        out.push_str("## pergunta do agente\n");
        out.push_str(self.question.trim());
        out.push('\n');
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paragraphs_split_on_blank_lines() {
        assert_eq!(paragraphs("um\n\ndois"), vec!["um", "dois"]);
        assert_eq!(paragraphs("um\ndois"), vec!["um\ndois"]);
        assert_eq!(paragraphs("\n\n  \n\num\n\n\n"), vec!["um"]);
        assert!(paragraphs("   ").is_empty());
    }

    #[test]
    fn folding_removes_portuguese_diacritics() {
        assert_eq!(fold("Você PREFERE, é só dizer"), "voce prefere, e so dizer");
    }

    #[test]
    fn explicit_question_fires() {
        assert_eq!(
            ANSWER_REQUEST.evaluate("Achei dois caminhos.\n\nSigo pelo primeiro?", true),
            Ok(Signal::QuestionMark)
        );
    }

    #[test]
    fn question_two_paragraphs_back_still_fires() {
        let text = "Vale seguir por aqui?\n\nDeixei o log em /tmp/run.log.";
        assert_eq!(
            ANSWER_REQUEST.evaluate(text, true),
            Ok(Signal::QuestionMark)
        );
    }

    #[test]
    fn question_three_paragraphs_back_does_not() {
        let text = "Vale seguir por aqui?\n\num\n\ndois";
        assert_eq!(
            ANSWER_REQUEST.evaluate(text, true),
            Err(Declined::NoRequest)
        );
    }

    #[test]
    fn soft_invitation_fires_on_the_lexicon() {
        let text =
            "Deixei os tres arquivos no lugar.\n\nQuer que eu rode a suite antes de commitar.";
        assert_eq!(ANSWER_REQUEST.evaluate(text, true), Ok(Signal::Lexicon));
    }

    #[test]
    fn conditional_offer_needs_a_first_person_verb_nearby() {
        assert_eq!(
            ANSWER_REQUEST.evaluate("Pronto.\n\nSe quiser, reverto o commit.", true),
            Ok(Signal::Lexicon)
        );
        assert_eq!(
            ANSWER_REQUEST.evaluate("Pronto.\n\nReverto o commit se preferir.", true),
            Ok(Signal::Lexicon)
        );
        // The phrase alone, describing the user's options rather than offering
        // to act, does not fire.
        assert_eq!(
            ANSWER_REQUEST.evaluate("Pronto.\n\nO time usa a flag se quiser o modo novo, e o default segue o mesmo de antes do patch de ontem.", true),
            Err(Declined::NoRequest)
        );
    }

    #[test]
    fn lexicon_scope_is_the_last_paragraph_only() {
        // This is the parameter that took the false-positive rate from 10% to
        // 3%: a report that mentions "prefere" mid-way and then closes with a
        // plain statement is not a request.
        let text =
            "Medi as duas rotas e o time prefere a segunda.\n\nEstá tudo commitado na branch.";
        assert_eq!(
            ANSWER_REQUEST.evaluate(text, true),
            Err(Declined::NoRequest)
        );
    }

    #[test]
    fn closed_report_without_a_request_stays_quiet() {
        let text =
            "Rodei a suite: 41 verdes, 0 vermelhos.\n\nO patch está em feat/x e o CI passou.";
        assert_eq!(
            ANSWER_REQUEST.evaluate(text, true),
            Err(Declined::NoRequest)
        );
    }

    #[test]
    fn guards_win_over_the_signal() {
        assert_eq!(
            ANSWER_REQUEST.evaluate("No response requested.", true),
            Err(Declined::NoResponseRequested)
        );
        assert_eq!(
            ANSWER_REQUEST.evaluate(
                "API Error: 529 overloaded. Quer que eu tente de novo?",
                true
            ),
            Err(Declined::ApiError)
        );
        assert_eq!(
            ANSWER_REQUEST.evaluate("Sigo pelo primeiro?", false),
            Err(Declined::NotAHumanStop)
        );
        assert_eq!(ANSWER_REQUEST.evaluate("   ", true), Err(Declined::NoText));
    }

    #[test]
    fn api_error_deep_in_the_text_does_not_suppress() {
        let head = "a".repeat(400);
        let text = format!("{head}\n\nO log diz API Error: 500. Tento de novo?");
        assert_eq!(
            ANSWER_REQUEST.evaluate(&text, true),
            Ok(Signal::QuestionMark)
        );
    }

    #[test]
    fn background_notification_is_not_a_human_stop() {
        let line = serde_json::json!({
            "type": "user",
            "message": { "content": [
                { "type": "text", "text": "a1b2c3d4e5f6 toolu_01ABCdefGHI finished" }
            ]}
        });
        assert!(!user_line_is_human_stop(&line));
    }

    #[test]
    fn local_command_caveat_and_interrupt_are_not_human_stops() {
        for text in [
            "Caveat: The messages below were generated by the user while running local commands",
            "[Request interrupted by user]",
        ] {
            let line = serde_json::json!({
                "type": "user", "message": { "content": text }
            });
            assert!(!user_line_is_human_stop(&line), "{text}");
        }
    }

    #[test]
    fn tool_result_is_not_a_human_stop() {
        let line = serde_json::json!({
            "type": "user",
            "message": { "content": [{ "type": "tool_result", "tool_use_id": "toolu_1" }] }
        });
        assert!(!user_line_is_human_stop(&line));
        let flat = serde_json::json!({ "type": "user", "sourceToolUseID": "toolu_1" });
        assert!(!user_line_is_human_stop(&flat));
    }

    #[test]
    fn a_person_typing_is_a_human_stop() {
        let line = serde_json::json!({
            "type": "user", "message": { "content": "sim, vai pelo primeiro" }
        });
        assert!(user_line_is_human_stop(&line));
    }

    // -- the cut ----------------------------------------------------------

    fn msg(role: &'static str, n: usize) -> ContextMessage {
        ContextMessage {
            role,
            text: "x".repeat(n),
        }
    }

    #[test]
    fn the_cut_drops_oldest_first_and_never_splits() {
        let earlier = vec![msg("user", 5000), msg("assistant", 900), msg("user", 100)];
        let built = ANSWER_REQUEST.build_request("q".repeat(50).as_str(), &earlier, None);
        // 6000 - 50 leaves 5950: the two newest fit, the 5000 does not.
        assert_eq!(built.context.len(), 2);
        assert_eq!(built.context[0].text.chars().count(), 900);
        assert_eq!(built.context[1].text.chars().count(), 100);
        assert!(built.context_truncated);
        // Nothing was sliced.
        assert!(built.context.iter().all(|m| m.text.len() % 100 == 0));
    }

    #[test]
    fn the_question_survives_a_budget_it_alone_exceeds() {
        let question = "q".repeat(ANSWER_REQUEST.context_char_budget + 500);
        let built = ANSWER_REQUEST.build_request(&question, &[msg("user", 10)], None);
        assert_eq!(built.question.chars().count(), question.chars().count());
        assert!(built.context.is_empty());
        assert!(built.context_truncated);
    }

    #[test]
    fn the_cut_caps_the_message_count() {
        let earlier: Vec<_> = (0..30).map(|_| msg("user", 10)).collect();
        let built = ANSWER_REQUEST.build_request("q", &earlier, None);
        assert_eq!(built.context.len(), ANSWER_REQUEST.context_max_messages);
        assert!(built.context_truncated);
    }

    #[test]
    fn a_short_conversation_is_not_marked_truncated() {
        let earlier = vec![msg("user", 10), msg("assistant", 20)];
        let built = ANSWER_REQUEST.build_request("q", &earlier, None);
        assert_eq!(built.context.len(), 2);
        assert!(!built.context_truncated);
    }

    #[test]
    fn the_rendered_payload_is_what_it_discloses() {
        let built = ANSWER_REQUEST.build_request(
            "Sigo pelo primeiro?",
            &[ContextMessage {
                role: "user",
                text: "compara as duas rotas".into(),
            }],
            Some("/Users/you/www/app".into()),
        );
        let rendered = built.render_payload();
        assert!(rendered.contains("/Users/you/www/app"));
        assert!(rendered.contains("compara as duas rotas"));
        assert!(rendered.ends_with("Sigo pelo primeiro?\n"));
        // Rendering twice is byte-identical, so the panel and the request
        // cannot show different things.
        assert_eq!(rendered, built.render_payload());
    }
}
