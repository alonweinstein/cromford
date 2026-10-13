#!/bin/bash
# bin/tts-say.sh <text-file|-> <out.ogg> — ElevenLabs TTS -> Telegram-ready OGG/Opus.
# Voice: ELEVENLABS_VOICE_ID (default River — relaxed, neutral). Model: flash v2.5
# (lowest latency/cost). Markdown tokens stripped so they aren't read aloud.
set -uo pipefail
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir)
SRC="${1:?text file or -}"; OUT="${2:?out.ogg}"
set -a; . $HENV/elevenlabs.env 2>/dev/null; set +a
[ -n "${ELEVENLABS_API_KEY:-}" ] || { echo "no ELEVENLABS_API_KEY" >&2; exit 1; }
VOICE="${ELEVENLABS_VOICE_ID:-SAz9YHcvj6GT2YYXdXww}"
TEXT=$(cat "$SRC" | sed -e 's/\*\*//g' -e 's/`//g' -e 's/^#\{1,4\} //' -e 's/\[\([^]]*\)\]([^)]*)/\1/g')
[ -n "$TEXT" ] || { echo "empty text" >&2; exit 1; }
TMP=$(mktemp --suffix=.mp3)
HTTP=$(jq -n --arg t "$TEXT" '{text:$t, model_id:"eleven_flash_v2_5"}' | \
  curl -s -o "$TMP" -w "%{http_code}" -X POST \
    "https://api.elevenlabs.io/v1/text-to-speech/$VOICE?output_format=mp3_44100_64" \
    -H "xi-api-key: $ELEVENLABS_API_KEY" -H "Content-Type: application/json" -d @-)
[ "$HTTP" = "200" ] && [ -s "$TMP" ] || { echo "TTS failed http=$HTTP $(head -c 120 "$TMP")" >&2; rm -f "$TMP"; exit 1; }
ffmpeg -y -loglevel error -i "$TMP" -c:a libopus -b:a 32k -ar 48000 -ac 1 "$OUT" || { rm -f "$TMP"; exit 1; }
rm -f "$TMP"
