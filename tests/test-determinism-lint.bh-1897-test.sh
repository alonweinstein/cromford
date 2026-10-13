#!/bin/bash
# tests/test-determinism-lint.bh-1897-test.sh — BH-1897 (BH-1816.0): the
# date-empty-stamp rule finds `date -d "$x"` in bin/**.sh with no -n/-z guard
# on that variable in the lines above it.
#
#   THE PROPERTY UNDER TEST: GNU `date -u -d ""` exits 0 and prints today's
#   00:00:00Z, so `e=$(date -u -d "$x" +%s) || fallback` never falls back when
#   $x is empty. The rule reports that shape at error (since BH-1901), judges
#   EVERY `date -d "$VAR"` on a line (not just the first), accepts a
#   `[ -n "$x" ]` / `[ -z "$x" ] ||` guard on a non-comment line within
#   date_guard_lookback lines, reads bin/ only (never tests/), and a NOW= pin
#   does not exempt it.
#
# Every case drives bin/test-determinism-lint.sh against the SHIPPED
# catalog/determinism-lint.conf. F1b still runs on a copy of the shipped conf
# with this rule forced to error; since BH-1901 that sed is a no-op, so the copy
# is the shipped conf.
#
# determinism: ok-file the fixtures below are deliberate unguarded date stamps as
# DATA; this suite itself reads no clock and rolls no dice.
# Run from anywhere: tests/test-determinism-lint.bh-1897-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/test-determinism-lint.sh"
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# run <dir-or-file> [flags...] -> stdout+stderr in $OUT, rc in $RC. HARNESS
# points at a scratch tree so a box-local flags/determinism-lint.conf cannot
# leak in and change the answer.
run() { OUT=$(HARNESS="$T/h" bash "$LINT" "$@" 2>&1); RC=$?; }
has() { grep -qE "$1" <<<"$OUT"; }
case_dir() { rm -rf "$T/c"; mkdir -p "$T/c/tests" "$T/c/bin"; }
# fix <name> : writes stdin to $T/c/bin/<name>.sh in a fresh case dir
fix() { case_dir; cat > "$T/c/bin/$1.sh"; }

# ── F1. the plain shape reports, at error (BH-1901) ─────────────────────────
fix f1 <<'EOF'
#!/bin/bash
x="$1"
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'bin/f1\.sh:3: date-empty-stamp' && has 'determinism findings'; } && ok \
  || bad "F1: an unguarded date -d \"\$x\" in bin/ did not fail the run (rc=$RC): $OUT"

# ── F1b. the message says why, through the real CLI ──────────────────────────
sed -E 's/^(rule[[:space:]]+date-empty-stamp[[:space:]]+)warn/\1error/' "$DIR/catalog/determinism-lint.conf" > "$T/err.conf"
OUT=$(HARNESS="$T/h" DETERMINISM_LINT_CONF="$T/err.conf" bash "$LINT" "$T/c" 2>&1); RC=$?
{ [ "$RC" = 1 ] && has 'bin/f1\.sh:3: date-empty-stamp: GNU date -d "" exits 0' \
    && has '# determinism: ok date-empty-stamp'; } && ok \
  || bad "F1b: the date-empty-stamp message is missing or wrong (rc=$RC): $OUT"

# ── F2. the ${1:-} form reports ──────────────────────────────────────────────
fix f2 <<'EOF'
#!/bin/bash
e=$(date -u -d "${1:-}" +%s) || e=0
EOF
run "$T/c"
has 'bin/f2\.sh:2: date-empty-stamp' && ok || bad "F2: \${1:-} was not judged: $OUT"

# ── F3. every date on the line is judged (metrics-collect.sh:53) ─────────────
fix f3 <<'EOF'
#!/bin/bash
[ -n "$START" ] || return 1
END=$(tail -1 log)
DUR=$(( ($(date -d "$END" +%s 2>/dev/null || echo 0) - $(date -d "$START" +%s 2>/dev/null || echo 0)) / 60 ))
EOF
run "$T/c"
has 'bin/f3\.sh:4: date-empty-stamp' && ok || bad "F3: \$END is unguarded but the line was silent: $OUT"
# ... and the mirror: guarding only the FIRST one is not enough either
fix f3b <<'EOF'
#!/bin/bash
[ -n "$END" ] || return 1
DUR=$(( ($(date -d "$END" +%s 2>/dev/null || echo 0) - $(date -d "$START" +%s 2>/dev/null || echo 0)) / 60 ))
EOF
run "$T/c"
has 'bin/f3b\.sh:3: date-empty-stamp' && ok || bad "F3b: \$START is unguarded but the line was silent: $OUT"
# both guarded: silent
fix f3c <<'EOF'
#!/bin/bash
if [ -n "$START" ] && [ -n "$END" ]; then
  DUR=$(( ($(date -d "$END" +%s 2>/dev/null || echo 0) - $(date -d "$START" +%s 2>/dev/null || echo 0)) / 60 ))
