#!/bin/bash
# tests/result-parent-pr-test.sh — A STACKED CLAIM MUST NEVER WRITE THE PARENT'S
# URL AS THIS RECORD'S `PR:`.
#
# THE DEFECT (BH-848, 2026-09-18). When `gh pr create` died on the App GraphQL
# cap, bin/run-build.sh's RESULT ratchet folded 120 chars of the caller's notes
# into the failed line — and for a stacked child those notes are
# `STACKED on ticket/bh-776 (https://github.com/example-org/cromford/pull/803)`,
# the PARENT's URL. fly/builder-runner.sh then grepped the FIRST url on the record
# and wrote it as `PR:`. Two records (BH-776 -> #803, BH-550 -> #754) pointed the
# merge sweep at somebody else's PR: worse than no link, because it looks linked.
#
# WHAT THIS SUITE PINS:
#   1-2. the ratchet redacts every pull URL out of the FAILED line (and leaves a
#        real `PR_CREATED <url> | STACKED on …` success line byte for byte alone);
#   3-5. bin/lib/result-pr-url.sh reads a record's OWN url — line 1's `PR_CREATED
#        <url>` or a `PR:` line, never a `PARENT_PR:` line — and the EXTRACTED
#        `# >>> result assemble` block of fly/builder-runner.sh writes the parent
#        as `PARENT_PR:` and nothing as `PR:` when the record has no PR of its own.
#
# The production blocks are lifted VERBATIM by their `# >>>` / `# <<<` markers and
# run against a scratch tree; assertions are on the files they write.
#
# Run from anywhere: bash tests/result-parent-pr-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d) && trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
# One clock read for the whole file (bin/test-determinism-lint.sh); nothing here
# is time-dependent — it only keeps fixture names unique.
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

CHILD="https://github.com/example-org/cromford/pull/9"
PARENT="https://github.com/example-org/cromford/pull/803"
PULLRE='https://github.com/[^ ]+/pull/[0-9]+'

marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }

RATCHET="$T/ratchet.sh"
marked '# >>> result pr url ratchet' '# <<< result pr url ratchet' "$RB_ALL" > "$RATCHET"
[ -s "$RATCHET" ] && ok || bad "the '# >>> result pr url ratchet' block is missing from bin/run-build.sh"

ASSEMBLE="$T/assemble.sh"
marked '# >>> result assemble' '# <<< result assemble' "$DIR/fly/builder-runner.sh" > "$ASSEMBLE"
[ -s "$ASSEMBLE" ] && ok || bad "the '# >>> result assemble' block is missing from fly/builder-runner.sh"

LIB="$DIR/bin/lib/result-pr-url.sh"
[ -r "$LIB" ] || { echo "FAIL: bin/lib/result-pr-url.sh does not exist"; echo "result-parent-pr-test: $PASS pass, $((FAIL+1)) fail"; exit 1; }

# ══ 1. the failed line carries NO pull URL ═══════════════════════════════════
B1="$T/b1"; mkdir -p "$B1"
( BUILD="$B1"; PR_CREATE_ERR="GraphQL: API rate limit already exceeded for installation ID 161623167."
  . "$RATCHET"
  RESULT "PR_CREATED  | REBASE_CONFLICT vs origin/main @f0e9aa4 | STACKED on ticket/bh-776 ($PARENT) — parent must merge first" ) >/dev/null
[ "$(grep -cE "$PULLRE" "$B1/RESULT")" = 0 ] \
  && ok || bad "block 1: the failed line must carry NO pull URL, got: $(cat "$B1/RESULT")"
[ "$(grep -c '^PR_CREATE_FAILED' "$B1/RESULT")" = 1 ] \
  && ok || bad "block 1: the line must still be PR_CREATE_FAILED, got: $(cat "$B1/RESULT")"
grep -q 'example-org/cromford PR 803' "$B1/RESULT" \
  && ok || bad "block 1: the parent must stay READABLE as 'example-org/cromford PR 803', got: $(cat "$B1/RESULT")"
# ... and with the STACKED note SHORT enough to survive the 120-char fold whole —
# the exact BH-776 record, where the parent url landed on disk in full and the
# pool record published it as this build's `PR:`.
B1B="$T/b1b"; mkdir -p "$B1B"
( BUILD="$B1B"; PR_CREATE_ERR="GraphQL: API rate limit already exceeded."
  . "$RATCHET"
  RESULT "PR_CREATED  | STACKED on ticket/bh-776 ($PARENT) — parent must merge first" ) >/dev/null
[ "$(grep -cE "$PULLRE" "$B1B/RESULT")" = 0 ] \
  && ok || bad "block 1: a SHORT stacked note must not leave the parent url on the failed line, got: $(cat "$B1B/RESULT")"
grep -q 'example-org/cromford PR 803' "$B1B/RESULT" \
  && ok || bad "block 1: the short note's parent must still be readable, got: $(cat "$B1B/RESULT")"

