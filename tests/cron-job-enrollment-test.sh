#!/bin/bash
# tests/cron-job-enrollment-test.sh — the hub/box crons enroll in the jobs
# ledger, and the ledger can never be the reason one of them does less work.
#
# WHAT PHASE 4 ADDED AND THEREFORE WHAT THIS PINS. bin/merge-sweep.sh,
# bin/review-prs.sh and bin/rule-miner.sh now claim a coordination row, beat it
# while they work, and close it with a real rc. Three properties decide whether
# that is machinery or decoration, and all three are claims about behaviour
# under failure, so all three are DRIVEN here rather than grepped:
#
#   1. LAZY CLAIM. These crons do nothing on most ticks — merge-sweep fires
#      every ten minutes, review-prs twice an hour per project. A row per tick
#      would be hundreds of empty rows a day for the console to list and the
#      orphan watchdog to age. An idle tick must claim NOTHING.
#   2. FAIL OPEN. Worker down, secret unset, client missing: the merge still
#      merges, the review still reviews. A ledger that can stop the fleet is
#      worse than no ledger — it is the failure class this whole layer exists
#      to remove, reintroduced by the fix.
#   3. THE FILE IS STILL THE FLAG. flag_active reconciles a pause from its DB
#      row and then tests the FILE, so a 404 ("no such row") is NOT "unpause"
#      and an outage leaves the box deciding exactly as it does today.
#
# Run from anywhere: tests/cron-job-enrollment-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
BASE="$T"

# ---------------------------------------------------------------------------
# A scratch $HARNESS per run, plus a curl that records every request and
# answers per CURL_MODE. `flags404` is its own mode because "no row for this
# flag" is a REAL answer the client must map to "nothing to reconcile" — the
# same status a broken worker would return for everything, and the difference
# between the two decides whether a paused board silently resumes.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
new_harness() { # new_harness -> prints a fresh $HARNESS
  local T; T=$(mktemp -d "$BASE/h-XXXXXX")
  mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/bin/lib" "$T/fakebin" "$T/env" "$T/builds"
  . "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" || exit 1  # BH-1510.2: lanes read models from model_routes
  cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
  mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
  # THE SWEEP'S DECISION READS ARE REST (BH-784), so the lib and the contract it
  # reads through ride into the scratch harness. Without them the sweep's
  # fail-closed shims answer "unverifiable" to every read and it never reaches a
  # merge — which would make this suite's ledger assertions pass or fail on the
  # absence of a library instead of on the ledger, the one thing it is about.
  cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-pr-list.sh" "$T/bin/lib/"
  mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
  cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
  : > "$T/env/global.env"
  # BH-1510.1: review-prs's model is a model_routes row, read through review_model.
  # This worker stub answers /api/model-routes/* with a 404 (below) — the
  # resolver's "worker unreachable" — so the lane serves the box cache of #1507's
  # table, exactly as a real box whose worker is down would.
  cp "$DIR/bin/lib/review-model.sh" "$T/bin/lib/"
  mrs_fixture "$T" project-3
  cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  flagon) case "$URL" in
            */api/model-routes/*) printf '{"error":"not found"}\n404\n' ;;
            # TEST-CHANGE BH-4153: the row names the flag that was asked for (the
            # worker always does); a row for another name is unreadable, which a
            # stop switch would read as ON for the wrong reason.
            */api/flags/*) n="${URL##*/api/flags/}"; n="${n%%\?*}"
                           printf '{"flag":{"name":"%s","active":1,"updated_at":"2026-08-28T00:00:00Z"}}\n200\n' "$n" ;;
            */api/jobs) printf '{"job":{"id":"job-1"}}\n201\n' ;;
            *) printf '{"ok":1}\n200\n' ;;
          esac ;;
  *) case "$URL" in
       */api/model-routes/*) printf '{"error":"not found"}\n404\n' ;;
       */api/flags/*) printf '{"error":"not found"}\n404\n' ;;   # no row = nothing to reconcile
       */api/jobs)    printf '{"job":{"id":"job-1"}}\n201\n' ;;
       *)             printf '{"ok":1}\n200\n' ;;
     esac ;;
esac
EOF
  chmod +x "$T/fakebin/curl"
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/deploy-request.sh"; chmod +x "$T/bin/deploy-request.sh"
  printf '%s' "$T"
}
# NO `|| echo 0`: grep -c already PRINTS 0 when it matches nothing and exits 1,
# so the fallback appends a SECOND zero and every comparison against it fails
# with the unreadable "0\n0". The empty case that actually needs a default is a
# request log that was never written at all.
claims() {
  local f="$1/req.txt"
  [ -f "$f" ] || { echo 0; return 0; }
  grep -c 'POST .*/api/jobs ' "$f"
}

