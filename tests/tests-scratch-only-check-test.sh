#!/bin/bash
# tests/tests-scratch-only-check-test.sh — the scratch-only check must FIRE.
#
# checks/tests-scratch-only/check.sh is the static half of the answer to the
# 2026-09-15 hub wipe (#388, root cause #404): a test that never sourced the
# scratch lib re-derived $H as the LIVE harness root and rm -rf'd it. The check
# reads a tree (or a diff) and says which lines could do that again.
#
# Everything here drives the REAL check and the REAL bin/checks-run.sh over
# fixture trees copied under $T. Nothing greps the check's source: what a
# detector is worth is what it printed, on a tree that was actually scanned.
#
# Self-contained: no network, no secrets, no $HARNESS.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
C="$DIR/checks/tests-scratch-only"
RUN="$DIR/bin/checks-run.sh"
F="$C/fixtures"
FAMILY=b3957447980a
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The fixture trees are COPIED, not run: they are data describing bad and good
# shapes, and one of them contains an rm -rf "$H".
cp -r "$F/tree-bad"  "$T/bad"  2>/dev/null || bad "could not copy tree-bad into the scratch tree"
cp -r "$F/tree-good" "$T/good" 2>/dev/null || bad "could not copy tree-good into the scratch tree"

# ── A0. the fixtures are INERT when something DOES execute them ────────────
# "Nothing runs the fixtures" is not a safety property this repo controls. This
# build's own bin/repro-gate.sh globbed all fifteen fixture scripts as added
# test files and ran bash over the list; it survived only because check.sh sorts
# first in argv and that runner executes one file. tree-bad/tests/rm-h-test.sh
# is a loaded #388 — it must not be able to delete a harness even when it IS
# executed, as root, with HARNESS set. So: run every fixture script against a
# fake harness and prove the fake harness is still standing afterwards.
mkdir -p "$T/fake-harness/state" "$T/fake-harness/plans/p" "$T/fake-harness/builds/b"
mkdir -p "$T/fake-repos/keep"
for FX in "$T"/bad/tests/*.sh "$T"/good/tests/*.sh \
          "$T"/bad/bin/*.sh "$T"/bad/bin/lib/*.sh "$T"/good/bin/*.sh; do
  [ -f "$FX" ] || continue
  # Every path a fixture could aim at is redirected into the scratch tree, so a
  # fixture that is NOT inert deletes something this assertion can see.
  HARNESS="$T/fake-harness" H="$T/fake-harness" HARNESS_FIXTURE="$T/fake-harness" \
    REPOS_ROOT="$T/fake-repos" bash "$FX" >/dev/null 2>&1
done
GONE=""
for P in "$T/fake-harness" "$T/fake-harness/state" "$T/fake-harness/plans/p" \
         "$T/fake-harness/builds/b" "$T/fake-repos/keep"; do
  [ -d "$P" ] || GONE="$GONE $P"
done
[ -z "$GONE" ] && ok \
  || bad "executing the fixtures DELETED part of the fake harness:$GONE — fixtures must be inert"

# ── A. the check fires on every seeded shape in tree-bad ────────────────────
# One line per violation, each tagged with the rule it broke and the family, so
# a hit in a log is traceable without opening the catalog.
OUT=$(bash "$C/check.sh" --tree "$T/bad" 2>/dev/null); RC=$?
[ "$RC" = 1 ] && ok || bad "bad tree: rc was $RC, expected 1"
N=$(printf '%s\n' "$OUT" | grep -c .)
[ "$N" = 7 ] && ok || bad "bad tree: expected exactly 7 hits, got $N:
$OUT"
for E in "tests/no-source-test.sh:4 R1" \
         "tests/late-source-test.sh:4 R1" \
         "tests/rm-h-test.sh:7 R2" \
         "tests/bash-c-test.sh:6 R2" \
         "bin/unguarded.sh:6 R3" \
         "bin/literal.sh:5 R3" \
         "bin/lib/derived.sh:5 R3"; do
  LOC=${E%% *}; TAG=${E##* }
  HIT=$(printf '%s\n' "$OUT" | grep -F "$LOC	" )
  if [ -z "$HIT" ]; then
    bad "$LOC was not reported at all (expected $TAG):
$OUT"
  else
    grep -q "$TAG" <<<"$HIT" && ok || bad "$LOC was reported without its $TAG tag: $HIT"
    grep -q "(family $FAMILY)" <<<"$HIT" && ok || bad "$LOC was reported without the family key: $HIT"
  fi
done

# ── B. the check stays silent on tree-good ─────────────────────────────────
# A rule that matches nothing looks exactly like a clean tree, so the negatives
# carry the weight: mktemp-owned cleanups, both case-guard shapes, heredoc
# bodies, comments, a printf of a literal rm string, $T-prefixed deletions.
OUT=$(bash "$C/check.sh" --tree "$T/good" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "good tree: rc was $RC, expected 0"
[ -z "$OUT" ] && ok || bad "good tree: expected no output, got:
$OUT"

# ── C. a tree it cannot scan is rc 2, never a quiet clean ──────────────────
OUT=$(bash "$C/check.sh" --tree "$T/nonexistent" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "a missing tree must be rc 2, got $RC"
grep -q 'could not run' <<<"$OUT" && ok || bad "rc 2 must SAY it could not run, got: $OUT"
# A root that exists but is not a harness checkout is the same answer.
mkdir -p "$T/notarepo"
OUT=$(bash "$C/check.sh" --tree "$T/notarepo" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "a root with no tests/ and bin/ must be rc 2, got $RC"
# An unknown flag is a usage error, not a pass.
OUT=$(bash "$C/check.sh" --wat 2>&1 </dev/null); RC=$?
[ "$RC" = 2 ] && ok || bad "an unknown flag must be rc 2, got $RC"

# A SCANNER that died is the same answer. mawk quietly rejecting a pattern is
# the realistic shape (it is why the header bans {n} quantifiers), and the
# failure mode that matters is silence: awk dies, the output is empty, and the
# check exits 0 on a seven-violation tree. Both modes must fail closed instead.
mkdir -p "$T/fakebin"
printf '#!/bin/sh\necho "awk: boom" >&2\nexit 3\n' > "$T/fakebin/awk"
chmod +x "$T/fakebin/awk"
OUT=$(PATH="$T/fakebin:$PATH" bash "$C/check.sh" --tree "$T/bad" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "tree mode with a broken awk must be rc 2, got $RC: $OUT"
grep -q 'could not run' <<<"$OUT" \
  && ok || bad "tree mode with a broken awk must SAY it could not run, got: $OUT"
OUT=$(printf 'bin/x.sh\t3\trm -rf "$HARNESS/y"\n' \
  | PATH="$T/fakebin:$PATH" bash "$C/check.sh" - 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "diff mode with a broken awk must be rc 2, got $RC: $OUT"
grep -q 'could not run' <<<"$OUT" \
  && ok || bad "diff mode with a broken awk must SAY it could not run, got: $OUT"

# ── D. the RUNNER's tree mode — the production entry point ─────────────────
# CHECKS_DIR points at a scratch catalog holding only this check, so the counts
# below are this check's and nobody else's.
mkdir -p "$T/cat"
cp -r "$C" "$T/cat/tests-scratch-only"
chmod +x "$T/cat/tests-scratch-only/check.sh" 2>/dev/null

OUT=$(CHECKS_DIR="$T/cat" "$RUN" --tree "$T/bad" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "runner --tree on the bad tree: rc was $RC, expected 1"
N=$(grep -c '^CHECK-HIT tests-scratch-only ' <<<"$OUT")
[ "$N" = 7 ] && ok || bad "runner --tree on the bad tree: expected 7 CHECK-HIT lines, got $N:
$OUT"
grep -q '^CHECKS: 7 hit(s) — tests-scratch-only(x7)' <<<"$OUT" \
  && ok || bad "runner --tree summary wrong: $(grep '^CHECKS:' <<<"$OUT")"

OUT=$(CHECKS_DIR="$T/cat" "$RUN" --tree "$T/good" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "runner --tree on the good tree: rc was $RC, expected 0"
grep -q '^CHECKS: clean (1 tree check(s)' <<<"$OUT" \
  && ok || bad "runner --tree on the good tree must report the clean tree count, got: $OUT"

OUT=$(CHECKS_DIR="$T/cat" "$RUN" --tree "$T/nonexistent" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "runner --tree on a missing root must be rc 2, got $RC"
grep -q 'could not run' <<<"$OUT" && ok || bad "runner --tree rc 2 must say so, got: $OUT"

# A tree check that CRASHES fails the run closed. #463 wires this into CI, and a
# detector that died must never read as a tree with nothing to find.
mkdir -p "$T/boomcat/boom/fixtures/tree-bad"
printf '#!/bin/bash\nexit 3\n' > "$T/boomcat/boom/check.sh"; chmod +x "$T/boomcat/boom/check.sh"
OUT=$(CHECKS_DIR="$T/boomcat" "$RUN" --tree "$T/good" 2>&1); RC=$?
grep -q '^CHECK-ERROR boom rc=3' <<<"$OUT" \
  && ok || bad "a tree check exiting 3 must be reported as CHECK-ERROR, got: $OUT"
[ "$RC" = 2 ] && ok || bad "a crashed tree check must make the run rc 2, got $RC"

# The same thing end to end with the REAL check and a broken awk, on the tree
# that holds seven violations. Before the check learned to read its scanner's
# rc, this printed "CHECKS: clean" at rc 0 — the worst answer available.
OUT=$(PATH="$T/fakebin:$PATH" CHECKS_DIR="$T/cat" "$RUN" --tree "$T/bad" 2>&1); RC=$?
grep -q '^CHECK-ERROR tests-scratch-only rc=2' <<<"$OUT" \
  && ok || bad "a broken awk must surface as CHECK-ERROR through the runner, got: $OUT"
grep -q '^CHECKS: clean' <<<"$OUT" \
  && bad "a broken awk reported a CLEAN tree through the runner: $OUT" || ok
[ "$RC" = 2 ] && ok || bad "runner --tree with a broken awk must be rc 2, got $RC: $OUT"

# A catalog with no tree-capable check has scanned NOTHING. Saying "clean" there
# is the vacuous green this whole catalog exists to refuse.
mkdir -p "$T/stdincat"
cp -r "$DIR/checks/secret-literals" "$T/stdincat/secret-literals"
OUT=$(CHECKS_DIR="$T/stdincat" "$RUN" --tree "$T/good" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "a catalog with no tree-capable check must be rc 2, got $RC"
grep -q 'could not run — no tree-capable check' <<<"$OUT" \
  && ok || bad "rc 2 must name the reason, got: $OUT"

# ── E. diff mode of the check, through the REAL runner and REAL catalog ────
OUT=$("$RUN" "$F/violation.diff" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "the seeded violation diff must be rc 1, got $RC: $OUT"
N=$(grep -c '^CHECK-HIT tests-scratch-only bin/plan-sweep.sh:' <<<"$OUT")
[ "$N" = 2 ] && ok || bad "the violation diff must produce 2 hits on bin/plan-sweep.sh, got $N:
$OUT"
grep -q '^CHECK-HIT tests-scratch-only bin/plan-sweep.sh:12 R3:' <<<"$OUT" \
  && ok || bad "the rm on the assigned \$PLANDIR (line 12) was not caught: $OUT"
grep -q '^CHECK-HIT tests-scratch-only bin/plan-sweep.sh:13 R3:' <<<"$OUT" \
  && ok || bad "the rm on the textual \$HARNESS path (line 13) was not caught: $OUT"

OUT=$("$RUN" "$F/clean.diff" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "the clean diff must be rc 0, got $RC: $OUT"
grep -q '^CHECK-HIT ' <<<"$OUT" && bad "something fired on the clean diff: $OUT" || ok

# ── F. the live checkout's bin/ guards hold ────────────────────────────────
# The one assertion against the real tree. Every bin/ recursive rm on a
# $HARNESS-derived path carries a prefix guard, and a new unguarded one added
# later turns this red — which is the whole point of shipping the guards.
ALL=$(bash "$C/check.sh" --tree "$DIR" 2>/dev/null); RC=$?
# rc 2 here would mean the scan never happened, and "no bin/ hits" from a scan
# that did not run is exactly the vacuous green this catalog refuses.
{ [ "$RC" = 0 ] || [ "$RC" = 1 ]; } && ok || bad "the check could not scan the live checkout (rc=$RC)"
OUT=$(printf '%s\n' "$ALL" | grep '^bin/')
[ -z "$OUT" ] && ok || bad "the live checkout has unguarded bin/ deletions:
$OUT"

# ── G. diff mode of the RUNNER is unchanged ───────────────────────────────
# The --tree branch must not have moved the stdin path a hair.
OUT=$("$RUN" "$DIR/checks/secret-literals/fixtures/violation.diff" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "runner diff mode regressed: rc was $RC, expected 1"
# x4 since BH-1124 added the 40-char ghs_ literal to that fixture.
grep -q 'secret-literals(x4)' <<<"$OUT" \
  && ok || bad "runner diff mode regressed: secret-literals no longer counts 4: $OUT"
OUT=$("$RUN" "$T/no-such.diff" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "runner diff mode regressed: a missing diff must still be rc 2, got $RC"

echo "tests-scratch-only-check-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
