#!/bin/bash
# tests/evidence-verdicts.bh-1346-test.sh — the `[$]` half of the round-4 fix in
# bin/lib/evidence.sh (BH-1346), pinned against every awk on this box.
#
# WHY THIS SUITE EXISTS. `RUN_RE` writes the `$` run-line prefix as the bracket
# expression `[$]`, not as `\$`, because the same string is handed to awk with
# `-v re=` for the validate.txt window cut, and a `-v` value goes through awk's
# string-escape pass before it becomes a regex: gawk and BSD awk turn `\$` into
# a bare `$` anchor, so `^[[:space:]]*(\$[[:space:]]|…)` can never match a
# `$ bash …` line and the window runs straight on into the NEXT task's block.
# tests/evidence-verdicts-test.sh has no fixture where the next block opens with
# `$ bash …` — every §1j/§1n stop is a `CMD`/`NOT RUN:` line — so restoring `\$`
# survives that suite 97/97. This one goes red on it.
#
# WHY THE PER-FLAVOUR LOOP. mawk keeps `\$` literal, and mawk is the default awk
# on most of this fleet, so a suite that only ever runs the default `awk` cannot
# see the bug at all. Each flavour on PATH is driven through a shim directory
# plus `hash -r` in a subshell, and the suite prints the flavours it actually
# drove — a flavour that is absent is not driven and is never counted as a pass.
# macOS awk (which degrades `\$` the same way gawk does) cannot be run from a
# Linux box; it is not claimed here.
#
# Every assertion reads evidence.json, never source text. The one source pin is
# the mutant control, and it asserts the mutation landed on exactly one line so
# a future rewrite of RUN_RE cannot make the control vacuous.
#
# Run: bash tests/evidence-verdicts.bh-1346-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/evidence.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: [$2] does not contain [$3]" ;; esac; }

# shellcheck source=../bin/lib/evidence.sh
. "$LIB" || { echo "evidence-verdicts.bh-1346: cannot source bin/lib/evidence.sh"; exit 1; }

# A scratch repo whose diff touches nothing: the staging check must answer "no"
# for both tests named below, so what is under test is the window cut only.
REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main >/dev/null 2>&1
printf 'fixture\n' > "$REPO/README.md"
git -C "$REPO" add README.md >/dev/null 2>&1
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q -m base >/dev/null 2>&1

j() { jq -r "$2" "$1/evidence.json" 2>/dev/null; }

# The fixture: block 1 names tests/a-test.sh, carries a pass SUMMARY but NO exit
# token of its own; block 2 opens with a `$ bash …` run line and records EXIT: 0.
# Block 1 must therefore be INCONCLUSIVE (its window stops at block 2's run
# line), and block 2 CONFIRMED (the control proving `$ ` still opens a window).
mkfix() { # mkfix <build-dir>
  mkdir -p "$1"
  { printf '## Acceptance tests\n'
    printf -- '- a runs, proven by `tests/a-test.sh`\n'
    printf -- '- b runs, proven by `tests/b-test.sh`\n'; } > "$1/plan.md"
  cat > "$1/validate.txt" <<'VAL'
TASK: T1 — a
CMD : bash tests/a-test.sh
a-suite: 3 passed, 0 failed

TASK: T2 — b
$ bash tests/b-test.sh
EXIT: 0
VAL
}

# The production entry point, run in a subshell so a PATH shim (and, for the
# mutant control, a different lib) cannot leak into the rest of the suite.
run_fixture() { # run_fixture <build-dir> [<awk-shim-dir>] [<lib>]
  local d="$1" shim="${2:-}" lib="${3:-$LIB}"
  mkfix "$d"
  (
    if [ -n "$shim" ]; then PATH="$shim:$PATH"; export PATH; hash -r; fi
    # shellcheck source=/dev/null
    . "$lib" || exit 1
    evidence_score "$d" "$d/plan.md" main "$REPO" > "$d/score.out" 2>&1
  )
}

