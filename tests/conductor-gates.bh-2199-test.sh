#!/bin/bash
# tests/conductor-gates.bh-2199-test.sh — the two conductor gate holes that let
# #2158 and #2196 merge over a lead CHANGES_REQUESTED (BH-2199, acceptance).
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh, merge mode, over a Mergify
# repo (queue_rules in .mergify.yml) with a fake gh. Every assertion reads the
# real `gh pr merge` calls, the real label adds (the queue ask), the real rows
# and the real conductor log / ALERTS.log.
#   G1  lead CR at head A, live head B only merged main -> no merge, no enqueue,
#       and the log names the standing lead BLOCK and head A
#   G2  lead CR at the live head -> no merge, no enqueue, the same log line
#   G3  B changed the PR's own diff -> the CR no longer stands; it is enqueued
#   G4  the queue is silent, two READY PRs in one tick -> ZERO direct merges,
#       both held (rows stay READY, never BLOCKED_HUMAN), ONE alert
#   G5  a held PR is asked again only every MC_MERGIFY_REASK_TICKS held ticks
# Run from anywhere: tests/conductor-gates.bh-2199-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# The open-PR list is REST (BH-1585); this bridge answers it from list.json.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/hotfix-lib.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# The block gate rides with the conductor lib in production. verdicts.sh stays
# out, as in tests/conductor-block-gate-test.sh: its worker read would answer
# "unreadable" in this fixture and hold every merge.
cp "$DIR/bin/lib/block-gate.sh" "$T/h/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$T/h/bin/merge-conductor.sh"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/pre-arm-guards.sh"; chmod +x "$T/h/bin/pre-arm-guards.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"
MSHA=cccccccc3333
head_of() { printf 'aaaaaaaa00%s' "$1"; }
BLOCKED=dddddddd0041   # the head the lead's review was left on (G1)

for N in 41 42; do
  REC="$T/h/builds/pool-mgfy-MG-$N-2026091700$N"
  mkdir -p "$REC"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$N" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  head_of "$N" > "$REC/reviewed-sha"
  : > "$REC/pipeline.log"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n' | base64 | tr -d '\n')

labels_csv() { tr '\n' ',' < "$T/labels-$1" 2>/dev/null | sed 's/,$//'; }
open_list() {
  local n out="" lbl csv
  for n in ${OPEN_PRS:-41 42}; do
    [ "$(cat "$T/prstate-$n" 2>/dev/null)" = open ] || continue
    csv=$(labels_csv "$n"); lbl="[]"
    [ -n "$csv" ] && lbl=$(printf '%s' "$csv" | jq -R 'split(",")|map({name:.})' -c)
    out="$out{\"number\":$n,\"url\":\"https://github.com/example-org/mgfy-os/pull/$n\",\"headRefOid\":\"$(head_of "$n")\",\"headRefName\":\"ticket/mg-$n\",\"isDraft\":false,\"mergeStateStatus\":\"CLEAN\",\"mergeable\":\"MERGEABLE\",\"state\":\"OPEN\",\"isInMergeQueue\":false,\"labels\":$lbl},"
  done
  printf '[%s]\n' "${out%,}" > "$T/list.json"
}

# The gh stub. The reads BH-2199 adds (reviews with their STATE, the PR's base,
# the three-dot compare) answer through the -q program the lib passes, from
# JSON fixtures, the way `gh api … -q` would.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
CHECK=\$(cat "$T/checkmode" 2>/dev/null || echo none)
N=\$(printf '%s' "\$*" | sed -nE 's#.*(/pull/|/pulls/|/issues/)([0-9]+).*#\2#p' | head -1)
[ -n "\$N" ] || N=41
PRSTATE=\$(cat "$T/prstate-\$N" 2>/dev/null || echo open)
HEAD=aaaaaaaa00\$N
LBL=\$(tr '\n' ',' < "$T/labels-\$N" 2>/dev/null | sed 's/,\$//')
Q=""; prev=""; for a in "\$@"; do [ "\$prev" = -q ] && Q="\$a"; prev="\$a"; done
fx() { if [ -f "\$1" ]; then if [ -n "\$Q" ]; then jq -r "\$Q" "\$1"; else cat "\$1"; fi; else echo "HTTP 404: Not Found" >&2; exit 1; fi; }
case "\$*" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "api -X GET repos/example-org/mgfy-os/pulls/"*"/reviews"*)
    f="$T/reviews-\$N.json"; [ -f "\$f" ] || f="$T/no-reviews.json"; fx "\$f" ;;
  "api -X GET repos/example-org/mgfy-os/compare/"*)
    sha=\$(printf '%s' "\$*" | sed -nE 's#.*compare/[^ ]*\.\.\.([0-9a-f]+).*#\1#p'); fx "$T/compare-\$sha.json" ;;
  "api -X GET repos/example-org/mgfy-os/pulls/"*) fx "$T/pull-base.json" ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "\$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$T/queue-cmds.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*)
    printf '%s\n' "\$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-\$N"; sort -u -o "$T/labels-\$N" "$T/labels-\$N"
    [ "\$CHECK" = running ] && { printf 'queued\n' >> "$T/labels-\$N"; sort -u -o "$T/labels-\$N" "$T/labels-\$N"; } ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/merge-queue"*)
    printf '%s\n' "\$*" >> "$T/label-removes.txt"
    grep -vxF 'merge-queue' "$T/labels-\$N" > "$T/labels-\$N.tmp" 2>/dev/null; mv -f "$T/labels-\$N.tmp" "$T/labels-\$N" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; echo merged > "$T/prstate-\$N"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/pr-comments.txt" ;;
  *v3.diff*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    case "\$PRSTATE" in
      merged) restpr MERGED "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator "$MSHA" ;;
      *)      restpr OPEN   "\$HEAD" "ticket/mg-\$N" main "\$LBL" MERGEABLE CLEAN operator ;;
    esac ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*) restpr --raw 200 '{"state":"closed","number":'"\$N"'}' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open","number":'"\$N"'}' ;;
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
echo '[]' > "$T/no-reviews.json"
echo '{"number":41,"base":{"ref":"main"}}' > "$T/pull-base.json"

