#!/bin/bash
# tests/merge-queue-native-test.sh — the ASYNC merge contract: what the merge
# conductor must do on a repo whose default branch is behind GitHub's NATIVE
# merge queue (a ruleset rule of type merge_queue).
#
# WHY DRIVEN AND NOT GREPPED. `gh pr merge <url> --squash --match-head-commit
# <sha>` on a merge-queue branch ENQUEUES and exits 0: the PR stays OPEN,
# mergeCommit.oid is null, and isInMergeQueue becomes true. mergeStateStatus has
# NO QUEUED value (the enum is DIRTY UNKNOWN BLOCKED BEHIND UNSTABLE HAS_HOOKS
# CLEAN), so the only witness is isInMergeQueue. Every consequence of a landing
# the fleet depends on — the merge ledger row, state/merge-sweep-done.txt, the
# merge_sha artifact, the issue close, deploy-request.sh, the ship beat — used to
# hang off the same `if` as the merge call, so under a queue none of them fired,
# the PR was never settled, and the second tick parked it BLOCKED_HUMAN
# merge-failed-twice. The claims here are about WHICH TICK DOES WHAT; a grep
# cannot see that.
#
# gh, curl (the jobs client), beat, agent-call, deploy-request and fleet-conf are
# stubbed the way tests/merge-conductor-test.sh stubs them. The gh stub fails the
# run on `--auto` (allow_auto_merge is false fleet-wide; gh enqueues without it).
# Run from anywhere: tests/merge-queue-native-test.sh   (exit 0 = all pass)
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

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
# The decision reads go through bin/lib/gh-rest.sh since BH-784, so the fixture
# tree carries it exactly as a box does. Without it the lib's fail-closed shim
# answers "unverifiable" to every read and this suite would be green on a
# conductor that never reads anything.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
H1=aaaaaaaa1111; H2=bbbbbbbb2222; MSHA=cccccccc3333
printf 'queued example-org/queued-os - - 2 box-q\nplain example-org/plain-os - - 3 box-p\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/deployreq.txt"\nexit 0\n' "$T" > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
printf '#!/bin/bash\nexit 2\n' > "$T/h/bin/pre-arm-guards.sh"; chmod +x "$T/h/bin/pre-arm-guards.sh"

# Build records: PR 11 on the queue repo, PR 21 on the plain repo. Both APPROVE
# bound to H1, both issue-driven (fleet.conf board prefix "-"), so a landing owes
# an issue close (#11 / #21 from the build KEY) and a deploy request.
mkdir -p "$T/h/builds/pool-queued-QS-11-202609120001" "$T/h/builds/pool-plain-PL-21-202609120002"
echo "PR_CREATED https://github.com/example-org/queued-os/pull/11" > "$T/h/builds/pool-queued-QS-11-202609120001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/pool-queued-QS-11-202609120001/review.md"
echo "$H1" > "$T/h/builds/pool-queued-QS-11-202609120001/reviewed-sha"
echo "PR_CREATED https://github.com/example-org/plain-os/pull/21" > "$T/h/builds/pool-plain-PL-21-202609120002/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/pool-plain-PL-21-202609120002/review.md"
echo "$H1" > "$T/h/builds/pool-plain-PL-21-202609120002/reviewed-sha"

