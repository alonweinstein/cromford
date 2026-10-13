#!/bin/bash
# tests/tier-wording-lint.bh-4582-test.sh — the human-seat tier wording lint
# (BH-4582, BH-4572.3): bin/lint-tier-wording.sh and its rules-pack row.
#
#   L1. "tier-2 waits for the operator" added to prompts/x.md: rc 1, names file:line.
#   L2. a clean added line ("risk tiers are reported, not gated"): rc 0, no stdout.
#   L3. "human seat" added in rules/topics/: rc 1, names file:line.
#   L4. the real tree, --all: rc 0, no stdout.
#   L5. delta mode judges ADDED lines only: a phrase already at the base is
#       quiet; the same file under --all is rc 1.
#   L6. the scan set: the phrase in docs/notes/, bin/ or prompts/greenfield/
#       is quiet.
#   L7. --base nosuchref is rc 2 naming it; a non-git root in delta mode is rc 2.
#   L8. adversarial negatives stay quiet; each banned variant is rc 1.
#   L10. skills/*/SKILL.md is in the scan set (the ticket says "rules,
#        prompts and skills"): the phrase there is rc 1 in delta and --all
#        mode; another file under skills/ stays quiet.
#   L9. the production entry point: bin/rules-pack.sh --only tier-wording on a
#       fixture that adds the phrase to prompts/TEMPLATE-GH.md is red and
#       prints exactly the routed `tier-wording: <path>:<n>: ...` line.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/tier-wording-lint.bh-4582-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LINT="$DIR/bin/lint-tier-wording.sh"
[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1

# run <cmd...> — sets RC, OUT, ERR
run() {
  "$@" >"$T/out" 2>"$T/err"; RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
lint() { run bash "$LINT" "$@"; }

# tests/ is outside the lint's scan set, so the phrases can sit here verbatim.
P_WAIT="tier-2 waits for the operator"; P_SEAT="the deliberate human seat"; P_MERGE="the operator merges tier-2"

# --- the fixture ----------------------------------------------------------
R="$T/r"
mkdir -p "$R/prompts" "$R/rules/topics"
printf '# x\n\nsome prompt text\n' > "$R/prompts/x.md"
printf '# template\n- PRs only.\n' > "$R/prompts/TEMPLATE-GH.md"
printf '# topic\n\nrule text\n' > "$R/rules/topics/02-x.md"
printf '# rules\n\nrendered text\n%s\n' "$P_MERGE; old line" > "$R/rules/CLAUDE.md"
rd_fixture_repo "$R" || { echo "FAIL: cannot build the fixture repo"; exit 1; }
rd_git "$R" config gc.auto 0; rd_git "$R" config maintenance.auto false
B0=$(rd_git "$R" rev-parse HEAD)
reset_fx() { rd_git "$R" checkout -qf -B work "$B0"; rd_git "$R" clean -fdxq; }
commit() { rd_git "$R" add -A && rd_git "$R" commit -qm "$1"; }

# --- L1 -------------------------------------------------------------------
reset_fx
echo "$P_WAIT" >> "$R/prompts/x.md"; commit L1
N=$(wc -l < "$R/prompts/x.md")
lint --base "$B0" "$R"
[ "$RC" -eq 1 ] && ok || bad "L1 rc $RC (want 1): $OUT $ERR"
[ "$OUT" = "prompts/x.md:$N: tier-wording: $P_WAIT" ] && ok || bad "L1 stdout [$OUT] (want prompts/x.md:$N: tier-wording: $P_WAIT)"
case "$ERR" in *"1 "*) ok ;; *) bad "L1 stderr has no count: $ERR" ;; esac

# --- L2 -------------------------------------------------------------------
reset_fx
echo "risk tiers are reported, not gated" >> "$R/prompts/x.md"; commit L2
lint --base "$B0" "$R"
[ "$RC" -eq 0 ] && ok || bad "L2 rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "L2 stdout [$OUT] (want empty)"

# --- L3 -------------------------------------------------------------------
reset_fx
printf 'Tier 2 keeps %s for now.\n' "$P_SEAT" >> "$R/rules/topics/02-x.md"; commit L3
N=$(wc -l < "$R/rules/topics/02-x.md")
lint --base "$B0" "$R"
[ "$RC" -eq 1 ] && ok || bad "L3 rc $RC (want 1): $OUT $ERR"
case "$OUT" in "rules/topics/02-x.md:$N: tier-wording: "*) ok ;; *) bad "L3 stdout [$OUT] does not name rules/topics/02-x.md:$N" ;; esac

# --- L4 -------------------------------------------------------------------
lint --all "$DIR"
[ "$RC" -eq 0 ] && ok || bad "L4 real tree --all rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "L4 real tree --all stdout: $OUT"

# --- L5 -------------------------------------------------------------------
reset_fx
echo "an unrelated rendered line" >> "$R/rules/CLAUDE.md"; commit L5
lint --base "$B0" "$R"
[ "$RC" -eq 0 ] && ok || bad "L5 delta rc $RC (want 0, the phrase is at the base): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "L5 delta stdout [$OUT] (want empty)"
lint --all "$R"
[ "$RC" -eq 1 ] && ok || bad "L5 --all rc $RC (want 1): $OUT $ERR"
[ "$OUT" = "rules/CLAUDE.md:4: tier-wording: $P_MERGE; old line" ] && ok || bad "L5 --all stdout [$OUT]"

