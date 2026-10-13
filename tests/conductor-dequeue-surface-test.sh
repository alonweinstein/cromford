#!/bin/bash
# tests/conductor-dequeue-surface-test.sh — BH-872 workstream C: when Mergify
# takes a PR out of the queue because `github-review-approved` went false, the
# conductor says so ONCE per (PR, head) instead of leaving the PR parked in
# silence.
#
# THE INCIDENT. The review lane's standing CHANGES_REQUESTED review makes
# Mergify's `github-review-approved` condition false, Mergify dequeues the PR,
# and the conductor's ejection block logged "the batch build went red (provider
# mergify)" — a CI story about a review. Nothing on the PR, nothing in the fleet
# feed, and the requeue arm needs CLEAN, which the standing review denies.
#
# Driven, not grepped. Section A sources bin/lib/merge-conductor-lib.sh and calls
# mc_dequeue_reason against a gh stub that runs the REAL jq filter over
# GitHub-shaped fixture JSON, so the filter itself is under test. Section B
# EXTRACTS the `# >>> dequeue surface` block out of bin/merge-conductor.sh
# verbatim and runs THAT with fixture variables, so deleting the call site fails
# a test here. Every assertion is on the recorded gh argv, the beat argv, the
# attempts mark file or logs/merge-conductor.log — never on script text.
# Every fixture value is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/conductor-dequeue-surface-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
PRURL="https://github.com/$SLUG/pull/41"
QKEY="$SLUG#41"
H1=aaaaaaaa1111
H2=bbbbbbbb2222
H3=cccccccc3333
H4=dddddddd4444
TOKEN=github-review-approved
GH_RC1=""

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state/merge-conductor" "$T/fakebin" "$T/fix"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh
# ahead of its first line of logic, so a fixture that copies the lib alone gets a
# lib that cannot load.
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# BH-1586: the comment and check-run reads go through gh_rest (and the paged
# comment list through gh-rest-list.sh), so the fixture tree carries them.
for f in gh-pr-list.sh gh-budget.sh gh-rest.sh gh-rest-var.sh gh-rest-list.sh; do
  [ -r "$DIR/bin/lib/$f" ] && cp "$DIR/bin/lib/$f" "$T/h/bin/lib/"
done
: > "$T/h/state/merge-conductor/attempts.txt"
ATT="$T/h/state/merge-conductor/attempts.txt"
MCLOG="$T/h/logs/merge-conductor.log"
: > "$MCLOG"

# beat.sh: the fleet feed, recorded as argv.
cat > "$T/h/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/beats.txt"
exit 0
EOF
chmod +x "$T/h/bin/beat.sh"

# gh stub. Reads are answered from fixture JSON through the REAL -q filter, so a
# filter that does not match GitHub's shape fails here (D4). Writes are recorded.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
ALL="\$*"
printf '%s\n' "\$ALL" >> "$T/gh-calls.txt"
JQ=""; A=(); REST=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    -q|--jq)    JQ="\$2"; shift 2 ;;
    --paginate) shift ;;
    # BH-1586: the reads are gh_rest now (gh api -i -X GET PATH -F ...). The
    # method and the -F paging args are not part of the path the arms match.
    -i) REST=1; shift ;;
    -X) [ "\$2" = GET ] || A+=("\$1" "\$2"); shift 2 ;;
    -F) shift 2 ;;
    *) A+=("\$1"); shift ;;
  esac
done
case "\${A[0]:-}" in
  pr)
    case "\${A[1]:-}" in
      comment) printf 'GRAPHQL %s\n' "\$ALL" >> "$T/gh-comments.txt"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  api)
    # The REST comment write (#891 round 1, Important 2). -f body=… was already
    # shifted out above, so the recorded argv is the method + path; the BODY is
    # kept separately so the wording assertions still read the real text.
    case " \${ALL} " in
      *" -X POST repos/"*"/issues/"*"/comments"*)
        printf 'REST %s\n' "\$ALL" >> "$T/gh-comments.txt"
        printf '%s\n' "\$ALL" | sed -E 's/.*-f body=//' >> "$T/gh-comment-bodies.txt"
        exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
