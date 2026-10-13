#!/bin/bash
# tests/flag-callsites-pool.bh-5635-test.sh — BH-5635.3: the pool routing and
# WIP-limit call sites read through bin/lib/flag-on.sh, not a raw flags/ test.
#
# Modules under test: bin/free-slots.sh bin/fleet-propagate.sh
# bin/fly-results-ingest.sh bin/split-watchdog.sh bin/fly-machine-state.sh
# bin/fleet-status-push.sh bin/pr-owner-sweep.sh bin/fly-dispatch.sh
# bin/healthcheck.sh bin/fly-pool-tick.sh bin/blocked-resolver.sh
# bin/harness-sync.sh bin/pipeline-health.sh bin/lib/flag-on.sh
#
#   G1 the ticket's grep gate prints nothing (the 13 files exist first)
#   G2 each of the 13 scripts sources bin/lib/flag-on.sh
#   G3 the two publishers use flag_file_on, never flag_on
#   G4 blocked-resolver.sh keeps its own flag_on and has no top-level source
#   D1 driven: a wip-limit row (active 1, value 5) and no file -> first word 5
#   D2 driven: the row is 404 and no file -> first word unlimited
#   D3 driven: API down, cache {active:1,value:"3"}, no file -> first word 3
#   M1 mutation guard (D1): free-slots.sh back to `cat flags/wip-limit-` misses the row
#   D4 driven: the client is present but bin/lib/jobs/ is not -> free-slots.sh
#      still answers from flags/builder-fly-p (the client's exit must not end it)
#   M2 mutation guard (D1): flag-on.sh without the bin/lib/jobs/ check fails D4
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/flag-callsites-pool.bh-5635-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SCRIPTS="bin/fleet-propagate.sh bin/fly-results-ingest.sh bin/split-watchdog.sh bin/fly-machine-state.sh
bin/fleet-status-push.sh bin/pr-owner-sweep.sh bin/fly-dispatch.sh bin/healthcheck.sh bin/fly-pool-tick.sh
bin/blocked-resolver.sh bin/free-slots.sh bin/harness-sync.sh bin/pipeline-health.sh"

echo "== G1: no raw [ -f ] test of a routing or wip-limit flag outside bin/lib =="
for s in $SCRIPTS; do [ -f "$DIR/$s" ] || bad "G1: $s is missing"; done
HITS=$(cd "$DIR" && grep -rnE '\[ !? ?-f .*flags/(wip-limit|fly-pool|builder-fly)' bin cron fly 2>/dev/null | grep -v '^bin/lib/')
[ -z "$HITS" ] && ok || bad "G1: raw flag tests remain:
$HITS"

echo "== G2: every changed script sources bin/lib/flag-on.sh =="
for s in $SCRIPTS; do
  grep -qE '(^|[;({]|then|else) *\. ".*/lib/flag-on\.sh"' "$DIR/$s" && ok || bad "G2: $s does not source bin/lib/flag-on.sh"
  grep -qE '\b(flag_on|flag_value|flag_file_on) [a-z-]+ "\$' "$DIR/$s" && ok || bad "G2: $s makes no flag_on/flag_value/flag_file_on call"
done

echo "== G3: the publishers read the file only (flag_file_on) =="
for s in bin/harness-sync.sh bin/pipeline-health.sh; do
  grep -q 'flag_file_on builder-fly' "$DIR/$s" && ok || bad "G3: $s has no 'flag_file_on builder-fly'"
  grep -q 'flag_file_on fly-pool' "$DIR/$s" && ok || bad "G3: $s has no 'flag_file_on fly-pool'"
  grep -qE '(^|[^_a-z])flag_on ' "$DIR/$s" && bad "G3: $s calls flag_on (a publisher must not feed the row back into itself)" || ok
done

echo "== G4: blocked-resolver.sh keeps its own flag_on; the lib is sourced only in a subshell =="
BR="$DIR/bin/blocked-resolver.sh"
grep -q '^flag_on() { if command -v flag_active' "$BR" && ok || bad "G4: blocked-resolver.sh lost its own flag_on"
grep -qE '^\. .*flag-on\.sh' "$BR" && bad "G4: blocked-resolver.sh sources flag-on.sh at top level (it would replace its own flag_on)" || ok
grep -qE '^br_pool_routed\(\).*\( \. "\$H/bin/lib/flag-on\.sh".*flag_on fly-pool "\$1" \)' "$BR" && ok \
  || bad "G4: br_pool_routed does not read fly-pool through the lib in a subshell"


