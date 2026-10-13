#!/bin/bash
# tests/gates-to-reports.bh-5292-test.sh — BH-5292: a limit on something that
# is not itself harmful (time, size, a missing timing row) is REPORTED, never a
# red. Each case drives the real script or the real production block.
#
#   R1  fast-lints-data: an always-suite with no durations row prints a WARN
#       naming the suite and the suite passes; a malformed durations row still
#       fails it
#   R2  fast-lints --list: an unmeasured suite weighs the durations file's
#       median (the shard split's stand-in) and is still named as unmeasured
#   R3  fast-lints --assert-budget: over the total budget, and a row over
#       2 x FAST_LINTS_MAX_S, each rc 0 with the note on stderr; a malformed
#       timings file is still rc 2
#   R4  harness-ci.yml: the fast always-lints step's last line requires only
#       prc and frc; brc is still computed and printed
#   R5  rb/pr tier: a 1,000-line diff on plain paths stays tier 1 and carries
#       the "large diff: N lines" note; a protected-path diff is still tier 2
#   R6  the five former wall-clock suites pass with a sleep injected into their
#       stubs (WALLCLOCK_STUB_SLEEP_S=6, which every old <=3 / <=5 / <5 bound failed)
#   R7  bin/size-gate.sh: no '## Size' warns, estimates from the file list and
#       proceeds (rc 0); a declaration at 2x the threshold still splits (rc 2);
#       an estimate over 2x the threshold still splits
#   R8  docs/GATES-VS-REPORTS.md names what is hard and what reports
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/gates-to-reports.bh-5292-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
mkdir -p "$T/h"
export HARNESS="$T/h"
unset FAST_LINTS_MAX_S FAST_LINTS_BUDGET_S FAST_LINTS_DURATIONS PROJECT WALLCLOCK_STUB_SLEEP_S
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ═══ R1 the durations-row requirement is a warning ═══════════════════════════
echo "R1: fast-lints-data"
R="$T/r1"; mkdir -p "$R/tests" "$R/catalog"
: > "$R/catalog/test-impact-always.txt"
# The same always-run trigger tests/test-impact-always-re.bh-4551-test.sh F9 uses.
printf '%s\n' 'git -C "$DIR" ls-files | wc -l' > "$R/tests/wide-test.sh"
# TEST-CHANGE (merge with main's BH-5518): D2 and D4 now read this same file,
# so the fixture carries the two rows they pin (gh-rest-no-subshell-lint and
# the gh-app ratchet). Without them an empty file fails D2/D4, not D1. The
# missing row under test is still tests/wide-test.sh's.
printf '# durations fixture: only the rows D2 and D4 pin\ntests/gh-rest-no-subshell-lint.sh\t1.0\t1\ntests/gh-app-ratchet-test.sh\t1.0\t1\n' > "$T/r1-missing.tsv"
FLD_ROOT="$R" FLD_DURATIONS="$T/r1-missing.tsv" bash "$DIR/tests/fast-lints-data.bh-3860-test.sh" > "$T/r1a.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "R1a a missing row passes the suite" || bad "R1a rc=$rc: $(grep -E 'FAIL|WARN' "$T/r1a.out" | tr '\n' '|')"
grep -qE '^  WARN D1 .*tests/wide-test.sh' "$T/r1a.out" && ok "R1a the warning names the suite" \
  || bad "R1a no WARN naming tests/wide-test.sh: $(grep D1 "$T/r1a.out" | tr '\n' '|')"
grep -qF 'D1 hint: tests/wide-test.sh is always-run via tests/wide-test.sh:1' "$T/r1a.out" \
  && ok "R1a the hint still names the matched line" || bad "R1a no hint: $(grep D1 "$T/r1a.out" | tr '\n' '|')"
# TEST-CHANGE (merge with main's BH-5518): main deleted fast-lints-data D3, the
# refresh-paragraph provenance check, because CI now composes the durations
# file (bin/ci-durations.sh) and it has no hand-written refresh paragraph. The
# R1a assertion that D3 is a warning had no check left to assert on.
grep -q 'D3' "$T/r1a.out" && bad "R1a D3 is gone on main (BH-5518) but still runs: $(grep D3 "$T/r1a.out" | tr '\n' '|')" \
  || ok "R1a no D3 provenance check runs (main dropped it, BH-5518)"
