#!/bin/bash
# tests/restore-drill.bh-1731-test.sh — the lifecycle of the weekly restore
# drill (BH-1731, parent #400): lock, reap, spend guard, configured check,
# create (with the RAM_ADDON classifier), wait, steps, and the finalizer that
# beats once, deletes, then writes the marker.
#
# Runs the REAL bin/restore-drill.sh with the REAL Orgo seam in a scratch
# harness root. Three things are stubbed: curl (plays Orgo), bin/beat.sh, and a
# test-local bin/lib/restore-drill-steps.sh whose drill_on_box answers per
# $STEPS_MODE, so this suite does not depend on the steps sibling (#1732).
# curl and beat.sh append to ONE sequence log ($T/seq.log), so order between a
# beat and a DELETE is an assertion, not an inference.
#
# Run from anywhere: tests/restore-drill.bh-1731-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$T/fakebin"
for f in lane-gate env-path restore-drill-orgo; do
  cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/" || { echo "FAIL: missing bin/lib/$f.sh"; exit 1; }
done
cp "$DIR/bin/restore-drill.sh" "$H/bin/" || { echo "FAIL: missing bin/restore-drill.sh"; exit 1; }
: > "$H/env/global.env"

# Test-local steps: records its inputs, and what the inflight file said while
# it ran (the id must be persisted BEFORE anything happens on the box).
cat > "$H/bin/lib/restore-drill-steps.sh" <<'EOF'
drill_on_box() {
  printf '%s %s %s\n' "$1" "$2" "$RESTORE_DRILL_HEALTH_PROJECT" > "$STUB_DIR/steps.called"
  cat "$H/state/restore-drill-inflight" > "$STUB_DIR/steps.inflight" 2>/dev/null
  case "${STEPS_MODE:-ok}" in
    ok)       DRILL_VERDICT=OK;   DRILL_DETAIL="restored";      DRILL_RPO_S=3600; return 0 ;;
    fail)     DRILL_VERDICT=FAIL; DRILL_DETAIL="smoke failed";  DRILL_RPO_S="";   return 1 ;;
    fail-rc0) DRILL_VERDICT=FAIL; DRILL_DETAIL="rc0 but fail";  DRILL_RPO_S="";   return 0 ;;
    ok-rc1)   DRILL_VERDICT=OK;   DRILL_DETAIL="";              DRILL_RPO_S=5;    return 1 ;;
    sleep)    sleep 3; DRILL_VERDICT=OK; DRILL_DETAIL="slept"; DRILL_RPO_S=1; return 0 ;;  # determinism: ok the C5 SIGTERM target: the test kills this step mid-sleep, so the duration only has to outlast the signal
  esac
}
EOF

cat > "$H/bin/beat.sh" <<'EOF'
#!/bin/bash
printf 'BEAT %s\n' "$1" >> "$STUB_DIR/seq.log"
exit "${STUB_BEAT_RC:-0}"
EOF
chmod +x "$H/bin/beat.sh"

# curl playing Orgo. Appends "METHOD PATH BODY" to the sequence log.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
m=GET url="" data=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m=$2; shift ;;
    --data-binary) data=1; shift ;;
    -m|-H|-w) shift ;;
    http*) url=$1 ;;
  esac
  shift
done
body=""
[ "$data" = 1 ] && body=$(cat)
def_post='{"id":"c-new"}' def_get='{"status":"running"}'
p=${url#*://*/api}
printf '%s %s %s\n' "$m" "$p" "$body" >> "$STUB_DIR/seq.log"
case "$m $p" in
  "POST /computers")
    [ -n "${STUB_POST_RC:-}" ] && exit "$STUB_POST_RC"
    printf '%s\n%s' "${STUB_POST_BODY-$def_post}" "${STUB_POST_CODE:-200}" ;;
  "GET /computers/"*)
    printf '%s\n%s' "${STUB_GET_BODY:-$def_get}" "${STUB_GET_CODE:-200}" ;;
  "DELETE /computers/"*)
    printf '%s\n%s' '{}' "${STUB_DEL_CODE:-200}" ;;
  *) printf '%s\n%s' '{}' 404 ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH"

