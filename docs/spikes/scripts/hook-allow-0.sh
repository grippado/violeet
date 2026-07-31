#!/bin/bash
input=$(cat)
echo "[$(date -u +%T)] allow-hook delay=0 recebido" >> /tmp/aiterm-spike/hook-allow.log
[ "0" -gt 0 ] && sleep 0
echo "[$(date -u +%T)] allow-hook delay=0 respondendo allow" >> /tmp/aiterm-spike/hook-allow.log
echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
