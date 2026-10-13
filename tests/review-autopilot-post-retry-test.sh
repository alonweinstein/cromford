#!/bin/bash
# tests/review-autopilot-post-retry-test.sh — BH-1018: the >12h review autopilot
# must never pay for the same review twice.
#
# THE SPEND THIS PINS. bin/review-autopilot.sh buys one Fable review per aging
# PR head and wrote its dedup key ONLY after `gh pr comment` succeeded, and
# wrote nothing at all when the model came back empty. Both non-success exits
# therefore left the guard false, so the next hourly tick re-bought a review
# that had already been paid for. The Mac-side runaway-spend audit of
# 2026-09-17..19 measured it: 156 of 372 review spends were re-buys, one PR 16
# times. Fleet rule: ~/.claude/rules/metered-api-dedup.md — a PERSISTED check
# before the billable call, three outcomes (ok / empty / failed), empty is
# billed and TERMINAL, and terminal state on every non-success path.
#
# WHAT IS ASSERTED, and all of it on what a RUN DID — the real script against a
# scratch $HARNESS with gh, agent-call and beat stubbed. Nothing here greps the
# source of bin/review-autopilot.sh; a branch no tick can reach would pass a
# grep just as happily.
#
#   1. A failed post caches: the key file lands in `status=reviewed-unposted`
#      with the full comment body in a `.body` sibling, BEFORE the post is
#      attempted, and exactly one model call was made.
#   2. The next tick re-posts from that cache: still one model call, the posted
#      bytes are the cached bytes, the key's first line becomes the mirror
#      format, the cache is dropped and the daily cap counted the spend ONCE.
#   3. The key is NOT the conductor's read any more (BH-1951, spec change):
#      mc_autopilot_verdict reads NOTHING off the posted key file (it reads rows)
#      nor off an unposted one — an unposted review is not a verdict the PR carries.
#   4. An empty model answer is billed and counted: once -> `empty … n=1`,
#      twice -> `empty-terminal`, and the third tick makes no call at all.
#   5. A posted head is never re-reviewed, and a cache that is gone falls back
#      to a fresh (counted) review rather than posting nothing.
#
# Run from anywhere: bash tests/review-autopilot-post-retry-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
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

# ONE clock read for the whole file (bin/test-determinism-lint.sh): the PR's
# created_at is derived from it, so "older than the 12h cutoff" is true by
# construction whatever the wall clock says.
NOW=$(date -u +%s)
CREATED=$(date -u -d "@$((NOW - 86400))" '+%Y-%m-%dT%H:%M:%SZ')
DAY=$(date -u -d "@$NOW" '+%Y%m%d')

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env" "$H/state" "$T/fakebin"
cp "$DIR/bin/review-autopilot.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh and
# exits on a missing module — the fixture must carry the modules too.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
: > "$H/env/global.env"
# BH-1510.1: this lane's model is a model_routes row, read through review_model;
# this worker-less box carries the resolver's cache of #1507's table.
cp "$DIR/bin/lib/review-model.sh" "$H/bin/lib/"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1

SHA=aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddd
HEAD12=${SHA:0:12}
KEY="$H/state/review-autopilot/o-p1-7-$HEAD12"
CNTF="$H/state/review-autopilot/count-p1-$DAY"

# The one open PR every tick sees: harness-authored, non-draft, a day old.
jq -n --arg sha "$SHA" --arg c "$CREATED" \
  '[{number:7,html_url:"https://github.com/o/p1/pull/7",title:"BH-x: a thing",
     body:"Closes #7",head:{sha:$sha,ref:"ticket/x"},base:{ref:"main"},
     draft:false,user:{login:"operator",type:"User"},created_at:$c,updated_at:$c,
     merged_at:null,closed_at:null,labels:[],state:"open"}]' > "$T/pulls.json"

