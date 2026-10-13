#!/bin/bash
# The external-PR lane may review a PR immediately once, but every replacement
# head must have a non-empty, fully green Actions run set before another paid
# review starts. This drives the real review-prs.sh with only GitHub/model calls
# stubbed, so the spend boundary itself is under test.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

mkdir -p "$T/fakebin"
export TEST_ROOT="$T"

cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  printf '7\tnewhead123\texternaldev\tChange under review\n'
elif [ "${1:-}" = api ]; then
  case "${GH_API_MODE:-empty}" in
    error) exit 1 ;;
    empty) : ;;
    pending) printf '{"s":"in_progress","c":null}\n' ;;
    red) printf '{"s":"completed","c":"failure"}\n' ;;
    green) printf '{"s":"completed","c":"success"}\n' ;;
    # E2E policy (2026-09-12): substance green, only an E2E-class run red/pending.
    e2ered)   printf '{"s":"completed","c":"success","n":"Typecheck"}\n{"s":"completed","c":"failure","n":"E2E Tests"}\n{"s":"completed","c":"failure","n":"Production QA"}\n' ;;
    e2epend)  printf '{"s":"completed","c":"success","n":"Unit tests"}\n{"s":"in_progress","c":null,"n":"E2E Tests"}\n' ;;
    e2eonly)  printf '{"s":"completed","c":"failure","n":"E2E Tests"}\n' ;;
    unitred)  printf '{"s":"completed","c":"failure","n":"Unit tests"}\n{"s":"completed","c":"failure","n":"E2E Tests"}\n' ;;
    accepted) printf '{"s":"completed","c":"skipped"}\n{"s":"completed","c":"neutral"}\n' ;;
    paged)
      if [[ "$*" == *--paginate* ]]; then
        printf '{"s":"completed","c":"success"}\n{"s":"in_progress","c":null}\n'
      else
        printf '{"s":"completed","c":"success"}\n'
      fi ;;
  esac
elif [ "${1:-}" = pr ] && [ "${2:-}" = diff ]; then
  if [[ "$*" == *--name-only* ]]; then
    case "${GH_DIFF_FILES:-plain}" in
      plain) printf 'lib/pricing.ts\nscripts/migrations/0042.sql\n' ;;
      ui)    printf 'lib/pricing.ts\nsrc/app/clients/page.tsx\n' ;;
      deps)  printf 'package.json\n' ;;
      none)  exit 1 ;;
    esac
  else
    printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'
  fi
