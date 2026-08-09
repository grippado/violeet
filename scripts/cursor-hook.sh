#!/bin/sh
# violeet Cursor hook adapter — reads Cursor hook JSON from stdin, POSTs to the
# daemon, and translates HITL responses back to Cursor's permission format.
# Installed to ~/.violeet/cursor-hook.sh by `violeet install-cursor-hooks`.
set -eu

# Cursor pipes hook JSON on stdin. A heredoc for the Python body would steal
# that stream, so capture stdin here first.
export CURSOR_HOOK_INPUT
CURSOR_HOOK_INPUT=$(cat)

exec python3 - "$HOME" <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

HOME = sys.argv[1]
DISCOVERY = os.path.join(HOME, ".violeet", "daemon.json")
HARNESS_HEADER = "x-violeet-harness"
CURSOR_HARNESS = "cursor"

EVENT_MAP = {
    "sessionStart": "SessionStart",
    "sessionEnd": "SessionEnd",
    "beforeSubmitPrompt": "UserPromptSubmit",
    "stop": "Stop",
    "beforeShellExecution": "PermissionRequest",
    "beforeMCPExecution": "PermissionRequest",
}


def read_port():
    try:
        with open(DISCOVERY, encoding="utf-8") as f:
            return int(json.load(f)["hook_port"])
    except (OSError, KeyError, TypeError, ValueError):
        return None


def session_id(data):
    sid = data.get("session_id") or data.get("conversation_id")
    if isinstance(sid, str) and sid.strip():
        return sid.strip()
    return None


def cwd_of(data):
    cwd = data.get("cwd")
    if isinstance(cwd, str) and cwd.strip():
        return cwd.strip()
    roots = data.get("workspace_roots")
    if isinstance(roots, list) and roots:
        first = roots[0]
        if isinstance(first, str) and first.strip():
            return first.strip()
    return None


def to_daemon_payload(data):
    event_name = data.get("hook_event_name")
    if not isinstance(event_name, str):
        return None, False

    mapped = EVENT_MAP.get(event_name)
    if mapped is None:
        return None, False

    sid = session_id(data)
    if sid is None:
        return None, False

    out = {
        "session_id": sid,
        "hook_event_name": mapped,
    }

    cwd = cwd_of(data)
    if cwd:
        out["cwd"] = cwd

    transcript = data.get("transcript_path")
    if isinstance(transcript, str) and transcript.strip():
        out["transcript_path"] = transcript.strip()

    if mapped == "UserPromptSubmit":
        prompt = data.get("prompt")
        if isinstance(prompt, str) and prompt:
            out["prompt"] = prompt

    if mapped == "PermissionRequest":
        if event_name == "beforeShellExecution":
            command = data.get("command")
            if not isinstance(command, str):
                return None, True
            out["tool_name"] = "Bash"
            out["tool_input"] = {"command": command}
        else:
            tool_name = data.get("tool_name")
            if not isinstance(tool_name, str) or not tool_name.strip():
                return None, True
            out["tool_name"] = tool_name.strip()
            tool_input = data.get("tool_input")
            if tool_input is None:
                out["tool_input"] = {}
            else:
                out["tool_input"] = tool_input

    return out, mapped == "PermissionRequest"


def post(port, path, body, permission=False):
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            HARNESS_HEADER: CURSOR_HARNESS,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=600 if permission else 5) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except (urllib.error.URLError, TimeoutError):
        return None, b""


def cursor_permission_response(status, raw):
    if status == 200 and raw:
        try:
            parsed = json.loads(raw.decode("utf-8"))
            decision = (
                parsed.get("hookSpecificOutput", {}).get("decision", {})
            )
            behavior = decision.get("behavior")
            reason = decision.get("reason")
            if behavior == "allow":
                return {"permission": "allow"}
            if behavior == "deny":
                out = {"permission": "deny"}
                if isinstance(reason, str) and reason:
                    out["user_message"] = reason
                return out
        except (json.JSONDecodeError, UnicodeDecodeError):
            pass
    # Fail-open: Cursor defaults to allow on hook failure; ask keeps the IDE dialog.
    return {
        "permission": "ask",
        "user_message": "violeet could not resolve this permission request.",
    }


def log_invocation(data):
    try:
        log_path = os.path.join(HOME, ".violeet", "cursor-hook.log")
        event = data.get("hook_event_name", "?")
        sid = data.get("session_id") or data.get("conversation_id") or "?"
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(f"{event} sid={sid}\n")
    except OSError:
        pass


DEBOUNCE_SEC = 0.75


def should_skip_duplicate(data):
    """Workspace at $HOME loads ~/.cursor/hooks.json as user + project hooks."""
    event = data.get("hook_event_name", "")
    sid = session_id(data)
    if not event or sid is None:
        return False
    cache_path = os.path.join(HOME, ".violeet", "cursor-hook-debounce.json")
    key = f"{event}:{sid}"
    now = time.time()
    try:
        with open(cache_path, encoding="utf-8") as f:
            cache = json.load(f)
    except (OSError, json.JSONDecodeError):
        cache = {}
    last = cache.get(key)
    if last is not None and now - last < DEBOUNCE_SEC:
        return True
    cache[key] = now
    cache = {k: v for k, v in cache.items() if now - v < 60}
    try:
        with open(cache_path, "w", encoding="utf-8") as f:
            json.dump(cache, f)
    except OSError:
        pass
    return False


def emit_cursor_stdout(data):
    event = data.get("hook_event_name")
    if event == "sessionStart":
        print("{}")
    elif event == "beforeSubmitPrompt":
        print(json.dumps({"continue": True}))


raw = os.environ.get("CURSOR_HOOK_INPUT", "")
if not raw.strip():
    sys.exit(0)

try:
    inbound = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

log_invocation(inbound)

if should_skip_duplicate(inbound):
    if inbound.get("hook_event_name") in (
        "beforeShellExecution",
        "beforeMCPExecution",
    ):
        print(json.dumps(cursor_permission_response(None, b"")))
    else:
        emit_cursor_stdout(inbound)
    sys.exit(0)

port = read_port()
if port is None:
    if inbound.get("hook_event_name") in (
        "beforeShellExecution",
        "beforeMCPExecution",
    ):
        print(json.dumps(cursor_permission_response(None, b"")))
    sys.exit(0)

payload, is_permission = to_daemon_payload(inbound)
if payload is None:
    if is_permission:
        print(json.dumps(cursor_permission_response(None, b"")))
    sys.exit(0)

if is_permission:
    status, body = post(port, "/hook/permission-request", payload, permission=True)
    print(json.dumps(cursor_permission_response(status, body)))
else:
    post(port, "/hook/event", payload)
    emit_cursor_stdout(inbound)
PY