# --- the stubs --------------------------------------------------------------
# Every gh call is recorded and every posted comment is kept, so "did this tick
# post, and what bytes" is a fact about the run rather than a reading of a log.
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
if [ "${1:-}" = pr ] && [ "${2:-}" = comment ]; then
  BF=""
  while [ $# -gt 0 ]; do [ "$1" = --body-file ] && BF="${2:-}"; shift; done
  if [ -f "$T/gh-comment-fails" ]; then
    echo "gh: the comment could not be posted (HTTP 502)" >&2; exit 1
  fi
  cat "$BF" >> "$T/posted.txt"; echo post >> "$T/post-count.txt"; exit 0
fi
case "$*" in
  api\ repos/o/p1/pulls*|*repos/o/p1/pulls\?*)
    # TEST-CHANGE (BH-782): the open-PR list is a REST read through
    # bin/lib/gh-rest.sh now (`gh api -i -X GET ...`), so the argv carries -i
    # and the answer needs the status line the library parses. Same fixture.
    case "$*" in *" -i "*) printf 'HTTP/2.0 200 OK\r\n\r\n' ;; esac
    cat "$T/pulls.json" ;;
  *"pr diff"*--name-only*)  printf 'bin/x.sh\n' ;;
  *"pr diff"*)              printf 'diff --git a/bin/x.sh b/bin/x.sh\n+echo hi\n' ;;
  *"pr view"*--json\ body*) printf 'Closes #7\n' ;;
  *"pr view"*)              printf 'mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS\n' ;;
  *)                        : ;;
esac
exit 0
EOF
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"

# THE BILLABLE CALL. Its argv is appended, so the count of spends is a file.
{ printf '#!/bin/bash\nT=%q\n' "$T"; cat <<'EOF'
printf '%s\n' "$*" >> "$T/agent-calls.txt"
# K3: the call-guard key the lane hands bin/agent-call.sh, one line per call.
printf '%s\n' "${AGENT_CALL_FP:-}" >> "$T/agent-call-fps.txt"
printf '%s\n' "${AGENT_CALL_GUARD_STAGE:-}" >> "$T/agent-call-stages.txt"
cat "$T/model-out" > "$5"
exit 0
EOF
} > "$H/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh"

printf 'Nothing load-bearing was deferred; the diff does what the body says.\n\nVERDICT: MERGE — reads fine\n' > "$T/model-out"
: > "$T/gh-calls.txt"; : > "$T/posted.txt"; : > "$T/post-count.txt"
: > "$T/agent-calls.txt"; : > "$T/run.log"

RUN() { ( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN="" \
          bash "$H/bin/review-autopilot.sh" >>"$T/run.log" 2>&1 ) || true; }
# `wc -l <`, not `grep -c`: grep exits 1 on a file with no matches, and the
# `|| echo 0` that would cover that prints a SECOND count.
CALLS()  { wc -l < "$T/agent-calls.txt" 2>/dev/null | tr -d ' '; }
POSTS()  { wc -l < "$T/post-count.txt" 2>/dev/null | tr -d ' '; }
CAP()    { cat "$CNTF" 2>/dev/null || echo 0; }
RESET()  { scratch_rm "$H/state/review-autopilot"
           : > "$T/agent-calls.txt"; : > "$T/posted.txt"; : > "$T/post-count.txt"
           : > "$T/gh-calls.txt"; rm -f "$T/gh-comment-fails"; }

# ============================================================================
# 1. The post fails -> the review is CACHED, not thrown away
# ============================================================================
RESET
touch "$T/gh-comment-fails"
RUN
[ "$(CALLS)" = 1 ] && ok || bad "the first tick must buy exactly one review (calls=$(CALLS))"
[ "$(POSTS)" = 0 ] && ok || bad "a failing gh must post nothing (posts=$(POSTS))"
[ -f "$KEY" ] && ok || bad "a failed post must still leave the head-keyed state file $KEY"
head -1 "$KEY" 2>/dev/null | grep -q '^status=reviewed-unposted ' && ok \
  || bad "the key's first line must say reviewed-unposted (got '$(head -1 "$KEY" 2>/dev/null)')"
