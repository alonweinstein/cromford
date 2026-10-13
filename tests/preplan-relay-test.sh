#!/bin/bash
# tests/preplan-relay-test.sh — the pre-plan RELAY: a plan written on a watcher
# box reaching the Fly machine that actually builds the ticket.
# Run from anywhere: tests/preplan-relay-test.sh   (exit 0 = all pass)
#
# THE DEFECT THIS PINS (BH-658 / BH-775). bin/fly-pool.sh:push_preplan read
# $HARNESS/plans/<project>-<KEY>/ on the HUB — a box that is forbidden to
# pre-plan (bin/run-preplan.sh's hub-no-build block), so that directory is empty
# there by design. Every Fly build therefore re-planned from scratch and said
# nothing about it: 0 of 1052 build records on box-project-4-1 carried a
# PREPLAN_ line while that box's own plans/ held 58 plan dirs. The relay was
# reading one machine's disk for a file another machine had written.
#
# HOW IT IS DRIVEN. The producer is the REAL bin/run-preplan.sh against a
# scratch $HARNESS with a fake agent-call/git/curl; push_preplan is EXTRACTED
# VERBATIM from the shipped bin/fly-pool.sh (a paraphrase would pass on a
# version that never shipped). Every assertion reads a file the code wrote — the
# fake curl's call log, the relayed directory, logs/preplan.log — never source
# text.
#
# The jobs-client verbs themselves (preplan_put/get/index) are pinned by
# tests/jobs-client-test.sh; the adopt block and its evidence row are pinned
# where they ship. This suite owns the three hops in between.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/fakebin" "$T/env" "$T/flags" "$T/logs" "$T/locks" \
         "$T/plans" "$T/state" "$T/prompts" "$T/repos" "$T/builds" "$T/curl"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" proj || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/planned-files.sh" "$T/bin/" 2>/dev/null
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
: > "$T/env/global.env"

# ── the fake curl ────────────────────────────────────────────────────────────
# Records every call (method + url + body) and answers from files in $CURL_DIR:
#   routes   pattern<TAB>http-code<TAB>body-file, first URL match wins
#   rc       a TRANSPORT failure code (28 = timeout), 0 = answer normally
# A URL that matches no route answers 404, which is what a worker that has not
# been redeployed yet actually does.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
D="${CURL_DIR:?CURL_DIR unset}"
M=GET; U=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w|-o) shift 2 ;;
    -*) shift ;;
    *) U="$1"; shift ;;
  esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
N=$(cat "$D/n" 2>/dev/null || echo 0); N=$((N+1)); printf '%s\n' "$N" > "$D/n"
printf '%s\t%s\n' "$M" "$U" >> "$D/calls"
printf '%s' "$BODY" > "$D/body.$N"
printf '%s' "$BODY" > "$D/body.last"
RC=$(cat "$D/rc" 2>/dev/null || echo 0)
[ "$RC" != 0 ] && exit "$RC"
CODE=404; FILE=""
if [ -s "$D/routes" ]; then
  while IFS=$'\t' read -r PAT C F; do
    [ -n "$PAT" ] || continue
    case "$U" in *"$PAT"*) CODE="$C"; FILE="$F"; break ;; esac
  done < "$D/routes"
fi
if [ -n "$FILE" ] && [ -r "$FILE" ]; then cat "$FILE"; else printf '{"error":"no route"}'; fi
printf '\n%s' "$CODE"
exit 0
SH
chmod +x "$T/fakebin/curl"
curl_reset() { rm -f "$T/curl/calls" "$T/curl/n" "$T/curl/body."* "$T/curl/routes"; printf '0\n' > "$T/curl/rc"; }
route() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T/curl/routes"; }
curl_reset

# ── a consumable pre-plan record on disk, the shape run-preplan.sh leaves ─────
# THE PLAN ENDS IN TWO NEWLINES on purpose. preplan_put ships the file with
# --rawfile (exact bytes), so a fetch that round-trips the body through
# $(jq -r …) — which strips every trailing newline — writes back a DIFFERENT
# file than the box published. The cmp below is what catches that.
PD="$T/plans/proj-AB-1"; mkdir -p "$PD"
printf '## Scope\nTouch src/lib/pay.ts and nothing else.\nSIZE: S\n\n' > "$PD/plan.md"
printf '1234567890abcdef1234567890abcdef12345678\n' > "$PD/base-sha"
printf 'src/lib/pay.ts\n' > "$PD/planned-files.txt"
printf '2026-09-17T10:00:00Z|2026-09-17T10:00:00Z||3\n' > "$PD/ticket-fp"
printf 'AB-1\n' > "$PD/key"

