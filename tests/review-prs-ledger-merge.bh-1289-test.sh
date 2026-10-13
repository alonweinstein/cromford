#!/bin/bash
# tests/review-prs-ledger-merge.bh-1289-test.sh — the verdict write MERGES into
# the PR's ledger row instead of replacing it, so the `.ledger_sha` watermark
# BH-989 wrote earlier in the SAME tick survives the verdict.
#
# The defect: `.[$n] = {sha:$s, verdict:$v, tier:$t, served:$sv}` assigned a
# fresh object to the row. On a harness-authored, non-pipeline (hand) PR the
# dismissal pass runs first and watermarks the head; the verdict write then
# wiped it, so the next tick saw `DONE == SHA` but no `LEDGER_SHA`, paid for one
# more paginated `pulls/N/reviews` read, rewrote the watermark, and only the
# tick after that skipped. One free GitHub read per reviewed hand PR per head,
# every head, for ever.
#
# WHICH KEYS SURVIVE. Only the row's cross-tick, head-keyed caches:
# `ledger_sha` (BH-989) plus the CI-debounce bookkeeping (`deferred_sha`,
# `deferred_at`, `ci_alerted_sha`) that the sibling merged write
# (`rp_rehydrate_record`) already keeps. Everything else on the row was
# bookkeeping for the attempt that just ended — the in-flight marker, the
# no-verdict counter, the merge-retry counters — and is dropped exactly as
# before; G11 of tests/review-prs-gh-dedup-test.sh pins that the in-flight
# marker must not outlive the verdict, and case 4 below pins the merge-retry
# counters on this path.
#
# Every assertion is on the gh call log and the state file — never on the
# script's text (D3).
#
#   bash tests/review-prs-ledger-merge.bh-1289-test.sh      exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export TEST_ROOT="$T"
mkdir -p "$T/fakebin"

# ── the gh stub ───────────────────────────────────────────────────────────────
# Same construction as tests/review-prs-followups.bh-989-test.sh: `gh api`
# answers from a JSON fixture and applies the real `-q` filter with jq, so the
# lane's own jq is under test. Knob: RATE_LOW (the deferred dismissal pass).
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
printf '%s | %s\n' "${GH_TOKEN:-none}" "$*" >> "$TEST_ROOT/gh-calls.log"
if [ "${1:-}" = pr ]; then
  case "${2:-}" in
    list) printf '7\t%s\t%s\tChange under review\n' "${PR_HEAD:-S1}" "${PR_AUTHOR:-externaldev}"; exit 0 ;;
    diff) printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'; exit 0 ;;
    view)
      case "$*" in
        *--json\ state*) printf 'OPEN\n'; exit 0 ;;
        *--json\ mergeCommit*) printf '\n'; exit 0 ;;
      esac
      printf '## What\nSomething an outside author wrote.\n'
      exit 0 ;;
    review|comment)
      while [ $# -gt 0 ]; do
        if [ "$1" = --body ]; then printf '%s' "${2:-}" > "$TEST_ROOT/last-post-body.txt"; fi
        shift
      done
      exit 0 ;;
  esac
  exit 0
fi
if [ "${1:-}" = api ]; then
  shift
  Q=""; PATHARG=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -q|--jq) Q="${2:-}"; shift 2 ;;
      -X|--method) shift 2 ;;
      -f|-F|--field|--raw-field) shift 2 ;;
      --paginate|--slurp) shift ;;
      *) [ -z "$PATHARG" ] && PATHARG="$1"; shift ;;
    esac
  done
  emit() { if [ -n "$Q" ]; then printf '%s' "$1" | jq -r "$Q"; else printf '%s' "$1"; fi; }
  # The ledger gate asks for `…/reviews?per_page=100`; the dismissal pass asks
  # for `…/reviews`. Both are the same fixture, so the query string is dropped
  # before the match — a stub that answered only one of them would make the
  # rehydrate rung look absent and every case below buy a review.
  PATHARG="${PATHARG%%\?*}"
  case "$PATHARG" in
    rate_limit)
      # A LITERAL reset epoch: no wall-clock read (bin/test-determinism-lint.sh).
      case "${RATE_LOW:-0}" in
        1) REM=10 ;;
        *) REM=5000 ;;
      esac
      printf '{"resources":{"core":{"remaining":%s,"limit":5000,"reset":2000000000},"graphql":{"remaining":%s,"limit":5000,"reset":2000000000}}}\n' "$REM" "$REM"
      exit 0 ;;
    */reviews/*/dismissals) exit 0 ;;
    */pulls/*/reviews/*)
      emit "$(jq -c --argjson id "${PATHARG##*/}" '.[] | select(.id == $id)' "$TEST_ROOT/reviews.json")"
      exit 0 ;;
    */pulls/*/reviews)
      emit "$(cat "$TEST_ROOT/reviews.json")"
      exit 0 ;;
    */pulls/[0-9]*)
      # The PR body over REST (#891 round 1, Nit 6): the lane reads the pipeline
      # marker here, not through `gh pr view --json body` (GraphQL). No marker
      # in any case below — every PR here is a HAND PR the lane reviews itself.
      emit "$(jq -nc --arg b '## What
