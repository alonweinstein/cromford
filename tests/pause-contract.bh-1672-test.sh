#!/bin/bash
# tests/pause-contract.bh-1672-test.sh — the box-side half of the BH-1672 pause
# contract: bin/lib/pause.sh reading a hand-written state/pauses.json.
#
# Every case sources the REAL lib and calls pause_active / pause_label exactly as
# a lane will, against a cache shaped like the GET /api/pauses body. The clock is
# pinned through PAUSE_NOW, the override the lib documents, so the expiry edge
# is exact and never depends on when the suite runs.
# Run from anywhere: tests/pause-contract.bh-1672-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/../bin/lib/pause.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export JOBS_HARNESS="$T/h"
mkdir -p "$JOBS_HARNESS/state"
CACHE="$JOBS_HARNESS/state/pauses.json"

NOW=1790000000
export PAUSE_NOW=$NOW
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
FUT=$(iso $((NOW + 3600)))
PAST_CREATED=$(iso $((NOW - 3600)))

# row <scope> <what> <expires_at> [ended_at]
row() {
  jq -nc --arg s "$1" --arg w "$2" --arg e "$3" --arg c "$PAST_CREATED" --arg end "${4:-}" \
    '{id:1, scope:$s, what:$w, reason:"test", actor:"t", created_at:$c, expires_at:$e,
      ended_at:(if $end == "" then null else $end end),
      end_reason:(if $end == "" then null else "resumed" end)}'
}
cache() { jq -s '{pauses:., truncated:false}' > "$CACHE"; }
active() { pause_active "$@"; echo $?; }

[ "$(__pause_cache)" = "$CACHE" ] && ok || bad "cache path is \$JOBS_HARNESS/state/pauses.json (got $(__pause_cache))"

# A1: a fleet row pauses every project.
row fleet merges "$FUT" | cache
[ "$(active projA merges)" = 0 ] && ok || bad "A1 fleet merges row → projA paused"
[ "$(active projB merges)" = 0 ] && ok || bad "A1 fleet merges row → projB paused"

# A2 / N1 / N2: a project row pauses only that project, only that what.
row projA reviews "$FUT" | cache
[ "$(active projA reviews)" = 0 ] && ok || bad "A2 projA reviews row → projA reviews paused"
[ "$(active projB reviews)" = 1 ] && ok || bad "N1 projA row must not pause projB"
[ "$(active projA builds)" = 1 ] && ok || bad "N2 projA reviews row must not pause projA builds"

# N3: an ended row is not live, however far away expires_at is.
row projA merges "$FUT" "$(iso $((NOW - 60)))" | cache
[ "$(active projA merges)" = 1 ] && ok || bad "N3 ended row must not pause"

# N4: expires_at one second before now is over; move the clock back and it is live.
row projA merges "$(iso $((NOW - 1)))" | cache
[ "$(active projA merges)" = 1 ] && ok || bad "N4 expired 1s before PAUSE_NOW must not pause"
[ "$(PAUSE_NOW=$((NOW - 2)) active projA merges)" = 0 ] && ok || bad "N4 same row, PAUSE_NOW 2s earlier → paused"
# The edge itself: expires_at == now is over (strict >).
row projA merges "$(iso $NOW)" | cache
[ "$(active projA merges)" = 1 ] && ok || bad "N4 expires_at == PAUSE_NOW must not pause"

# N5: no cache file → not paused, empty label.
rm -f "$CACHE"
[ "$(active projA merges)" = 1 ] && ok || bad "N5 no cache must not pause"
[ -z "$(pause_label projA)" ] && ok || bad "N5 no cache → empty label"

# N6: garbage → not paused, empty label. So is a body with no pauses array.
printf 'not json{' > "$CACHE"
[ "$(active projA merges)" = 1 ] && ok || bad "N6 garbage cache must not pause"
[ -z "$(pause_label projA)" ] && ok || bad "N6 garbage cache → empty label"
echo '{}' > "$CACHE"
[ "$(active projA merges)" = 1 ] && ok || bad "N6 {} must not pause"
echo '{"pauses":"x"}' > "$CACHE"
[ "$(active projA merges)" = 1 ] && ok || bad "N6 non-array pauses must not pause"
# A row whose expires_at does not parse is not live; a good row beside it still is.
{ row projA merges "soon"; row projA reviews "$FUT"; } | cache
[ "$(active projA merges)" = 1 ] && ok || bad "N6 unparseable expires_at must not pause"
[ "$(active projA reviews)" = 0 ] && ok || bad "N6 a bad row must not hide a good one"
# Missing args are not a pause.
row fleet merges "$FUT" | cache
[ "$(active projA)" = 1 ] && ok || bad "pause_active with no what must not pause"

# L1: fleet merges + projA reviews + an ended builds row + another project's triage.
{ row projA reviews "$FUT"; row fleet merges "$FUT"; row projA merges "$FUT";
  row projA builds "$FUT" "$(iso $((NOW - 60)))"; row projB triage "$FUT"; } | cache
out=$(pause_label projA)
[ "$out" = 'PAUSED(merges,reviews) ' ] && ok || bad "L1 label = 'PAUSED(merges,reviews) ' (got '$out')"
out=$(pause_label projB)
[ "$out" = 'PAUSED(merges,triage) ' ] && ok || bad "L1 projB label = 'PAUSED(merges,triage) ' (got '$out')"

# L2: an empty list → no label at all.
echo '{"pauses":[],"truncated":false}' > "$CACHE"
out=$(pause_label projA)
[ -z "$out" ] && ok || bad "L2 empty pauses → empty label (got '$out')"

# S1 / S2: BH-1683 filled in the stubs (tests/pause-lib.bh-1672-test.sh pins
# them). What still holds here: with no jobs client to load, pause_refresh
# leaves the cache alone at rc 0, and with no env pause shape it prints nothing.
row fleet merges "$FUT" | cache
before=$(sha256sum "$CACHE")
PAUSE_JOBS_CLIENT="$T/no-client.sh" pause_refresh 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok || bad "S1 pause_refresh with no client rc 0 (got $rc)"
[ "$(sha256sum "$CACHE")" = "$before" ] && ok || bad "S1 pause_refresh with no client must leave the cache alone"
[ -z "$(unset REVIEW_AUTOPILOT_DAILY_CAP; pause_env_shapes)" ] && ok || bad "S2 pause_env_shapes with no env pause prints nothing"

# H: the header carries both wire contracts the siblings build against.
LIB="$DIR/bin/lib/pause.sh"
if [ -f "$LIB" ]; then
  for pin in 'GET /api/pauses' 'PUT /api/pauses' 'POST /api/pauses/:id/end' 'POST /api/pauses/expire' 'state/pauses.json'; do
    grep -qF "$pin" "$LIB" && ok || bad "H header names '$pin'"
  done
else
  bad "H $LIB is missing"
fi

echo "pause-contract.bh-1672: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
