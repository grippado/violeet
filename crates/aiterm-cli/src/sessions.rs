//! `aiterm sessions` — what the daemon currently thinks is running.
//!
//! # Why this exists
//!
//! Every other view of a session is inside the app. When a card shows a number
//! that looks wrong, the question "is the app rendering it wrong or is the
//! daemon sending it wrong" has been, until now, unanswerable without attaching
//! a socket client by hand. This is that client, with a table on the end of it.
//!
//! It is a **debugging** tool and reads like one: it prints what the daemon
//! said, not a friendlier version of it. An unknown value is `—` here for the
//! same reason it is on a card — a dash is a fact and a zero is a claim.
//!
//! # How it talks to the daemon
//!
//! One connection, one `request_snapshot`, read until the daemon goes quiet,
//! fold the messages, print, disconnect. The snapshot is "just ordinary
//! messages" by protocol design, so folding them is the same operation the app
//! performs — which is what makes agreement between this and the sidebar
//! meaningful rather than coincidental.
//!
//! The messages are parsed as plain JSON rather than through `aiterm-proto`'s
//! types, which are `Serialize` only. Deriving `Deserialize` on them for a
//! debug command would mean the daemon's own outbound types grow a
//! reverse direction nothing else needs.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::Value;

use crate::probe;
use crate::ui::Style;

/// How long to wait for the snapshot to stop arriving.
///
/// The protocol has no end-of-snapshot marker — deliberately, since the
/// snapshot is indistinguishable from live traffic. Silence is the only signal,
/// and 400 ms is far longer than a local socket needs to deliver a few dozen
/// lines.
const QUIET: Duration = Duration::from_millis(400);

#[derive(Debug, Default)]
struct Row {
    title: Option<String>,
    title_source: Option<String>,
    cwd: Option<String>,
    state: Option<String>,
    tab_id: Option<String>,
    origin_app: Option<String>,
    context_used: Option<u64>,
    context_size: Option<u64>,
    hitl_tool: Option<String>,
}

pub fn run(style: &Style) -> Result<(), String> {
    let path = probe::default_socket_path().ok_or("cannot tell where $HOME is")?;
    let rows = fetch(&path)?;

    if rows.is_empty() {
        println!("{} no sessions", style.dim("·"));
        return Ok(());
    }

    println!(
        "{:<10} {:<34} {:<12} {:<11} {}",
        style.dim("SESSION"),
        style.dim("TITLE"),
        style.dim("STATE"),
        style.dim("CONTEXT"),
        style.dim("WHERE")
    );

    for (id, row) in &rows {
        let state = match &row.hitl_tool {
            // The pending request outranks the reported state, exactly as the
            // card does it: when the two disagree it is because the HITL landed
            // first, and the blocked session is the one that must be right.
            Some(tool) => format!("waiting: {tool}"),
            None => row.state.clone().unwrap_or_else(|| "—".into()),
        };
        println!(
            "{:<10} {:<34} {:<12} {:<11} {}",
            &id[..id.len().min(8)],
            truncate(&title_of(row), 34),
            truncate(&state, 12),
            context_of(row),
            where_of(row),
        );
    }
    Ok(())
}

fn title_of(row: &Row) -> String {
    match (&row.title, &row.title_source) {
        (Some(t), Some(s)) => format!("{t} ({s})"),
        (Some(t), None) => t.clone(),
        // No title at all: the app falls back to the working directory's last
        // component, and saying so is more useful than an empty column.
        (None, _) => match &row.cwd {
            Some(cwd) => format!("{} (cwd)", leaf(cwd)),
            None => "—".into(),
        },
    }
}

/// `28% 56k/200k`, or just the count when the window size is unknown, or `—`.
/// Never a percentage computed from one measured number and one guess.
fn context_of(row: &Row) -> String {
    match (row.context_used, row.context_size) {
        (Some(used), Some(size)) if size > 0 => {
            format!("{}% {}", used * 100 / size, short(used))
        }
        (Some(used), _) => short(used),
        _ => "—".into(),
    }
}

fn where_of(row: &Row) -> String {
    match (&row.tab_id, &row.origin_app) {
        (Some(tab), _) => format!("tab {}", &tab[..tab.len().min(8)]),
        (None, Some(app)) => app.clone(),
        (None, None) => "outside".into(),
    }
}

fn short(n: u64) -> String {
    match n {
        n if n >= 1_000_000 => format!("{:.1}M", n as f64 / 1e6),
        n if n >= 1_000 => format!("{:.0}k", n as f64 / 1e3),
        n => n.to_string(),
    }
}

fn leaf(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    s.chars().take(max.saturating_sub(1)).collect::<String>() + "…"
}

/// Connect, ask for the snapshot, fold what comes back.
fn fetch(path: &std::path::Path) -> Result<BTreeMap<String, Row>, String> {
    let stream = UnixStream::connect(path)
        .map_err(|e| format!("daemon not reachable at {}: {e}", path.display()))?;
    stream
        .set_read_timeout(Some(QUIET))
        .map_err(|e| format!("cannot set a read timeout: {e}"))?;

    let mut writer = stream
        .try_clone()
        .map_err(|e| format!("cannot clone the socket: {e}"))?;
    writeln!(
        writer,
        r#"{{"type":"request_snapshot","v":1,"ts":"{}"}}"#,
        aiterm_proto::wire::timestamp(chrono_now())
    )
    .map_err(|e| format!("cannot ask for a snapshot: {e}"))?;
    writer.flush().ok();

    let mut rows: BTreeMap<String, Row> = BTreeMap::new();
    for line in BufReader::new(stream).lines() {
        // A timeout is how the snapshot ends. Any other error ends it too:
        // there is nothing to recover, and a partial table is still useful.
        let Ok(line) = line else { break };
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        fold(&mut rows, &value);
    }
    Ok(rows)
}