Something an outside author wrote.
' '{body:$b}')"
      exit 0 ;;
    *actions/runs*) exit 0 ;;
  esac
  exit 0
fi
exit 0
STUB

cat > "$T/fakebin/agent-call" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\n1. Something is wrong in a.ts:1 — fix it.\nTIER: %s\nVERDICT: %s\n' \
  "${AGENT_TIER:-2}" "${AGENT_VERDICT:-REQUEST_CHANGES}" > "$5"
printf 'claude\n' > "$5.runner"
STUB
chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call"

# ── the fixture harness tree ──────────────────────────────────────────────────
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() {
  rm -rf "$T/h"
  rm -f "$T/agent-calls.log" "$T/gh-calls.log" "$T/last-post-body.txt" "$T/reviews.json"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  cp "$T/fakebin/agent-call" "$T/h/bin/agent-call.sh"
  # BH-1510.1: the reviewer's model is a model_routes row, read through review_model;
  # this worker-less box carries the resolver's cache of #1507's table.
  cp "$DIR/bin/lib/review-model.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" tproj
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
  chmod +x "$T/h/bin/beat.sh"
  printf 'tproj o/tproj https://tproj.example.com /api/board 3 box-tproj 100.0.0.1\n' > "$T/h/fleet.conf"
  printf '[]\n' > "$T/reviews.json"
  printf '{}\n' > "$T/h/state/tproj.pr-reviews.json"
  # The rate-limit lib: without it on the box the dismissal read is never
  # deferred, and cases 2 and 3 need the deferred path (#891 round 1, Nit 7).
  cp "$DIR/bin/lib/gh-budget.sh" "$T/h/bin/lib/gh-budget.sh"
}

state_put() { printf '%s\n' "$1" > "$T/h/state/tproj.pr-reviews.json"; }

run_lane() {
  PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" \
    GH_TOKEN="${GH_TOKEN_FIXTURE:-ghp_default}" \
    PR_HEAD="${PR_HEAD:-S1}" PR_AUTHOR="${PR_AUTHOR:-externaldev}" \
    RATE_LOW="${RATE_LOW:-0}" GH_BUDGET_TTL_S=0 \
    AGENT_VERDICT="${AGENT_VERDICT:-REQUEST_CHANGES}" AGENT_TIER="${AGENT_TIER:-2}" \
    bash "$RP" tproj >/dev/null 2>&1
}

