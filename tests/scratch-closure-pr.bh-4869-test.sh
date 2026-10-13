#!/bin/bash
# tests/scratch-closure-pr.bh-4869-test.sh — BH-4869. The scratch-closure lint
# (tests/scratch-closure-lint.bh-4552-test.sh) ran only in the merge-queue
# corpus, so a new suite that hand-copied bin/lib files passed PR CI and every
# builder gate and then sank a whole Mergify batch (#4680, #4735, #4029, #4773).
# It is now a `scratch-closure` rules-pack component, and the builder's gate
# promotes it into the fast tier on any suite diff.
#
#   P1  the PR lint command (bin/rules-pack.sh, as the `fast always-lints
#       (BH-3860)` step runs it) is red on a diff adding a hand-copying suite
#   P2  the same suite using scratch_install_closure is green
#   P3  the isolated runner (a builder's) gives the same red, not "no base"
#       (root beside a harness dir only, else skipped)
#   P4  the scratch-closure-allow marker keeps it green
#   G1  bin/test-impact-gate.sh at --cap 1 runs the lint, tagged fast-lint
#   G2  --skip-suites naming it wins: `run by the rules pack (outside the cap)`
#   G3  not promoted for bin/, tests/lib/, tests/<subdir>/ or a suite deletion
#   G4  promoted for an edited suite and an added tests/mc/ suite
#   G5  a checkout without the lint file: no promotion and no note
#   W1  the workflow step runs the whole pack and does not skip scratch-closure
#   D1  prompts/build-discipline.md carries the D46 rule
# A clone of this checkout (its uncommitted edits overlaid), the real pack and
# the real gate, no mocks.
# Run from anywhere: tests/scratch-closure-pr.bh-4869-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
command -v git >/dev/null || { echo "scratch-closure-pr: git is required"; exit 2; }
command -v jq >/dev/null || { echo "scratch-closure-pr: jq is required"; exit 2; }
unset RATCHET_BASE TI_BASE TI_PR_TITLE TI_PR_LABELS TI_PR_HEAD_REF
export HARNESS="$T/h" TEST_IMPACT_DURATIONS_FILE="$T/dur"
mkdir -p "$HARNESS"; : > "$T/dur"; : > "$T/fast-empty"

LINT=tests/scratch-closure-lint.bh-4552-test.sh
# Fixture text naming the lib dir is built from pieces so this suite's own
# lines never count against the lint it tests.
L='bin/''lib'

# --- the fixture repo: this checkout as it stands, committed as `base` --------
R="$T/r"
git clone -q --shared "$DIR" "$R" || { echo "FAIL: clone"; exit 1; }
{ git -C "$DIR" diff --name-only HEAD; git -C "$DIR" ls-files -o --exclude-standard -- bin catalog prompts tests .github; } | sort -u \
  | while IFS= read -r f; do
      if [ -f "$DIR/$f" ]; then mkdir -p "$R/$(dirname "$f")" && cp -p "$DIR/$f" "$R/$f"
      else rm -f "$R/$f"; fi
    done
g() { git -C "$R" "$@"; }
g -c user.name=t -c user.email=t@t add -A >/dev/null 2>&1
g -c user.name=t -c user.email=t@t commit -q --allow-empty -m base || { echo "FAIL: base commit"; exit 1; }
g branch -f base HEAD
g update-ref refs/remotes/origin/main HEAD
# branch <name> <step...>: a fresh branch off base, the steps, one commit.
branch() {
  local n=$1; shift
  g checkout -q -B "$n" base || return 1
  "$@"
  g add -A >/dev/null 2>&1
  g -c user.name=t -c user.email=t@t commit -q -m "$n" || return 1
}
hand()   { printf '%s\n' '#!/bin/bash' "for f in a.sh b.sh; do cp \"\$DIR/$L/\$f\" \"\$T/$L/\"; done" > "$R/tests/new.bh-2-test.sh"; }
helper() { printf '%s\n' '#!/bin/bash' "scratch_install_closure bin/env-diff.sh \"\$T\" >/dev/null || exit 1" > "$R/tests/new.bh-2-test.sh"; }
allow()  { hand; printf '%s\n' '# scratch-closure-allow: unit-tests a.sh directly' >> "$R/tests/new.bh-2-test.sh"; }

