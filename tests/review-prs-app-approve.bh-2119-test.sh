#!/bin/bash
# tests/review-prs-app-approve.bh-2119-test.sh — an APPROVE from the review lane
# goes out on the App token unless the PR's author IS the reviewing App, and
# landing it dismisses the lane's own CHANGES_REQUESTED on older heads (BH-2119).
#
# THE DEFECT THIS PINS (project-5 #3244, 2026-09-24). Every APPROVE went out on
# the lane's default credential (`operator`), a workaround for GitHub's 422 on an
# App approving its own PR. Since BH-1668 pool PRs are opened by a DIFFERENT App
# (`cromford-builders[bot]`), so the workaround only posted bot verdicts as
# the operator. And the only dismissal pass sits behind harness_pr_author_match, which a
# builders-authored PR fails, so the App's own CHANGES_REQUESTED on the older
# head stayed standing next to the new approval and the PR stayed blocked.
#
# Drives the REAL bin/review-prs.sh with only GitHub and the model stubbed, and
# asserts on the gh call log (with the token each call went out on) and the
# lane's log, never on the script's text.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/review-prs-app-approve.bh-2119-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RP="$DIR/bin/review-prs.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export TEST_ROOT="$T"
mkdir -p "$T/fakebin"

# ── the gh stub (same construction as tests/review-prs-dedupe-test.sh) ─────────
# One addition: reviews-after.json. Once the lane has posted a review, a reviews
# read answers from it when it exists — GitHub's list after the APPROVE landed,
# which is what the supersede pass re-reads.
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
printf '%s | %s\n' "${GH_TOKEN:-none}" "$*" >> "$TEST_ROOT/gh-calls.log"
if [ "${1:-}" = pr ]; then
  case "${2:-}" in
    list) printf '7\t%s\t%s\tChange under review\n' "${PR_HEAD:-S1}" "${PR_AUTHOR:-externaldev}"; exit 0 ;;
    diff) printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'; exit 0 ;;
    view) printf '## What\nA pool-built change.\n'; exit 0 ;;
    review|comment)
      if [ "${REVIEW_POST_FAIL:-0}" = 1 ] && [ "$2" = review ]; then
        echo 'HTTP 422: Unprocessable Entity' >&2
        exit 1
      fi
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
      -X|--method|-f|-F|--field|--raw-field) shift 2 ;;
      --paginate|--slurp) shift ;;
      *) [ -z "$PATHARG" ] && PATHARG="$1"; shift ;;
    esac
  done
  emit() { if [ -n "$Q" ]; then printf '%s' "$1" | jq -r "$Q"; else printf '%s' "$1"; fi; }
  case "$PATHARG" in
    */reviews/*/dismissals) exit 0 ;;
    */pulls/*/reviews|*/pulls/*/reviews\?*)
      F="$TEST_ROOT/reviews.json"
      if [ -f "$TEST_ROOT/reviews-after.json" ] && grep -q ' | pr review ' "$TEST_ROOT/gh-calls.log"; then
        F="$TEST_ROOT/reviews-after.json"
      fi
      emit "$(cat "$F")"
      exit 0 ;;
    *actions/runs*) exit 0 ;;
    */pulls/[0-9]*)
      emit "$(jq -nc '{body:"## What\nA pool-built change.\n"}')"
      exit 0 ;;
  esac
  exit 0
fi
exit 0
STUB

cat > "$T/fakebin/agent-call" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_ROOT/agent-calls.log"
printf 'Static review.\n1. Something is wrong in a.ts:1 — fix it.\nTIER: 2\nVERDICT: %s\n' "${AGENT_VERDICT:-APPROVE}" > "$5"
printf 'claude\n' > "$5.runner"
STUB
chmod +x "$T/fakebin/gh" "$T/fakebin/agent-call"

. "$DIR/tests/lib/model-route-stub.sh" || exit 1
fresh_harness() {
  rm -rf "$T/h"
  rm -f "$T/agent-calls.log" "$T/gh-calls.log" "$T/reviews.json" "$T/reviews-after.json"
  : > "$T/gh-calls.log"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  cp "$T/fakebin/agent-call" "$T/h/bin/agent-call.sh"
  cp "$DIR/bin/lib/review-model.sh" "$T/h/bin/lib/"
  mrs_fixture "$T/h" tproj
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
  chmod +x "$T/h/bin/beat.sh"
  printf 'tproj o/tproj https://tproj.example.com /api/board 3 box-tproj 100.0.0.1\n' > "$T/h/fleet.conf"
  printf '[]\n' > "$T/reviews.json"
  printf '{}\n' > "$T/h/state/tproj.pr-reviews.json"
}

