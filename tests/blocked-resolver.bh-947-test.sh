#!/bin/bash
# tests/blocked-resolver.bh-947-test.sh — BH-947: the rebuild rung holds on a live
# build, counts distinct job ids for the cap, and refuses to double-spend a
# duplicate enqueue answer.
#
# Run from anywhere: tests/blocked-resolver.bh-947-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh REQUIRES the REST contract (#783): without it the lane
# refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
# bin/lib/br/ (BH-1176): the lane sources its modules out of $HARNESS and REFUSES
# the tick without them, so a fixture that copies the script must carry them too.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
chmod +x "$H/bin/"*.sh
# One project, a GitHub-Issues lane (board prefix "-"), owned by a remote box.
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# lane-alert is RECORDED, never stubbed silent.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# Every gh call is recorded.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # bin/blocked-resolver.sh decides, comments and closes over REST now (#783):
  # the \`gh api -i\` envelope is answered by the shared stub, which records
  # every PATCH in \$T/closed.txt and every comment POST in \$T/comments.txt.
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/TK-9' > "$T/prbranch"
    printf 'TK-9: a thing' > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/TK-9" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/TK-9" ;;
  *"--json headRefName"*)  echo "ticket/TK-9" ;;
  *"--json headRefOid"*)   echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  *"pr list"*"--state merged"*) cat "$T/mergedprs" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
echo OPEN > "$T/prstate"; : > "$T/mergedprs"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""

# Force the rebuild rung immediately: no mechanical/fix-round attempts.
BRENV=(BR_MAX_REBUILDS=3 BR_MAX_MECHANICAL=0 BR_MAX_FIXROUNDS=0)

RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
ROW() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$(date -u +%s)" abc123 abc123 "$2" "$3" \
          > "$H/state/merge-conductor/pr-state.tsv"; }
ROWST() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$2" "$(date -u +%s)" abc123 abc123 "$3" "$4" \
          > "$H/state/merge-conductor/pr-state.tsv"; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
