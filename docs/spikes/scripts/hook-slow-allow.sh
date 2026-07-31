#!/bin/bash
input=$(cat)
echo "[$(date -u +%T)] command hook SLOW: recebido, dormindo 90s" >> /tmp/aiterm-spike/hook-slow.log
sleep 90
echo "[$(date -u +%T)] command hook SLOW: respondendo allow" >> /tmp/aiterm-spike/hook-slow.log
echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