# An armed box: the reviewing App is `cromford`, bin/gh-token.sh mints ghs_x.
arm_app() {
  printf 'GH_APP_ID=1\nGH_APP_SLUG=cromford\n' > "$T/h/env/github-app.env"
  printf '#!/bin/bash\nprintf "ghs_x\\n"\n' > "$T/h/bin/gh-token.sh"
  chmod +x "$T/h/bin/gh-token.sh"
}

footer_body() { # footer_body <sha> <APPROVE|REQUEST_CHANGES>
  printf 'Static review.\n1. lib/x.ts:4 leaks a token into the log.\nTIER: 2\nVERDICT: %s\n\n---\n_Automated harness review (Fable) of %s. Static review — no build run._' "$2" "$1"
}
review_row() { # review_row <id> <state> <commit> <login> <body>
  jq -nc --argjson id "$1" --arg st "$2" --arg c "$3" --arg l "$4" --arg b "$5" \
    '{id:$id, state:$st, commit_id:$c, user:{login:$l}, body:$b}'
}
# before: the rows GitHub holds when the tick starts; after: the same plus
# whatever the tick's own post (and any sibling) added.
reviews() { printf '[%s]\n' "$1" > "$T/reviews.json"; }
reviews_after() { printf '[%s]\n' "$1" > "$T/reviews-after.json"; }

STALE_CR=$(review_row 11 CHANGES_REQUESTED S0 'cromford[bot]' "$(footer_body S0 REQUEST_CHANGES)")
NEW_APPROVE=$(review_row 20 APPROVED S1 'cromford[bot]' "$(footer_body S1 APPROVE)")

run_lane() {
  PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" \
    GH_TOKEN=ghp_default \
    PR_HEAD="${PR_HEAD:-S1}" PR_AUTHOR="${PR_AUTHOR:-cromford-builders[bot]}" \
    AGENT_VERDICT="${AGENT_VERDICT:-APPROVE}" REVIEW_POST_FAIL="${REVIEW_POST_FAIL:-0}" \
    bash "$RP" tproj >/dev/null 2>&1
}

ghlog() { cat "$T/gh-calls.log" 2>/dev/null; }
approve_lines() { grep -E ' \| pr review 7 .*--approve' "$T/gh-calls.log"; }
dismiss_lines() { grep -E ' \| api -X PUT repos/o/tproj/pulls/7/reviews/[0-9]+/dismissals' "$T/gh-calls.log"; }
dismissed() { dismiss_lines | grep -c "reviews/$1/dismissals" || true; }
rplog() { cat "$T/h/logs/pr-reviews.log" 2>/dev/null; }

# ─────────────────────────────────────────────────────────────────────────────
# TEST-CHANGE (lead fix, #2144): the supersede cases (A1, N1-N5) were written
# for a builders-authored PR, when `cromford-builders[bot]` was outside the
# harness author set. #1926 (BH-1668) put it in the default set, so on main a
# builders PR is a harness PR and main's per-tick BH-872 pass already dismisses
# the App's stale review there, before the review. The supersede pass now runs
# only on NON-harness authors (guarded in bin/review-prs.sh), so A1 and N1-N5
# drive it on an external author, with their assertions unchanged, and A1b/A1g
# pin what a builders-authored PR gets.
EXT=externaldev

# A1 (the REPRO, on the path the supersede pass exists for). A PR by a
#    non-harness author, head S1, the App's own blocking review at S0, verdict
#    APPROVE: the approval goes out on the App token, and the stale review is
#    dismissed on the App token with a message citing the new review and head.
fresh_harness; arm_app
reviews "$STALE_CR"
reviews_after "$STALE_CR,$NEW_APPROVE"
PR_AUTHOR=$EXT run_lane
[ "$(approve_lines | grep -c '^ghs_x | ')" = 1 ] \
  && ok || bad "A1: the APPROVE did not go out on the App token: $(ghlog)"
grep -q '^ghp_default | pr review' "$T/gh-calls.log" \
  && bad "A1: a review was posted on the default credential (as operator): $(ghlog)" || ok
[ "$(dismissed 11)" = 1 ] \
  && ok || bad "A1: the App's stale CHANGES_REQUESTED (review 11 @S0) was not dismissed exactly once: $(ghlog)"
