#!/bin/bash
# tests/load-project-readiness-gate-test.sh — --require-readiness refuses BEFORE
# onboarding touches anything.
#
# WHY THE ORDER IS THE PROPERTY. load-project.sh appends a fleet.conf row,
# renders a prompt, commits, pushes, creates a label and bootstraps a box. A
# gate that ran anywhere inside that sequence would refuse a repo that is
# already half-enrolled, which is worse than no gate: the registry row is what
# cron reads, and a row whose box never bootstrapped is a lane that looks alive
# and builds nothing. So F1 drives the REAL script with a `gh` stub that records
# every invocation and asserts the stub was never reached — if the gate ever
# drifts below `== validate repo ==`, that marker appears and this suite is red.
#
# F3 is the other half: the default (--require-readiness absent, i.e. 0) must
# not invoke the report at all. It runs the gate block against a copied ROOT
# whose bin/readiness-report.sh is a marker-dropping stub, so "nothing changes
# for existing projects" is asserted rather than assumed.
#
# Run from anywhere: bash tests/load-project-readiness-gate-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LP="$DIR/bin/load-project.sh"
FIX="$DIR/tests/fixtures/readiness"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/h"
rm -rf "$T/a-empty" "$T/b-ready"
A="$T/a-empty"; mkdir -p "$A"; cp -R "$FIX/a-empty/." "$A/"
B="$T/b-ready"; mkdir -p "$B"; cp -R "$FIX/b-ready/." "$B/"

# Every gh call is recorded and refused: reaching gh at all is the failure this
# suite is about, and a stub that succeeded would let the script run on into the
# steps that write.
cat > "$T/bin/gh" <<STUB
#!/bin/bash
touch "$T/gh-called"
echo "gh \$*" >> "$T/gh-log"
exit 1
STUB
chmod +x "$T/bin/gh"

# ---------- F1. the real script refuses, and refuses early ------------------
rm -f "$T/gh-called" "$T/gh-log"
( cd "$T" && PATH="$T/bin:$PATH" HARNESS="$T/h" \
    bash "$LP" acme/x --require-readiness 4 --repo-dir "$A" ) >"$T/f1.out" 2>&1
RC=$?
[ "$RC" = 3 ] && ok || bad "F1: a repo below the bar must exit 3 (rc $RC)
$(sed 's/^/    /' "$T/f1.out")"
grep -q 'REFUSED' "$T/f1.out" && ok || bad "F1: the refusal must say REFUSED"
grep -q 'tests.present' "$T/f1.out" && ok || bad "F1: the refusal must name the gaps that caused it"
grep -q 'acme/x' "$T/f1.out" && ok || bad "F1: the refusal must name the repo it refused"
[ -f "$T/gh-called" ] && bad "F1: the gate must refuse BEFORE the first gh call" || ok
# Nothing in the checkout may move: the registry is the thing a refusal must
# leave alone.
[ -z "$(git -C "$DIR" status --porcelain -- fleet.conf)" ] \
  && ok || bad "F1: a refused enrolment must not touch fleet.conf"

# ---------- the gate block, extracted verbatim ------------------------------
python3 - "$LP" "$T/gate.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
b = s.index("# >>> readiness gate")
e = s.index("# <<< readiness gate")
open(sys.argv[2], "w").write("#!/bin/bash\nset -euo pipefail\n" + s[b:e])
PY
[ -s "$T/gate.sh" ] && ok || bad "load-project.sh must delimit its readiness gate with >>>/<<< markers"

