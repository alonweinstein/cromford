#!/bin/bash
# tests/flag-on-routing-rows.bh-5960-test.sh — BH-5960: bin/lib/flag-on.sh asks
# flag_active first for a PORTED routing name (builder-fly-*, fly-pool-*,
# fly-pool-app-*), after routing_sync, when a worker is configured. Unknown
# (worker down, nothing cached) reads OFF: a routing flag is not a stop switch.
#
# Driven, not grepped: each case sources the real bin/lib/flag-on.sh and the real
# bin/jobs-client.sh against a curl stub, then ports the routing names the way
# BH-4154 (#4546) does by extending FLAG_PORTED_RE. It asserts rc, stdout, files
# and the request sink.
#
#   R1-R3b  row ON, no flags/ file -> ON (and the row's value)
#   R4/R4b  row cleared / no row -> OFF
#   R5      worker down after a good read -> the last-good cache answers ON
#   R6      worker down, nothing cached -> OFF, no outage marker, no ALERTS line
#   R7      paused-p in the same outage -> ON (stop switch unchanged)
#   R8      JOBS_URL set, HARNESS_SECRET empty -> the file, no /api/flags request
#   R9      no worker, or an unported name -> the file, as before
#   R10     legacy file present, no row -> ON (local hold)
#   R11     routing_sync still runs before the row read
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/flag-on-routing-rows.bh-5960-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/flag-on.sh" ] || { echo "FAIL: $DIR/bin/lib/flag-on.sh is missing"; exit 1; }

mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*/api/flags/*)
    [ -n "${DOWN:-}" ] && { printf 'err\n500\n'; exit 0; }
    rest="${URL##*/api/flags/}"; n="${rest%%\?*}"; s=fleet
    case "$rest" in *\?scope=*) s="${rest##*\?scope=}"; s="${s%%&*}" ;; esac
    if [ -s "${ROWS:-/nonexistent}/$n.json" ]; then jq -c --arg s "$s" '.flag.scope=$s' "$ROWS/$n.json"; printf '200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "GET "*/api/routing/*)
    [ -n "${DOWN:-}" ] && { printf 'err\n500\n'; exit 0; }
    n="routing-${URL##*/}"
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
# bin/jobs-client.sh reloads an empty secret from env/global.env, so the
# no-secret root carries an empty one.
mkh_nosecret() { mkh "$1"; : > "$1/env/global.env"; }
# row <root> <name> <value-json|null> [cleared] — a harness_flags row.
row() {
  local cl=null; [ -n "${4:-}" ] && cl='"2026-09-19T02:00:00Z"'
  printf '{"flag":{"name":"%s","value":%s,"set_at":"2026-09-19T01:00:00Z","cleared_at":%s}}' "$2" "$3" "$cl" > "$1/rows/$2.json"
}
# fo <root> <fn> [args...] — JURL (empty = no worker), JSEC (empty = no secret),
# DOWN (the worker answers 500), RR (ROUTING_ROWS). UNPORTED=1 skips the port.
fo() {
  local HR="$1"; shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$HR" HARNESS_SECRET="${JSEC-test-secret-fixture}" JOBS_RETRIES=0 \
           JOBS_URL="${JURL-https://jobs.invalid}" ROWS="$HR/rows" REQ_SINK="$HR/req.log" JOBS_BOX=box-t
    [ -n "${RR:-}" ] && export ROUTING_ROWS="$RR"
    [ -n "${DOWN:-}" ] && export DOWN
    unset H
    . "$HR/bin/lib/flag-on.sh" || exit 3
    . "$HR/bin/jobs-client.sh" 2>/dev/null || exit 3
    # BH-4154 ports the routing families; a superset no-op once it has.
    [ "${UNPORTED:-}" = 1 ] || FLAG_PORTED_RE="${FLAG_PORTED_RE%)\$}|builder-fly-.+|fly-pool-.+)\$"
    "$@" 2>/dev/null )
}
N=0
fresh() { N=$((N+1)); H1="$T/r$N"; "${1:-mkh}" "$H1"; }

echo "== R1: row fly-pool-p ON, no file -> ON =="
fresh; row "$H1" fly-pool-p null
fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 0 ] && ok || bad "R1: flag_on fly-pool p rc $RC, want 0"
grep -q '^GET .*/api/flags/fly-pool-p$' "$H1/req.log" 2>/dev/null && ok || bad "R1: no GET /api/flags/fly-pool-p request"
[ ! -e "$H1/flags/fly-pool-p" ] && ok || bad "R1: the read wrote flags/fly-pool-p"
[ ! -e "$H1/state/flags-cache/fly-pool-p.json" ] && ok || bad "R1: the read wrote the pause_flags cache"
[ ! -e "$H1/state/flags-cache/.outage" ] && ok || bad "R1: the read opened an outage"

echo "== R2: row builder-fly-p ON, no file -> ON =="
fresh; row "$H1" builder-fly-p null
fo "$H1" flag_on builder-fly p; RC=$?
[ "$RC" = 0 ] && ok || bad "R2: flag_on builder-fly p rc $RC, want 0"

