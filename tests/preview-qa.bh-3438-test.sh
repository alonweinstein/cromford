#!/bin/bash
# tests/preview-qa.bh-3438-test.sh — BH-3438: preview QA on a project whose
# previews cannot sign in, and a preview-QA skip that says why it skipped.
#
#   F  bin/evidence-summary.sh puts the skip reason from qa.md on the
#      `| preview QA | skipped — … |` row of the PR's evidence block
#   G  the pipeline's fail-open branch writes the fail-open line with its exact
#      prefix plus wait-preview.sh's last stderr line (driven: the block between
#      `# >>> preview-qa skip reason` markers, evaled against a fixture)
#   H  preview_qa_mode (bin/lib/preview-qa-mode.sh): project-5 reads signed-out
#      from catalog/preview-qa.conf; another project, a missing file, a bogus
#      mode and a malformed row all read auth
#   I  the QA prompt for project-5 tells the session not to sign in and to drive
#      signed out; the prompt for project-3 does not; both QA calls use it
#   J  the tier-1 QA gate demotes a counted, shot-backed project-5 PASS to
#      tier-2 (SIGNED-OUT ONLY); the same PASS on project-3 stays tier-1
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/preview-qa.bh-3438-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
EV="$DIR/bin/evidence-summary.sh"
LIB="$DIR/bin/lib/preview-qa-mode.sh"
CONF="$DIR/catalog/preview-qa.conf"
STAMP() { echo 2026-09-29T00:00:00Z; }

# --- F. the reason reaches the PR's evidence row --------------------------------------
BF="$T/rec-skip-403"; mkdir -p "$BF"
printf 'preview unavailable — QA skipped (fail-open): deployments API denied (HTTP 403) and no Vercel snapshot for project-5 — QA cannot see previews\n' > "$BF/qa.md"
OUT=$("$EV" "$BF" 2 "")
ROW=$(grep '^| preview QA |' <<<"$OUT")
grep -q '^| preview QA | skipped —' <<<"$ROW" && ok || bad "F: the row must still open '| preview QA | skipped —': $ROW"
grep -q 'HTTP 403' <<<"$ROW" && ok || bad "F: the skip reason is not on the preview QA row: $ROW"
[ "$(awk -F'|' '{print NF}' <<<"$ROW")" = 4 ] && ok || bad "F: the reason split the table row: $ROW"
# A PASS row carries no skip text even when the file has other lines.
BF2="$T/rec-pass"; mkdir -p "$BF2"
printf 'drove it\nQA COVERAGE: screens=1 flows=1 shots=1\nQA: PASS\n' > "$BF2/qa.md"
ROW2=$(grep '^| preview QA |' <<<"$("$EV" "$BF2" 2 "")")
grep -q 'preview unavailable' <<<"$ROW2" \
  && bad "F: a PASS row rendered a skip reason" || ok

# --- G. the fail-open branch writes the reason ------------------------------------------
awk '/^# >>> preview-qa skip reason/{f=1;next} /^# <<< preview-qa skip reason/{exit} f' "$RB_ALL" > "$T/skip.sh"
if [ -s "$T/skip.sh" ]; then
  ok
  BUILD="$T/g1"; mkdir -p "$BUILD"
  printf 'wait-preview: polling\n\nwait-preview.sh: deployments API denied (HTTP 403) and no Vercel snapshot for project-5\n\n' > "$BUILD/wait-preview.err"
  ( . "$T/skip.sh" )
  L=$(cat "$BUILD/qa.md" 2>/dev/null)
  [ "$L" = "preview unavailable — QA skipped (fail-open): wait-preview.sh: deployments API denied (HTTP 403) and no Vercel snapshot for project-5" ] \
    && ok || bad "G: the fail-open line must carry the last non-empty stderr line: [$L]"
  BUILD="$T/g2"; mkdir -p "$BUILD"; : > "$BUILD/wait-preview.err"
  ( . "$T/skip.sh" )
  L=$(cat "$BUILD/qa.md" 2>/dev/null)
  [ "$L" = "preview unavailable — QA skipped (fail-open): no reason given" ] \
    && ok || bad "G: an empty stderr must say 'no reason given': [$L]"
else
  bad "G: no '# >>> preview-qa skip reason' block in the pipeline"
fi
# Both wait-preview calls capture stderr to the file the reason is read from.
[ "$(grep -c '2>"\$BUILD/wait-preview.err"' "$RB_ALL")" -ge 2 ] \
  && ok || bad "G: both wait-preview.sh calls must write \$BUILD/wait-preview.err"

