#!/usr/bin/env bash
#
# Convert the bespoke prompt MP3s in sounds/ to 8 kHz mono 16-bit PCM WAV,
# which is FreeSWITCH's native format. Re-run this after dropping a fresh
# batch of renders into sounds/.
#
# Why 8 kHz mono?
#   - PSTN telephony bandwidth is 300-3400 Hz; resampling to 8 kHz throws
#     away nothing the caller can hear and saves CPU at playback time.
#   - mono is correct for a phone call (stereo would be downmixed anyway).
#   - 16-bit PCM is the codec FreeSWITCH plays without any decode overhead.
#
# Requires ffmpeg on the host. Operates only on the named files below, so
# stray test renders in sounds/ are ignored.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SOUNDS="$REPO/sounds"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "error: ffmpeg not found on PATH" >&2
  exit 1
fi

convert() {
  local rel="$1"
  local src="$SOUNDS/$rel.mp3"
  local dst="$SOUNDS/$rel.wav"
  if [ ! -f "$src" ]; then
    echo "  MISSING $rel.mp3" >&2
    return 1
  fi
  ffmpeg -y -loglevel error -i "$src" \
    -ar 8000 -ac 1 -c:a pcm_s16le "$dst"
  printf '  ok   %s.wav\n' "$rel"
}

echo "Dialogue prompts:"
for n in welcome enter-code invalid-code you-entered press-to-confirm \
         cancelled thanks all-lines-busy limit-reached error goodbye; do
  convert "$n"
done

echo "Digit clips:"
mkdir -p "$SOUNDS/digits"
for d in 0 1 2 3 4 5 6 7 8 9; do
  convert "digits/$d"
done

echo "done."