echo "== R3: row fly-pool-app-p = pool-x -> flag_value prints pool-x =="
fresh; row "$H1" fly-pool-app-p '"pool-x"'
V=$(fo "$H1" flag_value fly-pool-app p); RC=$?
[ "$RC" = 0 ] && ok || bad "R3: flag_value fly-pool-app p rc $RC, want 0"
[ "$V" = pool-x ] && ok || bad "R3: flag_value printed '$V', want 'pool-x'"
echo "-- R3b: ON with no value -> rc 0, nothing printed"
fresh; row "$H1" fly-pool-app-p null
V=$(fo "$H1" flag_value fly-pool-app p); RC=$?
[ "$RC" = 0 ] && ok || bad "R3b: rc $RC, want 0"
[ -z "$V" ] && ok || bad "R3b: printed '$V', want nothing"

echo "== R4: row cleared / no row -> OFF =="
fresh; row "$H1" fly-pool-p null cleared
fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 1 ] && ok || bad "R4: cleared row rc $RC, want 1"
fresh
fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 1 ] && ok || bad "R4b: no row rc $RC, want 1"

echo "== R5: worker down after a good read -> the last-good cache answers ON =="
fresh; row "$H1" fly-pool-p null
fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 0 ] && ok || bad "R5: first read rc $RC, want 0"
DOWN=1 fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 0 ] && ok || bad "R5: outage read rc $RC, want 0 from the cache"

echo "== R6: worker down, nothing cached, no file -> OFF =="
fresh; row "$H1" fly-pool-p null; row "$H1" fly-pool-app-p '"pool-x"'
DOWN=1 fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 1 ] && ok || bad "R6: flag_on rc $RC, want 1 (unknown routing = OFF)"
V=$(DOWN=1 fo "$H1" flag_value fly-pool-app p); RC=$?
[ "$RC" = 1 ] && ok || bad "R6: flag_value rc $RC, want 1"
[ -z "$V" ] && ok || bad "R6: flag_value printed '$V', want nothing"
[ ! -e "$H1/state/flags-cache/.outage" ] && ok || bad "R6: the routing read opened an outage marker"
grep -q '\[flags\]' "$H1/logs/ALERTS.log" 2>/dev/null && bad "R6: an ALERTS [flags] line was written" || ok

echo "== R7: paused-p in the same outage -> ON (unchanged) =="
fresh
DOWN=1 fo "$H1" flag_on paused p; RC=$?
[ "$RC" = 0 ] && ok || bad "R7: paused-p rc $RC, want 0 (stop switch fails closed)"

echo "== R8: JOBS_URL set, HARNESS_SECRET empty -> the file =="
fresh mkh_nosecret; row "$H1" fly-pool-p null
JSEC="" fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 1 ] && ok || bad "R8: no file rc $RC, want 1"
: > "$H1/flags/fly-pool-p"
JSEC="" fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 0 ] && ok || bad "R8: file rc $RC, want 0"
grep -q '/api/flags/' "$H1/req.log" 2>/dev/null && bad "R8: a /api/flags/ request was sent with no secret" || ok

echo "== R9: no worker, or an unported name -> the file =="
fresh; : > "$H1/flags/fly-pool-p"
JURL="" fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 0 ] && ok || bad "R9a: rc $RC, want 0"
rm -f "$H1/flags/fly-pool-p"
JURL="" fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 1 ] && ok || bad "R9b: rc $RC, want 1"
printf 'pool-x\n' > "$H1/flags/fly-pool-app-p"
V=$(JURL="" fo "$H1" flag_value fly-pool-app p)
[ "$V" = pool-x ] && ok || bad "R9c: printed '$V', want 'pool-x'"
[ ! -e "$H1/req.log" ] && ok || bad "R9: the not-configured path sent a request"
fresh; row "$H1" fly-pool-p null
UNPORTED=1 fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 1 ] && ok || bad "R9d: unported, row ON, no file rc $RC, want 1 (the file answers)"
: > "$H1/flags/fly-pool-p"
UNPORTED=1 fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 0 ] && ok || bad "R9d: unported, file present rc $RC, want 0"

echo "== R10: legacy file present, no row -> ON =="
fresh; : > "$H1/flags/fly-pool-p"
fo "$H1" flag_on fly-pool p; RC=$?
[ "$RC" = 0 ] && ok || bad "R10: rc $RC, want 0 (the legacy file is a local hold)"

echo "== R11: routing_sync runs before the row read =="
fresh
RR=on fo "$H1" flag_on fly-pool p
ri=$(grep -n '/api/routing/p$' "$H1/req.log" 2>/dev/null | head -1 | cut -d: -f1)
fi_=$(grep -n '/api/flags/fly-pool-p$' "$H1/req.log" 2>/dev/null | head -1 | cut -d: -f1)
[ -n "$ri" ] && [ -n "$fi_" ] && [ "$ri" -lt "$fi_" ] && ok \
  || bad "R11: want GET /api/routing/p (line ${ri:-none}) before GET /api/flags/fly-pool-p (line ${fi_:-none})"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