assert_fixture() { # assert_fixture <label> <build-dir>
  local label="$1" d="$2" bl
  # The expected artifact line is read back from the fixture, so a fixture edit
  # can never silently make this assertion agree with nothing.
  bl=$(grep -n '^\$ bash tests/b-test\.sh$' "$d/validate.txt" | head -1 | cut -d: -f1)
  eq "$label claim 1 (no exit token, next run line is \$ bash) is INCONCLUSIVE" \
    "$(j "$d" '.claims[0].verdict')" "INCONCLUSIVE"
  has "$label claim 1 note says the named test never appears" \
    "$(j "$d" '.claims[0].note')" "never appears"
  eq "$label claim 1 borrowed no artifact" "$(j "$d" '.claims[0].artifact')" ""
  eq "$label claim 2 (the \$ bash control) is CONFIRMED" \
    "$(j "$d" '.claims[1].verdict')" "CONFIRMED"
  eq "$label claim 2 artifact is the \$ bash run line" \
    "$(j "$d" '.claims[1].artifact')" "validate.txt:$bl (agent-recorded)"
}

# ── §1 the fixture under the box's default awk ───────────────────────────────
run_fixture "$T/x1"
assert_fixture "§1 default awk" "$T/x1"

# ── §2 the same fixture under every awk flavour on PATH ──────────────────────
# gawk and BSD awk degrade `\$`; mawk does not. Driving all of them is what
# makes the pin real on a mawk-default box.
GAWK_SHIM=""
DRIVEN=""
for name in gawk mawk busybox nawk original-awk; do
  BIN=$(command -v "$name" 2>/dev/null) || continue
  [ -n "$BIN" ] || continue
  SHIM="$T/awk-$name"; mkdir -p "$SHIM"
  if [ "$name" = busybox ]; then
    printf '#!/bin/sh\nexec %s awk "$@"\n' "$BIN" > "$SHIM/awk"
    chmod 755 "$SHIM/awk"
  else
    ln -sf "$BIN" "$SHIM/awk"
  fi
  run_fixture "$T/x-$name" "$SHIM"
  assert_fixture "§2 $name" "$T/x-$name"
  DRIVEN="$DRIVEN $name"
  [ "$name" = gawk ] && GAWK_SHIM="$SHIM"
done
echo "driven:$DRIVEN"
[ -n "$DRIVEN" ] || bad "§2 no awk flavour was found on PATH — the pin drove nothing"

# ── §3 the mutant control: restore `\$` and the fixture must go red ──────────
# D1, mechanical. The mutation is the exact regression `[$]` exists to prevent.
sed 's/(\[\$\]\[\[:space:\]\]|/(\\$[[:space:]]|/' "$LIB" > "$T/mutant.sh"
eq "§3 the mutation removes exactly one line" \
  "$(diff "$LIB" "$T/mutant.sh" | grep -c '^<')" "1"
eq "§3 the mutation adds exactly one line" \
  "$(diff "$LIB" "$T/mutant.sh" | grep -c '^>')" "1"
eq "§3 the shipped lib carries the bracket form" \
  "$(grep -cF '([$][[:space:]]|' "$LIB")" "1"
eq "§3 the mutant carries the backslash form instead" \
  "$(grep -cF '(\$[[:space:]]|' "$T/mutant.sh")" "1"

if [ -n "$GAWK_SHIM" ]; then
  run_fixture "$T/mut" "$GAWK_SHIM" "$T/mutant.sh"
  eq "§3 under gawk the mutant's window runs on and claim 1 borrows a false CONFIRMED" \
    "$(j "$T/mut" '.claims[0].verdict')" "CONFIRMED"
  eq "§3 the borrowed artifact is block 2's EXIT line" \
    "$(j "$T/mut" '.claims[0].artifact')" "validate.txt:2 (agent-recorded)"
else
  echo "mutant control: skipped (no gawk on PATH)"
fi

# The real lib is still the one loaded in this shell: the mutant was only ever
# sourced inside a subshell.
eq "§3 the shipped lib on disk is untouched by this suite" \
  "$(grep -cF '([$][[:space:]]|' "$LIB")" "1"

echo "evidence-verdicts.bh-1346: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
