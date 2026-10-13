#!/bin/bash
# tests/hotfix-conductor-degraded-test.sh — in DEGRADED mode (the Mergify
# queue acknowledging nothing) the `hotfix` PR is ASKED of the queue FIRST
# (BH-369, hotfix lane 2/3), and since BH-2199 nothing — the hotfix included —
# is merged directly around the queue.
#
# THE CASE THIS PINS. Mergify's queue does the ordering when it is answering.
# When it is NOT — the Merge Queue product off, the label write refused, the app
# uninstalled — the conductor bypasses the queue and merges directly, and in
# that mode NOTHING orders the merges: the PRs land in the order GitHub happened
# to list them. An emergency behind four ordinary PRs then waits for four merges
# and four deploys, in the one mode where speed is the whole point.
#
# So the tick reads the `hotfix` label off the PR list BEFORE it starts any
# worker, launches those PRs first, and — because a worker is a background
# subshell and launch order is not merge order — records them in a per-tick
# marker that a plain PR checks before its own degraded merge. A plain PR that
# finds one waits for the NEXT tick (five minutes) rather than for the hotfix
# worker: this harness never blocks on another task's lifetime (the operator,
# 2026-09-13), so the marker is read once and never waited on.
#
# WHAT IS ASSERTED IS THE ORDER OF THE REAL `gh pr merge` CALLS, the real
# ALERTS.log lines and the real rows — the whole script runs against a scratch
# $HARNESS with a fake gh, exactly like tests/merge-queue-mergify-test.sh (which
# owns the rest of the Mergify provider contract and is not edited here).
#
# MC_PR_PARALLEL=1 in most sections is not a convenience: it makes the tick
# fork one worker at a time, so "42 merged before 41" is a fact about the
# ordering and not about a race between three background subshells.
#
# Run from anywhere: tests/hotfix-conductor-degraded-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh): every fixture
# timestamp below is derived from it.
NOW=$(date -u +%s)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
# gh-rest.sh rides with the conductor lib: since BH-784 every decision read in
# the lib goes through it, and a tree without it keeps the fail-closed shims —
# which answer "unverifiable" to everything, so this suite would be green on a
# conductor that never read a PR.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/hotfix-lib.sh" \
   "$DIR/bin/lib/queue-batch-only.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"
# The stub `gh` below answers `gh api -i -X …` with a REAL HTTP response: the
# contract judges the STATUS LINE, not gh's exit code, so an `echo` of JSON
# reads as "no status line" = UNVERIFIABLE. tests/lib/rest-emit.sh is the
# shared emitter and owns the exact REST shapes (MERGED is state "closed" WITH
# merged_at set, which is what must not be confused with CLOSED).
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# CONDUCTOR=<file> drives a DIFFERENT copy of the script — that is how the
# red-first proof is re-run against main:
#   git show main:bin/merge-conductor.sh > /tmp/mc-main.sh
#   CONDUCTOR=/tmp/mc-main.sh bash tests/hotfix-conductor-degraded-test.sh
cp "${CONDUCTOR:-$DIR/bin/merge-conductor.sh}" "$T/h/bin/merge-conductor.sh"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
# flock is NOT stubbed here, unlike the single-PR fixtures next door: this suite
# runs three workers of one project at once, and the row file, the tick counters
# and the hotfix marker are all read-modify-write under a real flock in
# production. A no-op flock would let one worker's row rewrite drop another's —
# a race invented by the fixture, in the one suite whose subject is concurrency.
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/deployreq.txt"\nexit 0\n' "$T" > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/pre-arm-guards.sh"; chmod +x "$T/h/bin/pre-arm-guards.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"
MSHA=cccccccc3333
head_of() { printf 'aaaaaaaa00%s' "$1"; }

# Three build records: 41, 42, 43, each APPROVE bound to its own head.
for N in 41 42 43; do
  REC="$T/h/builds/pool-mgfy-MG-$N-2026091700$N"
  mkdir -p "$REC"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$N" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  head_of "$N" > "$REC/reviewed-sha"
  : > "$REC/pipeline.log"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: hotfix\n  - name: default\n' | base64 | tr -d '\n')