# ===========================================================================
# merge-sweep.sh
# ===========================================================================
seed_sweep() { # seed_sweep <harness> <merge-rc>
  local T="$1" mrc="$2"
  mkdir -p "$T/builds/rec-1"
  echo "PR_CREATED https://github.com/example-org/project-3/pull/9" > "$T/builds/rec-1/RESULT"
  printf 'summary\nTIER: 2\nVERDICT: APPROVE\n' > "$T/builds/rec-1/review.md"
  # The conductor lib rides along: the sweep's PR-state reads go
  # through its mc_pr_view (gh_rest, BH-783/784), so this fixture drives the reader production uses
  # instead of the no-lib stub that answers "could not read" to everything.
  mkdir -p "$T/bin/lib"; cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/bin/lib/"
  # BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh
  # and exits on a missing module — a fixture that copies it carries them too.
  mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
  : > "$T/merge-calls.txt"
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none" from a real read (not a fallback on an unreadable probe).
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
case "\$*" in
  # The sweep re-reads the PR after the merge call (gh's exit code is not a
  # landing — on a merge-queue repo it only enqueues), so the stub answers what
  # GitHub would: MERGED when this fixture's merge succeeded, OPEN when it did not.
  *"--json state,isInMergeQueue"*) [ "$mrc" = 0 ] && echo "MERGED false" || echo "OPEN false" ;;
  *"pr view"*state,mergeStateStatus,author*) echo "OPEN CLEAN operator" ;;
  # The state is now read on its own, and "is it queued" is asked of the queue
  # PROVIDER (this repo has none), because isInMergeQueue is GitHub's queue only.
  *"pr view"*"--json state -q .state"*) [ "$mrc" = 0 ] && echo MERGED || echo OPEN ;;
  # THE SAME FACTS OVER REST (BH-784). The sweep's state read is
  # \`gh api -i -X GET repos/<slug>/pulls/<n>\` judged on the HTTP status line,
  # so the stub prints a whole response through restpr: OPEN before the merge
  # call, MERGED after it when this fixture's merge succeeds. The diff shares
  # the pulls path and is told apart by its Accept header, so it matches first.
  *"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/example-org/project-3/pulls/9"*)
    if [ -f "$T/merged" ]; then restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator; fi ;;
  *"pr diff"*)  : ;;
  *"pr merge"*) echo merged; [ "$mrc" = 0 ] && touch "$T/merged"; exit $mrc ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
}
run_sweep() { # run_sweep <harness> <curl-mode> [extra-env...]
  local T="$1" mode="$2"; shift 2
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_BEAT_SECS=3600 \
           CURL_MODE="$mode" REQ_SINK="$T/req.txt"
    "$@" bash "$DIR/bin/merge-sweep.sh" >/dev/null 2>&1 )
  echo $?
}

# --- 1. an idle tick claims NOTHING -----------------------------------------
T=$(new_harness); printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
RC=$(run_sweep "$T" ok)
[ "$RC" = 0 ] && ok || bad "an idle merge-sweep must exit 0, got $RC"
[ "$(claims "$T")" = 0 ] \
  && ok || bad "an idle merge-sweep opened a job row — 144 empty rows a day is noise the watchdog has to age"

# --- 2. a real merge claims, beats, and closes done -------------------------
T=$(new_harness); seed_sweep "$T" 0
RC=$(run_sweep "$T" ok)
[ "$RC" = 0 ] && ok || bad "merge-sweep exited $RC on a clean merge"
grep -q 'MERGED https://github.com/example-org/project-3/pull/9' "$T/logs/merge-sweep.log" \
  && ok || bad "the sweep did not actually merge: $(cat "$T/logs/merge-sweep.log" 2>/dev/null)"
[ "$(claims "$T")" = 1 ] && ok || bad "a real merge must open exactly one row, got $(claims "$T")"
C=$(grep -m1 'POST .*/api/jobs ' "$T/req.txt" | sed -E 's|^POST [^ ]+ ||')
[ "$(jq -r .kind    <<<"$C")" = merge ] && ok || bad "the sweep's row must be kind=merge, got: $C"
[ "$(jq -r .project <<<"$C")" = fleet ] && ok || bad "the sweep is fleet-wide, not one project's, got: $C"
grep -q '/heartbeat' "$T/req.txt" && ok || bad "the sweep's row never beat"
grep -q 'PATCH .*"status":"done"' "$T/req.txt" \
  && ok || bad "a successful sweep must close status=done: $(grep PATCH "$T/req.txt")"

