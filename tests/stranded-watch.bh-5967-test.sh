#!/bin/bash
# tests/stranded-watch.bh-5967-test.sh — BH-5967 part 3: the stranded-ticket
# watch (`orphan-reconcile.sh --stranded <project>`, one run per project on the
# BH-5913 runner) re-offers a ticket nothing is working, counts the re-offers,
# and writes NEEDS_HUMAN on the fourth in 24 h. The triage-tick reconcile no
# longer treats a QUEUED_FLY routing stub as a close-out it must wait for.
#
# THE CENSUS (2026-10-10, box-small logs/cromford.log). Every
# reconcile tick from 21:02Z on logged `orphans=34 enqueued=- skipped=BH-3921:
# awaiting-closeout,BH-4587:awaiting-closeout,...`: run-build's `QUEUED_FLY
# <KEY>` dirs are closed only when a pool result is RELAYED, so a pool build
# that stood down or a row that went FAILED left them open for ever.
#
#   W1  the watch fixture: TK-989 is stranded (its build row FAILED 150 min ago,
#       no PR, no blocker), TK-902 has an open PR, TK-887 has a HOLD. Only
#       TK-989 gets a fresh queue row, with a line naming it and why, and no
#       build is started on the hub
#   W2  the idle window: TK-910's row ended 30 minutes ago, inside the default
#       60: not re-offered by the watch
#   W3  three re-offers in 24 h, then the fourth writes NEEDS_HUMAN with the
#       last result instead of a row; the run after that says nothing new
#   W4  a ticket that got its PR loses its re-offer count
#   W5  the triage-tick reconcile launches an orphan whose only open build dir
#       is a QUEUED_FLY stub, and one whose dir is a stand-down
#   W6  bin/stranded-watch.sh (the cron entry) starts the watch for the project
#       through the per-project runner and returns; the run re-offers TK-989
#   W7  on a pool-routed project the re-offered row's target is `fly`, the one
#       the pool claims
#   W8  a `duplicate` answer (a row already queued or claimed) is not counted
#       as a re-offer
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
         bin/lib/closeout-overdue.sh bin/lib/gh-rest.sh bin/lib/gh-rest-var.sh bin/lib/gh-rest-list.sh bin/fleet-conf.sh \
         bin/stranded-watch.sh bin/project-lane-run.sh; do
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
  "POST "*/api/queue*) printf '%s\n' "$BODY" >> "$HARNESS/queue-posts.log"
    if [ -e "$HARNESS/dup" ]; then printf '{"ok":true,"duplicate":true}\n200\n'; else printf '{"ok":true}\n200\n'; fi ;;
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
watch() { "$H/bin/orphan-reconcile.sh" --stranded "$P" 2>/dev/null; }
posts() { grep -o '"key":"[^"]*"' "$H/queue-posts.log" 2>/dev/null | sort | tr '\n' ' '; }
nposts() { grep -c . "$H/queue-posts.log" 2>/dev/null; }
# forget <KEY> — this watch's own grace marker for KEY, as if the idle window passed.
forget() { rm -f "$H/state/orphan-reconcile/$P/$1.enqueued"; }

# ── W1 + W2: only the stranded ticket is re-offered, and the hub builds nothing ──
reset
watch
[ "$(posts)" = '"key":"TK-989" ' ] && ok || bad "W1: THE POINT: only TK-989 gets a fresh queue row (posts: $(posts); log: $(tail -3 "$H/logs/$P.log"))"
grep -q 'stranded_reoffer[\\"]*:1' "$H/queue-posts.log" && ok || bad "W1: the row says it is a stranded re-offer: $(cat "$H/queue-posts.log" 2>/dev/null)"
grep -q 'stranded: TK-989 (issue #989) re-offered with a fresh queue row (1 of 3 in 24h) — stranded because: .*; last row: failed: deferred 12 times' "$H/logs/$P.log" && ok \
  || bad "W1: one line names the ticket, why and its last row: $(grep 'stranded:' "$H/logs/$P.log")"
[ ! -s "$H/launches.log" ] && ok || bad "W1: the watch starts no build on the hub: $(cat "$H/launches.log")"
grep -q 'TK-910' "$H/queue-posts.log" 2>/dev/null && bad "W2: TK-910 ended 30 min ago, inside the 60-min idle window: $(cat "$H/queue-posts.log")" || ok
grep -q 'stranded-watch: open=4 ' "$H/logs/$P.log" && ok || bad "W1: one summary line: $(grep stranded-watch: "$H/logs/$P.log")"