# One switch for "GitHub answered 502": the conductor must read that as "no
# reason", never as a reason.
# A REST read (gh_rest, BH-1586) gets a whole HTTP response and the RAW fixture
# JSON: the conductor applies its own jq filter, so the filter is still the one
# under test. A raw read keeps the old gh shape (exit 1 on failure, -q applied).
if [ -n "\${GH_RC1:-}" ]; then
  [ "\$REST" = 1 ] && { printf 'HTTP/1.1 502 Bad Gateway\r\n\r\n{"message":"fixture"}'; exit 0; }
  echo "gh: HTTP 502 (fixture)" >&2; exit 1
fi
OUT=""
case "\${A[1]:-}" in
  repos/$SLUG/issues/*/comments*)   OUT=\$(cat "$T/fix/comments.json" 2>/dev/null) ;;
  repos/$SLUG/commits/*/check-runs) OUT=\$(cat "$T/fix/checkruns.json" 2>/dev/null) ;;
  *) printf '%s\n' "\${A[1]:-}" >> "$T/gh-unexpected.txt"; exit 1 ;;
esac
if [ "\$REST" = 1 ]; then
  [ -n "\$OUT" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 0; }
  printf 'HTTP/1.1 200 OK\r\n\r\n%s\n' "\$OUT"; exit 0
fi
[ -n "\$OUT" ] || exit 1
if [ -n "\$JQ" ]; then printf '%s' "\$OUT" | jq -r "\$JQ"; else printf '%s' "\$OUT"; fi
EOF
chmod +x "$T/fakebin/gh"

reset_calls() { : > "$T/gh-calls.txt"; : > "$T/gh-comments.txt"; : > "$T/gh-comment-bodies.txt"; : > "$T/beats.txt"; : > "$T/gh-unexpected.txt"; }
reset_calls

# ── fixture bodies ───────────────────────────────────────────────────────────
# COPIED FROM WHAT MERGIFY ACTUALLY PRINTS (#891 review round 1, D4). The first
# cut of these invented a shape — a "Queue conditions are not satisfied" list
# where the token appeared only on a review dequeue — and the classifier that
# passed against it fired on every ejection live, because Mergify prints the
# token in the required-conditions checklist of EVERY status comment on a repo
# whose ruleset asks for a review. Each body below is trimmed from a real
# example-org/project-5 comment, keeping every line that decides the answer:
#   REVIEW_CMT  #2458 @ 2026-09-18 08:47Z — dequeued BECAUSE of the review.
#   BATCH_CMT   #2029 @ 2026-09-17 07:35Z — dequeued on a checks TIMEOUT, and it
#               carries the token anyway (line 56 of the real body, satisfied:
#               a checkbox-less parent with an `- [X] #2029` child). This is the
#               false positive; it must answer nothing.
#   MERGED_CMT  #2367 — merged, token present, no `## Reason` at all.
# Multi-line on purpose — the newest-comment read must survive a body with
# newlines in it, and the line is what the classifier reads.
cmts() { cat > "$T/fix/comments.json"; }
cks()  { cat > "$T/fix/checkruns.json"; }