LOG() { tail -n 25 "$H/logs/blocked-resolver.log" 2>/dev/null; }
ALERTS() { cat "$H/logs/ALERTS.log" 2>/dev/null; }
CLEAN() { scratch_rm "$H/state/blocked-resolver"; mkdir -p "$H/state/blocked-resolver/tproj"; rm -f "$H"/state/build-queue/tproj/* 2>/dev/null || true
          scratch_rm "$H/builds"; mkdir -p "$H/builds"
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comments.txt"; : > "$T/lane-alert.txt"
          : > "$H/logs/ALERTS.log"; : > "$H/logs/blocked-resolver.log"; : > "$T/run.log"
          rm -f "$H"/state/jobs-* 2>/dev/null || true
          echo OPEN > "$T/prstate"; : > "$T/mergedprs"; }

# Generic jobs-client stub: answers come from files under $H/state.
JOBS_GENERIC() {
  cat > "$H/bin/jobs-client.sh" <<'JOBS1'
#!/bin/bash
queue_put() {
  printf '%s\n' "$*" >> "$H/state/jobs-queue-put.txt"
  local ans; ans=$(cat "$H/state/jobs-put-answer.txt" 2>/dev/null)
  [ -n "$ans" ] || return 1
  printf '%s\n' "$ans"
}
queue_row() {
  cat "$H/state/jobs-row.txt" 2>/dev/null
  return $(cat "$H/state/jobs-row-rc.txt" 2>/dev/null || echo 2)
}
queue_list() {
  cat "$H/state/jobs-list.txt" 2>/dev/null
  [ -s "$H/state/jobs-list.txt" ] || return 1
}
queue_done() { return 0; }
JOBS1
  chmod +x "$H/bin/jobs-client.sh"
}
PUT_ANSWER() { printf '%s' "$1" > "$H/state/jobs-put-answer.txt"; }
ROW_ANSWER() { printf '%b' "$1" > "$H/state/jobs-row.txt"; printf '%s' "${2:-0}" > "$H/state/jobs-row-rc.txt"; }
LIST_ANSWER() { printf '%b' "$1" > "$H/state/jobs-list.txt"; }

# ============================================================================
# 1. RED-FIRST duplicate race: queue_put says queued once, duplicate twice.
#    The duplicate answers must spend NO rung and must not abandon.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"
# queue_put writes the row store, so from tick 2 the PRE-CHECK sees the live row
# and holds before any enqueue. This case pins the PRE-CHECK hold (the cheap
# half of the fix); the enqueue's own `duplicate` answer is pinned by case 10
# and the race behind it by case 11.
cat > "$H/bin/jobs-client.sh" <<'JOBS2'
#!/bin/bash
queue_row() {
  local store="$H/state/jobs-row-store-$1-$2"
  cat "$store" 2>/dev/null
  [ -s "$store" ] || return 2
}
queue_put() {
  local cfile="$H/state/jobs-put-count-$1-$2"
  local cnt; cnt=$(cat "$cfile" 2>/dev/null || echo 0)
  local ans
  local store="$H/state/jobs-row-store-$1-$2"
  if [ "$cnt" = 0 ]; then ans="queued"; else ans="duplicate"; fi
  echo $((cnt+1)) > "$cfile"
  printf '%s\n' "$*" >> "$H/state/jobs-queue-put.txt"
  local stamp; stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%b\n' "$ans\t$stamp\t-\t-\t-" > "$store"
  printf '%s\n' "$ans"
}
queue_done() { return 0; }
queue_list() { return 1; }
JOBS2
chmod +x "$H/bin/jobs-client.sh"
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
RUN
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0')" = 1 ] && ok \
  || bad "duplicate race must spend exactly one rebuild counter (got $(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0'))"
[ "$(STATEJSON tproj-TK-9 | jq -r '(.rebuild_jobs // []) | length')" = 1 ] && ok \
  || bad "exactly one ledger job must be recorded (got $(STATEJSON tproj-TK-9 | jq -r '(.rebuild_jobs // []) | length'))"
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')" = REBUILD_WAIT ] && ok \
  || bad "a held duplicate race must set wait=REBUILD_WAIT (got '$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = "" ] && ok \
  || bad "duplicate race must not abandon (outcome '$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')')"
grep -q 'rebuild already in flight' "$H/logs/blocked-resolver.log" && ok \
  || bad "log must name the hold (got: $(LOG))"
[ "$(grep -c 'REBUILD FRESH' "$H/logs/blocked-resolver.log")" = 1 ] && ok \
  || bad "exactly one REBUILD FRESH line expected (got $(grep -c 'REBUILD FRESH' "$H/logs/blocked-resolver.log"))"
[ "$(grep -c 'rebuild 2 of 3' "$H/logs/blocked-resolver.log")" = 0 ] && ok \
  || bad "no second rebuild attempt should be logged"
[ "$(grep -c 'rebuild 3 of 3' "$H/logs/blocked-resolver.log")" = 0 ] && ok \
  || bad "no third rebuild attempt should be logged"
grep -q 'ABANDONED' "$H/logs/ALERTS.log" \
  && bad "duplicate race must not alert ABANDONED (got: $(ALERTS))" || ok

# ============================================================================
# 2. Three failed jobs: ledger already holds three distinct jobs; cap ends it.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER queued
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
# Seed a ledger with three past rebuild job ids and three attempts.
jq -nc --arg at "$(ISO 3600)" --arg now "$(ISO 0)" \
  '{project:"tproj",rkey:"tproj-TK-9",mechanicals:0,fixrounds:0,rebuilds:3,outcome:"",
    rebuild_jobs:[
      {id:"TK-9@2026-09-19T10:00:00Z~r1",enqueued_at:"2026-09-19T10:00:00Z",at:$at},
      {id:"TK-9@2026-09-19T11:00:00Z~r2",enqueued_at:"2026-09-19T11:00:00Z",at:$at},
      {id:"TK-9@2026-09-19T12:00:00Z~r3",enqueued_at:"2026-09-19T12:00:00Z",at:$at}
    ],
    attempts:[
      {at:$at,action:"rebuild-fresh",reason:"merge-failed-twice",detail:"fresh build enqueued (rebuild 1 of 3)"},
      {at:$at,action:"rebuild-fresh",reason:"merge-failed-twice",detail:"fresh build enqueued (rebuild 2 of 3)"},
      {at:$at,action:"rebuild-fresh",reason:"merge-failed-twice",detail:"fresh build enqueued (rebuild 3 of 3)"}
    ],updated:$now}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
# Readable empty queue: no live build, cap reached -> abandon.
ROW_ANSWER "" 0
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = ABANDONED ] && ok \
  || bad "three failed jobs must reach ABANDONED (got '$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')')"
grep -q 'ABANDONED tproj/tproj-TK-9' "$H/logs/ALERTS.log" && ok \
  || bad "ABANDONED must be logged (got: $(ALERTS))"
grep -q 'TK-9@2026-09-19T10:00:00Z~r1' "$H/logs/ALERTS.log" && ok \
  || bad "ABANDONED alert must name the first job (got: $(ALERTS))"
grep -q 'TK-9@2026-09-19T12:00:00Z~r3' "$H/logs/ALERTS.log" && ok \
  || bad "ABANDONED alert must name the last job (got: $(ALERTS))"

# ============================================================================
# 3. Live claimed row: pre-check holds, no close, no event, br_one rc 3.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER queued
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
ROW_ANSWER "claimed\t2026-09-19T10:00:00Z\tm1\t-\t-" 0
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')" = REBUILD_WAIT ] && ok \
  || bad "live claimed row must set wait=REBUILD_WAIT (got '$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0')" = 0 ] && ok \
  || bad "a held row must spend no rebuild counter (got $(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0'))"
[ -s "$T/closed.txt" ] && bad "a held row must not close the PR (closed: $(cat "$T/closed.txt"))" || ok
grep -q 'EVENT resolver_rung' "$H/logs/blocked-resolver.log" \
  && bad "a held row must not emit a rung event (got: $(LOG))" || ok
grep -q 'rebuild already in flight (job' "$H/logs/blocked-resolver.log" && ok \
  || bad "log must say the rebuild is already in flight (got: $(LOG))"
# br_one rc 3 and no PER_TICK slot spent: the tick line must say rungs=0/...
grep -qE 'rungs=0/' "$H/logs/blocked-resolver.log" && ok \
  || bad "a held candidate must consume no per-tick slot (got: $(LOG))"

# ============================================================================
# 4. PR_CREATED RESULT lands: rebuild-landed, wait cleared.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER queued
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
# The stale PR was closed by the rebuild rung; reflect it in the gh stub.
echo CLOSED > "$T/prstate"
# Move the conductor row out of BLOCKED_HUMAN so it is not re-offered.
printf 'o/tproj#9	CLOSED	%s	abc123	abc123	-	merge-failed-twice	https://github.com/o/tproj/pull/9
' "$(date -u +%s)" > "$H/state/merge-conductor/pr-state.tsv"
# Simulate the rebuild finishing with PR_CREATED.
mkdir -p "$H/builds/tproj-TK-9-202609191000"
printf 'PR_CREATED https://github.com/o/tproj/pull/99\n' > "$H/builds/tproj-TK-9-202609191000/RESULT"
touch -d "@$((NOW+60))" "$H/builds/tproj-TK-9-202609191000/RESULT"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')" = "-" ] && ok \
  || bad "a landed rebuild must clear wait (got '$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait_job // ""')" = "-" ] && ok \
  || bad "a landed rebuild must clear wait_job (got '$(STATEJSON tproj-TK-9 | jq -r '.wait_job // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action // ""')" = rebuild-landed ] && ok \
  || bad "a landed rebuild must record rebuild-landed (got '$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action // ""')')"
[ "$(grep -c -- '-X PATCH' "$T/closed.txt")" = 1 ] && ok \
  || bad "the stale PR must be closed exactly once (got $(grep -c -- '-X PATCH' "$T/closed.txt"))"

# ============================================================================
# 5. Queue outage at cap: hold, not abandon.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER queued
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
# Seed a ledger at the cap, then make queue_row unreadable.
jq -nc --arg at "$(ISO 3600)" --arg now "$(ISO 0)" \
  '{project:"tproj",rkey:"tproj-TK-9",mechanicals:0,fixrounds:0,rebuilds:3,outcome:"",
    rebuild_jobs:[
      {id:"TK-9@E1",enqueued_at:"2026-09-19T10:00:00Z",at:$at},
      {id:"TK-9@E2",enqueued_at:"2026-09-19T11:00:00Z",at:$at},
      {id:"TK-9@E3",enqueued_at:"2026-09-19T12:00:00Z",at:$at}
    ],attempts:[],updated:$now}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
ROW_ANSWER "" 2
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = "" ] && ok \
  || bad "outage at cap must hold, not abandon (got '$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')" = REBUILD_WAIT ] && ok \
  || bad "outage at cap must set wait (got '$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')')"
grep -q 'NOT abandoned' "$H/logs/blocked-resolver.log" && ok \
  || bad "log must say NOT abandoned (got: $(LOG))"
grep -q 'ABANDONED' "$H/logs/ALERTS.log" \
  && bad "outage at cap must not alert ABANDONED (got: $(ALERTS))" || ok

# ============================================================================
# 6. Old client (no queue_row) + legacy row: today's behaviour preserved.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"
cat > "$H/bin/jobs-client.sh" <<'JOBS3'
#!/bin/bash
queue_put() { printf '%s\n' "$*" >> "$H/state/jobs-queue-put.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
JOBS3
chmod +x "$H/bin/jobs-client.sh"
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
# Seed a legacy row with no ledger.
jq -nc --arg at "$(ISO 3600)" --arg now "$(ISO 0)" \
  '{project:"tproj",rkey:"tproj-TK-9",mechanicals:0,fixrounds:0,rebuilds:1,outcome:"",attempts:[],updated:$now}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0')" = 2 ] && ok \
  || bad "old client must keep bumping the legacy counter (got $(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0'))"
[ "$(STATEJSON tproj-TK-9 | jq -r 'has("rebuild_jobs")')" = false ] && ok \
  || bad "old client must not create a ledger (got $(STATEJSON tproj-TK-9 | jq -c '.rebuild_jobs // null'))"

# ============================================================================
# 7. External job: empty ledger, queue_row answers claimed for an unknown job,
#    then a RESULT + done row arrives → rebuild-landed.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER queued
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
# External job is live in the worker but never enqueued by this lane.
ROW_ANSWER "claimed\t2026-09-19T09:00:00Z\tm1\t-\texternal enqueue" 0
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')" = REBUILD_WAIT ] && ok \
  || bad "external job must set wait (got '$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.rebuild_jobs | length // 0')" = 0 ] && ok \
  || bad "external job must not be added to rebuild_jobs (got $(STATEJSON tproj-TK-9 | jq -r '.rebuild_jobs | length // 0'))"
[ "$(STATEJSON tproj-TK-9 | jq -r '[.attempts[]? | select(.action == "rebuild-fresh")] | length')" = 1 ] && ok \
  || bad "external job must record exactly one rebuild-fresh attempt (got $(STATEJSON tproj-TK-9 | jq -r '[.attempts[]? | select(.action == "rebuild-fresh")] | length'))"
# The stale PR was closed by the rebuild rung; reflect it in the gh stub.
echo CLOSED > "$T/prstate"
# Move the conductor row out of BLOCKED_HUMAN so it is not re-offered.
printf 'o/tproj#9	CLOSED	%s	abc123	abc123	-	merge-failed-twice	https://github.com/o/tproj/pull/9
' "$(date -u +%s)" > "$H/state/merge-conductor/pr-state.tsv"
# The external job finishes.
mkdir -p "$H/builds/tproj-TK-9-202609190900"
printf 'PR_CREATED https://github.com/o/tproj/pull/99\n' > "$H/builds/tproj-TK-9-202609190900/RESULT"
touch -d "@$((NOW+60))" "$H/builds/tproj-TK-9-202609190900/RESULT"
ROW_ANSWER "done\t2026-09-19T09:00:00Z\tm1\t-\texternal enqueue" 0
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')" = "-" ] && ok \
  || bad "external job landing must clear wait (got '$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action // ""')" = rebuild-landed ] && ok \
  || bad "external job landing must record rebuild-landed (got '$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action // ""')')"

# ============================================================================
# 8. F2 pin: seeded row + PLAN_BLOCKED RESULT + done row → abandoned, counter stays 1.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER queued
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
jq -nc --arg at "$(ISO 3600)" --arg now "$(ISO 0)" \
  '{project:"tproj",rkey:"tproj-TK-9",mechanicals:0,fixrounds:0,rebuilds:1,outcome:"",
    rebuild_jobs:[{id:"TK-9@E1",enqueued_at:"2026-09-19T10:00:00Z",at:$at}],
    attempts:[{at:$at,action:"rebuild-fresh",reason:"merge-failed-twice",detail:"fresh build enqueued (rebuild 1 of 3)"}],
    parked_url:"https://github.com/o/tproj/pull/9",parked_rec:"-",updated:$now}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
mkdir -p "$H/builds/tproj-TK-9-202609191000"
printf 'PLAN_BLOCKED the ticket does not say which rate applies, see %s/plan.md\n' "$H/builds/tproj-TK-9-202609191000" > "$H/builds/tproj-TK-9-202609191000/RESULT"
touch -d "@$((NOW+60))" "$H/builds/tproj-TK-9-202609191000/RESULT"
LIST_ANSWER "tproj\tTS-9\t9\tdone\tfly\t0\tm1\t2026-09-19T10:00:00Z\tPLAN_BLOCKED the ticket does not say which rate applies, see $H/builds/tproj-TK-9-202609191000/plan.md\t-"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = ABANDONED ] && ok \
  || bad "PLAN_BLOCKED RESULT must abandon (got '$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0')" = 1 ] && ok \
  || bad "F2 pin must keep rebuild counter at 1 (got $(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0'))"
grep -q 'PLAN_BLOCKED' "$H/logs/ALERTS.log" && ok \
  || bad "ABANDONED alert must name PLAN_BLOCKED (got: $(ALERTS))"

# ============================================================================
# 9. OBSERVE mode: every new path logs WOULD and writes nothing.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER queued
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
touch "$H/flags/blocked-resolver-observe"
RUN
[ -s "$T/closed.txt" ] && bad "observe mode must not close a PR" || ok
[ -s "$H/state/jobs-queue-put.txt" ] && bad "observe mode must not enqueue" || ok
[ -s "$H/state/blocked-resolver/tproj/tproj-TK-9.json" ] && bad "observe mode must not write state" || ok
grep -q 'WOULD' "$H/logs/blocked-resolver.log" && ok \
  || bad "observe mode must log WOULD lines (got: $(LOG))"
rm -f "$H/flags/blocked-resolver-observe"

# ============================================================================
# 6b. A live row in OBSERVE mode must also WOULD-hold and write nothing.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
ROW_ANSWER "claimed\t2026-09-19T10:00:00Z\tm1\t-\t-" 0
touch "$H/flags/blocked-resolver-observe"
RUN
[ -s "$T/closed.txt" ] && bad "observe+held must not close a PR" || ok
[ -s "$H/state/blocked-resolver/tproj/tproj-TK-9.json" ] && bad "observe+held must not write state" || ok
grep -q 'WOULD' "$H/logs/blocked-resolver.log" && ok \
  || bad "observe+held must log WOULD (got: $(LOG))"
rm -f "$H/flags/blocked-resolver-observe"

# ============================================================================
# 10. THE ROOT CAUSE, PINNED (BH-947 review B2). The pre-check cannot read the
#     queue (an outage, below the cap) so the rung goes ahead and enqueues — and
#     the WORKER answers `duplicate`. br_enqueue_fresh must answer rc 3: no rung
#     spent, no ledger row, a hold. Mutating that `return 3` back to `return 0`
#     (main's behaviour, the bug project-5 TK-1150 shipped) turns this red.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER duplicate
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
# Unreadable queue: the pre-check does NOT hold, so the enqueue answer is the
# only arbiter — the ticket's CLIENT_NO_ROW intent, with a reader present so the
# cap still reads the ledger.
ROW_ANSWER "" 2
RUN
grep -q 'REFUSED as duplicate' "$H/logs/blocked-resolver.log" && ok \
  || bad "a duplicate enqueue answer must be logged as REFUSED as duplicate (got: $(LOG))"
[ "$(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0')" = 0 ] && ok \
  || bad "a duplicate answer must spend no rebuild counter (got $(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0'))"
[ "$(STATEJSON tproj-TK-9 | jq -r '(.rebuild_jobs // []) | length')" = 0 ] && ok \
  || bad "a duplicate answer must add no ledger job (got $(STATEJSON tproj-TK-9 | jq -r '(.rebuild_jobs // []) | length'))"
# THE ONE EXTERNAL ATTEMPT IS RECORDED under the placeholder id (BH-947 review
# I2). This assertion read `= 0` when the case landed, which was wrong: a row
# whose last non-hold attempt is not `rebuild-fresh` is not polled by
# br_from_rebuilds at all, so the raced build's RESULT was never consumed and
# the next readable tick bought a second build on top of a finished one
# (case 12 drives exactly that). No counter and no ledger row is still the
# contract — the two assertions above this one — and the attempt is not one.
[ "$(STATEJSON tproj-TK-9 | jq -r '[.attempts[]? | select(.action == "rebuild-fresh")] | length')" = 1 ] && ok \
  || bad "a duplicate answer must record the one external rebuild-fresh attempt (got $(STATEJSON tproj-TK-9 | jq -r '[.attempts[]? | select(.action == "rebuild-fresh")] | length'))"
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].reason // ""')" = external-rebuild-wait ] && ok \
  || bad "the placeholder attempt must be the external-rebuild-wait one (got '$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].reason // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait_job // ""')" = "TK-9@duplicate-race" ] && ok \
  || bad "an unreadable re-probe must hold under the placeholder id (got '$(STATEJSON tproj-TK-9 | jq -r '.wait_job // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')" = REBUILD_WAIT ] && ok \
  || bad "a duplicate answer must hold (got '$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')')"
grep -q 'duplicate enqueue race — holding' "$H/logs/blocked-resolver.log" && ok \
  || bad "an unreadable queue behind a duplicate answer must hold with no job id (got: $(LOG))"
grep -q 'ABANDONED' "$H/logs/ALERTS.log" \
  && bad "a duplicate answer must not alert ABANDONED (got: $(ALERTS))" || ok

# ============================================================================
# 11. THE RACE THE rc-3 ARM EXISTS FOR (BH-947 review I3). The pre-check reads
#     no live row; a triage relaunch claims the key before our put lands; the
#     worker answers `duplicate`. The RE-PROBE has to name THAT job on THIS tick
#     and record the one external rebuild-fresh attempt — that attempt is what
#     lets br_from_rebuilds consume its RESULT instead of the next tick reading
#     `done`, finding the cap unspent and enqueueing on top of a finished build.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"
cat > "$H/bin/jobs-client.sh" <<'JOBS4'
#!/bin/bash
queue_row() {
  local store="$H/state/jobs-row-store-$1-$2"
  [ -s "$store" ] || return 2
  cat "$store"
}
queue_put() {
  printf '%s\n' "$*" >> "$H/state/jobs-queue-put.txt"
  # A triage relaunch claims the key between the pre-check and this put.
  printf '%b\n' "claimed\t2026-09-19T09:00:00Z\tm1\ttriage\t-" > "$H/state/jobs-row-store-$1-$2"
  printf 'duplicate\n'
}
queue_done() { return 0; }
queue_list() { return 1; }
JOBS4
chmod +x "$H/bin/jobs-client.sh"
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait_job // ""')" = "TK-9@2026-09-19T09:00:00Z" ] && ok \
  || bad "the re-probe must name the real job id (got '$(STATEJSON tproj-TK-9 | jq -r '.wait_job // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '[.attempts[]? | select(.action == "rebuild-fresh")] | length')" = 1 ] && ok \
  || bad "the racing external job must be recorded once on the same tick (got $(STATEJSON tproj-TK-9 | jq -r '[.attempts[]? | select(.action == "rebuild-fresh")] | length'))"
grep -q 'rebuild already in flight (job TK-9@2026-09-19T09:00:00Z' "$H/logs/blocked-resolver.log" && ok \
  || bad "the hold must name the racing job and not a placeholder (got: $(LOG))"
grep -q 'job id unknown' "$H/logs/blocked-resolver.log" \
  && bad "a readable re-probe must not fall back to the id-less hold (got: $(LOG))" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0')" = 0 ] && ok \
  || bad "a raced duplicate must spend no rebuild counter (got $(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0'))"

# ============================================================================
# 12. THE LEGACY COUNTER IS NOT FORGOTTEN (BH-947 review B1). A row parked
#     BEFORE the ledger landed carries `rebuilds: 2` and no `rebuild_jobs`. Its
#     first post-merge enqueue writes a ONE-entry ledger, and a cap that reads
#     the ledger alone would forget the two builds already bought: three more
#     Opus builds on a ladder of three, `rebuild 4 of 3` in the lane log, and an
#     ABANDONED alert that says "rebuilt fresh 3 times" against a counter of 5.
#     The cap is the LARGER of the two.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER queued
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
# Readable queue, nothing live: the rung reaches the cap check every tick.
ROW_ANSWER "" 0
jq -nc --arg at "$(ISO 3600)" --arg now "$(ISO 0)" \
  '{project:"tproj",rkey:"tproj-TK-9",mechanicals:0,fixrounds:0,rebuilds:2,outcome:"",
    attempts:[
      {at:$at,action:"rebuild-fresh",reason:"merge-failed-twice",detail:"fresh build enqueued (rebuild 1 of 3)"},
      {at:$at,action:"rebuild-fresh",reason:"merge-failed-twice",detail:"fresh build enqueued (rebuild 2 of 3)"}
    ],updated:$now}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
RUN
RUN
[ "$(grep -c . "$H/state/jobs-queue-put.txt" 2>/dev/null || echo 0)" = 1 ] && ok \
  || bad "a legacy rebuilds:2 row must buy exactly ONE more build (got $(grep -c . "$H/state/jobs-queue-put.txt" 2>/dev/null || echo 0) enqueues)"
[ "$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')" = ABANDONED ] && ok \
  || bad "the legacy counter must still end the ladder (outcome '$(STATEJSON tproj-TK-9 | jq -r '.outcome // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0')" = 3 ] && ok \
  || bad "the legacy counter must stop at the cap (got $(STATEJSON tproj-TK-9 | jq -r '.rebuilds // 0'))"
grep -q 'rebuild 3 of 3' "$H/logs/blocked-resolver.log" && ok \
  || bad "the one bought build must be logged as rebuild 3 of 3 (got: $(LOG))"
[ "$(grep -c 'rebuild 4 of 3' "$H/logs/blocked-resolver.log")" = 0 ] && ok \
  || bad "no build past the ladder may be logged (got: $(LOG))"
grep -q 'rebuilt fresh 3 times' "$H/logs/ALERTS.log" && ok \
  || bad "the ABANDONED alert must count the legacy builds too (got: $(ALERTS))"

# ============================================================================
# 13. AN EXTERNAL BUILD WHOSE RECORD NEVER REACHES THIS BOX (BH-947 review I1).
#     The queue-row fallback accepts a `done` row only when its enqueued_at is
#     at or after the rebuild attempt — right for a build this lane enqueued,
#     impossible for one it did not: br_rebuild_wait writes that attempt at
#     FIRST SIGHTING, always after the worker's own enqueue. So the build the
#     lane is holding for was never consumed, and the next tick closed the stale
#     PR and bought a build on top of one that had already produced a PR.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER queued
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
ROW_ANSWER "claimed\t2026-09-19T09:00:00Z\tm1\t-\texternal enqueue" 0
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait_job // ""')" = "TK-9@2026-09-19T09:00:00Z" ] && ok \
  || bad "the external hold must name the worker's stamp (got '$(STATEJSON tproj-TK-9 | jq -r '.wait_job // ""')')"
# The external build ends. NO builds/ record ever reaches this box — the ledger
# row bin/fly-pool.sh closes is the only evidence.
echo CLOSED > "$T/prstate"
printf 'o/tproj#9\tCLOSED\t%s\tabc123\tabc123\t-\tmerge-failed-twice\thttps://github.com/o/tproj/pull/9\n' \
  "$(date -u +%s)" > "$H/state/merge-conductor/pr-state.tsv"
ROW_ANSWER "done\t2026-09-19T09:00:00Z\tm1\t-\texternal enqueue" 0
LIST_ANSWER "tproj\tTS-9\t9\tdone\tfly\t0\tm1\t2026-09-19T09:00:00Z\tPR_CREATED https://github.com/o/tproj/pull/99\t-"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action // ""')" = rebuild-landed ] && ok \
  || bad "the external build's queue row must be consumed (got '$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')" = "-" ] && ok \
  || bad "consuming the external build must clear wait (got '$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')')"
[ "$(grep -c 'not consumed' "$H/logs/blocked-resolver.log")" = 0 ] && ok \
  || bad "the row the lane is waiting on must not be refused as too old (got: $(LOG))"
[ ! -s "$H/state/jobs-queue-put.txt" ] && ok \
  || bad "no build may be bought on top of the external one (got: $(cat "$H/state/jobs-queue-put.txt"))"

# ============================================================================
# 14. THE SAME, BEHIND THE DUP-RACE PLACEHOLDER (BH-947 review I2). The
#     re-probe could not read the row, so the hold is `<KEY>@duplicate-race`
#     and the attempt carries that id. When the raced build's `done` row
#     becomes readable it must be consumed against the placeholder, not read as
#     "older than this rebuild" and followed by a second enqueue.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER duplicate
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
ROW_ANSWER "" 2
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait_job // ""')" = "TK-9@duplicate-race" ] && ok \
  || bad "the unreadable re-probe must hold under the placeholder (got '$(STATEJSON tproj-TK-9 | jq -r '.wait_job // ""')')"
echo CLOSED > "$T/prstate"
printf 'o/tproj#9\tCLOSED\t%s\tabc123\tabc123\t-\tmerge-failed-twice\thttps://github.com/o/tproj/pull/9\n' \
  "$(date -u +%s)" > "$H/state/merge-conductor/pr-state.tsv"
ROW_ANSWER "done\t2026-09-19T08:00:00Z\tm1\ttriage\t-" 0
LIST_ANSWER "tproj\tTS-9\t9\tdone\tfly\t0\tm1\t2026-09-19T08:00:00Z\tPR_CREATED https://github.com/o/tproj/pull/99\t-"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action // ""')" = rebuild-landed ] && ok \
  || bad "the raced build's row must be consumed (got '$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action // ""')')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')" = "-" ] && ok \
  || bad "consuming the raced build must clear wait (got '$(STATEJSON tproj-TK-9 | jq -r '.wait // ""')')"
[ "$(grep -c . "$H/state/jobs-queue-put.txt" 2>/dev/null || echo 0)" = 1 ] && ok \
  || bad "no second enqueue may follow the raced build (got $(grep -c . "$H/state/jobs-queue-put.txt" 2>/dev/null || echo 0))"

# ============================================================================
# 15. A jq THAT COULD NOT ANSWER IS NOT "already recorded" (BH-947 review N1).
#     One earlier attempt with a non-string `detail` makes the dedupe filter
#     error out; the empty answer read as "already there" and the external
#     attempt — the one thing that lets br_from_rebuilds consume the build —
#     was never written.
# ============================================================================
CLEAN; touch "$H/flags/fly-pool-tproj"; JOBS_GENERIC; PUT_ANSWER queued
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
jq -nc --arg at "$(ISO 3600)" --arg now "$(ISO 0)" \
  '{project:"tproj",rkey:"tproj-TK-9",mechanicals:0,fixrounds:0,rebuilds:0,outcome:"",
    attempts:[{at:$at,action:"mechanical",reason:"merge-failed-twice",detail:5}],updated:$now}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
ROW_ANSWER "claimed\t2026-09-19T09:00:00Z\tm1\t-\texternal enqueue" 0
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r '[.attempts[]? | select(.action == "rebuild-fresh")] | length')" = 1 ] && ok \
  || bad "an unreadable dedupe must still record the external attempt (got $(STATEJSON tproj-TK-9 | jq -r '[.attempts[]? | select(.action == "rebuild-fresh")] | length'))"

# ============================================================================
# 16. NO CODE OR DOC MAY CLAIM A MARKER NOTHING WRITES (BH-947 review I3).
#     BH-1122 removed the `.enqueue-alerted` page and its write; the landed
#     path kept the `rm -f` and the map page kept describing it.
# ============================================================================
grep -q 'enqueue-alerted' "$DIR/bin/blocked-resolver.sh" \
  && bad "bin/blocked-resolver.sh still touches the .enqueue-alerted marker nothing writes" || ok
grep -q 'enqueue-alerted' "$DIR/docs/verification-map/rebuild-wait.md" \
  && bad "docs/verification-map/rebuild-wait.md still describes the .enqueue-alerted marker" || ok

echo "blocked-resolver.bh-947-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
