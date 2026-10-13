#!/bin/bash
# tests/test-impact-gate.bh-1524-test.sh — BH-1524: A BUILD OF THIS REPO RUNS
# THE SUITES ITS DIFF CAN REACH BEFORE IT PUSHES.
#
# Until BH-1524, HARNESS_SUITE_RUN picked the suite command out of package.json
# and nothing else. cromford has no package.json, so every pool build of
# it recorded `HARNESS_EXIT: no-test-script` and pushed having run NO suite —
# and the pinned-contract suites (T1.32, expected-map, the br_close_pr caller
# pin, A10, the gh-rest contract check) were first run by CI, a review round late.
#
#   G1  THE PRODUCTION CALLER. The harness-suite block, extracted verbatim from
#       the flattened pipeline, run in a scratch checkout shaped like this repo
#       (bash suites, no package.json, bin/test-impact-gate.sh). It must run the
#       gate, not record no-test-script — red on main, which is the ticket.
#   G2  the gate's red is the build's red: a pin that breaks is HARNESS_EXIT 1
#   G3  the cap: strongest reason first (self > reads > always > named > source
#       > closure), the rest named as left to CI, and --runner plan runs NOTHING
#       and says so
#   G4  no selection is rc 2 — never a green of nothing
#   G5  root beside a live harness: auto picks the isolated runner. As real
#       root (the Fly test host) the suites run as nobody in a snapshot; as a
#       non-root user the snapshot cannot be handed to nobody, which is rc 125
#       and HARNESS_EXIT `could-not-run` — not green and not a red suite
#   G6  --base is resolved to the merge-base: main moving on after the fork
#       must not add main's suites to this branch's gate
#   G7  a setpriv that cannot switch to nobody is rc 125, never red suites
#       (#1541 review C1/I1: as nobody, `setpriv --clear-groups` exits 127 and
#       every pool build read HARNESS_EXIT 1)
#   G8  the stage's timeout killing the gate is could-not-run, with the suites
#       that completed listed — never a pass, never a fail (review I2)
#   G9  the budget: once spent, no suite is STARTED, and the unstarted ones
#       are named as left to CI; the verdict is about what ran. Run on a stub
#       `date +%s` that only slow-test advances (BH-1741), so the cut-off is
#       exact on any runner; G9b moves the stub by less and runs-test starts.
#       It reads its own durations file, never the one G1-G8 timed on the
#       real clock, so the in-tier order is fixed too
#   G10 the cap and the budget are settings rows (lane.fly-pool[.<project>].*),
#       resolved through bin/lib/lane-gate.sh's lane_knob
#
# Real git repos under $T, the real scripts, no mocks of the gate or the
# selector. No network, no secrets, no clock read beyond one pinned stamp.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null || { echo "test-impact-gate: git is required for this suite"; exit 2; }

NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
# The gate records each suite's time for the next run's ordering (BH-1554). Its
# default is the live harness state dir, so every run here writes to scratch.
export TEST_IMPACT_DURATIONS_FILE="$T/state/test-impact-durations.tsv"

# ── the fixture: this repo's shape, in miniature ────────────────────────────
R="$T/repo"
mkdir -p "$R/bin/lib" "$R/tests" "$R/docs"
for f in bin/test-impact.sh bin/test-impact-gate.sh bin/test-suite-run.sh bin/lib/suite-runner.sh bin/lib/train-shape.sh; do
  cp "$DIR/$f" "$R/$f"
