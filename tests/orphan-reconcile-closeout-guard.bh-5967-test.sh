#!/bin/bash
# tests/orphan-reconcile-closeout-guard.bh-5967-test.sh — BH-5967 (the guard
# fix, split out as a hotfix): the triage-tick reconcile does not hold an
# ownerless ticket back as awaiting-closeout because of a build dir that owes
# no close-out.
#
# THE CENSUS (box-small, logs/cromford.log, 2026-10-10 21:02Z ..
# 21:37Z). Every reconcile tick logged `reconcile: open=95 owned=60 orphans=34
# enqueued=- skipped=BH-3921:awaiting-closeout,BH-4587:awaiting-closeout,...`.
# The dirs were run-build's `QUEUED_FLY <KEY>` routing stubs (for example
# builds/cromford-BH-5521-202610100803). A stub is closed only when a newer
# pool result is RELAYED, so a pool build that stood down, or a row that went
# FAILED, left it open for ever, and 34 tickets were never relaunched.
#
#   G1  an orphan whose only open dir is a QUEUED_FLY stub is relaunched
#   G2  an orphan whose only open dir is a stand-down (the DEFERRED sentinel,
#       or a BUILD_DEFERRED head) is relaunched
#   G3  an orphan with a real RESULT and no COMMENTED is still skipped as
#       awaiting-closeout
#
# The rig is tests/orphan-reconcile-test.sh's: the real script against a
# scratch HARNESS, fake gh and curl. Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
for L in bin/orphan-reconcile.sh bin/jobs-client.sh bin/lib/preplan-lib.sh bin/lib/gh-budget.sh bin/lib/hold.sh \
         bin/lib/closeout-overdue.sh bin/lib/gh-rest.sh bin/lib/gh-rest-var.sh bin/lib/gh-rest-list.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/launches.log"' > "$H/bin/run-build.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/alerts-called.log"' > "$H/bin/lane-alert.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/needs-human.log"' 'exit 0' > "$H/bin/needs-human-hold.sh"
chmod +x "$H/bin/"*.sh

# gh: the open board, the all-states list, the PR list and one HOLD thread.
cat > "$T/fakebin/gh" <<'SH'
ARGS="$*"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
[ "$PAGE" = 1 ] || SEND 200 '[]'
case "$ARGS" in
  "api repos/example-org/project-5 -q .id") echo 1; exit 0 ;;
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    SEND 200 "$(jq -c --argjson n "$n" '[ .[] | select(.number==$n) | (.comments // [])[] ]' "$HARNESS/fixture/open.json")" ;;
  *"/pulls"*)
    SEND 200 "$(jq -c '[ .[] | {number, title, body, head:{ref:.headRefName}} ]' "$HARNESS/fixture/prs.json")" ;;
  *"/issues"*"state=all"*)
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*)
    SEND 200 "$(jq -c '[ .[] | {number, title, body, comments:((.comments // [])|length), updated_at:.updatedAt} ]' "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
# curl: the jobs ledger, the queue (a FAILED row per key, with its reason), and
# every POST to /api/queue recorded with its body.
cat > "$T/fakebin/curl" <<'SH'
URL="${!#}"; METHOD=GET; BODY=""
prev=""
for a in "$@"; do
  [ "$prev" = -X ] && METHOD="$a"
  [ "$prev" = --data-binary ] && BODY="$a"
  prev="$a"
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
case "$METHOD $URL" in
  "POST "*/api/queue*) printf '%s\n' "$BODY" >> "$HARNESS/queue-posts.log"; printf '{"ok":true}\n200\n' ;;
  "GET "*/api/queue*"key="*)
    k=$(printf '%s' "$URL" | sed -nE 's/.*key=([^&]+).*/\1/p')
    printf '{"queue":[{"project":"project-5","ticket_key":"%s","status":"failed","reason":"deferred 12 times (BUILD_DEFERRED After: TK-5 in flight) — parked for the blocked-resolver"}]}\n200\n' "$k" ;;
  "GET "*/api/queue*) printf '{"queue":[]}\n200\n' ;;
  "GET "*/api/jobs*) printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

