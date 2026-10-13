#!/bin/bash
# tests/box-ops.bh-2518-test.sh — the per-box executor lane (BH-2660, BH-2518.2):
# bin/box-ops.sh claims this box's own box_commands rows from the jobs worker,
# runs each op under `timeout`, logs one line per command and posts the result.
#
# Runs the REAL bin/box-ops.sh, bin/jobs-client.sh (+ bin/lib/jobs/*),
# bin/lib/lane-gate.sh and the contract's bin/lib/box-ops-fly.sh in a scratch
# harness root. Stubbed: curl (answers the worker by path and logs every
# box-commands request to $T/requests.log), ssh and fly (touch a marker and
# fail), and $H/bin/{state-backup,harness-sync,cli-update,hub-lease,box-name}.sh.
#
# Cases L1-L8, K1, S1-S5, R1 and the in-suite mutations M1-M3 are the plan's
# acceptance tests (builds/cromford-BH-2660-*/plan.md).
#
# Run from anywhere: tests/box-ops.bh-2518-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/env" "$T/fakebin"
cp "$DIR/bin/box-ops.sh" "$H/bin/" || { echo "FAIL: missing bin/box-ops.sh"; exit 1; }
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || exit 1
# box-ops alerts go through bin/alert-line.sh (alert-writer ratchet); stage it
# and the state lib it sources so ALERTS.log lines still land in the scratch tree.
cp "$DIR/bin/alert-line.sh" "$H/bin/" || exit 1
cp "$DIR/bin/lib/alert-state.sh" "$H/bin/lib/" 2>/dev/null || true
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
for f in lane-gate lanes-registry env-path box-ops-fly; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/" || { echo "FAIL: missing bin/lib/$f.sh"; exit 1; }
done
cp "$H/bin/lib/box-ops-fly.sh" "$T/box-ops-fly.real"
: > "$H/env/global.env"
: > "$H/logs/ALERTS.log"

# ── the ops box-ops dispatches to ────────────────────────────────────────
cat > "$H/bin/state-backup.sh" <<'EOF'
#!/bin/bash
touch "$STUB_DIR/SB_CALLED"
[ -n "${SB_SLEEP:-}" ] && sleep "$SB_SLEEP"
[ -n "${SB_LOG:-}" ] && printf '2026-09-26T00:00:00Z [state-backup] %s\n' "$SB_LOG" >> "$HARNESS/logs/state-backup.log"
[ -n "${SB_ALERT:-}" ] && printf '%s\n' "$SB_ALERT" >> "$HARNESS/logs/ALERTS.log"
if [ -n "${SB_STAMP:-}" ]; then
  ts=$SB_STAMP; [ "$ts" = now ] && ts=$(date -u +%Y%m%dT%H%M%SZ)
  printf '{"ts":"%s","key":"b1/%s.tar.zst"}\n' "$ts" "$ts" > "$HARNESS/state/backup-last.json"
