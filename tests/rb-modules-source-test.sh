#!/bin/bash
# reads-run-build: raw — it lifts the stage-module block out of the driver by its markers and pins that every bare call in the driver is expanded by the flatten; reading the flatten here would be the helper grading its own homework.
# tests/rb-modules-source-test.sh — the rb/ module seam (BH-478 part 1): the
# driver sources its stage modules, refuses to build on a half-synced box, and
# the suites can still read the pipeline as ONE text while the split is half
# done.
#
# WHY DRIVEN AND NOT GREPPED. Both halves are about what happens on a box, not
# about what somebody typed. `grep -q RB_MODULES bin/run-build.sh` passes just
# as happily on a loop that sources what it finds and shrugs at what it does
# not — which is a build running half a pipeline on a box whose bin/ arrived in
# two pieces, the failure this block exists to turn into one ALERTS line. So
# the block is lifted VERBATIM out of bin/run-build.sh by its markers and
# EXECUTED against a scratch harness, with the driver's own RESULT() lifted the
# same way, and every case asserts on artifacts: the exit code, the contents of
# ALERTS.log, and whether $BUILD/RESULT exists.
#
# The flatten helper is proven the same way: rb_all's output is compared byte
# for byte with cmp against a file, never grepped for a symbol. On the REAL repo
# (since the BH-572 cut, a driver of eleven bare calls) it pins that every call
# is expanded, so no reader suite at $RB_ALL reads a pipeline with a hole in it.
#
# Run from anywhere: tests/rb-modules-source-test.sh   (exit 0 = all pass)
# No network, no clock, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

MODS="gates plan execute spec review pr result"
RESUME=""   # set only for the resumed-build case below

# ============================================================================
# 1. The block itself, lifted by its markers
# ============================================================================
awk '/^# >>> stage modules/{f=1;next} /^# <<< stage modules/{exit} f' \
  "$DIR/bin/run-build.sh" > "$T/block.sh"
if [ -s "$T/block.sh" ]; then
  ok
else
  bad "could not extract the stage-module block by its markers"
  echo "rb-modules-source-test: $PASS pass, $((FAIL+1)) fail"
  exit 1
fi
bash -n "$T/block.sh" 2>/dev/null && ok || bad "the extracted block is not syntactically valid bash"
grep -q '^RB_MODULES=' "$T/block.sh" \
  && ok || bad "the block must carry the literal RB_MODULES= line the helper greps"
# Literal, not computed: rb_all below evals this line out of the driver, so a
# command substitution here would be the driver running code inside every suite
# that reads it. The spelling is the contract, which is why it is pinned here.
grep -q '^RB_MODULES="gates plan execute spec review pr result"$' "$T/block.sh" \
  && ok || bad "RB_MODULES must be a literal list, not an expansion: $(grep '^RB_MODULES=' "$T/block.sh")"

# The driver's own RESULT(), lifted by its markers too, so the resume case below
# is checked against the function the pipeline really writes RESULT files with
# rather than against a hand-written mock of it. STAMP is the one stub: it reads
# the wall clock, and a suite that reads the clock picks its own red day.
{ echo 'STAMP() { echo TS; }'
  awk '/^# >>> result pr url ratchet/{f=1;next} /^# <<< result pr url ratchet/{exit} f' \
    "$DIR/bin/run-build.sh"
  cat "$T/block.sh"
} > "$T/drive.sh"
bash -n "$T/drive.sh" 2>/dev/null && ok || bad "the drive script (RESULT + the block) is not valid bash"
grep -q '^RESULT() {' "$T/drive.sh" \
  && ok || bad "the real RESULT() must be lifted into the drive script"

drive() { # drive  -> runs the block against $T/h, sets OUT and RC
  rm -rf "$T/h/logs" "$T/b"
  mkdir -p "$T/h/logs" "$T/b"
  OUT=$( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 \
             ALERTS="$T/h/logs/ALERTS.log" RESUME_BUILD="${RESUME:-}" \
         bash -uo pipefail "$T/drive.sh" 2>&1 )
  RC=$?
}