ROWS="$T/h/state/merge-conductor/pr-state.tsv"
CLOG="$T/h/logs/merge-conductor.log"
A="$T/h/logs/ALERTS.log"
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS" 2>/dev/null; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
reset_fixture() { # reset_fixture <checkmode>
  scratch_rm "$T/h/state/merge-conductor"; scratch_rm "$T/h/state/block-gate"
  rm -f "$T/h/state/merge-sweep-done.txt" "$T/h/tmp"/*.provider "$T/h/tmp"/*.probe 2>/dev/null
  rm -f "$T"/reviews-*.json "$T"/compare-*.json 2>/dev/null
  for N in 41 42; do echo open > "$T/prstate-$N"; : > "$T/labels-$N"; done
  for f in gh-calls.txt merge-calls.txt label-adds.txt label-removes.txt queue-cmds.txt pr-comments.txt; do : > "$T/$f"; done
  : > "$A"; : > "$CLOG"
  echo "${1:-running}" > "$T/checkmode"
  open_list
}
lead_cr() { # lead_cr <pr> <commit> — the lead's CHANGES_REQUESTED, `## BLOCKING` and no BLOCK marker (#2158's shape)
  jq -nc --arg c "$2" --arg n "$1" '[{id:5308896759, user:{login:"operator", type:"User"}, author_association:"OWNER",
     state:"CHANGES_REQUESTED", commit_id:$c, submitted_at:"2026-09-24T19:03:16Z",
     html_url:("https://github.com/example-org/mgfy-os/pull/"+$n+"#pullrequestreview-5308896759"),
     body:"# Review\n\n## BLOCKING\n\nthe split-brain guard is missing"}]' > "$T/reviews-$1.json"
}
own_diff() { # own_diff <sha> <patch> — the PR's own diff at that head (compare main...<sha>)
  jq -nc --arg p "$2" '{files:[{filename:"src/x.ts", status:"modified", changes:2, sha:"1111", patch:$p}]}' > "$T/compare-$1.json"
}
merges_of() { grep -c -- "/pull/$1\b" "$T/merge-calls.txt" 2>/dev/null; }
asks_of()   { grep -c -- "issues/$1/labels" "$T/label-adds.txt" 2>/dev/null; }
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# ── G1: lead CR at A, B only merged main ────────────────────────────────────
reset_fixture running
lead_cr 41 "$BLOCKED"
own_diff "$BLOCKED"        $'@@ -3,2 +3,2 @@ ctx\n-const a = 0;\n+const a = 1;'
own_diff "$(head_of 41)"   $'@@ -9,2 +9,2 @@ ctx shifted by the main merge\n-const a = 0;\n+const a = 1;'
MC_PR_PARALLEL=1 run_tick
[ "$(merges_of 41)" = 0 ] && ok || bad "G1: a lead CR must survive a main-merge-only head — PR 41 was merged: $(cat "$T/merge-calls.txt")"
[ "$(asks_of 41)" = 0 ] && ok || bad "G1: a lead-blocked PR must not be ENQUEUED either (the queue is a merge): $(cat "$T/label-adds.txt")"
grep -q 'example-org/mgfy-os#41 MERGE_REFUSED block-gate: standing CHANGES_REQUESTED (lead/human BLOCK)' "$CLOG" && ok \
  || bad "G1: the log must name the standing lead BLOCK (log: $(grep -F '#41' "$CLOG" | tail -5))"
grep -q "${BLOCKED:0:8}" <<<"$(grep -F '#41 MERGE_REFUSED' "$CLOG")" && ok || bad "G1: the refusal must name the head the lead blocked (${BLOCKED:0:8})"
[ "$(state_of 'example-org/mgfy-os#41')" = READY ] && ok || bad "G1: the row keeps READY — a refusal, not a park (got '$(state_of 'example-org/mgfy-os#41')')"
[ "$(state_of 'example-org/mgfy-os#42')" = QUEUED ] && ok || bad "G1: the unblocked PR 42 is enqueued as usual (got '$(state_of 'example-org/mgfy-os#42')')"

# ── G2: lead CR at the live head ────────────────────────────────────────────
reset_fixture running
lead_cr 41 "$(head_of 41)"
MC_PR_PARALLEL=1 run_tick
[ "$(merges_of 41)" = 0 ] && [ "$(asks_of 41)" = 0 ] && ok || bad "G2: a lead CR on the live head must stop the merge and the enqueue (merges: $(cat "$T/merge-calls.txt") asks: $(cat "$T/label-adds.txt"))"
grep -q 'example-org/mgfy-os#41 MERGE_REFUSED block-gate: standing CHANGES_REQUESTED (lead/human BLOCK)' "$CLOG" && ok \
  || bad "G2: the log must name the standing lead BLOCK (log: $(grep -F '#41' "$CLOG" | tail -5))"

# ── G3: B changed the PR's own diff ─────────────────────────────────────────
reset_fixture running
lead_cr 41 "$BLOCKED"
own_diff "$BLOCKED"      $'@@ -3,2 +3,2 @@ ctx\n-const a = 0;\n+const a = 1;'
own_diff "$(head_of 41)" $'@@ -3,2 +3,3 @@ ctx\n-const a = 0;\n+const a = 1;\n+guard();'
MC_PR_PARALLEL=1 run_tick
[ "$(asks_of 41)" = 1 ] && ok || bad "G3: a head that changed the PR's own diff lifts the CR and is enqueued (asks: $(cat "$T/label-adds.txt"); log: $(grep -F '#41' "$CLOG" | tail -3))"
grep -q '#41 MERGE_REFUSED' "$CLOG" && bad "G3: nothing may be refused once the PR's own diff changed: $(grep '#41 MERGE_REFUSED' "$CLOG")" || ok

# ── G4: the queue is silent, two READY PRs ──────────────────────────────────
reset_fixture none
run_tick
[ ! -s "$T/merge-calls.txt" ] && ok || bad "G4: a silent Mergify queue must NEVER fall back to a direct merge (merge calls: $(cat "$T/merge-calls.txt"))"
for N in 41 42; do
  [ "$(state_of "example-org/mgfy-os#$N")" = READY ] && ok || bad "G4: PR $N must be held READY (got '$(state_of "example-org/mgfy-os#$N")')"
  grep -q "example-org/mgfy-os#$N MERGE_HELD" "$CLOG" && ok || bad "G4: PR $N must log MERGE_HELD (log: $(grep -F "#$N" "$CLOG" | tail -3))"
done
[ "$(grep -c 'held, NOT merged' "$A")" = 1 ] && ok || bad "G4: exactly ONE queue-silent alert for the repo (got $(grep -c 'held, NOT merged' "$A"): $(cat "$A"))"
grep -q 'merged directly' "$A" && bad "G4: no alert may claim a direct merge: $(grep 'merged directly' "$A")" || ok
grep -q 'BLOCKED_HUMAN' "$ROWS" && bad "G4: a silent queue is not a strike against any PR: $(cat "$ROWS")" || ok
[ "$(asks_of 41)" = 1 ] && [ "$(asks_of 42)" = 1 ] && ok || bad "G4: each PR's queue ask is made once this tick (asks: $(cat "$T/label-adds.txt"))"

# ── G5: the queue ask is retried every MC_MERGIFY_REASK_TICKS held ticks ────
# Default 6: the next tick asks nothing (no @mergifyio comment every 5 minutes
# on a repo whose queue product is off).
open_list; run_tick
[ "$(asks_of 41)" = 1 ] && ok || bad "G5: with the default re-ask interval the second held tick must not ask again (asks: $(cat "$T/label-adds.txt"))"
grep -q "example-org/mgfy-os#41 MERGE_HELD" "$CLOG" && ok || bad "G5: the held tick still says MERGE_HELD"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "G5: still no direct merge on a held tick (merge calls: $(cat "$T/merge-calls.txt"))"
# Interval 1: every held tick asks again.
open_list; MC_MERGIFY_REASK_TICKS=1 run_tick
[ "$(asks_of 41)" = 2 ] && ok || bad "G5: with MC_MERGIFY_REASK_TICKS=1 the next tick asks the queue again (asks: $(cat "$T/label-adds.txt"))"
# The queue answers on a later ask: the PR is QUEUED, never merged around it.
echo running > "$T/checkmode"; open_list; MC_MERGIFY_REASK_TICKS=1 run_tick
[ "$(state_of 'example-org/mgfy-os#41')" = QUEUED ] && ok || bad "G5: a later ask the queue answers moves the PR to QUEUED (got '$(state_of 'example-org/mgfy-os#41')')"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "G5: the queue lands it, not the conductor (merge calls: $(cat "$T/merge-calls.txt"))"

echo "conductor-gates.bh-2199-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