MARK="$H/state/restore-drill-last.json"
INF="$H/state/restore-drill-inflight"
SEQ="$T/seq.log"
ALERTS="$H/logs/ALERTS.log"

reset() {
  rm -f "$SEQ" "$T/steps.called" "$T/steps.inflight" "$MARK" "$INF" "$ALERTS" "$H/logs/restore-drill.log"
  unset STUB_POST_CODE STUB_POST_BODY STUB_POST_RC STUB_GET_BODY STUB_GET_CODE STUB_DEL_CODE STUB_BEAT_RC STEPS_MODE \
        RESTORE_DRILL_DEADLINE_S RESTORE_DRILL_POLL_S RESTORE_DRILL_RAM_GB RESTORE_DRILL_MIN_INTERVAL_H
  export ORGO_API_KEY=K RESTORE_DRILL_TEMPLATE_REF=tpl-x BACKUP_S3_ENDPOINT=e \
         BACKUP_S3_ACCESS_KEY_ID=a BACKUP_S3_SECRET_ACCESS_KEY=S3SECRETVALUE
  printf 'hubbox\n' > "$H/state/box-id"
}
lane() { HARNESS="$H" bash "$H/bin/restore-drill.sh" "$@" >"$T/lane.out" 2>&1; }
n_re()   { [ -f "$SEQ" ] || { echo 0; return; }; grep -cE "$1" "$SEQ"; return 0; }
ncalls() { n_re '^(GET|POST|DELETE) '; }
nbeats() { n_re '^BEAT '; }
beatline() { grep '^BEAT ' "$SEQ" 2>/dev/null | head -1 | sed 's/^BEAT //' | jq -r '.line' 2>/dev/null; }
mk() { jq -r "$1" "$MARK" 2>/dev/null; }
nalerts() { [ -s "$ALERTS" ] && wc -l < "$ALERTS" | tr -d ' ' || echo 0; }
lineno() { grep -nE "$1" "$SEQ" 2>/dev/null | head -1 | cut -d: -f1; }

NOW=$(date +%s)

# --- C1: full lifecycle, OK ---------------------------------------------------
reset
printf '{"ts":%s,"verdict":"FAIL","detail":"x","rpo_s":null,"deleted":true,"last_ok_ts":7,"first_run_ts":42}\n' $((NOW-100000)) > "$MARK"
lane; rc=$?
[ "$rc" = 0 ] && ok || bad "C1 rc=$rc $(cat "$T/lane.out")"
post=$(grep '^POST /computers ' "$SEQ" | head -1 | sed 's#^POST /computers ##')
printf '%s' "$post" | jq -e '.template_ref=="tpl-x" and .ram==8 and .cpu==2 and (has("snapshot")|not) and (.name|startswith("restore-drill-"))' >/dev/null 2>&1 \
  && ok || bad "C1 create body wrong: [$post]"
[ "$(cat "$T/steps.called" 2>/dev/null)" = "c-new hubbox cromford" ] && ok || bad "C1 steps.called=[$(cat "$T/steps.called" 2>/dev/null)]"
[ "$(cat "$T/steps.inflight" 2>/dev/null)" = "c-new" ] && ok || bad "C1 inflight was not c-new while steps ran"
[ "$(nbeats)" = 1 ] && ok || bad "C1 beats=$(nbeats)"
beatline | grep -qE '^restore-drill: OK .*RPO=3600$' && ok || bad "C1 beat line=[$(beatline)]"
grep '^BEAT ' "$SEQ" | sed 's/^BEAT //' | jq -e '.kind=="fleet_event"' >/dev/null 2>&1 && ok || bad "C1 beat is not a fleet_event"
b=$(lineno '^BEAT '); d=$(lineno '^DELETE /computers/c-new'); g=$(lineno '^GET /computers/c-new')
{ [ -n "$b" ] && [ -n "$d" ] && [ "$b" -lt "$d" ]; } && ok || bad "C1 beat (line ${b:-none}) not before DELETE (line ${d:-none})"
{ [ -n "$g" ] && [ "$g" -lt "$b" ]; } && ok || bad "C1 no GET before the beat"
mk '.verdict=="OK" and .deleted==true and .last_ok_ts==.ts and .first_run_ts==42 and .rpo_s==3600 and .detail=="restored"' | grep -qx true \
  && ok || bad "C1 marker wrong: $(cat "$MARK" 2>/dev/null)"