ISO() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
board() {
  cat > "$H/fixture/open.json" <<JSON
[
 {"number":989,"title":"TK-989 stranded","body":"## Scope","comments":[],"updatedAt":"$(ISO 86400)"},
 {"number":902,"title":"TK-902 has an open PR","body":"## Scope","comments":[],"updatedAt":"$(ISO 86400)"},
 {"number":887,"title":"TK-887 held","body":"## Scope","comments":[{"body":"HOLD — do not build this yet.","user":{"type":"User"},"created_at":"$(ISO 86000)"}],"updatedAt":"$(ISO 86000)"},
 {"number":910,"title":"TK-910 tried half an hour ago","body":"## Scope","comments":[],"updatedAt":"$(ISO 86400)"}
]
JSON
  echo '[{"number":1044,"title":"TK-902: the PR that owns it","headRefName":"ticket/TK-902","body":""}]' > "$H/fixture/prs.json"
  cat > "$H/fixture/jobs.json" <<JSON
{"jobs":[
 {"id":"build-project-5-TK-989-0","ticket_id":"TK-989","kind":"build","status":"failed","updated_at":"$(ISO 9000)","meta":"{\"ticket_id\":\"989\"}"},
 {"id":"build-project-5-TK-910-0","ticket_id":"TK-910","kind":"build","status":"failed","updated_at":"$(ISO 1800)","meta":"{\"ticket_id\":\"910\"}"}
]}
JSON
}
reset() {
  scratch_rm "$H/state"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  mkdir -p "$H/state" "$H/logs" "$H/builds"
  rm -f "$H/launches.log" "$H/queue-posts.log" "$H/needs-human.log" "$H/alerts-called.log"
  board
}
run() { "$H/bin/orphan-reconcile.sh" "$P" 2>/dev/null; }
summary() { grep -o 'reconcile: open=.*' "$H/logs/$P.log" | tail -1; }

reset
mkdir -p "$H/builds/$P-TK-989-202610100803" "$H/builds/pool-$P-TK-910-202610100900" "$H/builds/pool-$P-TK-902-202610100901"
echo 'QUEUED_FLY TK-989' > "$H/builds/$P-TK-989-202610100803/RESULT"
echo 'BUILD_DEFERRED plan overlap not-before 21:40:00Z — re-checked each tick' > "$H/builds/pool-$P-TK-910-202610100900/RESULT"
: > "$H/builds/pool-$P-TK-910-202610100900/DEFERRED"
run
grep -q 'project-5 989 TK-989' "$H/launches.log" 2>/dev/null && ok \
  || bad "G1: THE BUG: a QUEUED_FLY stub held TK-989 back ($(summary))"
grep -q 'project-5 910 TK-910' "$H/launches.log" 2>/dev/null && ok \
  || bad "G2: a DEFERRED stand-down held TK-910 back ($(summary))"

# G2b: a BUILD_DEFERRED head with no sentinel (a dir written before it existed).
reset
mkdir -p "$H/builds/pool-$P-TK-910-202610100900"
echo 'BUILD_DEFERRED After: TK-5 in flight — re-checked each tick' > "$H/builds/pool-$P-TK-910-202610100900/RESULT"
run
grep -q 'project-5 910 TK-910' "$H/launches.log" 2>/dev/null && ok \
  || bad "G2: a BUILD_DEFERRED head held TK-910 back ($(summary))"

# G3: a real result still owes its close-out.
reset
mkdir -p "$H/builds/pool-$P-TK-989-202610100903"
echo 'PLAN_BLOCKED /root/harness/builds/pool-project-5-TK-989-202610100903/plan.md' > "$H/builds/pool-$P-TK-989-202610100903/RESULT"
run
grep -q 'TK-989' "$H/launches.log" 2>/dev/null && bad "G3: a real RESULT with no COMMENTED must still hold the relaunch: $(cat "$H/launches.log")" || ok
summary | grep -q 'TK-989:awaiting-closeout' && ok || bad "G3: the summary names it awaiting-closeout ($(summary))"

echo "orphan-reconcile-closeout-guard.bh-5967: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
