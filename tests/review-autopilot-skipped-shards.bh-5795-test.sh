#!/bin/bash
# tests/review-autopilot-skipped-shards.bh-5795-test.sh — BH-5795: the review
# autopilot never BLOCKs a PR only because its CI test jobs were skipped.
#
# WHY. All 22 `ci-tests-skipped` BLOCKs (#4189..#5395) came from this lane. On
# a base of main, skipped test jobs are the design: the merge-queue batch runs
# the PR's impact set on the tree that lands. On another base, bin/ci-plan.sh
# now plans the impact set against main, and the lead-review enqueue starts a
# run for a held head. So:
#
#   A1  base main, every test job SKIPPED, the model BLOCKs for that alone: the
#       posted comment and the ledger say MERGE-WITH-NOTES, never BLOCK; the
#       prompt carries the skipped-test rule and the relabelled CI state
#   A2  base main, a BLOCK that names a real finding as well: still BLOCK
#   A3  a stacked base (ticket/parent), a skip-only BLOCK: STAYS BLOCK (the
#       queue does not test a merge into a ticket base; lead review of #5805),
#       and the prompt says the base is not main
#   A4  base main: one-clause BLOCKs about something else that only USE the
#       words skip / not tested / not run / not checked stay BLOCK (the eight
#       reasons the lead and Fable reviews of #5805 showed being downgraded)
#   A5  base main, a skip-only reason, but a check FAILED: stays BLOCK
#   A6  base main, a reason that names the skipped job ("Tests, traced"):
#       MERGE-WITH-NOTES
#   A7  base main, a skip-only VERDICT line but a [BLOCK] finding in the body:
#       stays BLOCK (lead review of 973ce2e9, note on review-autopilot.sh:929)
#
# The REAL lane in a scratch $HARNESS with the review-autopilot.bh-2310 rig
# (gh, agent-call and beat stubbed). The model's answer is a fixture file.
# Run from anywhere: bash tests/review-autopilot-skipped-shards.bh-5795-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
CREATED=$(date -u -d "@$((NOW - 86400))" '+%Y-%m-%dT%H:%M:%SZ')
DAY=$(date -u -d "@$NOW" '+%Y%m%d')
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env" "$H/state" "$T/fakebin"
# The lane and everything it sources (bin/lib/merge-conductor-lib.sh and its
# bin/lib/mc/ modules included), plus the fleet reader the conductor lib reads.
scratch_install_closure bin/review-autopilot.sh "$H" >/dev/null || { echo "FAIL: closure of bin/review-autopilot.sh"; exit 1; }
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || { echo "FAIL: closure of bin/fleet-conf.sh"; exit 1; }
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
: > "$H/env/global.env"
# BH-1510.1: this lane's model is a model_routes row, read through review_model;
# this worker-less box carries the resolver's cache of #1507's table.
scratch_install_closure bin/lib/review-model.sh "$H" >/dev/null || { echo "FAIL: closure of bin/lib/review-model.sh"; exit 1; }
scratch_install_closure bin/lib/patch-same.sh "$H" >/dev/null || { echo "FAIL: closure of bin/lib/patch-same.sh"; exit 1; }
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1

STATE="$H/state/review-autopilot"
CNTF="$STATE/count-p1-$DAY"
RLOG="$H/logs/review-autopilot.log"
ALOG="$H/logs/ALERTS.log"

# The one open PR every tick sees: harness-authored, non-draft, a day old.
pulls_for() { jq -n --arg sha "$1" --arg c "$CREATED" \
  --arg b "${2:-main}" '[{number:7,html_url:"https://github.com/o/p1/pull/7",title:"BH-x: a thing",
     body:"Closes #7",head:{sha:$sha,ref:"ticket/x"},base:{ref:$b},
     draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
     merged_at:null,closed_at:null,labels:[],state:"open"}]' > "$T/pulls.json"; }