# ── (a) every module present: the block is a no-op ──────────────────────────
mkdir -p "$T/h/bin/lib/rb"
for M in $MODS; do
  [ -r "$DIR/bin/lib/rb/$M.sh" ] \
    && cp "$DIR/bin/lib/rb/$M.sh" "$T/h/bin/lib/rb/$M.sh" \
    || bad "bin/lib/rb/$M.sh is missing from the repo"
done
[ "$(ls "$T/h/bin/lib/rb" | wc -l)" = 7 ] && ok || bad "expected seven stage modules in the repo"

drive
[ "$RC" = 0 ] && ok || bad "a fully synced box must source the modules and carry on (rc $RC: $OUT)"
[ -z "$OUT" ] && ok || bad "sourcing the modules must print nothing (got: $OUT)"
[ -s "$T/h/logs/ALERTS.log" ] && bad "a fully synced box must raise no ALERTS line" || ok
[ -e "$T/b/RESULT" ] && bad "the block must write no RESULT when nothing is wrong" || ok

# The loop SOURCES the modules, it does not merely look for them: a module that
# prints on source must be heard. Without this the whole block could be seven
# [ -r ] tests and every other case here would still be green, which is a seam
# that never actually loads the stages it is being built to load.
echo 'echo sourced-spec' > "$T/h/bin/lib/rb/spec.sh"
drive
grep -q 'sourced-spec' <<<"$OUT" \
  && ok || bad "the block must source each module, not just test that it is readable (got: $OUT)"

# ...and it sources them in the order RB_MODULES names, which is what makes that
# line the single source of truth for module order rather than a comment about
# one. Every module announces itself; the transcript is the order.
for M in $MODS; do echo "echo $M" > "$T/h/bin/lib/rb/$M.sh"; done
drive
[ "$OUT" = "$(printf '%s\n' $MODS)" ] \
  && ok || bad "modules must be sourced in RB_MODULES order (got: $(tr '\n' ' ' <<<"$OUT"))"
for M in $MODS; do cp "$DIR/bin/lib/rb/$M.sh" "$T/h/bin/lib/rb/$M.sh"; done