# --- 3. a merge that FAILED closes the row failed, and still exits 0 ---------
# The PROCESS rc is unchanged on purpose — nothing reads a cron's exit code, and
# a merge that failed is recorded where it can be seen instead.
T=$(new_harness); seed_sweep "$T" 1
RC=$(run_sweep "$T" ok)
[ "$RC" = 0 ] && ok || bad "merge-sweep must keep exiting 0 for cron, got $RC"
grep -q 'PATCH .*"status":"failed"' "$T/req.txt" \
  && ok || bad "a failed merge must close the row failed: $(grep PATCH "$T/req.txt")"
grep -q '"verdict":"FAILED"' "$T/req.txt" \
  && ok || bad "a failed merge must leave a FAILED stage event"

# --- 4. FAIL OPEN: the worker being down must not cost a merge --------------
# TEST-CHANGE BH-4153: automerge-disabled is a harness_flags row; with the worker
# down and NOTHING cached it is unknown, which a stop switch reads as ON (fails
# closed, plan Decision 7). The ledger must still not be a gate, so the box here
# has read its switch once (a cached "off"), the state of any live box; the
# fail-closed half is pinned right after.
T=$(new_harness); seed_sweep "$T" 0
mkdir -p "$T/state/flags-cache/fleet"
printf '%s\n' '{"on":false,"value":null,"set_at":null,"cleared_at":null,"src":"db","stamp":1700000000}' \
  > "$T/state/flags-cache/fleet/automerge-disabled"
RC=$(run_sweep "$T" down)
[ "$RC" = 0 ] && ok || bad "merge-sweep exited $RC with the worker down"
grep -q 'MERGED ' "$T/logs/merge-sweep.log" \
  && ok || bad "the worker being unreachable stopped a merge — the ledger became a gate"
T=$(new_harness); seed_sweep "$T" 0
RC=$(run_sweep "$T" down)
[ "$RC" = 0 ] && ok || bad "merge-sweep exited $RC with the worker down and nothing cached"
grep -q 'MERGED ' "$T/logs/merge-sweep.log" 2>/dev/null \
  && bad "worker down and automerge-disabled never read: the stop switch must fail closed (BH-4153)" || ok
# ...and with no client on the box at all.
T=$(new_harness); seed_sweep "$T" 0; rm -f "$T/bin/jobs-client.sh"
RC=$(run_sweep "$T" ok)
grep -q 'MERGED ' "$T/logs/merge-sweep.log" \
  && ok || bad "with bin/jobs-client.sh absent the sweep stopped merging (rc=$RC)"

# --- 5. the pause flag: 404 is NOT "unpause", a live row IS a pause ---------
T=$(new_harness); seed_sweep "$T" 0
run_sweep "$T" ok >/dev/null            # 404 on the flag row
grep -q 'MERGED ' "$T/logs/merge-sweep.log" \
  && ok || bad "a 404 on the pause flag read as PAUSED — no row means nothing to reconcile, not stop"
T=$(new_harness); seed_sweep "$T" 0
run_sweep "$T" flagon >/dev/null        # the DB says paused
grep -q 'MERGED ' "$T/logs/merge-sweep.log" 2>/dev/null \
  && bad "a console pause (active flag row) did not reach merge-sweep — it merged anyway" || ok
# TEST-CHANGE BH-4153: automerge-disabled is a harness_flags row read DB-first;
# no flags/ file is reconciled any more. The row's answer is the cached ON.
[ ! -e "$T/flags/automerge-disabled" ] \
  && ok || bad "a ported flag must not be written as flags/automerge-disabled (BH-4153)"
jq -e '.on == true' "$T/state/flags-cache/fleet/automerge-disabled" >/dev/null 2>&1 \
  && ok || bad "the active row must be cached ON in state/flags-cache/fleet/automerge-disabled"
# The local file alone still pauses it, worker or no worker.
T=$(new_harness); seed_sweep "$T" 0; touch "$T/flags/automerge-disabled"
run_sweep "$T" down >/dev/null
grep -q 'MERGED ' "$T/logs/merge-sweep.log" 2>/dev/null \
  && bad "the local kill-switch file stopped working when the worker was down" || ok