# --- the stubs --------------------------------------------------------------
# Every gh call is recorded and every posted comment is kept, so "did this tick
# post, how many times, and what bytes" is a fact about the run.
#
#   $T/gh-comment-fails          -> `gh pr comment` exits 1 and posts NOTHING
#   $T/gh-comment-lands-nonzero  -> it POSTS and THEN exits 1 (defect 3)
#   $T/gh-api-comments-fails     -> the issue-comments read exits 1
#   $T/gh-pulls-fails            -> the open-PR list fails on EVERY rung it has
#                                   (the REST pulls page AND the per-author
#                                   `gh pr list` fallback bin/lib/gh-pr-list.sh
#                                   drops to). Failing only the REST page is not
#                                   a failed list — the fallback then answers
#                                   "no open PRs", which is a different fact.
#   $T/comments.json             -> what the comments read answers (else [])
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  BF=""
  while [ $# -gt 0 ]; do [ "$1" = --body-file ] && BF="${2:-}"; shift; done
  if [ -f "$T/gh-comment-fails" ]; then
    echo "gh: the comment could not be posted (HTTP 502)" >&2; exit 1
  fi
  cat "$BF" >> "$T/posted.txt"; echo post >> "$T/post-count.txt"
  # The shape that made this ticket: the comment IS on the PR and gh still
  # exits nonzero (a 502 on the response read, a token that expired after the
  # write). The caller cannot tell the two failures apart from the rc alone.
  [ -f "$T/gh-comment-lands-nonzero" ] && { echo "gh: HTTP 502 reading the response" >&2; exit 1; }
  exit 0
fi
if [ "${1:-}" = pr ] && [ "${2:-}" = list ] && [ -f "$T/gh-pulls-fails" ]; then
  echo "gh: HTTP 502" >&2; exit 1
fi
case "$*" in
  api\ repos/o/p1/issues/7/comments*)
    [ -f "$T/gh-api-comments-fails" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    if [ -f "$T/comments.json" ]; then cat "$T/comments.json"; else printf '[]\n'; fi ;;
  *repos/o/p1/pulls/7)
    # The per-PR read the drain earns its delete with, answered the way
    # bin/lib/gh-rest.sh drives it (`gh api -i`: status line, blank line, body).
    # It is a DIFFERENT fact from the open-PR list — the list can come back
    # short with rc 0, this cannot. `gh-pulls-fails` takes the whole pulls
    # endpoint down with it, and a 5xx is rc 75 ("we could not look").
    if [ -f "$T/gh-pulls-fails" ] || [ -f "$T/gh-pr7-fails" ]; then
      printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{"message":"Bad gateway"}\n'; exit 0
    fi
    printf 'HTTP/2.0 200 OK\r\n\r\n'
    if [ -f "$T/pr-7.json" ]; then cat "$T/pr-7.json"; else printf '{"number":7,"state":"open","merged_at":null}\n'; fi ;;
  api\ repos/o/p1/pulls*|*repos/o/p1/pulls\?*)
    # TEST-CHANGE (BH-782): the open-PR list is a REST read through
    # bin/lib/gh-rest.sh now (`gh api -i -X GET ...`), so the argv carries -i
    # and the answer needs the status line the library parses. `gh-pulls-fails`
    # still takes the list down — as the 502 the library classifies, which is
    # the same fact the bare rc 1 was.
    if [ -f "$T/gh-pulls-fails" ]; then
      case "$*" in
        *" -i "*) printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{"message":"Bad gateway"}\n'; exit 0 ;;
      esac
      echo "gh: HTTP 502" >&2; exit 1
    fi
    case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac
    cat "$T/pulls.json" ;;
  *"pr diff"*--name-only*)  printf 'bin/x.sh\n' ;;
  *"pr diff"*)              printf 'diff --git a/bin/x.sh b/bin/x.sh\n+echo hi\n' ;;
  *"pr view"*--json\ body*) printf 'Closes #7\n' ;;
  *"pr view"*)              cat "$T/cistate" ;;
  *)                        : ;;
esac
exit 0
EOF
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"

# THE BILLABLE CALL. Its argv is appended (so the count of spends is a file) and
# its exit code is whatever $T/agent-rc says — the whole point of item 1.
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/agent-calls.txt"
cp "${6#@}" "$T/prompt.txt" 2>/dev/null
cat "$T/model-out" > "$5"
exit "$(cat "$T/agent-rc" 2>/dev/null || echo 0)"
EOF
} > "$H/bin/agent-call.sh"
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "${1:-}" >> "$T/beats.txt"
exit 0
EOF
} > "$H/bin/beat.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh"

GOOD_REVIEW='Nothing load-bearing was deferred; the diff does what the body says.

VERDICT: MERGE — reads fine'

