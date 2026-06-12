#!/bin/sh
# Replay a fragmented real-meeting transcript through the sidecar and show triggers.
cd "$(dirname "$0")/.."
{
  printf '%s\n' '{"type":"session_start","sessionId":"replay","ts":0}'
  i=0
  while IFS= read -r line; do
    i=$((i+1))
    src=$(printf '%s' "$line" | cut -d"|" -f1)
    txt=$(printf '%s' "$line" | cut -d"|" -f2-)
    printf '{"type":"utterance","id":"u%s","source":"%s","text":"%s","ts":%s}\n' "$i" "$src" "$txt" "$i"
    sleep 0.4
  done < test/fragments.txt
  sleep 30
} | node dist/main.js 2>&1 | grep -E "classify →|trigger\(|\"type\":\"card\""
