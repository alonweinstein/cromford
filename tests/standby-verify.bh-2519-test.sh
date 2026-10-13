#!/bin/bash
# tests/standby-verify.bh-2519-test.sh — the standby's verify lane (BH-2640,
# part of #2519): bin/standby-verify.sh claims one hub-requested verify run for
# THIS box, dry-run restores its hub's latest snapshot into a /tmp scratch dir
# with bin/state-restore.sh, judges it by restore-lab's rules and posts the
# verdict back.
#
# Runs the REAL bin/standby-verify.sh, bin/jobs-client.sh (+ bin/lib/jobs/*),
# bin/lib/lane-gate.sh, bin/lib/restore-drill-steps.sh and bin/box-name.sh in a
# scratch harness root. Stubbed: curl (answers the worker by path, logs every
# standby-verify request to $T/requests.log) and $H/bin/state-restore.sh
# (records argv, prints scripted output, can make the extracted tree).
#
#   L1  the lane flag / all-off exits 0 before any claim or restore
#   L2  a held lock exits 0 with no claim
#   L3  the happy path: claim body, restore argv (no --apply, no --standby),
#       result body, scratch removed, verdict=ok logged
#   L4  every verdict rule fails closed and names itself; sha256/snapshot_ts
#       are null unless verified; timeout; a bad timeout knob
#   L5  {run:null} is a silent exit 0
#   L6  a result POST that is not a 2xx: exit 1, one ALERTS line, NOT RECORDED
#   L7  a scratch dir inside $H (direct or by symlink): exit 2, one ALERTS
#       line, zero requests, nothing under $H removed
#   L8  a bad of_hub never reaches state-restore and is posted ok:false
#   L9  no box name: exit 0, nothing claimed
#   L10 a claim that answers 404: exit 0, no ALERTS line
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/standby-verify.bh-2519-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/tmp" "$H/env" "$T/fakebin" "$T/scratch"
cp "$DIR/bin/standby-verify.sh" "$H/bin/" || { echo "FAIL: missing bin/standby-verify.sh"; exit 1; }
# standby-verify alerts go through bin/alert-line.sh (alert-writer ratchet); stage
# it and the state lib it sources so ALERTS.log lines still land in the scratch tree.
mkdir -p "$H/bin/lib"
cp "$DIR/bin/alert-line.sh" "$H/bin/" || exit 1
cp "$DIR/bin/lib/alert-state.sh" "$H/bin/lib/" 2>/dev/null || true
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/box-name.sh" "$H/bin/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
for f in lane-gate lanes-registry restore-drill-steps env-path; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/" || { echo "FAIL: missing bin/lib/$f.sh"; exit 1; }
done
: > "$H/env/global.env"
: > "$H/logs/ALERTS.log"
echo keep > "$H/tmp/keep"

cat > "$H/bin/state-restore.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$STUB_DIR/sr.argv"
dest=""; prev=""
for a in "$@"; do [ "$prev" = --dest ] && dest=$a; prev=$a; done
[ -n "${SR_SLEEP:-}" ] && sleep "$SR_SLEEP"
[ -n "${SR_TREE:-}" ] && mkdir -p "$dest/$1/20260926T010000Z/tree" && echo x > "$dest/$1/20260926T010000Z/tree/x"
[ -n "${SR_EMPTY_TREE:-}" ] && mkdir -p "$dest/$1/20260926T010000Z/tree"
printf '%s' "${SR_OUT:-}"
exit "${SR_RC:-0}"
EOF
chmod +x "$H/bin/state-restore.sh"

