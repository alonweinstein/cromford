#!/bin/bash
# tests/blocked-resolver-readmemo.bh-5946-test.sh — BH-5946: the per-run read
# memo (bin/lib/br/opt/readmemo.sh). One run reads a PR, its issue thread and
# the merged-PR search once; a repeat GET in the same run is answered from the
# memo, and every read a rung makes after the dispatch line is live.
#
# WHAT IS CLAIMED. Every candidate row runs br_one in its own subshell, so a
# shell memo dies with the row. One keyless head-not-reapproved conductor row
# read the same `pulls/<n>` five times before any rung: discovery, the key
# derivation (branch, title), the merged guard and the human-verdict check.
#
# R1, R2 and R7 run the REAL bin/blocked-resolver.sh over a scratch $HARNESS
# (tests/lib/br-repeat-cuts-fixture.sh) and count the recorded gh calls. R3-R6
# source the module over the real bin/lib/gh-rest.sh and drive gh_rest and the
# lane's own br_pr_ref (lifted out of the script, as
# tests/resolver-pr-read-failed-test.sh does) against the same gh stub.
#
# Run from anywhere: tests/blocked-resolver-readmemo.bh-5946-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
. "$(dirname "$0")/lib/br-repeat-cuts-fixture.sh" || exit 1
BRF_MODULES="profile readmemo"
brf_setup || { echo "fixture setup failed"; exit 1; }
[ -r "$DIR/bin/lib/br/opt/readmemo.sh" ] || bad "bin/lib/br/opt/readmemo.sh is missing"

# NPULL <n> — the plain GETs of the PR object #<n> (no extra args: not the diff
# read with its Accept header, not /files or /reviews).
NPULL() { NGH "GET repos/o/tproj/pulls/$1$"; }
NPULLH() { NGH "GET repos/o/tproj/pulls/$1 -H "; }

# ===========================================================================
# R1 — one keyless head-not-reapproved row reads pulls/<n> once per run.
# ===========================================================================
# The branch names no ticket, the title does, so br_one derives the key. A HOLD
# on the issue stops the row at the rung gate, before the dispatch line, so
# every read this run makes is a pre-rung read.
R1FIX() {
  brf_reset
  PRADD 61 feature/no-key 'TK-61: the work'
  CROW 61 'head-not-reapproved: BLOCK on the head'
  HOLDCMT 61
}
R1FIX; BRENV=(BR_OPT_OFF=readmemo); TICK
R1_OFF=$(NPULL 61)
R1FIX; TICK
R1_ON=$(NPULL 61)
LOG | grep -q 'derived TK-61' && ok || bad "R1: the row must arrive keyless and derive TK-61: $(LOG | grep o-tproj-61 | head -3)"
LOG | grep -q 'HOLD respected TK-61' && ok || bad "R1: the row must stop at the rung gate: $(LOG | grep -i hold | head -3)"
[ "$R1_OFF" -ge 2 ] && ok || bad "R1: without the memo the run reads pulls/61 more than once (red-first shape), got $R1_OFF"
[ "$R1_ON" = 1 ] && ok || bad "R1: with the memo the run reads pulls/61 exactly once, got $R1_ON: $(grep 'pulls/61' "$T/gh.txt")"
[ "$(PFIELD memo_hits)" -ge 4 ] && ok || bad "R1: the prof: line must count the memo hits, got '$(PROF)'"
echo "readmemo R1: pulls/61 GETs in one run without the memo = $R1_OFF; with the memo = $R1_ON"

# R7 — BR_READMEMO=0 is the no-module run, call for call.
R1FIX; BRENV=(BR_READMEMO=0); TICK
[ "$(NPULL 61)" = "$R1_OFF" ] && ok || bad "R7: BR_READMEMO=0 must read pulls/61 $R1_OFF times like the no-module run, got $(NPULL 61)"
R1FIX; : > "$H/flags/br-readmemo-off"; TICK
[ "$(NPULL 61)" = "$R1_OFF" ] && ok || bad "R7: flags/br-readmemo-off must read pulls/61 $R1_OFF times like the no-module run, got $(NPULL 61)"

# R8 — a rung hook before the dispatch line reads live too. A canary carry
# rung (the seam's first hook) reads the PR head and declines: its read is one
# GET more than R1's, never a memo hit.
R1FIX
printf '%s\n' 'br_opt_carry_rung() { br_pr_field "$4" .head.sha "head sha" >/dev/null; return 1; }' > "$OPTD/mechanical.sh"
TICK
rm -f "$OPTD/mechanical.sh"
[ "$(NPULL 61)" = $((R1_ON + 1)) ] && ok || bad "R8: the carry hook's read must be live ($((R1_ON + 1)) GETs of pulls/61), got $(NPULL 61)"

