#!/bin/bash
# tests/free-slots-test.sh — how many builds can this box start right now.
#
# TWO DEFECTS, ONE ANSWER (project-5, 2026-09-11). The launch gate asks
# count-builds.sh how much work is in flight and compares it to
# flags/build-slots. Both halves of that were wrong:
#
#   1. It counted PROCESSES. run-build.sh forks a subshell that keeps the same
#      argv, so ONE running build shows as TWO — a box with build-slots=2 read
#      "2/2" with a single TK-267 build and refused to launch TK-268/269/270.
#      It was unblocked by hand with build-slots=10, which is not a fix: it is a
#      box lying about its capacity in the other direction.
#   2. It is a LOCAL slot count, and project-5 is Fly-routed. A launch for a
#      project with flags/builder-fly-<project> is enqueued to the pool and
#      returns immediately — bin/run-build.sh exits with QUEUED_FLY long before
#      it reaches the slot flock — so the local slot gate has nothing to say
#      about it, and applying it starves a lane that could not be full.
#
# DRIVEN, not grepped, for the counting: `ps` is a stub that replays a fixture
# process table, so the assertions are about what the counter concludes from a
# process list that has really been shaped like the live one. The prompt half
# IS a grep, and says so — the claim there is that the launch rules and the
# script agree on a name, which is a text claim.
# Run from anywhere: tests/free-slots-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/env" "$T/fakebin"
cp "$DIR/bin/count-builds.sh" "$T/h/bin/" 2>/dev/null
cp "$DIR/bin/free-slots.sh"   "$T/h/bin/" 2>/dev/null
# free-slots.sh resolves the slot count through the shared lib, the same way
# bin/run-build.sh's gate does; a sandbox without it would measure the fallback.
cp "$DIR/bin/lib/build-caps.sh" "$T/h/bin/lib/" 2>/dev/null
chmod +x "$T/h/bin/"*.sh 2>/dev/null

# The process table under test. A stub rather than the real `ps` because the
# whole question is what the counter does with a SPECIFIC set of cmdlines —
# including ones that must NOT match — and those cannot be conjured on a
# developer's machine.
cat > "$T/fakebin/ps" <<'STUB'
#!/bin/bash
cat "${PS_FIXTURE:-/dev/null}"
STUB
chmod +x "$T/fakebin/ps"

RB="/root/harness/bin/run-build.sh"
count() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" PS_FIXTURE="$T/ps.txt"
            bash "$T/h/bin/count-builds.sh" "$@" 2>/dev/null ); }
free()  { ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" PS_FIXTURE="$T/ps.txt"
            bash "$T/h/bin/free-slots.sh" "$@" 2>/dev/null ); }

# ══ 1. ONE BUILD IS ONE BUILD, HOWEVER MANY PROCESSES IT HAS ════════════════
cat > "$T/ps.txt" <<EOF
/sbin/launchd
/bin/bash $RB project-5 267 TK-267
/bin/bash $RB project-5 267 TK-267
EOF
[ "$(count)" = 1 ] \
  && ok || bad "one build's two processes must count as ONE build, got $(count) — this is the project-5 stall: slots read 2/2 with a single build running"
[ "$(count project-5)" = 1 ] && ok || bad "...and the same with a project filter, got $(count project-5)"

# A third process for the same build (a grandchild) changes nothing either: the
# identity is the argv tuple, not how deep the process tree happens to go.
printf '/bin/bash %s project-5 267 TK-267\n' "$RB" >> "$T/ps.txt"
[ "$(count)" = 1 ] && ok || bad "a third process of one build must still be one build, got $(count)"

# ...and two REAL builds are two, or the fix has simply broken the gate open.
printf '/bin/bash %s project-5 268 TK-268\n' "$RB" >> "$T/ps.txt"
printf '/bin/bash %s project-5 268 TK-268\n' "$RB" >> "$T/ps.txt"
[ "$(count)" = 2 ] && ok || bad "two distinct builds must count as two, got $(count) — a counter that always says 1 is not a fix"
[ "$(count project-5)" = 2 ] && ok || bad "the project filter must see both, got $(count project-5)"