fi
exit "${SB_RC:-0}"
EOF
cat > "$H/bin/harness-sync.sh" <<'EOF'
#!/bin/bash
touch "$STUB_DIR/HS_CALLED"
# a daemonised grandchild: it keeps every fd this stub was handed
[ -n "${HS_BG:-}" ] && { sleep "$HS_BG" >/dev/null 2>&1 </dev/null & }
[ -n "${HS_SLEEP:-}" ] && sleep "$HS_SLEEP"
printf '%s' "${HS_OUT:-}"
exit "${HS_RC:-0}"
EOF
cat > "$H/bin/cli-update.sh" <<'EOF'
#!/bin/bash
touch "$STUB_DIR/CU_CALLED"
printf '%s' "${CU_OUT:-}"
exit "${CU_RC:-0}"
EOF
cat > "$H/bin/hub-lease.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = check ] || exit 2
exit "${LEASE_RC:-1}"
EOF
cat > "$H/bin/box-name.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "${BOXNAME-b1}"
EOF
chmod +x "$H"/bin/*.sh

cat > "$T/fakebin/ssh" <<'EOF'
#!/bin/bash
touch "$STUB_DIR/SSH_CALLED"; exit 1
EOF
cat > "$T/fakebin/fly" <<'EOF'
#!/bin/bash
touch "$STUB_DIR/FLY_CALLED"; exit 1
EOF
# The worker, by path. -w '\n%{http_code}' is what _jobs_req asks for. A claim
# pops the next line of $STUB_DIR/queue; an empty queue is {"command":null}.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
method=GET; body=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method=$a ;; --data-binary|-d) body=$a ;; esac
  case "$a" in http*://*) url=$a ;; esac
  prev=$a
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
path="/${url#*://*/}"; path="${path%%\?*}"
case "$path" in
  /api/box-commands/claim)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/requests.log"
    ans='{"command":null}'
    if [ -s "$STUB_DIR/queue" ]; then
      ans=$(head -1 "$STUB_DIR/queue"); sed -i 1d "$STUB_DIR/queue"
    fi
    printf '%s\n%s' "$ans" "${CLAIM_CODE:-200}" ;;
  /api/box-commands/*/result)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/requests.log"
    # how many box-ops.log lines existed when the result was posted
    { wc -l < "$HARNESS/logs/box-ops.log" 2>/dev/null || echo 0; } >> "$STUB_DIR/logn"
    printf '%s\n%s' '{"ok":true}' "${RESULT_CODE:-200}" ;;
  *)
    printf '%s %s\n' "$method" "$path" >> "$STUB_DIR/other.log"
    printf '%s\n%s' '{}' 404 ;;
esac
EOF
chmod +x "$T/fakebin/ssh" "$T/fakebin/fly" "$T/fakebin/curl"

export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s3cret
export JOBS_URL=https://jobs.test JOBS_RETRIES=0

row() { # row <id> <type> [box] [target] [args-json]
  jq -nc --argjson id "$1" --arg t "$2" --arg b "${3:-b1}" --arg tg "${4:-}" --argjson a "${5:-null}" \
    '{command:{id:$id, box:$b, type:$t, target:$tg, args:$a, reason:"test", status:"claimed", claimed_by:"b1"}}'
}
reset() {
  rm -f "$T"/requests.log "$T"/other.log "$T"/logn "$T"/queue "$T"/*_CALLED "$T/PWNED"
  rm -f "$H/flags/lane-off-box-ops" "$H/logs/box-ops.log" "$H/logs/state-backup.log" "$H/state/backup-last.json"
  cp "$T/box-ops-fly.real" "$H/bin/lib/box-ops-fly.sh"
  unset SB_RC SB_STAMP SB_LOG SB_ALERT SB_SLEEP HS_RC HS_OUT HS_SLEEP HS_BG CU_RC CU_OUT
  unset CLAIM_CODE RESULT_CODE BOX_OPS_TIMEOUT_S BOX_OPS_MAX_PER_TICK
  export LEASE_RC=1 BOXNAME=b1
}
SCRIPT="$H/bin/box-ops.sh"
run() { bash "$SCRIPT" > "$T/out" 2>&1; }
reqs()     { cat "$T/requests.log" 2>/dev/null; } # a missing log is zero requests
nclaims()  { reqs | grep -c ' /api/box-commands/claim ' || true; }
nresults() { reqs | grep -c ' /api/box-commands/[^ ]*/result ' || true; }
result()   { grep " /api/box-commands/${1:-1}/result " "$T/requests.log" | tail -1 | cut -d' ' -f3-; }
claimbody(){ grep ' /api/box-commands/claim ' "$T/requests.log" | head -1 | cut -d' ' -f3-; }
alerts()   { wc -l < "$H/logs/ALERTS.log"; }
logl()     { wc -l < "$H/logs/box-ops.log" 2>/dev/null || echo 0; }
never() { # never <case>: the negatives every run must hold
  [ ! -e "$T/SSH_CALLED" ] && ok || bad "$1: ssh was called"
  [ ! -e "$T/FLY_CALLED" ] && ok || bad "$1: the fly CLI was called"
  local R
  while IFS= read -r R; do
    [ "$(jq -r '.ok|type' <<<"$R")" = boolean ] && [ "$(jq -r '.detail|length' <<<"$R")" -le 500 ] \
      && [ "$(jq -r '.claimer' <<<"$R")" = b1 ] && ok || bad "$1: result body shape: $R"
  done < <(grep ' /result ' "$T/requests.log" 2>/dev/null | cut -d' ' -f3-)
}
verdict() { # verdict <case> <true|false> <detail substring> [id]
  local R; R=$(result "${4:-1}")
  [ "$RC" = 0 ] && ok || bad "$1 rc=$RC ($(cat "$T/out"))"
  [ "$(jq -r '.ok' <<<"$R")" = "$2" ] && ok || bad "$1 ok is not $2: $R"
  jq -r '.detail' <<<"$R" | grep -qF -- "$3" && ok || bad "$1 detail lacks '$3': $R"
  never "$1"
}
nostub() { # nostub <case>: no op ran
  [ ! -e "$T/SB_CALLED" ] && [ ! -e "$T/HS_CALLED" ] && [ ! -e "$T/CU_CALLED" ] && ok \
    || bad "$1: an op stub ran: $(cd "$T" && echo ./*_CALLED)"
}

