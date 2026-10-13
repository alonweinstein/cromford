#!/bin/bash
# tests/external-review-ci-read-test.sh — the two ways an external PR goes quiet,
# and the two fixes, driven against the real bin/gh-token.sh and bin/review-prs.sh.
#
# THE INCIDENT (2026-09-14, project-2 box). collaborator-1's example-org/project-2
# #294, #488 and #489 sat APPROVED and unmerged for days, for two independent
# reasons that each produce silence:
#
#   1. THE BOX COULD NOT READ CI. Its fine-grained PAT answers 403 "Resource not
#      accessible by personal access token" on actions/runs (and check-runs, and
#      commits/status, and the statusCheckRollup GraphQL). review-prs.sh reads
#      the re-review debounce off actions/runs, so every tick logged "re-review
#      deferred — CI not green (CI status unavailable)", alerted once at 12h, and
#      then nothing forever. A GitHub App installation token reads that endpoint
#      fine, so the read now has a SECOND credential — and `--read` deliberately
#      ignores the write-side kill switches, because nothing is written by a GET.
#
#   2. AN APPROVE ON THE CURRENT HEAD WAS NOBODY'S JOB. The first review answered
#      APPROVE merged=no (a hold was in force that minute). From the next tick on
#      the recorded sha equalled the head, so the loop `continue`d before any
#      merge code — and no other lane lists external PRs. The verdict was on
#      record and the PR was invisible.
#
# So the assertions below are about what must happen WITHOUT a human: the read
# retries on the second credential and says which one answered; an approved,
# open, CLEAN head is re-offered to the same merge step every tick; and every
# hold that means "not yours to land" still stops it.
# Run from anywhere: tests/external-review-ci-read-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

# =============================================================================
# 1. bin/gh-token.sh --read — a credential for a GET, and only for a GET
# =============================================================================
command -v openssl >/dev/null 2>&1 || { echo "openssl missing — skipping section 1"; }
if command -v openssl >/dev/null 2>&1; then
  G="$T/g"
  mkdir -p "$G/bin/lib" "$G/env" "$G/flags" "$G/logs" "$G/state" "$G/locks" "$G/fakebin"
  cp "$DIR/bin/gh-token.sh" "$G/bin/"; chmod +x "$G/bin/gh-token.sh"
  cp "$DIR/bin/lib/gh-repo-token.sh" "$G/bin/lib/"
  openssl genrsa -out "$G/env/github-app.pem" 2048 2>/dev/null
  chmod 600 "$G/env/github-app.pem"
  printf 'GH_APP_ID=778899\nGH_APP_PRIVATE_KEY_FILE=%s/env/github-app.pem\n' "$G" > "$G/env/github-app.env"

  cat > "$G/fakebin/curl" <<'SH'
#!/bin/bash
URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) shift 2 ;;
    -d) shift 2 ;;
    -X) shift 2 ;;
    -sS|-s|-S|-I) shift ;;
    *) URL="$1"; shift ;;
  esac
done
printf '%s\n' "$URL" >> "$CURL_LOG"
case "$URL" in
  */app/installations) printf '[{"id":4242,"account":{"login":"example-org"}}]\n' ;;
  */access_tokens)
    N=$(( $(cat "$TOKSEQ" 2>/dev/null || echo 0) + 1 )); printf '%s' "$N" > "$TOKSEQ"
    printf '{"token":"ghs_read_%s","expires_at":"%s"}\n' "$N" "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%M:%SZ')" ;;
  */rate_limit) printf '{"rate":{"remaining":4996,"limit":5000}}\n' ;;
  *) echo '{}' ;;