PT=6
RUN() { ( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN="" \
          REVIEW_AUTOPILOT_POST_TRIES="$PT" REPOS_ROOT="${REPOS:-$T/repos}" \
          bash "$H/bin/review-autopilot.sh" >>"$T/run.log" 2>&1 ) || true; }
# `wc -l <`, not `grep -c`: grep exits 1 on a file with no matches, and the
# `|| echo 0` that would cover that prints a SECOND count.
CALLS()  { wc -l < "$T/agent-calls.txt" 2>/dev/null | tr -d ' '; }
POSTS()  { wc -l < "$T/post-count.txt" 2>/dev/null | tr -d ' '; }
CAP()    { cat "$CNTF" 2>/dev/null || echo 0; }
K1()     { head -1 "$KEY" 2>/dev/null; }
# Lines, never `grep -c` (same reason), and fixed-string so a scratch path full
# of dots cannot match something it does not equal.
COUNTF() { grep -cF -- "$2" "$1" 2>/dev/null || true; }
APV() { ( HARNESS="$H" PATH="$T/fakebin:$PATH"
          # shellcheck source=/dev/null
          . "$H/bin/lib/gh-pr-list.sh"
          # shellcheck source=/dev/null
          . "$H/bin/lib/merge-conductor-lib.sh"; mc_init
          mc_autopilot_verdict o/p1 7 'o/p1#7' "$1" ) 2>/dev/null; }
RESET()  { scratch_rm "$STATE"
           PT=6
           printf '0\n' > "$T/agent-rc"
           printf '%s\n' "$GOOD_REVIEW" > "$T/model-out"
           : > "$T/agent-calls.txt"; : > "$T/posted.txt"; : > "$T/post-count.txt"
           : > "$T/gh-calls.txt"; : > "$T/beats.txt"; : > "$RLOG"; : > "$ALOG"
           rm -f "$T/gh-comment-fails" "$T/gh-comment-lands-nonzero" \
                 "$T/gh-api-comments-fails" "$T/gh-pulls-fails" "$T/comments.json" \
                 "$T/gh-pr7-fails" "$T/pr-7.json"; }



KEYOF() { printf '%s/o-p1-7-%s' "$STATE" "${1:0:12}"; }
: > "$T/run.log"
R=1111111111111111111111111111111111111111
printf 'mergeable=MERGEABLE mergeState=CLEAN checks=Syntax + shellcheck + config integrity=SUCCESS, CI plan (what this run tests)=SKIPPED, Tests, traced (shard 0/1)=SKIPPED, Pure-logic gate fixtures=SKIPPED\n' > "$T/cistate"
SKIP_BLOCK='CI did not test this diff: every test job is SKIPPED on this head.

VERDICT: BLOCK — CI ran none of the test suites on this head'
REAL_BLOCK='1. A stray generated file is in the diff (worker/jobs/src/routes.gen.js:1).

VERDICT: BLOCK — a stray generated routes.gen.js must be removed, and no test ran on this head'
VLINE() { grep -E '^VERDICT:' "$T/posted.txt" | tail -1; }

# ---- A1: base main, a skip-only BLOCK
RESET; printf '%s\n' "$SKIP_BLOCK" > "$T/model-out"; pulls_for "$R" main; REPOS="$T/no-repos" RUN
[ "$(CALLS)" = 1 ] && [ "$(POSTS)" = 1 ] && ok || bad "A1 calls=$(CALLS) posts=$(POSTS) [$(tail -3 "$RLOG")]"
grep -q 'VERDICT: BLOCK' "$T/posted.txt" && bad "A1 a skip-only BLOCK on a main-based head was posted: $(VLINE)" || ok
case "$(VLINE)" in "VERDICT: MERGE-WITH-NOTES"*) ok ;; *) bad "A1 the posted verdict must be MERGE-WITH-NOTES: '$(VLINE)'" ;; esac
[[ "$(head -1 "$(KEYOF "$R")" 2>/dev/null)" =~ verdict=MERGE-WITH-NOTES$ ]] && ok || bad "A1 the ledger must say MERGE-WITH-NOTES: $(head -1 "$(KEYOF "$R")" 2>/dev/null)"
grep -q 'merge-queue batch runs' "$T/posted.txt" && ok || bad "A1 the comment must say the queue runs the suites"
grep -q 'Skipped-test rule' "$T/prompt.txt" 2>/dev/null && grep -q 'BY DESIGN' "$T/prompt.txt" && ok || bad "A1 the prompt must carry the skipped-test rule"
grep -q 'Tests, traced (shard 0/1)=SKIPPED (not a finding' "$T/prompt.txt" 2>/dev/null && ok || bad "A1 the prompt's CI state must mark the skipped jobs as not a finding"

