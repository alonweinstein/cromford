#!/bin/bash
# tests/lead-reviews-console.bh-4957-test.sh — the Mission Control /lead-reviews
# screen and the PR screen's "Lead review failed" line (BH-4957, BH-4950.4).
#
# WHY A SHELL SUITE AS WELL. The screen is proved by node --test in
# console-ui/tests/lead-reviews.bh-4957.test.js (reached through the console-ui
# job). This file is the part the impact lane and the orphan ratchet can SEE:
# it names the new sources by path, drives the pure half for real, and holds
# the screen to the rules a reviewer would otherwise check by eye
# (the cost-breaker-console.bh-2331 pattern).
#
#   1. lib/lead-reviews.js, DRIVEN: drift counts reconcile events only and says
#      when its page was full; a failure counts only on the PR's live head;
#      limit input is refused, never clamped; no auto-repo knob is null.
#   2. LeadReviews.js uses the shared SortableTable and the in-app useConfirm,
#      is routed at /lead-reviews and linked from /kanban, and never calls a
#      native dialog.
#   3. the node suite, run for real when the console-ui dependencies are installed.
# Run from anywhere: tests/lead-reviews-console.bh-4957-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/console-ui/src/lib/lead-reviews.js"
SCREEN="$DIR/console-ui/src/screens/LeadReviews.js"
APP="$DIR/console-ui/src/app.js"
KANBAN="$DIR/console-ui/src/screens/Kanban.js"
VERDICTS="$DIR/console-ui/src/ui/PRVerdicts.js"

for f in "$LIB" "$SCREEN" "$APP" "$KANBAN" "$VERDICTS"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

command -v node >/dev/null 2>&1 || { echo "lead-reviews-console: SKIPPED — node is not installed on this box"; exit 0; }

# --- 1: the lib, driven -----------------------------------------------------
OUT=$(node --input-type=module -e "
import { driftCount, leadReviewFailure, failedRows, parseLimit, autoReposFrom, sinceIso, prOfJob,
         SPEND_KEY, CONCURRENCY_KEY } from '$LIB';
const eq = (name, got, want) =>
  console.log((JSON.stringify(got) === JSON.stringify(want) ? 'ok ' : 'no ') + name + ' got=' + JSON.stringify(got));
const A = 'a'.repeat(40), O = '0'.repeat(40);

eq('keys', [SPEND_KEY, CONCURRENCY_KEY], ['lead_review.daily_spend_usd', 'lead_review.concurrency']);
eq('drift-reconcile-only', driftCount([{ reason: 'reconcile' }, { reason: 'webhook' }, {}], 1000), { n: 1, capped: false });
eq('drift-capped', driftCount([{ reason: 'reconcile' }, { reason: 'x' }], 2), { n: 1, capped: true });
eq('fail-live', leadReviewFailure({ liveHead: A, number: 5, gateRow: { number: 5, review_failed_sha: A }, failedRequests: [] }), { detail: null, job_id: null });
eq('fail-old-head', leadReviewFailure({ liveHead: A, number: 5, gateRow: { number: 5, review_failed_sha: O }, failedRequests: [] }), null);
eq('fail-other-pr', leadReviewFailure({ liveHead: A, number: 5, gateRow: null, failedRequests: [{ status: 'failed', pr: 6, head_sha: A }] }), null);
eq('fail-short-head', leadReviewFailure({ liveHead: 'aaaaaaaaaaaa', number: 5, gateRow: { number: 5, review_failed_sha: A }, failedRequests: [] }), null);
eq('failed-rows', failedRows([{ repo: 'o/r', number: 1, head: A, review_failed_sha: A }, { repo: 'o/r', number: 2, head: A, review_failed_sha: O }],
  [{ repo: 'o/r', pr: 1, head_sha: A, status: 'failed', detail: 'd', job_id: 'j' }]).map((r) => [r.number, r.detail, r.job_id]), [[1, 'd', 'j']]);
eq('limit-spend-neg', parseLimit('spend', '-1').ok, false);
eq('limit-spend-junk', parseLimit('spend', 'abc').ok, false);
eq('limit-spend-ok', parseLimit('spend', '12.5'), { ok: true, value: 12.5 });
eq('limit-conc-zero', parseLimit('concurrency', '0').ok, false);
eq('limit-conc-frac', parseLimit('concurrency', '1.5').ok, false);
eq('repos-none', autoReposFrom({ lanes: [] }), null);
eq('repos', autoReposFrom({ lanes: [{ id: 'lead-review-land', knobs: [{ env: 'LEAD_REVIEW_AUTO_REPOS', default: 'a/b c/d' }] }] }), ['a/b', 'c/d']);
eq('since', sinceIso(Date.parse('2026-10-07T12:00:00.500Z')), '2026-10-06T12:00:00Z');
eq('job-pr', [prOfJob({ ticket_id: 'lr-41-0123456789ab' }), prOfJob({ ticket_id: 'BH-1' })], [41, null]);
" 2>&1)
while IFS= read -r line; do
  case "$line" in
    ok\ *) ok ;;
    no\ *) bad "lib: ${line#no }" ;;
    *) [ -n "$line" ] && bad "lib: unexpected output: $line" ;;
  esac
done <<< "$OUT"

# --- 2: the screen's shape --------------------------------------------------
grep -q "from '../ui/SortableTable.js'" "$SCREEN" && ok || bad "LeadReviews.js must use the shared SortableTable"
grep -q "useConfirm" "$SCREEN" && ok || bad "LeadReviews.js must edit limits through the in-app useConfirm modal"
grep -q "\['/lead-reviews', LeadReviewsScreen\]" "$APP" && ok || bad "app.js must route /lead-reviews"
grep -q 'to="/lead-reviews"' "$KANBAN" && ok || bad "Kanban.js must link to /lead-reviews"
grep -q "export function LeadReviewFailedLine" "$VERDICTS" && ok || bad "PRVerdicts.js must export LeadReviewFailedLine"
CODE=$(grep -hvE '^[[:space:]]*//' "$SCREEN" "$LIB")
if [[ "$CODE" =~ (window\.)?(confirm|alert|prompt)[[:space:]]*\([[:space:]]*[\'\"\`] ]]; then
  bad "a native dialog in the lead reviews screen"
else
  ok
fi

# --- 3: the node suite, driven -----------------------------------------------
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "lead-reviews-console: node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/lead-reviews.bh-4957.test.js 2>&1); then ok
  else bad "console-ui/tests/lead-reviews.bh-4957.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error' | head -20
  fi
fi

echo "lead-reviews-console: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