# ── W1b: no cap by default (the operator, unlimited concurrency, 2026-10-11) ──────
# STRANDED_MAX_PER_RUN's default is 0, no cap: twelve stranded tickets are
# all re-offered in one run (the old default 10 left two for the next hour).
reset
python3 - "$H/fixture/open.json" "$H/fixture/jobs.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1])); j = json.load(open(sys.argv[2]))
for n in range(960, 971):
    o.append({"number": n, "title": "TK-%d stranded too" % n, "body": "## Scope", "comments": [], "updatedAt": o[0]["updatedAt"]})
    j["jobs"].append({"id": "build-project-5-TK-%d-0" % n, "ticket_id": "TK-%d" % n, "kind": "build", "status": "failed",
                      "updated_at": j["jobs"][0]["updated_at"], "meta": json.dumps({"ticket_id": str(n)})})
json.dump(o, open(sys.argv[1], "w")); json.dump(j, open(sys.argv[2], "w"))
PY
( unset STRANDED_MAX_PER_RUN; watch )
[ "$(nposts)" = 12 ] && ok || bad "W1b: with the default, all 12 stranded tickets get a row in one run (posts: $(nposts))"
grep -q ':cap' <<<"$(grep 'stranded-watch:' "$H/logs/$P.log" | tail -1)" && bad "W1b: a key was skipped :cap: $(grep 'stranded-watch:' "$H/logs/$P.log" | tail -1)" || ok
# The knob still works as a brake when a row sets it.
reset
python3 - "$H/fixture/open.json" "$H/fixture/jobs.json" <<'PY'
import json, sys
o = json.load(open(sys.argv[1])); j = json.load(open(sys.argv[2]))
for n in (960, 961):
    o.append({"number": n, "title": "TK-%d stranded too" % n, "body": "## Scope", "comments": [], "updatedAt": o[0]["updatedAt"]})
    j["jobs"].append({"id": "build-project-5-TK-%d-0" % n, "ticket_id": "TK-%d" % n, "kind": "build", "status": "failed",
                      "updated_at": j["jobs"][0]["updated_at"], "meta": json.dumps({"ticket_id": str(n)})})
json.dump(o, open(sys.argv[1], "w")); json.dump(j, open(sys.argv[2], "w"))
PY
STRANDED_MAX_PER_RUN=1 watch
[ "$(nposts)" = 1 ] && ok || bad "W1b: STRANDED_MAX_PER_RUN=1 re-offers one (posts: $(nposts))"
# A value that is not a whole number is no cap, said once in the log.
reset
STRANDED_MAX_PER_RUN=lots watch
grep -q "STRANDED_MAX_PER_RUN='lots' is not a whole number; no cap" "$H/logs/$P.log" && ok \
  || bad "W1b: a bad STRANDED_MAX_PER_RUN is not logged: $(grep -i max_per_run "$H/logs/$P.log")"
# Back to W1's state (TK-989 re-offered once) for W3.
reset; watch

# ── W3: three re-offers in 24 h, then NEEDS_HUMAN ─────────────────────────
forget TK-989; watch
forget TK-989; watch
[ "$(nposts)" = 3 ] && ok || bad "W3: three re-offers in the window (posts: $(nposts))"
[ "$(grep -c . "$H/state/stranded-watch/$P/TK-989.reoffers" 2>/dev/null)" = 3 ] && ok || bad "W3: the ledger counts 3"
forget TK-989; watch
[ "$(nposts)" = 3 ] && ok || bad "W3: THE POINT: the fourth re-offer is NOT a row (posts: $(nposts))"
grep -q '^project-5 989 [0-9a-f]* the stranded-ticket watch re-offered TK-989 3 times in 24h and no PR came of it. Last result: failed: deferred 12 times' "$H/needs-human.log" && ok \
  || bad "W3: NEEDS_HUMAN is written with the last result: $(cat "$H/needs-human.log" 2>/dev/null)"