# ---- A2: base main, a BLOCK with a real finding stays a BLOCK
RESET; printf '%s\n' "$REAL_BLOCK" > "$T/model-out"; pulls_for "$R" main; REPOS="$T/no-repos" RUN
case "$(VLINE)" in "VERDICT: BLOCK"*) ok ;; *) bad "A2 a BLOCK with a real finding must stay BLOCK: '$(VLINE)'" ;; esac
[[ "$(head -1 "$(KEYOF "$R")" 2>/dev/null)" =~ verdict=BLOCK$ ]] && ok || bad "A2 ledger: $(head -1 "$(KEYOF "$R")" 2>/dev/null)"

# ---- A3: a stacked base, a skip-only BLOCK stays BLOCK
RESET; printf '%s\n' "$SKIP_BLOCK" > "$T/model-out"; pulls_for "$R" ticket/parent; REPOS="$T/no-repos" RUN
case "$(VLINE)" in "VERDICT: BLOCK"*) ok ;; *) bad "A3 a skip-only BLOCK on a stacked head must stay BLOCK: '$(VLINE)'" ;; esac
grep -q 'base is ticket/parent, not main' "$T/prompt.txt" 2>/dev/null && ok || bad "A3 the prompt must say the base is not main"

# ---- A4: real one-clause BLOCKs that only use the words stay BLOCK
while IFS= read -r why; do
  [ -n "$why" ] || continue
  RESET; printf 'A finding.\n\nVERDICT: BLOCK — %s\n' "$why" > "$T/model-out"; pulls_for "$R" main; REPOS="$T/no-repos" RUN
  case "$(VLINE)" in "VERDICT: BLOCK"*) ok ;; *) bad "A4 '$why' must stay BLOCK: '$(VLINE)'" ;; esac
done <<'REASONS'
the curl exit code is not checked
the new resolver branch is not tested
case A3 was skipped to get green
the migration was not run against prod
authz not checked on /api/runs
the PR skips tests/bh-1234-test.sh to go green
no circuit breaker on the dispatch loop
new migration not tested against prod schema
REASONS

# ---- A5: a skip-only reason while a check FAILED stays BLOCK
printf 'mergeable=MERGEABLE mergeState=CLEAN checks=Syntax + shellcheck + config integrity=FAILURE, CI plan (what this run tests)=SKIPPED, Tests, traced (shard 0/1)=SKIPPED\n' > "$T/cistate"
RESET; printf '%s\n' "$SKIP_BLOCK" > "$T/model-out"; pulls_for "$R" main; REPOS="$T/no-repos" RUN
case "$(VLINE)" in "VERDICT: BLOCK"*) ok ;; *) bad "A5 a failed check keeps the BLOCK: '$(VLINE)'" ;; esac
printf 'mergeable=MERGEABLE mergeState=CLEAN checks=Syntax + shellcheck + config integrity=SUCCESS, CI plan (what this run tests)=SKIPPED, Tests, traced (shard 0/1)=SKIPPED, Pure-logic gate fixtures=SKIPPED\n' > "$T/cistate"

# ---- A6: the reason names the skipped job: downgraded
RESET; printf 'Nothing ran.\n\nVERDICT: BLOCK — every Tests, traced shard was SKIPPED on this head\n' > "$T/model-out"; pulls_for "$R" main; REPOS="$T/no-repos" RUN
case "$(VLINE)" in "VERDICT: MERGE-WITH-NOTES"*) ok ;; *) bad "A6 a reason naming the skipped job must downgrade: '$(VLINE)'" ;; esac

# ---- A7: a [BLOCK] finding in the body keeps the BLOCK
RESET; printf -- '- [BLOCK] bin/x.sh:12: the retry loop never ends.\n\nVERDICT: BLOCK — every Tests, traced shard was SKIPPED on this head\n' > "$T/model-out"; pulls_for "$R" main; REPOS="$T/no-repos" RUN
case "$(VLINE)" in "VERDICT: BLOCK"*) ok ;; *) bad "A7 a body [BLOCK] finding must keep the BLOCK: '$(VLINE)'" ;; esac

echo "review-autopilot-skipped-shards.bh-5795: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
