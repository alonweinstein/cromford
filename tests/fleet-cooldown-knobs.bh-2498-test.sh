#!/bin/bash
# tests/fleet-cooldown-knobs.bh-2498-test.sh — BH-2498: the follow-ups from the
# r2 review of #2476. Sources the REAL seam (bin/lib/fleet-cooldown.sh) and the
# REAL cooldown_* verbs; only _jobs_req is a stub, the same one
# tests/fleet-cooldown-cache.bh-2353-test.sh uses. Settings rows come from a
# hand-written box settings cache ($T/state/settings-cache.json) read through
# the real bin/lib/lane-gate.sh, against a registry rendered from this
# checkout's catalog/lanes.d (LANE_REGISTRY).
#
#   K1 a row lib.fleet-cooldown.fleet_cooldown_db=0 turns the fleet half off
#   K2 a row …fleet_cooldown_clear_guard_s=0 writes no tomb on a lane clear
#   K3 a row …fleet_cooldown_cache_s=0 beats env FLEET_COOLDOWN_CACHE_S=20
#   K4 a settings outage changes nothing: no cache + GET fails = env/default;
#      a stale cached row still wins; no lane-gate.sh = env/default; the caller
#      under set -euo pipefail keeps running and sees no output
#   K5 no row: env wins (a), no row and no env: the code defaults (b)
#   K6 sourcing the seam reads, writes and prints nothing
#   K7 the registry: DB, CACHE_S, CLEAR_GUARD_S settable, STORE not
#   K8 a row for FLEET_COOLDOWN_STORE is ignored (the worker stays the backend)
#   K9 a row that is not a number falls through to env, never to a guess
#   G1 guard = min(CLEAR_GUARD_S, LANE_DOWN_TTL_S): TTL 60 shows a re-down at +90
#   G2 TTL unset: the guard is 600, a row at the hide mark stays hidden
#   G3 TTL garbage or 0 falls back to 7200, never to a 0 guard
#   T1 a tomb older than 2x the guard whose hide mark is past is removed on a clear
#   T2 a tomb younger than 2x the guard is kept
#   T3 an old tomb whose hide mark is still ahead is kept and still hides
#   T4 no root (neither HARNESS nor H): no tomb glob, no settings read, a set -e
#      caller keeps running
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/fleet-cooldown-knobs.bh-2498-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/fleet-cooldown.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

unset FLEET_COOLDOWN_DB FLEET_COOLDOWN_STORE FLEET_COOLDOWN_CACHE_S FLEET_COOLDOWN_CLEAR_GUARD_S \
      LANE_DOWN_TTL_S HARNESS_SECRET JOBS_URL LANE_GATE_CACHE_S LANE_GATE_DISABLE
export HARNESS="$T" HARNESS_ENV_DIR="$T/env" JOBS_BOX=testbox
mkdir -p "$T/logs" "$T/ans"
FUT=4102444800
NOW=$(date +%s)
export LANE_GATE_NOW=$NOW
CACHE="$T/state/fleet-cooldown"
SET="$T/state/settings-cache.json"
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "registry did not compose"
export LANE_REGISTRY="$REG"

