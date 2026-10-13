#!/bin/bash
# tests/stop-owners-test.sh — SDLC item 6: every place the pipeline stops names
# who closes it.
#
# The hole this closes: the 232 abandoned ledger rows swept on 2026-08-24 were
# builds that stopped in a stage without writing a terminal. docs/RUN-BUILD-
# GRAPH.md recorded the remaining cases as findings rather than fixing them —
# four exits that vanished with no RESULT (F1-F4), five terminals no sweep SOP
# had a rule for (F5), and a 45-minute overlap timeout that proceeded into the
# concurrent edit the wait exists to prevent, saying so only in a per-build log.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q BUILD_DEFERRED bin/run-build.sh` passes on
# a deferral wired to the wrong default, on one that never names what it is
# waiting for, and on one that writes its RESULT but never records the timeout it
# decided to ignore. So the shipped lines are extracted VERBATIM by their markers
# and executed with the model call, the ledger, the clock and the sibling build
# stubbed — a regression in the real lines fails here, not in a paraphrase.
#
# No network, no model call, no secrets: a temp HARNESS root, a fake
# conflict-check, and a sleep that does not sleep.
# Run from anywhere: tests/stop-owners-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/state"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

SCRIPT="$RB_ALL"
[ -s "$SCRIPT" ] && ok || bad "bin/run-build.sh is missing"

# ============================================================================
# 1. the overlap wait — the timeout that used to proceed silently
# ============================================================================
awk '/^# >>> overlap wait/{f=1;next} /^# <<< overlap wait/{exit} f' "$SCRIPT" > "$T/overlap.sh"
[ -s "$T/overlap.sh" ] && ok || bad "could not extract the overlap-wait block — markers missing?"

# The sibling build is a stub: CONFLICTS=<n> makes conflict-check.sh report an
# overlap for its first n calls and then go quiet, which is what a sibling
# finishing looks like. The call count is the file's line count.
cat > "$T/h/bin/conflict-check.sh" <<'STUB'
#!/bin/bash
echo "call" >> "$CC_CALLS"
N=$(grep -c . "$CC_CALLS")
if [ "$N" -le "${CONFLICTS:-0}" ]; then
  echo "CONFLICT with widget-os-WD-8-202609061200: src/app/page.tsx ~ src/app/page.tsx"
  exit 1
fi
exit 0
STUB
chmod +x "$T/h/bin/conflict-check.sh"