echo "--- 1. preplan_fetch materializes the five files, key LAST"
# The row the worker would answer with, built from the SAME files the box holds
# (--rawfile = exact bytes), so "published" and "fetched" are comparable.
jq -n --rawfile plan "$PD/plan.md" --rawfile files "$PD/planned-files.txt" \
      --rawfile fp "$PD/ticket-fp" \
   '{preplan:{project:"proj",ticket_key:"AB-1",
              base_sha:"1234567890abcdef1234567890abcdef12345678",
              plan_md:$plan,planned_files:$files,ticket_fp:($fp|rtrimstr("\n"))}}' \
   > "$T/curl/row.json"

fetch() { # fetch <dst> -> rc of preplan_fetch
  ( export PATH="$T/fakebin:$PATH" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
           JOBS_BOX=test-box JOBS_RETRIES=0 CURL_DIR="$T/curl"
    # shellcheck source=/dev/null
    . "$T/bin/lib/preplan-lib.sh"
    preplan_fetch "$T" proj AB-1 "$1"; echo "rc=$?" )
}
curl_reset; route /api/preplans 200 "$T/curl/row.json"
D2="$T/fetched"
OUT=$(fetch "$D2")
[ "$OUT" = "rc=0" ] && ok || bad "a published row must fetch (got: $OUT)"
[ -s "$D2/plan.md" ] && ok || bad "fetch must write the row's plan_md"
[ "$(cat "$D2/base-sha" 2>/dev/null)" = 1234567890abcdef1234567890abcdef12345678 ] \
  && ok || bad "fetch must write base-sha"
[ "$(cat "$D2/planned-files.txt" 2>/dev/null)" = "src/lib/pay.ts" ] \
  && ok || bad "fetch must write planned-files.txt"
[ "$(cat "$D2/ticket-fp" 2>/dev/null)" = '2026-09-17T10:00:00Z|2026-09-17T10:00:00Z||3' ] \
  && ok || bad "fetch must write ticket-fp"
[ "$(cat "$D2/key" 2>/dev/null)" = AB-1 ] && ok || bad "fetch must write key"
# The relayed plan is the plan the builder BUILDS FROM. Byte-equal, or the
# machine is executing a document the box never wrote.
cmp -s "$PD/plan.md" "$D2/plan.md" \
  && ok || bad "the fetched plan.md must be BYTE-IDENTICAL to the published one (published $(wc -c < "$PD/plan.md") bytes, fetched $(wc -c < "$D2/plan.md" 2>/dev/null || echo 0))"
cmp -s "$PD/planned-files.txt" "$D2/planned-files.txt" \
  && ok || bad "the fetched planned-files.txt must be byte-identical to the published one"

# `key` is the GATE preplan_find checks, so it must land LAST. Proven by making
# an earlier write fail rather than by comparing mtimes: tmpfs stamps files at
# clock granularity, so five writes microseconds apart can share one mtime and
# an ordering assertion over them would pass on any order at all. Here base-sha
# cannot be written (it is a directory), so a fetch that wrote `key` first would
# leave an adoptable directory with no base sha in it — which is exactly the
# half-pushed pre-plan the gate exists to refuse.
D2B="$T/fetch-halfway"; mkdir -p "$D2B/base-sha"
curl_reset; route /api/preplans 200 "$T/curl/row.json"
OUT=$(fetch "$D2B" 2>/dev/null)
[ "$OUT" = "rc=2" ] && ok || bad "a fetch that cannot write its files must fail, got: $OUT"
[ ! -e "$D2B/key" ] && ok \
  || bad "key must be written LAST — a directory whose earlier files failed must never carry the gate file"

