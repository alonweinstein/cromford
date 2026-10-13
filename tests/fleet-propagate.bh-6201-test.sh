#!/bin/bash
# tests/fleet-propagate.bh-6201-test.sh — BH-6201: bin/fleet-propagate.sh
#   S1-S7  box sync never waits on a pool bake: a running bake makes only ITS
#          pool `busy`, the lane lock is released before the first bake, an
#          overlapping run syncs the boxes and defers its pools to the bake step
#          already running, and a drain never pulls the hub while one runs;
#   M1-M9  the dirty-mark rule (a newer or unknown mark is never lost);
#   L1-L12 the box-lag alert, R1-R2 its writer/reader round trip, C1 --check;
#   P1-P4  every bake logs its phases; no limit is raised.
#
# Same fixture as tests/fleet-propagate.bh-3680-test.sh (real git against a
# scratch origin, stubs through PATH and the scratch HARNESS), two boxes and
# two pools.
#
# Run from anywhere: tests/fleet-propagate.bh-6201-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
NOW=$(date +%s)
export HARNESS_LANE=test

H="$T/harness"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$T/bin"
cp "$DIR/bin/fleet-propagate.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
echo hub > "$H/state/box-id"
cat > "$H/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os - - 2 box-alpha 192.0.2.1
beta     Acme/beta     - - 4 box-beta  192.0.2.2
EOF
: > "$H/flags/fly-pool-app-alpha-os"
: > "$H/flags/fly-pool-app-beta"

cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_CALLS"
echo "${BOX_SHA:-cafe123456789}"; exit 0
EOF
# A bake already running: PGREP_ANY=1 matches any pattern, PGREP_MATCH=<pool>
# matches only a pattern that names that pool.
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
[ "${PGREP_ANY:-}" = 1 ] && { echo 4242; exit 0; }
if [ -n "${PGREP_MATCH:-}" ]; then
  case "$*" in *"$PGREP_MATCH"*) echo 4242; exit 0 ;; esac
fi
exit 1
EOF
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-l" ] && { cat "$LIVE_CRON" 2>/dev/null; exit 0; }
cp "$1" "$INSTALLED_CRON"; exit 0
EOF
printf '#!/bin/bash\necho sync >> "$SYNC_CALLS"\necho "synced (stub)"; exit 0\n' > "$H/bin/harness-sync.sh"
# The bake stub (bh-3680's, plus BAKE_PUSH_AT/BAKE_IMAGE_AT): BAKE_OUT and
# BAKE_SLEEP apply to alpha-os only. BAKE_PUSH=<pool> prints the push line at
# BAKE_PUSH_AT s and the image line at BAKE_IMAGE_AT s, then exits 0.
cat > "$H/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$BAKE_CALLS"
if [ "$1" = "${BAKE_PUSH:-}" ]; then
  sleep "${BAKE_PUSH_AT:-0}"
  echo "#33 pushing layer sha256:abc 9.5s done"
  sleep "$(( ${BAKE_IMAGE_AT:-0} - ${BAKE_PUSH_AT:-0} ))"
  echo "image: registry.fly.io/builder-$1:deployment-X"
  exit 0
fi
if [ "$1" = alpha-os ]; then
  [ -n "${BAKE_OUT:-}" ] && cat "$BAKE_OUT"
  [ -n "${BAKE_SLEEP:-}" ] && sleep "$BAKE_SLEEP"
