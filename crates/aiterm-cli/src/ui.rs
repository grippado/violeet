//! Terminal output: colour, the diff, and asking a question.
//!
//! Colour is suppressed when stdout is not a terminal, when `NO_COLOR` is set,
//! or when `TERM=dumb`. A CLI whose output is piped into a file and comes back
//! full of escape sequences is a CLI that cannot be pasted into a bug report.

use std::io::{self, IsTerminal, Write};

pub fn colour_enabled() -> bool {
    if std::env::var_os("NO_COLOR").is_some() {
        return false;
    }
    if std::env::var("TERM").map(|t| t == "dumb").unwrap_or(false) {
        return false;
    }
    io::stdout().is_terminal()
}

pub struct Style {
    enabled: bool,
}

impl Style {
    pub fn detect() -> Self {
        Self {
            enabled: colour_enabled(),
        }
    }

    fn wrap(&self, code: &str, text: &str) -> String {
        if self.enabled {
            format!("\x1b[{code}m{text}\x1b[0m")
        } else {
            text.to_string()
        }
    }

    pub fn green(&self, t: &str) -> String {
        self.wrap("32", t)
    }
    pub fn red(&self, t: &str) -> String {
        self.wrap("31", t)
    }
    pub fn yellow(&self, t: &str) -> String {
        self.wrap("33", t)
    }
    pub fn dim(&self, t: &str) -> String {
        self.wrap("2", t)
    }
    pub fn bold(&self, t: &str) -> String {
        self.wrap("1", t)
    }
}

/// A line-oriented diff.
///
/// Longest common subsequence over lines, which for a settings file — where the
/// change is a handful of inserted blocks — produces exactly the "these lines
/// are new" reading a human wants. Written here rather than pulled in because
/// the whole algorithm is thirty lines and the alternative is a dependency tree
/// for a cosmetic feature.
pub fn diff(before: &str, after: &str, style: &Style) -> String {
    let a: Vec<&str> = before.lines().collect();
    let b: Vec<&str> = after.lines().collect();

    // lcs[i][j] = length of the longest common subsequence of a[i..] and b[j..]
    let mut lcs = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for i in (0..a.len()).rev() {
        for j in (0..b.len()).rev() {
            lcs[i][j] = if a[i] == b[j] {
                lcs[i + 1][j + 1] + 1
            } else {
                lcs[i + 1][j].max(lcs[i][j + 1])
            };
        }
    }

    let mut out: Vec<String> = Vec::new();
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i] == b[j] {
            out.push(format!("  {}", a[i]));
            i += 1;
            j += 1;
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            out.push(style.red(&format!("- {}", a[i])));
            i += 1;
        } else {
            out.push(style.green(&format!("+ {}", b[j])));
            j += 1;
        }
    }
    while i < a.len() {
        out.push(style.red(&format!("- {}", a[i])));
        i += 1;
    }
    while j < b.len() {
        out.push(style.green(&format!("+ {}", b[j])));
        j += 1;
    }

    collapse_unchanged(out, 3)
}

/// Keep `context` unchanged lines around each change, elide the rest.
///
/// A settings file is mostly unrelated to us; printing all of it buries the
/// four lines the user is being asked to approve.
fn collapse_unchanged(lines: Vec<String>, context: usize) -> String {
    let changed: Vec<bool> = lines
        .iter()
        .map(|l| {
            let bare = strip_ansi(l);
            bare.starts_with('+') || bare.starts_with('-')
        })
        .collect();

    let keep: Vec<bool> = (0..lines.len())
        .map(|i| {
            let lo = i.saturating_sub(context);
            let hi = (i + context + 1).min(lines.len());
            changed[lo..hi].iter().any(|&c| c)
        })
        .collect();

    let mut out = String::new();
    let mut eliding = false;
    for (i, line) in lines.iter().enumerate() {
        if keep[i] {
            eliding = false;
            out.push_str(line);
            out.push('\n');
        } else if !eliding {
            eliding = true;
            out.push_str("  …\n");
        }
    }
    out
}

fn strip_ansi(s: &str) -> String {
    let mut out = String::new();
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            for c in chars.by_ref() {
                if c == 'm' {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Ask a yes/no question. Anything but an explicit yes is no.
///
/// Defaulting to no matters: this gates writing to a file we do not own, and a
/// user who hits return by reflex should get the outcome that changes nothing.
pub fn confirm(question: &str) -> io::Result<bool> {
    if !io::stdin().is_terminal() {
        // Non-interactive and no --yes: refuse rather than assume. A script
        // that wanted this to proceed can say so.
        println!("{question} [y/N] (not a terminal; assuming no — pass --yes to proceed)");
        return Ok(false);
    }
    print!("{question} [y/N] ");
    io::stdout().flush()?;

    let mut answer = String::new();
    io::stdin().read_line(&mut answer)?;
    Ok(matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes"))
}

/// Ask for one of several named choices. Returns the index, or `None` on abort.
pub fn choose(prompt: &str, options: &[(&str, &str)]) -> io::Result<Option<usize>> {
    println!("\n{prompt}");
    for (i, (label, description)) in options.iter().enumerate() {
        println!("  {}) {label} — {description}", i + 1);
    }

    if !io::stdin().is_terminal() {
        println!("\nNot a terminal, so there is nobody to ask. Aborting.");
        return Ok(None);
    }

    loop {
        print!("Choice [1-{}]: ", options.len());
        io::stdout().flush()?;
        let mut answer = String::new();
        if io::stdin().read_line(&mut answer)? == 0 {
            return Ok(None);
        }
        match answer.trim().parse::<usize>() {
            Ok(n) if n >= 1 && n <= options.len() => return Ok(Some(n - 1)),
            _ => println!("Please answer with a number between 1 and {}.", options.len()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plain() -> Style {
        Style { enabled: false }
    }

    #[test]
    fn an_insertion_shows_as_added_lines_only() {
        let d = diff("a\nb\nc\n", "a\nb\nNEW\nc\n", &plain());
        assert!(d.contains("+ NEW"));
        assert!(!d.contains("- "), "nothing was deleted, so nothing may read as deleted");
    }

    #[test]
    fn identical_input_produces_no_change_markers() {
        let d = diff("a\nb\n", "a\nb\n", &plain());
        assert!(!d.contains("+ ") && !d.contains("- "));
    }

    /// Long unchanged stretches are elided, or the four lines being approved are
    /// lost in three hundred lines of the user's own settings.
    #[test]
    fn distant_unchanged_lines_are_elided() {
        let before: String = (0..100).map(|i| format!("line {i}\n")).collect();
        let after = before.replace("line 50\n", "line 50\nINSERTED\n");
        let d = diff(&before, &after, &plain());

        assert!(d.contains("+ INSERTED"));
        assert!(d.contains('…'));
        assert!(d.lines().count() < 20);
    }

    #[test]
    fn colour_is_stripped_cleanly_for_the_change_detector() {
        let style = Style { enabled: true };
        let coloured = style.green("+ hello");
        assert_ne!(coloured, "+ hello");
        assert_eq!(strip_ansi(&coloured), "+ hello");
    }
}