# ===========================================================================
# review-prs.sh
# ===========================================================================
seed_review() { # seed_review <harness> <verdict-line>
  local T="$1" verdict="$2"
  : > "$T/env/project-3.env"
  echo '{}' > "$T/state/project-3.pr-reviews.json"
  cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none" from a real read (not a fallback on an unreadable probe).
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
case "$*" in
  *"pr list"*)  printf '41\tdeadbee\toutsider\tAdd a thing\n' ;;
  *"pr diff"*)  echo "+++ b/x.ts"; echo "+const a = 1;" ;;
  *"pr view"*comments,reviews*) echo "--- outsider:" ;;
  *"pr view"*body*) echo "does a thing" ;;
  *"pr view"*state*) echo MERGED ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
  # agent-call.sh's 5th argument is the output file the reviewer writes into.
  cat > "$T/bin/agent-call.sh" <<EOF
#!/bin/bash
echo "called \$1 \$2" >> "\$AGENT_SINK"
printf 'looks fine\nTIER: 1\n$verdict\n' > "\$5"
echo claude > "\$5.runner"
exit 0
EOF
  chmod +x "$T/bin/agent-call.sh"
}
run_review() { # run_review <harness> <curl-mode>
  local T="$1" mode="$2"
  : > "$T/req.txt"; : > "$T/agent.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_BEAT_SECS=3600 \
           CURL_MODE="$mode" REQ_SINK="$T/req.txt" AGENT_SINK="$T/agent.txt"
    bash "$DIR/bin/review-prs.sh" project-3 >/dev/null 2>&1 )
  echo $?
}

# --- 6. nothing to review claims nothing ------------------------------------
T=$(new_harness); seed_review "$T" "VERDICT: APPROVE"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"   # no open PRs
RC=$(run_review "$T" ok)
[ "$(claims "$T")" = 0 ] \
  && ok || bad "a review-prs tick with no PRs opened a row — ~380 empty rows a day across the fleet"

# --- 7. a real review claims on the LANE, beats, and closes -----------------
T=$(new_harness); seed_review "$T" "VERDICT: APPROVE"
RC=$(run_review "$T" ok)
[ "$RC" = 0 ] && ok || bad "review-prs exited $RC"
[ -s "$T/agent.txt" ] && ok || bad "the reviewer was never called"
[ "$(claims "$T")" = 1 ] && ok || bad "a real review must open exactly one row, got $(claims "$T")"
C=$(grep -m1 'POST .*/api/jobs ' "$T/req.txt" | sed -E 's|^POST [^ ]+ ||')
[ "$(jq -r .lane <<<"$C")" = review/project-3/claude ] \
  && ok || bad "the row's lane must be the catalog key for this workload, got: $C"
grep -q '/heartbeat' "$T/req.txt" && ok || bad "the review row never beat"
grep -q 'PATCH .*"status":"done"' "$T/req.txt" && ok || bad "the review row was never closed"
grep -q '"verdict":"APPROVE"' "$T/req.txt" \
  && ok || bad "the PR's verdict must land as a stage event on the row"

# JOB_ID has to be EXPORTED, or bin/agent-call.sh cannot attribute this lane's
# dollars to the row and the spend half of the lifecycle is silently missing.
# BH-1194: the client is a shim over bin/lib/jobs/, so the read is over the shim
# AND its modules — the assertion is the same, the text just lives in jobs.sh.
grep -rq 'export JOB_ID' "$DIR/bin/jobs-client.sh" "$DIR/bin/lib/jobs" \
  && ok || bad "job_lane_open must export JOB_ID — agent-call.sh reads it from the environment"

# --- 8. the worker down: the lane still RUNS, but a PAID review is HELD -------
# TEST-CHANGE (BH-2315): this case pinned "the review still happens with the
# worker down". That fail-open is the $328/day class: with the D1 verdict ledger
# unreadable, nobody can tell a head already paid for from a new one, so
# review-prs now holds the paid call (no agent-call) and still exits 0; the
# next tick asks again. The lane itself is not stopped by the ledger — it runs,
# claims nothing it cannot, and says so.
T=$(new_harness); seed_review "$T" "VERDICT: APPROVE"
RC=$(run_review "$T" down)
[ "$RC" = 0 ] && [ ! -s "$T/agent.txt" ] \
  && ok || bad "with the worker down review-prs must exit 0 and HOLD the paid review (rc=$RC, agent calls: $(wc -l < "$T/agent.txt" 2>/dev/null))"
