#!/bin/bash
# tests/flag-db-parity.bh-5635-test.sh — BH-5635.0: bin/lib/flag-on.sh gives the
# same answer from the DB row as from the flags/ file, and flag_sync writes a
# row's value as the file's content.
#
# Driven, not grepped: each case sources the real bin/lib/flag-on.sh (and through
# it the real bin/jobs-client.sh) against a curl stub, and asserts rc, stdout,
# file bytes, mtimes and the request sink.
#
#   P1-P6  every family x state: DB path (rows, JOBS_URL set) == file path (JOBS_URL empty)
#   P-404  no row: the file answers, the cache is not written
#   P7     flag_sync writes value content; P7b refuses a bad value; P7c newer local content wins
#   P8     bad flag / project -> rc 2, no request, no file
#   P9     HARNESS and H unset -> rc 2
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/flag-db-parity.bh-5635-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/flag-on.sh" ] || { echo "FAIL: $DIR/bin/lib/flag-on.sh is missing"; exit 1; }

NOW=$(date -u +%s)
T1=2026-09-19T01:00:00Z; E1=1789779600
T2=2026-09-19T02:00:00Z

mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*/api/flags/*|"GET "*/api/routing/*)
    n="${URL##*/}"; case "$URL" in */api/routing/*) n="routing-$n" ;; esac
    if [ -s "${ROWS:-/nonexistent}/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

mkh() {
  mkdir -p "$1/flags" "$1/state" "$1/logs" "$1/env" "$1/rows"
  scratch_install_closure bin/jobs-client.sh "$1" >/dev/null || exit 1
  scratch_install_closure bin/lib/flag-on.sh "$1" >/dev/null || exit 1
  scratch_install_closure bin/alert-line.sh "$1" >/dev/null || exit 1
  cp "$DIR/bin/alert_family.py" "$1/bin/" || exit 1
  echo "HARNESS_SECRET=test-secret-fixture" > "$1/env/global.env"
}
row() { # row <root> <name> <active-json> [value-json] [updated_at]
  printf '{"flag":{"name":"%s","active":%s,"updated_at":"%s","value":%s}}' "$2" "$3" "${5:-$T1}" "${4:-null}" > "$1/rows/$2.json"
}
# fo <root> <fn> [args...] — JURL (default the stub URL; empty = not configured).
fo() {
  local HR="$1"; shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$HR" HARNESS_SECRET=test-secret-fixture JOBS_RETRIES=0 \
           JOBS_URL="${JURL-https://jobs.invalid}" ROWS="$HR/rows" REQ_SINK="$HR/req.log" JOBS_BOX=box-t
    [ -n "${RR:-}" ] && export ROUTING_ROWS="$RR"
    unset H
    . "$HR/bin/lib/flag-on.sh" || exit 3
    "$@" 2>/dev/null )
}
mt() { stat -c %Y "$1" 2>/dev/null; }
# sync_via_client <name> — a caller that sourced the client itself, then flag_sync.
sync_via_client() { . "$HARNESS/bin/jobs-client.sh" || return 3; flag_sync "$1"; }
N=0
# pair <label> <flag> <project> <db-setup-fn> <file-setup-fn>: same rc and value.
pair() {
  local L="$1" flag="$2" p="$3" dbh fh drc frc dv fv
  N=$((N+1)); dbh="$T/db$N"; fh="$T/file$N"; mkh "$dbh"; mkh "$fh"
  "$4" "$dbh"; "$5" "$fh"
  dv=$(fo "$dbh" flag_value "$flag" "$p"); drc=$?
  fv=$(JURL="" fo "$fh" flag_value "$flag" "$p"); frc=$?
  [ "$drc" = "$frc" ] && ok || bad "$L: rc DB $drc != file $frc"
  [ "$dv" = "$fv" ] && ok || bad "$L: value DB '$dv' != file '$fv'"
  [ "$drc" = "${WANT_RC}" ] && ok || bad "$L: rc $drc, want $WANT_RC"
  [ "$dv" = "${WANT_V}" ] && ok || bad "$L: value '$dv', want '$WANT_V'"
  [ ! -e "$fh/req.log" ] && ok || bad "$L: the not-configured path sent a request"
}

echo "== P1-P3: pause_flags families (paused, wip-limit, automerge-disabled) =="
db_on()   { row "$1" "$NAME" 1; }
db_off()  { row "$1" "$NAME" 0; }
db_val()  { row "$1" "$NAME" 1 '"5"'; }
f_on()    { : > "$1/flags/$NAME"; }
f_off()   { :; }
f_val()   { printf '5\n' > "$1/flags/$NAME"; }
for fam in "paused p" "wip-limit p" "automerge-disabled -"; do
  set -- $fam; FL=$1; PR=$2; [ "$PR" = - ] && PR=""
  NAME="$FL${PR:+-$PR}"
  WANT_RC=0 WANT_V="";  pair "$NAME on"         "$FL" "$PR" db_on  f_on
  WANT_RC=1 WANT_V="";  pair "$NAME off"        "$FL" "$PR" db_off f_off
  # TEST-CHANGE (BH-5639 merge with BH-4153): paused-* and automerge-disabled*
  # are harness_flags rows now (flag_on reads them through flag_active), and a
  # stop switch carries no value, so the value pair is the pause_flags family's.
  [ "$FL" = wip-limit ] || continue
  WANT_RC=0 WANT_V="5"; pair "$NAME with value" "$FL" "$PR" db_val f_val
done

echo "== P4-P6: routing families (builder-fly, fly-pool, fly-pool-app) =="
rrow() { printf '{"routing":{"project":"p","builder":"%s","pool_app":%s,"halted":0,"updated_at":"%s"}}' "$2" "$3" "$T1" > "$1/rows/routing-p.json"; }
db_local() { rrow "$1" local null; }
db_fly1()  { rrow "$1" fly1 null; }
db_pool()  { rrow "$1" pool '"app1"'; }
fr_local() { :; }
fr_fly1()  { : > "$1/flags/builder-fly-p"; }
fr_pool()  { : > "$1/flags/builder-fly-p"; : > "$1/flags/fly-pool-p"; printf 'app1\n' > "$1/flags/fly-pool-app-p"; }
export RR=on
WANT_RC=1 WANT_V="";     pair "builder-fly local"  builder-fly  p db_local fr_local
WANT_RC=0 WANT_V="";     pair "builder-fly fly1"   builder-fly  p db_fly1  fr_fly1
WANT_RC=1 WANT_V="";     pair "fly-pool fly1"      fly-pool     p db_fly1  fr_fly1
WANT_RC=0 WANT_V="";     pair "fly-pool pool"      fly-pool     p db_pool  fr_pool
WANT_RC=1 WANT_V="";     pair "fly-pool-app local" fly-pool-app p db_local fr_local
WANT_RC=0 WANT_V="app1"; pair "fly-pool-app pool"  fly-pool-app p db_pool  fr_pool
[ ! -e "$T/db$N/state/flags-cache/fly-pool-app-p.json" ] && ok || bad "P6: a routing family wrote a flags-cache entry"
grep -q '/api/routing/p' "$T/db$N/req.log" 2>/dev/null && ok || bad "P6: the routing family never asked routing_sync"
unset RR

echo "== P-404: no row: the file answers, the cache stays absent =="
P4="$T/p404"; mkh "$P4"; touch -d "@$E1" "$P4/flags/paused-p"
fo "$P4" flag_on paused p; RC=$?
[ "$RC" = 0 ] && ok || bad "P-404: rc $RC with the file present"
[ "$(mt "$P4/flags/paused-p")" = "$E1" ] && ok || bad "P-404: the file changed"
[ ! -e "$P4/state/flags-cache/paused-p.json" ] && ok || bad "P-404: a 404 wrote the cache"
[ ! -e "$P4/state/flags-cache/.outage" ] && ok || bad "P-404: a 404 opened an outage"

echo "== P7: flag_sync writes the row's value as the file content =="
P7="$T/p7"; mkh "$P7"; row "$P7" wip-limit-p 1 '"5"'
fo "$P7" flag_on wip-limit p; RC=$?
[ "$RC" = 0 ] && ok || bad "P7: rc $RC"
[ "$(cat "$P7/flags/wip-limit-p" 2>/dev/null)" = 5 ] && ok || bad "P7: file content '$(cat "$P7/flags/wip-limit-p" 2>/dev/null)', want 5"
[ "$(mt "$P7/flags/wip-limit-p")" = "$E1" ] && ok || bad "P7: mtime $(mt "$P7/flags/wip-limit-p"), want the row's $E1"
compgen -G "$P7/flags/*.tmp.*" >/dev/null && bad "P7: a tmp file was left in flags/" || ok
fo "$P7" flag_on wip-limit p
[ "$(mt "$P7/flags/wip-limit-p")" = "$E1" ] && ok || bad "P7: an equal-content re-read touched the file"
row "$P7" wip-limit-p 1 '"7"' "$T2"
fo "$P7" flag_on wip-limit p
[ "$(cat "$P7/flags/wip-limit-p" 2>/dev/null)" = 7 ] && ok || bad "P7: a newer row value did not replace the content"
echo "-- P7b: a value outside the alphabet is refused"
P7B="$T/p7b"; mkh "$P7B"; row "$P7B" wip-limit-p 1 '"../x"'
fo "$P7B" sync_via_client wip-limit-p; RC=$?
[ "$RC" = 1 ] && ok || bad "P7b: flag_sync rc $RC on a bad value, want 1"
[ ! -e "$P7B/flags/wip-limit-p" ] && ok || bad "P7b: a refused value wrote the file"
[ "$(grep -c 'value refused' "$P7B/logs/jobs-client.log" 2>/dev/null)" = 1 ] && ok || bad "P7b: want 1 'value refused' line in jobs-client.log"
fo "$P7B" flag_on wip-limit p; RC=$?
[ "$RC" = 1 ] && ok || bad "P7b: flag_on rc $RC on a refused row with no cache or file"
[ ! -e "$P7B/flags/wip-limit-p" ] && ok || bad "P7b: flag_on wrote a refused value"
echo "-- P7c: a local file newer than the row keeps its content"
P7C="$T/p7c"; mkh "$P7C"; row "$P7C" wip-limit-p 1 '"5"'
printf '3\n' > "$P7C/flags/wip-limit-p"; touch -d "@$NOW" "$P7C/flags/wip-limit-p"
OUT=$(fo "$P7C" flag_value wip-limit p)
[ "$(cat "$P7C/flags/wip-limit-p")" = 3 ] && ok || bad "P7c: an older row overwrote a newer local value"
[ "$OUT" = 3 ] && ok || bad "P7c: flag_value '$OUT', want the file's 3"

echo "== P8: bad names are rc 2 with no request and no file =="
P8="$T/p8"; mkh "$P8"
for args in "paused a/b" "paused ../../x" "lanedown p" "paused-x p" "paused" "paused .." "wip-limit" "builder-fly"; do
  # shellcheck disable=SC2086
  fo "$P8" flag_on $args; RC=$?
  [ "$RC" = 2 ] && ok || bad "P8: flag_on $args answered rc $RC, want 2"
done
fo "$P8" flag_on paused ""; RC=$?
[ "$RC" = 2 ] && ok || bad "P8: flag_on paused '' answered rc $RC, want 2"
[ ! -e "$P8/req.log" ] && ok || bad "P8: a bad name sent a request: $(cat "$P8/req.log")"
[ -z "$(ls -A "$P8/flags")" ] && ok || bad "P8: a bad name wrote under flags/"
fo "$P8" flag_on automerge-disabled; RC=$?
[ "$RC" = 1 ] && ok || bad "P8: flag_on automerge-disabled answered rc $RC, want 1 (valid, no row, no file)"
grep -q '/api/flags/automerge-disabled' "$P8/req.log" 2>/dev/null && ok || bad "P8: automerge-disabled did not read its row"

echo "== P9: no root is rc 2 =="
P9="$T/p9"; mkh "$P9"
( unset HARNESS H; export PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid REQ_SINK="$P9/req.log"
  . "$P9/bin/lib/flag-on.sh" || exit 3; flag_on paused p 2>/dev/null ); RC=$?
[ "$RC" = 2 ] && ok || bad "P9: HARNESS and H unset answered rc $RC, want 2"
[ ! -e "$P9/req.log" ] && ok || bad "P9: no root still sent a request"

echo
echo "flag-db-parity.bh-5635: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