# A row for another ticket is NOT this ticket's pre-plan (TK-493: a reused
# machine's directory must say who it is for).
cat > "$T/curl/other.json" <<'JSON'
{"preplan":{"project":"proj","ticket_key":"AB-9","base_sha":"1234567890abcdef1234567890abcdef12345678","plan_md":"other\n"}}
JSON
curl_reset; route /api/preplans 200 "$T/curl/other.json"
D3="$T/fetched-other"
OUT=$(fetch "$D3")
[ "$OUT" = "rc=1" ] && ok || bad "a row for ANOTHER ticket_key must be a miss (rc 1), got: $OUT"
[ ! -e "$D3/plan.md" ] && ok || bad "a refused row must leave no plan.md behind"

# A row with a plan but no base sha is UNPARSEABLE, not a miss: the freshness
# check has nothing to answer with, and "miss" would send an operator looking
# for a pre-plan that was in fact stored.
cat > "$T/curl/nosha.json" <<'JSON'
{"preplan":{"project":"proj","ticket_key":"AB-1","plan_md":"## Scope\nsomething\n"}}
JSON
curl_reset; route /api/preplans 200 "$T/curl/nosha.json"
OUT=$(fetch "$T/fetched-nosha")
[ "$OUT" = "rc=2" ] && ok || bad "a row with no base_sha must be rc 2 (unparseable), got: $OUT"

curl_reset; route /nothing 200 ""
OUT=$(fetch "$T/fetched-404")
[ "$OUT" = "rc=1" ] && ok || bad "a 404 must be a MISS (rc 1), got: $OUT"
curl_reset; printf '28\n' > "$T/curl/rc"
OUT=$(fetch "$T/fetched-down")
[ "$OUT" = "rc=2" ] && ok || bad "an outage must be rc 2, never a miss, got: $OUT"
printf '0\n' > "$T/curl/rc"

echo "--- 2. there is no publish gate (BH-3437)"
# Every box publishes; tests/preplan-publish.bh-3437-test.sh drives the block.
# The routing-flag gate read a hub file a watcher box need not have.
! grep -q preplan_publish_wanted "$DIR/bin/run-preplan.sh" "$DIR/bin/lib/preplan-lib.sh" \
  && ok || bad "the preplan_publish_wanted routing gate must be gone"
touch "$T/flags/builder-fly-proj"

echo "--- 3. push_preplan (extracted verbatim from bin/fly-pool.sh)"
sed -n '/^push_preplan() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$T/push.sh"
[ -s "$T/push.sh" ] && ok || bad "could not extract push_preplan from bin/fly-pool.sh"
# drive it with stubbed mput/say/preplan_fetch, the hub's own plans/ dir empty
push() { # push <mode: hit|miss|outage|local> -> writes $T/push-calls and $T/push-say
  local mode="$1"
  rm -f "$T/push-calls" "$T/push-say" "$T/push-fetched"
  ( HARNESS="$T/hub"; P=proj
    say() { printf '%s\n' "$*" >> "$T/push-say"; }
    preplan_speculative() { echo 1; }
    mput() { printf 'mput %s -> %s\n' "$2" "$3" >> "$T/push-calls"; }
    preplan_fetch() {
      printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$T/push-fetched"
      case "$mode" in
        hit) mkdir -p "$4"
             printf 'relayed plan\n' > "$4/plan.md"
             printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$4/base-sha"
             printf 'src/lib/pay.ts\n' > "$4/planned-files.txt"
             return 0 ;;
        outage) return 2 ;;
        *) return 1 ;;
      esac
    }
    # shellcheck source=/dev/null
    . "$T/push.sh"; push_preplan m1 AB-1 )
}
mkdir -p "$T/hub/plans"
push hit
grep -q 'preplan/plan.md' "$T/push-calls" 2>/dev/null \
  && ok || bad "with an empty hub plans/ the relay must fetch and ship the plan (calls: $(cat "$T/push-calls" 2>/dev/null))"
[ "$(tail -1 "$T/push-calls" 2>/dev/null)" = "mput $(tail -1 "$T/push-calls" 2>/dev/null | awk '{print $2}') -> /run/harness/preplan/key" ] \
  && ok || bad "key must be the LAST file pushed — it is the adopt's gate (calls: $(cat "$T/push-calls" 2>/dev/null))"