cat > "$T/prelude.sh" <<EOF
. "\${FCD_LIB:-$LIB}" || exit 99
. "$DIR/bin/lib/jobs/machines.sh" || exit 99
_jobs_req() {
  local key; key=\$(printf '%s' "\$1 \$2" | tr -c 'A-Za-z0-9' _)
  printf '%s %s %s\n' "\$1" "\$2" "\${3:-}" >> "$T/calls"
  cat "$T/ans/\$key" 2>/dev/null
  return "\$(cat "$T/ans/\$key.rc" 2>/dev/null || echo 0)"
}
EOF
run() { bash -c ". '$T/prelude.sh'; $1" 2>&1; }
answer() { printf '%s' "$2" > "$T/ans/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; }
answer_rc() { printf '%s' "$2" > "$T/ans/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _).rc"; }
calls() { cat "$T/calls" 2>/dev/null; }
# settings <fetched_at> <json values>: the box settings cache lane-gate reads.
settings() { mkdir -p "$T/state"; printf '{"fetched_at":%s,"values":%s,"seeded":{}}' "$1" "$2" > "$SET"; }
# reset: no calls, no answers, no fleet-cooldown state, a FRESH settings cache
# with no rows (so no case makes a GET /api/settings unless it asks for one).
reset() {
  rm -f "$T/calls" "$T/ans"/* "$T/store.tsv" "$T/store.tsv.lock"
  scratch_rm "$T/state"
  settings "$NOW" '{}'
  answer "GET /api/cooldowns?kind=account" '{"rows":[],"truncated":false}'
  answer "GET /api/cooldowns?kind=lane" '{"rows":[],"truncated":false}'
  answer "POST /api/cooldowns" '{"ok":true,"row":{}}'
  answer "POST /api/cooldowns/clear" '{"cleared":1}'
}
puts() { calls | grep -c '^POST /api/cooldowns ' ; }
# hide <vendor> <subject>: field 3 of the lane's tomb, or "none".
hide() { local f="$CACHE/cleared.lane.$1.$2"; if [ -f "$f" ]; then cut -f3 "$f"; else echo none; fi; }
near() { [ "$1" != none ] && [ "$1" -ge $(($2 - 5)) ] && [ "$1" -le $(($2 + 5)) ]; }
store_row() { printf 'lane\t%s\t%s\t%s\t\tr\thub\t1\n' "$1" "$2" "$3" >> "$T/store.tsv"; }

# ---------- K1 a DB row of 0 is the kill switch -------------------------------
reset; settings "$NOW" '{"lib.fleet-cooldown.fleet_cooldown_db":"0"}'
out=$(run "fcd_put account claude a1 $FUT; rc=0; fcd_live account claude a1 || rc=\$?; echo \$rc")
[ "$out" = 2 ] && ok || bad "K1 fcd_live with DB row 0: want rc 2, got [$out]"
[ "$(puts)" = 0 ] && ok || bad "K1 a put was sent with DB row 0: $(calls)"

# ---------- K2 a CLEAR_GUARD_S row of 0 writes no tomb -------------------------
reset; settings "$NOW" '{"lib.fleet-cooldown.fleet_cooldown_clear_guard_s":"0"}'
run 'fcd_clear lane claude box1' >/dev/null
[ -z "$(ls "$CACHE"/cleared.lane.* 2>/dev/null)" ] && ok || bad "K2 guard row 0 still wrote a tomb: $(ls "$CACHE")"

# ---------- K3 a CACHE_S row beats env ------------------------------------------
reset; settings "$NOW" '{"lib.fleet-cooldown.fleet_cooldown_cache_s":"0"}'
FLEET_COOLDOWN_CACHE_S=20 run 'fcd_list account' >/dev/null
[ ! -e "$CACHE/cache.account.tsv" ] && ok || bad "K3 row CACHE_S=0 lost to env 20: a box cache was written"
[ "$(calls | grep -c '^GET /api/cooldowns?kind=account')" = 1 ] && ok || bad "K3 the list was not read: $(calls)"

# ---------- K4 a settings outage never changes behaviour ------------------------
# a: no box settings cache, the worker refuses GET /api/settings.
reset; rm -f "$SET"; answer_rc "GET /api/settings" 7
out=$(run "set -euo pipefail; fcd_put account claude a1 $FUT; fcd_list account; echo reached")
[ "$out" = reached ] && ok || bad "K4a caller output under set -euo pipefail: [$out]"
[ "$(puts)" = 1 ] && ok || bad "K4a the outage switched the put off: $(calls)"
[ -f "$CACHE/cache.account.tsv" ] && ok || bad "K4a the outage switched the box cache off (default 20)"
# b: the worker still refuses, the box cache is an hour old and holds DB=0: the
# cached row is the last good answer and still wins (lane-gate's outage rung).
reset; settings $((NOW - 3600)) '{"lib.fleet-cooldown.fleet_cooldown_db":"0"}'; answer_rc "GET /api/settings" 7
out=$(run "set -euo pipefail; fcd_put account claude a1 $FUT; echo reached")
[ "$out" = reached ] && ok || bad "K4b caller output: [$out]"
[ "$(puts)" = 0 ] && ok || bad "K4b a stale cached DB=0 row did not hold during the outage: $(calls)"
[ "$(calls | grep -c '^GET /api/settings')" -ge 1 ] && ok || bad "K4b the stale cache was not refreshed first: $(calls)"
# c: the seam without lane-gate.sh beside it (a DB=0 row that nothing can read).
reset; settings "$NOW" '{"lib.fleet-cooldown.fleet_cooldown_db":"0"}'
mkdir -p "$T/bare"; cp "$LIB" "$T/bare/fleet-cooldown.sh"
out=$(FCD_LIB="$T/bare/fleet-cooldown.sh" run "set -euo pipefail; fcd_put account claude a1 $FUT; echo reached")
[ "$out" = reached ] && ok || bad "K4c caller output without lane-gate: [$out]"
[ "$(puts)" = 1 ] && ok || bad "K4c no lane-gate did not fall back to env/default (put not sent): $(calls)"

# ---------- K5 then env, then default -------------------------------------------
reset
FLEET_COOLDOWN_CACHE_S=0 run 'fcd_list account' >/dev/null
[ ! -e "$CACHE/cache.account.tsv" ] && ok || bad "K5a env CACHE_S=0 with no row still wrote a box cache"
reset
t0=$(date +%s)
run 'fcd_list account; fcd_clear lane claude box1' >/dev/null
[ -f "$CACHE/cache.account.tsv" ] && ok || bad "K5b no row, no env: no box cache (default 20)"
h=$(hide claude box1)
near "$h" $((t0 + 600)) && ok || bad "K5b default guard: hide [$h], want ~$((t0 + 600))"

# ---------- K6 sourcing is side-effect free -------------------------------------
mkdir -p "$T/k6"; rm -f "$T/calls"
out=$(cd "$T/k6" && HARNESS="$T/k6" bash -c 'set -euo pipefail; . "$1"; . "$1"' _ "$LIB" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ -z "$(ls -A "$T/k6")" ] && [ -z "$(calls)" ] && ok \
  || bad "K6 source rc=$rc out=[$out] files=$(ls -A "$T/k6") calls=$(calls)"

# ---------- K7 the registry -----------------------------------------------------
for e in FLEET_COOLDOWN_DB FLEET_COOLDOWN_CACHE_S FLEET_COOLDOWN_CLEAR_GUARD_S FLEET_COOLDOWN_STORE; do
  want=true; [ "$e" = FLEET_COOLDOWN_STORE ] && want=false
  got=$(jq -r --arg e "$e" '[.libs[]? | select(.id=="fleet-cooldown") | .knobs[] | select(.env==$e) | .settable][0]' "$REG" 2>/dev/null)
  [ "$got" = "$want" ] && ok || bad "K7 $e settable: want $want, got [$got]"
done

# ---------- K8 a STORE row is ignored -------------------------------------------
reset; settings "$NOW" "{\"lib.fleet-cooldown.fleet_cooldown_store\":\"$T/k8store.tsv\"}"
run "fcd_list account; fcd_put account claude a1 $FUT" >/dev/null
[ "$(calls | grep -c '^GET /api/cooldowns?kind=account')" -ge 1 ] && ok || bad "K8 the worker was not the backend: $(calls)"
[ ! -e "$T/k8store.tsv" ] && ok || bad "K8 a settings row redirected the store to $T/k8store.tsv"

# ---------- K9 a garbage row falls through to env -------------------------------
reset; settings "$NOW" '{"lib.fleet-cooldown.fleet_cooldown_cache_s":"abc","lib.fleet-cooldown.fleet_cooldown_clear_guard_s":"x1"}'
FLEET_COOLDOWN_CACHE_S=0 FLEET_COOLDOWN_CLEAR_GUARD_S=0 run 'fcd_list account; fcd_clear lane claude box1' >/dev/null
[ ! -e "$CACHE/cache.account.tsv" ] && ok || bad "K9 a garbage CACHE_S row did not fall through to env 0"
[ -z "$(ls "$CACHE"/cleared.lane.* 2>/dev/null)" ] && ok || bad "K9 a garbage GUARD row did not fall through to env 0"

# ---------- G1 the guard is capped at LANE_DOWN_TTL_S ---------------------------
reset; export FLEET_COOLDOWN_STORE="$T/store.tsv"
t0=$(date +%s)
LANE_DOWN_TTL_S=60 run 'fcd_clear lane claude b1' >/dev/null
h=$(hide claude b1)
[ "$h" != none ] && [ "$h" -le $((t0 + 65)) ] && ok || bad "G1 TTL 60, guard 600: hide [$h], want <= $((t0 + 65))"
store_row claude b1 $((t0 + 90))
out=$(LANE_DOWN_TTL_S=60 run 'rc=0; fcd_live lane claude b1 || rc=$?; echo "live=$rc"; fcd_list lane | cut -f1,2')
[ "$out" = "$(printf 'live=0\nclaude\tb1')" ] && ok || bad "G1 a re-down past the TTL was hidden: [$out]"

# ---------- G2 TTL unset: guard 600, a row at the mark stays hidden -------------
reset
t0=$(date +%s)
run 'fcd_clear lane claude b2' >/dev/null
h=$(hide claude b2)
near "$h" $((t0 + 600)) && ok || bad "G2 TTL unset: hide [$h], want ~$((t0 + 600))"
[ "$h" != none ] && store_row claude b2 "$h"
out=$(run 'rc=0; fcd_live lane claude b2 || rc=$?; echo "live=$rc"; fcd_list lane')
[ "$out" = live=1 ] && ok || bad "G2 a row at the hide mark showed: [$out]"

# ---------- G3 a garbage or 0 TTL never shrinks the guard -----------------------
for ttl in abc 0; do
  reset
  t0=$(date +%s)
  LANE_DOWN_TTL_S=$ttl run 'fcd_clear lane claude b3' >/dev/null
  h=$(hide claude b3)
  near "$h" $((t0 + 600)) && ok || bad "G3 TTL [$ttl]: hide [$h], want ~$((t0 + 600))"
done

# ---------- T1..T3 tomb GC ------------------------------------------------------
tomb() { # tomb <vendor> <subject> <hide> <mtime>
  mkdir -p "$CACHE"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$CACHE/cleared.lane.$1.$2"
  touch -d "@$4" "$CACHE/cleared.lane.$1.$2"
}
reset
t0=$(date +%s)
tomb claude old $((t0 - 10)) $((t0 - 1300))       # T1: old and expired
tomb claude young $((t0 - 10)) $((t0 - 100))      # T2: expired but young
tomb claude t3 $((t0 + 3000)) $((t0 - 1300))      # T3: old but still guarding
store_row claude t3 $((t0 + 2000))
run 'fcd_clear lane claude other' >/dev/null
[ ! -e "$CACHE/cleared.lane.claude.old" ] && ok || bad "T1 an old expired tomb was not collected"
[ -e "$CACHE/cleared.lane.claude.young" ] && ok || bad "T2 a tomb younger than 2x the guard was collected"
[ -e "$CACHE/cleared.lane.claude.t3" ] && ok || bad "T3 an old tomb still guarding was collected"
[ -e "$CACHE/cleared.lane.claude.other" ] && ok || bad "T1 the clear did not write its own tomb"
out=$(run 'rc=0; fcd_live lane claude t3 || rc=$?; echo "live=$rc"; fcd_list lane')
[ "$out" = live=1 ] && ok || bad "T3 the guarded row showed after the GC: [$out]"
# A guard of 0 still drains old tombs.
reset
tomb claude old $((t0 - 10)) $((t0 - 1300))
FLEET_COOLDOWN_CLEAR_GUARD_S=0 run 'fcd_clear lane claude other' >/dev/null
[ ! -e "$CACHE/cleared.lane.claude.old" ] && ok || bad "T1 guard 0 did not drain an old expired tomb"

# ---------- T4 no root: no GC glob, no settings read, a set -e caller lives ------
# Neither HARNESS nor H: the seam has no state dir, so the GC globs nothing and
# the knobs never reach lane-gate (whose root falls back to /root/harness).
reset; mkdir -p "$T/t4/state/fleet-cooldown"
printf 'claude\told\t1\n' > "$T/t4/state/fleet-cooldown/cleared.lane.claude.old"
touch -d "@$((t0 - 99999))" "$T/t4/state/fleet-cooldown/cleared.lane.claude.old"
out=$(cd "$T/t4" && env -u HARNESS -u H bash -xc \
  ". '$T/prelude.sh'; set -euo pipefail; fcd_clear lane claude t4 || true; fcd_list lane; echo reached" 2>"$T/t4.trace")
[ "$out" = reached ] && ok || bad "T4 set -e caller with no root: [$out]"
! grep -q 'cleared\.lane\.' "$T/t4.trace" && ok || bad "T4 no root still touched a tomb path: $(grep 'cleared\.lane\.' "$T/t4.trace" | head -3)"
! grep -q 'lib_env_apply\|settings-cache' "$T/t4.trace" && ok || bad "T4 no root still read settings: $(grep 'lib_env_apply\|settings-cache' "$T/t4.trace" | head -3)"
[ -e "$T/t4/state/fleet-cooldown/cleared.lane.claude.old" ] && ok || bad "T4 no root collected a tomb relative to the cwd"
unset FLEET_COOLDOWN_STORE

echo "fleet-cooldown-knobs.bh-2498: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