# Same ticket, different KEY, is different work — and vice versa.
cat > "$T/ps.txt" <<EOF
/bin/bash $RB project-3 139 TK-139
/bin/bash $RB project-3 139 TK-139-followup
EOF
[ "$(count)" = 2 ] && ok || bad "the identity is project+ticket+key, not project+ticket, got $(count)"

# ══ 2. THE 2026-07-26 SELF-MATCH MUST STAY DEAD ═════════════════════════════
# pgrep -f matched any agent session whose PROMPT quoted the script path, which
# reported phantom builds and starved every slot on project-3. The anchor that killed
# that is the whole reason this script exists; a rewrite that loses it trades
# one starvation bug for the older one.
cat > "$T/ps.txt" <<EOF
/bin/bash $RB project-1 240 TK-240
claude --model opus -p Read the SOP and run $RB project-1 241 TK-241 if a slot is free
/bin/bash -c while :; do $RB project-1 242 TK-242; done
codex exec --full-auto run $RB project-1 243 TK-243
EOF
[ "$(count)" = 1 ] \
  && ok || bad "only the real pipeline may count; an agent or poller QUOTING the path must not (got $(count)) — that is the project-3 2026-07-26 starvation"
[ "$(count project-1)" = 1 ] && ok || bad "the same under a project filter, got $(count project-1)"

# A build of ANOTHER project is invisible to a filtered count, and visible to
# the box-wide one — the box slot is shared, the wip limit is not.
cat > "$T/ps.txt" <<EOF
/bin/bash $RB project-3 139 TK-139
/bin/bash $RB project-3 139 TK-139
/bin/bash $RB project-1 240 TK-240
EOF
[ "$(count project-3)" = 1 ] && ok || bad "filtered count leaked another project, got $(count project-3)"
[ "$(count project-1)" = 1 ] && ok || bad "filtered count wrong for the second project, got $(count project-1)"
[ "$(count)" = 2 ] && ok || bad "the box-wide count must see both projects, got $(count)"

: > "$T/ps.txt"
[ "$(count)" = 0 ] && ok || bad "an empty process table must count 0, got '$(count)'"

# ══ 3. FREE SLOTS, WHICH IS THE NUMBER THE LAUNCH RULE ACTUALLY WANTS ═══════
# Every caller was doing this arithmetic by hand, in prose, in nine prompt
# files — which is why the two halves could disagree for so long without
# anything failing.
printf '2\n' > "$T/h/flags/build-slots"
cat > "$T/ps.txt" <<EOF
/bin/bash $RB project-5 267 TK-267
/bin/bash $RB project-5 267 TK-267
EOF
[ "$(free project-5 | awk '{print $1}')" = 1 ] \
  && ok || bad "2 slots with ONE build running must leave 1 free, got '$(free project-5)'"
: > "$T/ps.txt"
[ "$(free project-5 | awk '{print $1}')" = 2 ] && ok || bad "an idle box must offer every slot, got '$(free project-5)'"
[ "$(free | awk '{print $1}')" = 2 ] && ok || bad "the box-wide question must answer too, got '$(free)'"

# A BOX SLOT IS BOX-WIDE, which the old prose in nine prompt files got wrong:
# it said "build-slots minus count-builds.sh <project>", so another project's
# build was invisible and the number promised a slot run-build.sh would refuse.
# run-build.sh flocks one of N box-wide locks/build-slot-S.lock.
cat > "$T/ps.txt" <<EOF
/bin/bash $RB project-1 240 TK-240
/bin/bash $RB project-1 240 TK-240
EOF
[ "$(free project-5 | awk '{print $1}')" = 1 ] \
  && ok || bad "another project's build occupies a BOX slot and must count against this project's free slots, got '$(free project-5)'"

