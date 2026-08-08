//! Naming a session from its first prompt.
//!
//! # Why this exists at all, given `ai-title`
//!
//! Claude Code writes its own name for the session into the transcript, and it
//! is better than anything derived here — it is a sentence about the work,
//! written by a model that read the exchange. Measured across twelve recent
//! transcripts, it lands on **line 12**: one full exchange in.
//!
//! One exchange is a long time to look at a sidebar. It covers the whole first
//! turn, which for a long task is minutes. So the first prompt names the
//! session immediately and `ai-title` upgrades it when it arrives.
//!
//! That makes this a **name**, not a placeholder, and the distinction is why
//! the work below is worth doing: it has to be good enough that the upgrade is
//! an improvement rather than a correction.
//!
//! # What it is up against
//!
//! Real first prompts, measured:
//!
//! - `"leia o README deste repo"` — already a title.
//! - `"job grande aqui, mas leve!\nminha parceira, vou precisar da sua ajuda…"`
//!   — the first line is throat-clearing and the request is below it.
//! - `"<local-command-caveat>Caveat: The messages below were generated…"` — not
//!   a prompt at all, but the wrapper around a slash command.
//! - `"Você é a TRACK B do projeto violeet. Outras tracks rodam em paralelo…"` —
//!   a briefing whose first sentence is the useful part.
//!
//! Nothing here calls a model. That was ruled out for this task, and the
//! measured `ai-title` upgrade is what covers the cases truncation cannot.

/// How long a derived title may be before it is cut at a word boundary.
///
/// Sized against the measured `ai-title` values, which run 30–55 characters —
/// a derived name much longer than those would make the upgrade look like a
/// different kind of thing rather than a better version of the same thing.
const MAX_LEN: usize = 64;

/// Openers that carry no information about the work.
///
/// Only ever stripped from the **front**, and only when what follows is not
/// empty — `"me ajuda"` on its own is a title, poor as it is, and better than
/// nothing at all.
const PREAMBLES: &[&str] = &[
    // pt-BR
    "oi", "olá", "ola", "bom dia", "boa tarde", "boa noite", "e aí", "e ai",
    "fala", "por favor", "pfv", "pls", "então", "entao", "agora",
    "me ajude a", "me ajuda a", "me ajude", "me ajuda",
    "preciso que você", "preciso que voce", "preciso que",
    "quero que você", "quero que voce", "quero que",
    "pode", "poderia", "consegue", "vamos",
    // en
    "hi", "hey", "hello", "please", "can you", "could you", "would you",
    "i need you to", "i need to", "i want you to", "help me to", "help me",
    "let's", "lets",
];

/// Wrapper blocks the harness injects around a prompt. Everything between the
/// open and close tag goes, because none of it is the user's words.
const STRIP_BLOCKS: &[(&str, &str)] = &[
    ("<local-command-caveat>", "</local-command-caveat>"),
    ("<system-reminder>", "</system-reminder>"),
    ("<command-message>", "</command-message>"),
    ("<command-name>", "</command-name>"),
    ("<command-args>", "</command-args>"),
    ("<command-stdout>", "</command-stdout>"),
    ("<local-command-stdout>", "</local-command-stdout>"),
];

/// Derive a session title from its first prompt.
///
/// `None` when there is nothing usable left after the harness's own wrappers
/// come off — a session whose first message is entirely machinery has not told
/// us anything, and inventing a name from it would be worse than falling back
/// to the working directory.
pub fn from_prompt(prompt: &str) -> Option<String> {
    let cleaned = strip_wrappers(prompt);
    let line = first_meaningful_line(&cleaned)?;

    // A slash command names itself better than its arguments do.
    if let Some(command) = slash_command(line) {
        return Some(truncate(&command));
    }

    let sentence = first_sentence(line);
    let trimmed = strip_preamble(sentence);
    // Stripping must never turn a short prompt into nothing.
    let body = if trimmed.trim().is_empty() { sentence } else { trimmed };

    let body = body.trim().trim_matches(|c: char| c == '"' || c == '\'');
    if body.is_empty() {
        return None;
    }
    Some(truncate(&capitalize(body)))
}