REVIEW_CMT='# Merge Queue Status\n\n- ✅ **Entered queue** — `2026-09-18 08:42 UTC` · Rule: `default`\n- 🟠 **Checks running** · on draft #2469\n- 🚫 **Left the queue** — `2026-09-18 08:47 UTC` · at `7550fb76a29a16ff1a2f14b017abcc09cc5b86cb`\n\n<details>\n<summary><strong>Waiting for</strong></summary>\n\n- [ ] `check-success = "Build + Unit tests"`\n- [ ] [`github-review-approved`](https://docs.mergify.com/configuration/conditions/#pull-request-attributes-github-review-approved) [🛡 GitHub repository ruleset rule `main`]\n\n</details>\n\n## Reason\n\nPull request #2458 has been dequeued\n\nmerge conditions no longer match. Blocked by:\n\n> - `github-review-approved`\n>\n> - [ ] `check-success = "Build + Unit tests"`\n> - [ ] [`github-review-approved`](https://docs.mergify.com/configuration/conditions/#pull-request-attributes-github-review-approved) [🛡 GitHub repository ruleset rule `main`]\n\n## Hint\n\nYou should look at the reason for the failure and decide if the pull request needs to be fixed.\n'
BATCH_CMT='# Merge Queue Status\n\n- ✅ **Entered queue** — `2026-09-17 06:51 UTC` · Rule: `default`\n- ❌ **Checks failed (attempt 1/2)** · on draft #2031\n- ❌ **Checks timed out (attempt 2/2)** · on draft #2041\n- 🚫 **Left the queue** — `2026-09-17 07:35 UTC` · at `d4cbee8c758a2fdd2258db0c01e356be12e1ce69`\n\n<details>\n<summary><strong>Waiting for</strong></summary>\n\n- [ ] `check-success = "Build + Unit tests"`\n\n</details>\n<details>\n<summary>All conditions</summary>\n\n- [ ] `check-success = "Build + Unit tests"`\n- [`github-review-approved`](https://docs.mergify.com/configuration/conditions/#pull-request-attributes-github-review-approved) [🛡 GitHub repository ruleset rule `main`]\n  - [X] #2029\n\n</details>\n\n## Reason\n\nThe merge conditions cannot be satisfied: the checks did not pass within the automatic checks timeout of 24 minutes 14 seconds, derived from this queue recent CI runtime\n\nFailing checks:\n- 🟠 [Build + Unit tests](https://github.com/example-org/project-5/actions/runs/35193185334)\n\n## Hint\n\nYou may have to fix your CI before adding the pull request to the queue again.\n'
MERGED_CMT='# Merge Queue Status\n\n- ✅ **Entered queue** — `2026-09-18 16:12 UTC` · Rule: `default`\n- ✅ **Checks passed** · on draft #2539\n- ✅ **Merged** — `2026-09-18 16:22 UTC` · squash\n\n<details>\n<summary>Required conditions to merge</summary>\n\n- [X] `check-success = "Build + Unit tests"`\n- [`github-review-approved`](https://docs.mergify.com/configuration/conditions/#pull-request-attributes-github-review-approved) [🛡 GitHub repository ruleset rule `main`]\n  - [X] #2367\n\n</details>\n'
IDLE_CK='{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral","output":{"title":"Merge queue is ready","summary":"The merge queue is ready to accept pull requests."}}]}'
# The queue check run carries the same checklist and no `## Reason`: an
# UNSATISFIED condition is an unchecked box, a satisfied one is a checkbox-less
# parent with `- [X]` children (the merged-#2458 summary, MERGED_CK).
REVIEW_CK='{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":"The pull request is not queued","summary":"- 🚫 **Left the queue** — at `aaaaaaaa1111`\n\n<details>\n<summary><strong>Waiting for</strong></summary>\n\n- [ ] [`github-review-approved`](https://docs.mergify.com/configuration/conditions/#pull-request-attributes-github-review-approved) [🛡 GitHub repository ruleset rule `main`]\n\n</details>\n"}}]}'
MERGED_CK='{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"success","output":{"title":"The pull request has been merged","summary":"- ✅ **Merged** — at `1269c18b` · squash\n\n<details>\n<summary>Required conditions to merge</summary>\n\n- [X] `check-success = \"Build + Unit tests\"`\n- [`github-review-approved`](https://docs.mergify.com/configuration/conditions/#pull-request-attributes-github-review-approved) [🛡 GitHub repository ruleset rule `main`]\n  - [X] #2458\n\n</details>\n"}}]}'

one_cmt() { # one_cmt <login> <body-with-\n>
  jq -nc --arg l "$1" --arg b "$(printf '%b' "$2")" \
    '[{id:9001,created_at:"2026-09-18T13:00:00Z",user:{login:$l},body:$b}]'
}
two_cmts() { # two_cmts <old-body> <new-body>  (oldest first, as the API returns)
  jq -nc --arg a "$(printf '%b' "$1")" --arg b "$(printf '%b' "$2")" \
    '[{id:9001,created_at:"2026-09-18T13:00:00Z",user:{login:"mergify[bot]"},body:$a},
      {id:9002,created_at:"2026-09-18T13:10:00Z",user:{login:"mergify[bot]"},body:$b}]'
}