elif [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  printf '\n'
elif [ "${1:-}" = pr ] && { [ "${2:-}" = review ] || [ "${2:-}" = comment ]; }; then
  :
fi
STUB

cat > "$T/fakebin/agent-call" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > "$5"
printf 'claude\n' > "$5.runner"
STUB
chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call"

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() {
  rm -rf "$T/h" "$T/agent-calls.log"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" \
    "$T/h/env" "$T/h/builds"
  cp "$T/fakebin/agent-call" "$T/h/bin/agent-call.sh"
  # BH-1510.1: the reviewer's model is a model_routes row, read through review_model;
  # this worker-less box carries the resolver's cache of #1507's table.
  cp "$DIR/bin/lib/review-model.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" project-1
  cp "$DIR/bin/lib/e2e-paths.sh" "$T/h/bin/lib/"
  cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
  chmod +x "$T/h/bin/beat.sh"
}

seed_first_review() {
  printf '{}\n' > "$T/h/state/project-1.pr-reviews.json"
}

seed_rereview() {
  printf '%s\n' '{"7":{"sha":"oldhead","verdict":"REQUEST_CHANGES","tier":"2"}}' \
    > "$T/h/state/project-1.pr-reviews.json"
}

run_lane() {
  PATH="$T/fakebin:$PATH" HARNESS="$T/h" GH_API_MODE="$1" GH_DIFF_FILES="${3:-plain}" \
    REVIEW_CI_STALE_SECS="${2:-43200}" bash "$RP" project-1 >/dev/null 2>&1
}

calls() {
  if [ -f "$T/agent-calls.log" ]; then
    wc -l < "$T/agent-calls.log"
  else
    echo 0
  fi
}

fresh_harness
seed_first_review
run_lane empty
[ "$(calls)" -eq 1 ] && ok || bad "a PR's first review should still run immediately"

for mode in error empty pending red paged; do
  fresh_harness
  seed_rereview
  run_lane "$mode"
  [ "$(calls)" -eq 0 ] && ok || bad "$mode CI state started a paid re-review"
  grep -q 're-review deferred' "$T/h/logs/pr-reviews.log" \
    && ok || bad "$mode CI state did not record its deferral"
done

for mode in green accepted; do
  fresh_harness
  seed_rereview
  run_lane "$mode"
  [ "$(calls)" -eq 1 ] && ok || bad "$mode CI state did not release the re-review"
done

fresh_harness
seed_rereview
run_lane pending
run_lane pending
[ "$(grep -c 're-review deferred' "$T/h/logs/pr-reviews.log")" -eq 1 ] \
  && ok || bad "the same deferred head logged more than once"

fresh_harness
NOW=$(date -u +%s)
jq -nc --argjson at "$((NOW - 301))" \
  '{"7":{sha:"oldhead",verdict:"REQUEST_CHANGES",tier:"2",deferred_sha:"newhead123",deferred_at:$at}}' \
  > "$T/h/state/project-1.pr-reviews.json"
run_lane red 300
run_lane red 300
[ "$(calls)" -eq 0 ] && ok || bad "the stale-CI alert bypassed the green gate"
[ "$(grep -c 're-review has waited' "$T/h/logs/ALERTS.log")" -eq 1 ] \
  && ok || bad "stale non-green CI should alert exactly once per head"

# ── E2E policy (the operator 2026-09-12, docs/E2E-POLICY.md point 6) ──────────────────
# E2E / Production-QA runs are advisory unless the diff touches an E2E path.
# non-E2E diff + only E2E-class runs red or pending: substance green, the
# re-review runs and the log names the runs that were set aside
for mode in e2ered e2epend; do
  fresh_harness; seed_rereview
  run_lane "$mode" 43200 plain
  [ "$(calls)" -eq 1 ] && ok || bad "$mode on a non-E2E diff should have released the re-review"
done
fresh_harness; seed_rereview; run_lane e2ered 43200 plain
grep -q 'E2E-class run(s) advisory (no E2E path in diff): E2E Tests=failure, Production QA=failure' "$T/h/logs/pr-reviews.log" \
  && ok || bad "advisory E2E runs were not named in the log: $(cat "$T/h/logs/pr-reviews.log")"
# the same red E2E on a diff that touches app/ (or package.json) still defers
for files in ui deps; do
  fresh_harness; seed_rereview
  run_lane e2ered 43200 "$files"
  [ "$(calls)" -eq 0 ] && ok || bad "red E2E on an E2E-path diff ($files) started a paid re-review"
  grep -q 're-review deferred' "$T/h/logs/pr-reviews.log" && ok || bad "E2E-path diff ($files) did not record its deferral"
done
# a red unit run is never advisory, whatever the diff
fresh_harness; seed_rereview; run_lane unitred 43200 plain
[ "$(calls)" -eq 0 ] && ok || bad "a red Unit tests run was waved through as advisory"
# fail closed: changed-file list unavailable -> every run counts
fresh_harness; seed_rereview; run_lane e2ered 43200 none
[ "$(calls)" -eq 0 ] && ok || bad "an unavailable file list must count every run (fail closed)"
# fail closed: the lib is missing -> the pre-policy rule, every run counts
fresh_harness; seed_rereview; rm -f "$T/h/bin/lib/e2e-paths.sh"; run_lane e2ered 43200 plain
[ "$(calls)" -eq 0 ] && ok || bad "a missing e2e-paths lib must fall back to counting every run"
# a head whose ONLY run is an advisory E2E: no substantive evidence at all, so
# it waits (fail closed, same as an empty run list) and records why
fresh_harness; seed_rereview; run_lane e2eonly 43200 plain
[ "$(calls)" -eq 0 ] && ok || bad "an advisory-only run set must wait for the fast jobs"
grep -q 'no substantive (non-E2E) runs yet' "$T/h/logs/pr-reviews.log" \
  && ok || bad "advisory-only head did not record why it waits: $(cat "$T/h/logs/pr-reviews.log")"

echo "review-ci-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