# The two open-PR lists, swapped per scenario by writing these files.
open_queued() { # open_queued <inqueue true|false> | "none"
  if [ "$1" = none ]; then echo "[]" > "$T/list-queued.json"; return; fi
  cat > "$T/list-queued.json" <<J
[{"number":11,"url":"https://github.com/example-org/queued-os/pull/11","headRefOid":"$2","headRefName":"ticket/qs-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":$1}]
J
}
open_plain() { # open_plain none | open
  if [ "$1" = none ]; then echo "[]" > "$T/list-plain.json"; return; fi
  cat > "$T/list-plain.json" <<J
[{"number":21,"url":"https://github.com/example-org/plain-os/pull/21","headRefOid":"$H1","headRefName":"ticket/pl-21","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false}]
J
}
open_plain none
open_queued false "$H1"   # not in the queue yet — this tick is the one that enqueues
echo queued > "$T/mode"

# THE DECISION READS ARE REST NOW (BH-784). `gh api -i -X GET repos/…/pulls/<n>`
# prints response HEADERS then the body, and bin/lib/gh-rest.sh judges the HTTP
# STATUS LINE — so a stub arm has to emit a whole HTTP response, not a bare JSON
# line. tests/lib/rest-emit.sh is the shared emitter; `restpr MERGED …` prints
# the real REST shape (state "closed" WITH merged_at set), which is the thing a
# hand-rolled fixture keeps getting wrong.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
MODE=\$(cat "$T/mode" 2>/dev/null || echo queued)
issue_num() { printf '%s' "\$1" | sed -n 's|.*/issues/\([0-9][0-9]*\).*|\1|p'; }
case "\$*" in
  # --- the budget read: a 0-byte answer here leaves gh-budget.sh an empty cache
  #     file and the NEXT tick in this scratch tree dies silently.
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  # --- the capability probe: queued-os main carries a merge_queue rule ---------
  # BH-1586: gh_rest reads in the real REST shapes (a list, then the object).
  *"api -i -X GET repos/example-org/queued-os/rulesets/9"*)
    restpr --raw 200 '{"id":9,"name":"main","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"pull_request"},{"type":"merge_queue"},{"type":"required_status_checks"}]}' ;;
  *"api -i -X GET repos/example-org/queued-os/rulesets"*) restpr --raw 200 '[{"id":9,"enforcement":"active"}]' ;;
  *"api -i -X GET repos/example-org/plain-os/rulesets/4"*)
    restpr --raw 200 '{"id":4,"name":"main","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"pull_request"},{"type":"required_status_checks"}]}' ;;
  *"api -i -X GET repos/example-org/plain-os/rulesets"*) restpr --raw 200 '[{"id":4,"enforcement":"active"}]' ;;
  *"api -i -X GET repos/example-org/broken-os/rulesets"*) restpr --raw 502 '{"message":"could not resolve"}' ;;
  *"api -i -X GET repos/"*"/contents/.mergify.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  # --- writes ------------------------------------------------------------------
  *"pr merge"*"--auto"*) echo "ENQUEUE PASSED --auto: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr merge https://github.com/example-org/queued-os/pull/11 --squash --match-head-commit $H1") touch "$T/enqueued11"; exit 0 ;;
  *"pr merge https://github.com/example-org/plain-os/pull/21 --squash --match-head-commit $H1") touch "$T/merged21"; exit 0 ;;
  *"pr merge"*) echo "wrong merge form: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  # The issue close-out is REST too: a comment POST, then a PATCH to state=closed
  # that gh_rest_close only believes after a FRESH read says closed — so the
  # PATCH has to actually move the issue in this stub's world.
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"
    issue_num "\$*" >> "$T/closed-issues"
    restpr --raw 200 '{"state":"closed"}' ;;
  # --- reads -------------------------------------------------------------------
  *"api -i -X GET repos/"*"/issues/"*)
    if grep -qxF "\$(issue_num "\$*")" "$T/closed-issues" 2>/dev/null
    then restpr --raw 200 '{"state":"closed"}'
    else restpr --raw 200 '{"state":"open"}'; fi ;;
  # The DIFF media type shares the /pulls/<n> path, so it is matched first.
  *"api -i -X GET repos/example-org/queued-os/pulls/11"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/plain-os/pulls/21"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  # The settle pass reads the PR once and derives state, head, branch and labels
  # from it (mc_queue_state's single read). One MODE answers every shape.
  # A NATIVE queue has no label and no check: there is no REST field for
  # isInMergeQueue, so nothing here can say "GitHub's queue holds it".
  *"api -i -X GET repos/example-org/queued-os/pulls/11"*)
    case "\$MODE" in
      merged)  restpr MERGED "$H1" ticket/qs-11 main "" MERGEABLE CLEAN app/cromford "$MSHA" ;;
      closed)  restpr CLOSED "$H1" ticket/qs-11 main "" ;;
      *)       restpr OPEN   "$H1" ticket/qs-11 main "" ;;
    esac ;;
  *"api -i -X GET repos/example-org/plain-os/pulls/21"*)
    if [ -f "$T/merged21" ]
    then restpr MERGED "$H1" ticket/pl-21 main "" MERGEABLE CLEAN app/cromford "$MSHA"
    else restpr OPEN   "$H1" ticket/pl-21 main "" ; fi ;;
  # the stacked-parent probe: no parent PR on any branch here
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"pr list -R example-org/queued-os --state open"*) cat "$T/list-queued.json" ;;
  *"pr list -R example-org/plain-os --state open"*) cat "$T/list-plain.json" ;;
  *"pr list"*"--state closed"*) : ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# jobs client: no ledger rows anywhere (404) — the records decide, as in prod