[ ! -e "$INF" ] && ok || bad "C1 inflight file left behind"
grep -rq S3SECRETVALUE "$SEQ" "$H/logs" "$T/lane.out" 2>/dev/null && bad "C1 S3 secret leaked into a log" || ok
[ "$(nalerts)" = 0 ] && ok || bad "C1 wrote ALERTS"

# --- C2: steps FAIL -> still deleted, last_ok_ts carried ----------------------
reset; export STEPS_MODE=fail
printf '{"ts":1,"verdict":"OK","detail":"","rpo_s":1,"deleted":true,"last_ok_ts":111,"first_run_ts":5}\n' > "$MARK"
lane; rc=$?
[ "$rc" = 1 ] && ok || bad "C2 rc=$rc"
[ "$(n_re '^DELETE /computers/c-new')" = 1 ] && ok || bad "C2 no DELETE for c-new"
[ "$(nbeats)" = 1 ] && ok || bad "C2 beats=$(nbeats)"
beatline | grep -qE '^restore-drill: FAIL smoke failed RPO=unknown$' && ok || bad "C2 beat line=[$(beatline)]"
mk '.verdict=="FAIL" and .last_ok_ts==111 and .first_run_ts==5 and .deleted==true and .rpo_s==null' | grep -qx true \
  && ok || bad "C2 marker wrong: $(cat "$MARK" 2>/dev/null)"

# --- C2b: rc 0 but DRILL_VERDICT=FAIL, and OK with rc 1 -> FAIL ---------------
for mode in fail-rc0 ok-rc1; do
  reset; export STEPS_MODE=$mode
  lane; rc=$?
  [ "$rc" = 1 ] && ok || bad "C2b/$mode rc=$rc"
  [ "$(mk .verdict)" = FAIL ] && ok || bad "C2b/$mode verdict=$(mk .verdict)"
  mk '.last_ok_ts' | grep -qx null && ok || bad "C2b/$mode stamped last_ok_ts"
done
beatline | grep -qE '^restore-drill: FAIL steps rc=1 RPO=5$' && ok || bad "C2b/ok-rc1 beat line=[$(beatline)]"

# --- C3: 403 RAM_ADDON -> SKIP, nothing to delete -----------------------------
reset; export STUB_POST_CODE=403 STUB_POST_BODY='{"error":"RAM_ADDON required"}'
lane; rc=$?
[ "$rc" = 0 ] && ok || bad "C3 rc=$rc"
[ "$(ncalls)" = 1 ] && ok || bad "C3 calls=$(ncalls)"
[ "$(n_re '^DELETE ')" = 0 ] && ok || bad "C3 issued a DELETE"
[ "$(nbeats)" = 1 ] && ok || bad "C3 beats=$(nbeats)"
beatline | grep -qE '^restore-drill: SKIP .*8GB.*RAM_ADDON' && ok || bad "C3 beat line=[$(beatline)]"
[ ! -e "$INF" ] && ok || bad "C3 wrote inflight"
mk '.verdict=="SKIP" and .deleted==false' | grep -qx true && ok || bad "C3 marker wrong: $(cat "$MARK" 2>/dev/null)"
[ "$(nalerts)" = 0 ] && ok || bad "C3 wrote ALERTS"

# --- C3b: adversarial negatives for the RAM_ADDON classifier ------------------
c3b() { # <label> <code> <body> [transport-rc]
  reset; export STUB_POST_CODE="$2" STUB_POST_BODY="$3"
  [ -n "${4:-}" ] && export STUB_POST_RC="$4"
  lane; rc=$?
  [ "$rc" = 1 ] && ok || bad "C3b/$1 rc=$rc"
  beatline | grep -qE '^restore-drill: FAIL create HTTP ' && ok || bad "C3b/$1 beat line=[$(beatline)]"
  [ "$(n_re '^DELETE ')" = 0 ] && ok || bad "C3b/$1 issued a DELETE"
  [ ! -e "$INF" ] && ok || bad "C3b/$1 wrote inflight"
  [ "$(mk .verdict)" = FAIL ] && ok || bad "C3b/$1 verdict=$(mk .verdict)"
}
c3b 403-forbidden 403 '{"error":"forbidden"}'
c3b 500-token     500 '{"error":"RAM_ADDON"}'
c3b 402-token     402 '{"error":"RAM_ADDON required"}'
c3b 401           401 '{"error":"unauthorized"}'
c3b 000           200 '{"id":"c-new"}' 7
beatline | grep -qF 'create HTTP 000' && ok || bad "C3b/000 did not name HTTP 000"

