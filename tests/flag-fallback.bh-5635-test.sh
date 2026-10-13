#!/bin/bash
# tests/flag-fallback.bh-5635-test.sh — BH-5635.0: bin/lib/flag-on.sh answers
# FAIL-CLOSED when the harness-jobs flag read fails. The pause, automerge and
# WIP gates must never read "not paused" while the last known answer was paused.
#
# Driven, not grepped: every case sources the real bin/lib/flag-on.sh, which
# sources the real bin/jobs-client.sh, against a curl stub. Asserts rc, file
# bytes, cache bytes, the outage marker and ALERTS.log line counts.
#
#   F1 observable outcome: a good read caches; API down + file removed -> ON, 1 ALERTS line
#   F2 500 {} with the cache ON -> ON, cache bytes unchanged
#   F3 200 with active:null -> outage, not OFF; cache unchanged
#   F4 one ALERTS line per outage episode; recovery clears the marker, logs once
#   F5 wip-limit outage: cached value first, else the file; automerge-disabled fleet name
#   F6 a garbage cache is absent: the file decides
#   F7 mutation guard (D1): flag-on.sh without the cache term fails F1
#   F8 a readable row with flags/ unwritable: the row decides, ON iff active 1 or the file
#   F9 a ported name (paused-*) goes through flag_active: no flags/ file, fail-closed
#
#
# TEST-CHANGE (BH-5639 merge with BH-4153, the operator 2026-10-09): paused-* and
# automerge-disabled* are harness_flags rows, read by flag_active with its own
# fail-closed cache (bin/lib/jobs/flags.sh). F1-F4 and F6-F8 now drive
# wip-limit-p, the pause_flags family this reader still owns; every assertion
# is unchanged. F9 pins the ported route.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/flag-fallback.bh-5635-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/flag-on.sh" ] || { echo "FAIL: $DIR/bin/lib/flag-on.sh is missing"; exit 1; }

T1=2026-09-19T01:00:00Z

# The stub answers GET /api/flags/<name> from $ROWS/<name>.json (404 when there
# is no such file) and records every request. CURL_MODE=down|500|empty are the
# outage arms.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)  exit 7 ;;
  500)   printf '{}\n500\n'; exit 0 ;;
  empty) printf '\n200\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "GET "*/api/flags/*)
    n="${URL##*/}"; n="${n%%\?*}"   # flag_fetch (BH-4153) adds ?scope=
    if [ -s "${ROWS:-/nonexistent}/$n.json" ]; then cat "$ROWS/$n.json"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# mkh <root> — a scratch harness: the client, the reader, the alert helper.
mkh() {
  mkdir -p "$1/flags" "$1/state" "$1/logs" "$1/env" "$1/rows"
  scratch_install_closure bin/jobs-client.sh "$1" >/dev/null || exit 1
  scratch_install_closure bin/lib/flag-on.sh "$1" >/dev/null || exit 1
  scratch_install_closure bin/alert-line.sh "$1" >/dev/null || exit 1
  cp "$DIR/bin/alert_family.py" "$1/bin/" || exit 1
  echo "HARNESS_SECRET=test-secret-fixture" > "$1/env/global.env"
}
row() { # row <root> <name> <active-json> [value-json]
  printf '{"flag":{"name":"%s","active":%s,"updated_at":"%s","value":%s}}' "$2" "$3" "$T1" "${4:-null}" > "$1/rows/$2.json"
}
# fo <root> <fn> [args...] — source the real lib in <root> and call <fn>.
fo() {
  local HR="$1"; shift
  ( export PATH="$T/fakebin:$PATH" HARNESS="$HR" HARNESS_SECRET=test-secret-fixture JOBS_RETRIES=0 \
           JOBS_URL=https://jobs.invalid ROWS="$HR/rows" REQ_SINK="$HR/req.log" JOBS_BOX=box-t \
           CURL_MODE="${CURL_MODE:-ok}"
    unset H
    . "$HR/bin/lib/flag-on.sh" || exit 3
    "$@" 2>/dev/null )
}
alerts() { grep -c '\[flags\]' "$1/logs/ALERTS.log" 2>/dev/null || echo 0; }
CACHE=state/flags-cache

echo "== F1: a good read caches; API down and the file removed still answers ON =="
F1="$T/f1"; mkh "$F1"; row "$F1" wip-limit-p 1
fo "$F1" flag_on wip-limit p; RC=$?
[ "$RC" = 0 ] && ok || bad "F1: rc $RC for an active row"
[ -s "$F1/$CACHE/wip-limit-p.json" ] && ok || bad "F1: no cache after a good read"
[ "$(jq -r .active "$F1/$CACHE/wip-limit-p.json" 2>/dev/null)" = 1 ] && ok || bad "F1: cache does not say active 1"
rm -f "$F1/flags/wip-limit-p"
CURL_MODE=down fo "$F1" flag_on wip-limit p; RC=$?
[ "$RC" = 0 ] && ok || bad "F1: API down + file removed answered rc $RC — the box would build while paused"
[ "$(alerts "$F1")" = 1 ] && ok || bad "F1: $(alerts "$F1") [flags] ALERTS lines, want 1"
[ -e "$F1/$CACHE/.outage" ] && ok || bad "F1: no outage marker"