[ -s "$KEY.body" ] && ok || bad "the full comment body must be cached at $KEY.body"
grep -q "harness-review-autopilot $HEAD12" "$KEY.body" 2>/dev/null && ok \
  || bad "the cached body must carry the head-bound marker"
grep -q 'VERDICT: MERGE' "$KEY.body" 2>/dev/null && ok \
  || bad "the cached body must carry the model's verdict line"
[ "$(CAP)" = 1 ] && ok || bad "the daily cap must count the spend that failed to post (cap=$(CAP))"
cp "$KEY.body" "$T/cached-body"

# ============================================================================
# 2. The next tick RE-POSTS from the cache and buys nothing
# ============================================================================
rm -f "$T/gh-comment-fails"
RUN
[ "$(CALLS)" = 1 ] && ok || bad "the retry tick must make NO model call (calls=$(CALLS))"
[ "$(POSTS)" = 1 ] && ok || bad "the retry tick must post exactly once (posts=$(POSTS))"
cmp -s "$T/cached-body" "$T/posted.txt" && ok \
  || bad "the posted bytes must be the cached bytes"
head -1 "$KEY" 2>/dev/null | grep -qE '^reviewed .* verdict=MERGE$' && ok \
  || bad "a posted review's first line must be the mirror format (got '$(head -1 "$KEY" 2>/dev/null)')"
[ -f "$KEY.body" ] && bad "the cache must be dropped once the comment is up" || ok
[ "$(CAP)" = 1 ] && ok || bad "a review that needed two ticks must count ONE spend (cap=$(CAP))"

# A posted head is never reviewed again — the guard that already worked.
RUN
[ "$(CALLS)" = 1 ] && ok || bad "a posted head must never be re-reviewed (calls=$(CALLS))"
[ "$(POSTS)" = 1 ] && ok || bad "a posted head must never be re-commented (posts=$(POSTS))"

# ============================================================================
# 3. The key file is not the conductor's read (BH-1951)
# ============================================================================
APV() { ( HARNESS="$H" PATH="$T/fakebin:$PATH"
          # shellcheck source=/dev/null
          . "$H/bin/lib/gh-pr-list.sh"
          # shellcheck source=/dev/null
          . "$H/bin/lib/merge-conductor-lib.sh"; mc_init
          mc_autopilot_verdict o/p1 7 'o/p1#7' "$SHA" ) 2>/dev/null; }
# A lib that does not LOAD prints nothing, and "nothing" is also what a correct
# refusal prints — so every assertion below would pass for the wrong reason, or
# fail without saying why. This names which one it is. (#1050 lost a CI round to
# exactly that: the BH-680 shim `exit 1`s on a missing bin/lib/mc module, and
# APV's 2>/dev/null ate the line that said so.)
if ( HARNESS="$H"
     # shellcheck source=/dev/null
     . "$H/bin/lib/gh-pr-list.sh"
     # shellcheck source=/dev/null
     . "$H/bin/lib/merge-conductor-lib.sh"
     type mc_autopilot_verdict >/dev/null 2>&1 ) >/dev/null 2>&1; then ok
else bad "the conductor lib does not load in this fixture — mc_autopilot_verdict is undefined, so the mirror assertions below read as 'no verdict' (BH-680: merge-conductor-lib.sh is a shim that exits on a missing bin/lib/mc module)"; fi
# TEST-CHANGE (BH-1951): mc_autopilot_verdict no longer reads the key FILE; it
# reads the source=box row the lane POSTs before the `reviewed` write, then the
# PR comment. This worker-less rig posts no row ("not configured"), so the posted
# key alone answers nothing. The row path: tests/verdict-files-retired.bh-1951-test.sh.
[ -z "$(APV)" ] && ok || bad "mc_autopilot_verdict must not read the posted key file (got '$(APV)')"
cp "$KEY" "$T/posted-key"
printf 'status=reviewed-unposted 2026-09-19 00:00:00Z verdict=MERGE tries=1\n' > "$KEY"
[ -z "$(APV)" ] && ok || bad "an UNPOSTED review must not be claimed as a verdict (got '$(APV)')"
cp "$T/posted-key" "$KEY"