# The worker, by path. -w '\n%{http_code}' is what _jobs_req asks for.
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
  /api/hub/standby/verify/claim)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/requests.log"
    [ -n "${CLAIM_RC:-}" ] && exit "$CLAIM_RC"
    printf '%s\n%s' "$(cat "$STUB_DIR/claim.json")" "${CLAIM_CODE:-200}" ;;
  /api/hub/standby/verify/*/result)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/requests.log"
    printf '%s\n%s' '{"ok":true}' "${RESULT_CODE:-200}" ;;
  *)
    printf '%s %s\n' "$method" "$path" >> "$STUB_DIR/other.log"
    printf '%s\n%s' '{}' 404 ;;
esac
EOF
chmod +x "$T/fakebin/curl"

export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s3cret
export JOBS_URL=https://jobs.test JOBS_RETRIES=0 BOX_NAME=standby-box STANDBY_VERIFY_TMPDIR="$T/scratch"
unset JOBS_BOX HARNESS_ENV_DIR

SHA=$(printf 'c%.0s' $(seq 64))
STAMP=20260926T010000Z
RUN7='{"run":{"id":7,"box":"standby-box","of_hub":"hub","status":"claimed","claimed_by":"standby-box"}}'
OK_OUT="pulled hub/$STAMP.tar.zst -> /x/hub/$STAMP/snapshot.tar.zst
sha256 ok $SHA
extracted hub/$STAMP.tar.zst -> /x/tree
"
reset() {
  rm -f "$T/requests.log" "$T/other.log" "$T/sr.argv" "$H/logs/standby-verify.log"
  rm -rf "$T/scratch"; mkdir -p "$T/scratch"
  rm -f "$H/flags/lane-off-standby-verify" "$H/flags/all-off"
  printf '%s' "$RUN7" > "$T/claim.json"
  unset SR_OUT SR_RC SR_TREE SR_EMPTY_TREE SR_SLEEP CLAIM_CODE CLAIM_RC RESULT_CODE STANDBY_VERIFY_TIMEOUT_S
  export STANDBY_VERIFY_TMPDIR="$T/scratch"
}
sv() { bash "$H/bin/standby-verify.sh" > "$T/out" 2>&1; }
cnt()      { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }
nreq()     { cnt . "$T/requests.log"; }
nclaims()  { cnt ' /api/hub/standby/verify/claim ' "$T/requests.log"; }
nresults() { cnt ' /api/hub/standby/verify/7/result ' "$T/requests.log"; }
result()   { grep ' /api/hub/standby/verify/7/result ' "$T/requests.log" | tail -1 | cut -d' ' -f3-; }
alerts()   { cnt . "$H/logs/ALERTS.log"; }
scratch_left() { find "$T/scratch" -mindepth 1 -maxdepth 1 | wc -l; }
never_live() { # the negative every restore must hold
  if [ -f "$T/sr.argv" ]; then
    grep -qE -- '--apply|--standby' "$T/sr.argv" && bad "$1: --apply/--standby passed: $(cat "$T/sr.argv")" || ok
  fi
}

# ── L3 happy path ────────────────────────────────────────────────────────
reset
export SR_OUT="$OK_OUT" SR_TREE=1
A0=$(alerts)
sv; RC=$?
[ "$RC" = 0 ] && ok || bad "L3 rc=$RC ($(cat "$T/out"))"
S=$(sed -n 's/^hub latest --dest \(.*\)\/tree --live .*$/\1/p' "$T/sr.argv" 2>/dev/null)
[ -n "$S" ] && [ "$(cat "$T/sr.argv")" = "hub latest --dest $S/tree --live $S/empty-live" ] && ok \
  || bad "L3 state-restore argv: $(cat "$T/sr.argv" 2>/dev/null)"
case "$S" in "$T/scratch/standby-verify."*) ok ;; *) bad "L3 scratch not under STANDBY_VERIFY_TMPDIR: $S" ;; esac
[ -n "$S" ] && [ ! -e "$S" ] && ok || bad "L3 scratch dir $S left behind"
[ "$(nclaims)" = 1 ] && [ "$(nresults)" = 1 ] && ok || bad "L3 requests: $(cat "$T/requests.log" 2>/dev/null)"
grep -qF 'POST /api/hub/standby/verify/claim {"claimer":"standby-box"}' "$T/requests.log" && ok \
  || bad "L3 claim body: $(cat "$T/requests.log" 2>/dev/null)"
R=$(result)
[ "$(jq -c '[.claimer,.ok,.sha256,.snapshot_ts]' <<<"$R" 2>/dev/null)" = "[\"standby-box\",true,\"$SHA\",\"$STAMP\"]" ] \
  && ok || bad "L3 result body: $R"
[ "$(alerts)" = "$A0" ] && ok || bad "L3 ALERTS grew: $(tail -2 "$H/logs/ALERTS.log")"
grep -q 'run 7 of_hub=hub verdict=ok' "$H/logs/standby-verify.log" 2>/dev/null && ok \
  || bad "L3 no verdict=ok log line: $(cat "$H/logs/standby-verify.log" 2>/dev/null)"
never_live L3

# ── L4 failure verdicts ──────────────────────────────────────────────────
fail_case() { # fail_case <name> <detail substring> [sha|null] [stamp|null]
  local R; R=$(result)
  [ "$RC" = 0 ] && ok || bad "$1 rc=$RC ($(cat "$T/out"))"
  [ "$(nresults)" = 1 ] && ok || bad "$1 result posts: $(cat "$T/requests.log" 2>/dev/null)"
  [ "$(jq -r '.ok' <<<"$R" 2>/dev/null)" = false ] && ok || bad "$1 not ok:false: $R"
  jq -r '.detail' <<<"$R" | grep -qF -- "$2" && ok || bad "$1 detail lacks '$2': $R"
  [ "$(jq -r '.sha256' <<<"$R")" = "${3:-null}" ] && ok || bad "$1 sha256 is $(jq -r .sha256 <<<"$R"), want ${3:-null}"
  [ "$(jq -r '.snapshot_ts' <<<"$R")" = "${4:-null}" ] && ok || bad "$1 snapshot_ts is $(jq -r .snapshot_ts <<<"$R"), want ${4:-null}"
  [ "$(scratch_left)" = 0 ] && ok || bad "$1 scratch left: $(ls "$T/scratch")"
  grep -q 'verdict=fail' "$H/logs/standby-verify.log" 2>/dev/null && ok || bad "$1 no verdict=fail log line"
  never_live "$1"
}
reset; export SR_RC=1 SR_OUT="pulled hub/$STAMP.tar.zst -> /x
REFUSED: sha256 mismatch for hub/$STAMP.tar.zst (stored a, downloaded b)
"
sv; RC=$?; fail_case "L4 refused" "state-restore rc=1: REFUSED: sha256 mismatch"

reset; export SR_OUT="sha256 ok $SHA
" SR_TREE=1
sv; RC=$?; fail_case "L4 no pulled line" "no 'pulled hub/<ts>.tar.zst' line"

reset; export SR_OUT="pulled other/$STAMP.tar.zst -> /x
sha256 ok $SHA
" SR_TREE=1
sv; RC=$?; fail_case "L4 pulled for another prefix" "no 'pulled hub/<ts>.tar.zst' line"

reset; export SR_OUT="pulled hub/$STAMP.tar.zst -> /x
sha256 MISMATCH
" SR_TREE=1
sv; RC=$?; fail_case "L4 sha256 mismatch" "sha256 not verified: sha256 MISMATCH" null "$STAMP"

reset; export SR_OUT="pulled hub/$STAMP.tar.zst -> /x
sha256 ok ${SHA:1}
" SR_TREE=1
sv; RC=$?; fail_case "L4 sha256 63 hex" "sha256 not verified" null "$STAMP"

reset; export SR_OUT="$OK_OUT" SR_EMPTY_TREE=1
sv; RC=$?; fail_case "L4 empty tree" "extracted tree hub/$STAMP/tree is missing or empty" "$SHA" "$STAMP"

reset; export SR_OUT="$OK_OUT"
sv; RC=$?; fail_case "L4 missing tree" "extracted tree hub/$STAMP/tree is missing or empty" "$SHA" "$STAMP"

reset; export SR_OUT="state-restore: not configured - missing: BACKUP_S3_ENDPOINT
"
sv; RC=$?; fail_case "L4 rc 0 not configured" "no 'pulled hub/<ts>.tar.zst' line in state-restore output: state-restore: not configured"

reset; export SR_OUT="$OK_OUT" SR_TREE=1 SR_SLEEP=3 STANDBY_VERIFY_TIMEOUT_S=1
sv; RC=$?; fail_case "L4 timeout" "state-restore timed out after 1s"

reset; export SR_OUT="$OK_OUT" SR_TREE=1 STANDBY_VERIFY_TIMEOUT_S=abc
sv; RC=$?; fail_case "L4 bad timeout knob" "STANDBY_VERIFY_TIMEOUT_S 'abc' is not a positive integer"
[ ! -e "$T/sr.argv" ] && ok || bad "L4 bad timeout knob: state-restore ran"
reset; export SR_OUT="$OK_OUT" SR_TREE=1 STANDBY_VERIFY_TIMEOUT_S=0
sv; RC=$?; fail_case "L4 zero timeout knob" "STANDBY_VERIFY_TIMEOUT_S '0' is not a positive integer"
[ ! -e "$T/sr.argv" ] && ok || bad "L4 zero timeout knob: state-restore ran"

# ── L8 of_hub validated ──────────────────────────────────────────────────
for bad_of in '../hub' 'Hub' 'hub;rm' ''; do
  reset; export SR_OUT="$OK_OUT" SR_TREE=1
  jq -nc --arg o "$bad_of" '{run:{id:7,box:"standby-box",of_hub:$o,status:"claimed"}}' > "$T/claim.json"
  sv; RC=$?; fail_case "L8 of_hub '$bad_of'" "of_hub"
  [ ! -e "$T/sr.argv" ] && ok || bad "L8 of_hub '$bad_of': state-restore ran with $(cat "$T/sr.argv")"
done

# ── L5 no run ────────────────────────────────────────────────────────────
reset; printf '{"run":null}' > "$T/claim.json"
A0=$(alerts)
sv; RC=$?
[ "$RC" = 0 ] && [ "$(nclaims)" = 1 ] && [ "$(nreq)" = 1 ] && ok || bad "L5 rc=$RC requests=$(cat "$T/requests.log" 2>/dev/null)"
[ ! -e "$T/sr.argv" ] && ok || bad "L5 state-restore ran with no run"
[ "$(alerts)" = "$A0" ] && ok || bad "L5 ALERTS grew"
[ "$(scratch_left)" = 0 ] && ok || bad "L5 scratch left"

# ── L10 claim answers 404 (routes not deployed) / 500 / transport ────────
for code in 404 500; do
  reset; export CLAIM_CODE=$code
  A0=$(alerts)
  sv; RC=$?
  [ "$RC" = 0 ] && ok || bad "L10 claim $code rc=$RC"
  [ ! -e "$T/sr.argv" ] && ok || bad "L10 claim $code: state-restore ran"
  [ "$(alerts)" = "$A0" ] && ok || bad "L10 claim $code: ALERTS grew: $(tail -1 "$H/logs/ALERTS.log")"
  grep -q "claim failed (HTTP $code)" "$H/logs/standby-verify.log" 2>/dev/null && ok || bad "L10 claim $code: no log line"
done
reset; export CLAIM_RC=28
A0=$(alerts)
sv; RC=$?
[ "$RC" = 0 ] && [ "$(alerts)" = "$A0" ] && [ ! -e "$T/sr.argv" ] && ok || bad "L10 transport rc=$RC alerts=$(alerts)"

# ── L6 result not recorded ───────────────────────────────────────────────
reset; export SR_OUT="$OK_OUT" SR_TREE=1 RESULT_CODE=500
A0=$(alerts)
sv; RC=$?
[ "$RC" = 1 ] && ok || bad "L6 rc=$RC, want 1"
[ "$(alerts)" = $((A0 + 1)) ] && ok || bad "L6 ALERTS lines: $(alerts), want $((A0 + 1))"
tail -1 "$H/logs/ALERTS.log" | grep -q 'result for run 7 not recorded (HTTP 500)' && ok || bad "L6 ALERTS line: $(tail -1 "$H/logs/ALERTS.log")"
grep -q 'run 7 .*NOT RECORDED' "$H/logs/standby-verify.log" && ok || bad "L6 no NOT RECORDED log line"
grep -q 'verdict=ok:' "$H/logs/standby-verify.log" && bad "L6 an unrecorded run was logged as recorded" || ok
[ "$(scratch_left)" = 0 ] && ok || bad "L6 scratch left"

# ── L1 gated ─────────────────────────────────────────────────────────────
for f in lane-off-standby-verify all-off; do
  reset; : > "$H/flags/$f"
  sv; RC=$?
  [ "$RC" = 0 ] && [ "$(nreq)" = 0 ] && [ ! -e "$T/sr.argv" ] && ok || bad "L1 $f rc=$RC requests=$(cat "$T/requests.log" 2>/dev/null)"
  rm -f "$H/flags/$f"
done

# ── L2 locked ────────────────────────────────────────────────────────────
reset
( exec 9>"$H/locks/standby-verify.lock"; flock 9; exec sleep 5 ) &
LP=$!
wait_holder "$LP"
sv; RC=$?
[ "$RC" = 0 ] && [ "$(nreq)" = 0 ] && ok || bad "L2 held lock rc=$RC requests=$(cat "$T/requests.log" 2>/dev/null)"
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null

# ── L7 scratch guard ─────────────────────────────────────────────────────
reset; export STANDBY_VERIFY_TMPDIR="$H/tmp"
A0=$(alerts)
sv; RC=$?
[ "$RC" = 2 ] && ok || bad "L7 in-harness tmpdir rc=$RC, want 2"
[ "$(alerts)" = $((A0 + 1)) ] && ok || bad "L7 ALERTS lines: $(alerts), want $((A0 + 1))"
[ "$(nreq)" = 0 ] && ok || bad "L7 claimed despite the guard"
[ -f "$H/tmp/keep" ] && [ "$(find "$H/tmp" -mindepth 1 | wc -l)" = 1 ] && ok || bad "L7 \$H/tmp changed: $(ls -A "$H/tmp")"
reset; ln -sfn "$H" "$T/link-into-h"; export STANDBY_VERIFY_TMPDIR="$T/link-into-h/tmp"
A0=$(alerts)
sv; RC=$?
[ "$RC" = 2 ] && [ "$(alerts)" = $((A0 + 1)) ] && [ "$(nreq)" = 0 ] && ok || bad "L7 symlinked tmpdir rc=$RC alerts=$(alerts) requests=$(nreq)"
[ -f "$H/tmp/keep" ] && [ "$(find "$H/tmp" -mindepth 1 | wc -l)" = 1 ] && ok || bad "L7 symlink: \$H/tmp changed"

# ── L9 no box name ───────────────────────────────────────────────────────
reset; mv "$H/bin/box-name.sh" "$T/box-name.real"
printf '#!/bin/bash\nexit 1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"
sv; RC=$?
[ "$RC" = 0 ] && [ "$(nreq)" = 0 ] && ok || bad "L9 rc=$RC requests=$(cat "$T/requests.log" 2>/dev/null)"
grep -q 'no box name; nothing claimed' "$H/logs/standby-verify.log" 2>/dev/null && ok || bad "L9 no log line"
[ "$(scratch_left)" = 0 ] && ok || bad "L9 scratch left"
mv "$T/box-name.real" "$H/bin/box-name.sh"

echo "standby-verify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