# --- C-noid: a 2xx with no usable id is FAIL, and says so in ALERTS ----------
reset; export STUB_POST_BODY='{"id":"../../x y"}'
lane; rc=$?
[ "$rc" = 1 ] && ok || bad "C-noid rc=$rc"
beatline | grep -qF 'create returned no id' && ok || bad "C-noid beat line=[$(beatline)]"
[ "$(n_re '^(GET|DELETE) ')" = 0 ] && ok || bad "C-noid called Orgo after the create"
[ "$(nalerts)" = 1 ] && ok || bad "C-noid alerts=$(nalerts)"

# --- C4: never running -> FAIL after the deadline, still deleted --------------
reset; export STUB_GET_BODY='{"status":"starting"}' RESTORE_DRILL_DEADLINE_S=2 RESTORE_DRILL_POLL_S=1
lane; rc=$?
[ "$rc" = 1 ] && ok || bad "C4 rc=$rc"
beatline | grep -qE '^restore-drill: FAIL not running after .*starting.*RPO=unknown$' && ok || bad "C4 beat line=[$(beatline)]"
[ "$(n_re '^DELETE /computers/c-new')" = 1 ] && ok || bad "C4 no DELETE for c-new"
[ ! -e "$T/steps.called" ] && ok || bad "C4 ran the steps on a box that never came up"
ng=$(n_re '^GET /computers/c-new'); [ "$ng" -ge 2 ] && [ "$ng" -le 4 ] && ok || bad "C4 GET polls=$ng (want 2..4 for a 2s deadline at 1s)"

# --- C5: SIGTERM during the steps -> delete, one FAIL beat, marker FAIL -------
reset; export STEPS_MODE=sleep
HARNESS="$H" bash "$H/bin/restore-drill.sh" >"$T/lane.out" 2>&1 &
pid=$!
for _ in $(seq 1 100); do [ -e "$T/steps.called" ] && break; sleep 0.1; done
kill -TERM "$pid" 2>/dev/null
wait "$pid"; rc=$?
[ "$rc" = 143 ] && ok || bad "C5 rc=$rc"
[ "$(n_re '^DELETE /computers/c-new')" = 1 ] && ok || bad "C5 no DELETE for c-new after TERM"
[ ! -e "$INF" ] && ok || bad "C5 inflight not cleared"
[ "$(nbeats)" = 1 ] && ok || bad "C5 beats=$(nbeats)"
beatline | grep -qE '^restore-drill: FAIL interrupted by TERM' && ok || bad "C5 beat line=[$(beatline)]"
[ "$(mk .verdict)" = FAIL ] && ok || bad "C5 verdict=$(mk .verdict)"

# --- C6: reap a leaked box first; never delete any other id -------------------
reset; printf 'old-123\n' > "$INF"
lane; rc=$?
[ "$rc" = 0 ] && ok || bad "C6 rc=$rc"
[ "$(head -1 "$SEQ" | awk '{print $1, $2}')" = "DELETE /computers/old-123" ] && ok || bad "C6 first call=[$(head -1 "$SEQ")]"
other=$(grep '^DELETE ' "$SEQ" | awk '{print $2}' | grep -vxE '/computers/(old-123|c-new)')
[ -z "$other" ] && ok || bad "C6 deleted another id: $other"
[ "$(n_re '^POST /computers')" = 1 ] && ok || bad "C6 no create after the reap"
grep -q 'reaped old-123' "$H/logs/restore-drill.log" 2>/dev/null && ok || bad "C6 reap not logged"
[ ! -e "$INF" ] && ok || bad "C6 inflight left behind"