# ══ 2. a real success line passes through byte for byte ═════════════════════
B2="$T/b2"; mkdir -p "$B2"
LINE2="PR_CREATED $CHILD | STACKED on ticket/bh-776 ($PARENT) — parent must merge first"
( BUILD="$B2"; . "$RATCHET"; RESULT "$LINE2" ) >/dev/null
[ "$(cat "$B2/RESULT")" = "$LINE2" ] \
  && ok || bad "block 2: a success line must pass through untouched, got: $(cat "$B2/RESULT")"

# ══ the assemble block's fixture harness ════════════════════════════════════
# The block is run exactly as fly/builder-runner.sh runs it: the lib sourced
# first (the runner sources it at the top), $HARNESS/builds/<project>-<key>-<ts>
# holding the record, $RESULT_FILE the pool record it assembles.
assemble() { # assemble <name> <RESULT contents> -> prints the assembled record
  local name="$1" body="$2" h
  h="$T/$name"
  scratch_rm "$h"; mkdir -p "$h/builds/cromford-BH-776-2026091800$NOW"
  printf '%s\n' "$body" > "$h/builds/cromford-BH-776-2026091800$NOW/RESULT"
  printf 'VERDICT: APPROVE\nTIER: 2\n' > "$h/builds/cromford-BH-776-2026091800$NOW/review.md"
  ( HARNESS="$h" PROJECT=cromford key=BH-776 RESULT_FILE="$h/POOL_RESULT" WARM_STATE=warm
    . "$LIB"
    . "$ASSEMBLE" ) >/dev/null 2>&1
  cat "$h/POOL_RESULT"
}

# ══ 3. a stacked SUCCESS: own PR as PR:, parent as PARENT_PR: ═══════════════
R3=$(assemble a3 "PR_CREATED $CHILD | STACKED on ticket/bh-776 ($PARENT) — parent must merge first")
[ "$(grep -c "^PR: $CHILD$" <<<"$R3")" = 1 ] \
  && ok || bad "block 3: the record's OWN pr must be the PR: line, got: $R3"
[ "$(grep -c "^PARENT_PR: $PARENT$" <<<"$R3")" = 1 ] \
  && ok || bad "block 3: the parent must be recorded as PARENT_PR:, got: $R3"

# ══ 4. a stacked FAILED record: no PR: line at all ══════════════════════════
R4=$(assemble a4 "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded for installation ID 161623167. — refused a url-less create claim carrying ' | STACKED on ticket/bh-776 (example-org/cromford PR 803) — parent must merge first'")
[ "$(grep -c '^PR: ' <<<"$R4")" = 0 ] \
  && ok || bad "block 4: a record with no PR of its own must get NO PR: line, got: $R4"
[ "$(grep -c "^PARENT_PR: $PARENT$" <<<"$R4")" = 1 ] \
  && ok || bad "block 4: the redacted parent note must still resolve to PARENT_PR: $PARENT, got: $R4"
# ... and the PRE-REDACTION shape (an older builder, a record written before the
# ratchet change) must not produce a PR: line either. This is the exact BH-776
# record that mislinked to #803.
R4B=$(assemble a4b "PR_CREATE_FAILED: GraphQL: API rate limit already exceeded. — refused a url-less create claim carrying ' | STACKED on ticket/bh-776 ($PARENT) — parent must merge first'")
[ "$(grep -c '^PR: ' <<<"$R4B")" = 0 ] \
  && ok || bad "block 4: a RAW parent url on a failed line must still not become PR: (the BH-776 mislink), got: $R4B"
[ "$(grep -c "^PARENT_PR: $PARENT$" <<<"$R4B")" = 1 ] \
  && ok || bad "block 4: the raw parent url must be recorded as PARENT_PR:, got: $R4B"

# ══ 5. result_own_pr_url never reads a PARENT_PR: line ══════════════════════
REC="$T/rec"; mkdir -p "$REC"
printf 'PR_CREATE_FAILED: nothing was opened\nTIER: 2\nPARENT_PR: %s\nBUILD_DIR: x\n' "$PARENT" > "$REC/RESULT"
OWN=$( . "$LIB"; result_own_pr_url "$REC/RESULT" )
[ -z "$OWN" ] && ok || bad "block 5: result_own_pr_url must print nothing for a PARENT_PR:-only record, got '$OWN'"
PAR=$( . "$LIB"; result_parent_pr_url "$REC/RESULT" )
[ "$PAR" = "$PARENT" ] && ok || bad "block 5: result_parent_pr_url must read the PARENT_PR: line, got '$PAR'"
# A reconciled record links through its own `PR:` line, and that one IS its own.
printf 'PR_CREATED %s | RECONCILED 2026-09-18T00:00:00Z by pr-url-reconcile\nRECONCILED_FROM: PR_CREATE_FAILED: x\nPR: %s\nPARENT_PR: %s\n' \
  "$CHILD" "$CHILD" "$PARENT" > "$REC/RESULT2"
OWN2=$( . "$LIB"; result_own_pr_url "$REC/RESULT2" )
[ "$OWN2" = "$CHILD" ] && ok || bad "block 5: a reconciled record's own url must win, got '$OWN2'"

echo "result-parent-pr-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
