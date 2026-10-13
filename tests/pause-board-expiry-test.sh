#!/bin/bash
# tests/pause-board-expiry-test.sh — a console pause_board carries an EXPLICIT
# expiry and says it.
#
# Before: the console's pause_board sent no ttl_s, so the jobs worker applied its
# generic pause_default_ttl_s (86400) and the triage row lapsed 24h after the
# last pause with nothing on the command, the board or ALERTS saying when.
# Now:
#   E1 no ttl_s in the payload -> ttl_s = PAUSE_BOARD_TTL_S (a poll-commands
#      settings row, default 604800), never omitted;
#   E2 a payload ttl_s wins over the settings row;
#   E3 an unusable PAUSE_BOARD_TTL_S falls back to the registered default;
#   E4 the RESULT names the row's expires_at when the worker returns it, and
#      stays the plain "paused" when it does not (older worker / stub);
#   E5 the knob is registered in catalog/lanes.d/poll-commands.json with the
#      same default the code falls back to.
# Run from anywhere: tests/pause-board-expiry-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

{ echo 'case "$TYPE" in'
  awk '/^    # >>> pause handlers/{f=1;next} /^    # <<< pause handlers/{exit} f{print}' "$DIR/bin/poll-commands.sh"
  echo 'esac'
} > "$T/pause.body"
[ "$(wc -l < "$T/pause.body")" -gt 3 ] || { echo "FAIL: could not extract the pause handlers block"; exit 1; }

cat > "$T/stubs.sh" <<'EOF'
set_flag() { case "${2:-}" in on) touch "$HARNESS/flags/$1" ;; off) rm -f "$HARNESS/flags/$1" ;; esac; return 0; }
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$CALLS"
  # Mirrors bin/lib/jobs/req.sh: the answer is printed AND kept in JOBS_BODY.
  JOBS_HTTP=200; JOBS_BODY='{}'
  if [ "$1 $2" = "PUT /api/pauses" ] && [ -n "${STUB_EXP:-}" ]; then
    JOBS_BODY=$(jq -nc --arg e "$STUB_EXP" '{pause:{id:7,scope:"project-3",what:"triage",expires_at:$e,ended_at:null}}')
  fi
  printf '%s' "$JOBS_BODY"
  return 0
}
EOF
CALLS="$T/calls.log"
run() { # run <payload> [knob] [stub-expires-at]
  : > "$CALLS"
  env -u PAUSE_BOARD_TTL_S ${2:+PAUSE_BOARD_TTL_S="$2"} HARNESS="$T/h" CALLS="$CALLS" STUB_EXP="${3:-}" \
    TYPE=pause_board PROJECT=project-3 PAYLOAD="$1" ID=1 OK=false RESULT="" \
    bash -c 'set -uo pipefail; . "$0"; . "$1"; echo "OK=$OK RESULT=$RESULT"' "$T/stubs.sh" "$T/pause.body"
}
ttl_sent() { sed -n 1p "$CALLS" | cut -d' ' -f3- | jq -r '.ttl_s // "absent"'; }

DEF=$(jq -r '.knobs[] | select(.env=="PAUSE_BOARD_TTL_S") | .default' "$DIR/catalog/lanes.d/poll-commands.json" 2>/dev/null)
[ "$DEF" = 604800 ] && ok || bad "E5 PAUSE_BOARD_TTL_S must be a poll-commands settings row with default 604800 (got '${DEF:-none}')"

OUT=$(run '{"reason":"deploy"}')
[ "$(ttl_sent)" = 604800 ] && [ -f "$T/h/flags/paused-project-3" ] && grep -q '^OK=true' <<<"$OUT" \
  && ok || bad "E1 no payload ttl must send the settings default 604800 (ttl=$(ttl_sent) out=$OUT)"

OUT=$(run '{"reason":"deploy"}' 172800)
[ "$(ttl_sent)" = 172800 ] && ok || bad "E1 PAUSE_BOARD_TTL_S=172800 must be sent (ttl=$(ttl_sent))"

OUT=$(run '{"reason":"deploy","ttl_s":600}' 172800)
[ "$(ttl_sent)" = 600 ] && ok || bad "E2 a payload ttl_s wins over the settings row (ttl=$(ttl_sent))"

for K in abc 0 -5 '1e3'; do
  OUT=$(run '{"reason":"deploy"}' "$K")
  [ "$(ttl_sent)" = 604800 ] && ok || bad "E3 PAUSE_BOARD_TTL_S='$K' must fall back to 604800 (ttl=$(ttl_sent))"
done

OUT=$(run '{"reason":"deploy"}' "" 2026-10-04T12:00:00Z)
grep -q '^OK=true RESULT=paused until 2026-10-04T12:00:00Z$' <<<"$OUT" \
  && ok || bad "E4 RESULT must name the worker's expires_at (out=$OUT)"
OUT=$(run '{"reason":"deploy"}')
grep -q '^OK=true RESULT=paused$' <<<"$OUT" \
  && ok || bad "E4 no expires_at in the answer keeps RESULT=paused (out=$OUT)"
# An expires_at that is not an ISO time is never echoed into the RESULT.
OUT=$(run '{"reason":"deploy"}' "" 'soon; rm -rf /')
grep -q '^OK=true RESULT=paused$' <<<"$OUT" \
  && ok || bad "E4 a malformed expires_at is not echoed (out=$OUT)"

echo "pause-board-expiry: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