# Section 7 swaps the repo's .mergify.yml for a batch-only one; the stub reads
# whatever this file holds at call time.
printf '%s' "$MGFY_YML" > "$T/mgfy.b64"

# ---------------------------------------------------------------------------
# 0. The predicates (bin/lib/hotfix-lib.sh)
# ---------------------------------------------------------------------------
# The label match gates merge ORDER and defers other PRs' merges, so the
# adversarial names carry the weight: `hotfix-candidate` is somebody ASKING,
# `not-hotfix` is somebody saying no, and either one reading as an emergency
# holds up every other PR on the repo for a tick.
# shellcheck source=/dev/null
. "$T/h/bin/lib/hotfix-lib.sh"
csv_yes() { hotfix_labels_csv_has "$1" "$T/h" && ok || bad "0: labels CSV '$1' must read as a hotfix"; }
csv_no()  { hotfix_labels_csv_has "$1" "$T/h" && bad "0: labels CSV '$1' must NOT read as a hotfix" || ok; }
csv_yes "hotfix"
csv_yes " Hotfix "
csv_yes "merge-queue,hotfix"
csv_yes "HOTFIX,queued"
csv_no  "hotfix-candidate"
csv_no  "not-hotfix"
csv_no  "hotfixes"
csv_no  "pre-hotfix"
csv_no  "merge-queue,queued"
csv_no  "-"
csv_no  ""
touch "$T/h/flags/hotfix-lane-off"
csv_no "hotfix"
hotfix_pr_is "hotfix" "" "$T/h" && bad "0: the kill switch must make hotfix_pr_is answer no" || ok
rm -f "$T/h/flags/hotfix-lane-off"
# hotfix_pr_is: the PR label first, the build record's ticket-meta.json second.
MREC="$T/h/builds/pool-mgfy-MG-99-202609170099"; mkdir -p "$MREC"
printf '{"labels":[{"name":"hotfix"}]}\n' > "$MREC/ticket-meta.json"
hotfix_pr_is "hotfix" "" "$T/h"        && ok || bad "0: hotfix_pr_is must answer yes on the PR label alone"
hotfix_pr_is "-" "$MREC" "$T/h"        && ok || bad "0: hotfix_pr_is must fall back to the record's ticket-meta.json"
hotfix_pr_is "not-hotfix" "" "$T/h"    && bad "0: hotfix_pr_is must answer no for not-hotfix with no record" || ok
hotfix_pr_is "-" "$T/h/builds/nope" "$T/h" && bad "0: an absent record is not a hotfix" || ok
scratch_rm "$MREC"

# ---------------------------------------------------------------------------
# The fixture repo: three READY PRs, a queue that answers nothing
# ---------------------------------------------------------------------------
for N in 41 42 43; do echo open > "$T/prstate-$N"; : > "$T/labels-$N"; done
echo none > "$T/checkmode"