grep -q 'stranded: TK-989 (issue #989) NEEDS_HUMAN' "$H/logs/$P.log" && ok || bad "W3: the log says NEEDS_HUMAN: $(grep TK-989 "$H/logs/$P.log" | tail -1)"
forget TK-989; watch
[ "$(grep -c . "$H/needs-human.log")" = 1 ] && [ "$(nposts)" = 3 ] && ok || bad "W3: the next run places nothing new (needs-human: $(grep -c . "$H/needs-human.log"), posts: $(nposts))"

# ── W4: a ticket that got its PR loses its count ──────────────────────────
mkdir -p "$H/state/stranded-watch/$P"; printf '%s\n' "$NOW" "$NOW" > "$H/state/stranded-watch/$P/TK-902.reoffers"
watch
[ ! -e "$H/state/stranded-watch/$P/TK-902.reoffers" ] && ok || bad "W4: TK-902 has an open PR, so its re-offer count goes"

# ── W5: the triage-tick reconcile is not held by a stub or a stand-down ───
reset
mkdir -p "$H/builds/$P-TK-989-202610100803" "$H/builds/pool-$P-TK-910-202610100900"
echo 'QUEUED_FLY TK-989' > "$H/builds/$P-TK-989-202610100803/RESULT"
echo 'BUILD_DEFERRED After: TK-5 in flight — re-checked each tick' > "$H/builds/pool-$P-TK-910-202610100900/RESULT"
: > "$H/builds/pool-$P-TK-910-202610100900/DEFERRED"
"$H/bin/orphan-reconcile.sh" "$P" 2>/dev/null
grep -q 'project-5 989 TK-989' "$H/launches.log" 2>/dev/null && ok \
  || bad "W5: THE BUG: a QUEUED_FLY stub held TK-989 as awaiting-closeout ($(grep -o 'reconcile: open=.*' "$H/logs/$P.log" | tail -1))"
grep -q 'project-5 910 TK-910' "$H/launches.log" 2>/dev/null && ok \
  || bad "W5: a stand-down dir does not hold TK-910 ($(grep -o 'reconcile: open=.*' "$H/logs/$P.log" | tail -1))"
grep -q 'awaiting-closeout' "$H/logs/$P.log" && bad "W5: nothing here is awaiting a close-out: $(grep -o 'skipped=[^ ]*' "$H/logs/$P.log")" || ok

# ── W6: the cron entry dispatches the watch through the runner ────────────
reset
grep -E '^project-5 ' "$DIR/fleet.conf" > "$T/fleet-one.conf"
FLEET_CONF="$T/fleet-one.conf" STRANDED_WATCH_SPREAD_SECS=0 "$H/bin/stranded-watch.sh"
grep -q 'stranded-watch dispatch: started 1 project run(s) (period 0s, no cap)' "$H/logs/stranded-watch.log" && ok \
  || bad "W6: the dispatcher starts one run for the one project: $(cat "$H/logs/stranded-watch.log" 2>/dev/null)"
for _i in $(seq 1 300); do [ -s "$H/queue-posts.log" ] && break; sleep 0.2; done
[ "$(posts)" = '"key":"TK-989" ' ] && ok || bad "W6: the dispatched run re-offers TK-989 (posts: $(posts); cron log: $(tail -2 "$H/logs/stranded-watch-cron.log" 2>/dev/null))"

# ── W7: a pool-routed project gets a fly row ──────────────────────────────
reset
: > "$H/flags/builder-fly-project-5"; : > "$H/flags/fly-pool-project-5"
watch
grep -q '"key":"TK-989","target":"fly"' "$H/queue-posts.log" && ok || bad "W7: the row is targeted at the pool: $(cat "$H/queue-posts.log" 2>/dev/null)"
rm -f "$H/flags/builder-fly-project-5" "$H/flags/fly-pool-project-5"

# ── W8: a duplicate is not a re-offer ─────────────────────────────────────
reset; : > "$H/dup"
watch
rm -f "$H/dup"
[ ! -s "$H/state/stranded-watch/$P/TK-989.reoffers" ] && ok || bad "W8: a duplicate answer is not counted: $(cat "$H/state/stranded-watch/$P/TK-989.reoffers")"
grep -q 'stranded: TK-989 (issue #989) already has a queued or claimed row' "$H/logs/$P.log" && ok || bad "W8: the line says nothing was re-offered: $(grep 'TK-989' "$H/logs/$P.log" | tail -2)"

echo "stranded-watch.bh-5967: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