calls() { [ -f "$T/agent-calls.log" ] && wc -l < "$T/agent-calls.log" || echo 0; }
ghlog() { cat "$T/gh-calls.log" 2>/dev/null; }
ghgrep() { grep -c -F -- "$1" "$T/gh-calls.log" 2>/dev/null || true; }
# reads() counts every call whose path STARTS pulls/7/reviews — the dismissal
# list, a single review body, a dismissal PUT, and the ledger gate's own
# `?per_page=100` read. list_reads() counts the dismissal-pass LIST only.
reads() { ghgrep 'pulls/7/reviews'; }
list_reads() { ghgrep 'pulls/7/reviews --paginate'; }
st() { jq -r --arg k "$1" '.["7"][$k] // ""' "$T/h/state/tproj.pr-reviews.json" 2>/dev/null; }
# `st` reads a null the same as an absent key, so the "nothing was fabricated"
# assertion asks the row itself whether the key is there at all.
has() { jq -r --arg k "$1" '.["7"] | has($k)' "$T/h/state/tproj.pr-reviews.json" 2>/dev/null; }

# ── 1. the ticket's case: a reviewed hand PR keeps its watermark ──────────────
# Tick 1 dismisses nothing (no standing reviews), watermarks the head, and buys
# the review. Tick 2 must ask GitHub nothing at all: the watermark answers the
# dismissal gate and `.sha` answers the review gate. RED before the fix on the
# three assertions marked below.
fresh_harness
PR_AUTHOR=operator run_lane
[ "$(calls)" -eq 1 ] && ok || bad "1: tick 1 did not buy exactly one review (calls=$(calls)): $(ghlog)"
[ "$(st sha)" = S1 ] && [ "$(st verdict)" = REQUEST_CHANGES ] \
  && ok || bad "1: tick 1 did not record the verdict (sha='$(st sha)' verdict='$(st verdict)')"
[ "$(st ledger_sha)" = S1 ] \
  && ok || bad "1: RED-FIRST — the verdict write dropped the watermark the dismissal pass wrote in the same tick (ledger_sha='$(st ledger_sha)')"
[ -z "$(st reviewing_sha)" ] \
  && ok || bad "1: the in-flight marker outlived the verdict (reviewing_sha='$(st reviewing_sha)')"
: > "$T/gh-calls.log"
PR_AUTHOR=operator run_lane
[ "$(list_reads)" = 0 ] \
  && ok || bad "1: RED-FIRST — tick 2 read the dismissal list again on a watermarked head: $(ghlog)"
[ "$(reads)" = 0 ] \
  && ok || bad "1: RED-FIRST — tick 2 read pulls/7/reviews at all on a head that is reviewed AND watermarked: $(ghlog)"
[ "$(calls)" -eq 1 ] && ok || bad "1: tick 2 bought a second review"
[ "$(st verdict)" = REQUEST_CHANGES ] && [ "$(st ledger_sha)" = S1 ] \
  && ok || bad "1: tick 2 disturbed the row (verdict='$(st verdict)' ledger_sha='$(st ledger_sha)')"

# ── 2. no watermark is FABRICATED by the merge ────────────────────────────────
# The adversarial negative. A budget-low tick defers the dismissal pass and the
# ledger gate still buys the review (BH-989 case 9) — so the row gets a verdict
# and NO watermark, and the next healthy tick must still read and dismiss. A
# merge that wrote `ledger_sha` from a null would strand a stale-head blocking
# review until the branch moved.
fresh_harness
PR_AUTHOR=operator RATE_LOW=1 run_lane
[ "$(calls)" -eq 1 ] && ok || bad "2: the budget-low tick did not buy the review (calls=$(calls)): $(ghlog)"
[ "$(st sha)" = S1 ] && ok || bad "2: the budget-low tick recorded no head (sha='$(st sha)')"
[ -z "$(st ledger_sha)" ] \
  && ok || bad "2: a deferred dismissal pass was watermarked as completed by the verdict write (ledger_sha='$(st ledger_sha)')"
[ "$(has ledger_sha)" = false ] && [ "$(has deferred_sha)" = false ] \
  && ok || bad "2: the merge fabricated null cache keys onto a row that never had them: $(cat "$T/h/state/tproj.pr-reviews.json")"
