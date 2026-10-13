#!/bin/bash
# tests/pipeline-health-skip-closed.bh-637-test.sh — a closed-issue refusal must
# not halt a project's pool (BH-637 §3a, the half that makes the skip shippable).
#
# WHAT THIS PINS AND WHY. bin/pipeline-health.sh check 3 halts every pool spawn
# for a project after two consecutive reaped BUILD_REFUSED results, and only a
# harness deploy clears the flag. Its own alert says what it is for: "REFUSED at
# the context gate" — a machine that boots, reads its context and refuses is a
# machine we paid ~10 minutes of performance-8x for nothing.
#
# A SKIP_CLOSED refusal is the opposite of that. It is the build system
# correctly declining to rebuild shipped work, and two shipped tickets in a row
# is a NORMAL day. Left counted, the first wave of stale `ai-build` labels after
# BH-637 ships would halt the project's pool — a worse outcome than the rebuild
# the skip prevents.
#
# The block is extracted VERBATIM from bin/pipeline-health.sh between its own
# markers and executed against a fixture log, with alert() stubbed, so what is
# asserted is the flag file and the alert text — not the source.
#
# TIME IS PINNED (NOW below): check 3 has a 3600s recency guard, so a suite that
# read the wall clock would be green until its fixture aged out.
#
# Run from anywhere: tests/pipeline-health-skip-closed.bh-637-test.sh (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PH="$DIR/bin/pipeline-health.sh"
[ -r "$PH" ] || { echo "FAIL: bin/pipeline-health.sh is missing"; exit 1; }

A=$(grep -c '^# >>> pool refusal halt' "$PH")
B=$(grep -c '^# <<< pool refusal halt' "$PH")
[ "$A" = 1 ] && [ "$B" = 1 ] \
  && ok || bad "bin/pipeline-health.sh must carry exactly one '# >>> pool refusal halt' … '# <<< pool refusal halt' block (open=$A close=$B)"
awk '/^# >>> pool refusal halt/{f=1;next} /^# <<< pool refusal halt/{exit} f' "$PH" > "$T/halt.sh"
[ -s "$T/halt.sh" ] && ok || bad "the extracted pool-refusal-halt block is empty — there is nothing to drive"
grep -q 'flags/pool-halt-' "$T/halt.sh" \
  && ok || bad "the extracted block is not the halt check (no flags/pool-halt- in it)"

mkdir -p "$T/h/logs" "$T/h/flags"

# NOW is pinned, and every fixture line is dated from it, so the 3600s recency
# guard means the same thing on every run and on every day.
NOW=1789000000
STAMP_AT() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%d %H:%M:%SZ'; }

# drive <reaped-line…> — write the fixture log newest last, run the real block.
drive() {
  local i=0 age
  : > "$T/h/logs/fly-pool.log"
  : > "$T/alerts.txt"
  rm -f "$T/h/flags/pool-halt-proj"
  for L in "$@"; do
    age=$(( 600 - i * 60 ))
    printf '%s [pool/proj] reaped %s\n' "$(STAMP_AT "$age")" "$L" >> "$T/h/logs/fly-pool.log"
    i=$((i+1))
  done
  ( export H="$T/h" PROJECTS=proj NOW="$NOW" ALERTS="$T/alerts.txt"
    bash -c 'alert(){ printf "%s\n" "$*" >> "$ALERTS"; }; . "$1"' _ "$T/halt.sh" )
}

# ════════════════════════════════════════════════════════════════════════════
# 1. TODAY'S BEHAVIOUR IS PINNED FIRST. Two real gate refusals still halt the
#    pool — this change must not quietly disarm the check it edits.
# ════════════════════════════════════════════════════════════════════════════
drive "pool-proj-TK-11-x BUILD_REFUSED context drift" "pool-proj-TK-12-x BUILD_REFUSED context drift"
[ -f "$T/h/flags/pool-halt-proj" ] && ok || bad "two context-gate refusals must still set flags/pool-halt-proj"
grep -q 'SPAWNS HALTED' "$T/alerts.txt" && ok || bad "two context-gate refusals must still alert (got: $(cat "$T/alerts.txt"))"

