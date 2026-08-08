#!/bin/bash
# Cenario A: hook `command` que loga o payload cru e nega imediatamente.
LOG=/tmp/violeet-spike/hook.log
input=$(cat)

{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) PermissionRequest recebido (command hook) ==="
  echo "--- payload cru ---"
  echo "$input"
  echo "--- chaves de topo ---"
  echo "$input" | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin).keys()))'
  echo "--- campos de interesse ---"
  echo "$input" | python3 -c '
import json,sys
d = json.load(sys.stdin)
for k in ("tool_name","tool_input","permission_suggestions","tool_use_id","permission_mode","hook_event_name"):
    print(f"{k}: {json.dumps(d.get(k), ensure_ascii=False)}" if k in d else f"{k}: <AUSENTE>")
'
  echo
} >> "$LOG" 2>&1

cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "reason": "SPIKE-DENY: negado pelo hook command, sem dialogo interativo"
    }
  }
}
EOF