grep -q 'preplan/base-sha' "$T/push-calls" 2>/dev/null \
  && ok || bad "the staleness data must ride with the plan (calls: $(cat "$T/push-calls" 2>/dev/null))"
grep -q 'source: db' "$T/push-say" 2>/dev/null \
  && ok || bad "the relay must say where the pre-plan came from (say: $(cat "$T/push-say" 2>/dev/null))"
# the temp dir it fetched into is removed, under a /tmp/ prefix guard
FETCHED=$(awk '{print $4}' "$T/push-fetched" 2>/dev/null)
case "$FETCHED" in /tmp/preplan-relay.*) ok ;; *) bad "the fetch target must be a mktemp dir under /tmp (got: $FETCHED)" ;; esac
[ -n "$FETCHED" ] && [ ! -d "$FETCHED" ] && ok || bad "the relay's temp dir must be removed ($FETCHED still exists)"

push miss
[ ! -s "$T/push-calls" ] && ok || bad "a DB miss must ship nothing (calls: $(cat "$T/push-calls" 2>/dev/null))"
grep -q 'PREPLAN_MISS' "$T/push-say" 2>/dev/null \
  && ok || bad "a DB miss must say the builder will record PREPLAN_MISS (say: $(cat "$T/push-say" 2>/dev/null))"
grep -q 'db: miss' "$T/push-say" 2>/dev/null \
  && ok || bad "a miss must be named a miss (say: $(cat "$T/push-say" 2>/dev/null))"
push outage
grep -q 'db: outage' "$T/push-say" 2>/dev/null \
  && ok || bad "an outage must NOT read as a miss (say: $(cat "$T/push-say" 2>/dev/null))"
[ ! -s "$T/push-calls" ] && ok || bad "an outage must ship nothing (calls: $(cat "$T/push-calls" 2>/dev/null))"

# a LOCAL pre-plan dir still wins, and costs no request at all
mkdir -p "$T/hub/plans/proj-AB-1"
printf 'local plan\n' > "$T/hub/plans/proj-AB-1/plan.md"
printf 'cafebabecafebabecafebabecafebabecafebabe\n' > "$T/hub/plans/proj-AB-1/base-sha"
push local
[ ! -e "$T/push-fetched" ] && ok || bad "a local pre-plan dir must not hit the DB"
grep -q 'source: local' "$T/push-say" 2>/dev/null \
  && ok || bad "a local relay must say so (say: $(cat "$T/push-say" 2>/dev/null))"
scratch_rm "$T/hub/plans/proj-AB-1"

# no client on this host: the relay cannot even ask, and says so rather than
# returning like a machine that had nothing to send.
rm -f "$T/push-calls" "$T/push-say"
( HARNESS="$T/hub"; P=proj
  say() { printf '%s\n' "$*" >> "$T/push-say"; }
  preplan_speculative() { echo 1; }
  mput() { printf 'mput %s -> %s\n' "$2" "$3" >> "$T/push-calls"; }
  . "$T/push.sh"; push_preplan m1 AB-1 )
[ ! -e "$T/push-calls" ] && ok || bad "with no preplan_fetch the relay must ship nothing"
grep -q 'no client on this host' "$T/push-say" 2>/dev/null \
  && ok || bad "a host with no client must say so (say: $(cat "$T/push-say" 2>/dev/null))"
grep -q 'PREPLAN_MISS' "$T/push-say" 2>/dev/null \
  && ok || bad "the no-client line must name the outcome the builder will record"

# mktemp failing (a full /tmp on the hub) must not be the one silent path left:
# zero pushes, and a line that says the builder is about to PREPLAN_MISS.
rm -f "$T/push-calls" "$T/push-say" "$T/push-fetched"
( HARNESS="$T/hub"; P=proj
  say() { printf '%s\n' "$*" >> "$T/push-say"; }
  preplan_speculative() { echo 1; }
  mput() { printf 'mput %s -> %s\n' "$2" "$3" >> "$T/push-calls"; }
  preplan_fetch() { printf 'fetch\n' >> "$T/push-fetched"; return 0; }
  mktemp() { return 1; }
  . "$T/push.sh"; push_preplan m1 AB-1 )