# ════════════════════════════════════════════════════════════════════════════
# 2. TWO CLOSED-ISSUE REFUSALS ARE A NORMAL DAY. No flag, no page.
# ════════════════════════════════════════════════════════════════════════════
drive "pool-proj-TK-2060-x BUILD_REFUSED SKIP_CLOSED #2060 — issue is CLOSED on example-org/proj" \
      "pool-proj-TK-2066-x BUILD_REFUSED SKIP_CLOSED #2066 — issue is CLOSED on example-org/proj"
[ ! -f "$T/h/flags/pool-halt-proj" ] && ok \
  || bad "two SKIP_CLOSED refusals must NOT halt the pool — a deploy is the only thing that clears that flag"
[ ! -s "$T/alerts.txt" ] && ok || bad "two SKIP_CLOSED refusals must not page (got: $(cat "$T/alerts.txt"))"

# ════════════════════════════════════════════════════════════════════════════
# 3. ONE OF EACH is not two in a row, in either order.
# ════════════════════════════════════════════════════════════════════════════
drive "pool-proj-TK-13-x BUILD_REFUSED context drift" \
      "pool-proj-TK-2066-x BUILD_REFUSED SKIP_CLOSED #2066 — issue is CLOSED on example-org/proj"
[ ! -f "$T/h/flags/pool-halt-proj" ] && ok || bad "one gate refusal plus one SKIP_CLOSED is not two in a row (drift then skip)"
drive "pool-proj-TK-2066-x BUILD_REFUSED SKIP_CLOSED #2066 — issue is CLOSED on example-org/proj" \
      "pool-proj-TK-13-x BUILD_REFUSED context drift"
[ ! -f "$T/h/flags/pool-halt-proj" ] && ok || bad "one SKIP_CLOSED plus one gate refusal is not two in a row (skip then drift)"

# ════════════════════════════════════════════════════════════════════════════
# 4. THE RECENCY GUARD SURVIVES THE EDIT. Two real refusals older than an hour
#    are history a deploy already answered, and must not halt anything.
# ════════════════════════════════════════════════════════════════════════════
: > "$T/h/logs/fly-pool.log"; : > "$T/alerts.txt"; rm -f "$T/h/flags/pool-halt-proj"
printf '%s [pool/proj] reaped pool-proj-TK-14-x BUILD_REFUSED context drift\n' "$(STAMP_AT 20000)" >> "$T/h/logs/fly-pool.log"
printf '%s [pool/proj] reaped pool-proj-TK-15-x BUILD_REFUSED context drift\n' "$(STAMP_AT 19000)" >> "$T/h/logs/fly-pool.log"
( export H="$T/h" PROJECTS=proj NOW="$NOW" ALERTS="$T/alerts.txt"
  bash -c 'alert(){ printf "%s\n" "$*" >> "$ALERTS"; }; . "$1"' _ "$T/halt.sh" )
[ ! -f "$T/h/flags/pool-halt-proj" ] && ok || bad "refusals older than the 3600s window must not halt the pool"

# ════════════════════════════════════════════════════════════════════════════
# 5. A CLEAN LOG halts nothing, and neither does a single refusal.
# ════════════════════════════════════════════════════════════════════════════
drive "pool-proj-TK-16-x DONE" "pool-proj-TK-17-x DONE"
[ ! -f "$T/h/flags/pool-halt-proj" ] && ok || bad "two clean reaps must not halt the pool"
drive "pool-proj-TK-18-x DONE" "pool-proj-TK-19-x BUILD_REFUSED context drift"
[ ! -f "$T/h/flags/pool-halt-proj" ] && ok || bad "one refusal is not two consecutive refusals"

# ════════════════════════════════════════════════════════════════════════════
# 6. TWO SKIP_ACTOR REFUSALS (BH-4490) are the gate ignoring an untrusted
#    trigger, not a pool refusing builds. No flag, no page.
# ════════════════════════════════════════════════════════════════════════════
drive "pool-proj-TK-20-x BUILD_REFUSED SKIP_ACTOR TK-20 — ignored bot actor=dependabot[bot] event=1" \
      "pool-proj-TK-21-x BUILD_REFUSED SKIP_ACTOR TK-21 — ignored not-listed actor=mallory event=2"
[ ! -f "$T/h/flags/pool-halt-proj" ] && ok || bad "two SKIP_ACTOR refusals must NOT halt the pool"
[ ! -s "$T/alerts.txt" ] && ok || bad "two SKIP_ACTOR refusals must not page (got: $(cat "$T/alerts.txt"))"

echo "pipeline-health-skip-closed.bh-637: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