# --- C-reapfail: a leaked box that will not delete stops the run --------------
reset; printf 'old-123\n' > "$INF"; export STUB_DEL_CODE=500
lane; rc=$?
[ "$rc" = 1 ] && ok || bad "C-reapfail rc=$rc"
[ "$(n_re '^POST ')" = 0 ] && ok || bad "C-reapfail created another box"
[ "$(nalerts)" = 1 ] && grep -q 'old-123' "$ALERTS" && ok || bad "C-reapfail alerts=$(nalerts)"
[ "$(cat "$INF" 2>/dev/null)" = old-123 ] && ok || bad "C-reapfail inflight not kept"
[ "$(mk .verdict)" = FAIL ] && ok || bad "C-reapfail verdict=$(mk .verdict)"
beatline | grep -qF 'inflight old-123 not deleted' && ok || bad "C-reapfail beat line=[$(beatline)]"

# --- C-reapjunk: garbage in the inflight file never reaches a URL -------------
reset; printf '/;$(x)\n' > "$INF"
lane; rc=$?
[ "$(n_re '^DELETE /computers/[^c]')" = 0 ] && ok || bad "C-reapjunk deleted a junk id"
[ ! -e "$INF" ] && ok || bad "C-reapjunk inflight left behind"

# --- C7: the final DELETE fails -> one ALERTS line, inflight kept -------------
reset; export STUB_DEL_CODE=500
lane; rc=$?
[ "$(nalerts)" = 1 ] && grep -q 'c-new' "$ALERTS" && ok || bad "C7 alerts=$(nalerts) [$(cat "$ALERTS" 2>/dev/null)]"
[ "$(cat "$INF" 2>/dev/null)" = c-new ] && ok || bad "C7 inflight not kept"
mk '.deleted' | grep -qx false && ok || bad "C7 deleted=$(mk .deleted)"
[ "$(mk .verdict)" = OK ] && ok || bad "C7 verdict=$(mk .verdict) (a failed delete is not a failed drill)"

# --- C7b: DELETE 404 counts as deleted ----------------------------------------
reset; export STUB_DEL_CODE=404
lane; rc=$?
mk '.deleted' | grep -qx true && ok || bad "C7b 404 deleted=$(mk .deleted)"
[ ! -e "$INF" ] && ok || bad "C7b inflight left behind on 404"

# --- C9: spend guard ----------------------------------------------------------
reset
printf '{"ts":%s,"verdict":"OK","detail":"","rpo_s":1,"deleted":true,"last_ok_ts":1,"first_run_ts":1}\n' $((NOW-3600)) > "$MARK"
cp "$MARK" "$T/mark.before"
lane; rc=$?
[ "$rc" = 0 ] && ok || bad "C9 rc=$rc"
[ "$(n_re '^POST ')" = 0 ] && ok || bad "C9 created a box inside the guard"
[ "$(nbeats)" = 0 ] && ok || bad "C9 beat inside the guard"
cmp -s "$MARK" "$T/mark.before" && ok || bad "C9 rewrote the marker inside the guard"
lane --force; rc=$?
[ "$rc" = 0 ] && ok || bad "C9 --force rc=$rc"
[ "$(n_re '^POST ')" = 1 ] && ok || bad "C9 --force POSTs=$(n_re '^POST ')"
# MIN_INTERVAL_H=0 is off
reset; cp "$T/mark.before" "$MARK"; export RESTORE_DRILL_MIN_INTERVAL_H=0
lane; [ "$(n_re '^POST ')" = 1 ] && ok || bad "C9 interval 0 did not turn the guard off"
# a corrupt marker is not "recent"
reset; printf 'not json\n' > "$MARK"
lane; [ "$(n_re '^POST ')" = 1 ] && ok || bad "C9 corrupt marker read as recent"
[ "$(mk .first_run_ts)" = "$(mk .ts)" ] && ok || bad "C9 corrupt marker: first_run_ts not now"

# --- C9b: lock held -> exit 0, no calls ---------------------------------------
reset
exec 8>"$H/locks/restore-drill.lock"; flock -n 8 || bad "C9b could not take the lock"
lane; rc=$?
exec 8>&-
[ "$rc" = 0 ] && ok || bad "C9b rc=$rc"
[ "$(ncalls)" = 0 ] && [ "$(nbeats)" = 0 ] && ok || bad "C9b calls=$(ncalls) beats=$(nbeats) with the lock held"
[ ! -e "$MARK" ] && ok || bad "C9b wrote a marker with the lock held"