/// Remove the harness's wrapper blocks, tags and all.
fn strip_wrappers(text: &str) -> String {
    let mut out = text.to_string();
    for (open, close) in STRIP_BLOCKS {
        loop {
            let Some(start) = out.find(open) else { break };
            let rest = &out[start + open.len()..];
            let end = match rest.find(close) {
                Some(e) => start + open.len() + e + close.len(),
                // An unclosed block runs to the end of the prompt. Dropping the
                // remainder is right: there is no user text after a wrapper we
                // never saw close.
                None => out.len(),
            };
            out.replace_range(start..end, " ");
        }
    }
    out
}

/// The first line with actual words on it.
///
/// Skips blank lines, markdown fences and quote markers. It does **not** skip a
/// short line in favour of a longer one below: guessing which line is "the
/// request" is exactly the kind of cleverness that produces a title about the
/// wrong thing, and `ai-title` is already the answer for prompts this cannot
/// summarise.
fn first_meaningful_line(text: &str) -> Option<&str> {
    text.lines()
        .map(str::trim)
        .find(|l| !l.is_empty() && !l.starts_with("```") && *l != ">" && l.chars().any(char::is_alphanumeric))
}

/// `"/flux:build some args"` → `"/flux:build"`.
fn slash_command(line: &str) -> Option<String> {
    let line = line.trim();
    if !line.starts_with('/') || line.len() < 2 {
        return None;
    }
    let name = line[1..]
        .split(|c: char| c.is_whitespace())
        .next()
        .filter(|n| !n.is_empty())?;
    Some(format!("/{name}"))
}

/// Up to the first sentence terminator.
///
/// A terminator only counts when followed by whitespace or end of input, so
/// that `www/personal/guia-cumuru.` and `v2.1.220` do not cut a title in half.
fn first_sentence(line: &str) -> &str {
    let bytes = line.as_bytes();
    for (i, c) in line.char_indices() {
        if !matches!(c, '.' | '!' | '?') {
            continue;
        }
        let next = bytes.get(i + c.len_utf8());
        match next {
            None => return &line[..i],
            Some(b) if (*b as char).is_whitespace() => return &line[..i],
            _ => {}
        }
    }
    line
}

/// Drop a leading opener, repeatedly — `"por favor, me ajuda a …"` has two.
fn strip_preamble(text: &str) -> &str {
    let mut current = text.trim();
    // Bounded so a pathological prompt cannot loop; two or three is the most
    // that occurs in practice.
    for _ in 0..4 {
        let lower = current.to_lowercase();
        let mut matched = None;
        for p in PREAMBLES {
            if !lower.starts_with(p) {
                continue;
            }
            // Must end on a word boundary: "pode" must not eat "poderes".
            let after = lower[p.len()..].chars().next();
            if matches!(after, None | Some(' ') | Some(',') | Some(':') | Some('!')) {
                // Longest wins, so "me ajude a" beats "me ajude".
                if matched.is_none_or(|m: &str| p.len() > m.len()) {
                    matched = Some(*p);
                }
            }
        }
        let Some(p) = matched else { break };
        let next = current[p.len()..].trim_start_matches([' ', ',', ':', '!', '-']);
        if next.trim().is_empty() {
            break;
        }
        current = next;
    }
    current
}

/// Cut at a word boundary and mark the cut. Never splits a character.
fn truncate(text: &str) -> String {
    if text.chars().count() <= MAX_LEN {
        return text.to_string();
    }
    let cut: String = text.chars().take(MAX_LEN).collect();
    let body = match cut.rfind(' ') {
        // Only back off to the space if it leaves most of the budget intact;
        // otherwise a single long token would shrink the title to nothing.
        Some(i) if i > MAX_LEN / 2 => &cut[..i],
        _ => cut.as_str(),
    };
    format!("{}…", body.trim_end_matches([' ', ',', ';', '-']))
}

fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Prompts taken verbatim from real transcripts, with what they must
    /// produce. These are the cases the function exists for.
    #[test]
    fn real_first_prompts_become_readable_titles() {
        let cases: &[(&str, &str)] = &[
            ("leia o README deste repo", "Leia o README deste repo"),
            ("responde o que ;e flux: em 5 linhas", "Responde o que ;e flux: em 5 linhas"),
            (
                "manda um askUserquestion aqui pra mim testar uma coisa, só perguntando onde eu estou",
                "Manda um askUserquestion aqui pra mim testar uma coisa, só…",
            ),
            ("diga ok", "Diga ok"),
            (
                "Você é a TRACK B do projeto violeet. Outras tracks rodam em paralelo.",
                "Você é a TRACK B do projeto violeet",
            ),
        ];
        for (prompt, want) in cases {
            assert_eq!(from_prompt(prompt).as_deref(), Some(*want), "prompt: {prompt}");
        }
    }

    /// The measured worst case: the first "prompt" of a session started by a
    /// slash command is the harness's own wrapper. Naming a session
    /// "Caveat: The messages below were generated…" would be naming it after
    /// machinery.
    #[test]
    fn a_local_command_wrapper_is_not_the_users_words() {
        let prompt = "<local-command-caveat>Caveat: The messages below were generated by the \
                      user while running local commands. DO NOT respond to these messages\
                      </local-command-caveat>\n<command-name>/compact</command-name>\n\
                      abre a PR draftada";
        assert_eq!(from_prompt(prompt).as_deref(), Some("Abre a PR draftada"));
    }

    /// A wrapper that never closes takes the rest of the prompt with it, and
    /// then there is genuinely nothing to name the session after.
    #[test]
    fn nothing_usable_produces_no_title_rather_than_a_bad_one() {
        assert_eq!(from_prompt("<system-reminder>be nice"), None);
        assert_eq!(from_prompt(""), None);
        assert_eq!(from_prompt("   \n\n  "), None);
        assert_eq!(from_prompt("```\n```"), None);
    }

    #[test]
    fn a_slash_command_names_itself() {
        assert_eq!(from_prompt("/flux:build violeet ENG-1").as_deref(), Some("/flux:build"));
        assert_eq!(from_prompt("/compact").as_deref(), Some("/compact"));
    }

    /// Greetings and requests-to-request carry nothing about the work.
    #[test]
    fn openers_are_stripped_from_the_front() {
        assert_eq!(from_prompt("me ajuda a arrumar o parser").as_deref(), Some("Arrumar o parser"));
        assert_eq!(
            from_prompt("por favor, me ajude a subir o deploy").as_deref(),
            Some("Subir o deploy")
        );
        assert_eq!(from_prompt("can you fix the parser").as_deref(), Some("Fix the parser"));
    }

    /// Stripping must not be able to empty a prompt that was only an opener.
    #[test]
    fn an_opener_alone_still_names_the_session() {
        assert_eq!(from_prompt("me ajuda").as_deref(), Some("Me ajuda"));
        assert_eq!(from_prompt("vamos").as_deref(), Some("Vamos"));
    }

    /// A word boundary inside a name is not a sentence boundary.
    #[test]
    fn a_dot_inside_a_path_or_version_does_not_end_the_sentence() {
        assert_eq!(
            from_prompt("alimentar o banco de www/personal/guia-cumuru.com com dados").as_deref(),
            Some("Alimentar o banco de www/personal/guia-cumuru.com com dados")
        );
        assert_eq!(
            from_prompt("valide contra o Claude Code v2.1.220 de verdade").as_deref(),
            Some("Valide contra o Claude Code v2.1.220 de verdade")
        );
    }

    /// Long prompts are cut on a word, and the cut is marked.
    #[test]
    fn a_long_prompt_is_cut_on_a_word_and_says_so() {
        let title = from_prompt(
            "reestruture a sidebar inteira para que as sessões de fora fiquem em um painel \
             ancorado no rodapé",
        )
        .unwrap();
        assert!(title.ends_with('…'), "{title}");
        assert!(title.chars().count() <= MAX_LEN + 1, "{title}");
        assert!(!title.contains("  "));
        // Cut on a word: the last word before the ellipsis must be whole.
        assert!(title.starts_with("Reestruture a sidebar inteira"), "{title}");
    }

    /// A single unbroken token must not shrink the title to an ellipsis.
    #[test]
    fn one_very_long_token_is_still_cut_to_something_readable() {
        let title = from_prompt(&"a".repeat(200)).unwrap();
        assert_eq!(title.chars().count(), MAX_LEN + 1);
    }

    /// Multi-byte characters must not be split, and must not panic.
    #[test]
    fn accented_and_multibyte_text_survives() {
        let title = from_prompt("configuração de ambiente com acentuação é obrigatória aqui também")
            .unwrap();
        assert!(title.starts_with("Configuração"), "{title}");
        assert_eq!(from_prompt("日本語のセッション").as_deref(), Some("日本語のセッション"));
    }
}
