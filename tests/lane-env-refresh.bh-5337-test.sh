#!/bin/bash
# tests/lane-env-refresh.bh-5337-test.sh — BH-5337 part 2: lane_env_apply
# (bin/lib/lane-gate.sh) refreshes state/settings-cache.json on lane entry when
# the cache is older than LANE_GATE_CACHE_S (60), so a knob changed in D1
# reaches the next tick. The refresh is fail-open: a worker that does not
# answer leaves the old cache, and the miss stamp holds the retry for one TTL.
#   R1  cache 500 s old holds lead_review_concurrency=0, the worker answers 3:
#       the lane gets 3 and the cache is re-stamped now.
#   R1b cache 500 s old with NO row for the knob (the row is new in D1): the
#       refresh on entry is what finds it, so the lane gets 3, not its default.
#   R2  the same stale cache, the worker does not answer: the lane keeps 0, the
#       cache file is byte-identical, state/lane-gate/.settings-miss is written.
#   R3  cache 10 s old (inside the TTL): no GET.
#   R4  cache exactly 60 s old (the TTL edge): one GET.
#   R5  a miss stamp 10 s old and a stale cache: no GET, the old value stays.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-env-refresh.bh-5337-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
DIR="$SRC"   # tests/lib/rendered.sh reads $DIR as the repo root
# catalog/lanes.json is generated and not committed: rendered_registry renders it into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=1760000000
KEY=lane.lead-review.lead_review_concurrency
CACHE="$T/h/state/settings-cache.json"
MISS="$T/h/state/lane-gate/.settings-miss"
mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/catalog" "$T/h/flags"
scratch_install_closure bin/lib/lane-gate.sh "$T/h" >/dev/null || { echo "FAIL: closure install of bin/lib/lane-gate.sh"; exit 1; }
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"
jq -e '[.. | objects | select(.env? == "LEAD_REVIEW_CONCURRENCY")] | length > 0' "$T/h/catalog/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: the registry has no LEAD_REVIEW_CONCURRENCY knob"; exit 1; }

# The stub worker: every GET is one line in $CALLS; UNREACHABLE=1 fails it.
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  jq -nc --arg k "$KEY" --arg v "$ROW" '{settings:[{key:$k,value:$v,actor:"operator"}]}'
}
SH

reset() { # reset <cache age s> [miss age s]; NOROW=1 caches no row for the knob
  rm -rf "$T/h/state/lane-gate"; : > "$T/calls"
  jq -nc --argjson fa "$((NOW - $1))" --arg k "$KEY" --arg nr "${NOROW:-}" \
    '{fetched_at:$fa, values:(if $nr == "" then {($k):"0"} else {} end), seeded:{}}' > "$CACHE"
  if [ -n "${2:-}" ]; then mkdir -p "${MISS%/*}"; echo "$((NOW - $2))" > "$MISS"; fi
}
# apply [VAR=val ...] — lane_env_apply lead-review in a clean shell; V is the
# value the lane sees.
apply() {
  V=$(env -u LEAD_REVIEW_CONCURRENCY HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" KEY="$KEY" ROW=3 "$@" bash -c '
    set -uo pipefail
    . "$HARNESS/bin/stub-jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"
    lane_env_apply lead-review
    printf "%s" "${LEAD_REVIEW_CONCURRENCY:-UNSET}"' 2>/dev/null)
}
gets() { grep -c '^GET /api/settings' "$T/calls"; }

# ── R1: a stale cache is refreshed on lane entry ──
reset 500
apply
[ "$V" = 3 ] && ok || bad "R1 a 500 s old cache was served: LEAD_REVIEW_CONCURRENCY='$V' (want 3)"
[ "$(gets)" = 1 ] && ok || bad "R1 GETs=$(gets) (want 1)"
[ "$(jq -r '.fetched_at' "$CACHE")" = "$NOW" ] && ok || bad "R1 the cache was not re-stamped: $(cat "$CACHE")"

# ── R1b: a row the stale cache has never seen ──
NOROW=1 reset 500
apply
[ "$V" = 3 ] && ok || bad "R1b a row new since the cache was filled did not reach the lane: LEAD_REVIEW_CONCURRENCY='$V' (want 3)"
[ "$(gets)" = 1 ] && ok || bad "R1b GETs=$(gets) (want 1)"

# ── R2: fail-open, the old cache stays ──
reset 500; cp "$CACHE" "$T/before.json"
apply UNREACHABLE=1
[ "$V" = 0 ] && ok || bad "R2 a failed refresh changed the value to '$V' (want the cached 0)"
cmp -s "$CACHE" "$T/before.json" && ok || bad "R2 a failed refresh changed the cache: $(cat "$CACHE")"
[ "$(cat "$MISS" 2>/dev/null)" = "$NOW" ] && ok || bad "R2 no miss stamp: '$(cat "$MISS" 2>/dev/null)'"

# ── R3: inside the TTL, no GET ──
reset 10
apply
[ "$(gets)" = 0 ] && ok || bad "R3 GETs=$(gets) inside the TTL (want 0)"
[ "$V" = 0 ] && ok || bad "R3 value '$V' (want the cached 0)"

# ── R4: at the TTL edge, one GET ──
reset 60
apply
[ "$(gets)" = 1 ] && ok || bad "R4 GETs=$(gets) at age 60 (want 1)"
[ "$V" = 3 ] && ok || bad "R4 value '$V' (want 3)"

# ── R5: a miss inside the TTL holds the retry ──
reset 500 10
apply
[ "$(gets)" = 0 ] && ok || bad "R5 GETs=$(gets) with a 10 s old miss stamp (want 0)"
[ "$V" = 0 ] && ok || bad "R5 value '$V' (want the cached 0)"

echo "lane-env-refresh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