# on a box whose worker is down. PUTs are accepted so pr_state rows still flow.
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
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS" 2>/dev/null; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$ROWS" 2>/dev/null; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }

touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
: > "$T/gh-calls.txt"; : > "$T/gh-writes.txt"; : > "$T/issue-calls.txt"; : > "$T/deployreq.txt"

# ============================================================================
# 1. Tick one on a queue repo: ENQUEUE, and NONE of the landing consequences
# ============================================================================
run_tick
[ -f "$T/enqueued11" ] && ok || bad "a READY PR on a merge-queue repo must be enqueued with gh pr merge --squash --match-head-commit"
grep -q -- "--auto" "$T/gh-calls.txt" && bad "the enqueue must NOT pass --auto (allow_auto_merge is false fleet-wide)" || ok
[ -s "$T/gh-writes.txt" ] && bad "$(cat "$T/gh-writes.txt")" || ok
[ "$(state_of 'example-org/queued-os#11')" = QUEUED ] && ok || bad "after the enqueue the row must be QUEUED (got '$(state_of 'example-org/queued-os#11')')"
grep -qxF 'https://github.com/example-org/queued-os/pull/11' "$T/h/state/merge-sweep-done.txt" 2>/dev/null \
  && bad "an ENQUEUED PR must not be written to merge-sweep-done.txt — it has not merged" || ok
[ -s "$T/issue-calls.txt" ] && bad "an ENQUEUED PR must not close its issue: $(cat "$T/issue-calls.txt")" || ok
[ -s "$T/deployreq.txt" ] && bad "an ENQUEUED PR must not request a deploy: $(cat "$T/deployreq.txt")" || ok
grep -q 'conductor_merged' "$T/beats.txt" 2>/dev/null && bad "an ENQUEUED PR must not beat a merge" || ok

# A second tick while it is still in the queue: still QUEUED, no second enqueue.
rm -f "$T/enqueued11"; open_queued true "$H1"
run_tick
[ "$(state_of 'example-org/queued-os#11')" = QUEUED ] && ok || bad "a PR still in the queue stays QUEUED (got '$(state_of 'example-org/queued-os#11')')"
[ -f "$T/enqueued11" ] && bad "a PR already in the queue must not be enqueued again" || ok

# …AND WHEN THE FIELD ITSELF IS UNAVAILABLE (BH-784). gh's --json allowlist can
# refuse isInMergeQueue, and since the REST conversion there is no REST field to
# fall back to either — mc_inqueue answers `unknown` -> false on that path. Read
# as "not in the queue", a row THIS conductor put in QUEUED classifies READY and
# is re-enqueued every tick: two strikes and the PR is parked BLOCKED_AGENT for a
# queue that was holding it correctly. MC_LIST_INQUEUE=0 is the refusal (it is
# what the refusal marker resolves to), and the list loses the field with it.
open_queued_nofield() { # the list gh answers when it refuses the field
  cat > "$T/list-queued.json" <<J
[{"number":11,"url":"https://github.com/example-org/queued-os/pull/11","headRefOid":"$H1","headRefName":"ticket/qs-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
}
run_tick_noinq() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_QUEUE_TTL=0 MC_LIST_INQUEUE=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "noinq tick rc=$? stderr:"; cat "$T/tick.err"; }; }
rm -f "$T/enqueued11"; open_queued_nofield
run_tick_noinq
[ -f "$T/enqueued11" ] \
  && bad "a PR already in the queue was RE-ENQUEUED because the queue field was invisible — two of those park it BLOCKED_AGENT" || ok
[ "$(state_of 'example-org/queued-os#11')" = QUEUED ] \
  && ok || bad "with isInMergeQueue in neither the list nor REST, a row the conductor queued must STAY QUEUED (got '$(state_of 'example-org/queued-os#11')')"
open_queued true "$H1"

