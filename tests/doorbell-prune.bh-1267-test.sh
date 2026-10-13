#!/bin/bash
# tests/doorbell-prune.bh-1267-test.sh — the wakes retention prune: the client
# verb, the knob, and the lane that calls it once a day (BH-1267 item 2).
#
# WHY THIS EXISTS. Nothing has ever deleted a `wakes` row. The table only grows,
# and GET /api/wakes/summary reads a time window over it every day for every
# fleet repo. BH-1267 adds an index and a BOUNDED prune, called from the daily
# doorbell lane that already walks that summary.
#
# THE PRUNE DELETES ROWS, so most of this file is about what must NOT happen:
#   * `wakes-prune abc`, `wakes-prune 0`, `wakes-prune` — rc 1 and NO REQUEST,
#     refused client-side before anything can be deleted (D11: absent ≠ zero);
#   * `WAKES_RETENTION_DAYS=0` is OFF, and a junk value prunes nothing and says
#     so — a knob nobody can read is not a reason to guess 30;
#   * a `--repo` run (bin/load-project.sh onboarding one project) never prunes;
#   * a prune that FAILS logs `failed`, never `deleted=0`, and cannot change the
#     doorbell verdicts, the summary line or the --strict exit code (D9/D13).
#
# Run from anywhere: tests/doorbell-prune.bh-1267-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rendered.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SUT="$DIR/bin/doorbell-coverage-check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$SUT" ] || { echo "FAIL: bin/doorbell-coverage-check.sh missing or not executable"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

RECEIVER="https://jobs.test/webhooks/github"
export JOBS_URL="https://jobs.test"
export HARNESS_SECRET=s
export JOBS_RETRIES=0
export HARNESS="$T/harness"
export HARNESS_ALERTS="$T/harness/logs/ALERTS.log"
mkdir -p "$HARNESS/logs" "$HARNESS/flags" "$HARNESS/env" "$T/calls"
: > "$HARNESS/env/global.env"
export CALLS="$T/calls" SUMMARY_JSON="$T/summary.json" SUMMARY_DOWN="$T/summary.down"
export PRUNE_JSON="$T/prune.json" PRUNE_DOWN="$T/prune.down"

export FLEET_CONF="$T/fleet.conf"
cat > "$FLEET_CONF" <<EOF
# <project> <repo> <prod> <board-prefix> <offset> <box> <ip>
armed-proj    Test/armed      -  -  1  box-test 100.0.0.1
nohook-proj   Test/nohook     -  -  2  box-test 100.0.0.1
EOF