printf '# durations fixture\ntests/wide-test.sh\tabc\t123456789\n' > "$T/r1-bad.tsv"
FLD_ROOT="$R" FLD_DURATIONS="$T/r1-bad.tsv" bash "$DIR/tests/fast-lints-data.bh-3860-test.sh" > "$T/r1b.out" 2>&1; rc=$?
[ "$rc" != 0 ] && ok "R1b a malformed row still fails" || bad "R1b rc=0 with a malformed row"
grep -qE 'FAIL D0 .*line 2' "$T/r1b.out" && ok "R1b the failure names the malformed line" \
  || bad "R1b no D0 failure naming line 2: $(grep -E 'D0|FAIL' "$T/r1b.out" | tr '\n' '|')"
printf '# durations fixture\ntests/wide-test.sh\t1.0\n' > "$T/r1-short.tsv"
FLD_ROOT="$R" FLD_DURATIONS="$T/r1-short.tsv" bash "$DIR/tests/fast-lints-data.bh-3860-test.sh" > "$T/r1c.out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'FAIL D0' "$T/r1c.out" && ok "R1c a row with no run id is malformed" || bad "R1c rc=$rc"

# ═══ R2 fast-lints --list weighs an unmeasured suite at the median ═══════════
echo "R2: fast-lints --list median stand-in"
F="$T/r2"; mkdir -p "$F/bin" "$F/catalog" "$F/tests"; git -C "$F" init -q
cp "$DIR/bin/fast-lints.sh" "$DIR/bin/test-impact.sh" "$F/bin/"
for s in a b c new-x; do printf '#!/bin/bash\nexit 0\n' > "$F/tests/$s-test.sh"; done
printf 'tests/a-test.sh a\ntests/b-test.sh b\ntests/c-test.sh c\ntests/new-x-test.sh x\n' > "$F/catalog/test-impact-always.txt"
: > "$F/catalog/rules-pack.tsv"
printf 'tests/a-test.sh\t1.0\t1\ntests/b-test.sh\t2.0\t1\ntests/c-test.sh\t30.0\t1\n' > "$F/dur.tsv"
FAST_LINTS_DURATIONS="$F/dur.tsv" "$F/bin/fast-lints.sh" --list > "$F/out" 2> "$F/err"; rc=$?
[ "$rc" = 0 ] && grep -qxF tests/new-x-test.sh "$F/out" && ok "R2a median 2.0 <= 10: the unmeasured suite is in the fast set" \
  || bad "R2a rc=$rc out=$(tr '\n' ' ' < "$F/out") err=$(cat "$F/err")"
grep -q 'unmeasured: tests/new-x-test.sh;' "$F/err" && ok "R2a it is still named as unmeasured" || bad "R2a err=$(cat "$F/err")"
printf 'tests/a-test.sh\t11.0\t1\ntests/b-test.sh\t12.0\t1\ntests/c-test.sh\t30.0\t1\n' > "$F/dur.tsv"
FAST_LINTS_DURATIONS="$F/dur.tsv" "$F/bin/fast-lints.sh" --list > "$F/out" 2> "$F/err"; rc=$?
[ "$rc" = 0 ] && ! grep -qxF tests/new-x-test.sh "$F/out" && ok "R2b median 12.0 > 10: left out like any slow suite" \
  || bad "R2b rc=$rc out=$(tr '\n' ' ' < "$F/out")"

# ═══ R3 fast-lints --assert-budget reports, never reds ═══════════════════════
echo "R3: fast-lints --assert-budget"
printf 'a\t3\t0\nb\t4\t0\n' > "$T/tm.tsv"
FAST_LINTS_BUDGET_S=5 "$F/bin/fast-lints.sh" --assert-budget "$T/tm.tsv" > "$T/r3.out" 2> "$T/r3.err"; rc=$?
[ "$rc" = 0 ] && grep -q '7s over the 5s budget' "$T/r3.err" && ok "R3a over the total budget: rc 0 and the note" \
  || bad "R3a rc=$rc err=$(cat "$T/r3.err")"
printf 'a\t3\t0\nc\t25\t0\n' > "$T/tm.tsv"
FAST_LINTS_MAX_S=10 FAST_LINTS_BUDGET_S=600 "$F/bin/fast-lints.sh" --assert-budget "$T/tm.tsv" > "$T/r3.out" 2> "$T/r3.err"; rc=$?
[ "$rc" = 0 ] && grep -q 'c took 25s, over 2 x FAST_LINTS_MAX_S (20s)' "$T/r3.err" && ok "R3b a slow suite: rc 0 and named" \
  || bad "R3b rc=$rc err=$(cat "$T/r3.err")"