grep -q 'D1 verdict ledger could not be read' "$T/logs/pr-reviews.log" 2>/dev/null \
  && ok || bad "the held review must say why in pr-reviews.log"

# --- 9. a no-verdict review closes the row FAILED ---------------------------
# The evidence-keeping path: an unparseable review is a bug, and the row is
# where a bug that happened at 3am is still visible at 9am.
T=$(new_harness); seed_review "$T" "nothing parseable here"
RC=$(run_review "$T" ok)
grep -q '"verdict":"NO_VERDICT"' "$T/req.txt" \
  && ok || bad "a review with no verdict must leave a NO_VERDICT event"
grep -q 'PATCH .*"status":"failed"' "$T/req.txt" \
  && ok || bad "a run whose only review produced no verdict must close failed"

# ===========================================================================
# rule-miner.sh — the weekly lane
# ===========================================================================
run_miner() { # run_miner <harness> <curl-mode>
  local T="$1" mode="$2"
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_BEAT_SECS=3600 \
           CURL_MODE="$mode" REQ_SINK="$T/req.txt"
    bash "$DIR/bin/rule-miner.sh" >/dev/null 2>&1 )
  echo $?
}

# --- 10. a week with no incidents claims nothing ----------------------------
T=$(new_harness); printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
RC=$(run_miner "$T" ok)
[ "$(claims "$T")" = 0 ] \
  && ok || bad "a zero-incident week opened a row — a rule is only ever mined from a real incident"

# --- 11. incidents claim the lane before anything expensive starts ----------
# The clone is stubbed to fail, so the run aborts immediately AFTER the claim.
# That is deliberately the harshest shape for the lifecycle: an early abort is
# exactly when a row gets opened and never closed.
T=$(new_harness)
mkdir -p "$T/state/rule-mining/manual"
printf 'a hand-filed lesson\n' > "$T/state/rule-mining/manual/lesson.md"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
RC=$(run_miner "$T" ok)
[ "$(claims "$T")" = 1 ] && ok || bad "an incident week must claim the lane, got $(claims "$T") row(s)"
C=$(grep -m1 'POST .*/api/jobs ' "$T/req.txt" | sed -E 's|^POST [^ ]+ ||')
[ "$(jq -r .lane <<<"$C")" = mine/rule-miner/claude ] \
  && ok || bad "rule-miner's lane must be its catalog key, got: $C"
[ "$(jq -r .kind <<<"$C")" = mine ] && ok || bad "rule-miner's row is kind=mine, got: $C"
grep -q 'PATCH .*"status":"failed"' "$T/req.txt" \
  && ok || bad "a run that aborted after claiming must still CLOSE its row — an open row nothing closes is the orphan this layer invents"

# --- 12. the dry run spends nothing and claims nothing ----------------------
T=$(new_harness)
mkdir -p "$T/state/rule-mining/manual"
printf 'a hand-filed lesson\n' > "$T/state/rule-mining/manual/lesson.md"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
: > "$T/req.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
         JOBS_URL=https://jobs.invalid CURL_MODE=ok REQ_SINK="$T/req.txt" RULE_MINER_DRY=1
  bash "$DIR/bin/rule-miner.sh" >/dev/null 2>&1 )
[ "$(claims "$T")" = 0 ] \
  && ok || bad "RULE_MINER_DRY=1 claimed a row — an operator reading the inventory is not a run to page about"

# --- 13. the pause flag reaches the weekly lane too -------------------------
T=$(new_harness)
mkdir -p "$T/state/rule-mining/manual"
printf 'a hand-filed lesson\n' > "$T/state/rule-mining/manual/lesson.md"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
RC=$(run_miner "$T" flagon)
# BH-2412: the no-row step reads the pause_flags row read-only, so the pause
# stops the lane without flag_active's reconcile creating flags/rule-miner-disabled.
[ "$(claims "$T")" = 0 ] && ok || bad "a console pause did not stop rule-miner (claims=$(claims "$T"))"
[ ! -e "$T/flags/rule-miner-disabled" ] && ok || bad "a console pause wrote flags/rule-miner-disabled (the no-row read is read-only since BH-2412)"

# --- 14. NO SECRETS anywhere the wrapping writes ----------------------------
# Every one of these lanes now handles HARNESS_SECRET where it did not before.
T=$(new_harness); seed_sweep "$T" 0
run_sweep "$T" ok >/dev/null
grep -rq test-secret "$T/logs" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into a log written by the wrapped crons" || ok

echo "cron-job-enrollment-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
