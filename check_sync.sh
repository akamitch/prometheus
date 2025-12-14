#!/usr/bin/env bash
set -euo pipefail

echo "Chain sync status (node container)..."
STATUS=$(curl -s localhost:26657/status)

HEIGHT=$(echo "$STATUS" | jq -r '.result.sync_info.latest_block_height')
TIME=$(echo "$STATUS" | jq -r '.result.sync_info.latest_block_time')
CATCHING_UP=$(echo "$STATUS" | jq -r '.result.sync_info.catching_up')

BLOCK_TS=$(date -d "$TIME" +%s)
NOW_TS=$(date +%s)
LAG=$((NOW_TS - BLOCK_TS))

echo "Height:       $HEIGHT"
echo "Block time:   $TIME"
echo "Catching up:  $CATCHING_UP"
echo "Time lag:     ${LAG}s"

if [ "$CATCHING_UP" = "false" ] && [ "$LAG" -le 30 ]; then
  echo "OK: node is in sync."
else
  echo "WARN: node not fully in sync (lag ${LAG}s, catching_up=$CATCHING_UP)."
fi