# ---------- F2. a repo at the bar is waved through --------------------------
OUT=$(PATH="$T/bin:$PATH" HARNESS="$T/h" ROOT="$DIR" SLUG=acme/x \
      REQUIRE_READINESS=4 REPO_DIR="$B" bash "$T/gate.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "F2: a repo at the requested level must continue (rc $RC)
$(sed 's/^/    /' <<<"$OUT")"
grep -q 'continuing' <<<"$OUT" && ok || bad "F2: the gate must say it is continuing"
grep -q 'READINESS LEVEL: 4/5' <<<"$OUT" \
  && ok || bad "F2: the operator sees the table, not just a verdict"
grep -q 'preview.config' <<<"$OUT" \
  && ok || bad "F2: the operator sees the individual checks, not just the level line"

# ---------- F2b. the repo is graded ONCE ------------------------------------
# Two runs would ask GitHub the same read-only questions twice, and — worse —
# let the table the operator reads disagree with the level the gate acted on.
# A gate that prints REFUSED under a table showing the bar was met cannot be
# argued with. The stub counts invocations, so a second call is red here.
# --print-levels is counted separately and on purpose: it reads the level table
# and asks GitHub nothing, so it is not a grading run. What must never happen
# twice is the run that probes.
mkdir -p "$T/countroot/bin"
cat > "$T/countroot/bin/readiness-report.sh" <<STUB
#!/bin/bash
case "\$*" in
  *--print-levels*) echo p >> "$T/rr-levels" ;;
  *)                echo x >> "$T/rr-count" ;;