fi
for F in ${BAKE_FAIL:-}; do [ "$1" = "$F" ] && { echo "Error: build failed (stub)"; exit 1; }; done
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$ALERTS"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$T/bin"/* "$H/bin"/*

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin" "$T/src/docs"
echo "echo v1" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/livecron"

FLY="$H/state/fly"
WORK="$H/state/fleet-propagate"
LOGF="$H/logs/fleet-propagate.log"
N=0
commit() { # commit [docs] — change bin/run-build.sh (or docs/x.md), one commit, push
  N=$((N+1))
  if [ "${1:-}" = docs ]; then echo "d$N" > "$T/src/docs/x.md"; else echo "v$N" > "$T/src/bin/run-build.sh"; fi
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "c$N" && git -C "$T/src" push -q origin main
}
# run [args] — one tick. RID names its own call files so a background run and a
# foreground run never share them.
run() {
  local R="${RID:-}"
  : > "$T/ssh$R.calls"; : > "$T/bake$R.calls"; : > "$T/alerts$R"; : > "$T/sync$R.calls"
  ( HARNESS="$H" HARNESS_CHECKOUT="$T/checkout" \
    FLEET_PROPAGATE_PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" \
    SSH_CALLS="$T/ssh$R.calls" BAKE_CALLS="$T/bake$R.calls" ALERTS="$T/alerts$R" SYNC_CALLS="$T/sync$R.calls" \
    LIVE_CRON="$T/livecron" INSTALLED_CRON="$T/installed.cron" \
    BOX_SHA="${BOX_SHA:-}" PGREP_ANY="${PGREP_ANY:-}" PGREP_MATCH="${PGREP_MATCH:-}" \
    BAKE_FAIL="${BAKE_FAIL:-}" BAKE_OUT="${BAKE_OUT:-}" BAKE_SLEEP="${BAKE_SLEEP:-}" BAKE_PUSH="${BAKE_PUSH:-}" \
    BAKE_PUSH_AT="${BAKE_PUSH_AT:-}" BAKE_IMAGE_AT="${BAKE_IMAGE_AT:-}" \
    POOL_IMAGE_MIN_AGE_MIN="" POOL_BAKE_TIMEOUT_S="${POOL_BAKE_TIMEOUT_S:-}" \
    POOL_BAKE_RETRY_MAX="${RETRY:-}" POOL_BAKE_PUSH_GRACE_S="${GRACE:-}" \
    PROPAGATE_BOX_LAG_ALERT_MIN="${LAGMIN:-}" \
    bash "$H/bin/fleet-propagate.sh" "$@" ) > "$T/out$R" 2>"$T/err$R"
}
cnt()    { grep -c . "$1" 2>/dev/null | head -1; }
nlog()   { cnt "$LOGF"; }
newlog() { tail -n +"$(( $1 + 1 ))" "$LOGF"; }  # newlog <lines-before>
jsonq()  { jq -r "$1" "$H/state/fleet-propagate.json" 2>/dev/null; }
settle() {
  mkdir -p "$FLY"
  echo $((NOW - 3600)) > "$FLY/alpha-os.baked-at"; echo $((NOW - 3600)) > "$FLY/beta.baked-at"
  rm -f "$FLY"/*.image-dirty "$FLY"/*.bake-retries
}
lagreset() { rm -f "$WORK/box-shas.tsv" "$WORK/boxes-behind-since" "$WORK/boxes-behind-alerted"; }
head_of() { git -C "$1" rev-parse HEAD; }
# hold_lock <lockfile> — a background holder; release_lock frees it.
HOLD_PID=""
hold_lock() {
  : > "$T/hold"; rm -f "$T/held"
  ( exec 8>"$1"; flock 8; : > "$T/held"; while [ -e "$T/hold" ]; do sleep 0.1; done ) &
  HOLD_PID=$!
  local i=0; while [ ! -e "$T/held" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
}
release_lock() { rm -f "$T/hold"; [ -n "$HOLD_PID" ] && wait "$HOLD_PID" 2>/dev/null; HOLD_PID=""; }

# First run records where the fleet is (no state yet => nothing propagates).
run

# ══ S1 a bake already running: the boxes still sync, the pools are busy ══════
settle; lagreset; commit
NEW=$(head_of "$T/src")
L0=$(nlog)
PGREP_ANY=1 run
[ "$(cnt "$T/ssh.calls")" = 2 ] && ok || bad "S1 2 ssh calls while a bake runs (got $(cnt "$T/ssh.calls")): $(newlog "$L0")"
grep -q 'DEFERRED (a fly-image-build.sh' <<<"$(newlog "$L0")" && bad "S1 a running bake must not defer the box sync: $(newlog "$L0")" || ok
tail -1 "$LOGF" | grep -q ' hub=ok boxes=2/2 ' && ok || bad "S1 last line hub=ok boxes=2/2: $(tail -1 "$LOGF")"
[ "$(jsonq '.pools["alpha-os"].status')" = busy ] && ok || bad "S1 alpha-os busy (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(jsonq '.pools.beta.status')" = busy ] && ok || bad "S1 beta busy (got $(jsonq '.pools.beta.status'))"
[ "$(cat "$FLY/alpha-os.image-dirty" 2>/dev/null)" = "$NEW" ] && ok || bad "S1 alpha-os marked dirty at NEW (got $(cat "$FLY/alpha-os.image-dirty" 2>/dev/null))"
[ "$(cnt "$T/bake.calls")" = 0 ] && ok || bad "S1 a busy pool is not baked (got $(cat "$T/bake.calls"))"
# S7 one combined alert, not a page
[ "$(cnt "$T/alerts")" = 1 ] && ok || bad "S7 S1 exactly one alert (got $(cnt "$T/alerts"): $(cat "$T/alerts"))"
grep -q -- '--critical' "$T/alerts" && bad "S7 S1 a busy pool must not page: $(cat "$T/alerts")" || ok

# ══ S2 a running bake of ONE pool makes only that pool busy ══════════════════
settle; commit
NEW=$(head_of "$T/src")
PGREP_MATCH=alpha-os run
[ "$(jsonq '.pools["alpha-os"].status')" = busy ] && ok || bad "S2 alpha-os busy (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(jsonq '.pools.beta.status')" = ok ] && ok || bad "S2 beta baked (got $(jsonq '.pools.beta.status'))"
[ "$(cat "$T/bake.calls")" = beta ] && ok || bad "S2 bake calls = beta only (got '$(cat "$T/bake.calls")')"
# S6 a normal tick with pools records the bake step
[ "$(jsonq .bake)" = done ] && ok || bad "S6 .bake done (got $(jsonq .bake))"
[ "$(jsonq .bake_sha)" = "$NEW" ] && ok || bad "S6 .bake_sha = NEW (got $(jsonq .bake_sha))"

# ══ S3/S4 a slow bake never holds the next box sync ═════════════════════════
settle; lagreset; commit
SHA1=$(head_of "$T/src"); S1_7=${SHA1:0:7}
L0=$(nlog)
RID=1 BAKE_SLEEP=20 POOL_BAKE_TIMEOUT_S=10 GRACE=0 run &
RUN1=$!
i=0
while ! grep -qF "..$S1_7 hub=ok boxes=2/2 images=pending(2)" <<<"$(newlog "$L0")" && [ "$i" -lt 80 ]; do sleep 0.1; i=$((i+1)); done
newlog "$L0" | grep -qF "..$S1_7 hub=ok boxes=2/2 images=pending(2)" && ok \
  || bad "S3 within 8 s the sync line says images=pending(2): $(newlog "$L0")"
flock -n "$H/locks/fleet-propagate.lock" true && ok || bad "S3 the lane lock is free while run 1 bakes"
commit
SHA2=$(head_of "$T/src"); S2_7=${SHA2:0:7}
run
kill -0 "$RUN1" 2>/dev/null && ok || bad "S3 fixture: run 1 must still be baking while run 2 runs"
[ "$(cnt "$T/ssh.calls")" = 2 ] && ok || bad "S3 run 2 syncs 2 boxes while run 1 bakes (got $(cnt "$T/ssh.calls"))"
grep -F "..$S2_7 " "$LOGF" | tail -1 | grep -q 'hub=ok boxes=2/2 images=deferred(2)' && ok \
  || bad "S3 run 2's line says images=deferred(2): $(grep -F "..$S2_7 " "$LOGF")"
[ "$(jsonq .last_sha)" = "$SHA2" ] && ok || bad "S3 .last_sha = sha2 after run 2 (got $(jsonq .last_sha))"
[ "$(jsonq .bake)" = deferred ] && ok || bad "S6 a tick with the bake lock held records .bake deferred (got $(jsonq .bake))"
[ "$(cnt "$T/alerts")" = 1 ] && ok || bad "S7 run 2 exactly one alert (got $(cnt "$T/alerts"): $(cat "$T/alerts"))"
grep -q -- '--critical' "$T/alerts" && bad "S7 run 2 a deferred bake must not page: $(cat "$T/alerts")" || ok
grep -qF "2 pool images deferred to the bake step already running (marked dirty at $S2_7)" "$T/alerts" && ok \
  || bad "S3 run 2's alert names the deferral: $(cat "$T/alerts")"
[ "$(cnt "$T/bake.calls")" = 0 ] && ok || bad "S3 run 2 bakes nothing (got $(cat "$T/bake.calls"))"
wait "$RUN1"
[ "$(jsonq .last_sha)" = "$SHA2" ] && ok || bad "S3 run 1's merge must not move .last_sha back (got $(jsonq .last_sha))"
grep -F "..$S1_7 " "$LOGF" | tail -1 | grep -q 'boxes=2/2' && ok || bad "S3 run 1's final line boxes=2/2: $(grep -F "..$S1_7 " "$LOGF" | tail -1)"
grep -F "..$S1_7 " "$LOGF" | tail -1 | grep -qF 'failed=alpha-os(timeout)' && ok \
  || bad "S3 run 1's final line failed=alpha-os(timeout): $(grep -F "..$S1_7 " "$LOGF" | tail -1)"
[ "$(cat "$FLY/alpha-os.image-dirty" 2>/dev/null)" = "$SHA2" ] && ok || bad "S4 alpha-os.image-dirty kept at sha2 (got $(cat "$FLY/alpha-os.image-dirty" 2>/dev/null))"
[ "$(cat "$FLY/beta.image-dirty" 2>/dev/null)" = "$SHA2" ] && ok || bad "S4 beta.image-dirty kept at sha2 (got $(cat "$FLY/beta.image-dirty" 2>/dev/null))"

# ══ S5 a drain while a bake step runs exits before the hub step ══════════════
settle; commit
run   # baked at this sha, clean
echo "$(head_of "$T/src")" > "$FLY/alpha-os.image-dirty"
echo $((NOW - 7200)) > "$FLY/alpha-os.baked-at"
hold_lock "$H/locks/fleet-propagate-bake.lock"
L0=$(nlog)
run
release_lock
newlog "$L0" | grep -q 'drain deferred: a bake step is running' && ok || bad "S5 drain deferred logged: $(newlog "$L0")"
[ "$(cnt "$T/sync.calls")" = 0 ] && ok || bad "S5 harness-sync not called (got $(cnt "$T/sync.calls"))"
[ "$(cnt "$T/bake.calls")" = 0 ] && ok || bad "S5 no bake (got $(cat "$T/bake.calls"))"
[ -f "$FLY/alpha-os.image-dirty" ] && ok || bad "S5 the dirty mark stays for the next tick"

# ══ M1-M9 the dirty-mark rule ════════════════════════════════════════════════
git -C "$T/checkout" fetch -q origin && git -C "$T/checkout" merge -q --ff-only origin/main 2>/dev/null
A=$(git -C "$T/checkout" rev-parse HEAD~2); X=$(git -C "$T/checkout" rev-parse HEAD~1); Y=$(git -C "$T/checkout" rev-parse HEAD)
UNK=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
awk '/^# >>> dirty-marker \(BH-6201\)/,/^# <<< dirty-marker/' "$DIR/bin/fleet-propagate.sh" > "$T/dirty.sh"
MD="$T/m"; mkdir -p "$MD"
mark() { ( FLY_STATE="$MD" CHECKOUT="$T/checkout"; . "$T/dirty.sh"; fp_mark_dirty p "$1" ); cat "$MD/p.image-dirty" 2>/dev/null; }
clear_() { ( FLY_STATE="$MD" CHECKOUT="$T/checkout"; . "$T/dirty.sh"; fp_clear_dirty p "$1" ); [ -f "$MD/p.image-dirty" ] && echo kept || echo removed; }
rm -f "$MD/p.image-dirty";   [ "$(mark "$X")" = "$X" ] && ok || bad "M1 absent + mark X -> X"
echo "$A" > "$MD/p.image-dirty"; [ "$(mark "$X")" = "$X" ] && ok || bad "M2 older ancestor replaced by X"
echo "$X" > "$MD/p.image-dirty"; [ "$(mark "$X")" = "$X" ] && ok || bad "M3 same sha stays X"
echo "$Y" > "$MD/p.image-dirty"; [ "$(mark "$X")" = "$Y" ] && ok || bad "M4 a newer mark Y is kept"
echo "$UNK" > "$MD/p.image-dirty"; [ "$(mark "$X")" = "$UNK" ] && ok || bad "M5 an unknown mark is kept"
echo "$X" > "$MD/p.image-dirty"; [ "$(clear_ "$X")" = removed ] && ok || bad "M6 clear X with X -> removed"
echo "$A" > "$MD/p.image-dirty"; [ "$(clear_ "$X")" = removed ] && ok || bad "M7 clear X with an ancestor -> removed"
echo "$Y" > "$MD/p.image-dirty"; [ "$(clear_ "$X")" = kept ] && ok || bad "M8 clear X with a newer Y -> kept"
# M9: an unknown mark is stale (every real mark is a sha this checkout fetched),
# so a finished bake removes it — one extra bake, never one every window. The
# plan said "kept"; tests/fleet-propagate.bh-821-test.sh §B3 pins removal.
echo "$UNK" > "$MD/p.image-dirty"; [ "$(clear_ "$X")" = removed ] && ok || bad "M9 clear X with an unknown mark -> removed"

# ══ L1-L11 the box-lag alert, with the lane lock held (the incident shape) ═══
settle; lagreset
commit; run                       # the hub checkout is now at a bin/ commit
HUB=$(head_of "$T/checkout"); HUB7=${HUB:0:7}; PARENT=$(git -C "$T/checkout" rev-parse HEAD~1)
rows() { # rows <alpha-sha> [<beta-sha>|none]
  printf 'box-alpha\t%s\t0\t%s\n' "$1" "$NOW" > "$WORK/box-shas.tsv"
  [ "${2:-$1}" = none ] || printf 'box-beta\t%s\t0\t%s\n' "${2:-$1}" "$NOW" >> "$WORK/box-shas.tsv"
}
since() { echo "$(( $(date +%s) - $1 )) ${HUB7}" > "$WORK/boxes-behind-since"; }
hold_lock "$H/locks/fleet-propagate.lock"
# L1
lagreset; run
[ "$(cnt "$T/alerts")" = 0 ] && ok || bad "L1 no tsv: 0 alerts (got $(cat "$T/alerts"))"
[ ! -f "$WORK/boxes-behind-since" ] && ok || bad "L1 no tsv: no since file"
# L11 behind, since absent -> since written, no alert
lagreset; rows "$PARENT"; run
[ "$(cnt "$T/alerts")" = 0 ] && ok || bad "L11 0 alerts on the first behind sighting (got $(cat "$T/alerts"))"
[ "$(cut -d' ' -f2 "$WORK/boxes-behind-since" 2>/dev/null)" = "$HUB7" ] && ok || bad "L11 since names the hub sha7 (got '$(cat "$WORK/boxes-behind-since" 2>/dev/null)')"
# L2 under the threshold
lagreset; rows "$PARENT"; since 1170; run
[ "$(cnt "$T/alerts")" = 0 ] && ok || bad "L2 19.5m behind: 0 alerts (got $(cat "$T/alerts"))"
# L3/L9 over the threshold, while the lane lock is held
since 1830
flock -n "$H/locks/fleet-propagate.lock" true && bad "L9 fixture: the lane lock must be held" || ok
run
[ "$(cnt "$T/alerts")" = 1 ] && ok || bad "L3/L9 exactly one alert past 30m with the lane lock held (got $(cnt "$T/alerts"): $(cat "$T/alerts"))"
grep -q -- '^--critical --id fleet-propagate-boxes-behind fleet-propagate ' "$T/alerts" && ok || bad "L3 critical with the lag id: $(cat "$T/alerts")"
grep -q 'box-alpha' "$T/alerts" && grep -q 'box-beta' "$T/alerts" && ok || bad "L3 both boxes named: $(cat "$T/alerts")"
grep -qF "$HUB7" "$T/alerts" && ok || bad "L3 the hub sha7 named: $(cat "$T/alerts")"
[ -f "$WORK/boxes-behind-alerted" ] && ok || bad "L3 boxes-behind-alerted written"
# L4 still behind -> not repeated
run
[ "$(cnt "$T/alerts")" = 0 ] && ok || bad "L4 the alert is not repeated (got $(cat "$T/alerts"))"
# L6 caught up -> one resolve, both files removed; again -> nothing
rows "$HUB"; run
[ "$(cnt "$T/alerts")" = 1 ] && ok || bad "L6 one resolve (got $(cnt "$T/alerts"): $(cat "$T/alerts"))"
grep -q -- '^--log-only --resolve --id fleet-propagate-boxes-behind fleet-propagate ' "$T/alerts" && ok || bad "L6 resolve shape: $(cat "$T/alerts")"
[ ! -f "$WORK/boxes-behind-since" ] && [ ! -f "$WORK/boxes-behind-alerted" ] && ok || bad "L6 both lag files removed"
run
[ "$(cnt "$T/alerts")" = 0 ] && ok || bad "L6 a second caught-up check sends nothing (got $(cat "$T/alerts"))"
# L7 off
lagreset; rows "$PARENT"; since 7200; LAGMIN=0 run
[ "$(cnt "$T/alerts")" = 0 ] && ok || bad "L7 PROPAGATE_BOX_LAG_ALERT_MIN=0 is off (got $(cat "$T/alerts"))"
# L8 a bad knob logs and uses 30
lagreset; rows "$PARENT"; since 1830; LAGMIN=abc run
grep -qF 'PROPAGATE_BOX_LAG_ALERT_MIN=abc is not a number of minutes — using 30' "$LOGF" && ok || bad "L8 the bad knob is logged"
[ "$(cnt "$T/alerts")" = 1 ] && ok || bad "L8 a bad knob uses 30 (got $(cat "$T/alerts"))"
# L10 a registry box with no row is behind
lagreset; rows "$HUB" none; since 1830; run
grep -q 'box-beta' "$T/alerts" && ok || bad "L10 the box with no row is named: $(cat "$T/alerts")"
grep -q 'box-alpha' "$T/alerts" && bad "L10 a current box is not named: $(cat "$T/alerts")" || ok
# L12 an empty registry read cannot judge: no resolve, the lag files stay
lagreset; rows "$PARENT"; since 1830; run
[ -f "$WORK/boxes-behind-alerted" ] && ok || bad "L12 fixture: the alert is open"
rows "$HUB"; mv "$H/fleet.conf" "$T/fleet.conf.away"; run; mv "$T/fleet.conf.away" "$H/fleet.conf"
[ "$(cnt "$T/alerts")" = 0 ] && ok || bad "L12 an empty registry sends no resolve (got $(cat "$T/alerts"))"
[ -f "$WORK/boxes-behind-since" ] && [ -f "$WORK/boxes-behind-alerted" ] && ok || bad "L12 an empty registry keeps both lag files"
release_lock
# L5 behind on docs/ only -> not behind (BH-5247 rule)
lagreset; commit docs
git -C "$T/checkout" pull -q --ff-only origin main
DOCHUB=$(head_of "$T/checkout")
rows "$HUB"; echo "$(( $(date +%s) - 1830 )) ${DOCHUB:0:7}" > "$WORK/boxes-behind-since"
hold_lock "$H/locks/fleet-propagate.lock"
run
[ "$(cnt "$T/alerts")" = 0 ] && ok || bad "L5 a lag on docs/ only is no lag (got $(cat "$T/alerts"))"
[ ! -f "$WORK/boxes-behind-since" ] && ok || bad "L5 boxes-behind-since removed"
release_lock

# ══ R1/R2 the sync step writes box-shas.tsv, the lag check reads it ══════════
settle; lagreset; commit
BOX_SHA=$(head_of "$T/src") run
[ "$(grep -cP '^box-(alpha|beta)\t[0-9a-f]{40}\t0\t[0-9]+$' "$WORK/box-shas.tsv" 2>/dev/null)" = 2 ] && ok \
  || bad "R1 two rows with a 40-hex sha and rc 0: $(cat "$WORK/box-shas.tsv" 2>/dev/null)"
hold_lock "$H/locks/fleet-propagate.lock"; run; release_lock
[ ! -f "$WORK/boxes-behind-since" ] && ok || bad "R1 current boxes write no since file"
settle; lagreset; commit
run
hold_lock "$H/locks/fleet-propagate.lock"; run; release_lock
[ -f "$WORK/boxes-behind-since" ] && ok || bad "R2 a garbage box sha is behind"
[ "$(cnt "$T/alerts")" = 0 ] && ok || bad "R2 no alert on the first sighting (got $(cat "$T/alerts"))"

# ══ C1 --check prints the lag and writes nothing ═════════════════════════════
snapshot() { find "$H/state" "$H/logs" -type f -exec md5sum {} + 2>/dev/null | sort; }
BEFORE=$(snapshot)
run --check
grep -q 'box lag:' "$T/out" && ok || bad "C1 --check prints box lag: $(cat "$T/out")"
[ "$(snapshot)" = "$BEFORE" ] && ok || bad "C1 --check wrote under \$H/state or \$H/logs"

# ══ P1-P4 bake phases ═══════════════════════════════════════════════════════
settle; lagreset; commit
L0=$(nlog)
BAKE_PUSH=alpha-os BAKE_PUSH_AT=2 BAKE_IMAGE_AT=3 GRACE=0 run
newlog "$L0" | grep -qE 'pool alpha-os: bake phases build=[0-9]+s push=[0-9]+s record=[0-9-]+s total=[0-9]+s rc=0' && ok \
  || bad "P1 one phases line at grace 0: $(newlog "$L0")"
[ "$(newlog "$L0" | grep -c 'pool alpha-os: bake phases')" = 1 ] && ok || bad "P1 exactly one phases line for alpha-os"
case "$(jsonq '.pools["alpha-os"].phases')" in build=*) ok ;; *) bad "P2 .pools[alpha-os].phases (got $(jsonq '.pools["alpha-os"].phases'))" ;; esac
[ "$(jq -r '.pools.beta.phases|type' "$H/state/fleet-propagate.json" 2>/dev/null)" = string ] && ok || bad "P2 .pools.beta.phases is a string"
settle; commit
S7=$(head_of "$T/src" | cut -c1-7)
printf 'step 1\n#9 [warm 4/5] RUN git clone\n' > "$T/p3.out"
L0=$(nlog)
RETRY=0 BAKE_OUT="$T/p3.out" BAKE_SLEEP=30 POOL_BAKE_TIMEOUT_S=1 GRACE=60 run
newlog "$L0" | grep 'pool alpha-os: bake phases' | grep -q 'push=- .*rc=124' && ok || bad "P3 killed in build: push=- rc=124: $(newlog "$L0" | grep 'bake phases')"
grep -q 'phases=' "$H/logs/fly-image-build/alpha-os-$S7.log" 2>/dev/null && ok || bad "P3 the capture header has phases="
[ "$(grep -c 'POOL_BAKE_TIMEOUT_S:-1800' "$DIR/bin/fleet-propagate.sh")" -ge 1 ] && ok || bad "P4 the 1800 s default stays in the script"
[ "$(jq -r '.knobs[]|select(.env=="POOL_BAKE_TIMEOUT_S")|.default' "$DIR/catalog/lanes.d/fleet-propagate.json")" = 1800 ] && ok || bad "P4 the registry default stays 1800"

echo "fleet-propagate.bh-6201-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
