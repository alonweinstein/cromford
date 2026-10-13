#!/bin/bash
# tests/flag-audit.bh-5635-test.sh — BH-5635.1: bin/flag.sh on/off/list/history.
#
# Driven, not grepped: every case runs the REAL bin/flag.sh, installed with its
# closure into a scratch root, against a curl stub on PATH. Each case asserts
# the rc, the stderr text, the request sink, the body sink and the flags/ file.
#
#   A1-A3   on: one PUT with name/active/actor/value?/reason?, then the read-back:
#           the cache for a BH-4153 row family (no flags/ file), flags/ for wip-limit
#   A4-A5   non-200 / no secret -> rc 1, "row not written (<status>)", no file
#   A6-A7   bad flag / project -> rc 2, zero requests, no file
#   A8      routing families refused (on AND off), pointer to routing-set
#   A9      off removes an older legacy file; a newer local file is a local
#           hold, rc 3, never success
#   A10     PUT 500 leaves the file alone; PUT 200 with a wrong body is rc 1
#   A11     the secret is never in a request body
#   A12     list [<project>]: the six families only, the 500-row cap is said
#   A13     history: GET /api/flag-changes?name=<name>
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/flag-audit.bh-5635-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/flag.sh" ] || { echo "FAIL: $DIR/bin/flag.sh is missing"; exit 1; }

T1=2026-09-19T01:00:00Z
T2=2026-09-19T02:00:00Z
T3=2026-09-19T03:00:00Z

mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
# The jobs worker, faked: records "METHOD URL" and the body, answers from files.
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac
printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
[ -n "$BODY" ] && printf '%s\n' "$BODY" >> "$BODY_SINK"
if [ -n "${STUB_FAIL_ON:-}" ]; then
  case "$URL" in */api/flags/"$STUB_FAIL_ON") printf '{"error":"boom"}\n500\n'; exit 0 ;; esac
  case "$BODY" in *"\"name\":\"$STUB_FAIL_ON\""*) printf '{"error":"boom"}\n500\n'; exit 0 ;; esac
fi
case "$METHOD $URL" in
  "PUT "*/api/flags)
    st="${STUB_PUT_STATUS:-200}"; b="${STUB_PUT_BODY:-}"
    if [ "$st" != 200 ] || [ -n "$b" ]; then printf '%s\n%s\n' "${b:-{\}}" "$st"; exit 0; fi
    n=$(printf '%s' "$BODY" | jq -r .name)
    printf '%s' "$BODY" | jq -c --arg u "$STUB_UPD" \
      '{flag:{name, active, value:(.value // null), actor, reason:(.reason // null), updated_at:$u}}' > "$ROWS/$n.json"
    cat "$ROWS/$n.json"; printf '\n200\n' ;;
  "GET "*/api/flags/*)
    n="${URL##*/}"
    if [ -s "$ROWS/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "GET "*/api/flags) cat "$STUB_LIST"; printf '\n200\n' ;;
  "GET "*/api/flag-changes*) cat "$STUB_CHANGES"; printf '\n200\n' ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

N=0
mkh() { # mkh -> sets HR to a fresh scratch root with bin/flag.sh and its closure
  N=$((N+1)); HR="$T/h$N"
  mkdir -p "$HR/flags" "$HR/state" "$HR/logs" "$HR/rows"
  scratch_install_closure bin/flag.sh "$HR" >/dev/null || exit 1
  scratch_install_closure bin/jobs-client.sh "$HR" >/dev/null || exit 1
  : > "$HR/req.log"; : > "$HR/body.log"
}
# fl <args...> — runs the real bin/flag.sh in $HR; sets RC, OUT, ERR.
# SEC= (empty) runs with no HARNESS_SECRET at all.
fl() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$HR" JOBS_RETRIES=0 JOBS_URL=https://jobs.invalid \
           ROWS="$HR/rows" REQ_SINK="$HR/req.log" BODY_SINK="$HR/body.log" JOBS_BOX=box-t \
           STUB_UPD="$T2" STUB_LIST="$T/list.json" STUB_CHANGES="$T/changes.json"
    unset H
    if [ -n "${SEC-test-secret-fixture}" ]; then export HARNESS_SECRET="${SEC-test-secret-fixture}"; else unset HARNESS_SECRET; fi
    "$HR/bin/flag.sh" "$@" ) > "$T/out" 2> "$T/err"
  RC=$?; OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
reqs() { grep -c . "$HR/req.log"; }
body() { tail -1 "$HR/body.log"; }

