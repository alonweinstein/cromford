#!/bin/bash
# Transcribe an audio/video file to text on stdout (Telegram voice notes etc).
# usage: transcribe.sh <media-file>   — prints transcript; rc=1 on failure.
set -uo pipefail
IN="${1:?media file}"
[ -s "$IN" ] || { echo "transcribe: missing/empty $IN" >&2; exit 1; }
WAV=$(mktemp --suffix=.wav)
trap 'rm -f "$WAV"' EXIT
# Any container/codec Telegram sends (oga/opus, m4a, mp4 video note) -> 16k mono wav
ffmpeg -y -loglevel error -i "$IN" -vn -ac 1 -ar 16000 "$WAV" || exit 1
HF_HUB_DISABLE_PROGRESS_BARS=1 /root/harness/venv-whisper/bin/python - "$WAV" <<'EOF'
import sys
from faster_whisper import WhisperModel
model = WhisperModel("small", device="cpu", compute_type="int8",
                     download_root="/root/harness/models", local_files_only=True)
segments, info = model.transcribe(sys.argv[1], vad_filter=True)
text = " ".join(s.text.strip() for s in segments).strip()
print(text)
EOF