# Sourcing the seven modules exits 0, prints nothing, and adds no symbol that is
# not a stage entry — in a bare env, because the loop runs on EVERY build.
#
# The count used to be pinned at zero, which was the same sentence while every
# module was still a stub. From BH-478.2 on, a module that has landed its body
# DOES define its `rb_<stage>` entry, so the count is no longer the assertion —
# the SHAPE is: exit 0, empty output, and every name `declare -F` reports is an
# rb_ entry. A stub satisfies that with an empty list, so this holds all the way
# through the split, and it catches strictly more than the count did: a helper
# hoisted to column 0, a stray top-level statement, a module that shadows `git`.
# The two halves are separate runs so an empty-output failure cannot be read as
# a definition failure or the other way round.
#
# --noprofile --norc because this box's /etc/bash.bashrc gets pulled in whenever
# stdin is a socket, and its noise would read here as output from a module.
SIDE=$( env -i PATH="$PATH" M="$DIR/bin/lib/rb" bash --noprofile --norc -uo pipefail -c '
          for m in gates plan execute spec review pr result; do . "$M/$m.sh"; done' 2>&1 )
SIDE_RC=$?
[ "$SIDE_RC" = 0 ] && ok || bad "sourcing the seven modules must exit 0 (got $SIDE_RC: $SIDE)"
[ -z "$SIDE" ] && ok || bad "sourcing the modules must print nothing (got: $SIDE)"
DEFS=$( env -i PATH="$PATH" M="$DIR/bin/lib/rb" bash --noprofile --norc -uo pipefail -c '
          for m in gates plan execute spec review pr result; do . "$M/$m.sh"; done
          declare -F' 2>&1 )
STRAY=$(grep -vE '^declare -f rb_[a-z_]+$' <<<"$DEFS" | grep -c '[^[:space:]]')
[ "$STRAY" = 0 ] \
  && ok || bad "sourcing the modules must define nothing but rb_ entries (got: $DEFS)"

# ── (b) one module missing, fresh run: fail closed, one ALERTS line, no RESULT ─
rm -f "$T/h/bin/lib/rb/review.sh"
drive
[ "$RC" = 2 ] && ok || bad "a half-synced box must exit 2 (got $RC: $OUT)"
[ -z "$OUT" ] && ok || bad "the stop writes to ALERTS, not to stdout (got: $OUT)"
[ -e "$T/b/RESULT" ] && bad "a fresh run's stop must write no RESULT — an ALERTS line is its only owner" || ok
N=$(grep -c . "$T/h/logs/ALERTS.log" 2>/dev/null)
[ "$N" = 1 ] && ok || bad "expected exactly one ALERTS line, got $N"
grep -q 'bin/lib/rb/review.sh' "$T/h/logs/ALERTS.log" \
  && ok || bad "the ALERTS line must name the module that is missing: $(cat "$T/h/logs/ALERTS.log")"
grep -q "$(hostname)" "$T/h/logs/ALERTS.log" \
  && ok || bad "the ALERTS line must name the box it is missing on"
grep -q 'widget-os/WD-9' "$T/h/logs/ALERTS.log" \
  && ok || bad "the ALERTS line must name the build it stopped"

# It stops at the FIRST missing module rather than reporting the rest: the box
# is half-synced, and seven lines about one rsync is a pager storm, not news.
# gates.sh is the first name in the list, so this also pins that the loop does
# not run on past a miss to check the others.
rm -f "$T/h/bin/lib/rb/gates.sh"
drive
[ "$(grep -c . "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "two missing modules must still raise one line, not one per module"
grep -q 'bin/lib/rb/gates.sh' "$T/h/logs/ALERTS.log" \
  && ok || bad "the line must name the FIRST module the loop missed"
cp "$DIR/bin/lib/rb/gates.sh" "$T/h/bin/lib/rb/gates.sh"

# ── (b2) the same miss on a RESUMED build: a BUILD_DEFERRED RESULT first ────
# A resume has already been handed its build dir, and the jobs watchdog's resume
# pass (bin/lib/resume-dead.sh) re-enters any dir with no RESULT in it. A silent exit there is not a stop, it
# is a loop that burns the attempt cap down to BUILD_DEAD. BUILD_DEFERRED is the
# word the resumer refunds, so that is the word this path writes.
RESUME="$T/b"; drive; RESUME=""
[ "$RC" = 2 ] && ok || bad "a resumed build on a half-synced box must still exit 2 (got $RC)"
[ "$(grep -c . "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "the resume path raises the same single ALERTS line"
if [ -s "$T/b/RESULT" ]; then
  ok
  read -r W REST < "$T/b/RESULT"
  [ "$W" = BUILD_DEFERRED ] \
    && ok || bad "the resume path's RESULT must open with BUILD_DEFERRED (got: $W $REST)"
  grep -q 'bin/lib/rb/review.sh' "$T/b/RESULT" \
    && ok || bad "the resume path's RESULT must name the missing module: $(cat "$T/b/RESULT")"
else
  bad "a resumed build must write a RESULT before it exits — the resumer re-enters a RESULT-less dir"
  bad "(no RESULT: cannot check the BUILD_DEFERRED word)"
  bad "(no RESULT: cannot check the module name)"
fi
cp "$DIR/bin/lib/rb/review.sh" "$T/h/bin/lib/rb/review.sh"

# ── (b3) present but unreadable: presence is not the test, readability is ───
# Skipped as root, which reads a chmod 000 file happily and would turn this into
# a case that asserts nothing.
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$T/h/bin/lib/rb/pr.sh"
  drive
  [ "$RC" = 2 ] && ok || bad "an unreadable module must stop the build the same way (got $RC: $OUT)"
  [ "$(grep -c . "$T/h/logs/ALERTS.log")" = 1 ] \
    && ok || bad "an unreadable module raises one ALERTS line"
  chmod 644 "$T/h/bin/lib/rb/pr.sh"
else
  echo "rb-modules-source-test: running as root, skipping the unreadable-module case"
fi

# ── (a, again) the tree is whole again: back to a silent no-op ──────────────
drive
[ "$RC" = 0 ] && ok || bad "a repaired tree must build again (rc $RC: $OUT)"

# ============================================================================
# 2. rb_all — the pipeline as one text, in its original order
# ============================================================================
# ── (c) the flatten of the REAL repo expands every call ─────────────────────
# Since the BH-572 cut the driver runs its stages as eleven bare calls, so the
# flatten is no longer the driver's own text: it is the driver with each call
# replaced by its body. The byte identity with the pre-cut driver is proved once,
# against the merge-base, in that PR; what a later edit can break is a call the
# flatten cannot expand (a module that lost its entry, a renamed function), and
# every reader suite would then read a pipeline with a hole in it. So: the driver
# carries eleven bare calls, and not one of them survives the flatten.
F=$(rb_all "$DIR" "$T/real.all.sh")
[ "$F" = "$T/real.all.sh" ] && ok || bad "rb_all must print the path it wrote (got: $F)"
RB_CALLS=$(grep -cE '^rb_[a-z_]+$' "$DIR/bin/run-build.sh")
[ "$RB_CALLS" = 11 ] \
  && ok || bad "the driver must run its stages as eleven bare rb_ calls (got $RB_CALLS)"
LEFT=$(grep -E '^rb_[a-z_]+$' "$F" | tr '\n' ' ')
[ -z "$LEFT" ] \
  && ok || bad "every driver call must be expanded by the flatten; left as bare calls: $LEFT"

# r1: a scratch repo that is a faithful copy of the real one with its bare call
# lines stripped — a driver that calls nothing flattens to itself.
mkdir -p "$T/r1/bin/lib/rb"
grep -vE '^rb_[a-z_]+$' "$DIR/bin/run-build.sh" > "$T/r1/bin/run-build.sh"
cp "$DIR"/bin/lib/rb/*.sh "$T/r1/bin/lib/rb/"
F=$(rb_all "$T/r1" "$T/r1.all.sh")
cmp -s "$F" "$T/r1/bin/run-build.sh" \
  && ok || bad "rb_all must be the identity on a driver with no bare rb_ call"

# ── (d) one bare call, one module defining it ───────────────────────────────
# The body lands where the call was and neither wrapper line survives.
mkdir -p "$T/r2/bin/lib/rb"
cat > "$T/r2/bin/run-build.sh" <<'EOF'
#!/bin/bash
RB_MODULES="gates"
before
rb_gates
after
EOF
cat > "$T/r2/bin/lib/rb/gates.sh" <<'EOF'
rb_gates() {
  echo one
  echo two
} # end rb_gates
EOF
cat > "$T/r2/expected" <<'EOF'
#!/bin/bash
RB_MODULES="gates"
before
  echo one
  echo two
after
EOF
F=$(rb_all "$T/r2" "$T/r2.all.sh")
cmp -s "$F" "$T/r2/expected" \
  && ok || bad "rb_all must inline the body in place and drop both wrapper lines: $(cat "$F")"
grep -q '^rb_gates$' "$F" && bad "the call line must not survive the flatten" || ok
grep -q 'end rb_gates' "$F" && bad "the closer must not survive the flatten" || ok

# r3: everything that is NOT a bare call copies through untouched — including
# the shapes a naive matcher would eat — and so does a bare call no module
# defines (the flatten never invents text).
mkdir -p "$T/r3/bin/lib/rb"
cat > "$T/r3/bin/run-build.sh" <<'EOF'
#!/bin/bash
RB_MODULES="gates"
rb_gates "$X"
  rb_gates
rb_gates # comment
# rb_gates
rb_gates=1
RB_GATES
rb_Gates
rb_nothing
EOF
cp "$T/r2/bin/lib/rb/gates.sh" "$T/r3/bin/lib/rb/gates.sh"
F=$(rb_all "$T/r3" "$T/r3.all.sh")
cmp -s "$F" "$T/r3/bin/run-build.sh" \
  && ok || bad "only a bare rb_<name> line is a call; everything else copies through: $(cat "$F")"

# r4: no RB_MODULES line at all (the tree before this change) — the helper must
# still copy the driver through rather than erroring on the empty list.
mkdir -p "$T/r4/bin"
printf '#!/bin/bash\necho hi\n' > "$T/r4/bin/run-build.sh"
F=$(rb_all "$T/r4" "$T/r4.all.sh")
cmp -s "$F" "$T/r4/bin/run-build.sh" \
  && ok || bad "a driver with no RB_MODULES line must still flatten to itself"

# ── (e) a module that opens a stage function and never closes it ────────────
# Copying to EOF would hand every reader suite a pipeline text nobody wrote, and
# the suites would then report their own findings about it. It says which module
# and which function, and leaves no half-written file behind to be mistaken for
# an answer.
mkdir -p "$T/r5/bin/lib/rb"
cat > "$T/r5/bin/run-build.sh" <<'EOF'
#!/bin/bash
RB_MODULES="plan"
before
rb_plan
after
EOF
cat > "$T/r5/bin/lib/rb/plan.sh" <<'EOF'
rb_plan() {
  echo one
EOF
ERRF="$T/r5.err"
F=$(rb_all "$T/r5" "$T/r5.all.sh" 2>"$ERRF"); RC5=$?
[ "$RC5" != 0 ] && ok || bad "an unclosed stage function must fail the flatten (rc $RC5)"
[ "$(grep -c . "$ERRF")" = 1 ] \
  && ok || bad "the failure is exactly one stderr line, got: $(cat "$ERRF")"
grep -q 'bin/lib/rb/plan.sh' "$ERRF" \
  && ok || bad "the stderr line must name the module: $(cat "$ERRF")"
grep -q 'rb_plan' "$ERRF" \
  && ok || bad "the stderr line must name the function: $(cat "$ERRF")"
[ -e "$T/r5.all.sh" ] && bad "a failed flatten must leave no out-file to be read as an answer" || ok
[ -z "$F" ] && ok || bad "a failed flatten must print no path (got: $F)"

# ============================================================================
# 3. The seam's own drift guards
# ============================================================================
# ── (f) every reader suite reads the flatten, not the driver ───────────────
# A suite that reads the raw driver as TEXT reads a pipeline with holes in it
# once the later parts of BH-478 start moving bodies out; it belongs on
# tests/lib/rb-all.sh and $RB_ALL instead. A suite that EXECUTES the driver
# needs the real runnable path, because the flatten is not runnable.
#
# WHY A MARKER AND NOT A LIST (BH-1177). This used to be one pinned list of
# three absolute paths, so every PR that added or retired a raw reader re-typed
# a line that belongs to no ticket, and two such PRs conflicted on it. Now each
# suite says so in its OWN header —
#
#   # reads-run-build: raw — <why the flatten will not do>
#
# — and the set is kept from growing by one file per entry under
# tests/rb-raw-readers-baseline/. Adding or retiring a reader touches that
# suite and that suite's entry: never a line another PR is also editing. The
# guard is the same one it always was, in three directions: a raw reader with
# no marker fails, a marker with no registry entry fails, and a marker on a
# suite that stopped reading the driver fails as stale.
RB_REG="$DIR/tests/rb-raw-readers-baseline"

# The declaration is read from the HEADER BLOCK only — shebang, blanks and
# comments before the first line of code — for the same reason the gh-identity
# marker is: a declaration you cannot see with `head` is not one. The reason is
# whatever follows the marker once the leading punctuation is dropped, so an em
# dash, a colon or nothing at all all parse, and an EMPTY reason does not.
rb_reader_why() { # rb_reader_why <file> -> prints the reason; rc 1 if none
  awk '
    /^#!/            { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ {
      if (match($0, /reads-run-build:[[:space:]]*raw/)) {
        why = substr($0, RSTART + RLENGTH)
        sub(/^[^A-Za-z0-9]*/, "", why)
        if (why != "") { print why; found = 1 }
        exit
      }
      next
    }
    { exit }
    END { exit (found ? 0 : 1) }
  ' "$1"
}