esac
SH
  printf '#!/bin/bash\nexit 1\n' > "$G/fakebin/gh"
  chmod +x "$G/fakebin/curl" "$G/fakebin/gh"

  gt() { # gt <args...> — bin/gh-token.sh under the fixture; extra env via GT_ENV
    : > "$G/curl.log"; printf '0' > "$G/tokseq"
    # shellcheck disable=SC2086
    env PATH="$G/fakebin:$PATH" HARNESS="$G" GH_APP_API_BASE="http://api.test" \
        CURL_LOG="$G/curl.log" TOKSEQ="$G/tokseq" GH_TOKEN=pattok \
        ${GT_ENV:-} "$G/bin/gh-token.sh" "$@" 2>/dev/null
  }

  OUT=$(gt example-org/project-2)
  [ "$OUT" = "ghs_read_1" ] && ok || bad "an armed box should mint normally, got '$OUT'"

  # The two WRITE kill switches: they still stop an ordinary ask...
  touch "$G/flags/gh-app-tokens-off"
  OUT=$(gt example-org/project-2)
  [ "$OUT" = "pattok" ] && ok || bad "flags/gh-app-tokens-off must still fall back to the PAT for a normal ask, got '$OUT'"
  # ...and they do NOT stop a read-only ask, which is the whole point: the flag
  # guards who WRITES to GitHub, and this token is spent on a GET of a run list.
  OUT=$(gt --read example-org/project-2)
  [ "$OUT" = "ghs_read_1" ] && ok || bad "--read must ignore flags/gh-app-tokens-off, got '$OUT'"
  rm -f "$G/flags/gh-app-tokens-off"

  GT_ENV="GH_APP_TOKENS=0" OUT=$(GT_ENV="GH_APP_TOKENS=0" gt example-org/project-2)
  [ "$OUT" = "pattok" ] && ok || bad "GH_APP_TOKENS=0 must still fall back to the PAT for a normal ask, got '$OUT'"
  OUT=$(GT_ENV="GH_APP_TOKENS=0" gt --read example-org/project-2)
  [ "$OUT" = "ghs_read_1" ] && ok || bad "--read must ignore GH_APP_TOKENS=0, got '$OUT'"
  OUT=$(GT_ENV="GH_TOKEN_READ=1" gt example-org/project-2)
  [ "$OUT" = "ghs_read_1" ] && ok || bad "GH_TOKEN_READ=1 must be the same mode as --read, got '$OUT'"

  # No App credentials at all is NOT a switch — it is the absence of the thing.
  # --read prints the PAT exactly like every other invocation.
  mv "$G/env/github-app.env" "$G/env/github-app.env.off"
  OUT=$(gt --read example-org/project-2)
  [ "$OUT" = "pattok" ] && ok || bad "--read with no App credentials must print the PAT, got '$OUT'"
  [ -s "$G/curl.log" ] && bad "--read on an unconfigured box must not touch GitHub" || ok
  mv "$G/env/github-app.env.off" "$G/env/github-app.env"

  # The token never reaches a log.
  OUT=$(gt --read example-org/project-2)
  grep -qr 'ghs_read_' "$G/logs" 2>/dev/null && bad "a token value reached logs/" || ok
fi

# =============================================================================
# 2 + 3. bin/review-prs.sh — the CI read's fallback, and the merge retry
# =============================================================================
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mkfix() { # a fresh scratch harness for one scenario
  scratch_rm "$H"; rm -rf "$T/agent-calls.log" "$T/merge-calls.txt" "$T/ghtoken-calls.txt" "$T/gh-calls.txt"
  mkdir -p "$H/bin/lib" "$H/state" "$H/logs" "$H/locks" "$H/env" "$H/flags" "$H/builds"
  cp "$DIR/bin/lib/e2e-paths.sh" "$DIR/bin/lib/gh-ci-read.sh" "$H/bin/lib/"
  cp "$DIR/bin/alert-line.sh" "$H/bin/"
  # BH-1510.1: the reviewer's model is a model_routes row, read through review_model;
  # this worker-less box carries the resolver's cache of #1507's table.
  cp "$DIR/bin/lib/review-model.sh" "$H/bin/lib/"
  mrs_fixture "$H" project-1
  for s in beat.sh deploy-request.sh merge-queue.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$H/bin/$s"; chmod +x "$H/bin/$s"
  done
  cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$5"
printf 'claude\n' > "$5.runner"
SH
  chmod +x "$H/bin/agent-call.sh"
  # The read-only token minter. Records every ask so "was the fallback used"
  # is a fact about the run and not a reading of the log text.
  cat > "$H/bin/gh-token.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/ghtoken-calls.txt"
[ "${GHTOKEN_BROKEN:-0}" = 1 ] && exit 1
printf 'ghs_read_token\n'
SH
  chmod +x "$H/bin/gh-token.sh"
}
export TEST_ROOT="$T"