# Never negative: build-slots can be lowered under running work, and a negative
# free count read as a number is worse than useless to a launch rule.
cat > "$T/ps.txt" <<EOF
/bin/bash $RB project-5 267 TK-267
/bin/bash $RB project-5 268 TK-268
/bin/bash $RB project-5 269 TK-269
EOF
[ "$(free project-5 | awk '{print $1}')" = 0 ] && ok || bad "over-subscribed slots must floor at 0, got '$(free project-5)'"

# The wip limit is the OTHER gate run-build.sh applies, so the number reported
# here has to respect it or it still fails to predict a BUILD_DEFERRED.
printf '4\n' > "$T/h/flags/build-slots"
printf '1\n' > "$T/h/flags/wip-limit-project-5"
cat > "$T/ps.txt" <<EOF
/bin/bash $RB project-5 267 TK-267
/bin/bash $RB project-5 267 TK-267
EOF
[ "$(free project-5 | awk '{print $1}')" = 0 ] \
  && ok || bad "a reached wip-limit must report 0 free even with box slots to spare, got '$(free project-5)'"
free project-5 | grep -q 'wip' \
  && ok || bad "...and must say which cap bound it, or a human cannot tell it from a busy box: $(free project-5)"
printf '9\n' > "$T/h/flags/wip-limit-project-5"
[ "$(free project-5 | awk '{print $1}')" = 3 ] \
  && ok || bad "a generous wip-limit must not RAISE the count above the box slots, got '$(free project-5)'"
rm -f "$T/h/flags/wip-limit-project-5"

# NO CAP SET IS "UNLIMITED", NOT 1 (2026-09-13, "we never lock and serialize").
# run-build.sh takes no slot lock when BUILD_SLOTS resolves to 0, so a launch rule
# told "1" on an uncapped box would hold back work nothing would have refused.
# This assertion moved with that default on purpose.
rm -f "$T/h/flags/build-slots"
: > "$T/ps.txt"
[ "$(free project-5 | awk '{print $1}')" = unlimited ] \
  && ok || bad "no slot cap at all must read unlimited, got '$(free project-5)'"
free project-5 | grep -q 'BUILD_SLOTS=0' \
  && ok || bad "...and must name the reason, or it is indistinguishable from fly routing: $(free project-5)"
printf 'two\n' > "$T/h/flags/build-slots"
[ "$(free project-5 | awk '{print $1}')" = unlimited ] \
  && ok || bad "a junk build-slots must read as no cap, got '$(free project-5)'"

# BUILD_SLOTS is the source of truth and OUTRANKS the legacy flag.
printf '2\n' > "$T/h/flags/build-slots"
printf 'BUILD_SLOTS=5\n' > "$T/h/env/global.env"
[ "$(free project-5 | awk '{print $1}')" = 5 ] \
  && ok || bad "BUILD_SLOTS in env/global.env must outrank flags/build-slots, got '$(free project-5)'"
printf 'BUILD_SLOTS=0\n' > "$T/h/env/global.env"
[ "$(free project-5 | awk '{print $1}')" = unlimited ] \
  && ok || bad "BUILD_SLOTS=0 must read unlimited even with the legacy flag present, got '$(free project-5)'"
# ...and an uncapped box is still wip-capped per project.
printf '1\n' > "$T/h/flags/wip-limit-project-5"
cat > "$T/ps.txt" <<EOF
/bin/bash $RB project-5 267 TK-267
EOF
[ "$(free project-5 | awk '{print $1}')" = 0 ] \
  && ok || bad "a reached wip-limit must bind against an uncapped box, got '$(free project-5)'"
rm -f "$T/h/flags/wip-limit-project-5"
: > "$T/h/env/global.env"
: > "$T/ps.txt"
printf '2\n' > "$T/h/flags/build-slots"

# ══ 4. A FLY-ROUTED PROJECT IS NOT SLOT-GATED AT ALL ═══════════════════════
# bin/run-build.sh returns QUEUED_FLY for a flagged project before it ever
# reaches the slot flock, so a fly launch consumes NOTHING locally. Reporting a
# local number for it is not conservative, it is wrong: it stopped three ready
# project-5 builds from being handed to a pool that was idle.
touch "$T/h/flags/builder-fly-project-5"
cat > "$T/ps.txt" <<EOF
/bin/bash $RB project-5 267 TK-267
/bin/bash $RB project-5 267 TK-267
/bin/bash $RB project-5 268 TK-268
EOF
[ "$(free project-5 | awk '{print $1}')" = unlimited ] \
  && ok || bad "a Fly-routed project must not be slot-gated, got '$(free project-5)'"
