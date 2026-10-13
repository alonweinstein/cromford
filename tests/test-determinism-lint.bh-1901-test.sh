#!/bin/bash
# tests/test-determinism-lint.bh-1901-test.sh — BH-1901 (BH-1816.4): date-empty-stamp
# is an error, and only a real test on the variable counts as its guard.
#
#   THE PROPERTY UNDER TEST: a `-n` guard is a `[`, `[[` or `test` followed by
#   `-n VAR`, so `head -n "$x"`, `grep -n "$x"` and `[ ! -n "$x" ]` no longer
#   silence the rule. A `-z` test on VAR counts only when it short-circuits AWAY
#   from the date call on its own line: `||`, or `&&` / `; then` plus
#   return/exit/continue/break. The real repo carries no finding (case R), and a
#   bin/ finding now fails the run (E1).
#
# Every case drives bin/test-determinism-lint.sh against the SHIPPED
# catalog/determinism-lint.conf.
#
# determinism: ok-file the fixtures below are deliberate unguarded date stamps as
# DATA; this suite itself reads no clock and rolls no dice.
# Run from anywhere: tests/test-determinism-lint.bh-1901-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/test-determinism-lint.sh"
CONF="$DIR/catalog/determinism-lint.conf"
NOTE="$DIR/docs/notes/2026-09-24-BH-1816-date-empty-stamp.md"
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
# reports <name> <line> <label> / silent <label>: judge the last run
reports() {
  { [ "$RC" = 1 ] && has "bin/$1\\.sh:$2: date-empty-stamp"; } && ok \
    || bad "$3: expected a date-empty-stamp finding at bin/$1.sh:$2 (rc=$RC): $OUT"
}
silent() {
  { [ "$RC" = 0 ] && ! has 'date-empty-stamp'; } && ok \
    || bad "$1: expected no date-empty-stamp finding (rc=$RC): $OUT"
}

# ── R. the real repo is clean ────────────────────────────────────────────────
OUT=$(cd "$DIR" && HARNESS="$T/h" bash "$LINT" 2>&1); RC=$?
{ [ "$RC" = 0 ] && ! has 'date-empty-stamp:'; } && ok \
  || bad "R: the repo lint is not rc 0 with 0 date-empty-stamp findings (rc=$RC): $(grep -E 'date-empty-stamp|findings' <<<"$OUT")"

# ── E1. the plain shape is now an error ──────────────────────────────────────
fix e1 <<'EOF'
#!/bin/bash
x="$1"
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"
{ reports e1 3 E1; } && { has 'determinism findings' && ok || bad "E1: no 'determinism findings' header: $OUT"; }

# ── T-HEAD / T-GREP. a -n that is some command's option is not a guard ──────
fix thead <<'EOF'
#!/bin/bash
n=$(head -n "$x" f)
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"; reports thead 3 T-HEAD
fix tgrep <<'EOF'
#!/bin/bash
grep -n "$x" f
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"; reports tgrep 3 T-GREP

# ── T-NOT. an inverted -n is not a guard ─────────────────────────────────────
fix tnot <<'EOF'
#!/bin/bash
[ ! -n "$x" ] || return 1
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"; reports tnot 3 T-NOT

# ── T-ZAND / T-ZIF. a -z that leads INTO the date call is not a guard ───────
fix tzand <<'EOF'
#!/bin/bash
[ -z "$x" ] && e=$(date -u -d "$x" +%s)
EOF
run "$T/c"; reports tzand 2 T-ZAND
fix tzif <<'EOF'
#!/bin/bash
if [ -z "$x" ]; then
  e=$(date -u -d "$x" +%s)
fi
EOF
run "$T/c"; reports tzif 3 T-ZIF

# ── T-ZOR / T-ZRET. a -z that short-circuits away still guards ──────────────
fix tzor <<'EOF'
#!/bin/bash
[ -z "$x" ] || e=$(date -u -d "$x" +%s)
EOF
run "$T/c"; silent T-ZOR
fix tzret <<'EOF'
#!/bin/bash
[ -z "$x" ] && return 1
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"; silent T-ZRET
fix tzret2 <<'EOF'
#!/bin/bash
if [ -z "$x" ]; then return 1; fi
e=$(date -u -d "$x" +%s) || e=0
EOF
run "$T/c"; silent T-ZRET2
fix tzret3 <<'EOF'
#!/bin/bash
for x in a b; do
  test -z "${x:-}" && continue
  e=$(date -u -d "$x" +%s) || e=0
done
EOF
run "$T/c"; silent T-ZRET3

# ── T-DBL. [[ -n $x ]] unquoted and `test -n` still guard ────────────────────
fix tdbl <<'EOF'
#!/bin/bash
[[ -n $x ]] && e=$(date -u -d "$x" +%s)
test -n "$y" && e=$(date -u -d "$y" +%s)
EOF
run "$T/c"; silent T-DBL

