#!/bin/bash
# tests/mc/expected-map-fragments-test.sh — the conductor's function ownership
# map is a DIRECTORY of fragments, not one shared file (Lane E, hot-file
# fragments, 2026-09-24).
#
# WHY. tests/mc/expected-map.tsv was touched by 21 commits between 2026-09-21
# and 2026-09-24, 11 of them rebases, round fixes or lead fixes. Every PR that
# added a conductor function appended a row next to its neighbours AND appended
# a sentence to the file's one-line header comment, so any two such PRs
# conflicted on that line whatever functions they added — a DIRTY PR, or a red
# Mergify batch, on a hunk no ticket was about. The rows are a SET: nothing reads
# their order. So each change now writes its own fragment,
# tests/mc/expected-map.d/<TICKET-KEY>.tsv, and the three suites that judge the
# split (tests/mc-split-layout-test.sh, tests/mc/lib-complete-test.sh,
# tests/mc/driver-complete-test.sh) read the union through
# tests/lib/mc-expected-map.sh.
#
# WHAT IT PINS
#   F1  the single-file map is retired and stays retired: a PR that recreates
#       tests/mc/expected-map.tsv would be read by nothing, silently.
#   F2  the real fragment directory assembles clean, and the union still carries
#       the lib's anchor row (log/mc_stamp) the layout suite guards on.
#   F3  every file in the directory is a *.tsv fragment — a stray
#       `BH-1.tsv.orig` or `notes.md` would otherwise be skipped without a word.
#   F4  the assembler REFUSES, naming the file, each malformed shape: a row that
#       is not three tab-separated fields, a module outside the six, an origin
#       other than lib|driver, one function claimed by two rows (in two
#       fragments — the conflict the single file used to surface as a merge
#       conflict now surfaces here), and an empty or missing directory.
#   F5  the three consumers read the directory through the assembler and name no
#       retired path.
#
# No clock, no network, no gh, no git. Nothing outside $T is written.
# Run from anywhere: tests/mc/expected-map-fragments-test.sh   (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

MAPD="$DIR/tests/mc/expected-map.d"
HELPER="$DIR/tests/lib/mc-expected-map.sh"

# ── F1. the single file is gone ─────────────────────────────────────────────
[ ! -e "$DIR/tests/mc/expected-map.tsv" ] && ok \
  || bad "F1: tests/mc/expected-map.tsv must not exist — rows go in tests/mc/expected-map.d/<TICKET-KEY>.tsv"

# ── F2. the real directory assembles clean ──────────────────────────────────
if [ -r "$HELPER" ] && . "$HELPER"; then ok
else bad "F2: tests/lib/mc-expected-map.sh must exist and source clean"; fi
if command -v mc_expected_map >/dev/null 2>&1; then
  mc_expected_map "$MAPD" "$T/map.tsv" 2>"$T/map.err"; RC=$?
  [ "$RC" = 0 ] && ok || bad "F2: the fragment directory must assemble (rc=$RC): $(head -3 "$T/map.err" | tr '\n' ' ')"
  grep -qxF "$(printf 'log\tmc_stamp\tlib')" "$T/map.tsv" 2>/dev/null && ok \
    || bad "F2: the assembled map must carry the log/mc_stamp anchor row"
  ROWS=$(awk -F'\t' 'NF==3 && $1 !~ /^#/{n++} END{print n+0}' "$T/map.tsv" 2>/dev/null)
  [ "${ROWS:-0}" -gt 0 ] && ok || bad "F2: the assembled map holds no rows"
else
  bad "F2: mc_expected_map is not defined"
fi

# ── F3. nothing in the directory is silently skipped ────────────────────────
if [ -d "$MAPD" ]; then
  STRAY=$(find "$MAPD" -mindepth 1 ! -name '*.tsv' -print | sed "s#^$DIR/##" | tr '\n' ' ')
  [ -z "$STRAY" ] && ok || bad "F3: not a *.tsv fragment, so never read: $STRAY"
  NFRAG=$(find "$MAPD" -maxdepth 1 -type f -name '*.tsv' | wc -l | tr -d ' ')
  [ "$NFRAG" -gt 0 ] && ok || bad "F3: tests/mc/expected-map.d holds no fragments"
else
  bad "F3: tests/mc/expected-map.d is missing"
fi