[ ! -e "$T/push-calls" ] && ok || bad "a failed mktemp must ship nothing (calls: $(cat "$T/push-calls" 2>/dev/null))"
grep -q 'PREPLAN_MISS' "$T/push-say" 2>/dev/null \
  && ok || bad "a failed mktemp must SAY the relay shipped nothing (say: $(cat "$T/push-say" 2>/dev/null))"

# the kill flag still stops everything
rm -f "$T/push-calls" "$T/push-say" "$T/push-fetched"
( HARNESS="$T/hub"; P=proj; say() { :; }; preplan_speculative() { echo 0; }
  mput() { printf 'mput\n' >> "$T/push-calls"; }
  preplan_fetch() { printf 'fetch\n' >> "$T/push-fetched"; return 1; }
  . "$T/push.sh"; push_preplan m1 AB-1 )
[ ! -e "$T/push-calls" ] && [ ! -e "$T/push-fetched" ] && ok \
  || bad "PREPLAN_SPECULATIVE=0 must stop the relay before it reads anything"

echo "--- 4. the producer: bin/run-preplan.sh publishes what it just wrote"
PH="$T/producer"; mkdir -p "$PH/bin/lib" "$PH/env" "$PH/flags" "$PH/logs" "$PH/locks" \
                          "$PH/plans" "$PH/prompts" "$PH/state" "$PH/repos/proj" "$PH/curl"
model_routes_fixture "$PH" proj || exit 1  # BH-1510.2: this root runs a converted lane too
cp "$DIR/bin/run-preplan.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/planned-files.sh" "$PH/bin/"
mkdir -p "$PH/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$PH/bin/lib/jobs/"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/hub-box.sh" "$PH/bin/lib/"
printf 'JOBS_URL=https://jobs.invalid\nHARNESS_SECRET=test-secret\nJOBS_RETRIES=0\n' > "$PH/env/global.env"
# A WATCHER box, not the hub: bin/lib/hub-box.sh refuses to pre-plan on the hub,
# which is the whole reason the hub's plans/ dir is empty and this relay exists.
cat > "$PH/bin/box-name.sh" <<'SH'
#!/bin/bash
echo box-test
SH
cat > "$PH/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in prod) echo '-' ;; board_prefix) echo '-' ;; *) echo '-' ;; esac
SH
cat > "$PH/bin/verification-map.sh" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$PH/bin/agent-call.sh" <<'SH'
#!/bin/bash
# $5 is the plan-run log inside the plan dir
D=$(dirname "$5"); mkdir -p "$D"
printf '## Scope\nTouch src/lib/pay.ts.\n\n## Size\nFILES: 1\nLINES: 10\nSIZE: S\n' > "$D/plan.md"
exit 0
SH
cat > "$PH/bin/git" <<'SH'
#!/bin/bash
ARGS="$*"
case "$ARGS" in
  *rev-parse*) echo 1234567890abcdef1234567890abcdef12345678 ;;
  *"worktree add"*) P=""; PREV=""; for A in "$@"; do [ "$PREV" = "--detach" ] && P="$A"; PREV="$A"; done
                    [ -n "$P" ] && mkdir -p "$P" ;;
esac
exit 0
SH
chmod +x "$PH/bin/"*.sh "$PH/bin/git"
cp "$T/fakebin/curl" "$PH/bin/curl"; chmod +x "$PH/bin/curl"
preplan_run() { # preplan_run [transport-rc] [http-code|none] -> the script's exit code
  scratch_rm "$PH/plans/proj-AB-1"; scratch_rm "$PH/repos/.preplan-proj-AB-1"
  rm -f "$PH/curl/calls" "$PH/curl/n" "$PH/curl/body."* "$PH/curl/routes"
  printf '%s\n' "${1:-0}" > "$PH/curl/rc"
  [ "${2:-200}" = none ] || printf '/api/preplans\t%s\t%s\n' "${2:-200}" "$PH/curl/ok.json" > "$PH/curl/routes"
  ( export HARNESS="$PH" REPOS_ROOT="$PH/repos" CURL_DIR="$PH/curl" \
           PATH="$PH/bin:$PATH" PREPLAN_SPECULATIVE=1
    "$PH/bin/run-preplan.sh" proj tkt-1 AB-1 >/dev/null 2>&1; echo "$?" )
}
printf '{"preplan":{"project":"proj","ticket_key":"AB-1"}}' > "$PH/curl/ok.json"