# ===========================================================================
# R2 — two rows of one ticket share the merged-PR search.
# ===========================================================================
# #61 and #62 both carry TK-61 (ticket/TK-61, ticket/TK-61-r2). Observe mode:
# the hold gate logs WOULD hold and writes nothing, so the second row walks the
# same path as the first.
R2FIX() {
  brf_reset
  PRADD 61; PRADD 62 ticket/TK-61-r2 'TK-61: the work, again'
  CROW 61 'head-not-reapproved: BLOCK on the head'
  CROW 62 'head-not-reapproved: BLOCK on the head'
  HOLDCMT 61
  # A record with a first_seen: the merged guard searches only with a park time.
  SEED tproj-TK-61 '{}'
  : > "$H/flags/blocked-resolver-observe"
}
R2FIX; BRENV=(BR_OPT_OFF=readmemo); TICK
R2_OFF=$(NGH 'GET search/issues')
R2FIX; TICK
R2_ON=$(NGH 'GET search/issues')
[ "$(LOG | grep -c 'WOULD hold')" = 2 ] && ok || bad "R2: both rows must reach the hold gate: $(LOG | grep -i hold)"
[ "$R2_OFF" = 4 ] && ok || bad "R2: without the memo two rows make 4 searches, got $R2_OFF"
[ "$R2_ON" = 2 ] && ok || bad "R2: with the memo two rows make 2 searches, got $R2_ON"

# R9 — a row that reaches its dispatch line drops the memo for the rows after
# it: the same two rows with no hold and no observe mode. #61 dispatches its
# rung, so #62 makes both searches again.
R2FIX; rm -f "$H/flags/blocked-resolver-observe" "$T/f/comments-61.json"; TICK
LOG | grep -qE 'o-tproj-61 \[conductor/head-not-reapproved\] -> ' && ok || bad "R9: #61 must reach its dispatch line: $(LOG | grep o-tproj-61 | tail -2)"
[ "$(NGH 'GET search/issues')" = 4 ] && ok || bad "R9: after #61's dispatch line #62 must search live again (4 searches), got $(NGH 'GET search/issues')"

# ===========================================================================
# R3 — a rung reads live after the dispatch line.
# ===========================================================================
# no-verdict -> the re-review rung, which reads the PR head after the dispatch
# line. In observe mode that rung returns before its read, so the difference
# between the two runs is the rung's own plain reads of the PR, every one of
# which the memo would answer if the dispatch line did not turn it off.
R3FIX() { brf_reset; PRADD 63; CROW 63 'no-verdict: the review lane answered nothing'; }
# R3RUN <observe 0|1> [env...] — the plain pulls/63 GETs of one run.
R3RUN() { local obs="$1"; shift; R3FIX; [ "$obs" = 1 ] && : > "$H/flags/blocked-resolver-observe"; BRENV=("$@"); TICK; NPULL 63; }
R3_OBS=$(R3RUN 1); R3_RUNG=$(R3RUN 0)
LOG | grep -qE 'o-tproj-63 \[conductor/no-verdict\] -> re-review' && ok || bad "R3: #63 must dispatch the re-review rung: $(LOG | grep o-tproj-63 | tail -3)"
R3_OFF_OBS=$(R3RUN 1 BR_OPT_OFF=readmemo); R3_OFF_RUNG=$(R3RUN 0 BR_OPT_OFF=readmemo)
[ "$R3_OBS" = 1 ] && ok || bad "R3: in observe mode only discovery reads pulls/63 (every gate is a memo hit), got $R3_OBS"
# The rung's own reads are the difference between a rung run and an observe
# run. With the memo they must be exactly as many as with no memo: every one
# of them went to GitHub.
[ $((R3_RUNG - R3_OBS)) -ge 1 ] && [ $((R3_RUNG - R3_OBS)) = $((R3_OFF_RUNG - R3_OFF_OBS)) ] && ok \
  || bad "R3: the rung's reads after the dispatch line must all be live: with the memo $((R3_RUNG - R3_OBS)), with no memo $((R3_OFF_RUNG - R3_OFF_OBS))"

