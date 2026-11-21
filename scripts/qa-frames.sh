#!/usr/bin/env bash
# Renders the synthetic sample through the real export pipeline (no UI, no Screen Recording) and extracts
# three frames: before the zoom, mid-zoom, full zoom, plus a GIF.   ./scripts/qa-frames.sh [Reel binary] [out dir]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-$HOME/Library/Developer/Xcode/DerivedData/ReelDev/Build/Products/Debug/Reel.app/Contents/MacOS/Reel}"
OUT="${2:-qa/render}"
FF=/opt/homebrew/bin/ffmpeg
WORK="$(mktemp -d "${TMPDIR:-/tmp}/reel-frames.XXXXXX")"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
"$APP" -make-sample "$WORK/take" >/dev/null
"$APP" -render "$WORK/take" "$WORK/out.mp4" 2>/dev/null
"$APP" -render "$WORK/take" "$OUT/sample.gif" 2>/dev/null
for pair in "before-zoom:0.3" "mid-zoom:0.8" "full-zoom:1.2"; do
  "$FF" -y -loglevel error -ss "${pair#*:}" -i "$WORK/out.mp4" -frames:v 1 "$OUT/frame-${pair%%:*}.png"
done
ls -la "$OUT"