# ── C1. the warn_show comment sits on warn_show ──────────────────────────────
prev=$(awk '/^opt warn_show /{ print p; exit } { p = $0 }' "$CONF")
glb=$(awk '/^# How many lines above a `date -d/{ print p; exit } { p = $0 }' "$CONF")
{ [[ "$prev" == \#*"warn lines"* || "$prev" == \#*"scrolls"* ]] && [[ "$glb" != *"warn lines"* && "$glb" != *"scrolls"* ]] \
    && [ "$(grep -c 'warn lines' "$CONF")" = 1 ]; } && ok \
  || bad "C1: the warn_show comment is not directly above 'opt warn_show' (above it: '$prev'; above the lookback comment: '$glb')"

# ── D1. the dated audit note ─────────────────────────────────────────────────
{ [ -s "$NOTE" ] && grep -q '^Doc: ' "$NOTE" && grep -q 'date_guard_lookback' "$NOTE" \
    && grep -q 'determinism: ok date-empty-stamp' "$NOTE" && grep -q 'bin/lib/jobs/flags.sh' "$NOTE" \
    && grep -q 'bin/account-pick.sh' "$NOTE"; } && ok \
  || bad "D1: $NOTE is missing, or lacks Doc:/date_guard_lookback/the waiver form/the two named sites"

# ── W1. this change adds no date-empty-stamp waiver under bin/ ───────────────
# Judged against THIS diff (tests/lib/ratchet-delta.sh): each bin/ file's
# waiver-line count at the base (the newest main HEAD contains) and at HEAD,
# red only when a file's count went up. The old `git diff origin/main` was a
# two-dot diff against main's TIP, so a waiver main REMOVED after the branch
# forked read as one this branch added; and no origin/main was a SKIP. Now a
# base that does not resolve is red.
waivers() { (cd "$1" && grep -rc 'determinism: ok date-empty-stamp' bin 2>/dev/null) | awk -F: '$NF > 0 { n = $NF; sub(/:[0-9]+$/, ""); print $0 "\t" n }' | sort; }
w1_check() {  # <repo> — one line per file whose waivers went up, rc 1 if any
  local repo="$1" base w p n b rc=0
  base=$(rd_base "$repo") || { echo "W1: $base"; return 1; }
  w=$(mktemp -d "$T/w1.XXXXXX") || return 1
  rd_tree "$repo" "$base" "$w" bin || { echo "W1: cannot read bin/ at $base"; return 1; }
  waivers "$w" > "$w.base"; waivers "$repo" > "$w.head"
  while IFS=$'\t' read -r p n b; do
    echo "W1: $p carries $n date-empty-stamp waiver(s), $b at base ${base:0:12} — guard the date call instead"
    rc=1
  done < <(rd_delta "$w.head" "$w.base")
  return $rc
}
OUT=$(w1_check "$DIR"); [ $? = 0 ] && ok || bad "$OUT"
WV='x=$(date -u -d "$y" +%s) # determinism: ok date-empty-stamp fixture'
w1_repo() { scratch_rm "$1" || return 1; mkdir -p "$1/bin"; printf '#!/bin/bash\n%s\n' "$WV" > "$1/bin/a.sh"; printf '#!/bin/bash\n%s\n' "$WV" > "$1/bin/m.sh"; rd_fixture_repo "$1"; }
w1_main_rm()  { printf '#!/bin/bash\ntrue\n' > "$1/bin/m.sh"; }
w1_pr_docs()  { echo d >> "$1/README"; rd_git "$1" commit -qam docs; }
w1_pr_add()   { printf '%s\n' "$WV" >> "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: waiver'; }
w1_pr_move()  { printf '#!/bin/bash\n# moved\n%s\n' "$WV" > "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: edits around the waiver'; }
w1_case() {  # <name> <want_rc> <steps...>
  local name="$1" want="$2" R="$T/w1-$1" step out rc
  shift 2
  w1_repo "$R" || { bad "W1 case $name: setup"; return; }
  for step in "$@"; do
    case "$step" in
      main-rm) rd_main_commit "$R" 'main drops a waiver' w1_main_rm ;;
      merge)   rd_git "$R" merge -q --no-edit refs/remotes/origin/main ;;
      nomain)  rd_git "$R" update-ref -d refs/remotes/origin/main ;;
      *)       "$step" "$R" ;;
    esac >/dev/null 2>&1 || { bad "W1 case $name: step $step"; return; }
  done
  out=$(RATCHET_BASE= TI_BASE= w1_check "$R"); rc=$?
  [ "$rc" = "$want" ] && ok || bad "W1 case $name: rc=$rc want $want: $out"
}
w1_case main-removes-branch-behind 0 main-rm w1_pr_docs
w1_case main-removes-queue-draft   0 w1_pr_docs main-rm merge
w1_case pr-edits-around-a-waiver   0 w1_pr_move
w1_case pr-adds-waiver             1 w1_pr_add
w1_case pr-adds-after-drift        1 main-rm w1_pr_add merge
w1_case no-base                    1 w1_pr_docs nomain

echo "test-determinism-lint.bh-1901: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