# ===========================================================================
# R3b-R6 — the wrapper over the real gh_rest, and the lane's br_pr_ref.
# ===========================================================================
brf_reset
PRADD 64
SEAM() { # SEAM <shell code> — the module over gh-rest.sh in a clean shell, with
  # an empty memo: every SEAM shares this shell's pid, so the memo dir is reset.
  rm -rf "$T/tmp"/br-read-memo.* 2>/dev/null
  ( export TMPDIR="$T/tmp" HARNESS="$H"; H="$H"; ST="$ST"; LOG="$T/seam.log"
    TICK_COUNTS="$T/counts"; : > "$TICK_COUNTS"
    br_count() { printf '%s\n' "$1" >> "$TICK_COUNTS"; }
    say() { printf '%s\n' "$*" >> "$LOG"; }
    unset GH_REST_LIB
    . "$DIR/bin/lib/gh-rest.sh" || exit 9
    . "$DIR/bin/lib/br/opt/readmemo.sh" || exit 9
    eval "$1" )
}
# R3b — BR_READMEMO_LIVE=0 (the row after its dispatch line) never answers from
# the memo and never stores.
: > "$T/gh.txt"
SEAM 'gh_rest GET repos/o/tproj/pulls/64 >/dev/null; gh_rest GET repos/o/tproj/pulls/64 >/dev/null
      BR_READMEMO_LIVE=0; gh_rest GET repos/o/tproj/pulls/64 >/dev/null; gh_rest GET repos/o/tproj/pulls/64 >/dev/null'
[ "$(NPULL 64)" = 3 ] && ok || bad "R3b: 1 stored read + 2 live reads with BR_READMEMO_LIVE=0 = 3 GETs, got $(NPULL 64)"
# The memo answer is the body byte for byte, with the stored status.
: > "$T/gh.txt"
SEAM 'a=$(gh_rest GET repos/o/tproj/pulls/64); gh_rest GET repos/o/tproj/pulls/64 > "$T/second"; echo "$GH_REST_STATUS $GH_REST_REASON" > "$T/st"; printf "%s\n" "$a" > "$T/first"'
cmp -s "$T/first" "$T/second" && ok || bad "R3b: a memo hit must print the stored body byte for byte"
[ "$(cat "$T/st")" = "200 memo" ] && ok || bad "R3b: a memo hit must replay the status and say memo, got '$(cat "$T/st")'"
[ "$(NPULL 64)" = 1 ] && ok || bad "R3b: the second read must be a memo hit, got $(NPULL 64) GETs"
# A memo hit made no call, so it carries no quota: the quota globals read empty,
# not the previous live call's values (lead review NOTE at readmemo.sh:80).
: > "$T/gh.txt"
SEAM 'gh_rest GET repos/o/tproj/pulls/64 >/dev/null; GH_REST_QUOTA_REMAINING=4321 GH_REST_QUOTA_LIMIT=5000
      gh_rest GET repos/o/tproj/pulls/64 >/dev/null; echo "q=[${GH_REST_QUOTA_REMAINING:-}][${GH_REST_QUOTA_LIMIT:-}] r=$GH_REST_REASON" > "$T/q"'
[ "$(cat "$T/q")" = "q=[][] r=memo" ] && ok || bad "R3b: a memo hit must leave the quota globals empty, got '$(cat "$T/q")'"
# A write to the PR drops its entries: the next GET is live.
: > "$T/gh.txt"
SEAM 'gh_rest GET repos/o/tproj/pulls/64 >/dev/null; gh_rest PATCH repos/o/tproj/pulls/64 -f state=closed >/dev/null; gh_rest GET repos/o/tproj/pulls/64 >/dev/null'
[ "$(NPULL 64)" = 2 ] && ok || bad "R3b: a PATCH must drop the PR's entries (2 GETs), got $(NPULL 64)"
# br_opt_readmemo_drop drops the PR and the search.
: > "$T/gh.txt"
SEAM 'gh_rest GET repos/o/tproj/pulls/64 >/dev/null; gh_rest GET search/issues -f q=x >/dev/null
      br_opt_readmemo_drop https://github.com/o/tproj/pull/64
      gh_rest GET repos/o/tproj/pulls/64 >/dev/null; gh_rest GET search/issues -f q=x >/dev/null'
[ "$(NPULL 64)" = 2 ] && [ "$(NGH 'GET search/issues')" = 2 ] && ok \
  || bad "R3b: br_opt_readmemo_drop must drop the PR and the search (pulls $(NPULL 64), search $(NGH 'GET search/issues'))"
# A read with an extra header (the iron-law diff read) is never memoised.
: > "$T/gh.txt"
SEAM 'gh_rest GET repos/o/tproj/pulls/64 -H "Accept: application/vnd.github.diff" >/dev/null; gh_rest GET repos/o/tproj/pulls/64 -H "Accept: application/vnd.github.diff" >/dev/null'
[ "$(NPULLH 64)" = 2 ] && ok || bad "R3b: a read with -H must stay live, got $(NPULLH 64) GETs"
# /files is not memoised.
: > "$T/gh.txt"
SEAM 'gh_rest GET repos/o/tproj/pulls/64/files >/dev/null; gh_rest GET repos/o/tproj/pulls/64/files >/dev/null'
[ "$(NGH 'pulls/64/files')" = 2 ] && ok || bad "R3b: pulls/<n>/files must stay live, got $(NGH 'pulls/64/files')"