dismiss_lines | grep 'reviews/11/' | grep -q '^ghs_x | ' \
  && ok || bad "A1: the dismissal did not go out on the App token: $(dismiss_lines)"
dismiss_lines | grep 'reviews/11/' | grep -q 'Superseded' \
  && ok || bad "A1: the dismissal message does not say it was superseded: $(dismiss_lines)"
dismiss_lines | grep 'reviews/11/' | grep -q 'S1' \
  && ok || bad "A1: the dismissal message does not cite the new head: $(dismiss_lines)"
dismiss_lines | grep 'reviews/11/' | grep -q 'review 20' \
  && ok || bad "A1: the dismissal message does not cite the new review's id: $(dismiss_lines)"
# ORDER: the approval lands before anything is dismissed.
[ "$(grep -nE ' \| pr review 7 ' "$T/gh-calls.log" | head -1 | cut -d: -f1)" \
  -lt "$(grep -nE 'reviews/11/dismissals' "$T/gh-calls.log" | head -1 | cut -d: -f1 || echo 0)" ] 2>/dev/null \
  && ok || bad "A1: the dismissal was not after the APPROVE post: $(ghlog)"
grep -q 'review 11' <<<"$(rplog)" \
  && ok || bad "A1: the supersede dismissal was not logged: $(rplog)"

# A1b. A builders-authored PR is a HARNESS PR on main (#1926): the App's stale
#     review 11 is dismissed by the per-tick BH-872 pass exactly once, BEFORE
#     the review is posted, and the APPROVE still goes out on the App token.
#     GitHub's re-read after that shows the row DISMISSED.
DISMISSED_11=$(review_row 11 DISMISSED S0 'cromford[bot]' "$(footer_body S0 REQUEST_CHANGES)")
fresh_harness; arm_app
reviews "$STALE_CR"
reviews_after "$DISMISSED_11,$NEW_APPROVE"
run_lane
[ "$(approve_lines | grep -c '^ghs_x | ')" = 1 ] \
  && ok || bad "A1b: the APPROVE on a builders PR did not go out on the App token: $(ghlog)"
[ "$(dismissed 11)" = 1 ] \
  && ok || bad "A1b: the stale review 11 was not dismissed exactly once on a builders PR: $(ghlog)"
dismiss_lines | grep 'reviews/11/' | grep -q 'BH-872' \
  && ok || bad "A1b: the builders PR's dismissal is not the per-tick BH-872 one: $(dismiss_lines)"
[ "$(grep -nE 'reviews/11/dismissals' "$T/gh-calls.log" | head -1 | cut -d: -f1)" \
  -lt "$(grep -nE ' \| pr review 7 ' "$T/gh-calls.log" | head -1 | cut -d: -f1 || echo 0)" ] 2>/dev/null \
  && ok || bad "A1b: the BH-872 dismissal was not before the review post: $(ghlog)"

# A1g. THE GUARD IS IN THE CODE, NOT THE FIXTURE: on a builders (harness) PR a
#     re-read that still lists review 11 as CHANGES_REQUESTED (a lagging list)
#     must not buy a second dismissal from the supersede pass.
fresh_harness; arm_app
reviews "$STALE_CR"
reviews_after "$STALE_CR,$NEW_APPROVE"
run_lane
[ "$(dismissed 11)" = 1 ] \
  && ok || bad "A1g: the supersede pass acted on a harness-authored PR (review 11 dismissed $(dismissed 11) times): $(dismiss_lines)"
grep -q 'Superseded' <<<"$(dismiss_lines)" \
  && bad "A1g: a supersede dismissal was sent on a harness-authored PR: $(dismiss_lines)" || ok

# A2. The PR's author IS the reviewing App: GitHub 422s a self-approve, so the
#     APPROVE keeps the default credential — and the stale review still goes.
fresh_harness; arm_app
reviews "$STALE_CR"
reviews_after "$STALE_CR,$(review_row 20 APPROVED S1 operator "$(footer_body S1 APPROVE)")"
PR_AUTHOR='cromford[bot]' run_lane
[ "$(approve_lines | grep -c '^ghp_default | ')" = 1 ] \
  && ok || bad "A2: an APPROVE on the App's own PR did not keep the default credential: $(ghlog)"
grep -q '^ghs_x' <<<"$(approve_lines)" \
  && bad "A2: an APPROVE on the App's own PR went out on the App token (422): $(ghlog)" || ok