mkdir -p "$T/fakebin"
# sleep is stubbed out: merge_step sleeps 5s after `gh pr merge`, and the cap
# scenario below runs it seven times.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"; chmod +x "$T/fakebin/sleep"
# The GitHub stub. CI_MODE decides what the Actions read does for each token;
# PR_STATE / PR_MERGE_STATE decide what the merge retry sees.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/gh-calls.txt"
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  printf '7\tnewhead123\texternaldev\tChange under review\n'
elif [ "${1:-}" = api ]; then
  # BH-1295 REVIEW FIX (F1b follow-up, drain review): merge_retry()'s no-lib
  # fallback (bin/review-prs.sh) is REST now, never GraphQL — the standing
  # fleet rule gh_rest exists for (a GraphQL rate limit kills a lane mid-
  # session, and a no-lib fallback is exactly the path firing when things are
  # already degraded). It calls `gh api repos/example-org/project-1/pulls/7
  # -q '{STATE:…, MSTATE:…}'`, a plain `gh api -q FILTER` that runs the
  # filter and prints the RESULT; this stub IS the whole of `gh`, so it
  # prints that same result directly. Matched before the CI_MODE case below
  # so the two api reads (PR state, Actions check-runs) never collide.
  case "$*" in
    # TEST-CHANGE (BH-1585): merge_step's state-after read is this same REST
    # read now (it was `gh pr view --json state`, the arm below), so once the
    # merge verb has run it answers PR_STATE_AFTER — the value the old arm gave.
    *"repos/example-org/project-1/pulls/7"*)
      st="${PR_STATE:-OPEN}"
      [ -s "$TEST_ROOT/merge-calls.txt" ] && [ -n "${PR_STATE_AFTER:-}" ] && st="$PR_STATE_AFTER"
      # TEST-CHANGE (BH-1285): the no-lib projection now carries base.ref too,
      # which merge_step reads before the direct merge (a stacked PR is held).
      printf '{"STATE":"%s","MSTATE":"%s","base":{"ref":"main"}}\n' "$st" "${PR_MERGE_STATE:-CLEAN}" ;;
    *)
      case "${CI_MODE:-both-403}" in
        default-ok) printf '{"s":"completed","c":"success","n":"Typecheck"}\n'; exit 0 ;;
        both-403)   echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1 ;;
        app-only)
          if [ "${GH_TOKEN:-}" = ghs_read_token ]; then
            printf '{"s":"completed","c":"success","n":"Typecheck"}\n'; exit 0
          fi
          echo "gh: Resource not accessible by personal access token (HTTP 403)" >&2; exit 1 ;;
      esac ;;
  esac
elif [ "${1:-}" = pr ] && [ "${2:-}" = merge ]; then
  printf '%s\n' "$*" >> "$TEST_ROOT/merge-calls.txt"
elif [ "${1:-}" = pr ] && [ "${2:-}" = diff ]; then
  if [[ "$*" == *--name-only* ]]; then printf 'lib/pricing.ts\n'
  else printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'; fi
elif [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  # The merge_retry() PR-state read moved to `gh api` above (F1b follow-up);
  # these two arms remain for the two `gh pr view` reads merge_step() still
  # makes right after `gh pr merge` (state-after and merge-commit), which are
  # outside the no-lib fallback's scope.
  case "$*" in
    *"--json state"*)           printf '%s\n' "${PR_STATE_AFTER:-OPEN}" ;;
    *"--json mergeCommit"*)     printf 'deadbeefcafe\n' ;;
    *)                          printf '\n' ;;
  esac
fi
exit 0
SH
chmod +x "$T/fakebin/gh"

