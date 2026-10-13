#!/bin/bash
# greenfield-ingest.sh <workspace> [source-dir ...] — mirror client-provided
# assets into <workspace>/materials/ as agent-readable text. Sources come from
# args and/or <workspace>/sources.txt (one dir per line, ~ ok, # comments).
# Idempotent + resumable: skip-if-output-exists keyed on source name; re-run
# any time new files arrive from the client.
# Conversions: pdf -> pdftotext; docx/rtf -> textutil; xlsx -> per-sheet CSV
# (python3 pandas/openpyxl if available); md/txt/csv/json -> copy.
set -uo pipefail
WS="${1:?usage: greenfield-ingest.sh <workspace> [source-dir ...]}"
shift || true
WS="$(cd "$WS" && pwd)"
MAT="$WS/materials"
mkdir -p "$MAT"

SOURCES=("$@")
if [ -f "$WS/sources.txt" ]; then
  while IFS= read -r LINE; do
    LINE="${LINE%%#*}"; LINE="$(echo "$LINE" | xargs)"; [ -n "$LINE" ] || continue
    SOURCES+=("${LINE/#\~/$HOME}")
  done < "$WS/sources.txt"
fi
[ "${#SOURCES[@]}" -gt 0 ] || { echo "no sources (pass dirs or create $WS/sources.txt)"; exit 1; }

N_NEW=0; N_SKIP=0; N_FAIL=0
ingest_file() { # ingest_file <file> <prefix>
  local F="$1" PFX="$2" BASE OUT EXT
  BASE="$(basename "$F")"
  case "$BASE" in *.dg.json) return ;; esac  # Deepgram raw payloads duplicate their .md transcripts
  EXT="${BASE##*.}"; EXT=$(tr '[:upper:]' '[:lower:]' <<<"$EXT")
  case "$EXT" in
    md|txt|csv|json) OUT="$MAT/${PFX}__${BASE}"
      [ -s "$OUT" ] && { N_SKIP=$((N_SKIP+1)); return; }
      cp "$F" "$OUT" && N_NEW=$((N_NEW+1)) ;;
    pdf) OUT="$MAT/${PFX}__${BASE%.*}.txt"
      [ -s "$OUT" ] && { N_SKIP=$((N_SKIP+1)); return; }
      if pdftotext -layout "$F" "$OUT" 2>/dev/null && [ -s "$OUT" ]; then N_NEW=$((N_NEW+1))
      else echo "  FAILED pdf: $BASE (install poppler? scanned-image pdf?)"; rm -f "$OUT"; N_FAIL=$((N_FAIL+1)); fi ;;
    docx|rtf|doc) OUT="$MAT/${PFX}__${BASE%.*}.txt"
      [ -s "$OUT" ] && { N_SKIP=$((N_SKIP+1)); return; }
      if textutil -convert txt -output "$OUT" "$F" 2>/dev/null && [ -s "$OUT" ]; then N_NEW=$((N_NEW+1))
      else echo "  FAILED doc: $BASE"; rm -f "$OUT"; N_FAIL=$((N_FAIL+1)); fi ;;
    xlsx|xls) OUT="$MAT/${PFX}__${BASE%.*}__sheets.txt"
      [ -s "$OUT" ] && { N_SKIP=$((N_SKIP+1)); return; }
      if python3 - "$F" "$OUT" <<'PYEOF' 2>/dev/null
import sys
try:
    import pandas as pd
except ImportError:
    sys.exit(1)
src, dst = sys.argv[1], sys.argv[2]
with open(dst, "w") as out:
    for name, df in pd.read_excel(src, sheet_name=None).items():
        out.write(f"===== SHEET: {name} =====\n")
        out.write(df.to_csv(index=False))
        out.write("\n")
PYEOF
      then N_NEW=$((N_NEW+1))
      else echo "  FAILED xlsx: $BASE (python3 pandas/openpyxl missing?)"; rm -f "$OUT"; N_FAIL=$((N_FAIL+1)); fi ;;
    *) return ;;  # skip binaries/media silently
  esac
}

for SRC in "${SOURCES[@]}"; do
  [ -d "$SRC" ] || { echo "skip missing source: $SRC"; continue; }
  PFX="$(basename "$SRC")"
  echo "source: $SRC"
  while IFS= read -r -d '' F; do
    ingest_file "$F" "$PFX"
  done < <(find "$SRC" -maxdepth 2 -type f ! -name '.*' -print0)
done
echo "ingest: $N_NEW new, $N_SKIP already present, $N_FAIL failed -> $MAT ($(ls "$MAT" | wc -l | tr -d ' ') files total)"