# R4 — an HTTP 500 is not stored: the second read asks GitHub again.
: > "$T/gh.txt"; echo 500 > "$T/f/status-64"
SEAM 'r1=0; gh_rest GET repos/o/tproj/pulls/64 >/dev/null || r1=$?; r2=0; gh_rest GET repos/o/tproj/pulls/64 >/dev/null || r2=$?; echo "$r1 $r2" > "$T/rcs"'
rm -f "$T/f/status-64"
[ "$(NPULL 64)" = 2 ] && ok || bad "R4: a 500 must not be stored (2 GETs), got $(NPULL 64)"
[ "$(cat "$T/rcs")" = "75 75" ] && ok || bad "R4: both reads answer 75, got '$(cat "$T/rcs")'"

# R5 — an entry older than BR_READMEMO_MAX_AGE_S is not used.
: > "$T/gh.txt"
SEAM 'gh_rest GET repos/o/tproj/pulls/64 >/dev/null
      find "$TMPDIR" -path "*br-read-memo*" -type f -exec touch -d "@$(( '"$NOW"' - 301 ))" {} +
      gh_rest GET repos/o/tproj/pulls/64 >/dev/null'
[ "$(NPULL 64)" = 2 ] && ok || bad "R5: an entry older than 300 s must not be used (2 GETs), got $(NPULL 64)"

# R6 — br_pr_ref, lifted out of the lane: the memo answers a repeat read; a
# read the memo path cannot make keeps today's raw two-try loop and its words.
fn() { awk -v F="^$1\\(\\)" '$0~F{f=1} f{print} f&&/^}$/{exit}' "$DIR/bin/blocked-resolver.sh"; }
PRREF_SRC=$(fn br_pr_ref); SLUG_SRC=$(fn br_slug_of_url)
[ -n "$PRREF_SRC" ] && [ -n "$SLUG_SRC" ] || bad "R6: br_pr_ref / br_slug_of_url not found in bin/blocked-resolver.sh"
R6() { SEAM 'br_use_token() { :; }; mc_num_of_url() { printf "%s" "${1##*/}"; }
             mc_slug_of_url() { printf "%s" "$1" | sed -nE "s#^https://github.com/([^/]+/[^/]+)/pull/.*#\\1#p"; }
             '"$SLUG_SRC"'
             '"$PRREF_SRC"'
             '"$1"; }
: > "$T/gh.txt"
R6 'a=$(br_pr_ref https://github.com/o/tproj/pull/64); b=$(br_pr_ref https://github.com/o/tproj/pull/64); printf "%s\n%s\n" "$a" "$b" > "$T/ref"'
[ "$(sed -n 1p "$T/ref")" = "o/tproj ticket/TK-64 $(HEAD_OF 64)" ] && ok || bad "R6: br_pr_ref must print '<slug> <branch> <head>', got '$(sed -n 1p "$T/ref")'"
[ "$(sed -n 2p "$T/ref")" = "$(sed -n 1p "$T/ref")" ] && ok || bad "R6: the memo answer must be the same line"
[ "$(NGH 'pulls/64')" = 1 ] && ok || bad "R6: two br_pr_ref calls must read pulls/64 once, got $(NGH 'pulls/64'): $(cat "$T/gh.txt")"
# The failed read: the REST read answers 500, the raw read fails with gh's own
# words, and br_pr_ref still answers rc 2 with those words (the text
# tests/resolver-pr-read-failed-test.sh pins).
: > "$T/gh.txt"; echo 500 > "$T/f/status-64"
R6 'r=0; out=$(br_pr_ref https://github.com/o/tproj/pull/64) || r=$?; printf "%s\n%s\n" "$r" "$out" > "$T/ref"'
rm -f "$T/f/status-64"
[ "$(sed -n 1p "$T/ref")" = 2 ] && ok || bad "R6: a failed read must answer rc 2, got '$(sed -n 1p "$T/ref")'"
[ "$(sed -n 2p "$T/ref")" = "gh: fixture error (HTTP 500)" ] && ok || bad "R6: BR_PR_REF_ERR must be gh's own first error line, got '$(sed -n 2p "$T/ref")'"
[ "$(grep -c -- '--jq' "$T/gh.txt")" = 2 ] && ok || bad "R6: the raw two-try loop must still run on a failed read, got $(grep -c -- '--jq' "$T/gh.txt") raw reads"

echo "blocked-resolver-readmemo: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