# ============================================================================
# A. mc_dequeue_reason — the classifier. It gates an irreversible-ish write (a
#    client-visible PR comment), so the negatives matter as much as the hit.
# ============================================================================
reason() { # reason <head> ; prints [<answer>]
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" GH_RC1="$GH_RC1" \
    bash -c 'set -uo pipefail
      . "$HARNESS/bin/lib/merge-conductor-lib.sh"
      printf "[%s]" "$(mc_dequeue_reason "$1" "$2" "$3")"' _ "$SLUG" "$PRURL" "$1" 2>"$T/reason.err" )
}

# A1. The dequeue comment names the condition -> the token.
reset_calls; one_cmt 'mergify[bot]' "$REVIEW_CMT" | cmts; cks <<<"$IDLE_CK"
OUT=$(reason "$H1")
[ "$OUT" = "[$TOKEN]" ] && ok || bad "A1 a Mergify dequeue comment naming $TOKEN must answer it (got $OUT, err=$(cat "$T/reason.err"))"

# A2. A red batch is not a review dequeue.
reset_calls; one_cmt 'mergify[bot]' "$BATCH_CMT" | cmts; cks <<<"$IDLE_CK"
OUT=$(reason "$H1")
[ "$OUT" = "[]" ] && ok || bad "A2 a failing-checks dequeue must answer nothing (got $OUT)"

# A3. Mergify's idle check is not a witness of anything (project-5 #547).
reset_calls; cmts <<<'[]'; cks <<<"$IDLE_CK"
OUT=$(reason "$H1")
[ "$OUT" = "[]" ] && ok || bad "A3 the idle 'Merge queue is ready' check must answer nothing (got $OUT)"

# A4. THE API FAILED. An unreadable reason is not a reason (D11).
reset_calls; one_cmt 'mergify[bot]' "$REVIEW_CMT" | cmts; cks <<<"$REVIEW_CK"
GH_RC1=1; OUT=$(reason "$H1"); GH_RC1=""
[ "$OUT" = "[]" ] && ok || bad "A4 a gh failure must answer nothing, not the token (got $OUT)"

# A5. The OTHER source: the check run's own summary on the head.
reset_calls; cmts <<<'[]'; cks <<<"$REVIEW_CK"
OUT=$(reason "$H1")
[ "$OUT" = "[$TOKEN]" ] && ok || bad "A5 the Mergify check summary naming $TOKEN must answer it (got $OUT)"
grep -q "commits/$H1/check-runs" "$T/gh-calls.txt" && ok || bad "A5 the check run must be read on the HEAD sha: $(cat "$T/gh-calls.txt")"

# A6. NEWEST, not any. An old review dequeue under a fresh red batch is history.
reset_calls; two_cmts "$REVIEW_CMT" "$BATCH_CMT" | cmts; cks <<<"$IDLE_CK"
OUT=$(reason "$H1")
[ "$OUT" = "[]" ] && ok || bad "A6 only the NEWEST Mergify comment counts (got $OUT)"
reset_calls; two_cmts "$BATCH_CMT" "$REVIEW_CMT" | cmts; cks <<<"$IDLE_CK"
OUT=$(reason "$H1")
[ "$OUT" = "[$TOKEN]" ] && ok || bad "A6b the newest comment naming the token must answer it (got $OUT)"

# A7. A person quoting the condition in the thread is not Mergify dequeuing.
reset_calls; one_cmt operator "$REVIEW_CMT" | cmts; cks <<<"$IDLE_CK"
OUT=$(reason "$H1")
[ "$OUT" = "[]" ] && ok || bad "A7 only mergify[bot]'s own comment counts (got $OUT)"