# ============================================================================
# 2. The tick GitHub merges it out of the queue: settle, exactly once
# ============================================================================
echo merged > "$T/mode"; open_queued none      # merged PRs leave the open list
run_tick
[ "$(state_of 'example-org/queued-os#11')" = MERGED ] && ok || bad "a PR merged out of the queue must settle to MERGED (got '$(state_of 'example-org/queued-os#11')')"
grep -qxF 'https://github.com/example-org/queued-os/pull/11' "$T/h/state/merge-sweep-done.txt" && ok || bad "the settle must ledger the merge where the sweep looks (merge-sweep-done.txt)"
# The close is `gh api -i -X PATCH repos/<slug>/issues/<n> -f state=closed` since
# BH-784 — same claim, new verb.
[ "$(grep -c 'PATCH repos/example-org/queued-os/issues/11 ' "$T/issue-calls.txt")" = 1 ] && ok || bad "the settle must close the issue exactly once (got $(cat "$T/issue-calls.txt"))"
[ "$(wc -l < "$T/deployreq.txt" | tr -d ' ')" = 1 ] && ok || bad "the settle must request exactly one deploy (got $(cat "$T/deployreq.txt"))"
grep -q "$MSHA" "$T/deployreq.txt" && ok || bad "the deploy request must carry the REAL merge sha (got $(cat "$T/deployreq.txt"))"
grep -q 'conductor_merged' "$T/beats.txt" && ok || bad "the settle must beat the merge"

# A third tick must add nothing: the row is MERGED and the settle never re-runs.
run_tick
[ "$(wc -l < "$T/deployreq.txt" | tr -d ' ')" = 1 ] && ok || bad "a later tick must not enqueue a second deploy (got $(cat "$T/deployreq.txt"))"
[ "$(grep -c 'PATCH repos/example-org/queued-os/issues/11 ' "$T/issue-calls.txt")" = 1 ] && ok || bad "a later tick must not close the issue again"

# ============================================================================
# 3. Ejection: the merge_group build went red and GitHub dropped the entry
# ============================================================================
: > "$T/h/state/merge-conductor/attempts.txt"
seed_queued_row() { # seed_queued_row <head>
  printf 'example-org/queued-os#11\tQUEUED\t%s\t%s\t%s\t-\tenqueued at %s\thttps://github.com/example-org/queued-os/pull/11\n' \
    "$(date -u +%s)" "$1" "$1" "${1:0:8}" > "$ROWS"
}
seed_queued_row "$H1"
echo ejected > "$T/mode"; open_queued false "$H1"; : > "$T/gh-writes.txt"; rm -f "$T/enqueued11"
run_tick
[ "$(state_of 'example-org/queued-os#11')" = WAIT_CI ] && ok || bad "an ejected PR must go WAIT_CI, not BLOCKED_HUMAN (got '$(state_of 'example-org/queued-os#11')')"
grep -q 'queue-ejected' <<<"$(reason_of 'example-org/queued-os#11')" && ok || bad "the ejection reason must say queue-ejected (got '$(reason_of 'example-org/queued-os#11')')"
[ -f "$T/enqueued11" ] && bad "an ejected PR must NOT be re-enqueued on the same head — that is the forever-loop shape" || ok

# Second ejection: an earlier head was ejected too (the author pushed a fix and
# the merge_group build went red again). Two ejections is a human's problem.
printf 'ejected example-org/queued-os#11 %s\n' "$H2" >> "$T/h/state/merge-conductor/attempts.txt"
seed_queued_row "$H1"
run_tick
[ "$(state_of 'example-org/queued-os#11')" = BLOCKED_HUMAN ] && ok || bad "a second ejection must be BLOCKED_HUMAN (got '$(state_of 'example-org/queued-os#11')')"
grep -q 'queue-ejected-twice' <<<"$(reason_of 'example-org/queued-os#11')" && ok || bad "the second ejection's reason must be queue-ejected-twice (got '$(reason_of 'example-org/queued-os#11')')"