# ── L1 lane off → no claim ───────────────────────────────────────────────
reset; row 1 backup_now > "$T/queue"; touch "$H/flags/lane-off-box-ops"
run; RC=$?
[ "$RC" = 0 ] && ok || bad "L1 rc=$RC"
[ "$(nclaims)" = 0 ] && ok || bad "L1 claimed while lane-off: $(reqs)"
nostub L1; never L1

# ── L2 lock held → no claim, no wait ─────────────────────────────────────
reset; row 1 backup_now > "$T/queue"
exec 8>"$H/locks/box-ops.lock"; flock -n 8 || bad "L2 test could not take the lock"
S0=$(date +%s); run; RC=$?; S1=$(date +%s)
exec 8>&-
[ "$RC" = 0 ] && ok || bad "L2 rc=$RC"
[ $((S1 - S0)) -lt 5 ] && ok || bad "L2 waited $((S1 - S0))s on a held lock"
[ "$(nclaims)" = 0 ] && ok || bad "L2 claimed under a held lock"
nostub L2; never L2

# ── L3 empty box name → ALERTS, exit 1, no claim ─────────────────────────
reset; row 1 backup_now > "$T/queue"; export BOXNAME=''
A0=$(alerts); run; RC=$?
[ "$RC" = 1 ] && ok || bad "L3 rc=$RC ($(cat "$T/out"))"
[ "$(alerts)" = $((A0 + 1)) ] && tail -1 "$H/logs/ALERTS.log" | grep -q 'box-name' && ok \
  || bad "L3 ALERTS: $(tail -2 "$H/logs/ALERTS.log")"
[ "$(nclaims)" = 0 ] && ok || bad "L3 claimed with no box name"
never L3

# ── K1 a bad knob refuses before claiming, never clamped ─────────────────
for kv in BOX_OPS_MAX_PER_TICK=0 BOX_OPS_TIMEOUT_S=abc BOX_OPS_TIMEOUT_S=-5; do
  reset; row 1 backup_now > "$T/queue"; export "${kv?}"
  A0=$(alerts); run; RC=$?
  [ "$RC" = 1 ] && ok || bad "K1 $kv rc=$RC"
  [ "$(alerts)" = $((A0 + 1)) ] && tail -1 "$H/logs/ALERTS.log" | grep -qF "${kv%%=*}" && ok \
    || bad "K1 $kv ALERTS: $(tail -1 "$H/logs/ALERTS.log")"
  [ "$(nclaims)" = 0 ] && ok || bad "K1 $kv claimed"
  nostub "K1 $kv"