touch "$PH/flags/builder-fly-proj"
RC=$(preplan_run)
[ "$RC" = 0 ] && ok || bad "run-preplan.sh must exit 0 on the happy path (got $RC)"
[ -s "$PH/plans/proj-AB-1/plan.md" ] && ok || bad "run-preplan.sh must leave the plan on disk"
POSTS=$(grep -c $'POST\thttps://jobs.invalid/api/preplans' "$PH/curl/calls" 2>/dev/null || true)
[ "$POSTS" = 1 ] && ok || bad "a Fly-routed project must publish exactly one pre-plan (POSTs: $POSTS, calls: $(cat "$PH/curl/calls" 2>/dev/null))"
[ "$(jq -r '.plan_md' "$PH/curl/body.last" 2>/dev/null)" = "$(cat "$PH/plans/proj-AB-1/plan.md")" ] \
  && ok || bad "the published plan_md must be the plan this run just wrote"
[ "$(jq -r '.base_sha' "$PH/curl/body.last" 2>/dev/null)" = 1234567890abcdef1234567890abcdef12345678 ] \
  && ok || bad "the published base_sha must be the sha the planner read"
# Published AFTER the consumable record is complete: a row that described a
# half-written plan dir is the one failure worse than no row at all.
[ -s "$PH/plans/proj-AB-1/key" ] && ok || bad "the publish must happen after key is on disk"
grep -q 'pre-plan published' "$PH/logs/preplan.log" \
  && ok || bad "the publish must leave a line in logs/preplan.log"

# BH-3437: a box with NO flags/builder-fly-* publishes all the same. That flag
# is hub-side routing state a watcher box need not carry, and gating on it is
# why project-5, project-1 and project-3 published 0 rows.
rm -f "$PH/flags/builder-fly-proj"
RC=$(preplan_run)
[ "$RC" = 0 ] && ok || bad "a flag-less box's pre-plan must still exit 0 (got $RC)"
POSTS=$(grep -c $'POST\thttps://jobs.invalid/api/preplans' "$PH/curl/calls" 2>/dev/null || true)
[ "$POSTS" = 1 ] && ok \
  || bad "a box with no builder-fly flag must still publish exactly one pre-plan (POSTs: $POSTS, calls: $(cat "$PH/curl/calls" 2>/dev/null))"
touch "$PH/flags/builder-fly-proj"

: > "$PH/logs/preplan.log"
RC=$(preplan_run 28)
[ "$RC" = 0 ] && ok || bad "an unreachable worker must never change the pre-plan's exit code (got $RC)"
grep -q 'publish unreachable' "$PH/logs/preplan.log" \
  && ok || bad "an outage must say 'unreachable' in logs/preplan.log (log: $(tail -3 "$PH/logs/preplan.log"))"
: > "$PH/logs/preplan.log"
RC=$(preplan_run 0 413)
[ "$RC" = 0 ] && ok || bad "a refused publish must never change the exit code (got $RC)"
grep -q 'publish REFUSED' "$PH/logs/preplan.log" \
  && ok || bad "a 413 must say REFUSED, never 'published' (log: $(tail -3 "$PH/logs/preplan.log"))"
# A 500 is the WORKER breaking, not the worker judging this plan. It must read as
# an outage, or the line sends an operator to the payload while the server is the
# thing that is down.
: > "$PH/logs/preplan.log"
RC=$(preplan_run 0 500)
[ "$RC" = 0 ] && ok || bad "a 500 must never change the pre-plan's exit code (got $RC)"
grep -q 'publish unreachable (500)' "$PH/logs/preplan.log" \
  && ok || bad "a 500 must say unreachable and carry the status (log: $(tail -3 "$PH/logs/preplan.log"))"
grep -q 'publish REFUSED' "$PH/logs/preplan.log" \
  && bad "a 500 must never be logged as REFUSED (log: $(tail -3 "$PH/logs/preplan.log"))" || ok

echo "preplan-relay: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