# ============================================================================
# 4. A repo with NO merge_queue rule keeps today's synchronous path
# ============================================================================
: > "$ROWS"; : > "$T/deployreq.txt"; : > "$T/issue-calls.txt"; : > "$T/gh-writes.txt"
open_queued none; open_plain open; echo queued > "$T/mode"
run_tick
[ -f "$T/merged21" ] && ok || bad "a READY PR on a repo with no merge queue must still be merged synchronously"
[ "$(state_of 'example-org/plain-os#21')" = MERGED ] && ok || bad "the synchronous path must reach MERGED in ONE tick (got '$(state_of 'example-org/plain-os#21')')"
grep -qxF 'https://github.com/example-org/plain-os/pull/21' "$T/h/state/merge-sweep-done.txt" && ok || bad "the synchronous path must still write merge-sweep-done.txt"
[ "$(grep -c 'PATCH repos/example-org/plain-os/issues/21 ' "$T/issue-calls.txt")" = 1 ] && ok || bad "the synchronous path must still close the issue once"
[ "$(wc -l < "$T/deployreq.txt" | tr -d ' ')" = 1 ] && ok || bad "the synchronous path must still request exactly one deploy"
grep -q 'pre-arm' "$T/h/logs/merge-conductor.log" 2>/dev/null; : # pre-arm behaviour is tests/prearm-skip-on-queue-test.sh

# ============================================================================
# 5. The probe and the settle, as library functions
# ============================================================================
# shellcheck source=/dev/null
export PATH="$T/fakebin:$PATH"; . "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
MC_QUEUE_TTL=0
mc_queue_enabled example-org/queued-os && ok || bad "mc_queue_enabled must be true for a repo whose active ruleset carries a merge_queue rule"
mc_queue_enabled example-org/plain-os && bad "mc_queue_enabled must be false for a repo with no merge_queue rule" || ok
mc_queue_enabled example-org/broken-os && bad "mc_queue_enabled must FAIL CLOSED to 'no queue' when the API errors" || ok
# The cache answers without a second API call (one probe per slug per tick).
MC_QUEUE_TTL=300; : > "$T/gh-calls.txt"
mc_queue_enabled example-org/queued-os >/dev/null
grep -q 'rulesets' "$T/gh-calls.txt" && bad "a cached probe must not re-hit the rulesets API within the tick" || ok
# The settle is safe to run twice — only ONE deploy is ever enqueued.
# The merge sha comes off the PR read itself now (`.merge_commit_sha`, BH-784),
# so the fixture has to present a MERGED PR or there is honestly nothing to
# deploy and the settle says so instead of enqueuing a blank train.
: > "$T/deployreq.txt"; : > "$T/issue-calls.txt"; echo merged > "$T/mode"
mc_settle_merged 'example-org/queued-os#11' https://github.com/example-org/queued-os/pull/11 queued example-org/queued-os ticket/qs-11 "$T/h/builds/pool-queued-QS-11-202609120001" - >/dev/null
mc_settle_merged 'example-org/queued-os#11' https://github.com/example-org/queued-os/pull/11 queued example-org/queued-os ticket/qs-11 "$T/h/builds/pool-queued-QS-11-202609120001" - >/dev/null
[ "$(wc -l < "$T/deployreq.txt" | tr -d ' ')" = 1 ] && ok || bad "a settle that runs twice must enqueue exactly ONE deploy (got $(cat "$T/deployreq.txt"))"
# QUEUED is a first-class state with its own age budget.
grep -qw QUEUED <<<"$MC_STATES" && ok || bad "QUEUED must be in MC_STATES"
[ "$(mc_budget QUEUED)" -gt 0 ] 2>/dev/null && ok || bad "QUEUED must have an age budget (got '$(mc_budget QUEUED)')"
# The classifier: isInMergeQueue wins over BOTH the CLEAN and the BLOCKED lines.
MC_INQUEUE=1
[ "$(mc_classify OPEN CLEAN MERGEABLE "$H1" "$H1" APPROVE claude green 0 0 0 0 - | cut -f1)" = QUEUED ] && ok || bad "CLEAN + isInMergeQueue must classify QUEUED, never READY"
[ "$(mc_classify OPEN BLOCKED MERGEABLE "$H1" "$H1" APPROVE claude green 0 0 0 0 - | cut -f1)" = QUEUED ] && ok || bad "BLOCKED + isInMergeQueue must classify QUEUED, never WAIT_CI"
MC_INQUEUE=0
[ "$(mc_classify OPEN CLEAN MERGEABLE "$H1" "$H1" APPROVE claude green 0 0 0 0 - | cut -f1)" = READY ] && ok || bad "without isInMergeQueue the classifier is unchanged"

echo "merge-queue-native-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
