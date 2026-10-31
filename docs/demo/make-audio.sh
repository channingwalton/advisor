#!/usr/bin/env bash
# Generates out/dialogue.wav from dialogue.txt with the macOS `say` voices, and
# out/timeline.tsv with the start and end time (seconds) of each spoken line.
# Needs ffmpeg. RATE sets the speech rate in words a minute (default 180).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out="$here/out"
rate=${RATE:-180}
rm -rf "$out/lines"
mkdir -p "$out/lines"
: > "$out/concat.txt"
printf 'start\tend\tvoice\ttext\n' > "$out/timeline.tsv"

duration() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

t=0
n=0
while IFS='|' read -r voice pause text; do
  [[ -z "$voice" || "$voice" == \#* ]] && continue
  n=$((n + 1))
  say -v "$voice" -r "$rate" -o "$out/lines/$n.aiff" "$text"
  speech=$(duration "$out/lines/$n.aiff")
  ffmpeg -v error -y -i "$out/lines/$n.aiff" -af "apad=pad_dur=$pause" -ar 48000 -ac 1 "$out/lines/$n.wav"
  printf '%.2f\t%.2f\t%s\t%s\n' "$t" "$(echo "$t + $speech" | bc)" "$voice" "$text" >> "$out/timeline.tsv"
  t=$(echo "$t + $(duration "$out/lines/$n.wav")" | bc)
  printf "file '%s'\n" "$out/lines/$n.wav" >> "$out/concat.txt"
done < "$here/dialogue.txt"

ffmpeg -v error -y -f concat -safe 0 -i "$out/concat.txt" -c copy "$out/dialogue.wav"
printf 'Wrote %s (%.1f s, %d lines)\n' "$out/dialogue.wav" "$(duration "$out/dialogue.wav")" "$n"
column -t -s $'\t' "$out/timeline.tsv"