echo "== A1: on paused project-6-os =="
mkh; fl on paused project-6-os
[ "$RC" = 0 ] && ok || bad "A1 rc $RC, want 0 (err: $ERR)"
[ "$(grep -c '^PUT https://jobs.invalid/api/flags$' "$HR/req.log")" = 1 ] && ok || bad "A1 want exactly 1 PUT: $(cat "$HR/req.log")"
[ "$(body | jq -r '.name')" = paused-project-6-os ] && ok || bad "A1 body name: $(body)"
[ "$(body | jq -r '.active')" = 1 ] && ok || bad "A1 body active: $(body)"
[ "$(body | jq -r '.actor')" = box-t ] && ok || bad "A1 body actor: $(body)"
[ "$(body | jq -r 'has("value")')" = false ] && ok || bad "A1 body carries a value key: $(body)"
# BH-4153: paused-* is a harness_flags row. The sync fills the cache and writes
# no flags/ file, and the cache reads the flag as on.
[ ! -e "$HR/flags/paused-project-6-os" ] && ok || bad "A1 a flags/paused-project-6-os file was written for a row family"
[ "$(jq -r .on "$HR/state/flags-cache/fleet/paused-project-6-os" 2>/dev/null)" = true ] && ok \
  || bad "A1 the cache does not read paused-project-6-os as on: $(cat "$HR/state/flags-cache/fleet/paused-project-6-os" 2>/dev/null)"
case "$OUT" in *"paused-project-6-os on (row written, cache synced)"*) ok ;; *) bad "A1 stdout: $OUT" ;; esac

echo "== A2: --reason rides in the body =="
mkh; fl on paused p --reason "hold for audit"
[ "$RC" = 0 ] && ok || bad "A2 rc $RC"
[ "$(body | jq -r '.reason')" = "hold for audit" ] && ok || bad "A2 body reason: $(body)"

echo "== A3: wip-limit needs a positive integer --value =="
mkh; fl on wip-limit p --value 5
[ "$RC" = 0 ] && ok || bad "A3 rc $RC (err: $ERR)"
[ "$(body | jq -r '.value')" = 5 ] && ok || bad "A3 body value: $(body)"
[ "$(cat "$HR/flags/wip-limit-p" 2>/dev/null)" = 5 ] && ok || bad "A3 flags/wip-limit-p content '$(cat "$HR/flags/wip-limit-p" 2>/dev/null)', want 5"
for v in abc 0 -3 '5; rm -rf' 1234567; do
  mkh; fl on wip-limit p --value "$v"
  [ "$RC" = 1 ] && ok || bad "A3 --value '$v' rc $RC, want 1"
  [ "$(reqs)" = 0 ] && ok || bad "A3 --value '$v' sent a request"
  [ ! -e "$HR/flags/wip-limit-p" ] && ok || bad "A3 --value '$v' wrote a file"
done
mkh; fl on wip-limit p
[ "$RC" = 1 ] && ok || bad "A3b no --value rc $RC, want 1"
[ "$(reqs)" = 0 ] && ok || bad "A3b no --value sent a request"
case "$ERR" in *"wip-limit needs --value <positive integer>"*) ok ;; *) bad "A3b stderr: $ERR" ;; esac
mkh; fl on paused p --value 5
[ "$RC" = 2 ] && ok || bad "A3c --value on paused rc $RC, want 2"
[ "$(reqs)" = 0 ] && ok || bad "A3c --value on paused sent a request"
mkh; fl off wip-limit p --value 5
[ "$RC" = 2 ] && ok || bad "A3d --value on off rc $RC, want 2"
[ "$(reqs)" = 0 ] && ok || bad "A3d --value on off sent a request"

echo "== A4: PUT 401 -> row not written, no file, no read-back =="
mkh; STUB_PUT_STATUS=401 fl on paused p
[ "$RC" = 1 ] && ok || bad "A4 rc $RC, want 1"
case "$ERR" in *"flag.sh: row not written (401)"*) ok ;; *) bad "A4 stderr: $ERR" ;; esac
[ ! -e "$HR/flags/paused-p" ] && ok || bad "A4 flags/paused-p written after a 401"
[ "$(reqs)" = 1 ] && ok || bad "A4 want only the PUT: $(cat "$HR/req.log")"
case "$OUT$ERR" in *"row written"*|*synced*) bad "A4 claims a write: $OUT$ERR" ;; *) ok ;; esac
mkh; STUB_PUT_STATUS=409 fl on paused p
[ "$RC" = 1 ] && ok || bad "A4b 409 rc $RC, want 1"
case "$ERR" in *"row not written (409)"*) ok ;; *) bad "A4b stderr: $ERR" ;; esac
[ ! -e "$HR/flags/paused-p" ] && ok || bad "A4b flags/paused-p written after a 409"