seed() { printf '%s\n' "$1" > "$H/state/project-1.pr-reviews.json"; }
REVIEWED='{"7":{"sha":"newhead123","verdict":"APPROVE","tier":"2","served":"claude"}}'
run_lane() { # run_lane [VAR=val ...]
  env PATH="$T/fakebin:$PATH" HARNESS="$H" TEST_ROOT="$T" "$@" \
    bash "$DIR/bin/review-prs.sh" project-1 >/dev/null 2>&1
}
calls()  { [ -f "$T/agent-calls.log" ] && wc -l < "$T/agent-calls.log" || echo 0; }
merges() { [ -f "$T/merge-calls.txt" ] && wc -l < "$T/merge-calls.txt" || echo 0; }

echo "== 2. the CI read: a second credential, and one line naming which answered =="

# The project-2 shape: the default token 403s on actions/runs, the App token
# reads it fine — so the re-review runs instead of deferring forever.
mkfix; seed '{"7":{"sha":"oldhead","verdict":"REQUEST_CHANGES","tier":"2"}}'
run_lane CI_MODE=app-only
[ "$(calls)" -eq 1 ] && ok || bad "a 403 on the default token must retry on the App token, not defer (calls=$(calls))"
grep -q -- '--read example-org/project-1' "$T/ghtoken-calls.txt" 2>/dev/null \
  && ok || bad "the retry must ask gh-token.sh --read for THIS repo: $(cat "$T/ghtoken-calls.txt" 2>/dev/null)"
grep -q 'CI read answered by the read-only App token' "$H/logs/pr-reviews.log" \
  && ok || bad "the log must name which token answered: $(cat "$H/logs/pr-reviews.log")"

# Both credentials refused: the old behaviour, and the log says so plainly.
mkfix; seed '{"7":{"sha":"oldhead","verdict":"REQUEST_CHANGES","tier":"2"}}'
run_lane CI_MODE=both-403
[ "$(calls)" -eq 0 ] && ok || bad "with both tokens refused the re-review must still defer"
grep -q 'CI status unavailable (default token and read-only App token both refused)' "$H/logs/pr-reviews.log" \
  && ok || bad "a double refusal must name both credentials: $(cat "$H/logs/pr-reviews.log")"

# The default token working is the status quo: no mint, no extra log line.
mkfix; seed '{"7":{"sha":"oldhead","verdict":"REQUEST_CHANGES","tier":"2"}}'
run_lane CI_MODE=default-ok
[ "$(calls)" -eq 1 ] && ok || bad "a green read on the default token must release the re-review"
[ -s "$T/ghtoken-calls.txt" ] && bad "a successful default read must not mint anything" || ok
grep -q 'CI read answered by' "$H/logs/pr-reviews.log" \
  && bad "the default token answering is not news and must not be logged" || ok

# A box with no gh-token.sh at all (an old box mid-rollout) behaves exactly as
# it did before this change.
mkfix; seed '{"7":{"sha":"oldhead","verdict":"REQUEST_CHANGES","tier":"2"}}'
rm -f "$H/bin/gh-token.sh"
run_lane CI_MODE=both-403
[ "$(calls)" -eq 0 ] && ok || bad "no gh-token.sh must mean the pre-change read"
grep -q 're-review deferred' "$H/logs/pr-reviews.log" && ok || bad "the deferral must still be recorded"

echo "== 3. the merge retry: an APPROVE on the current head is a claim, not a file =="

# The rescue itself: recorded APPROVE, head unchanged, PR OPEN + CLEAN -> merge.
mkfix; seed "$REVIEWED"
run_lane PR_STATE=OPEN PR_MERGE_STATE=CLEAN PR_STATE_AFTER=MERGED
[ "$(merges)" -eq 1 ] && ok || bad "an approved, open, CLEAN head must be re-offered to the merge step"
grep -q 'approved head still open -> merge retried (merged=yes)' "$H/logs/pr-reviews.log" \
  && ok || bad "the retry must log its outcome: $(cat "$H/logs/pr-reviews.log")"
[ "$(calls)" -eq 0 ] && ok || bad "the retry must not buy a second review of a head already reviewed"

# One attempt per PR per tick, not a loop.
mkfix; seed "$REVIEWED"
run_lane PR_STATE=OPEN PR_MERGE_STATE=CLEAN PR_STATE_AFTER=MERGED
[ "$(merges)" -eq 1 ] && ok || bad "a tick must attempt the merge at most once"