export FIXTURES="$T/fixtures"; mkdir -p "$FIXTURES"
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'GH_EOF'
#!/bin/bash
echo "$*" >> "$CALLS/gh"
[ "${1:-}" = api ] || exit 1
shift
EP="${1:-}"; shift
JQ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq|-q) JQ="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$EP" in
  */hooks)
    SLUG="${EP#/}"; SLUG="${SLUG#repos/}"; SLUG="${SLUG%/hooks}"
    F="$FIXTURES/${SLUG//\//_}.json"
    [ -f "$F" ] || exit 1
    if [ -n "$JQ" ]; then jq -r "$JQ" < "$F"; else cat "$F"; fi
    ;;
  repos/*|/repos/*) echo 12345 ;;
  *) exit 1 ;;
esac
GH_EOF
chmod +x "$T/fakebin/gh"

# curl: the summary route and the prune route, each with its own outage switch.
# The prune arm records the BODY (what `days` actually reached the worker is the
# assertion that a junk knob sent nothing) — and records it only when one
# arrives, so "no request" is an empty file, never a blank line.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
case "$*" in
  *"/api/wakes/prune"*)
    PREV=""
    for a in "$@"; do
      [ "$PREV" = "--data-binary" ] && echo "$a" >> "$CALLS/prune"
      PREV="$a"
    done
    [ -f "$PRUNE_DOWN" ] && exit 7
    printf '%s\n200' "$(cat "$PRUNE_JSON" 2>/dev/null || echo '{"deleted":0}')"
    exit 0 ;;
  *"/api/wakes/summary"*)
    echo "${!#}" >> "$CALLS/curl"
    [ -f "$SUMMARY_DOWN" ] && exit 7
    printf '%s\n200' "$(cat "$SUMMARY_JSON" 2>/dev/null || echo '{"repos":[]}')"
    exit 0 ;;
esac
printf '{}\n200'
SH
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

hook() { printf '{"active":%s,"config":{"url":"%s"}}' "$1" "$2"; }
printf '[%s]\n' "$(hook true "$RECEIVER")" > "$FIXTURES/Test_armed.json"
printf '[]\n'                              > "$FIXTURES/Test_nohook.json"

BEFORE="2026-08-23T05:50:00Z"   # determinism: ok a literal echoed back by the stub; nothing here reads a clock
LAST="2026-09-19T21:00:00Z"     # determinism: ok same — the stub's fixture value, not a clock read
printf '{"deleted":12,"before":"%s","days":30,"limit":5000,"capped":false}' "$BEFORE" > "$PRUNE_JSON"

summary() { printf '{"repos":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/summary.json"; }
R() { printf '{"repo":"%s","n":%s,"last_at":"%s","kinds":"%s"}' "$1" "$2" "$3" "$4"; }
run() { OUT=$("$SUT" "$@" 2>&1); RC=$?; }
reset() {
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  : > "$HARNESS_ALERTS"; rm -f "$HARNESS"/flags/alerted-doorbell-* "$HARNESS"/flags/alerted-jobs-client-*
  rm -f "$T/summary.json" "$T/summary.down" "$PRUNE_DOWN" "$HARNESS/logs/doorbell-coverage-check.log"
  rm -f "$HARNESS/logs/jobs-client.log"
  unset WAKES_RETENTION_DAYS
}
prunes() { [ -f "$T/calls/prune" ] && wc -l < "$T/calls/prune" | tr -d ' ' || echo 0; }
lanelog() { cat "$HARNESS/logs/doorbell-coverage-check.log" 2>/dev/null; }

# ───────────────────────────────────────────────────────────────────────────
# 1. the CLI verb: one POST, the TSV the lane reads
# ───────────────────────────────────────────────────────────────────────────
reset
OUT=$("$DIR/bin/jobs-client.sh" wakes-prune 30 2>/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "wakes-prune 30 rc=$RC, expected 0"
EXPECT=$(printf '12\t%s\tfalse' "$BEFORE")
[ "$OUT" = "$EXPECT" ] && ok || bad "wakes-prune TSV wrong: $(printf '%q' "$OUT")"
[ "$(prunes)" = 1 ] && ok || bad "expected exactly 1 prune request, got $(prunes)"
[ "$(cat "$T/calls/prune" 2>/dev/null)" = '{"days":30}' ] && ok \
  || bad "the prune body is not the days the caller asked for: $(cat "$T/calls/prune" 2>/dev/null)"

# ───────────────────────────────────────────────────────────────────────────
# 2. an outage is rc 1 and EMPTY stdout, and never an ALERTS line
# ───────────────────────────────────────────────────────────────────────────
# JOBS_ALERT=0 like wakes_summary: the doorbell log's contract is one line per
# repo per day, and a worker that is down is already alerted by the lanes that
# depend on it every minute.
reset; : > "$PRUNE_DOWN"
OUT=$("$DIR/bin/jobs-client.sh" wakes-prune 30 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "wakes-prune on an outage: rc=$RC, expected 1"
[ -z "$OUT" ] && ok || bad "wakes-prune printed on an outage: $OUT"
grep -q 'api/wakes/prune' "$HARNESS/logs/jobs-client.log" 2>/dev/null && ok \
  || bad "the failed prune left no trace in logs/jobs-client.log"
grep -q '\[jobs-client\]' "$HARNESS_ALERTS" 2>/dev/null \
  && bad "the prune burned the box's daily ALERT: $(cat "$HARNESS_ALERTS")" || ok

# ───────────────────────────────────────────────────────────────────────────
# 3. a junk, zero or missing `days` costs NO REQUEST
# ───────────────────────────────────────────────────────────────────────────
# The client refuses before the worker can be asked to delete anything.
for ARG in abc 0 -1 1.5 ""; do
  reset
  if [ -z "$ARG" ]; then
    OUT=$("$DIR/bin/jobs-client.sh" wakes-prune 2>/dev/null); RC=$?
  else
    OUT=$("$DIR/bin/jobs-client.sh" wakes-prune "$ARG" 2>/dev/null); RC=$?
  fi
  [ "$RC" = 1 ] && ok || bad "wakes-prune '$ARG' rc=$RC, expected 1"
  [ "$(prunes)" = 0 ] && ok || bad "wakes-prune '$ARG' sent a request: $(cat "$T/calls/prune")"
  [ -z "$OUT" ] && ok || bad "wakes-prune '$ARG' printed: $OUT"
done

# ───────────────────────────────────────────────────────────────────────────
# 4. the lane prunes ONCE per run, with the default 30 days
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R Test/armed 3 "$LAST" pr)"
run
[ "$RC" = 0 ] && ok || bad "registry walk rc=$RC, expected 0"
[ "$(prunes)" = 1 ] && ok || bad "expected exactly 1 prune for the whole walk, got $(prunes)"
[ "$(cat "$T/calls/prune" 2>/dev/null)" = '{"days":30}' ] && ok \
  || bad "the lane's default retention is not 30 days: $(cat "$T/calls/prune" 2>/dev/null)"
lanelog | grep -qE 'prune days=30 deleted=12 before=.* capped=0' && ok \
  || bad "the prune log line is missing or wrong: $(lanelog)"
case "$OUT" in *"checked=2 missing=1 unreadable=0 ringing=1"*) ok ;; *) bad "the prune changed the summary line — $OUT" ;; esac

# ───────────────────────────────────────────────────────────────────────────
# 5. WAKES_RETENTION_DAYS=0 is OFF — zero_means off, never "delete everything"
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R Test/armed 3 "$LAST" pr)"
OUT=$(WAKES_RETENTION_DAYS=0 "$SUT" 2>&1); RC=$?
[ "$(prunes)" = 0 ] && ok || bad "retention 0 still pruned: $(cat "$T/calls/prune")"
lanelog | grep -q 'retention off' && ok || bad "retention 0 left no log line: $(lanelog)"
[ "$RC" = 0 ] && ok || bad "retention 0 changed the exit code: rc=$RC"

# ───────────────────────────────────────────────────────────────────────────
# 6. a knob nobody can parse prunes NOTHING and says so
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R Test/armed 3 "$LAST" pr)"
OUT=$(WAKES_RETENTION_DAYS=abc "$SUT" 2>&1); RC=$?
[ "$(prunes)" = 0 ] && ok || bad "a junk retention value still pruned: $(cat "$T/calls/prune")"
lanelog | grep -q 'retention ignored' && ok || bad "a junk retention value was silent: $(lanelog)"
[ "$RC" = 0 ] && ok || bad "a junk retention value changed the exit code: rc=$RC"

# ───────────────────────────────────────────────────────────────────────────
# 7. a single-repo run (bin/load-project.sh onboarding) never prunes
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R Test/armed 3 "$LAST" pr)"
run --repo Test/armed
[ "$(prunes)" = 0 ] && ok || bad "a --repo run pruned the whole table: $(cat "$T/calls/prune")"
[ "$RC" = 0 ] && ok || bad "--repo run rc=$RC, expected 0"

# ───────────────────────────────────────────────────────────────────────────
# 8. a FAILED prune says failed — and changes nothing else about the run
# ───────────────────────────────────────────────────────────────────────────
reset; summary "$(R Test/armed 3 "$LAST" pr)"; : > "$PRUNE_DOWN"
run
lanelog | grep -q 'prune days=30 failed' && ok || bad "a failed prune did not say so: $(lanelog)"
grep -q 'deleted=' <<<"$(lanelog)" && bad "a failed prune reported a deleted count: $(lanelog)" || ok
case "$OUT" in *"checked=2 missing=1 unreadable=0 ringing=1"*) ok ;; *) bad "a failed prune moved the verdicts — $OUT" ;; esac
[ "$RC" = 0 ] && ok || bad "a failed prune failed the run: rc=$RC"
# …and --strict still answers for the DOORBELL, not for the prune.
reset; summary "$(R Test/armed 3 "$LAST" pr)"; : > "$PRUNE_DOWN"
run --strict
[ "$RC" = 1 ] && ok || bad "--strict with one missing repo must still be rc 1, got $RC"
reset; summary "$(R Test/armed 3 "$LAST" pr)"
run --repo Test/armed --strict
[ "$RC" = 0 ] && ok || bad "--strict over an armed repo must be rc 0, got $RC"

# ───────────────────────────────────────────────────────────────────────────
# 9. the knob is in the registry, so a settings row can move it
# ───────────────────────────────────────────────────────────────────────────
# Without this row the ${WAKES_RETENTION_DAYS:-30} read is reachable only by
# editing env/global.env on the hub, which is not what "a lane knob" means.
REG=$(rendered_registry)
K=$(jq -r '.lanes[]|select(.id=="doorbell-coverage-check")|.knobs[]?
  |select(.env=="WAKES_RETENTION_DAYS")
  |"\(.type) \(.default) \(.zero_means) \(.settable)"' "$REG")
[ "$K" = "int 30 off true" ] && ok \
  || bad "the retention knob is missing or wrong in the registry: '$K'"

echo "doorbell-prune-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