echo "== F2: a 500 {} with the cache ON answers ON and leaves the cache bytes alone =="
cp "$F1/$CACHE/wip-limit-p.json" "$T/f2-before"
CURL_MODE=500 fo "$F1" flag_on wip-limit p; RC=$?
[ "$RC" = 0 ] && ok || bad "F2: rc $RC on a 500 with the cache ON"
cmp -s "$T/f2-before" "$F1/$CACHE/wip-limit-p.json" && ok || bad "F2: the cache changed on a 500"
[ "$(alerts "$F1")" = 1 ] && ok || bad "F2: a repeat failure in the same episode wrote an ALERTS line"

echo "== F3: active:null is an outage, never OFF =="
F3="$T/f3"; mkh "$F3"; row "$F3" wip-limit-p 1
fo "$F3" flag_on wip-limit p >/dev/null; rm -f "$F3/flags/wip-limit-p"
cp "$F3/$CACHE/wip-limit-p.json" "$T/f3-before"
row "$F3" wip-limit-p null
fo "$F3" flag_on wip-limit p; RC=$?
[ "$RC" = 0 ] && ok || bad "F3: active:null answered rc $RC"
[ -e "$F3/$CACHE/.outage" ] && ok || bad "F3: active:null did not open an outage"
cmp -s "$T/f3-before" "$F3/$CACHE/wip-limit-p.json" && ok || bad "F3: active:null rewrote the cache"
[ ! -e "$F3/flags/wip-limit-p" ] && ok || bad "F3: an unreadable row touched flags/"
row "$F3" wip-limit-p 0 '"5; rm"'
fo "$F3" flag_on wip-limit p; RC=$?
[ "$RC" = 0 ] && ok || bad "F3: a row with a refused value answered rc $RC, not the cached ON"

echo "== F4: one ALERTS line per episode; recovery clears the marker =="
F4="$T/f4"; mkh "$F4"; row "$F4" wip-limit-p 0
for _ in 1 2 3; do CURL_MODE=down fo "$F4" flag_on wip-limit p; done
[ "$(alerts "$F4")" = 1 ] && ok || bad "F4: three failed reads wrote $(alerts "$F4") ALERTS lines, want 1"
grep -q 'harness-jobs flag read failed for wip-limit-p on box-t' "$F4/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "F4: the ALERTS line does not name the flag and box: $(cat "$F4/logs/ALERTS.log" 2>/dev/null)"
fo "$F4" flag_on wip-limit p; RC=$?
[ "$RC" = 1 ] && ok || bad "F4: a good inactive read answered rc $RC"
[ ! -e "$F4/$CACHE/.outage" ] && ok || bad "F4: a good read left the outage marker"
[ "$(grep -c 'outage ended (wip-limit-p read ok)' "$F4/logs/flags.log" 2>/dev/null)" = 1 ] && ok || bad "F4: no single 'outage ended' line in logs/flags.log"
fo "$F4" flag_on wip-limit p
[ "$(grep -c 'outage ended' "$F4/logs/flags.log" 2>/dev/null)" = 1 ] && ok || bad "F4: a second good read logged recovery again"
CURL_MODE=down fo "$F4" flag_on wip-limit p
[ "$(alerts "$F4")" = 2 ] && ok || bad "F4: a new episode wrote $(alerts "$F4") ALERTS lines in total, want 2"

echo "== F5: wip-limit outage: cached value first, else the file =="
F5="$T/f5"; mkh "$F5"; row "$F5" wip-limit-p 1 '"5"'
OUT=$(fo "$F5" flag_value wip-limit p); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = 5 ]; } && ok || bad "F5: good read gave rc $RC value '$OUT', want 0 / 5"
printf '3\n' > "$F5/flags/wip-limit-p"
OUT=$(CURL_MODE=down fo "$F5" flag_value wip-limit p); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = 5 ]; } && ok || bad "F5: outage gave rc $RC value '$OUT', want the cached 5"
rm -f "$F5/$CACHE/wip-limit-p.json"
OUT=$(CURL_MODE=down fo "$F5" flag_value wip-limit p); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = 3 ]; } && ok || bad "F5: outage with no cache gave rc $RC value '$OUT', want the file's 3"
row "$F5" automerge-disabled 1
fo "$F5" flag_on automerge-disabled; rm -f "$F5/flags/automerge-disabled"
CURL_MODE=down fo "$F5" flag_on automerge-disabled; RC=$?
[ "$RC" = 0 ] && ok || bad "F5: automerge-disabled outage with the cache ON answered rc $RC"