printf 'a\tx\t0\n' > "$T/tm.tsv"
"$F/bin/fast-lints.sh" --assert-budget "$T/tm.tsv" > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "R3c a malformed timings file is still rc 2" || bad "R3c rc=$rc"

# ═══ R4 the workflow step's verdict ══════════════════════════════════════════
echo "R4: harness-ci.yml fast always-lints"
step=$(awk '/- name: fast always-lints \(BH-3860\)/ { on = 1; next } on && /- name:/ { exit } on' "$DIR/.github/workflows/harness-ci.yml")
last=$(printf '%s\n' "$step" | sed '/^[[:space:]]*$/d' | tail -1 | sed 's/^[[:space:]]*//')
[ "$last" = '[ "$prc" = 0 ] && [ "$frc" = 0 ]' ] && ok "R4 the last line requires only prc and frc" || bad "R4 last line: $last"
grep -q 'bin/fast-lints.sh --assert-budget "$o/timings.tsv"; brc=\$?' <<<"$step" && grep -q 'budget rc=\$brc' <<<"$step" \
  && ok "R4 the budget is still measured and printed" || bad "R4 brc no longer computed/printed"

# ═══ R5 the diff-size tier ═══════════════════════════════════════════════════
echo "R5: rb/pr tier"
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { bad "R5 rb_all could not flatten the driver"; RB_ALL=/dev/null; }
pick() { A="$1" B="$2" awk 'index($0,ENVIRON["A"])>0 && index($0,ENVIRON["B"])>0 {print; exit}' "$RB_ALL"; }
PAT_LINE=$(pick "PAT='" 'schema\.prisma')
TIER_LINE=$(pick 'TIER=2' '"$PAT" <<<"$CHANGED"')
awk '/^# >>> diff size note/{f=1;next} /^# <<< diff size note/{exit} f' "$RB_ALL" > "$T/diffnote.sh"
[ -n "$PAT_LINE" ] && [ -n "$TIER_LINE" ] && [ -s "$T/diffnote.sh" ] && ok "R5 tier lines and the diff size note block extracted" \
  || bad "R5 extraction: pat=${PAT_LINE:+y} tier=${TIER_LINE:+y} note=$(wc -c < "$T/diffnote.sh")"
grep -qE 'TIER=2' "$T/diffnote.sh" && bad "R5 the diff size note block still sets TIER" || ok "R5 the diff size note block sets no TIER"
tier_of() { # tier_of <repo> -> "<tier>|<DIFF_NOTE>"
  ( cd "$1" || exit 1
    BASE=$(git rev-parse HEAD~1); TIER=1; BUILD="$T/r5b"; mkdir -p "$BUILD"; : > "$BUILD/pipeline.log"
    PROJECT=p KEY=K-1; STAMP() { echo TS; }
    CHANGED=$(git diff --name-only "$BASE"...HEAD)  # determinism: ok a diff inside a scratch fixture repo built two lines up, not this branch
    eval "$PAT_LINE"; eval "$TIER_LINE"
    . "$T/diffnote.sh"
    echo "$TIER|${DIFF_NOTE:-}" )
}
mkrepo() { # mkrepo <dir> <path> <lines>
  mkdir -p "$1"; git -C "$1" init -q; echo base > "$1/README"; git -C "$1" add -A; git -C "$1" commit -qm base
  mkdir -p "$1/$(dirname "$2")"; seq 1 "$3" > "$1/$2"; git -C "$1" add -A; git -C "$1" commit -qm change
}
mkrepo "$T/r5-big" src/lib/widget.ts 1000
got=$(tier_of "$T/r5-big")
[ "${got%%|*}" = 1 ] && ok "R5a a 1,000-line plain diff stays tier 1" || bad "R5a tier: $got"
[[ "${got#*|}" == *"large diff: 1000 lines"* ]] && ok "R5a and carries the large-diff note" || bad "R5a note: $got"
mkrepo "$T/r5-auth" src/auth/session.ts 5
got=$(tier_of "$T/r5-auth")
[ "${got%%|*}" = 2 ] && ok "R5b a protected-path diff is still tier 2" || bad "R5b tier: $got"
[ -z "${got#*|}" ] && ok "R5b a small diff carries no note" || bad "R5b note: $got"

