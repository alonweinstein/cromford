#!/bin/bash
# tests/test-determinism-lint-changed.bh-6049-test.sh — BH-6049: the lint's
# --changed <ref> mode, which the rules pack's determinism component uses.
#
#   THE PROPERTY UNDER TEST: a full-tree scan takes 70-113 s against the rules
#   pack's 120 s component timeout, so a loaded runner reported
#   could_not_run=determinism. --changed scans only the files that differ from
#   <ref> (committed, uncommitted, untracked), and falls back to the FULL tree
#   whenever it cannot trust that list: an unknown ref, an empty diff (the
#   pack's base re-run) or an edit to the lint or its conf. It never scans
#   nothing by mistake.
#
# Each case runs a copy of the real lint and the shipped conf inside a scratch
# git repo, because --changed reads the diff of the lint's own repo root.
#
# determinism: ok-file the fixtures below plant $RANDOM reads as DATA; this suite
# itself reads no clock and rolls no dice.
# Run from anywhere: tests/test-determinism-lint-changed.bh-6049-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

R="$T/r"
g() { git -C "$R" -c user.name=t -c user.email=t@localhost -c commit.gpgsign=false "$@"; }
mkdir -p "$R/bin" "$R/catalog" "$R/tests"
cp "$DIR/bin/test-determinism-lint.sh" "$R/bin/"
cp "$DIR/catalog/determinism-lint.conf" "$R/catalog/"
# old.sh carries a finding at the base: an unchanged file the changed scan must not read.
printf '#!/bin/bash\nx=$RANDOM\n' > "$R/tests/old-test.sh"
printf '#!/bin/bash\necho clean\n' > "$R/tests/new-test.sh"
g init -q && g add -A && g commit -qm base
BASE=$(g rev-parse HEAD)

# run [args...] -> output in $OUT, rc in $RC; HARNESS points at a scratch tree
# so a box-local flags/determinism-lint.conf cannot leak in.
run() { OUT=$(cd "$R" && HARNESS="$T/h" bash bin/test-determinism-lint.sh "$@" 2>&1); RC=$?; }
has() { grep -qE "$1" <<<"$OUT"; }

# ── C0. control: the full scan sees the base finding ─────────────────────────
run
{ [ "$RC" = 1 ] && has 'tests/old-test\.sh:2: rand-bash'; } && ok \
  || bad "C0: the full scan must report old-test.sh (rc=$RC): $OUT"

# ── C1. a clean change scans only the changed file ───────────────────────────
printf '#!/bin/bash\necho still clean\n' > "$R/tests/new-test.sh"
g commit -qam "clean change"
run --changed "$BASE"
{ [ "$RC" = 0 ] && has '1 files scanned' && ! has 'old-test'; } && ok \
  || bad "C1: --changed must scan only new-test.sh and pass (rc=$RC): $OUT"

# ── C2. a finding in a changed file is still found ───────────────────────────
printf '#!/bin/bash\ny=$RANDOM\n' > "$R/tests/new-test.sh"
run --changed "$BASE"
{ [ "$RC" = 1 ] && has 'tests/new-test\.sh:2: rand-bash' && ! has 'old-test'; } && ok \
  || bad "C2: an uncommitted finding in a changed file must fail the run (rc=$RC): $OUT"
g checkout -q -- tests/new-test.sh

# ── C3. an untracked new test file is scanned ────────────────────────────────
printf '#!/bin/bash\nz=$RANDOM\n' > "$R/tests/untracked-test.sh"
run --changed "$BASE"
{ [ "$RC" = 1 ] && has 'tests/untracked-test\.sh:2: rand-bash'; } && ok \
  || bad "C3: an untracked test file must be scanned (rc=$RC): $OUT"
mv "$R/tests/untracked-test.sh" "$T/untracked-test.sh.off"

# ── C4. an unknown ref is a full scan, never an empty one ────────────────────
run --changed 0000000000000000000000000000000000000000
{ [ "$RC" = 1 ] && has 'tests/old-test\.sh:2: rand-bash'; } && ok \
  || bad "C4: an unknown ref must fall back to the full scan (rc=$RC): $OUT"

# ── C5. an empty diff (the pack's base re-run) is a full scan ────────────────
run --changed HEAD
{ [ "$RC" = 1 ] && has 'tests/old-test\.sh:2: rand-bash'; } && ok \
  || bad "C5: an empty diff must fall back to the full scan (rc=$RC): $OUT"

# ── C6. an edit to the conf is a full scan ───────────────────────────────────
printf '\n' >> "$R/catalog/determinism-lint.conf"
run --changed "$BASE"
{ [ "$RC" = 1 ] && has 'tests/old-test\.sh:2: rand-bash'; } && ok \
  || bad "C6: a conf edit must rescan the full tree (rc=$RC): $OUT"
g checkout -q -- catalog/determinism-lint.conf

# ── C7. a non-test change only: nothing to scan, rc 0 ────────────────────────
g reset -q --hard "$BASE"
printf 'notes\n' > "$R/README"
g add README && g commit -qm readme
run --changed "$BASE"
{ [ "$RC" = 0 ] && ! has 'old-test'; } && ok \
  || bad "C7: a change with no test file must pass without the full scan (rc=$RC): $OUT"

# ── C8. the rules pack's determinism row passes the fork ─────────────────────
ROW=$(printf 'determinism\ttree\tcmd\tbin/test-determinism-lint.sh --changed <fork>\t')
grep -qF -- "$ROW" "$DIR/catalog/rules-pack.tsv" && ok \
  || bad "C8: catalog/rules-pack.tsv must run the determinism lint with --changed <fork>"

echo "test-determinism-lint-changed.bh-6049: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