# --- H. the registry ---------------------------------------------------------------------
if . "$LIB" 2>/dev/null; then
  ok
  [ "$(preview_qa_mode project-5 "$CONF")" = signed-out ] && ok || bad "H: project-5 must read signed-out from $CONF"
  [ "$(preview_qa_mode project-3 "$CONF")" = auth ] && ok || bad "H: project-3 must read auth"
  [ "$(preview_qa_mode project-5 "$T/nope.conf")" = auth ] && ok || bad "H: a missing conf must read auth"
  printf '# c\nx bogus\nproject-5\nproject-5-os signed-out\n' > "$T/h.conf"
  [ "$(preview_qa_mode x "$T/h.conf")" = auth ] && ok || bad "H: an unknown mode must read auth"
  [ "$(preview_qa_mode project-5 "$T/h.conf")" = auth ] && ok || bad "H: a row with no mode must read auth"
  [ "$(preview_qa_mode project-5-os "$T/h.conf")" = signed-out ] && ok || bad "H: a well-formed row must read its mode"
  [ "$(HARNESS="$DIR" preview_qa_mode project-5)" = signed-out ] && ok || bad "H: the default conf path must be \$HARNESS/catalog/preview-qa.conf"
  [ "$(HARNESS='' H='' preview_qa_mode project-5)" = auth ] && ok || bad "H: no root must read auth"
else
  bad "H: $LIB does not source"
fi

# --- I. the prompt ---------------------------------------------------------------------
awk '/^# >>> preview-qa mode/{f=1;next} /^# <<< preview-qa mode/{exit} f' "$RB_ALL" > "$T/mode.sh"
if [ -s "$T/mode.sh" ]; then
  ok
  prompt_for() { # prompt_for <project>
    ( QA_PROMPT_FOR() { printf 'BASE PROMPT for %s.' "$1"; }
      HARNESS="$DIR"; PROJECT="$1"; . "$T/mode.sh"; QA_PROMPT_MODE https://preview.test )
  }
  P1=$(prompt_for project-5)
  grep -q '^BASE PROMPT for https://preview.test\.' <<<"$P1" && ok || bad "I: the base prompt must come first: $P1"
  grep -q 'Do NOT attempt a Clerk sign-in' <<<"$P1" && ok || bad "I: project-5's prompt must forbid the sign-in: $P1"
  grep -q 'QA AUTH: signed-out' <<<"$P1" && ok || bad "I: project-5's prompt must ask for the QA AUTH line: $P1"
  P2=$(prompt_for project-3)
  [ "$P2" = "BASE PROMPT for https://preview.test." ] && ok || bad "I: project-3's prompt must be the base prompt unchanged: $P2"
else
  bad "I: no '# >>> preview-qa mode' block in the pipeline"
fi
[ "$(grep -c 'CC qa .*"\$(QA_PROMPT_MODE "\$PREVIEW_URL")' "$RB_ALL")" = 2 ] \
  && ok || bad "I: both QA calls (first pass and re-QA) must use QA_PROMPT_MODE"

# --- J. the tier-1 QA gate ----------------------------------------------------------------
awk '/^QA_NOTE="\$\{SIZE_NOTE:-\}"$/{f=1} f{print} /^# <<< preview-qa signed-out/{exit}' "$RB_ALL" > "$T/gate.sh"
if grep -q 'preview-qa signed-out' "$T/gate.sh"; then
  ok
  gate() { # gate <project> -> "TIER|QA_NOTE"
    local BUILD="$T/j-$1"; scratch_rm "$BUILD"; mkdir -p "$BUILD/qa-shots"
    printf 'drove it\nMAP ENTRIES: none\nQA COVERAGE: screens=2 flows=1 shots=2\nQA: PASS\n' > "$BUILD/qa.md"
    : > "$BUILD/qa-shots/a.png"; : > "$BUILD/qa-shots/b.png"
    ( HARNESS="$DIR"; PROJECT="$1"; KEY=K-1; TIER=1; SIZE_NOTE=""
      . "$T/gate.sh"; printf '%s|%s' "$TIER" "$QA_NOTE" )
  }
  R=$(gate project-5)
  [ "${R%%|*}" = 2 ] && ok || bad "J: a signed-out project-5 PASS must demote to tier-2 (got $R)"
  grep -q 'SIGNED-OUT ONLY' <<<"$R" && ok || bad "J: the note must say SIGNED-OUT ONLY (got $R)"
  grep -q 'SIGNED-OUT ONLY' "$T/j-project-5/pipeline.log" 2>/dev/null && ok || bad "J: the demotion must be logged to pipeline.log"
  R=$(gate project-3)
  [ "$R" = "1|" ] && ok || bad "J: the same PASS on project-3 must stay tier-1 with no note (got $R)"
else
  bad "J: no '# <<< preview-qa signed-out' marker after the QA gate"
fi

echo "preview-qa.bh-3438: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