fn fold(rows: &mut BTreeMap<String, Row>, msg: &Value) {
    let Some(session_id) = msg.get("session_id").and_then(Value::as_str) else {
        return;
    };
    let row = rows.entry(session_id.to_string()).or_default();

    match msg.get("type").and_then(Value::as_str) {
        Some("session_registered") => {
            row.title = str_of(msg, "title");
            row.cwd = str_of(msg, "cwd");
            row.tab_id = str_of(msg, "tab_id");
        }
        Some("session_updated") => {
            // Sparse: only a key that is present says anything, and an explicit
            // null clears. Absent leaves what we had.
            patch_str(&mut row.title, msg, "title");
            patch_str(&mut row.title_source, msg, "title_source");
            patch_str(&mut row.cwd, msg, "cwd");
            patch_str(&mut row.tab_id, msg, "tab_id");
            patch_str(&mut row.origin_app, msg, "origin_app");
            patch_u64(&mut row.context_used, msg, "context_window_used_tokens");
            patch_u64(&mut row.context_size, msg, "context_window_size_tokens");
            if let Some(state) = msg.get("state").and_then(Value::as_str) {
                row.state = Some(state.to_string());
            }
        }
        Some("hitl_pending") => {
            row.hitl_tool = str_of(msg, "tool_name");
        }
        Some("hitl_resolved") => {
            row.hitl_tool = None;
        }
        Some("session_ended") => {
            rows.remove(session_id);
        }
        _ => {}
    }
}

fn str_of(msg: &Value, key: &str) -> Option<String> {
    msg.get(key).and_then(Value::as_str).map(str::to_string)
}

fn patch_str(slot: &mut Option<String>, msg: &Value, key: &str) {
    match msg.get(key) {
        None => {}
        Some(Value::Null) => *slot = None,
        Some(v) => {
            if let Some(s) = v.as_str() {
                *slot = Some(s.to_string());
            }
        }
    }
}

fn patch_u64(slot: &mut Option<u64>, msg: &Value, key: &str) {
    match msg.get(key) {
        None => {}
        Some(Value::Null) => *slot = None,
        Some(v) => {
            if let Some(n) = v.as_u64() {
                *slot = Some(n);
            }
        }
    }
}

fn chrono_now() -> chrono::DateTime<chrono::Utc> {
    chrono::Utc::now()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(raw: &str) -> Value {
        serde_json::from_str(raw).unwrap()
    }

    /// The fold has to honour the sparse patch exactly as the app does, or the
    /// two disagree and this command stops being evidence about anything.
    #[test]
    fn an_absent_field_is_unchanged_and_an_explicit_null_clears() {
        let mut rows = BTreeMap::new();
        fold(
            &mut rows,
            &msg(r#"{"type":"session_registered","session_id":"s1","title":"first","cwd":"/repo"}"#),
        );
        fold(
            &mut rows,
            &msg(r#"{"type":"session_updated","session_id":"s1","state":"working"}"#),
        );
        assert_eq!(rows["s1"].title.as_deref(), Some("first"), "absent leaves it");

        fold(
            &mut rows,
            &msg(r#"{"type":"session_updated","session_id":"s1","title":null}"#),
        );
        assert_eq!(rows["s1"].title, None, "an explicit null clears it");
    }

    #[test]
    fn a_pending_permission_outranks_the_reported_state() {
        let mut rows = BTreeMap::new();
        fold(
            &mut rows,
            &msg(r#"{"type":"session_updated","session_id":"s1","state":"working"}"#),
        );
        fold(
            &mut rows,
            &msg(r#"{"type":"hitl_pending","session_id":"s1","tool_name":"Bash"}"#),
        );
        assert_eq!(rows["s1"].hitl_tool.as_deref(), Some("Bash"));

        fold(
            &mut rows,
            &msg(r#"{"type":"hitl_resolved","session_id":"s1"}"#),
        );
        assert_eq!(rows["s1"].hitl_tool, None);
    }

    #[test]
    fn a_session_that_ended_leaves_the_table() {
        let mut rows = BTreeMap::new();
        fold(&mut rows, &msg(r#"{"type":"session_registered","session_id":"s1"}"#));
        fold(&mut rows, &msg(r#"{"type":"session_ended","session_id":"s1"}"#));
        assert!(rows.is_empty());
    }

    /// A percentage needs both halves. One measured number and one missing one
    /// is a count, not a proportion.
    #[test]
    fn a_percentage_is_never_computed_from_half_a_measurement() {
        let mut row = Row::default();
        assert_eq!(context_of(&row), "—");
        row.context_used = Some(56_000);
        assert_eq!(context_of(&row), "56k");
        row.context_size = Some(200_000);
        assert_eq!(context_of(&row), "28% 56k");
    }

    #[test]
    fn a_session_with_no_title_falls_back_to_the_working_directory_and_says_so() {
        let row = Row {
            cwd: Some("/Users/x/www/personal/aiterm".into()),
            ..Row::default()
        };
        assert_eq!(title_of(&row), "aiterm (cwd)");
    }

    #[test]
    fn the_title_carries_where_it_came_from() {
        let row = Row {
            title: Some("Corrigir o parser".into()),
            title_source: Some("ai_title".into()),
            ..Row::default()
        };
        assert_eq!(title_of(&row), "Corrigir o parser (ai_title)");
    }
}