# A8. THE DEFECT ROUND 1 FOUND. The checks-timeout body (BATCH_CMT above, real
#     #2029) CARRIES `github-review-approved` in its conditions checklist, with
#     the condition satisfied. A whole-body substring match answers the token
#     here, and every checks-caused ejection on every Mergify project then gets
#     a client-visible comment and a fleet alert blaming a review that is fine.
#     The `## Reason` of that body names a checks timeout and nothing else.
reset_calls; one_cmt 'mergify[bot]' "$BATCH_CMT" | cmts; cks <<<"$IDLE_CK"
OUT=$(reason "$H1")
[ "$OUT" = "[]" ] && ok || bad "A8 a checks-timeout body that MENTIONS $TOKEN in its satisfied-conditions checklist must answer nothing (got $OUT)"

# A8b. Same token, same checklist, on a MERGED PR (real #2367): there is no
#      `## Reason` at all and the condition is satisfied with an `- [X]` child.
reset_calls; one_cmt 'mergify[bot]' "$MERGED_CMT" | cmts; cks <<<"$IDLE_CK"
OUT=$(reason "$H1")
[ "$OUT" = "[]" ] && ok || bad "A8b a MERGED PR's status comment must answer nothing (got $OUT)"

# A9. The same discipline on the check-run summary: a satisfied condition there
#     is a checkbox-less parent with `- [X]` children, not a reason.
reset_calls; cmts <<<'[]'; cks <<<"$MERGED_CK"
OUT=$(reason "$H1")
[ "$OUT" = "[]" ] && ok || bad "A9 a merged queue check summary naming a SATISFIED $TOKEN must answer nothing (got $OUT)"

# ============================================================================
# B. The LIVE call site: the `# >>> dequeue surface` block of the conductor's
#    ejection arm, extracted verbatim and run.
# ============================================================================
awk '/# >>> dequeue surface/{f=1;next} /# <<< dequeue surface/{exit} f' \
  "$DIR/bin/merge-conductor.sh" > "$T/surf.sh"
[ -s "$T/surf.sh" ] && ok || bad "B could not extract the dequeue surface block from bin/merge-conductor.sh — markers missing?"

run_surface() { # run_surface <merges> <head> [provider]
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" GH_RC1="$GH_RC1" \
      P=demo-os PROJECT=demo-os SLUG="$SLUG" PROVIDER="${3:-mergify}" \
      QKEY="$QKEY" QURL="$PRURL" QHEAD="$2" MERGES="$1" \
      bash -c 'set -uo pipefail
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        . "$0"' "$T/surf.sh" >/dev/null 2>"$T/surf.err" ) || true
  [ -s "$T/surf.err" ] && echo "surface stderr: $(cat "$T/surf.err")"
  return 0
}
marks() { grep -c "^dequeue-surfaced $QKEY $1\$" "$ATT" 2>/dev/null || true; }

# B1. First ejection of this head, merge mode: mark, comment, beat, log.
reset_calls; : > "$MCLOG"; one_cmt 'mergify[bot]' "$REVIEW_CMT" | cmts; cks <<<"$IDLE_CK"
run_surface 1 "$H1"
[ "$(marks "$H1")" = 1 ] && ok || bad "B1 the (PR, head) mark must be written: $(cat "$ATT")"
[ "$(grep -c '^REST ' "$T/gh-comments.txt")" = 1 ] && ok || bad "B1 exactly one comment on the PR: $(cat "$T/gh-comments.txt")"
# Important 2 (#891 round 1): over REST, never `gh pr comment` — that is a
# GraphQL mutation and this fleet's accounts die on the GraphQL limit mid-tick.
grep -q "repos/$SLUG/issues/41/comments" "$T/gh-comments.txt" \
  && ok || bad "B1 the comment must go out as POST repos/<slug>/issues/<n>/comments: $(cat "$T/gh-comments.txt")"
[ "$(grep -c '^GRAPHQL ' "$T/gh-comments.txt")" = 0 ] \
  && ok || bad "B1 THE DEFECT: the comment went out over \`gh pr comment\` (GraphQL): $(cat "$T/gh-comments.txt")"
grep -q 'Mergify took this PR out of the queue because a standing changes-requested review makes github-review-approved false' "$T/gh-comment-bodies.txt" \
  && ok || bad "B1 the comment must name WHY: $(cat "$T/gh-comment-bodies.txt")"