esac
exec "$DIR/bin/readiness-report.sh" "\$@"
STUB
chmod +x "$T/countroot/bin/readiness-report.sh"
rm -f "$T/rr-count" "$T/rr-levels"
OUT=$(PATH="$T/bin:$PATH" HARNESS="$T/h" ROOT="$T/countroot" SLUG=acme/x \
      REQUIRE_READINESS=4 REPO_DIR="$B" bash "$T/gate.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "F2b: the counting stub must not change the verdict (rc $RC)
$(sed 's/^/    /' <<<"$OUT")"
N=$(wc -l < "$T/rr-count" 2>/dev/null | tr -d ' ')
[ "$N" = 1 ] && ok || bad "F2b: the gate must grade the checkout exactly once (graded $N times)"

# ---------- F2c. the ceiling comes from the level table, not the script ------
# max_level lives in catalog/readiness-levels.json. A ceiling hardcoded here
# would mean adding a level to the catalog silently leaves the gate unable to
# ask for it — config that code refuses to honour is not config.
cat > "$T/six.json" <<'JSON'
{"_doc":"fixture","max_level":6,
 "levels":{"1":{"requires":["context.agents"],"must_not_fail":[],"unlocks":"x"},
           "6":{"requires":["context.vmap"],"must_not_fail":[],"unlocks":"x"}}}
JSON
OUT=$(PATH="$T/bin:$PATH" HARNESS="$T/h" ROOT="$DIR" SLUG=acme/x READINESS_LEVELS="$T/six.json" \
      REQUIRE_READINESS=6 REPO_DIR="$B" bash "$T/gate.sh" 2>&1); RC=$?
[ "$RC" = 3 ] && ok || bad "F2c: with a max_level of 6, asking for 6 is a grading refusal, not a usage error (rc $RC)
$(sed 's/^/    /' <<<"$OUT")"
grep -q 'REFUSED' <<<"$OUT" && ok || bad "F2c: level 6 against a 6-level table must be graded, not rejected as out of range"
# And one above that table's ceiling is still a usage error.
OUT=$(PATH="$T/bin:$PATH" HARNESS="$T/h" ROOT="$DIR" SLUG=acme/x READINESS_LEVELS="$T/six.json" \
      REQUIRE_READINESS=7 REPO_DIR="$B" bash "$T/gate.sh" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "F2c: 7 is above a 6-level table's ceiling and must be a usage error (rc $RC)"
grep -q '0-6' <<<"$OUT" && ok || bad "F2c: the usage error must name the table's real range (got '$OUT')"

# ---------- F2d. --repo-dir must be a checkout of the repo being enrolled ---
# --repo-dir is a path the operator types. Point it at the wrong clone and the
# gate printed "level 4 >= 4 — continuing" under a number computed for another
# repo, then enrolled $SLUG on it — the one number the flag exists to produce,
# about the wrong repo. The report resolves the graded checkout's own origin.
rm -rf "$T/other"; mkdir -p "$T/other"; G="$T/other"; cp -R "$B/." "$G/"
git -C "$G" init -q 2>/dev/null
git -C "$G" remote add origin https://github.com/other/repo.git
OUT=$(PATH="$T/bin:$PATH" HARNESS="$T/h" ROOT="$DIR" SLUG=acme/x \
      REQUIRE_READINESS=1 REPO_DIR="$G" bash "$T/gate.sh" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "F2d: a checkout of another repo is a usage error, not a grade (rc $RC)
$(sed 's/^/    /' <<<"$OUT")"
grep -q 'other/repo' <<<"$OUT" && ok || bad "F2d: the refusal must name the repo it actually graded"
grep -q 'acme/x' <<<"$OUT" && ok || bad "F2d: the refusal must name the repo being enrolled"
grep -q 'continuing' <<<"$OUT" && bad "F2d: a mismatched checkout must never wave the enrolment through" || ok
# The same checkout under its OWN slug grades normally: this refuses a mismatch,
# not every checkout that happens to have a remote.
OUT=$(PATH="$T/bin:$PATH" HARNESS="$T/h" ROOT="$DIR" SLUG=other/repo \
      REQUIRE_READINESS=1 REPO_DIR="$G" bash "$T/gate.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "F2d: the matching slug must still be graded and waved through (rc $RC)
$(sed 's/^/    /' <<<"$OUT")"
# And a directory with no github.com origin (every fixture, and any export)
# still grades — F2 above is that case, asserted here as the deliberate one.
TOPB=$(git -C "$B" rev-parse --show-toplevel 2>/dev/null) || TOPB=""
[ "$TOPB" != "$B" ] \
  && ok || bad "F2d: the b-ready fixture must not be a repo root, or F2 is not testing the empty-slug path"

# ---------- F3. the default never runs the report --------------------------
mkdir -p "$T/fakeroot/bin"
cat > "$T/fakeroot/bin/readiness-report.sh" <<STUB
#!/bin/bash
touch "$T/rr-called"
echo '{"level":0,"gaps":[]}'
exit 0
STUB
chmod +x "$T/fakeroot/bin/readiness-report.sh"
rm -f "$T/rr-called"
OUT=$(PATH="$T/bin:$PATH" ROOT="$T/fakeroot" SLUG=acme/x \
      REQUIRE_READINESS=0 REPO_DIR="$A" bash "$T/gate.sh" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "F3: the default must fall straight through (rc $RC: $OUT)"
[ -f "$T/rr-called" ] && bad "F3: --require-readiness 0 must not run the report at all" || ok
[ -z "$OUT" ] && ok || bad "F3: the default path must print nothing new (got '$OUT')"

# ---------- F4. a bar with nothing to grade --------------------------------
rm -f "$T/gh-called"
( cd "$T" && PATH="$T/bin:$PATH" bash "$LP" acme/x --require-readiness 4 ) >"$T/f4.out" 2>&1
RC=$?
[ "$RC" = 2 ] && ok || bad "F4: --require-readiness with no --repo-dir is a usage error (rc $RC)"
grep -q -- '--repo-dir' "$T/f4.out" && ok || bad "F4: the message must name the flag that is missing"
[ -f "$T/gh-called" ] && bad "F4: a usage error must not reach gh" || ok

# ---------- F5. a level that does not exist --------------------------------
( cd "$T" && PATH="$T/bin:$PATH" bash "$LP" acme/x --require-readiness 9 --repo-dir "$B" ) >"$T/f5.out" 2>&1
RC=$?
[ "$RC" = 2 ] && ok || bad "F5: an out-of-range level is refused, never clamped (rc $RC)"
( cd "$T" && PATH="$T/bin:$PATH" bash "$LP" acme/x --require-readiness four --repo-dir "$B" ) >"$T/f5b.out" 2>&1
RC=$?
[ "$RC" = 2 ] && ok || bad "F5: a non-integer level is a usage error (rc $RC)"

# ---------- F6. without the flag, onboarding behaves exactly as before ------
# The gate is opt-in, and the proof is that the unflagged run still walks into
# `== validate repo ==` and calls gh — the step the refusal above never reached.
rm -f "$T/gh-called"
( cd "$T" && PATH="$T/bin:$PATH" bash "$LP" acme/x --no-bootstrap ) >"$T/f6.out" 2>&1
[ -f "$T/gh-called" ] && ok || bad "F6: an unflagged run must reach the existing validate step"
grep -q '== validate repo ==' "$T/f6.out" && ok || bad "F6: the unflagged run must start where it always did"
grep -q 'REFUSED' "$T/f6.out" && bad "F6: an unflagged run must never refuse" || ok

echo "load-project-readiness-gate-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