done
chmod +x "$R/bin/"*.sh
cat > "$R/bin/lib/widget.sh" <<'SH'
#!/bin/bash
widget_count_open() { echo 3; }
widget_close_all() { echo closed; }
SH
cat > "$R/bin/tool.sh" <<'SH'
#!/bin/bash
. "$(dirname "$0")/lib/widget.sh"
widget_count_open
SH
# reads-test: the pin shape — greps the library's TEXT.
cat > "$R/tests/reads-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
if grep -q 'widget_close_all()' "$DIR/bin/lib/widget.sh"; then echo "reads: 1 passed, 0 failed"
else echo "FAIL: widget_close_all is gone"; echo "reads: 0 passed, 1 failed"; exit 1; fi
SH
# names-test: names a function of widget.sh and no path at all.
cat > "$R/tests/names-test.sh" <<'SH'
#!/bin/bash
: widget_count_open
echo "names: 1 passed, 0 failed"
SH
# runs-test: reaches widget.sh only through bin/tool.sh's source line.
cat > "$R/tests/runs-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
bash "$DIR/bin/tool.sh" >/dev/null
echo "runs: 1 passed, 0 failed"
SH
# wide-test: the always-run floor. It also says who ran it, for G5.
cat > "$R/tests/wide-test.sh" <<'SH'
#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
git -C "$DIR" ls-files >/dev/null
echo "wide ran as uid $(id -u)"
echo "wide: 1 passed, 0 failed"
SH
# slow-test: names widget_close_all, and takes SLOW_SUITE seconds when asked —
# the suite a budget or a stage timeout lands on (G8, G9). Under FAKE_CLOCK (G9)
# those seconds are ADDED to the stub clock rather than slept, so the budget
# cut-off is arithmetic; without it (G8's stage timeout) it really sleeps.
cat > "$R/tests/slow-test.sh" <<'SH'
#!/bin/bash
: widget_close_all
if [ -n "${FAKE_CLOCK:-}" ]; then
  echo $(( $(cat "$FAKE_CLOCK") + ${SLOW_SUITE:-0} )) > "$FAKE_CLOCK"
else
  sleep "${SLOW_SUITE:-0}"
fi
echo "slow: 1 passed, 0 failed"
SH
# The stub clock for G9: `date +%s` reads $FAKE_CLOCK, anything else is the
# real date. The gate's DEADLINE and its RUN_LOOP both call `date +%s` off PATH.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/date" <<SH
#!/bin/bash
[ -n "\${FAKE_CLOCK:-}" ] && [ "\$*" = "+%s" ] && { cat "\$FAKE_CLOCK"; exit 0; }
exec $(command -v date) "\$@"
SH
chmod +x "$T/fakebin/date"
# other-test: nothing to do with widget.sh — the precision assertion.
cat > "$R/tests/other-test.sh" <<'SH'
#!/bin/bash
echo "OTHER RAN"
echo "other: 1 passed, 0 failed"
SH
echo note > "$R/docs/n.md"
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)
echo '# touched' >> "$R/bin/lib/widget.sh"; gitc commit -qam "touch widget"