done

# ── S1 hub rides in boxes only while the lease is held ───────────────────
reset; run; RC=$?
B=$(claimbody)
[ "$RC" = 0 ] && [ "$(jq -c '.boxes' <<<"$B")" = '["b1"]' ] && [ "$(jq -r '.claimer' <<<"$B")" = b1 ] && ok \
  || bad "S1a lease not held: rc=$RC body=$B"
reset; export LEASE_RC=0; run; RC=$?
B=$(claimbody)
[ "$RC" = 0 ] && [ "$(jq -c '.boxes' <<<"$B")" = '["b1","hub"]' ] && [ "$(jq -r '.claimer' <<<"$B")" = b1 ] && ok \
  || bad "S1b lease held: rc=$RC body=$B"
[ "$(nresults)" = 0 ] && ok || bad "S1 posted a result for an empty claim"
never S1

# ── L4 backup_now: ok only on rc 0 AND a fresh upload stamp ──────────────
reset; row 1 backup_now > "$T/queue"; export SB_STAMP=now
run; RC=$?
verdict L4a true uploaded
[ "$(nclaims)" = 2 ] && [ "$(nresults)" = 1 ] && ok || bad "L4a requests: $(cat "$T/requests.log")"
grep -q 'cmd 1 type=backup_now box=b1 .*verdict=ok' "$H/logs/box-ops.log" && [ "$(logl)" = 1 ] && ok \
  || bad "L4a log: $(cat "$H/logs/box-ops.log" 2>/dev/null)"
[ "$(head -1 "$T/logn" 2>/dev/null)" = 1 ] && ok || bad "L4a the log line did not precede the result POST ($(cat "$T/logn" 2>/dev/null))"

l4b() { reset; row 1 backup_now > "$T/queue"; export SB_STAMP=20200101T000000Z; run; RC=$?; }
l4b; verdict L4b false 'no upload stamp at or after'
grep -q 'verdict=fail' "$H/logs/box-ops.log" && ok || bad "L4b log: $(cat "$H/logs/box-ops.log")"

reset; row 1 backup_now > "$T/queue"; export SB_LOG='skip: a backup is still running' SB_STAMP=20200101T000000Z
run; RC=$?; verdict L4c false 'backup already running (lock held)'

reset; row 1 backup_now > "$T/queue"; export SB_LOG='not configured - missing: BACKUP_S3_BUCKET' SB_RC=1
run; RC=$?; verdict L4d false 'not configured'
[[ "$(jq -r .detail <<<"$(result)")" == "not configured"* ]] && ok || bad "L4d detail: $(result)"

reset; row 1 backup_now > "$T/queue"
export SB_ALERT='2026-09-26T00:00:00Z [state-backup] b1: upload: put-object rc=1 for b1/x.tar.zst' SB_RC=1
run; RC=$?; verdict L4e false 'put-object rc=1'

reset; row 1 backup_now > "$T/queue"   # rc 0, no stamp file at all
run; RC=$?; verdict L4f false 'no upload stamp at or after'

# ── L5 harness_sync rc 0 / 20 / 30 ───────────────────────────────────────
reset; row 1 harness_sync > "$T/queue"; export HS_OUT=$'fetching\ndeployed abc123\n'
run; RC=$?; verdict L5a true 'deployed abc123'
reset; row 1 harness_sync > "$T/queue"; export HS_OUT='another harness-sync holds the lock' HS_RC=20
run; RC=$?; verdict L5b false 'not synced: another harness-sync holds the lock'
reset; row 1 harness_sync > "$T/queue"; export HS_OUT='refused (diverged)' HS_RC=30
A0=$(cat "$H/logs/ALERTS.log"); run; RC=$?; verdict L5c false 'refused: refused (diverged)'
[ "$(cat "$H/logs/ALERTS.log")" = "$A0" ] && ok || bad "L5c box-ops wrote ALERTS on rc 30"