# ============================================================================
# 4. Empty is billed: once counted, twice terminal, never a third call
# ============================================================================
RESET
: > "$T/model-out"
RUN
[ "$(CALLS)" = 1 ] && ok || bad "the first empty answer is one spend (calls=$(CALLS))"
head -1 "$KEY" 2>/dev/null | grep -qE '^empty .* n=1$' && ok \
  || bad "an empty answer must write terminal-track state (got '$(head -1 "$KEY" 2>/dev/null)')"
[ "$(CAP)" = 1 ] && ok || bad "an empty answer is billed and must be capped (cap=$(CAP))"
RUN
[ "$(CALLS)" = 2 ] && ok || bad "one retry of an empty answer is allowed (calls=$(CALLS))"
head -1 "$KEY" 2>/dev/null | grep -q '^empty-terminal ' && ok \
  || bad "two empty answers must be terminal (got '$(head -1 "$KEY" 2>/dev/null)')"
RUN
[ "$(CALLS)" = 2 ] && ok || bad "a terminal empty must never buy a third review (calls=$(CALLS))"
[ "$(POSTS)" = 0 ] && ok || bad "an empty review must never be posted (posts=$(POSTS))"
[ "$(APV)" = "" ] && ok || bad "an empty-terminal key must claim no verdict (got '$(APV)')"

# ============================================================================
# 5. A cache that is gone re-buys rather than posting nothing
# ============================================================================
RESET
printf 'Findings.\n\nVERDICT: BLOCK — a hardcoded model string\n' > "$T/model-out"
touch "$T/gh-comment-fails"
RUN
rm -f "$KEY.body"
rm -f "$T/gh-comment-fails"
RUN
[ "$(CALLS)" = 2 ] && ok || bad "an unposted key with no cached body must re-review (calls=$(CALLS))"
[ "$(POSTS)" = 1 ] && ok || bad "the re-review must post (posts=$(POSTS))"
grep -q 'VERDICT: BLOCK' "$T/posted.txt" && ok || bad "the posted comment must carry the verdict"
head -1 "$KEY" 2>/dev/null | grep -qE '^reviewed .* verdict=BLOCK$' && ok \
  || bad "the re-review must land in the mirror format (got '$(head -1 "$KEY" 2>/dev/null)')"
[ "$(CAP)" = 2 ] && ok || bad "two real reviews are two spends (cap=$(CAP))"

# K3: every review this lane buys names its work to the pre-call guard as
# THIS PR at THIS head, so the D1 counter (not the lane's own marker file) is
# what stops a re-buy after a wipe.
# TEST-CHANGE (BH-3930, spec change): the key is the shared per-head fp
# `review:<slug>#<n>@<sha>` (bin/lib/review-bought.sh's review_fp), no longer
# the lane-private `review-autopilot:` prefix, and it is claimed under stage
# review-head (K=1), so two review lanes on one head share one claim.
grep -qvxF "review:o/p1#7@$SHA" "$T/agent-call-fps.txt" 2>/dev/null \
  && bad "a review was bought without its PR+head call-guard key: $(sort -u "$T/agent-call-fps.txt" 2>/dev/null | tr '\n' ' ')" || ok
[ -s "$T/agent-call-fps.txt" ] && ok || bad "no review recorded a call-guard key at all"
grep -qvxF review-head "$T/agent-call-stages.txt" 2>/dev/null \
  && bad "a review was bought outside guard stage review-head: $(sort -u "$T/agent-call-stages.txt" 2>/dev/null | tr '\n' ' ')" || ok
[ -s "$T/agent-call-stages.txt" ] && ok || bad "no review recorded a guard stage at all"

echo "review-autopilot-post-retry: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