echo "== F6: a garbage cache is absent; the file decides =="
F6="$T/f6"; mkh "$F6"; mkdir -p "$F6/$CACHE"; echo garbage > "$F6/$CACHE/wip-limit-p.json"
CURL_MODE=down fo "$F6" flag_on wip-limit p; RC=$?
[ "$RC" = 1 ] && ok || bad "F6: garbage cache + no file answered rc $RC, want 1"
printf '{"active":7}' > "$F6/$CACHE/wip-limit-p.json"
CURL_MODE=down fo "$F6" flag_on wip-limit p; RC=$?
[ "$RC" = 1 ] && ok || bad "F6: active:7 in the cache answered rc $RC, want 1"
touch "$F6/flags/wip-limit-p"
CURL_MODE=down fo "$F6" flag_on wip-limit p; RC=$?
[ "$RC" = 0 ] && ok || bad "F6: the file present answered rc $RC, want 0"

echo "== F7: mutation guard — without the cache term, F1 goes red =="
F7="$T/f7"; mkh "$F7"; row "$F7" wip-limit-p 1
SUM=$(sha1sum < "$F7/bin/lib/flag-on.sh")
sed -i 's/\[ "\$c_active" = 1 \] || //' "$F7/bin/lib/flag-on.sh"
[ "$(sha1sum < "$F7/bin/lib/flag-on.sh")" = "$SUM" ] && bad "F7: the sed found no cache term to remove" || ok
fo "$F7" flag_on wip-limit p >/dev/null; rm -f "$F7/flags/wip-limit-p"
CURL_MODE=down fo "$F7" flag_on wip-limit p; RC=$?
[ "$RC" = 1 ] && ok || bad "F7: the mutant still answered rc $RC — F1 does not prove the cache path"

echo "== F8: a readable row with flags/ unwritable answers from the row, fail-closed =="
F8="$T/f8"; mkh "$F8"; scratch_rm "$F8/flags"; : > "$F8/flags"   # a plain file: mkdir, touch and mv fail
row "$F8" wip-limit-p 1
fo "$F8" flag_on wip-limit p; RC=$?
[ "$RC" = 0 ] && ok || bad "F8: row active 1 with flags/ unwritable answered rc $RC — the box would build while paused"
[ "$(jq -r .active "$F8/$CACHE/wip-limit-p.json" 2>/dev/null)" = 1 ] && ok || bad "F8: the cache does not record the row"
row "$F8" wip-limit-p 1 '"5"'
OUT=$(fo "$F8" flag_value wip-limit p); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = 5 ]; } && ok || bad "F8: wip-limit with flags/ unwritable gave rc $RC value '$OUT', want 0 / 5"
row "$F8" wip-limit-p 0
fo "$F8" flag_on wip-limit p; RC=$?
[ "$RC" = 1 ] && ok || bad "F8: row active 0 and no file answered rc $RC, want 1"
# A stale file the reconcile cannot remove still answers ON (fail-closed).
F8b="$T/f8b"; mkh "$F8b"; touch "$F8b/flags/wip-limit-p"; chmod 555 "$F8b/flags"
row "$F8b" wip-limit-p 0
fo "$F8b" flag_on wip-limit p; RC=$?
if [ -w "$F8b/flags" ]; then ok; else  # root ignores mode bits; the case only runs when they bite
  [ "$RC" = 0 ] && ok || bad "F8: a file the reconcile could not remove answered rc $RC, want 0"
fi
chmod 755 "$F8b/flags"

echo "== F9: a ported name (BH-4153) is read by flag_active: DB-first, no flags/ file, fail-closed =="
F9="$T/f9"; mkh "$F9"; row "$F9" paused-p 1
fo "$F9" flag_on paused p; RC=$?
[ "$RC" = 0 ] && ok || bad "F9: paused-p row active 1 answered rc $RC, want 0"
[ ! -e "$F9/flags/paused-p" ] && ok || bad "F9: flag_on wrote flags/paused-p for a ported name"
grep -q '/api/flags/paused-p' "$F9/req.log" 2>/dev/null && ok || bad "F9: the ported read did not ask the row: $(cat "$F9/req.log" 2>/dev/null)"
[ -s "$F9/state/flags-cache/fleet/paused-p" ] && ok || bad "F9: the BH-4153 last-good cache (state/flags-cache/fleet/paused-p) was not written"
[ ! -e "$F9/state/flags-cache/paused-p.json" ] && ok || bad "F9: the pause_flags reader's cache was written for a ported name"
row "$F9" paused-p 0
fo "$F9" flag_on paused p; RC=$?
[ "$RC" = 1 ] && ok || bad "F9: paused-p row active 0 answered rc $RC, want 1"
F9b="$T/f9b"; mkh "$F9b"
CURL_MODE=down fo "$F9b" flag_on paused p; RC=$?
[ "$RC" = 0 ] && ok || bad "F9: worker down, no cache: a stop switch must read ON (fail-closed), got rc $RC"

echo
echo "flag-fallback.bh-5635: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
