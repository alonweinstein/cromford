#!/bin/bash
# tests/prompt-rollout-rule.bh-1338-test.sh — every prompt that carries the
# DECOMPOSED sweep rule also carries the ROLLOUT one, in its own lane's wording.
#
# WHY IT EXISTS (BH-1338, follow-up 2 of the round-2 review of #1113). BH-985
# gave `ROLLOUT_FILED` / `ROLLOUT_FAILED` a result-sweep rule and put it in the
# seven prompts that ticket named. Six more prompts carry the DECOMPOSED rule
# and were never updated, so a watcher session on those projects reads a
# `ROLLOUT_FILED` result with no instruction: it does not know the master was
# parked on purpose and is one re-label away from re-building a ticket whose
# waves are already filed. Section F of the bh-985 suite pins the seven; this
# pins the six, and pins them to the TEMPLATE line rather than to a paraphrase,
# because the failure mode here is drift, not absence.
#
# WHAT IT PINS, per prompt file:
#   1. The template line it must match is itself present and is the ROLLOUT
#      bullet (the vacuity guard — a template that lost the line makes every
#      comparison below trivially true).
#   2. Exactly one line in the prompt carries the rule's markers.
#   3. That line is byte-identical to the template's.
#   4. It sits immediately after the DECOMPOSE_FAILED bullet.
#   5. Lane wording: GH-lane files talk about `re-label`; in-app files talk
#      about `in_progress` and never about labels.
#
# GH lane (issues projects) renders from prompts/TEMPLATE-GH.md; in-app board
# projects render from prompts/TEMPLATE.md. The two bullets differ on purpose —
# an in-app master is moved to `in_progress`, not de-labelled — so a file that
# got the wrong lane's bullet is as wrong as one that got none.
#
# Run from anywhere: bash tests/prompt-rollout-rule.bh-1338-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The bullet's opener, shared by both templates. Used as the vacuity guard.
OPENER='- **`ROLLOUT_FILED` / `ROLLOUT_FAILED` — a rollout master, waves filed or not:**'

line_with() { # line_with <file> <substring...> -> "<lineno>" of every line carrying all
  local f="$1"; shift
  local out p
  out=$(grep -n . "$DIR/$f" 2>/dev/null)
  for p in "$@"; do out=$(grep -F -- "$p" <<<"$out"); done
  printf '%s\n' "$out" | grep -E '^[0-9]+:' | cut -d: -f1
}

# ── the two template lines, and the guard that they are real ────────────────
declare -A TPL_LINE TPL_TEXT
for LANE in gh inapp; do
  case "$LANE" in
    gh)    TF=prompts/TEMPLATE-GH.md ;;
    inapp) TF=prompts/TEMPLATE.md ;;
  esac
  LN=$(line_with "$TF" ROLLOUT_FILED ROLLOUT_FAILED rollout-run.txt COMMENTED | head -1)
  if [ -z "$LN" ]; then
    bad "guard: $TF carries no rollout sweep bullet at all — every comparison below would be vacuous"
    TPL_LINE[$LANE]=""; TPL_TEXT[$LANE]=""
    continue
  fi
  TXT=$(sed -n "${LN}p" "$DIR/$TF")
  [ -n "$TXT" ] && ok || bad "guard: $TF:$LN is empty"
  case "$TXT" in
    "$OPENER"*) ok ;;
    *) bad "guard: $TF:$LN is not the rollout bullet (starts '${TXT:0:60}…')" ;;
  esac
  TPL_LINE[$LANE]="$LN"; TPL_TEXT[$LANE]="$TXT"
done

# ── each prompt against its lane's template line ────────────────────────────
check() { # check <lane: gh|inapp> <prompt file>
  local lane="$1" f="$2" tpl="${TPL_TEXT[$1]}"
  local lns n txt ld
  if [ -z "$tpl" ]; then
    bad "$f: no template line to compare against (see the guard above)"
    return
  fi
  lns=$(line_with "$f" ROLLOUT_FILED ROLLOUT_FAILED rollout-run.txt COMMENTED)
  n=$(grep -c . <<<"$lns")
  [ -z "$lns" ] && n=0
  if [ "$n" != 1 ]; then
    bad "$f must carry the rollout sweep rule on exactly one line, got $n"
    return
  fi
  ok
  txt=$(sed -n "${lns}p" "$DIR/$f")
  if [ "$txt" = "$tpl" ]; then ok
  else
    bad "$f:$lns must be byte-identical to the $lane template line; diff:
$(diff <(printf '%s\n' "$tpl") <(printf '%s\n' "$txt") | head -8)"
  fi
  ld=$(line_with "$f" DECOMPOSE_FAILED | head -1)
  if [ -z "$ld" ]; then
    bad "$f carries no DECOMPOSE_FAILED bullet — this suite's placement rule does not apply to it"
  else
    [ "$lns" = "$((ld + 1))" ] && ok \
      || bad "$f must place the rollout rule directly after the DECOMPOSE_FAILED bullet (rollout=$lns decompose=$ld)"
  fi
  # Lane wording. The bullets differ because the two lanes park a master
  # differently; the wrong lane's bullet is a wrong instruction, not a nit.
  case "$lane" in
    gh)
      grep -qF -- 're-label' <<<"$txt" && ok \
        || bad "$f is a GH-lane prompt — its rollout rule must say the master is not re-labelled" ;;
    inapp)
      grep -qF -- 'in_progress' <<<"$txt" && ok \
        || bad "$f is an in-app prompt — its rollout rule must name the \`in_progress\` master" ;;
  esac
  if [ "$lane" = inapp ]; then
    grep -qF -- 're-label' <<<"$txt" \
      && bad "$f is an in-app board — its rollout rule must not talk about labels" || ok
    grep -qF -- 'ai-build' <<<"$txt" \
      && bad "$f is an in-app board — its rollout rule must not name the \`ai-build\` label" || ok
  fi
}

for F in prompts/project-5.md prompts/project-7.md prompts/project-10.md prompts/harness-console.md; do
  check gh "$F"
done
for F in prompts/project-8.md prompts/project-9.md; do
  check inapp "$F"
done

echo "prompt-rollout-rule.bh-1338: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