# --- L6 -------------------------------------------------------------------
reset_fx
mkdir -p "$R/prompts/greenfield" "$R/docs/notes" "$R/bin"
echo "$P_WAIT" > "$R/docs/notes/x.md"
echo "# $P_WAIT" > "$R/bin/x.sh"
echo "$P_WAIT" > "$R/prompts/greenfield/x.md"
commit L6
lint --base "$B0" "$R"
[ "$RC" -eq 0 ] && ok || bad "L6 out-of-scan-set rc $RC (want 0): $OUT $ERR"
[ -z "$OUT" ] && ok || bad "L6 stdout [$OUT] (want empty)"

# --- L7 -------------------------------------------------------------------
reset_fx
lint --base nosuchref "$R"
[ "$RC" -eq 2 ] && ok || bad "L7 --base nosuchref rc $RC (want 2)"
case "$ERR" in *nosuchref*) ok ;; *) bad "L7 stderr does not name nosuchref: $ERR" ;; esac
mkdir -p "$T/nogit/prompts"; echo "$P_WAIT" > "$T/nogit/prompts/x.md"
lint "$T/nogit"
[ "$RC" -eq 2 ] && ok || bad "L7 non-git root in delta mode rc $RC (want 2): $OUT $ERR"
lint --all "$T/nogit"
[ "$RC" -eq 1 ] && ok || bad "L7 non-git root --all rc $RC (want 1, no git needed): $OUT $ERR"
lint --bogus "$R"
[ "$RC" -eq 2 ] && ok || bad "L7 --bogus rc $RC (want 2)"

# --- L8 -------------------------------------------------------------------
reset_fx
cat >> "$R/prompts/x.md" <<'EOF'
- Tier-2 alert remediator runs on the hub.
- When it is stuck, page a human.
- A third red arms the tier-2 demotion.
- tier-2 merges via the harness merge sweep after review.
- never name a person as the blocker.
- The factory merges every tier on lead review + gates; risk tiers are reported, not gated.
EOF
commit L8-negatives
lint --base "$B0" "$R"
[ "$RC" -eq 0 ] && ok || bad "L8 negatives rc $RC (want 0): $OUT"
for v in "Tier 2 needs a human to land" "AWAITING OPERATOR on this one" "the operator merges tier2 by hand" \
         "tier-2 is for a person to merge"; do
  reset_fx
  echo "$v" >> "$R/prompts/x.md"; commit "L8 $v"
  lint --base "$B0" "$R"
  [ "$RC" -eq 1 ] && ok || bad "L8 variant [$v] rc $RC (want 1): $OUT $ERR"
done

# --- L10 skills/*/SKILL.md -------------------------------------------------
reset_fx
mkdir -p "$R/skills/foo"
printf '# foo skill\n\nclean text\n%s\n' "$P_WAIT" > "$R/skills/foo/SKILL.md"
echo "$P_WAIT" > "$R/skills/foo/notes.md"
commit L10
lint --base "$B0" "$R"
[ "$RC" -eq 1 ] && ok || bad "L10 skills/foo/SKILL.md rc $RC (want 1): $OUT $ERR"
[ "$OUT" = "skills/foo/SKILL.md:4: tier-wording: $P_WAIT" ] && ok || bad "L10 stdout [$OUT] (want only skills/foo/SKILL.md:4)"
lint --all "$R"
case "$OUT" in *"skills/foo/SKILL.md:4: tier-wording:"*) ok ;; *) bad "L10 --all does not scan skills/*/SKILL.md: $OUT" ;; esac
case "$OUT" in *"skills/foo/notes.md"*) bad "L10 --all scanned a non-SKILL.md file under skills/: $OUT" ;; *) ok ;; esac

# --- L9 the production entry point -----------------------------------------
# The fixture is this checkout's HEAD with the lint's three working files laid
# over it, so the case means the same thing before and after the commit.
F="$T/fx"
mkdir -p "$F"
git -C "$DIR" archive HEAD | tar -x -C "$F" || { echo "FAIL: cannot archive HEAD"; exit 1; }
for p in bin/lint-tier-wording.sh bin/rules-pack.sh catalog/rules-pack.tsv; do
  [ -f "$DIR/$p" ] && cp -p "$DIR/$p" "$F/$p"
done
rd_fixture_repo "$F" || { echo "FAIL: cannot build the L9 fixture"; exit 1; }
rd_git "$F" config gc.auto 0; rd_git "$F" config maintenance.auto false
FB=$(rd_git "$F" rev-parse HEAD)
echo "$P_WAIT" >> "$F/prompts/TEMPLATE-GH.md"
N=$(wc -l < "$F/prompts/TEMPLATE-GH.md")
rd_git "$F" add -A && rd_git "$F" commit -qm L9
mkdir -p "$T/nolg"
run env HARNESS="$T/nolg" HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/rules-pack.sh" --tree "$F" --base "$FB" \
  --only tier-wording --runner local --out "$T/o9"
[ "$RC" -eq 1 ] && ok || bad "L9 rules-pack rc $RC (want 1): $OUT $ERR"
[ "$OUT" = "tier-wording: prompts/TEMPLATE-GH.md:$N: tier-wording: $P_WAIT" ] && ok \
  || bad "L9 stdout [$OUT] (want tier-wording: prompts/TEMPLATE-GH.md:$N: tier-wording: $P_WAIT)"
[ "$(jq -r '.components[0].id + " " + .components[0].state' "$T/o9/summary.json" 2>/dev/null)" = "tier-wording red" ] && ok \
  || bad "L9 summary.json components[0] $(jq -c '.components[0]' "$T/o9/summary.json" 2>/dev/null) (want tier-wording red)"

echo "tier-wording-lint: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