# pack <out> [--runner r]: the PR lint step's command, narrowed to the one id.
pack() {
  local o=$1; shift
  ( cd "$R" && HARNESS_TEST_SANDBOX=1 bin/rules-pack.sh --base origin/main --only scratch-closure --out "$T/$o" "$@" ) \
    > "$T/$o.out" 2> "$T/$o.err"
}

# --- P1: red ------------------------------------------------------------------
branch hand hand || bad "P1 branch"
pack o1 --runner local; rc=$?
[ "$rc" = 1 ] && ok || bad "P1 rc $rc (want 1): $(cat "$T/o1.out" "$T/o1.err")"
fl=$(grep '^scratch-closure: ' "$T/o1.out")
case "$fl" in *"tests/new.bh-2-test.sh:2:"*scratch_install_closure*) ok ;;
  *) bad "P1 no scratch-closure finding naming tests/new.bh-2-test.sh:2: [$(cat "$T/o1.out")]" ;; esac
grep -qxF "$LINT" "$T/o1/suites.txt" 2>/dev/null && ok || bad "P1 suites.txt does not list $LINT"
[ "$(jq -r .state "$T/o1/summary.json" 2>/dev/null)" = red ] && ok || bad "P1 state $(jq -r .state "$T/o1/summary.json" 2>/dev/null) (want red)"

# --- P2: green with the helper ---------------------------------------------------
branch helper helper || bad "P2 branch"
pack o2 --runner local; rc=$?
[ "$rc" = 0 ] && ok || bad "P2 rc $rc (want 0): $(cat "$T/o2.out" "$T/o2.err")"
[ -s "$T/o2.out" ] && bad "P2 stdout not empty: $(cat "$T/o2.out")" || ok
[ "$(jq -r .state "$T/o2/summary.json" 2>/dev/null)" = clean ] && ok || bad "P2 state $(jq -r .state "$T/o2/summary.json" 2>/dev/null) (want clean)"

# --- P3: the isolated runner, a builder's -----------------------------------------
if [ "$(id -u)" -eq 0 ] && [ -d "${HARNESS_ROOT_OVERRIDE:-/root/harness}" ]; then
  g checkout -q hand
  pack o3 --runner isolated; rc=$?
  [ "$rc" = 1 ] && ok || bad "P3 isolated rc $rc (want 1): $(cat "$T/o3.out" "$T/o3.err")"
  grep '^scratch-closure: ' "$T/o3.out" | grep -q 'tests/new.bh-2-test.sh:2:' && ok \
    || bad "P3 isolated finding missing: [$(cat "$T/o3.out")]"
  grep -q 'no base to diff against' "$T/o3.out" "$T/o3.err" && bad "P3 isolated run had no base" || ok
else
  echo "SKIP: P3 (needs root beside a harness dir)"; ok
fi

# --- P4: the allow marker ---------------------------------------------------------
branch allow allow || bad "P4 branch"
pack o4 --runner local; rc=$?
[ "$rc" = 0 ] && ok || bad "P4 rc $rc (want 0): $(cat "$T/o4.out" "$T/o4.err")"

# gate <name> [args...]: the builder's gate at --cap 1, plan only.
gate() {
  local n=$1; shift
  ( cd "$R" && TEST_IMPACT_GATE_FAST="$T/fast-empty" bin/test-impact-gate.sh --base origin/main \
      --runner plan --cap 1 --list "$T/$n.list" "$@" ) > "$T/$n.out" 2> "$T/$n.err"
}
promoted() { grep -qxF "$LINT" "$T/$1.list" 2>/dev/null; }
fastline() { grep -E "^plan: $LINT +fast-lint" "$T/$1.out"; }

