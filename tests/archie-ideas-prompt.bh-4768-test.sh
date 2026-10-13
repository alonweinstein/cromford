#!/bin/bash
# tests/archie-ideas-prompt.bh-4768-test.sh — BH-4768 (slice 5 of #4760): the
# inward ideas prompt catalog/prompts/archie-ideas.md and its replay cases.
#
#   I0   this PR touches nothing under bin/, worker/, cron/ or catalog/lanes
#        (skipped when origin/main..HEAD holds no BH-4768 commit)
#   I1a  the first line is the prompt's title
#   I1b  the input contract names each ledger key, the open issues and the
#        recent ideas, and sends outside-world ideas to archie-research.sh
#   I1c  the five answer words, NONE:, and "at most one"
#   I1d  the no-number and duplicate rules
#   I1e  COST is in AI coding sessions, never human time
#   I1f  the caller writes the ledger row (prow_put); never claim a filing
#   R    bin/archie-skill-replay.sh passes the two archie-ideas cases and the
#        archie-check cases on the same root, 0 failed
#   R2   SKILL.md carries the prompt: and verdicts: lines
#   R3   case 01 answers in the five lines with numbers; case 02 has no number
#   V1   no em or en dash in the prompt or the recorded replies
#
# The replay case DRIVES bin/archie-skill-replay.sh with its default recorded
# replayer. Nothing here calls a vendor.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-ideas-prompt.bh-4768-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PROMPT="$REPO/catalog/prompts/archie-ideas.md"
SKILL="$REPO/catalog/prompts/replays/archie-ideas"
C1="$SKILL/replays/01-idea-with-evidence"
C2="$SKILL/replays/02-no-number-rejected"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -s "$PROMPT" ] || bad "I1 ${PROMPT#"$REPO"/} is missing"

# --- I0 no lane, cron, bin or worker change in this ticket --------------------
# Only the files of BH-4768's own commits, and only while they are on the
# branch: after the merge the range is empty or holds other tickets' files.
OWN=$(git -C "$REPO" log --name-only --format= --grep='BH-4768' origin/main..HEAD 2>/dev/null | sed '/^$/d')
if [ -z "$OWN" ]; then
  echo "skip: I0 no BH-4768 commit in origin/main..HEAD"; ok
else
  HIT=$(grep -E '^(bin|worker|cron)/|^catalog/lanes' <<<"$OWN")
  if [ -z "$HIT" ]; then ok; else bad "I0 BH-4768 commits touch: $HIT"; fi
fi

# --- I1a title ----------------------------------------------------------------
if [ "$(head -1 "$PROMPT" 2>/dev/null)" = '# Archie inward ideas (BH-4760)' ]; then ok
else bad "I1a first line: $(head -1 "$PROMPT" 2>/dev/null)"; fi

# --- I1b input contract -------------------------------------------------------
for k in build_outcomes fix_rounds parks_by_reason alert_families cost_by_lane rework \
         open_ai_build_issues recent_ideas archie-research.sh; do
  if grep -qF -- "$k" "$PROMPT" 2>/dev/null; then ok; else bad "I1b prompt does not name $k"; fi
done

# --- I1c answer words ---------------------------------------------------------
for w in 'IDEA:' 'EVIDENCE:' 'EXPECTED:' 'COST:' 'TICKET:' 'NONE:'; do
  if grep -qF -- "$w" "$PROMPT" 2>/dev/null; then ok; else bad "I1c prompt lacks '$w'"; fi
done
if grep -qi 'at most one' "$PROMPT" 2>/dev/null; then ok; else bad "I1c prompt lacks 'at most one'"; fi

# --- I1d no number, duplicate -------------------------------------------------
for w in 'NONE: no number' 'NONE: duplicate of #' 'NONE: duplicate of <slug>'; do
  if grep -qF -- "$w" "$PROMPT" 2>/dev/null; then ok; else bad "I1d prompt lacks '$w'"; fi