echo "== A5: no HARNESS_SECRET -> no request at all =="
mkh; SEC="" fl on paused p
[ "$RC" = 1 ] && ok || bad "A5 rc $RC, want 1"
case "$ERR" in *"row not written (no-secret)"*) ok ;; *) bad "A5 stderr: $ERR" ;; esac
[ "$(reqs)" = 0 ] && ok || bad "A5 sent a request without a secret"
[ ! -e "$HR/flags/paused-p" ] && ok || bad "A5 wrote a file"

echo "== A6/A7: bad names -> rc 2, zero requests =="
for args in "on paused a/b" "on paused .." "on paused ../../x" "on bogus p" "on paused" "off paused a/b" "history paused .." "frobnicate paused p"; do
  mkh; set -- $args; fl "$@"
  [ "$RC" = 2 ] && ok || bad "A6 '$args' rc $RC, want 2"
  [ "$(reqs)" = 0 ] && ok || bad "A6 '$args' sent a request"
  [ -z "$(ls -A "$HR/flags")" ] && ok || bad "A6 '$args' wrote under flags/"
done
mkh; fl on paused 'a/b'
case "$ERR" in *"flag.sh: bad flag or project"*) ok ;; *) bad "A6 stderr: $ERR" ;; esac
[ ! -e "$HR/x" ] && [ ! -e "$T/x" ] && ok || bad "A7 a traversal name created a file"

echo "== A8: routing families are refused, on and off =="
for args in "on fly-pool p" "off fly-pool p" "on builder-fly p" "off builder-fly p" "on fly-pool-app p"; do
  mkh; set -- $args; : > "$HR/flags/$2-$3"; fl "$@"
  [ "$RC" = 2 ] && ok || bad "A8 '$args' rc $RC, want 2"
  case "$ERR" in *"routing flag; use bin/jobs-client.sh routing-set"*) ok ;; *) bad "A8 '$args' stderr: $ERR" ;; esac
  [ "$(reqs)" = 0 ] && ok || bad "A8 '$args' sent a request"
  [ -f "$HR/flags/$2-$3" ] && ok || bad "A8 '$args' touched flags/$2-$3"
done

echo "== A9: off removes an older file; a newer local file is not a success =="
mkh; : > "$HR/flags/paused-p"; touch -d "$T1" "$HR/flags/paused-p"; fl off paused p
[ "$RC" = 0 ] && ok || bad "A9 rc $RC, want 0 (err: $ERR)"
[ "$(body | jq -r '.active')" = 0 ] && ok || bad "A9 body active: $(body)"
[ ! -e "$HR/flags/paused-p" ] && ok || bad "A9 flags/paused-p still there after off"
[ "$(jq -r .on "$HR/state/flags-cache/fleet/paused-p" 2>/dev/null)" = false ] && ok \
  || bad "A9 the cache does not read paused-p as off: $(cat "$HR/state/flags-cache/fleet/paused-p" 2>/dev/null)"
case "$OUT" in *"paused-p off (row written, cache synced)"*) ok ;; *) bad "A9 stdout: $OUT" ;; esac
# A9c: off with no legacy file at all is a plain success.
mkh; fl off paused p
[ "$RC" = 0 ] && ok || bad "A9c off with no file rc $RC, want 0 (err: $ERR)"
mkh; : > "$HR/flags/paused-p"; touch -d "$T3" "$HR/flags/paused-p"; fl off paused p
[ "$RC" = 3 ] && ok || bad "A9b newer local file rc $RC, want 3"
case "$ERR" in *"row written; paused-p not synced on this box (a newer local flags/paused-p is a local hold)"*) ok ;; *) bad "A9b stderr: $ERR" ;; esac
case "$OUT" in *synced\)*) bad "A9b reported success: $OUT" ;; *) ok ;; esac
[ -f "$HR/flags/paused-p" ] && ok || bad "A9b LWW should keep the newer local file"

echo "== A10: a failed or unconfirmed PUT never touches flags/ =="
mkh; : > "$HR/flags/paused-p"; touch -d "$T1" "$HR/flags/paused-p"; M0=$(stat -c %Y "$HR/flags/paused-p")
STUB_PUT_STATUS=500 STUB_PUT_BODY='{}' fl off paused p
[ "$RC" = 1 ] && ok || bad "A10 rc $RC, want 1"
case "$ERR" in *"row not written (500)"*) ok ;; *) bad "A10 stderr: $ERR" ;; esac
[ -f "$HR/flags/paused-p" ] && [ "$(stat -c %Y "$HR/flags/paused-p")" = "$M0" ] && ok || bad "A10 flags/paused-p changed after a 500"
mkh; STUB_PUT_BODY='{}' fl on paused p
[ "$RC" = 1 ] && ok || bad "A10b 200 {} rc $RC, want 1"
case "$ERR" in *"row not confirmed (bad response)"*) ok ;; *) bad "A10b stderr: $ERR" ;; esac
[ "$(reqs)" = 1 ] && ok || bad "A10b a read-back followed an unconfirmed PUT: $(cat "$HR/req.log")"
[ ! -e "$HR/flags/paused-p" ] && ok || bad "A10b wrote a file"
mkh; STUB_PUT_BODY='{"flag":{"name":"paused-other","active":1,"updated_at":"'"$T2"'"}}' fl on paused p
[ "$RC" = 1 ] && ok || bad "A10c row for another name rc $RC, want 1"
[ ! -e "$HR/flags/paused-p" ] && [ ! -e "$HR/flags/paused-other" ] && ok || bad "A10c wrote a file"
mkh; STUB_PUT_BODY='{"flag":{"name":"paused-p","active":0,"updated_at":"'"$T2"'"}}' fl on paused p
[ "$RC" = 1 ] && ok || bad "A10d row with the wrong active rc $RC, want 1"