RB_RAW=$(grep -l '"\$DIR/bin/run-build\.sh"' "$DIR"/tests/*.sh 2>/dev/null \
         | while IFS= read -r F; do basename "$F"; done | sort | tr '\n' ' ')
[ -n "$RB_RAW" ] \
  && ok || bad "no suite reads bin/run-build.sh at all — THIS suite does, so the reader scan is not reaching tests/"
for B in $RB_RAW; do
  if ! rb_reader_why "$DIR/tests/$B" >/dev/null; then
    bad "tests/$B reads bin/run-build.sh as raw text and declares nothing. A suite that READS the pipeline sources tests/lib/rb-all.sh and reads \$RB_ALL, so its text is the pipeline in its original order at every state of the BH-478 split. If it must have the real driver (because it EXECUTES it), say so in its header: '# reads-run-build: raw — <why>', and add tests/rb-raw-readers-baseline/$B.txt."
  elif [ ! -f "$RB_REG/$B.txt" ]; then
    bad "tests/$B declares '# reads-run-build: raw' with no registry entry — one more raw reader is a reviewed decision, so add tests/rb-raw-readers-baseline/$B.txt saying why the flatten will not do."
  fi
done

# The other two directions: a marker that outlived its reader, and an entry that
# outlived its suite. Either one leaves the guard counting a reader that is not
# there, which is how a list quietly stops being the line it is holding.
for F in "$DIR"/tests/*.sh; do
  B=$(basename "$F")
  rb_reader_why "$F" >/dev/null || continue
  case " $RB_RAW " in
    *" $B "*) continue ;;
    *) bad "tests/$B declares '# reads-run-build: raw' but no longer reads the driver — drop the marker and tests/rb-raw-readers-baseline/$B.txt" ;;
  esac
done
ok
RB_REG_N=0
for E in "$RB_REG"/*.txt; do
  [ -e "$E" ] || continue
  RB_REG_N=$((RB_REG_N+1))
  B=$(basename "$E" .txt)
  if [ ! -f "$DIR/tests/$B" ]; then
    bad "raw-reader registry entry $B names no suite in tests/ — delete tests/rb-raw-readers-baseline/$B.txt"
    continue
  fi
  case " $RB_RAW " in
    *" $B "*) ;;
    *) bad "raw-reader registry entry $B names a suite that no longer reads the driver raw — delete tests/rb-raw-readers-baseline/$B.txt" ;;
  esac
  grep -qvE '^[[:space:]]*(#.*)?$' "$E" \
    || bad "raw-reader registry entry $B carries no note — say why the flatten will not do for that suite, or the entry is a pinned count in disguise"
done
[ "$RB_REG_N" -gt 0 ] \
  && ok || bad "the raw-reader registry is empty — THIS suite is a raw reader, so an empty registry means the guard is off rather than clean"

# ── (g) the counts other suites take across the whole pipeline text ─────────
# tests/intent-gate-test.sh counts the gate's path and tests/pool-cap-refusal-test.sh
# counts `gh pr create` in command position. A comment in the new block that
# happened to quote either string would move those counts and turn a sibling
# suite red for a reason nobody would find. They are pinned here, next to the
# block that could break them.
# Taken on the flatten: since the BH-572 cut the gate and the PR open live in the
# stage modules, and the pipeline they run in is the flatten.
[ "$(grep -c '"\$HARNESS/bin/intent-gate.sh"' "$T/real.all.sh")" = 1 ] \
  && ok || bad "the pipeline must still name the intent gate exactly once"
GHC=$(grep -cE '(^|[;&|(]|\$\()[[:space:]]*gh pr create' "$T/real.all.sh")
[ "$GHC" -le 1 ] \
  && ok || bad "the pipeline must not gain a second gh pr create in command position (got $GHC)"

echo "rb-modules-source-test: $PASS pass, $FAIL fail ($RB_REG_N raw readers registered)"
[ "$FAIL" -eq 0 ]