# --- C-notcfg: missing config -> SKIP naming it, no calls, no ALERTS ----------
reset; unset RESTORE_DRILL_TEMPLATE_REF
lane; rc=$?
[ "$rc" = 0 ] && ok || bad "C-notcfg rc=$rc"
[ "$(ncalls)" = 0 ] && ok || bad "C-notcfg calls=$(ncalls)"
[ "$(nbeats)" = 1 ] && ok || bad "C-notcfg beats=$(nbeats)"
beatline | grep -qE '^restore-drill: SKIP not configured - missing: .*RESTORE_DRILL_TEMPLATE_REF.* RPO=unknown$' && ok || bad "C-notcfg beat line=[$(beatline)]"
grep -qE 'ORGO_API_KEY|BACKUP_S3' <<<"$(beatline)" && bad "C-notcfg named a var that is set" || ok
[ "$(nalerts)" = 0 ] && ok || bad "C-notcfg wrote ALERTS"
[ "$(mk .verdict)" = SKIP ] && ok || bad "C-notcfg verdict=$(mk .verdict)"
reset; rm -f "$H/state/box-id"; unset BACKUP_S3_SECRET_ACCESS_KEY
lane; rc=$?
[ "$(ncalls)" = 0 ] && ok || bad "C-notcfg/box-id calls=$(ncalls)"
beatline | grep -qE 'missing: .*BACKUP_S3_SECRET_ACCESS_KEY.*state/box-id' && ok || bad "C-notcfg/box-id beat line=[$(beatline)]"

# --- C-beatfail: a beat that fails never changes the verdict ------------------
reset; export STUB_BEAT_RC=1
lane; rc=$?
[ "$rc" = 0 ] && ok || bad "C-beatfail rc=$rc"
[ "$(mk .verdict)" = OK ] && ok || bad "C-beatfail verdict=$(mk .verdict)"

# --- C-badram: a non-integer size is FAIL before any call ---------------------
reset; export RESTORE_DRILL_RAM_GB=8GB
lane; rc=$?
[ "$rc" = 1 ] && ok || bad "C-badram rc=$rc"
[ "$(ncalls)" = 0 ] && ok || bad "C-badram calls=$(ncalls)"
beatline | grep -qF 'bad RESTORE_DRILL_RAM_GB' && ok || bad "C-badram beat line=[$(beatline)]"

# --- C-badarg -----------------------------------------------------------------
reset
lane --bogus; rc=$?
[ "$rc" = 2 ] && ok || bad "C-badarg rc=$rc"
[ "$(ncalls)" = 0 ] && [ ! -e "$MARK" ] && ok || bad "C-badarg did work"

# --- registry: secrets are never knobs, no template id is invented ------------
R="$DIR/catalog/lanes.d/restore-drill.json"
jq -e '[.knobs[].env] | map(select(.=="ORGO_API_KEY" or startswith("BACKUP_S3_"))) | length==0' "$R" >/dev/null 2>&1 \
  && ok || bad "registry carries a secret as a knob"
jq -e '.knobs[]|select(.env=="RESTORE_DRILL_TEMPLATE_REF")|.default=="" and .settable==false' "$R" >/dev/null 2>&1 \
  && ok || bad "RESTORE_DRILL_TEMPLATE_REF not registered with an empty default, settable:false"
for k in RESTORE_DRILL_MIN_INTERVAL_H:24 RESTORE_DRILL_DEADLINE_S:2700 RESTORE_DRILL_POLL_S:15 RESTORE_DRILL_RAM_GB:8 RESTORE_DRILL_CPU:2 RESTORE_DRILL_CALL_TIMEOUT_S:300; do
  jq -e --arg e "${k%%:*}" --argjson d "${k#*:}" '.knobs[]|select(.env==$e)|.default==$d' "$R" >/dev/null 2>&1 \
    && ok || bad "registry default for ${k%%:*} is not ${k#*:}"
done

echo "restore-drill.bh-1731: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