drive() { # drive [env...] — runs the shipped block, echoes CONTINUED if it fell through
  rm -rf "$T/b"; mkdir -p "$T/b"
  : > "$T/calls"; : > "$T/sink"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 \
        ALERTS="$T/h/logs/ALERTS.log" CC_CALLS="$T/calls" SINK="$T/sink" \
        JOB_ID=job-1 OVERLAP_WAIT_SECS=180 "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; echo "$*" > "$BUILD/RESULT"; }
             sleep() { :; }
             job_artifact_put() { printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$SINK"; }
             . "$0"; echo "CONTINUED"' "$T/overlap.sh" 2>&1 )
}
defer_field() { sed -n "s/^$1:[[:space:]]*//p" "$T/b/overlap-defer.txt" 2>/dev/null; }

# 1a. no sibling claims a planned file: the block costs nothing and records
#     nothing. A gate that files paperwork on the happy path teaches everyone to
#     ignore its paperwork.
OUT=$(drive CONFLICTS=0)
grep -q CONTINUED <<<"$OUT" && ok || bad "a disjoint build must proceed (got: $OUT)"
[ ! -f "$T/b/overlap-defer.txt" ] && ok || bad "no overlap, no record: $(cat "$T/b/overlap-defer.txt")"
[ ! -s "$T/sink" ] && ok || bad "no overlap must mean no ledger row: $(cat "$T/sink")"

# 1b. the sibling finishes inside the cap: the wait did its job and the build
#     goes on. This is the case the whole mechanism exists for.
OUT=$(drive CONFLICTS=2)
grep -q CONTINUED <<<"$OUT" && ok || bad "a cleared overlap must proceed (got: $OUT)"
[ ! -f "$T/b/overlap-defer.txt" ] && ok || bad "an overlap that cleared is not a timeout"
grep -q 'serialized on file overlap' "$T/b/pipeline.log" \
  && ok || bad "the wait must log that it serialized: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# 1c. THE DEFAULT: the cap fires and the build STOPS, naming what it is waiting
#     for. A deferral with no wake condition is the silence this item exists to
#     end (LESSONS, the scaling week: every skip path enumerates its wake
#     reasons). This is the runtime behaviour SDLC item 6 was written to change,
#     so it is the unset-env case, not something a box has to opt into.
OUT=$(drive CONFLICTS=99)
grep -q CONTINUED <<<"$OUT" && bad "the default timeout must NOT reach EXECUTE (got: $OUT)" || ok
grep -q 'RESULT=BUILD_DEFERRED' <<<"$OUT" && ok || bad "the terminal must be BUILD_DEFERRED (got: $OUT)"
grep -q 'file overlap' <<<"$OUT" && ok || bad "the RESULT must say what it stopped on (got: $OUT)"
grep -q 'wakes when' <<<"$OUT" && ok || bad "the RESULT must name the wake condition (got: $OUT)"
grep -q 'next triage tick' <<<"$OUT" && ok || bad "the wake condition must name who re-offers the ticket (got: $OUT)"
[ "$(defer_field VERDICT)" = deferred ] && ok || bad "the file fallback must read deferred (got: $(defer_field VERDICT))"
grep -q 'WD-8' <<<"$(defer_field OVERLAP_DEFER)" && ok || bad "the record must name the build it collided with: $(cat "$T/b/overlap-defer.txt")"
[ "$(cut -f1 "$T/sink" | head -1)" = overlap_defer ] && ok || bad "the ledger row must be kind overlap_defer (got: $(cat "$T/sink"))"
[ "$(cut -f2 "$T/sink" | head -1)" = deferred ] && ok || bad "the ledger row's ref must be the verdict (got: $(cat "$T/sink"))"
[ "$(cut -f3 "$T/sink" | head -1 | jq -r '.enforced')" = true ] \
  && ok || bad "the row must say the deferral was taken: $(cut -f3 "$T/sink" | head -1)"
[ "$(cut -f3 "$T/sink" | head -1 | jq -r '.waited_s')" = 180 ] \
  && ok || bad "the row must carry how long it waited: $(cut -f3 "$T/sink" | head -1)"

# 1d. THE KILL SWITCH: =0 restores the old behaviour exactly — the build
#     proceeds into the collision — but the timeout is now a recorded fact in
#     two places instead of one log line, so the cost of disarming is visible.
OUT=$(drive CONFLICTS=99 OVERLAP_DEFER_ENFORCE=0)
grep -q CONTINUED <<<"$OUT" && ok || bad "OVERLAP_DEFER_ENFORCE=0 must still proceed (got: $OUT)"
grep -q 'RESULT=' <<<"$OUT" && bad "the kill switch must not write a terminal (got: $OUT)" || ok
[ "$(defer_field VERDICT)" = proceeded ] && ok || bad "the timeout must record itself as proceeded (got: $(defer_field VERDICT))"
[ "$(cut -f2 "$T/sink" | head -1)" = proceeded ] && ok || bad "the ledger row must read proceeded (got: $(cat "$T/sink"))"
[ "$(cut -f3 "$T/sink" | head -1 | jq -r '.enforced')" = false ] \
  && ok || bad "the row must say the deferral was NOT taken: $(cut -f3 "$T/sink" | head -1)"
grep -q 'OVERLAP_DEFER_ENFORCE=0, proceeding' "$T/b/pipeline.log" \
  && ok || bad "the log must name the switch that let it proceed: $(cat "$T/b/pipeline.log")"

# 1e. an unreadable switch value falls back to the SHIPPED default and says so
#     out loud. A typo in env/global.env must never silently disarm a stop —
#     that is how a gate becomes decoration nobody knows is off.
: > "$T/h/logs/ALERTS.log"
OUT=$(drive CONFLICTS=99 OVERLAP_DEFER_ENFORCE=maybe)
grep -q 'RESULT=BUILD_DEFERRED' <<<"$OUT" && ok || bad "a garbage switch value must fall back to deferring (got: $OUT)"
grep -q 'not a recognized on/off value' "$T/h/logs/ALERTS.log" \
  && ok || bad "the fallback must raise an ALERTS line: $(cat "$T/h/logs/ALERTS.log")"

# 1f. the cap is a cap: OVERLAP_WAIT_SECS bounds the waiting, so the block cannot
#     hold a build slot forever on a sibling that never finishes.
OUT=$(drive CONFLICTS=99 OVERLAP_WAIT_SECS=120)
[ "$(grep -c . "$T/calls")" -le 4 ] \
  && ok || bad "OVERLAP_WAIT_SECS=120 must cap the polling, got $(grep -c . "$T/calls") checks"
[ "$(cut -f3 "$T/sink" | head -1 | jq -r '.waited_s')" = 120 ] \
  && ok || bad "the recorded wait must honour the cap: $(cut -f3 "$T/sink" | head -1)"

# 1g. FAIL-OPEN like the rest of the ledger writes: no job row (worker
#     unreachable, or a box that predates the claim) still writes the file and
#     still takes the stop.
OUT=$(drive CONFLICTS=99 OVERLAP_DEFER_ENFORCE=1 JOB_ID=)
grep -q 'RESULT=BUILD_DEFERRED' <<<"$OUT" && ok || bad "no JOB_ID must not change the decision (got: $OUT)"
[ "$(defer_field VERDICT)" = deferred ] && ok || bad "the file fallback must survive a ledger-less box"
[ ! -s "$T/sink" ] && ok || bad "with no JOB_ID there is no row to write: $(cat "$T/sink")"

# 1h. ...and a non-numeric cap is still a cap. `[ 0 -ge abc ]` is an error, not
#     a comparison, so an unvalidated OVERLAP_WAIT_SECS typo would loop forever
#     holding the build, with no record and no RESULT — the same silent stop this
#     item is closing.
#
#     THE FALLBACK IS NOW 0, NOT 2700 (2026-09-13, "we never lock and serialize"):
#     a build may not queue behind another build, so the shipped default waits not
#     at all and defers on the first overlap. This assertion moved with the
#     default deliberately — it pins the typo path to the SHIPPED value, and the
#     property it guards is unchanged and in fact stronger: one check, bounded,
#     recorded, and a terminal.
: > "$T/h/logs/ALERTS.log"
OUT=$(drive CONFLICTS=99 OVERLAP_WAIT_SECS=abc)
grep -q 'RESULT=BUILD_DEFERRED' <<<"$OUT" && ok || bad "a garbage cap must still reach the timeout (got: $OUT)"
[ "$(grep -c . "$T/calls")" = 1 ] \
  && ok || bad "a garbage OVERLAP_WAIT_SECS must fall back to the 0 cap (one check, no wait), got $(grep -c . "$T/calls") checks"
[ "$(cut -f3 "$T/sink" | head -1 | jq -r '.waited_s')" = 0 ] \
  && ok || bad "the recorded wait must be the fallback cap: $(cut -f3 "$T/sink" | head -1)"
grep -q "OVERLAP_WAIT_SECS='abc' is not a number" "$T/h/logs/ALERTS.log" \
  && ok || bad "the cap fallback must raise an ALERTS line: $(cat "$T/h/logs/ALERTS.log")"

# 1i. THE SHIPPED DEFAULT ITSELF: with nothing set, an overlap defers on the
#     FIRST check. This is the assertion that would go red if someone reintroduced
#     a wait as the default — 1c drives the deferral with an explicit cap, so it
#     cannot see that.
OUT=$(drive CONFLICTS=99 OVERLAP_WAIT_SECS=)
grep -q 'RESULT=BUILD_DEFERRED' <<<"$OUT" && ok || bad "the unset default must defer (got: $OUT)"
[ "$(grep -c . "$T/calls")" = 1 ] \
  && ok || bad "the unset default must not wait at all — one conflict check, got $(grep -c . "$T/calls")"

# ============================================================================
# 2. F1-F4 — the four exits that used to vanish without a terminal
# ============================================================================
# Each is executed as shipped: the failure branch is lifted off its own line and
# run with RESULT/ALERTS stubbed, so "it writes a terminal" is observed rather
# than asserted about the source text.
branch() { # branch <fixed-string-that-identifies-the-line>
  local line body
  line=$(grep -a -m1 -F "$1" "$SCRIPT") || return 9
  [ -n "$line" ] || return 9
  body="${line#*|| }"
  ( env BUILD="$T/b" PROJECT=widget-os KEY=WD-9 BRANCH=ticket/wd-9 \
        REPO="$T/nope" ALERTS="$T/h/logs/ALERTS.log" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; }
             eval "$1"' _ "$body" 2>&1 )
}
rm -rf "$T/b"; mkdir -p "$T/b"

# F2: the project checkout is missing on this box. The build dir exists and the
# ticket is claimed, so leaving quietly is the leak shape exactly.
: > "$T/h/logs/ALERTS.log"
OUT=$(branch '[ -d "$REPO" ] ||')
grep -q 'RESULT=BUILD_REFUSED' <<<"$OUT" && ok || bad "F2 must write BUILD_REFUSED (got: $OUT)"
grep -q "$T/nope" <<<"$OUT" && ok || bad "F2's terminal must name the checkout it wanted (got: $OUT)"
grep -q 'repo missing' "$T/h/logs/ALERTS.log" && ok || bad "F2 must keep its ALERTS line"
# ...and it REFUSES rather than defers: every tick would repeat it until a human
# loads the project onto the box.
grep -q 'BUILD_DEFERRED' <<<"$OUT" && bad "a missing checkout is not 'not now' (got: $OUT)" || ok

# F3 / F4: a branch that cannot be checked out. Transient — another worktree
# holds it, or the fetch failed — so these defer and something retries them:
# F4 the next triage tick, F3 the resume lane (it is only reachable on a resume).
for F in F3 F4; do
  LINE=$(grep -a -m1 "# $F\$" "$SCRIPT")
  [ -n "$LINE" ] && ok || bad "$F's line lost its marker comment"
  OUT=$( env BUILD="$T/b" PROJECT=widget-os KEY=WD-9 BRANCH=ticket/wd-9 \
             ALERTS="$T/h/logs/ALERTS.log" \
         bash -c 'set -uo pipefail
                  STAMP() { echo TS; }
                  RESULT() { echo "RESULT=$*"; }
                  eval "$1"' _ "${LINE#*|| }" 2>&1 )
  grep -q 'RESULT=BUILD_DEFERRED' <<<"$OUT" && ok || bad "$F must write BUILD_DEFERRED (got: $OUT)"
  grep -q 'ticket/wd-9' <<<"$OUT" && ok || bad "$F's terminal must name the branch (got: $OUT)"
  grep -q 'retried' <<<"$OUT" && ok || bad "$F must name its retrier (got: $OUT)"
done

# F1: the dir the resume was told to re-enter is gone, so there is no RESULT to
# write and no job row to close. ALERTS is the only owner available.
: > "$T/h/logs/ALERTS.log"
awk '/\[ -d "\$RESUME_BUILD" \]/{f=1} f{print} /exit 2; }/{if(f)exit}' "$SCRIPT" > "$T/f1.sh"
[ -s "$T/f1.sh" ] && ok || bad "could not extract F1's guard"
( env HARNESS="$T/h" RESUME_BUILD="$T/gone" PROJECT=widget-os KEY=WD-9 \
  bash "$T/f1.sh" >/dev/null 2>&1 )
RC=$?
[ "$RC" = 2 ] && ok || bad "F1 must still exit 2 (got $RC)"
grep -q 'resume abandoned' "$T/h/logs/ALERTS.log" \
  && ok || bad "F1 must raise an ALERTS line: $(cat "$T/h/logs/ALERTS.log")"
grep -q "$T/gone" "$T/h/logs/ALERTS.log" \
  && ok || bad "F1's ALERTS line must name the dir that vanished"

# ============================================================================
# 3. F5 — the five terminals the sweep SOPs had no rule for
# ============================================================================
# The graph test asserts COVERAGE (every terminal in every SOP). What is checked
# here is that the rule says the right thing: a security block that read as
# "post the what-shipped comment" would be worse than the silence it replaced.
SOPS=$(grep -al 'Results sweep FIRST' "$DIR"/prompts/*.md)
# SHARE MIRROR: 2, not 11 — see tests/run-build-graph-test.sh.
[ "$(grep -c . <<<"$SOPS")" -ge 2 ] \
  && ok || bad "expected at least 2 sweep SOPs, found $(grep -c . <<<"$SOPS")"
for P in $SOPS; do
  B=$(grep -a 'SDLC item 6' "$P" | head -1)
  N=$(basename "$P")
  [ -n "$B" ] || { bad "$N carries no item-6 stop-owner rule"; continue; }
  for TERM in SECURITY_BLOCKED REFUTE_BLOCKED BUILD_REFUSED PLAN_STALE QUEUED_FLY; do
    grep -q "$TERM" <<<"$B" || bad "$N: the stop-owner rule never mentions $TERM"
  done
  grep -q 'ALERTS.log' <<<"$B" || bad "$N: the stop-owner rule raises no ALERTS line"
  grep -q 'held for a human read' <<<"$B" || bad "$N: a blocked lens must be held for a human"
  grep -q 'do NOT relaunch' <<<"$B" || bad "$N: the rule must forbid the relaunch reflex"
  grep -q 'COMMENTED' <<<"$B" || bad "$N: a closed-out stop must be marked COMMENTED or the sweep re-reads it forever"
done
ok

echo "stop-owners-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
