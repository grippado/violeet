#!/bin/bash
input=$(cat)
echo "[$(date -u +%T)] allow-hook delay=0 recebido" >> /tmp/violeet-spike/hook-allow.log
[ "0" -gt 0 ] && sleep 0
echo "[$(date -u +%T)] allow-hook delay=0 respondendo allow" >> /tmp/violeet-spike/hook-allow.log
echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