[ "$(dismissed 11)" -ge 1 ] \
  && ok || bad "A2: the stale CHANGES_REQUESTED was not dismissed on a self-authored PR: $(ghlog)"

# A3. The App login cannot be read (no slug or name): unknown is treated as the
#     App's own PR, so the APPROVE keeps the default credential — never a new 422.
fresh_harness; arm_app
printf 'GH_APP_ID=1\n' > "$T/h/env/github-app.env"
reviews "$STALE_CR"
run_lane
[ "$(approve_lines | grep -c '^ghp_default | ')" = 1 ] \
  && ok || bad "A3: an unreadable App login did not fall back to the default credential: $(ghlog)"

# A4. A operator-authored PR is not the App's own: the APPROVE is the App's.
fresh_harness; arm_app
PR_AUTHOR=operator run_lane
[ "$(approve_lines | grep -c '^ghs_x | ')" = 1 ] \
  && ok || bad "A4: an APPROVE on a operator-authored PR did not go out on the App token: $(ghlog)"

# N1. A person's CHANGES_REQUESTED (no lane footer) is for a person: never
#     dismissed, while the lane's own stale row beside it is. The person is
#     the operator, whose login IS a harness identity, so only the footer tells them apart.
fresh_harness; arm_app
HUMAN=$(review_row 13 CHANGES_REQUESTED S0 operator 'Please rename this before I merge it.')
reviews "$STALE_CR,$HUMAN"
reviews_after "$STALE_CR,$HUMAN,$NEW_APPROVE"
PR_AUTHOR=$EXT run_lane
[ "$(dismissed 13)" = 0 ] && ok || bad "N1: a person's review was dismissed: $(dismiss_lines)"
[ "$(dismissed 11)" = 1 ] && ok || bad "N1: the lane's own stale row was not dismissed: $(ghlog)"

# N2. A footer body under a login that is not ours is not ours to dismiss.
fresh_harness; arm_app
STRANGER=$(review_row 14 CHANGES_REQUESTED S0 stranger "$(footer_body S0 REQUEST_CHANGES)")
reviews "$STALE_CR,$STRANGER"
reviews_after "$STALE_CR,$STRANGER,$NEW_APPROVE"
PR_AUTHOR=$EXT run_lane
[ "$(dismissed 14)" = 0 ] && ok || bad "N2: a footer review by a login not ours was dismissed: $(dismiss_lines)"
[ "$(dismissed 11)" = 1 ] && ok || bad "N2: the lane's own stale row was not dismissed: $(ghlog)"

# N3. A lane CHANGES_REQUESTED AT the approved head (a sibling tick posted it
#     while this one reviewed) is left for the approval itself to supersede.
fresh_harness; arm_app
reviews "$STALE_CR"
reviews_after "$STALE_CR,$(review_row 15 CHANGES_REQUESTED S1 'cromford[bot]' "$(footer_body S1 REQUEST_CHANGES)"),$NEW_APPROVE"
PR_AUTHOR=$EXT run_lane
[ "$(dismissed 15)" = 0 ] && ok || bad "N3: a lane review AT the approved head was dismissed: $(dismiss_lines)"
[ "$(dismissed 11)" = 1 ] && ok || bad "N3: the lane's own stale row was not dismissed: $(ghlog)"

# N4. A REQUEST_CHANGES verdict supersedes nothing.
fresh_harness; arm_app
reviews "$STALE_CR"
AGENT_VERDICT=REQUEST_CHANGES PR_AUTHOR=$EXT run_lane
grep -qE ' \| pr review 7 ' "$T/gh-calls.log" && ok || bad "N4: the verdict was not posted: $(ghlog)"
[ -z "$(dismiss_lines)" ] && ok || bad "N4: a REQUEST_CHANGES verdict dismissed a review: $(dismiss_lines)"

# N5. A refused APPROVE (the comment fallback ran) must not drop the old review:
#     nothing new supersedes it.
fresh_harness; arm_app
reviews "$STALE_CR"
REVIEW_POST_FAIL=1 PR_AUTHOR=$EXT run_lane
grep -qE ' \| pr comment 7 ' "$T/gh-calls.log" && ok || bad "N5: the comment fallback did not run: $(ghlog)"
[ -z "$(dismiss_lines)" ] && ok || bad "N5: a review was dismissed although the APPROVE never landed: $(dismiss_lines)"

echo "review-prs-app-approve (BH-2119): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