# ── L6 cli_update ────────────────────────────────────────────────────────
reset; row 1 cli_update > "$T/queue"; export CU_OUT=$'claude 1 -> 2 method=npm ok=1\ncodex 3 -> 3 method=npm ok=1\ngh 4 -> 5 method=apt ok=1\n'
run; RC=$?; verdict L6a true 'gh 4 -> 5 method=apt ok=1'
[ "$(jq -r .detail <<<"$(result)")" = 'gh 4 -> 5 method=apt ok=1' ] && ok || bad "L6a detail is not the last line: $(result)"
reset; row 1 cli_update > "$T/queue"; export CU_OUT='codex missing' CU_RC=1
run; RC=$?; verdict L6b false 'cli-update rc=1: codex missing'

# ── L7 timeout on any op ─────────────────────────────────────────────────
reset; row 1 harness_sync > "$T/queue"; export BOX_OPS_TIMEOUT_S=1 HS_SLEEP=5 HS_OUT='deployed late'
S0=$(date +%s); run; RC=$?; S1=$(date +%s)
verdict L7 false 'timed out after 1s'
[ $((S1 - S0)) -lt 5 ] && ok || bad "L7 the op was not bounded ($((S1 - S0))s)"

# ── L8 unknown type → refused, nothing runs ──────────────────────────────
for ty in rm_rf 'backup_now; reboot'; do
  reset; row 1 "$ty" > "$T/queue"
  run; RC=$?; verdict "L8 $ty" false "refused: unknown type $ty"
  nostub "L8 $ty"
done

# ── L9 the dedupe lock never outlives the tick through a grandchild ──────
l9() { reset; row 1 harness_sync > "$T/queue"; export HS_OUT='deployed x' HS_BG=4; run; RC=$?; }
lock_free() { flock -n "$H/locks/box-ops.lock" true; }
l9; verdict L9 true 'deployed x'
lock_free && ok || bad "L9 box-ops.lock still held after the tick (a grandchild inherited fd 9)"

# ── S2 at most BOX_OPS_MAX_PER_TICK claims ───────────────────────────────
reset; export BOX_OPS_MAX_PER_TICK=2 SB_STAMP=now
for i in 1 2 3 4; do row "$i" backup_now; done > "$T/queue"
run; RC=$?
[ "$RC" = 0 ] && [ "$(nclaims)" = 2 ] && [ "$(nresults)" = 2 ] && [ "$(logl)" = 2 ] && ok \
  || bad "S2 rc=$RC claims=$(nclaims) results=$(nresults) log=$(logl)"
[ "$(wc -l < "$T/queue")" = 2 ] && ok || bad "S2 queue left: $(wc -l < "$T/queue")"
never S2

# ── S3 claim route not deployed (404) → quiet exit ───────────────────────
s3() { reset; row 1 backup_now > "$T/queue"; export CLAIM_CODE=404; A0=$(cat "$H/logs/ALERTS.log"); run; RC=$?; }
s3
[ "$RC" = 0 ] && ok || bad "S3 rc=$RC"
[ "$(logl)" = 1 ] && grep -q 'claim route not deployed (HTTP 404)' "$H/logs/box-ops.log" && ok \
  || bad "S3 log: $(cat "$H/logs/box-ops.log" 2>/dev/null)"
[ "$(cat "$H/logs/ALERTS.log")" = "$A0" ] && ok || bad "S3 ALERTS changed"
[ "$(nclaims)" = 1 ] && [ "$(nresults)" = 0 ] && ok || bad "S3 requests: $(cat "$T/requests.log")"
nostub S3; never S3