T1=2026-10-09T01:00:00Z
# The stub answers GET /api/flags/<name> from $ROWS/<name>.json (404 when there
# is no such file) and records every request. CURL_MODE=down is the outage arm.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$METHOD $URL" in
  "GET "*/api/flags/*)
    n="${URL##*/}"
    if [ -s "${ROWS:-/nonexistent}/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# mkh <root> — a scratch harness with the real free-slots.sh and what it reads.
mkh() {
  mkdir -p "$1/flags" "$1/state" "$1/logs" "$1/env" "$1/rows"
  scratch_install_closure bin/free-slots.sh "$1" >/dev/null || exit 1
  scratch_install_closure bin/jobs-client.sh "$1" >/dev/null || exit 1
  scratch_install_closure bin/lib/flag-on.sh "$1" >/dev/null || exit 1
  scratch_install_closure bin/alert-line.sh "$1" >/dev/null || exit 1
  cp "$DIR/bin/alert_family.py" "$1/bin/" || exit 1
  echo "HARNESS_SECRET=test-secret-fixture" > "$1/env/global.env"
}
row() { # row <root> <name> <active-json> [value-json]
  printf '{"flag":{"name":"%s","active":%s,"updated_at":"%s","value":%s}}' "$2" "$3" "$T1" "${4:-null}" > "$1/rows/$2.json"
}
# fs <root> <project> — run the real free-slots.sh in <root>; prints its stdout.
fs() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$1" HARNESS_SECRET=test-secret-fixture JOBS_RETRIES=0 \
           JOBS_URL=https://jobs.invalid ROWS="$1/rows" REQ_SINK="$1/req.log" JOBS_BOX=box-t \
           CURL_MODE="${CURL_MODE:-ok}"
    unset H BUILD_SLOTS
    bash "$1/bin/free-slots.sh" "$2" 2>/dev/null )
}
first() { printf '%s' "${1%% *}"; }

echo "== D1: a wip-limit row reaches the slot count with no flags/ file =="
D1="$T/d1"; mkh "$D1"; row "$D1" wip-limit-p 1 '"5"'
OUT=$(fs "$D1" p)
[ "$(first "$OUT")" = 5 ] && ok || bad "D1: free-slots.sh p printed '$OUT', want first word 5"
grep -q '^GET .*/api/flags/wip-limit-p$' "$D1/req.log" 2>/dev/null && ok \
  || bad "D1: no GET /api/flags/wip-limit-p in the request log: $(cat "$D1/req.log" 2>/dev/null)"

echo "== D2: a 404 row and no file invent no cap =="
D2="$T/d2"; mkh "$D2"
OUT=$(fs "$D2" p)
[ "$(first "$OUT")" = unlimited ] && ok || bad "D2: free-slots.sh p printed '$OUT', want first word unlimited"

echo "== D3: API down answers the cached value, fail-closed =="
D3="$T/d3"; mkh "$D3"; mkdir -p "$D3/state/flags-cache"
printf '{"active":1,"value":"3","updated_at":"%s","fetched_at":"%s"}' "$T1" "$T1" > "$D3/state/flags-cache/wip-limit-p.json"
OUT=$(CURL_MODE=down fs "$D3" p)
[ "$(first "$OUT")" = 3 ] && ok || bad "D3: free-slots.sh p in an outage printed '$OUT', want first word 3"

echo "== M1: mutation guard — the old cat read misses the row =="
M1="$T/m1"; mkh "$M1"; row "$M1" wip-limit-p 1 '"5"'
SUM=$(sha1sum < "$M1/bin/free-slots.sh")
sed -i 's|flag_value wip-limit "\$P"|cat "$H/flags/wip-limit-$P"|' "$M1/bin/free-slots.sh"
[ "$(sha1sum < "$M1/bin/free-slots.sh")" = "$SUM" ] && bad "M1: the sed found no flag_value wip-limit call to revert" || ok
OUT=$(fs "$M1" p)
[ "$(first "$OUT")" = unlimited ] && ok || bad "M1: the mutant printed '$OUT' — D1 does not prove the row read"

echo "== D4: a half-synced client (no bin/lib/jobs/) does not end the caller =="
D4="$T/d4"; mkh "$D4"; scratch_rm "$D4/bin/lib/jobs" || exit 1; : > "$D4/flags/builder-fly-p"
OUT=$(fs "$D4" p)
case "$OUT" in "unlimited (fly-routed"*) ok ;; *) bad "D4: free-slots.sh p printed '$OUT', want the fly-routed answer from the file" ;; esac

echo "== M2: mutation guard — without the bin/lib/jobs/ check, D4 goes red =="
M2="$T/m2"; mkh "$M2"; scratch_rm "$M2/bin/lib/jobs" || exit 1; : > "$M2/flags/builder-fly-p"
SUM=$(sha1sum < "$M2/bin/lib/flag-on.sh")
sed -i '/\[ -d "\$root\/bin\/lib\/jobs" \] || return 1/d' "$M2/bin/lib/flag-on.sh"
[ "$(sha1sum < "$M2/bin/lib/flag-on.sh")" = "$SUM" ] && bad "M2: the sed found no bin/lib/jobs check to remove" || ok
OUT=$(fs "$M2" p)
case "$OUT" in "unlimited (fly-routed"*) bad "M2: the mutant still answered '$OUT' — D4 does not prove the guard" ;; *) ok ;; esac

echo
echo "flag-callsites-pool.bh-5635: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
