#!/bin/bash
# tests/pipeline-health-pause-expiry-test.sh — bin/pipeline-health.sh warns
# BEFORE a live pause row lapses, so a board pause never ends silently.
#
# The block between `# >>> pause expiry warning` and `# <<< pause expiry
# warning` is extracted VERBATIM and run against a pauses cache
# (state/pauses.json, the file bin/lib/pause.sh's pause_refresh writes) with a
# recording alert().
#   W1 a live row expiring inside PAUSE_EXPIRY_WARN_S pages once, naming scope,
#      what, expires_at, actor and reason;
#   W2 a row expiring later, an ended row and an already-expired row do not;
#   W3 the alert key carries expires_at, so a renewed pause warns again;
#   W4 PAUSE_EXPIRY_WARN_S=0 turns the warning off; an unusable value falls
#      back to the registered default;
#   W5 the knob is a pipeline-health settings row, default 7200.
# Run from anywhere: tests/pipeline-health-pause-expiry-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/state" "$T/h/bin/lib"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

awk '/^# >>> pause expiry warning/{f=1;next} /^# <<< pause expiry warning/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] || { echo "FAIL: could not extract the pause expiry warning block — markers missing?"; exit 1; }

DEF=$(jq -r '.knobs[] | select(.env=="PAUSE_EXPIRY_WARN_S") | .default' "$DIR/catalog/lanes.d/pipeline-health.json" 2>/dev/null)
[ "$DEF" = 7200 ] && ok || bad "W5 PAUSE_EXPIRY_WARN_S must be a pipeline-health settings row with default 7200 (got '${DEF:-none}')"

NOW=1790000000
iso() { date -u -d "@$(( NOW + $1 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$(( NOW + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }
jq -n --arg soon "$(iso 3600)" --arg later "$(iso 18000)" --arg past "$(iso -60)" --arg soon2 "$(iso 5400)" '{pauses:[
  {id:1,scope:"project-3",what:"triage",actor:"operator",reason:"release freeze",expires_at:$soon,ended_at:null},
  {id:2,scope:"project-4",what:"triage",actor:"console",reason:"x",expires_at:$later,ended_at:null},
  {id:3,scope:"project-5",what:"merges",actor:"console",reason:"x",expires_at:$soon2,ended_at:"2026-01-01T00:00:00Z"},
  {id:4,scope:"project-9",what:"builds",actor:"console",reason:"x",expires_at:$past,ended_at:null}
]}' > "$T/h/state/pauses.json"

run() { # run [warn-knob]
  env -u PAUSE_EXPIRY_WARN_S ${1+PAUSE_EXPIRY_WARN_S="$1"} H="$T/h" NOW="$NOW" bash -c '
    set -uo pipefail
    pause_refresh() { return 0; }
    alert() { printf "%s|%s|%s\n" "$1" "$2" "$3"; }
    . "$0"' "$T/blk.sh"
}

OUT=$(run)
N=$(grep -c . <<<"$OUT")
[ "$N" = 1 ] && ok || bad "W1/W2 exactly one row is inside the 2h lead (got $N: $OUT)"
LINE=$(grep '|pauseexpiry:project-3:triage:' <<<"$OUT")
[ -n "$LINE" ] && grep -q "$(iso 3600)" <<<"$LINE" && grep -q 'operator' <<<"$LINE" && grep -q 'release freeze' <<<"$LINE" \
  && grep -q 'in 60m' <<<"$LINE" \
  && ok || bad "W1 the warning names scope, what, expires_at, minutes left, actor and reason (got: $OUT)"
grep -q "|pauseexpiry:project-3:triage:$(iso 3600)|" <<<"$OUT" \
  && ok || bad "W3 the alert key carries expires_at (got: $OUT)"

OUT=$(run 20000)
[ "$(grep -c . <<<"$OUT")" = 2 ] && grep -q 'pauseexpiry:project-4:triage:' <<<"$OUT" \
  && ok || bad "W4 a wider lead covers the 5h row too (got: $OUT)"
OUT=$(run 0)
[ -z "$OUT" ] && ok || bad "W4 PAUSE_EXPIRY_WARN_S=0 is off (got: $OUT)"
OUT=$(run abc)
[ "$(grep -c . <<<"$OUT")" = 1 ] && ok || bad "W4 an unusable knob falls back to 7200 (got: $OUT)"

rm -f "$T/h/state/pauses.json"
OUT=$(run)
[ -z "$OUT" ] && ok || bad "no cache is no warning, never an error (got: $OUT)"

echo "pipeline-health-pause-expiry: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