labels_csv() { tr '\n' ',' < "$T/labels-$1" 2>/dev/null | sed 's/,$//'; }
open_list() { # open_list [<num>...] — the open list, minus whatever has merged
  local ns="${*:-41 42 43}" n out="" lbl csv
  for n in $ns; do
    # A merged PR is gone from `gh pr list --state open`, which is what makes a
    # second tick see only what is left.
    [ "$(cat "$T/prstate-$n" 2>/dev/null)" = open ] || continue
    csv=$(labels_csv "$n"); lbl="[]"
    [ -n "$csv" ] && lbl=$(printf '%s' "$csv" | jq -R 'split(",")|map({name:.})' -c)
    out="$out{\"number\":$n,\"url\":\"https://github.com/example-org/mgfy-os/pull/$n\",\"headRefOid\":\"$(head_of "$n")\",\"headRefName\":\"ticket/mg-$n\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"isInMergeQueue\":false,\"labels\":$lbl},"
  done
  printf '[%s]\n' "${out%,}" > "$T/list.json"
}

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
CHECK=\$(cat "$T/checkmode" 2>/dev/null || echo none)
N=\$(printf '%s' "\$*" | sed -nE 's#.*(/pull/|/pulls/|/issues/)([0-9]+).*#\2#p' | head -1)
[ -n "\$N" ] || N=41
PRSTATE=\$(cat "$T/prstate-\$N" 2>/dev/null || echo open)
HEAD=aaaaaaaa00\$N
LBL=\$(tr '\n' ',' < "$T/labels-\$N" 2>/dev/null | sed 's/,\$//')
case "\$*" in
  # bin/lib/gh-budget.sh caches this read; an EMPTY answer leaves a 0-byte cache
  # file and a later run in this scratch tree dies silently mid-tick.
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  # BH-1586: the provider probes are gh_rest reads in the real REST shapes.
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"\$(cat "$T/mgfy.b64")\"}" ;;
  # The Mergify check-runs read is a REST decision read on the contract now
  # (BH-784): "no check on this head" is what becomes an ejection, so it has to
  # come back as a real answer with a status line. Same facts as the old arm.
  *"api -i -X GET repos/"*"/check-runs"*)
    case "\$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      failed)  restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*)
    printf '%s\n' "\$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-\$N"; sort -u -o "$T/labels-\$N" "$T/labels-\$N"
    # A queue that IS answering marks the PR with its own label ~2s later.
    [ "\$CHECK" = running ] && { printf 'queued\n' >> "$T/labels-\$N"; sort -u -o "$T/labels-\$N" "$T/labels-\$N"; } ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/merge-queue"*)
    printf '%s\n' "\$*" >> "$T/label-removes.txt"
    grep -vxF 'merge-queue' "$T/labels-\$N" > "$T/labels-\$N.tmp" 2>/dev/null; mv -f "$T/labels-\$N.tmp" "$T/labels-\$N" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; echo merged > "$T/prstate-\$N"; exit 0 ;;
  # --- The REST decision reads (BH-784) ------------------------------------
  # The six \`gh pr view --json …\` arms this stub used to carry are ONE
  # \`gh api -i -X GET repos/<slug>/pulls/<n>\`: state, head sha, head ref, base,
  # labels and author all ride on the same object, normalised by the lib. The
  # diff shares that path under the v3.diff media type, so it is matched FIRST.
  *v3.diff*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  # BH-1586: the hotfix proof's PR-files read is the paged gh_rest reader; no
  # added files, which is the answer the old raw read's empty echo gave. It
  # shares the pulls path, so it is matched before the pull object.
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    case "\$PRSTATE" in
      merged) restpr MERGED "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator "$MSHA" ;;
      closed) restpr CLOSED "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator ;;
      *)      restpr OPEN   "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator ;;
    esac ;;
  # mc_stack_parent's \`head=owner:branch\` list read. No parent here, and rc 0
  # with an EMPTY list is a real "no PR" under the contract, not an unknown.
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  # The issue close-out: read, comment, close, re-read. gh_rest_close answers 0
  # only when a FRESH read says closed, so the PATCH has to actually move the
  # state this stub reports.
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; : > "$T/issue-closed-\$N"
    restpr --raw 200 '{"state":"closed","number":'"\$N"'}' ;;
  *"api -i -X GET repos/"*"/issues/"*)
    IST=open; [ -f "$T/issue-closed-\$N" ] && IST=closed
    restpr --raw 200 '{"state":"'"\$IST"'","number":'"\$N"'}' ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