: > "$T/gh-calls.log"
PR_AUTHOR=operator run_lane
[ "$(list_reads)" = 1 ] \
  && ok || bad "2: the next healthy tick skipped the deferred dismissal pass: $(ghlog)"
[ "$(st ledger_sha)" = S1 ] \
  && ok || bad "2: the healthy tick left no watermark (ledger_sha='$(st ledger_sha)')"
[ "$(calls)" -eq 1 ] && ok || bad "2: the healthy tick bought a second review"

# ── 3. a carried key is carried, never re-keyed ───────────────────────────────
# The row a budget-low tick leaves on a PR whose head then moves S0 -> S1: an
# OLD-head watermark and an OLD-head CI-debounce clock, and no `sha` (so the
# CI debounce does not intercept this tick). The verdict at S1 must carry both
# through UNTOUCHED — they are keyed on S0, so the next healthy tick reads at
# S1 exactly as it would have. Re-keying them to S1 is the bug this pins.
fresh_harness
state_put '{"7":{"ledger_sha":"S0","deferred_sha":"S0","deferred_at":1700000000}}'
PR_AUTHOR=operator RATE_LOW=1 run_lane
[ "$(calls)" -eq 1 ] && ok || bad "3: the review was not bought (calls=$(calls)): $(ghlog)"
[ "$(st verdict)" = REQUEST_CHANGES ] && ok || bad "3: no verdict recorded (verdict='$(st verdict)')"
[ "$(st ledger_sha)" = S0 ] \
  && ok || bad "3: the old head's watermark was re-keyed or dropped (ledger_sha='$(st ledger_sha)')"
[ "$(st deferred_at)" = 1700000000 ] && [ "$(st deferred_sha)" = S0 ] \
  && ok || bad "3: the CI-debounce clock was reset (deferred_sha='$(st deferred_sha)' deferred_at='$(st deferred_at)')"
: > "$T/gh-calls.log"
PR_AUTHOR=operator run_lane
[ "$(list_reads)" = 1 ] \
  && ok || bad "3: the S0 watermark was read as an answer for S1: $(ghlog)"
[ "$(st ledger_sha)" = S1 ] \
  && ok || bad "3: the healthy tick did not rewrite the watermark to the current head (ledger_sha='$(st ledger_sha)')"

# ── 4. an APPROVE verdict merges the same way, and still drops the attempt
#      bookkeeping ─────────────────────────────────────────────────────────────
# The seeded merge-retry counters are a PREVIOUS attempt's bookkeeping (what a
# retried-but-unlanded APPROVE leaves). They must not survive a fresh verdict —
# merge_retry reads them off this row — while the watermark must.
fresh_harness
state_put '{"7":{"merge_retries":3,"merge_retry_sha":"S1","merge_retry_alerted_sha":"S1"}}'
PR_AUTHOR=operator AGENT_VERDICT=APPROVE run_lane
[ "$(st verdict)" = APPROVE ] && ok || bad "4: the APPROVE was not recorded (verdict='$(st verdict)')"
[ "$(st ledger_sha)" = S1 ] \
  && ok || bad "4: the APPROVE path dropped the watermark (ledger_sha='$(st ledger_sha)')"
[ -z "$(st merge_retries)" ] && [ -z "$(st merge_retry_sha)" ] && [ -z "$(st merge_retry_alerted_sha)" ] \
  && ok || bad "4: a previous attempt's merge-retry bookkeeping survived the verdict (merge_retries='$(st merge_retries)' merge_retry_sha='$(st merge_retry_sha)' merge_retry_alerted_sha='$(st merge_retry_alerted_sha)')"
: > "$T/gh-calls.log"
PR_AUTHOR=operator AGENT_VERDICT=APPROVE run_lane
[ "$(list_reads)" = 0 ] \
  && ok || bad "4: tick 2 read the dismissal list again on a watermarked approved head: $(ghlog)"

echo "review-prs-ledger-merge.bh-1289: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