# ── F4. the assembler refuses every malformed shape ─────────────────────────
refuses() { # <case> <want-in-stderr> — the fixture dir is $T/f/<case>
  local c="$1" want="$2" rc
  command -v mc_expected_map >/dev/null 2>&1 || { bad "F4/$c: mc_expected_map is not defined"; return; }
  mc_expected_map "$T/f/$c" "$T/f/$c.out" 2>"$T/f/$c.err"; rc=$?
  [ "$rc" != 0 ] && ok || bad "F4/$c: must be refused (rc=0)"
  grep -qF "$want" "$T/f/$c.err" && ok || bad "F4/$c: the refusal must name '$want': $(head -2 "$T/f/$c.err" | tr '\n' ' ')"
}
frag() { mkdir -p "$T/f/$1"; printf '%b' "$3" > "$T/f/$1/$2"; }

frag good 00-base.tsv '# a comment\nlog\tmc_stamp\tlib\n\nrebase\tmc_rebase\tlib\n'
frag good BH-1.tsv 'queue\tmc_new_thing\tlib\n'
if command -v mc_expected_map >/dev/null 2>&1; then
  mc_expected_map "$T/f/good" "$T/f/good.out" 2>"$T/f/good.err" && ok \
    || bad "F4/good: a well-formed pair of fragments must assemble: $(cat "$T/f/good.err")"
  [ "$(awk -F'\t' 'NF==3 && $1 !~ /^#/' "$T/f/good.out" 2>/dev/null | sort | tr '\n' '|')" \
    = "$(printf 'log\tmc_stamp\tlib|queue\tmc_new_thing\tlib|rebase\tmc_rebase\tlib|')" ] && ok \
    || bad "F4/good: the union must be exactly the rows of both fragments: $(tr '\n' '|' < "$T/f/good.out" 2>/dev/null)"
else
  bad "F4/good: mc_expected_map is not defined"
fi

frag twofield 00-base.tsv 'log\tmc_stamp\n'
refuses twofield "00-base.tsv:1"
frag module 00-base.tsv 'log\tmc_stamp\tlib\nsettlement\tmc_x\tlib\n'
refuses module "00-base.tsv:2"
frag origin 00-base.tsv 'log\tmc_stamp\tlib\nqueue\tmc_y\tmoved\n'
refuses origin "00-base.tsv:2"
frag dup 00-base.tsv 'log\tmc_stamp\tlib\n'
frag dup BH-9.tsv 'queue\tmc_stamp\tlib\n'
refuses dup "mc_stamp"
# Review of #2217: a fragment with no final newline must not glue its last row
# to the next fragment's first line — the union is the validated rows, each on
# its own line.
frag nonl 00-base.tsv 'log\tmc_stamp\tlib'
frag nonl BH-2.tsv 'queue\tmc_other\tlib\n'
if command -v mc_expected_map >/dev/null 2>&1; then
  mc_expected_map "$T/f/nonl" "$T/f/nonl.out" 2>"$T/f/nonl.err" && ok \
    || bad "F4/nonl: a fragment without a final newline must still assemble: $(cat "$T/f/nonl.err")"
  grep -qxF "$(printf 'log\tmc_stamp\tlib')" "$T/f/nonl.out" && grep -qxF "$(printf 'queue\tmc_other\tlib')" "$T/f/nonl.out" && ok \
    || bad "F4/nonl: both rows must come out on their own lines: $(tr '\n' '|' < "$T/f/nonl.out")"
else
  bad "F4/nonl: mc_expected_map is not defined"
fi
# A symlinked fragment is refused, never skipped in silence.
frag link 00-base.tsv 'log\tmc_stamp\tlib\n'
printf 'queue\tmc_linked\tlib\n' > "$T/f/elsewhere.tsv"
ln -s "$T/f/elsewhere.tsv" "$T/f/link/BH-3.tsv"
refuses link "BH-3.tsv"
mkdir -p "$T/f/empty"
refuses empty "no *.tsv fragment"
refuses missing "no *.tsv fragment"

# ── F5. the consumers read the directory ────────────────────────────────────
for s in tests/mc-split-layout-test.sh tests/mc/lib-complete-test.sh tests/mc/driver-complete-test.sh; do
  grep -q 'tests/mc/expected-map\.d' "$DIR/$s" && grep -q 'mc_expected_map ' "$DIR/$s" && ok \
    || bad "F5: $s must assemble tests/mc/expected-map.d through mc_expected_map"
  grep -q 'tests/mc/expected-map\.tsv' "$DIR/$s" \
    && bad "F5: $s still reads the retired tests/mc/expected-map.tsv" || ok
done

echo "mc/expected-map-fragments-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
