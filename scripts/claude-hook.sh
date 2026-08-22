#!/bin/sh
# violeet Claude Code hook adapter — reads Claude Code hook JSON from stdin and
# POSTs it to the daemon's /hook/event route. Installed to
# ~/.violeet/claude-hook.sh by `violeet install-hooks`.
#
# Why this exists at all, when Claude Code speaks HTTP natively and this whole
# thing used to be a `type: http` entry:
#
#   - A `type: http` hook has no path for "the daemon is not running". Claude
#     Code treats the connection failure as non-blocking, so nothing breaks —
#     but it prints `<event> hook error / connect ECONNREFUSED` into the
#     transcript, once per event. PreToolUse and PostToolUse fire on every
#     single tool call, so a laptop with the daemon down turns into a wall of
#     errors about a feature the user is not using. The schema has no
#     `optional`/`ignoreFailure` field to opt out of that (checked against the
#     hook reference, not assumed).
#   - The port had to be baked in at install time, which is why `install-hooks`
#     refuses to run without a live daemon. Read here instead, from the same
#     discovery file the Cursor adapter already uses, the port follows the
#     daemon instead of a snapshot of where it was that day.
#
# The Cursor adapter (scripts/cursor-hook.sh) has always degraded this way. This
# script is the Claude Code side of that same behaviour, and deliberately does
# less: it forwards informational events and nothing else. PermissionRequest
# stays a native `type: http` hook, because that one blocks on a human and its
# fallback (daemon unreachable -> Claude Code's own dialog) is the measured-safe
# path documented in crates/violeet-cli/src/hooks.rs.
#
# The contract with the harness is one line long: exit 0, always, silently. An
# informational hook has no decision to make, so there is no outcome this script
# could report that Claude Code should act on. Note how narrow that is: exit 2
# from a PreToolUse hook BLOCKS the tool call, so a stray failure here does not
# merely add noise, it stops the user's work.
#
# Which is why every variable this script reads is guarded rather than assumed.
# `set -u` turns an unset variable into an error, and an error under `set -e`
# into an exit — so `$HOME` alone, on a machine that somehow has none, would
# exit 1 under sh and 2 under dash, printing to stderr on the way out. That is
# the precise pair of symptoms this whole file exists to avoid, produced by the
# file itself.
set -eu

payload=$(cat)
[ -n "$payload" ] || exit 0

home=${HOME:-}
[ -n "$home" ] || exit 0

discovery="$home/.violeet/daemon.json"
[ -f "$discovery" ] || exit 0

port=$(
    sed -n 's/.*"hook_port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$discovery" |
        head -n 1
)
[ -n "$port" ] || exit 0

command -v curl >/dev/null 2>&1 || exit 0

# VIOLEET_TAB_ID is what binds a session to the tab it runs in (ADR-003), and
# the daemon reads an empty header as "no tab" rather than as a tab — so it is
# sent always, empty included, exactly as the native http hook sent it.
#
# `-m 2`, not 5: the hook entry's own timeout is 5s and it covers this whole
# script, not just the POST. Matching the two would mean a stalled daemon has
# curl give up at the same instant the harness kills the command, turning a
# silent failure into a hook-timeout line per tool call. Two seconds expires
# well inside the budget, and telemetry is never worth delaying a tool call
# for — the status line wrapper hits this same daemon with the same -m 2.
printf '%s' "$payload" | curl -s -m 2 -X POST \
    -H 'Content-Type: application/json' \
    -H "x-violeet-tab-id: ${VIOLEET_TAB_ID:-}" \
    --data-binary @- \
    "http://127.0.0.1:${port}/hook/event?src=violeet" >/dev/null 2>&1 || true

exit 0