# ── G1. HARNESS_SUITE_RUN, extracted verbatim, runs the gate ────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
python3 - "$RB_ALL" "$T/suite-block.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
b = s.index("# >>> harness suite run")
e = s.index("# <<< harness suite run")
open(sys.argv[2], "w").write(s[b:e])
PY
[ -s "$T/suite-block.sh" ] && ok || bad "G1: could not extract the harness suite block"
mkdir -p "$T/build"
suite_run() { # suite_run <outfile> [VAR=value ...] — the block, in the checkout
  local out="$1"; shift
  ( cd "$R" || exit 1
    env "$@" HARNESS="$T/h" PROJECT=cromford KEY=BH-1524 BUILD="$T/build" BASE="$BASE" \
    bash -c 'set -uo pipefail
             STAMP() { echo stamp; }
             . "'"$T"'/suite-block.sh"
             HARNESS_SUITE_RUN "$1" lenses' _ "$out" )
}
suite_run g1.txt TEST_IMPACT_GATE_RUNNER=local
H1=$(head -1 "$T/build/g1.txt")
[ "$H1" = "HARNESS_SUITE: impact gate — bin/test-impact-gate.sh --base $BASE" ] \
  && ok || bad "G1: a checkout with bin/test-impact-gate.sh and no package.json must run the gate (got: $H1 / $(tail -1 "$T/build/g1.txt"))"
grep -qx 'HARNESS_EXIT: 0' "$T/build/g1.txt" \
  && ok || bad "G1: the gate's real exit must be recorded (got: $(grep HARNESS_EXIT "$T/build/g1.txt"))"
grep -q 'no-test-script' "$T/build/g1.txt" && bad "G1: this repo shape must never record no-test-script again" || ok
for s in reads-test names-test runs-test wide-test; do
  grep -q -- "--- tests/$s.sh" "$T/build/g1.txt" && ok || bad "G1: tests/$s.sh can reach bin/lib/widget.sh and must RUN (got: $(grep -- '^--- ' "$T/build/g1.txt" | tr '\n' ' '))"
done
grep -q 'OTHER RAN' "$T/build/g1.txt" && bad "G1: tests/other-test.sh cannot reach the diff and must not run" || ok
# The PR body's gate table comes from this run, not from a hand-written list.
# Reasons ride strongest first, so the pin's own line LEADS with `reads`.
grep -qF '| `tests/reads-test.sh` | reads bin/lib/widget.sh;' "$T/build/impact-gate-lenses.md" \
  && ok || bad "G1: the generated gate table must carry the pin and its reason (got: $(head -8 "$T/build/impact-gate-lenses.md" 2>/dev/null | tr '\n' ' '))"
grep -q ': passed\.\*\*$' "$T/build/impact-gate-lenses.md" \
  && ok || bad "G1: the table's first line must carry the run's verdict (got: $(head -1 "$T/build/impact-gate-lenses.md" 2>/dev/null))"

# ── G2. a broken pin is a red build ─────────────────────────────────────────
gitc reset -q --hard "$BASE"
sed -i.bak '/widget_close_all/d' "$R/bin/lib/widget.sh" && rm -f "$R/bin/lib/widget.sh.bak"
gitc commit -qam "drop widget_close_all"
suite_run g2.txt TEST_IMPACT_GATE_RUNNER=local
grep -qx 'HARNESS_EXIT: 1' "$T/build/g2.txt" \
  && ok || bad "G2: a red pin must be HARNESS_EXIT 1 (got: $(grep HARNESS_EXIT "$T/build/g2.txt"))"
grep -q 'widget_close_all is gone' "$T/build/g2.txt" && ok || bad "G2: the red suite's own output must be in the build record"

# ── G3. the cap, and plan ───────────────────────────────────────────────────
gitc reset -q --hard "$BASE"
echo '# touched' >> "$R/bin/lib/widget.sh"; gitc commit -qam "touch widget"
( cd "$R" && bin/test-impact-gate.sh --base "$BASE" --cap 2 --runner plan --list "$T/g3.list" --table "$T/g3.md" ) > "$T/g3.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "G3: plan exits 0 (got $RC: $(tail -2 "$T/g3.out"))"
[ "$(cat "$T/g3.list" 2>/dev/null)" = "$(printf 'tests/reads-test.sh\ntests/wide-test.sh')" ] \
  && ok || bad "G3: cap 2 must keep the strongest reasons, reads then always (got: $(tr '\n' ' ' < "$T/g3.list" 2>/dev/null))"
grep -q 'left to CI by the cap: 3' "$T/g3.out" && grep -q '^plan:   tests/runs-test.sh' "$T/g3.out" && grep -q '^plan:   tests/names-test.sh' "$T/g3.out" \
  && ok || bad "G3: what is past the cap must be counted and named as left to CI (got: $(tr '\n' '|' < "$T/g3.out"))"
grep -q -- '--- tests/' "$T/g3.out" && bad "G3: --runner plan must run nothing" || ok
grep -q 'NOT RUN' "$T/g3.out" && grep -q 'NOT RUN' "$T/g3.md" \
  && ok || bad "G3: a plan must SAY it ran nothing, in the log and the table"
grep -q 'Left to CI (3)' "$T/g3.md" && ok || bad "G3: the table must list what was left to CI"

# ── G4. no selection is rc 2 ────────────────────────────────────────────────
( cd "$R" && bin/test-impact-gate.sh --base no-such-ref --runner local ) > "$T/g4.out" 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "G4: an unresolvable base must be rc 2, never a green (got $RC: $(tail -2 "$T/g4.out"))"
( cd "$R" && bin/test-impact-gate.sh --base "$BASE" --cap 0 ) >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "G4: --cap 0 must be refused (got $RC)"

# ── G6. the base is the fork point, not the tip of a moved main ─────────────
# A branch that main has moved past: main's own commit (touching
# tests/other-test.sh) is not this branch's diff, and its suite must not be
# selected. A two-dot diff against main's tip would select it.
gitc reset -q --hard "$BASE"
gitc branch -q -f mainline "$BASE"
gitc checkout -q -b feature6
echo '# touched' >> "$R/bin/lib/widget.sh"; gitc commit -qam "feature: touch widget"
gitc checkout -q mainline
echo '# main moved' >> "$R/tests/other-test.sh"; gitc commit -qam "main moves on"
gitc checkout -q feature6
( cd "$R" && bin/test-impact-gate.sh --base mainline --runner plan --list "$T/g6.list" ) > "$T/g6.out" 2>&1; RC=$?
[ "$RC" = 0 ] && grep -qx tests/reads-test.sh "$T/g6.list" \
  && ok || bad "G6: the branch's own diff must still be selected (rc $RC: $(tr '\n' ' ' < "$T/g6.list" 2>/dev/null))"
grep -qx tests/other-test.sh "$T/g6.list" \
  && bad "G6: a suite main changed after the fork is not this branch's diff — the base must be the merge-base" || ok

# ── G5. root beside a live harness picks the isolated runner ───────────────
# `id -u` answers 0 through a stub, and HARNESS_ROOT_OVERRIDE names a directory
# that exists: that is the pool builder's position.
mkdir -p "$T/stub" "$T/live-harness"
# The stub answers only while ID_STUB_ROOT is set, so it cannot lie to the
# suites themselves: the isolated runner starts them under `env -i`.
cat > "$T/stub/id" <<SH
#!/bin/bash
[ -n "\${ID_STUB_ROOT:-}" ] && [ "\$*" = "-u" ] && { echo 0; exit 0; }
exec $(command -v id) "\$@"
SH
chmod +x "$T/stub/id"
suite_run g5.txt PATH="$T/stub:$PATH" ID_STUB_ROOT=1 HARNESS_ROOT_OVERRIDE="$T/live-harness"
if [ "$(id -u)" = 0 ] && command -v setpriv >/dev/null 2>&1; then
  # Real root: the snapshot really is handed to nobody and the suites run.
  grep -qx 'HARNESS_EXIT: 0' "$T/build/g5.txt" \
    && ok || bad "G5: as root the isolated runner must run the suites green (got: $(grep -E 'HARNESS_EXIT|isolated' "$T/build/g5.txt"))"
  NOBODY=$(id -u nobody)
  grep -q "wide ran as uid $NOBODY" "$T/build/g5.txt" \
    && ok || bad "G5: the suites must run as nobody ($NOBODY), not root (got: $(grep 'wide ran as' "$T/build/g5.txt"))"
else
  # Not root: the snapshot cannot be handed to nobody. That is 125 from the gate
  # and `could-not-run` in the record — the class no-test-script is in.
  grep -qx 'HARNESS_EXIT: could-not-run' "$T/build/g5.txt" \
    && ok || bad "G5: a runner that cannot start must record could-not-run (got: $(grep -E 'HARNESS_EXIT|isolated' "$T/build/g5.txt"))"
fi
grep -q 'via isolated' "$T/build/g5.txt" \
  || grep -q 'isolated runner' "$T/build/g5.txt" \
  && ok || bad "G5: root beside a live harness must pick the isolated runner (got: $(tail -3 "$T/build/g5.txt" | tr '\n' '|'))"

# ── G7. a setpriv that cannot switch is could-not-run ───────────────────────
# chown answers yes and setpriv exits 127 — the pair a nobody caller meets (it
# owns its own snapshot, and setgroups is refused). Real root cannot reproduce
# that pair on its own, so both are stubbed: the claim is the gate's mapping.
mkdir -p "$T/stub7"
printf '#!/bin/bash\nexit 0\n' > "$T/stub7/chown"
printf '#!/bin/bash\necho "setpriv: setgroups failed: Operation not permitted" >&2\nexit 127\n' > "$T/stub7/setpriv"
chmod +x "$T/stub7/chown" "$T/stub7/setpriv"
gitc checkout -q -f feature6 2>/dev/null
( cd "$R" && PATH="$T/stub7:$PATH" bin/test-impact-gate.sh --base "$BASE" --runner isolated ) > "$T/g7.out" 2>&1; RC=$?
[ "$RC" = 125 ] && ok || bad "G7: a setpriv that cannot switch to nobody must be rc 125, not red suites (got $RC: $(tail -2 "$T/g7.out" | tr '\n' '|'))"
grep -q 'setpriv cannot switch' "$T/g7.out" && ok || bad "G7: the refusal must say what could not happen (got: $(tail -3 "$T/g7.out" | tr '\n' '|'))"
grep -q -- '--- tests/' "$T/g7.out" && bad "G7: no suite may run when the switch is refused" || ok

# ── G8. the stage's timeout is could-not-run, with what completed ───────────
# `timeout` is stubbed to four seconds; slow-test sleeps thirty. Everything
# ranked ahead of it finishes first and must be listed as completed.
if REAL_TIMEOUT=$(command -v timeout); then
  mkdir -p "$T/stub8"
  printf '#!/bin/bash\nshift\nexec %s 4 "$@"\n' "$REAL_TIMEOUT" > "$T/stub8/timeout"
  chmod +x "$T/stub8/timeout"
  suite_run g8.txt PATH="$T/stub8:$PATH" TEST_IMPACT_GATE_RUNNER=local SLOW_SUITE=30
  grep -qx 'HARNESS_EXIT: could-not-run' "$T/build/g8.txt" \
    && ok || bad "G8: a gate the stage timed out is could-not-run, never a red 124 (got: $(grep HARNESS_EXIT "$T/build/g8.txt"))"
  grep -q 'TIMED OUT' "$T/build/g8.txt" && grep -q '^  tests/reads-test.sh rc=0' "$T/build/g8.txt" \
    && ok || bad "G8: the record must say it timed out and list the suites that completed (got: $(grep -A4 'TIMED OUT' "$T/build/g8.txt" | tr '\n' '|'))"
  grep -q '^  tests/slow-test.sh' "$T/build/g8.txt" && bad "G8: the suite the timeout killed did not complete and must not be listed as done" || ok
  grep -q 'timed out' "$T/build/impact-gate-lenses.md" && ok || bad "G8: the gate table must say it timed out"
else
  echo "test-impact-gate: G8 needs coreutils timeout — not run here"; FAIL=$((FAIL+1))
fi

# ── G9. the budget stops STARTING suites ───────────────────────────────────
# Order: reads, wide (always), names, slow (named), runs (closure). On the stub
# clock every suite takes zero seconds except slow-test, which advances it by
# three against a two-second budget — so runs-test is never started, on any
# machine at any load (BH-1741: on the real clock a loaded runner could spend
# the budget before slow-test, or a fast one after it). It is named as left to
# CI, and the verdict is about what ran.
# Each g9 run also gets a durations file of its own that does not exist yet
# (BH-1554 ordering): every suite is then "never timed" and a tier keeps its
# alphabetical order, so the cut-off is the stub clock's and nothing else's.
g9() { # g9 <tag> <slow seconds> — the gate on the stub clock, budget 2
  echo "$NOW" > "$T/clock"
  ( cd "$R" && PATH="$T/fakebin:$PATH" FAKE_CLOCK="$T/clock" SLOW_SUITE="$2" \
      TEST_IMPACT_DURATIONS_FILE="$T/$1.durations.tsv" \
      bin/test-impact-gate.sh --base "$BASE" --runner local --budget 2 --table "$T/$1.md" ) > "$T/$1.out" 2>&1
}
# THE ORDER IS PART OF THE FIXTURE, AND G1-G8 WROTE TO IT. The gate orders a
# tier shortest-first from the durations file (BH-1554), and every run above
# recorded REAL seconds there. names-test and slow-test share the named tier:
# a loaded runner that timed names-test at 1s and slow-test at 0s put slow-test
# first, the budget then left names-test AND runs-test, and the table read
# "2 by the budget" (CI run 36222858456). That box's file is seeded here, so the
# test no longer depends on how fast G1-G8 happened to run — g9 must not read it.
printf 'tests/names-test.sh\t1\ntests/slow-test.sh\t0\n' > "$TEST_IMPACT_DURATIONS_FILE"
g9 g9 3; RC=$?
grep -- '^--- tests/' "$T/g9.out" | sed 's/^--- //; s/ .*//' | tr '\n' ' ' > "$T/g9.order"
[ "$(cat "$T/g9.order")" = "tests/reads-test.sh tests/wide-test.sh tests/names-test.sh tests/slow-test.sh " ] \
  && ok || bad "G9: the run order must be the fixture's (reads, wide, names, slow), whatever earlier runs recorded (got: $(cat "$T/g9.order"))"
[ "$RC" = 0 ] && ok || bad "G9: running out of budget is not a failure of what ran (got $RC: $(tail -3 "$T/g9.out" | tr '\n' '|'))"
grep -q 'impact-gate: done tests/slow-test.sh rc=0' "$T/g9.out" && ok || bad "G9: a suite started before the deadline must finish"
grep -q -- '--- tests/runs-test.sh' "$T/g9.out" && bad "G9: no suite may START after the budget is spent" || ok
grep -q 'budget ran out' "$T/g9.out" && grep -q '^  tests/runs-test.sh' "$T/g9.out" \
  && ok || bad "G9: the unstarted suites must be named as left to CI (got: $(grep -A3 budget "$T/g9.out" | tr '\n' '|'))"
grep -q '1 by the budget' "$T/g9.md" && grep -qF -- '- `tests/runs-test.sh`' "$T/g9.md" \
  && ok || bad "G9: the table must count and name what the budget left (got: $(head -2 "$T/g9.md" | tr '\n' '|'))"
sed -n '1s/.*ran \([0-9]*\) of \([0-9]*\) selected.*/\1 \2/p' "$T/g9.md" > "$T/g9.counts"
sed -n '2s/.*Left to CI: \([0-9]*\) by the cap, \([0-9]*\) by the budget.*/\1 \2/p' "$T/g9.md" >> "$T/g9.counts"
read -r G9RAN G9N < <(sed -n 1p "$T/g9.counts"); read -r G9L G9B < <(sed -n 2p "$T/g9.counts")
[ -n "${G9RAN:-}" ] && [ -n "${G9B:-}" ] && [ "$((G9RAN + G9L + G9B))" = "${G9N:-x}" ] \
  && [ "$(grep -c '(not started: budget)' "$T/g9.md")" = "$G9B" ] \
  && ok || bad "G9: the table's ran + left-by-cap + left-by-budget must be the selection, and it must mark exactly the budget's rows (got: $(tr '\n' '|' < "$T/g9.counts"))"
# G9b: the same run with slow-test taking ONE stub second. The clock is what
# decides the cut-off, so now runs-test is started and nothing is left.
g9 g9b 1; RC=$?
[ "$RC" = 0 ] && ok || bad "G9b: a run inside its budget is green (got $RC: $(tail -3 "$T/g9b.out" | tr '\n' '|'))"
grep -q -- '--- tests/runs-test.sh' "$T/g9b.out" && ok || bad "G9b: with budget left, runs-test must be started (got: $(grep -- '^--- ' "$T/g9b.out" | tr '\n' ' '))"
grep -q '0 by the budget' "$T/g9b.md" && ok || bad "G9b: the table must say the budget left nothing (got: $(head -2 "$T/g9b.md" | tr '\n' '|'))"

# ── G10. the cap and the budget are settings rows ──────────────────────────
# The real resolver (bin/lib/lane-gate.sh) under a scratch $HARNESS, the real
# registry composed from catalog/lanes.d, and a settings cache the resolver
# treats as fresh. The lane-wide row sets the cap; a project row beats it.
mkdir -p "$T/h10/bin/lib" "$T/h10/state"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h10/bin/lib/"
( cd "$DIR" && bin/lanes-build.sh ) > "$T/lanes.json" 2>/dev/null
jq -e '.lanes[]|select(.id=="fly-pool")|.knobs[]|select(.env=="TEST_IMPACT_GATE_CAP")' "$T/lanes.json" >/dev/null \
  && ok || bad "G10: TEST_IMPACT_GATE_CAP must be a registered knob of the fly-pool lane"
printf '{"fetched_at":%s,"values":{"lane.fly-pool.test_impact_gate_cap":"1","lane.fly-pool.test_impact_gate_budget_s":"120","lane.fly-pool.demo.test_impact_gate_cap":"2"}}\n' "$NOW" \
  > "$T/h10/state/settings-cache.json"
g10() { ( cd "$R" && HARNESS="$T/h10" LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW="$NOW" \
          bin/test-impact-gate.sh --base "$BASE" --runner plan "$@" ) 2>&1; }
OUT=$(g10)
grep -q '(cap 1, budget 120s)' <<<"$OUT" && ok || bad "G10: the lane-wide rows must set the cap and the budget (got: $(grep 'running up to' <<<"$OUT"))"
OUT=$(g10 --project demo)
grep -q '(cap 2, budget 120s)' <<<"$OUT" && ok || bad "G10: a project row must beat the lane-wide row (got: $(grep 'running up to' <<<"$OUT"))"
OUT=$(g10 --project demo --cap 3)
grep -q '(cap 3, budget 120s)' <<<"$OUT" && ok || bad "G10: an explicit --cap beats every row (got: $(grep 'running up to' <<<"$OUT"))"

echo "test-impact-gate: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