# ── S4 a failed result POST → ALERTS, exit 1, stop the tick ──────────────
reset; export RESULT_CODE=500 SB_STAMP=now
{ row 1 backup_now; row 2 backup_now; } > "$T/queue"
A0=$(alerts); run; RC=$?
[ "$RC" = 1 ] && ok || bad "S4 rc=$RC"
[ "$(alerts)" = $((A0 + 1)) ] && tail -1 "$H/logs/ALERTS.log" | grep -q 'command 1' \
  && tail -1 "$H/logs/ALERTS.log" | grep -q 're-offered' && ok || bad "S4 ALERTS: $(tail -2 "$H/logs/ALERTS.log")"
[ "$(nclaims)" = 1 ] && ok || bad "S4 kept claiming after a failed result: $(nclaims)"
never S4

# ── S5 routing: another box's row, the Fly contract stub, hostile ids ────
reset; row 1 backup_now other-box > "$T/queue"
run; RC=$?; verdict S5a false 'refused:'
[[ "$(jq -r .detail <<<"$(result)")" == refused:* ]] && ok || bad "S5a detail: $(result)"
nostub S5a

# S5b: the REAL bin/lib/box-ops-fly.sh, reached through box-ops, must refuse a
# destructive Fly verb it is not allowed to run, with no fly call (verdict's
# `never`). Project p is not a fleet project here (the scratch tree has no
# bin/fleet-conf.sh), so the refusal must hold whichever lib is on the tree:
# the BH-2518 contract stub ("fly ops not built yet") or the BH-2661 executors
# (#2806, "unknown project p"). Either merge order is green; any other answer,
# an ok, or a fly call is red.
for v in stop destroy; do
  reset; row 1 "fly_machine_$v" b1 abcd1234 '{"project":"p","app":"a"}' > "$T/queue"
  run; RC=$?; verdict "S5b-$v" false 'refused: '
  jq -r '.detail' <<<"$(result)" | grep -qxE 'refused: (fly ops not built yet|unknown project p)' && ok \
    || bad "S5b-$v: the real lib must refuse project p before any call: $(result)"
done

# A recording lib: it proves the good row reaches it with the args in order,
# and that a hostile row never does.
cat > "$T/box-ops-fly.rec" <<'EOF'
box_ops_fly_stop()    { printf '%s\n' "stop|$1|$2|$3" >> "$STUB_DIR/LIB_CALLED"; echo "stopped $1"; return 0; }
box_ops_fly_destroy() { printf '%s\n' "destroy|$1|$2|$3" >> "$STUB_DIR/LIB_CALLED"; echo "destroyed $1"; return 0; }
EOF
reset; cp "$T/box-ops-fly.rec" "$H/bin/lib/box-ops-fly.sh"; rm -f "$T/LIB_CALLED"
row 1 fly_machine_stop b1 abcd1234 '{"project":"p","app":"my-app"}' > "$T/queue"
run; RC=$?; verdict S5-rec true 'stopped abcd1234'
[ "$(cat "$T/LIB_CALLED" 2>/dev/null)" = 'stop|abcd1234|p|my-app' ] && ok || bad "S5-rec lib argv: $(cat "$T/LIB_CALLED" 2>/dev/null)"
for bad_row in \
  "fly_machine_destroy|abc;touch $T/PWNED|p|a" \
  'fly_machine_destroy|ABCDEFGH|p|a' \
  'fly_machine_stop|abcdefg|p|a' \
  "fly_machine_stop|$(printf 'a%.0s' $(seq 33))|p|a" \
  'fly_machine_stop|abcd1234|my project|a' \
  'fly_machine_stop|abcd1234|p|$(touch PWNED)'; do
  IFS='|' read -r ty tg pj ap <<<"$bad_row"
  reset; cp "$T/box-ops-fly.rec" "$H/bin/lib/box-ops-fly.sh"; rm -f "$T/LIB_CALLED"
  row 1 "$ty" b1 "$tg" "$(jq -nc --arg p "$pj" --arg a "$ap" '{project:$p, app:$a}')" > "$T/queue"
  run; RC=$?; verdict "S5c $tg/$pj/$ap" false 'refused: bad target/project/app'
  [ ! -e "$T/LIB_CALLED" ] && ok || bad "S5c $tg: the fly lib was called: $(cat "$T/LIB_CALLED")"
  [ ! -e "$T/PWNED" ] && [ ! -e "$H/PWNED" ] && ok || bad "S5c $tg: an id was executed"
