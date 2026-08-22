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
# could report that Claude Code should act on.
set -eu

payload=$(cat)
[ -n "$payload" ] || exit 0

discovery="$HOME/.violeet/daemon.json"
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
printf '%s' "$payload" | curl -s -m 5 -X POST \
    -H 'Content-Type: application/json' \
    -H "x-violeet-tab-id: ${VIOLEET_TAB_ID:-}" \
    --data-binary @- \
    "http://127.0.0.1:${port}/hook/event?src=violeet" >/dev/null 2>&1 || true

exit 0