# The kill switch.
mkfix; seed "$REVIEWED"
run_lane REVIEW_MERGE_RETRY=0 PR_STATE=OPEN PR_MERGE_STATE=CLEAN
[ "$(merges)" -eq 0 ] && ok || bad "REVIEW_MERGE_RETRY=0 must stop the retry"

# Every hold that means "not yours to land".
for f in automerge-disabled conductor-owns-merges; do
  mkfix; seed "$REVIEWED"; touch "$H/flags/$f"
  run_lane PR_STATE=OPEN PR_MERGE_STATE=CLEAN
  [ "$(merges)" -eq 0 ] && ok || bad "flags/$f must hold the merge retry"
done

# A Mergify repo: `gh pr merge` would bypass the queue, so the conductor owns it.
mkfix; seed "$REVIEWED"
printf 'mc_queue_conductor_only() { return 0; }\nmc_pr_queued() { return 1; }\n' \
  > "$H/bin/lib/merge-conductor-lib.sh"
run_lane PR_STATE=OPEN PR_MERGE_STATE=CLEAN
[ "$(merges)" -eq 0 ] && ok || bad "a Mergify-queue repo must not be merged directly by the retry"

# Judge provenance: an APPROVE from a fallback lane never auto-merges, and that
# is true on the tenth tick as much as on the first.
mkfix; seed '{"7":{"sha":"newhead123","verdict":"APPROVE","tier":"2","served":"codex"}}'
run_lane PR_STATE=OPEN PR_MERGE_STATE=CLEAN
[ "$(merges)" -eq 0 ] && ok || bad "a withheld (fallback-lane) APPROVE must never be retried into a merge"

# Not approved, not open, not clean: three ways to be none of the retry's business.
mkfix; seed '{"7":{"sha":"newhead123","verdict":"REQUEST_CHANGES","tier":"2","served":"claude"}}'
run_lane PR_STATE=OPEN PR_MERGE_STATE=CLEAN
[ "$(merges)" -eq 0 ] && ok || bad "a REQUEST_CHANGES record must not be merged"
grep -q 'repos/example-org/project-1/pulls/7' "$T/gh-calls.txt" 2>/dev/null \
  && bad "a non-APPROVE record must cost no extra GitHub read" || ok

mkfix; seed "$REVIEWED"; run_lane PR_STATE=MERGED PR_MERGE_STATE=CLEAN
[ "$(merges)" -eq 0 ] && ok || bad "an already-merged PR must not be merged again"
mkfix; seed "$REVIEWED"; run_lane PR_STATE=OPEN PR_MERGE_STATE=BLOCKED
[ "$(merges)" -eq 0 ] && ok || bad "a non-CLEAN mergeStateStatus must not be merged"

# The cap. A PR that refuses six times needs a person, not a seventh attempt —
# and the ALERT is written once, however many ticks follow.
mkfix; seed "$REVIEWED"
for _ in 1 2 3 4 5 6 7 8; do
  run_lane PR_STATE=OPEN PR_MERGE_STATE=CLEAN PR_STATE_AFTER=OPEN
done
[ "$(merges)" -eq 6 ] && ok || bad "the retry must stop after 6 attempts on one head (got $(merges))"
[ "$(grep -c 'still OPEN after 6 merge attempts' "$H/logs/ALERTS.log" 2>/dev/null || echo 0)" -eq 1 ] \
  && ok || bad "the cap must alert exactly once: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"

# A fresh APPROVE records the lane that served it, so the retry above can honour
# provenance instead of guessing at it.
mkfix; seed '{}'
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\nTIER: 1\nVERDICT: APPROVE\n' > "$5"
printf 'claude\n' > "$5.runner"
SH
chmod +x "$H/bin/agent-call.sh"
run_lane CI_MODE=default-ok PR_STATE=OPEN PR_MERGE_STATE=CLEAN PR_STATE_AFTER=MERGED
[ "$(jq -r '."7".served' "$H/state/project-1.pr-reviews.json")" = claude ] \
  && ok || bad "the verdict record must name the lane that served it"
[ "$(merges)" -eq 1 ] && ok || bad "a fresh APPROVE must still merge exactly as it always has"

echo "external-review-ci-read: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
