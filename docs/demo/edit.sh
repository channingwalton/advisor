#!/usr/bin/env bash
# Makes the README GIF, docs/demo/advisor.gif, from a take.
#
# Usage: edit.sh [take]   (default: out/take.mov)
#
# START and END trim the take, in seconds (default: the whole take). SPEED sets
# the playback speed (default 2). WIDTH (default 720 px) and FPS (default 10)
# set the size. HOLD keeps the last frame on screen for that many seconds
# (default 4), so that a reader can read the cards before the GIF loops.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
in=${1:-$here/out/take.mov}
gif="$here/advisor.gif"
speed=${SPEED:-2}
width=${WIDTH:-720}
fps=${FPS:-10}
hold=${HOLD:-4}

trim=()
if [[ -n "${START:-}" ]]; then trim+=(-ss "$START"); fi
if [[ -n "${END:-}" ]]; then trim+=(-to "$END"); fi

ffmpeg -v error -y ${trim[@]+"${trim[@]}"} -i "$in" -filter_complex \
  "[0:v]setpts=PTS/$speed,fps=$fps,scale=$width:-2:flags=lanczos,tpad=stop_mode=clone:stop_duration=$hold,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 "$gif"

seconds=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$gif")
printf 'Wrote %s (%.0f s, %s)\n' "$gif" "$seconds" "$(du -h "$gif" | cut -f1 | tr -d ' ')"