done

# --- I1e cost unit ------------------------------------------------------------
if grep -qF 'AI coding sessions' "$PROMPT" 2>/dev/null && grep -qiF 'never human time' "$PROMPT" 2>/dev/null; then ok
else bad "I1e the COST unit rule is missing"; fi

# --- I1f the caller writes the row --------------------------------------------
if grep -qF 'prow_put' "$PROMPT" 2>/dev/null && grep -qi 'never say that you filed' "$PROMPT" 2>/dev/null; then ok
else bad "I1f the caller-writes rule is missing"; fi

# --- R the replay cases pass through the real runner --------------------------
"$REPO/bin/archie-skill-replay.sh" --root "$REPO/catalog/prompts/replays" > "$T/out" 2>"$T/err"; RC=$?
for l in 'PASS archie-ideas/01-idea-with-evidence propose' 'PASS archie-ideas/02-no-number-rejected none' \
         'PASS archie-check/01-unreadable-metric speak' 'PASS archie-check/02-events-need-nothing blank'; do
  if grep -qx "$l" "$T/out"; then ok; else bad "R missing line '$l'"; fi
done
if [ "$RC" = 0 ] && ! grep -q '^FAIL' "$T/out" && tail -1 "$T/out" | grep -q ' 0 failed$'; then ok
else bad "R replay root: rc=$RC $(cat "$T/out" "$T/err")"; fi

# --- R2 SKILL.md frontmatter --------------------------------------------------
if grep -qx 'prompt: prompts/archie-soul.d catalog/prompts/archie-ideas.md' "$SKILL/SKILL.md" 2>/dev/null; then ok
else bad "R2 SKILL.md prompt: line"; fi
if grep -qx 'verdicts: propose | none' "$SKILL/SKILL.md" 2>/dev/null; then ok
else bad "R2 SKILL.md verdicts: line"; fi

# --- R3 the recorded replies keep the contract --------------------------------
# Case 01: the five lines, in order, before the VERDICT line.
grep -oE '^(IDEA|EVIDENCE|EXPECTED|COST|TICKET):' "$C1/recorded.txt" 2>/dev/null | tr '\n' ' ' > "$T/order"
if [ "$(cat "$T/order")" = 'IDEA: EVIDENCE: EXPECTED: COST: TICKET: ' ]; then ok
else bad "R3 case 01 answer lines: $(cat "$T/order")"; fi
if grep -E '^EVIDENCE:' "$C1/recorded.txt" 2>/dev/null | grep -q '[0-9]'; then ok
else bad "R3 case 01 EVIDENCE has no number"; fi
if grep -E '^COST:' "$C1/recorded.txt" 2>/dev/null | grep -qF 'AI coding sessions'; then ok
else bad "R3 case 01 COST is not in AI coding sessions"; fi
if grep -qx 'NONE: no number' "$C2/recorded.txt" 2>/dev/null && ! grep -q '^IDEA:' "$C2/recorded.txt"; then ok
else bad "R3 case 02 is not 'NONE: no number' alone"; fi
if [ -f "$C2/input.md" ] && python3 - "$C2/input.md" <<'PY'; then ok; else bad "R3 case 02 ledgers carry a digit"; fi
import json, re, sys
d = json.load(open(sys.argv[1]))
sys.exit(1 if re.search(r"[0-9]", json.dumps(d["ledgers"])) else 0)
PY

# --- V1 no em or en dash ------------------------------------------------------
for f in "$PROMPT" "$C1/recorded.txt" "$C2/recorded.txt"; do
  [ -f "$f" ] || { bad "V1 ${f#"$REPO"/} is missing"; continue; }
  if grep -qP '[\x{2013}\x{2014}]' "$f"; then bad "V1 em or en dash in ${f#"$REPO"/}"; else ok; fi
done

echo "archie-ideas-prompt: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