ROWS="$T/h/state/merge-conductor/pr-state.tsv"
CLOG="$T/h/logs/merge-conductor.log"
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS" 2>/dev/null; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
# The merge SEQUENCE is the line number of that PR's `gh pr merge` call: the
# stub appends one line per call, so line order IS call order.
merge_seq() { grep -n -- "/pull/$1 " "$T/merge-calls.txt" 2>/dev/null | head -1 | cut -d: -f1; }
reset_fixture() { # reset_fixture <labels-for-42>
  rm -rf "$T/h/state/merge-conductor" "$T/h/state/hotfix-announced" "$T/h/state/merge-sweep-done.txt"
  rm -f "$T/h/tmp"/*.provider "$T/h/tmp"/*.probe 2>/dev/null
  rm -f "$T"/issue-closed-* 2>/dev/null
  for N in 41 42 43; do echo open > "$T/prstate-$N"; : > "$T/labels-$N"; done
  [ -n "${1:-}" ] && printf '%s\n' "$1" > "$T/labels-42"
  for f in gh-calls.txt merge-calls.txt issue-calls.txt deployreq.txt label-adds.txt \
           label-removes.txt queue-cmds.txt beats.txt; do : > "$T/$f"; done
  : > "$T/h/logs/ALERTS.log"; : > "$CLOG"
  echo none > "$T/checkmode"
  open_list
}
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# TEST-CHANGE (BH-2199). Sections 1-5 used to assert the ORDER of degraded
# DIRECT merges (`gh pr merge` call order, MERGED rows, a "HOTFIX merged"
# alert, plain PRs DEFERRED behind the hotfix). BH-2199 removes the degraded
# direct merge on a queue_rules repo: a silent queue HOLDS every READY PR,
# hotfix included, and a direct merge there is a lead action. So the same
# fixtures now pin what is left of the hotfix lane in this mode — the hotfix is
# still ASKED of the queue first (label-add order), nothing merges around the
# queue, and the hold is said once — and the negatives keep their meaning on
# the ask order. Section 6 (a queue that answers) is unchanged.
ask_seq() { grep -n -- "issues/$1/labels" "$T/label-adds.txt" 2>/dev/null | head -1 | cut -d: -f1; }

# ---------------------------------------------------------------------------
# 1. The hotfix is ASKED first, and nothing merges around the queue
# ---------------------------------------------------------------------------
reset_fixture hotfix
MC_PR_PARALLEL=1 run_tick
[ "$(ask_seq 42)" = 1 ] && ok || bad "1a: the hotfix PR 42 must be the FIRST queue ask of the tick (asks: $(cat "$T/label-adds.txt"))"
S42=$(ask_seq 42); S41=$(ask_seq 41); S43=$(ask_seq 43)
[ -n "$S41" ] && [ -n "$S42" ] && [ "$S42" -lt "$S41" ] && ok || bad "1b: 42 must be asked before 41 (seq 42=$S42 41=$S41)"
[ -n "$S43" ] && [ -n "$S42" ] && [ "$S42" -lt "$S43" ] && ok || bad "1c: 42 must be asked before 43 (seq 42=$S42 43=$S43)"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "1d: a silent queue must never be bypassed, hotfix or not (merge calls: $(cat "$T/merge-calls.txt"))"
for N in 41 42 43; do
  [ "$(state_of "example-org/mgfy-os#$N")" = READY ] && ok || bad "1d: PR $N must be held READY (got '$(state_of "example-org/mgfy-os#$N")')"
done
# The tick says so, once, before it starts the workers.
[ "$(grep -c "heads this tick's order" "$CLOG")" = 1 ] && ok || bad "1e: the log must name the hotfix ordering exactly once (got $(grep -c "heads this tick's order" "$CLOG"): $(grep "heads this tick" "$CLOG"))"
grep -q "example-org/mgfy-os#42 heads this tick's order" "$CLOG" && ok || bad "1f: the ordering line must name PR 42 (got: $(grep 'heads this' "$CLOG"))"

# ---------------------------------------------------------------------------
# 2. Under real parallelism: still nothing merges, nothing defers
# ---------------------------------------------------------------------------
reset_fixture hotfix
run_tick
[ ! -s "$T/merge-calls.txt" ] && ok || bad "2a: with all workers running at once nothing may merge around the queue (merge calls: $(cat "$T/merge-calls.txt"))"
for N in 41 42 43; do
  [ "$(state_of "example-org/mgfy-os#$N")" = READY ] && ok || bad "2b: PR $N must be held READY (got '$(state_of "example-org/mgfy-os#$N")')"
  [ -n "$(ask_seq "$N")" ] && ok || bad "2c: PR $N must still be asked of the queue this tick (asks: $(cat "$T/label-adds.txt"))"
done
grep -q 'DEFERRED' "$CLOG" && bad "2d: with no direct merges there is nothing to defer behind a hotfix: $(grep DEFERRED "$CLOG")" || ok
# A second tick: still held, still no merge.
open_list; run_tick
[ ! -s "$T/merge-calls.txt" ] && ok || bad "2e: the second tick must not merge around the queue either (merge calls: $(cat "$T/merge-calls.txt"))"

# ---------------------------------------------------------------------------
# 3. The hold is said once, and the hotfix is named in the log
# ---------------------------------------------------------------------------
A="$T/h/logs/ALERTS.log"
[ "$(grep -c 'mergify queue not answering for example-org/mgfy-os — READY PRs are held, NOT merged' "$A")" = 1 ] && ok \
  || bad "3a: exactly one daily queue-silent alert across the two ticks (ALERTS: $(cat "$A"))"
grep -q 'HOTFIX merged' "$A" && bad "3b: nothing merged, so no HOTFIX merged line: $(grep 'HOTFIX' "$A")" || ok
grep -q 'merged directly' "$A" && bad "3c: no alert may claim a direct merge: $(grep 'merged directly' "$A")" || ok
grep -q 'example-org/mgfy-os#42 MERGE_HELD: HOTFIX' "$CLOG" && ok || bad "3d: the conductor log must say the HOTFIX is held (log: $(grep -F '#42' "$CLOG" | tail -3))"
grep -q 'hotfix:mgfy:MG-42:merged' "$T/beats.txt" && bad "3e: a held hotfix must not announce merged: $(cat "$T/beats.txt")" || ok

# ---------------------------------------------------------------------------
# 4. Negatives: a near-miss label, and the kill switch
# ---------------------------------------------------------------------------
reset_fixture hotfix-candidate
MC_PR_PARALLEL=1 run_tick
[ "$(ask_seq 41)" = 1 ] && ok || bad "4a: 'hotfix-candidate' is not the hotfix label — list order stands (asks: $(cat "$T/label-adds.txt"))"
grep -q 'HOTFIX' "$T/h/logs/ALERTS.log" && bad "4b: a near-miss label must raise no HOTFIX line: $(grep HOTFIX "$T/h/logs/ALERTS.log")" || ok

reset_fixture hotfix
touch "$T/h/flags/hotfix-lane-off"
MC_PR_PARALLEL=1 run_tick
[ "$(ask_seq 41)" = 1 ] && ok || bad "4c: with flags/hotfix-lane-off the order must be exactly what it is today (asks: $(cat "$T/label-adds.txt"))"
grep -q 'HOTFIX' "$T/h/logs/ALERTS.log" && bad "4d: the kill switch must silence the announce: $(grep HOTFIX "$T/h/logs/ALERTS.log")" || ok
grep -q "heads this tick's order" "$CLOG" && bad "4e: the kill switch must stop the reordering too" || ok
rm -f "$T/h/flags/hotfix-lane-off"

# ---------------------------------------------------------------------------
# 5. A hotfix PR that is not READY: nobody waits for it
# ---------------------------------------------------------------------------
# Its worker returns early and the plain PRs are asked in the SAME tick.
reset_fixture hotfix
mv "$T/h/builds/pool-mgfy-MG-42-202609170042" "$T/rec42-away" || bad "5: the fixture could not park PR 42's record"
MC_PR_PARALLEL=1 run_tick
for N in 41 43; do
  [ -n "$(ask_seq "$N")" ] && ok || bad "5a: PR $N must be asked in the SAME tick when the hotfix PR never reaches READY (asks: $(cat "$T/label-adds.txt"))"
done
grep -q 'DEFERRED' "$CLOG" && bad "5b: nothing may defer behind a PR the conductor never merges: $(grep DEFERRED "$CLOG")" || ok
grep -q 'HOTFIX' "$T/h/logs/ALERTS.log" && bad "5c: a PR that never merged must not announce: $(grep HOTFIX "$T/h/logs/ALERTS.log")" || ok
mv "$T/rec42-away" "$T/h/builds/pool-mgfy-MG-42-202609170042" || bad "5: the fixture could not restore PR 42's record"

# ---------------------------------------------------------------------------
# 6. ENTRY IS UNCHANGED: when the queue answers, a hotfix is queued like any PR
# ---------------------------------------------------------------------------
reset_fixture hotfix
echo running > "$T/checkmode"     # Mergify acknowledges within the tick
MC_PR_PARALLEL=1 run_tick
[ ! -s "$T/merge-calls.txt" ] && ok || bad "6a: with the queue answering NOTHING may be merged directly (got: $(cat "$T/merge-calls.txt"))"
[ "$(state_of 'example-org/mgfy-os#42')" = QUEUED ] && ok || bad "6b: the hotfix PR enters the queue exactly like any other (got '$(state_of 'example-org/mgfy-os#42')')"
grep -q -- "issues/42/labels" "$T/label-adds.txt" && ok || bad "6c: the hotfix PR must still be enqueued by the merge-queue label (got: $(cat "$T/label-adds.txt"))"
grep -q -- "issues/42/comments" "$T/queue-cmds.txt" && ok || bad "6d: the @mergifyio queue command is still posted for a hotfix (got: $(cat "$T/queue-cmds.txt"))"
grep -q 'HOTFIX' "$T/h/logs/ALERTS.log" && bad "6e: a QUEUED hotfix has not merged — no announce: $(grep HOTFIX "$T/h/logs/ALERTS.log")" || ok
[ "$(state_of 'example-org/mgfy-os#41')" = QUEUED ] && ok || bad "6f: the plain PRs queue as usual (got '$(state_of 'example-org/mgfy-os#41')')"

# ---------------------------------------------------------------------------
# 7. A REPO THAT TESTS ONLY IN ITS QUEUE IS HELD LIKE ANY OTHER MERGIFY REPO,
#    AND THE `@mergifyio queue` ASK IS MADE ONCE PER HEAD
#    (2026-09-24, "each tree is tested exactly once"; rebased onto BH-2199)
# ---------------------------------------------------------------------------
# TEST-CHANGE (#2220 rebase onto BH-2199, the operator 2026-09-25: the queue owns main,
# nothing merges directly when it is silent). This section used to assert
# #2220's own batch-only PARK arm: a `PARKED queue-silent-batch-only` log line
# and a warn-digest "PR parked, not merged" alert from mc_queue_parked_alert
# (7c, 7g, 7h, 7r). BH-2199 removed the degraded direct merge for EVERY
# queue_rules repo, so the park arm and its alert were dropped from #2220 as
# redundant: a batch-only repo now takes main's hold (MERGE_HELD, the daily
# "READY PRs are held, NOT merged" alert that section 3 pins). 7c and 7g assert
# that hold instead; 7h and 7r pinned the deleted park alert's severity and go
# with it. What #2220 still owns here is unchanged: nothing merges (7a, 7b,
# 7l) and the ask ledger posts `@mergifyio queue` once per head (7j-7q).
# Tick 2 runs with MC_MERGIFY_REASK_TICKS=1 so main's held-tick throttle lets
# every PR reach the enqueue, and the ledger alone decides the comment.
printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success=Lint\n    merge_conditions:\n      - check-success=Lint\n      - check-success=Corpus\n' \
  | base64 | tr -d '\n' > "$T/mgfy.b64"
reset_fixture hotfix
MC_PR_PARALLEL=1 run_tick
[ ! -s "$T/merge-calls.txt" ] && ok || bad "7a: a batch-only repo must never be merged directly when the queue is silent (got: $(cat "$T/merge-calls.txt"))"
for N in 41 42 43; do
  [ "$(state_of "example-org/mgfy-os#$N")" = MERGED ] && bad "7b: PR $N must not be MERGED" || ok
done
grep -q 'example-org/mgfy-os#41 MERGE_HELD: .*NOT merged directly' "$CLOG" && ok || bad "7c: the conductor must say the PR is held, not merged (log: $(tail -3 "$CLOG"))"
grep -q 'mergify queue not answering for example-org/mgfy-os' "$T/h/logs/ALERTS.log" && ok \
  || bad "7d: the daily queue-not-answering alert must still fire (ALERTS: $(cat "$T/h/logs/ALERTS.log"))"
grep -q -- "issues/41/labels" "$T/label-adds.txt" && ok || bad "7e: the enqueue is still asked for (the label goes on)"
A7=$(grep 'mergify queue not answering for example-org/mgfy-os' "$T/h/logs/ALERTS.log")
grep -q 'merged directly' <<<"$A7" && bad "7f: nothing was merged — the alert must not say 'merged directly': $A7" || ok
grep -q 'READY PRs are held, NOT merged' <<<"$A7" && ok || bad "7g: the alert must say the PRs are held, not merged: $A7"
[ "$(grep -c 'queue not answering' "$T/h/logs/ALERTS.log")" = 1 ] && ok \
  || bad "7i: one alert per repo per day, however many PRs are held (got $(grep -c 'queue not answering' "$T/h/logs/ALERTS.log"))"
for N in 41 42 43; do
  [ "$(grep -c -- "issues/$N/comments" "$T/queue-cmds.txt")" = 1 ] && ok \
    || bad "7j: tick 1 asks the queue once for PR $N (got $(grep -c -- "issues/$N/comments" "$T/queue-cmds.txt"))"
done
# Tick 2 on the same heads: the label is re-applied (idempotent) but the
# `@mergifyio queue` comment is NOT posted again. PR 43's ledger names an older
# head (a new head re-asks) and PR 41's ask is older than the backoff.
ASKD="$T/h/state/merge-conductor/mergify-asked"
[ -d "$ASKD" ] && ok || bad "7k: the ask ledger must exist after tick 1 ($ASKD)"
F43=$(grep -l 'aaaaaaaa0043' "$ASKD"/* 2>/dev/null | head -1)
F41=$(grep -l 'aaaaaaaa0041' "$ASKD"/* 2>/dev/null | head -1)
[ -n "$F43" ] && [ -n "$F41" ] && ok || bad "7k: the ledger must record each asked head (files: $(ls "$ASKD" 2>/dev/null))"
[ -n "$F43" ] && sed -i 's/aaaaaaaa0043/bbbbbbbb0043/' "$F43"
[ -n "$F41" ] && touch -d '@'$(( $(date -u +%s) - 7 * 3600 )) "$F41"
open_list; MC_MERGIFY_REASK_TICKS=1 MC_MERGIFY_REASK_S=21600 MC_PR_PARALLEL=1 run_tick
[ ! -s "$T/merge-calls.txt" ] && ok || bad "7l: tick 2 must not merge either (got: $(cat "$T/merge-calls.txt"))"
[ "$(grep -c -- "issues/42/comments" "$T/queue-cmds.txt")" = 1 ] && ok \
  || bad "7m: the same head is not asked twice inside the backoff (PR 42 asks: $(grep -c -- "issues/42/comments" "$T/queue-cmds.txt"))"
[ "$(grep -c -- "issues/43/comments" "$T/queue-cmds.txt")" = 2 ] && ok \
  || bad "7n: a head the ledger has not asked about is asked (PR 43 asks: $(grep -c -- "issues/43/comments" "$T/queue-cmds.txt"))"
[ "$(grep -c -- "issues/41/comments" "$T/queue-cmds.txt")" = 2 ] && ok \
  || bad "7o: past the backoff the same head is asked again (PR 41 asks: $(grep -c -- "issues/41/comments" "$T/queue-cmds.txt"))"
[ "$(grep -c -- "issues/42/labels" "$T/label-adds.txt")" = 2 ] && ok \
  || bad "7p: the label (idempotent) still goes on every tick (PR 42 label adds: $(grep -c -- "issues/42/labels" "$T/label-adds.txt"))"
[ "$(grep -c 'queue not answering' "$T/h/logs/ALERTS.log")" = 1 ] && ok \
  || bad "7q: tick 2 on the same day raises no second alert"
printf '%s' "$MGFY_YML" > "$T/mgfy.b64"

echo "hotfix-conductor-degraded-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