# --- G1: promoted past the cap ------------------------------------------------------
g checkout -q hand
gate g1; rc=$?
[ "$rc" = 0 ] && ok || bad "G1 gate rc $rc: $(tail -3 "$T/g1.err")"
promoted g1 && ok || bad "G1 $LINT not in the run list: $(cat "$T/g1.list" 2>/dev/null)"
fastline g1 >/dev/null && ok || bad "G1 no fast-lint plan line: $(grep "$LINT" "$T/g1.out")"

# --- G2: --skip-suites wins ---------------------------------------------------------
printf '%s\n' "$LINT" > "$T/skip"
gate g2 --skip-suites "$T/skip"
promoted g2 && bad "G2 $LINT still in the run list" || ok
grep -qxF "plan: $LINT  run by the rules pack (outside the cap)" "$T/g2.out" && ok \
  || bad "G2 no rules-pack plan line: $(grep "$LINT" "$T/g2.out")"

# --- G3: negatives ------------------------------------------------------------------
neg_bin()  { echo '# x' >> "$R/bin/env-diff.sh"; }
neg_lib()  { printf '%s\n' '#!/bin/bash' 'zz() { :; }' > "$R/tests/lib/zz-helper.sh"; }
neg_fx()   { mkdir -p "$R/tests/fixtures/zz"; printf '%s\n' '#!/bin/bash' > "$R/tests/fixtures/zz/x.sh"; }
neg_del()  { git -C "$R" rm -q tests/env-diff.bh-19-test.sh; }
for c in neg_bin neg_lib neg_fx neg_del; do
  branch "$c" "$c" || { bad "G3 $c branch"; continue; }
  gate "$c"
  promoted "$c" && bad "G3 $c promoted the lint" || ok
  fastline "$c" >/dev/null && bad "G3 $c tagged the lint fast-lint" || ok
done

# --- G4: positives ------------------------------------------------------------------
pos_edit() { echo 'echo x' >> "$R/tests/env-diff.bh-19-test.sh"; }
pos_mc()   { mkdir -p "$R/tests/mc"; printf '%s\n' '#!/bin/bash' 'exit 0' > "$R/tests/mc/zz-new-test.sh"; }
for c in pos_edit pos_mc; do
  branch "$c" "$c" || { bad "G4 $c branch"; continue; }
  gate "$c"
  promoted "$c" && ok || bad "G4 $c did not promote the lint: $(cat "$T/$c.list" 2>/dev/null)"
done

# --- G5: a checkout without the lint ---------------------------------------------------
no_lint() { git -C "$R" rm -q "$LINT"; helper; }
branch nolint no_lint || bad "G5 branch"
gate g5; rc=$?
[ "$rc" = 0 ] && ok || bad "G5 gate rc $rc: $(tail -3 "$T/g5.err")"
promoted g5 && bad "G5 promoted a lint the checkout lacks" || ok
grep -qi 'scratch-closure' "$T/g5.err" && bad "G5 stderr note: $(grep -i scratch-closure "$T/g5.err")" || ok

# --- W1: the PR lint step runs the whole pack ---------------------------------------
step=$(awk '/- name: fast always-lints \(BH-3860\)/ { on = 1; next } on && /- name:/ { exit } on' "$DIR/.github/workflows/harness-ci.yml")
case "$step" in *bin/rules-pack.sh*) ok ;; *) bad "W1 the fast always-lints step does not call bin/rules-pack.sh" ;; esac
case "$step" in *--only*) bad "W1 the step narrows the pack with --only" ;; *) ok ;; esac
skips=$(printf '%s\n' "$step" | grep -o -- '--skip [^ ]*' | cut -d' ' -f2)
case ",$skips," in *,scratch-closure,*) bad "W1 the step skips scratch-closure" ;; *) ok ;; esac

# --- D1: the builder prompt rule ------------------------------------------------------
d46=$(grep -E '^- \*\*D46 ' "$DIR/prompts/build-discipline.md")
case "$d46" in *scratch_install_closure*scratch-closure-allow*|*scratch-closure-allow*scratch_install_closure*) ok ;;
  *) bad "D1 prompts/build-discipline.md has no D46 rule naming scratch_install_closure and scratch-closure-allow" ;; esac

echo "scratch-closure-pr: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