done

# ── R1 the registry row ──────────────────────────────────────────────────
REGF="$DIR/catalog/lanes.d/box-ops.json"
[ "$(jq -r '.scope' "$REGF" 2>/dev/null)" = box ] && [ "$(jq -r '.script' "$REGF")" = bin/box-ops.sh ] \
  && [ "$(jq -r '.cadence' "$REGF")" = '* * * * *' ] && ok || bad "R1 box-ops.json scope/script/cadence"
[ "$(jq -c '.boxes' "$REGF" 2>/dev/null)" = "$(jq -c '.boxes' "$DIR/catalog/lanes.d/update-runners.json")" ] && ok \
  || bad "R1 boxes differ from update-runners"
[ "$(jq -c '[.knobs[]|select(.env=="BOX_OPS_TIMEOUT_S")|.default,.min]' "$REGF" 2>/dev/null)" = '[900,60]' ] \
  && [ "$(jq -c '[.knobs[]|select(.env=="BOX_OPS_MAX_PER_TICK")|.default,.min]' "$REGF")" = '[3,1]' ] && ok \
  || bad "R1 knobs: $(jq -c '.knobs' "$REGF" 2>/dev/null)"
CRONF="$DIR/cron/lanes/697-box-ops.cron"
grep -q '^# @ungated .' "$CRONF" 2>/dev/null && ! grep -q 'hub-lanes\|hub-lease' <(grep -v '^#' "$CRONF") \
  && grep -qx '\* \* \* \* \* /root/harness/bin/box-ops.sh >> /root/harness/logs/box-ops.log 2>&1' "$CRONF" && ok \
  || bad "R1 cron fragment: $(cat "$CRONF" 2>/dev/null)"

# ── M1-M3 mutations: each pinned behaviour, broken once, must be seen ────
mutant() { # mutant <sed expr>: a broken copy of the real script; fails if sed changed nothing
  sed "$1" "$DIR/bin/box-ops.sh" > "$T/mutant.sh"
  ! cmp -s "$T/mutant.sh" "$DIR/bin/box-ops.sh"
}
if mutant 's/ && ! \[\[ "\$STAMP" < "\$T0" \]\]//'; then
  SCRIPT="$T/mutant.sh"; l4b; SCRIPT="$H/bin/box-ops.sh"
  [ "$(jq -r .ok <<<"$(result)")" = true ] && ok || bad "M1 ignoring the stamp did not flip L4b to ok:true: $(result)"
else bad "M1 the stamp clause was not found to mutate"; fi
if mutant '/claim route not deployed/d'; then
  SCRIPT="$T/mutant.sh"; s3; SCRIPT="$H/bin/box-ops.sh"
  grep -q 'claim route not deployed (HTTP 404)' "$H/logs/box-ops.log" 2>/dev/null \
    && bad "M2 S3's 404 line survives without the 404 branch" || ok
else bad "M2 the 404 branch was not found to mutate"; fi
if mutant 's/ 9>&-//g'; then
  SCRIPT="$T/mutant.sh"; l9; SCRIPT="$H/bin/box-ops.sh"
  lock_free && bad "M3 the lock was free even with fd 9 inherited (L9 is vacuous)" || ok
  # the mutant's grandchild holds fd 9 for HS_BG seconds: wait for it to let go
  for _ in $(seq 1 100); do lock_free && break; sleep 0.1; done
else bad "M3 no 9>&- to mutate"; fi

echo "box-ops.bh-2518: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