echo "== A11: the secret never rides in a body =="
ALLB=$(cat "$T"/h*/body.log)
[ -n "$ALLB" ] && ok || bad "A11 no bodies were recorded at all"
case "$ALLB" in *test-secret-fixture*) bad "A11 a request body carries the secret" ;; *) ok ;; esac

echo "== A12: list [<project>] =="
cat > "$T/list.json" <<EOF
{"flags":[
 {"name":"paused-p","active":1,"value":null,"actor":"operator","updated_at":"$T1"},
 {"name":"wip-limit-p","active":1,"value":"4","actor":"box-t","updated_at":"$T2"},
 {"name":"lane-off-x","active":1,"value":null,"actor":"operator","updated_at":"$T1"},
 {"name":"paused-q","active":0,"value":null,"actor":"seed","updated_at":"$T1"}]}
EOF
mkh; fl list p
[ "$RC" = 0 ] && ok || bad "A12 list p rc $RC (err: $ERR)"
WANT=$(printf 'paused-p\t1\t-\toperator\t%s\nwip-limit-p\t1\t4\tbox-t\t%s' "$T1" "$T2")
[ "$OUT" = "$WANT" ] && ok || bad "A12 list p printed: $OUT"
[ "$(cat "$HR/req.log")" = "GET https://jobs.invalid/api/flags" ] && ok || bad "A12 requests: $(cat "$HR/req.log")"
mkh; fl list
[ "$RC" = 0 ] && ok || bad "A12b list rc $RC"
[ "$(printf '%s\n' "$OUT" | grep -c .)" = 3 ] && ok || bad "A12b list printed: $OUT"
case "$OUT" in *lane-off-x*) bad "A12b list shows a lane switch" ;; *) ok ;; esac
case "$ERR" in *"first 500"*) bad "A12b cap note on a 4-row list" ;; *) ok ;; esac
jq -c '{flags:[range(500) as $i | {name:("paused-p\($i)"),active:1,value:null,actor:"a",updated_at:"x"}]}' -n > "$T/list.json"
mkh; fl list
case "$ERR" in *"list shows the first 500 rows (worker cap)"*) ok ;; *) bad "A12c no cap note at 500 rows: $ERR" ;; esac
mkh; fl list 'a/b'
[ "$RC" = 2 ] && [ "$(reqs)" = 0 ] && ok || bad "A12d list a/b rc $RC, requests $(reqs)"
mkh; STUB_LIST=/nonexistent SEC="" fl list
[ "$RC" = 1 ] && ok || bad "A12e list with no secret rc $RC"
case "$ERR" in *"list failed (no-secret)"*) ok ;; *) bad "A12e stderr: $ERR" ;; esac

echo "== A13: history =="
cat > "$T/changes.json" <<EOF
{"changes":[{"id":7,"kind":"flag","name":"paused-p","before_json":null,"after_json":"{\"active\":1}","actor":"op-operator","reason":"audit","at":"$T2"}],"truncated":false}
EOF
mkh; fl history paused p
[ "$RC" = 0 ] && ok || bad "A13 rc $RC (err: $ERR)"
[ "$(cat "$HR/req.log")" = "GET https://jobs.invalid/api/flag-changes?name=paused-p" ] && ok || bad "A13 requests: $(cat "$HR/req.log")"
case "$OUT" in *"$T2 op-operator"*'{"active":1}'*audit*) ok ;; *) bad "A13 stdout: $OUT" ;; esac
printf '{"changes":[],"truncated":true}' > "$T/changes.json"
mkh; fl history automerge-disabled
[ "$(cat "$HR/req.log")" = "GET https://jobs.invalid/api/flag-changes?name=automerge-disabled" ] && ok || bad "A13b requests: $(cat "$HR/req.log")"
case "$ERR" in *truncated*) ok ;; *) bad "A13b no truncated note: $ERR" ;; esac

echo "flag-audit.bh-5635: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