fi
EOF
run "$T/c"
! has 'date-empty-stamp' && ok || bad "F3c: both vars guarded, still reported: $OUT"

# ── N1. same-line guard ──────────────────────────────────────────────────────
fix n1 <<'EOF'
#!/bin/bash
[ -n "$x" ] && e=$(date -u -d "$x" +%s)
EOF
run "$T/c"
! has 'date-empty-stamp' && ok || bad "N1: same-line -n guard still reported: $OUT"

# ── N2. guard 3 lines above (-n, and -z ||) ──────────────────────────────────
fix n2 <<'EOF'
#!/bin/bash
[ -n "$x" ] || return 1
a=1
b=2
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"
! has 'date-empty-stamp' && ok || bad "N2: -n guard 3 above still reported: $OUT"
fix n2z <<'EOF'
#!/bin/bash
[ -z "${x:-}" ] || {
a=1
b=2
e=$(date -u -d "$x" +%s) || e=0
}
EOF
run "$T/c"
! has 'date-empty-stamp' && ok || bad "N2z: -z guard 3 above still reported: $OUT"

# ── N3. the same guard 7 lines above is out of reach (lookback 6) ────────────
fix n3 <<'EOF'
#!/bin/bash
[ -n "$x" ] || return 1
a=1
a=2
a=3
a=4
a=5
a=6
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"
has 'bin/n3\.sh:9: date-empty-stamp' && ok || bad "N3: a guard 7 lines above must not count: $OUT"

# ── N4 / N5. epoch and relative forms are not this shape ─────────────────────
fix n4 <<'EOF'
#!/bin/bash
d=$(date -u -d "@$x" +%F)
d=$(date -u -d "$N days ago" +%F)
EOF
run "$T/c"
! has 'date-empty-stamp' && ok || bad "N4/N5: @\$x or \"\$N days ago\" reported: $OUT"

# ── N6. a line waiver with a reason silences; without one is a finding ──────
fix n6 <<'EOF'
#!/bin/bash
e=$(date -u -d "$x" +%s) || e=0  # determinism: ok date-empty-stamp caller already rejected empty
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'date-empty-stamp'; } && ok || bad "N6: a reasoned waiver did not silence (rc=$RC): $OUT"
fix n6b <<'EOF'
#!/bin/bash
e=$(date -u -d "$x" +%s) || e=0  # determinism: ok date-empty-stamp
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'bin/n6b\.sh:2: waiver-no-reason'; } && ok \
  || bad "N6b: a waiver with no reason must be a waiver-no-reason finding (rc=$RC): $OUT"

# ── N7. bin/ only: the same line in a test file is silent ────────────────────
case_dir
cat > "$T/c/tests/foo-test.sh" <<'EOF'
#!/bin/bash
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"
! has 'date-empty-stamp' && ok || bad "N7: date-empty-stamp read a tests/ file: $OUT"

# ── N8. a guard on ANOTHER variable is not a guard ───────────────────────────
fix n8 <<'EOF'
#!/bin/bash
[ -n "$y" ] || return 1
[ -n "$xy" ] || return 1
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"
has 'bin/n8\.sh:4: date-empty-stamp' && ok || bad "N8: a guard on \$y/\$xy guarded \$x: $OUT"

# ── N9. a guard inside a comment is not a guard ──────────────────────────────
fix n9 <<'EOF'
#!/bin/bash
# [ -n "$x" ] || return 1
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"
has 'bin/n9\.sh:3: date-empty-stamp' && ok || bad "N9: a commented-out guard counted: $OUT"

# ── N10. a file test is not a date argument ──────────────────────────────────
fix n10 <<'EOF'
#!/bin/bash
[ -d "$dir" ] || exit 1
[ -n "$x" ] && e=$(date -u -d "$x" +%s)
[ -d "$dir" ] && [ -n "$x" ] && e=$(date -u -d "$x" +%s)
EOF
run "$T/c"
! has 'date-empty-stamp' && ok || bad "N10: [ -d \"\$dir\" ] was judged as a date argument: $OUT"

# ── P1. a NOW= pin does not exempt it (the name is not clock-*) ──────────────
fix p1 <<'EOF'
#!/bin/bash
NOW=$(date +%s)
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"
has 'bin/p1\.sh:3: date-empty-stamp' && ok || bad "P1: a NOW= pin exempted date-empty-stamp: $OUT"

# ── R1. --rules shows it at error, with its scope and knob ───────────────────
run --rules
{ [ "$RC" = 0 ] && has '^rule[[:space:]]+date-empty-stamp[[:space:]]+error[[:space:]]+sh' \
    && has '^scope date-empty-stamp ' && has '^opt date_guard_lookback 6$'; } && ok \
  || bad "R1: --rules is missing the rule, scope or knob: $OUT"

echo "test-determinism-lint.bh-1897: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