grep -q 'that review is dismissed or a newer head is approved' "$T/gh-comment-bodies.txt" \
  && ok || bad "B1 the comment must name what RE-ENQUEUES it: $(cat "$T/gh-comment-bodies.txt")"
[ "$(grep -c "dequeue:$QKEY:$H1" "$T/beats.txt")" = 1 ] && ok || bad "B1 exactly one fleet_alert beat keyed on (PR, head): $(cat "$T/beats.txt")"
grep -q 'fleet_alert' "$T/beats.txt" && ok || bad "B1 the beat must be a fleet_alert: $(cat "$T/beats.txt")"
grep -q "DEQUEUED_REVIEW" "$MCLOG" && ok || bad "B1 the conductor log must carry DEQUEUED_REVIEW: $(cat "$MCLOG")"

# B2. The SAME (PR, head) again — a tick every 5 minutes must not re-comment.
reset_calls; : > "$MCLOG"
run_surface 1 "$H1"
[ "$(marks "$H1")" = 1 ] && ok || bad "B2 the mark must stay at one line: $(cat "$ATT")"
[ -s "$T/gh-comments.txt" ] && bad "B2 THE DEFECT: a second comment on the same head ($(cat "$T/gh-comments.txt"))" || ok
[ -s "$T/beats.txt" ] && bad "B2 a second beat on the same head: $(cat "$T/beats.txt")" || ok
grep -q "DEQUEUED_REVIEW" "$MCLOG" && bad "B2 a second DEQUEUED_REVIEW line: $(cat "$MCLOG")" || ok

# B3. Observe/actions mode: the beat and the mark, never a gh write.
reset_calls; : > "$MCLOG"
run_surface 0 "$H2"
[ "$(marks "$H2")" = 1 ] && ok || bad "B3 the mark is written in every mode: $(cat "$ATT")"
[ -s "$T/gh-comments.txt" ] && bad "B3 a non-merge tick must not write to GitHub: $(cat "$T/gh-comments.txt")" || ok
[ "$(grep -c "dequeue:$QKEY:$H2" "$T/beats.txt")" = 1 ] && ok || bad "B3 the beat fires in every mode: $(cat "$T/beats.txt")"
grep -q "DEQUEUED_REVIEW" "$MCLOG" && ok || bad "B3 the log line is written in every mode: $(cat "$MCLOG")"

# B4. A red batch ejection: this block says nothing at all.
reset_calls; : > "$MCLOG"; one_cmt 'mergify[bot]' "$BATCH_CMT" | cmts; cks <<<"$IDLE_CK"
run_surface 1 "$H3"
[ "$(marks "$H3")" = 0 ] && ok || bad "B4 no reason, no mark: $(cat "$ATT")"
[ -s "$T/gh-comments.txt" ] && bad "B4 THE DEFECT: a review-dequeue comment on a red batch ($(cat "$T/gh-comments.txt"))" || ok
[ -s "$T/beats.txt" ] && bad "B4 no reason, no beat: $(cat "$T/beats.txt")" || ok
grep -q "DEQUEUED_REVIEW" "$MCLOG" && bad "B4 no reason, no log line: $(cat "$MCLOG")" || ok

# B5. The native GitHub queue has no Mergify comment to read, and this block
#     must not spend a read looking for one.
reset_calls; : > "$MCLOG"; one_cmt 'mergify[bot]' "$REVIEW_CMT" | cmts; cks <<<"$REVIEW_CK"
run_surface 1 "$H4" github
[ "$(marks "$H4")" = 0 ] && ok || bad "B5 a non-mergify provider must not be surfaced: $(cat "$ATT")"
[ -s "$T/gh-comments.txt" ] && bad "B5 a github-queue ejection must not get the Mergify comment: $(cat "$T/gh-comments.txt")" || ok
[ -s "$T/gh-calls.txt" ] && bad "B5 no gh read at all on a non-mergify provider: $(cat "$T/gh-calls.txt")" || ok

[ -s "$T/gh-unexpected.txt" ] && bad "the gh stub was asked for a path no fixture answers: $(cat "$T/gh-unexpected.txt")" || ok

echo "conductor-dequeue-surface: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