# ═══ R6 the former wall-clock suites survive a slowed run ════════════════════
echo "R6: slowed runs"
for s in build-slot-gate-early.bh-5021-test.sh iron-law-guard-test.sh cost-rollup-liveness-test.sh wake-classes-hook.bh-1034-test.sh; do
  WALLCLOCK_STUB_SLEEP_S=6 HARNESS_TEST_SANDBOX=1 timeout 300 bash "$DIR/tests/$s" > "$T/r6-$s.out" 2>&1; rc=$?
  [ "$rc" = 0 ] && ok "R6 $s green with a 6s sleep in its stubs" \
    || bad "R6 $s rc=$rc slowed: $(grep -E 'FAIL' "$T/r6-$s.out" | head -3 | tr '\n' '|')"
done

# ═══ R7 the plan size gate ═══════════════════════════════════════════════════
echo "R7: bin/size-gate.sh"
GATE="$DIR/bin/size-gate.sh"
mkplan() { # mkplan <name> <n mentioned files> <size section or ''>
  local d="$T/r7-$1" i; mkdir -p "$d"
  { echo '# Plan'; for i in $(seq 1 "$2"); do echo "- src/lib/thing$i.ts"; done; echo; [ -n "$3" ] && printf '%s\n' "$3"; echo 'KIND: feature'; echo 'SIZE: M'; } > "$d/plan.md"
  for i in $(seq 1 "$2"); do echo "src/lib/thing$i.ts"; done > "$d/planned-files.txt"
  P="$d"
}
mkplan est 5 ''
G=$("$GATE" "$P/plan.md" 300 12 "$P/planned-files.txt" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "R7a no ## Size proceeds (rc 0)" || bad "R7a rc=$rc: $G"
grep -q '^SIZE_GATE_WARNING: ' <<<"$G" && ok "R7a with a warning" || bad "R7a no warning: $G"
grep -q '^SIZE_ESTIMATED: files=5 lines=125 ' <<<"$G" && ok "R7a size estimated from the file list (5 files x 300/12)" || bad "R7a estimate: $G"
grep -q '^SIZE_VERDICT: estimated$' <<<"$G" && ok "R7a verdict estimated" || bad "R7a verdict: $G"
grep -q '^SIZE_DECLARED:' <<<"$G" && bad "R7a an estimate must never read as a declaration: $G" || ok "R7a no SIZE_DECLARED line"
mkplan est-big 30 ''
G=$("$GATE" "$P/plan.md" 300 12 "$P/planned-files.txt" 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q '^SIZE_VERDICT: over$' <<<"$G" && grep -q 'estimated' <<<"$(grep '^SIZE_OVER:' <<<"$G")" \
  && ok "R7b an estimate over 2x the threshold (30 > 24 files) still splits" || bad "R7b rc=$rc: $G"
mkplan est-band 20 ''
G=$("$GATE" "$P/plan.md" 300 12 "$P/planned-files.txt" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "R7c an estimate between 1x and 2x proceeds (20 files, limit 12)" || bad "R7c rc=$rc: $G"
mkplan decl 3 $'## Size\nFILES: 3\nLINES: 600'
G=$("$GATE" "$P/plan.md" 300 12 "$P/planned-files.txt" 2>&1); rc=$?
[ "$rc" = 2 ] && grep -q '^SIZE_OVER: lines=600>300' <<<"$G" && ok "R7d a plan declaring 2x the threshold still splits" || bad "R7d rc=$rc: $G"
G=$("$GATE" "$T/no-plan.md" 300 12 2>&1); rc=$?
[ "$rc" = 3 ] && grep -q '^SIZE_VERDICT: undeclared$' <<<"$G" && ok "R7e no plan at all is still undeclared, rc 3" || bad "R7e rc=$rc: $G"

# ═══ R8 docs ═════════════════════════════════════════════════════════════════
echo "R8: docs"
D="$DIR/docs/GATES-VS-REPORTS.md"
if [ -s "$D" ] && grep -q '^# Gates vs reports' "$D" && grep -qi 'stays hard' "$D" && grep -qi 'reports' "$D"; then ok "R8 docs/GATES-VS-REPORTS.md"
else bad "R8 docs/GATES-VS-REPORTS.md missing or lacks the hard/report lists"; fi

echo "gates-to-reports.bh-5292: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