free project-5 | grep -qi 'fly' \
  && ok || bad "the answer must SAY it is fly-routed — an unexplained 'unlimited' reads as a bug: $(free project-5)"

# The flag is per project. A box that routes ONE project to the pool still has
# a finite number of local slots for every other project on it. The table is
# cleared first: those fixture processes are project-5's, and a box slot is
# BOX-wide, so leaving them would make this assertion about the wrong thing.
: > "$T/ps.txt"
[ "$(free project-1 | awk '{print $1}')" = 2 ] \
  && ok || bad "another project's fly flag must not make THIS one unlimited, got '$(free project-1)'"
# ...and the box-wide question is always a local one: there is no such thing as
# an unlimited box.
[ "$(free | awk '{print $1}')" != unlimited ] \
  && ok || bad "the box-wide count must stay numeric — a box has the slots it has: $(free)"
rm -f "$T/h/flags/builder-fly-project-5"

# A fly-routed project's running local processes (the brief QUEUED_FLY shim) are
# still counted honestly by count-builds; only the GATE is lifted.
touch "$T/h/flags/builder-fly-project-5"
cat > "$T/ps.txt" <<EOF
/bin/bash $RB project-5 267 TK-267
/bin/bash $RB project-5 267 TK-267
/bin/bash $RB project-5 268 TK-268
EOF
[ "$(count project-5)" = 2 ] \
  && ok || bad "count-builds must stay a plain counter — the fly decision belongs to free-slots, got $(count project-5)"
rm -f "$T/h/flags/builder-fly-project-5"

# ══ 5. THE LAUNCH RULES AND THE SCRIPT AGREE ON A NAME ═════════════════════
# This half is a grep, deliberately: the claim is that nine prompt files and
# four scripts point a model at the same command. The bug they encode is not a
# crash — it is a lane quietly refusing to launch — so nothing else notices when
# one of them drifts.
for f in "$DIR"/prompts/*.md; do
  b=$(basename "$f")
  # remediator.md names it in a LIST of idempotent scripts, not as a slot gate.
  [ "$b" = remediator.md ] && continue
  grep -q 'count-builds' "$f" \
    && bad "prompts/$b still sends the model to count-builds.sh for slots — it reports processes, and it does not know about Fly routing" \
    || ok
done
for f in "$DIR"/prompts/*.md; do
  grep -qi 'slot is free\|per FREE slot\|free slot' "$f" || continue
  grep -q 'free-slots.sh' "$f" \
    && ok || bad "prompts/$(basename "$f") gates a launch on slots but never names free-slots.sh"
done
# The tick's two free-slots.sh sentences are the queue preamble and the shard
# prompt, and BH-479 moved both out of run-triage.sh into the stage files that
# now assemble them (bin/lib/rt/scope.sh, bin/lib/rt/shards.sh). Same tick, same
# sentence, named where it actually lives.
# lib/resume-dead.sh is where resume-dead-builds.sh's pass lives since BH-1031
# (state→DB slice 6 folded it into the jobs watchdog); the slot question it asks
# is the same one, in its new home.
for s in lib/rt/scope.sh lib/rt/shards.sh prompt-eval.sh alerts-medic.sh lib/resume-dead.sh; do
  grep -q 'free-slots' "$DIR/bin/$s" \
    && ok || bad "bin/$s still decides slots without free-slots.sh"
done
# run-build.sh keeps count-builds.sh: its wip gate is a COUNT, and it is reached
# only on the local path (a fly build has already returned QUEUED_FLY above it).
grep -q 'count-builds.sh' "$RB_ALL" \
  && ok || bad "run-build.sh's wip gate should still count builds directly"

echo "free-slots-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
