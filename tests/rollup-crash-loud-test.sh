#!/bin/bash
# tests/rollup-crash-loud-test.sh — a crashed rollup must not push a stale
# snapshot and must not log success.
#
# THE FAILURE SHAPE (production, 2026-08-24). cost-rollup.sh is `set -uo
# pipefail` but NOT `-e`. When its python block died, the script carried on:
# summary.json was never rewritten, the STALE file was pushed to the watchdog
# KV, and the run logged "161 PR rows, summary written". The dashboard served
# last hour's numbers, and the only evidence was generated_at being an hour
# behind — which nobody diffs.
#
# That is this codebase's recurring species (a path that cannot succeed,
# reporting success) sitting on the script's own success line, which is the
# worst possible place for it: the log that would tell you is the log that
# lies. The tz crash is one cause; this test is about ALL of them, including
# the next one nobody has thought of.
# Run from anywhere: tests/rollup-crash-loud-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/cost-rollup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/logs" "$T/flags" "$T/state/cost"
mkdir -p "$T/bin"; cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"

# --- 1. the rc is captured at all -------------------------------------------
# Without this the script cannot know the block died. `set -uo pipefail` does
# not fail the script on a non-final command's failure, which is exactly why
# the crash was survivable and therefore invisible.
grep -q 'PYRC=\$?' "$SRC" \
  && ok || bad "the python block's exit code is never captured — a crash cannot be detected"

# --- 2. the guard fires BEFORE the push -------------------------------------
# Ordering is the whole fix. A check that runs after the push has already sent
# the stale snapshot to the dashboard.
GUARD=$(grep -n 'if \[ "\$PYRC" -ne 0 \]' "$SRC" | head -1 | cut -d: -f1)
PUSH=$(grep -n 'api/cost-snapshot' "$SRC" | head -1 | cut -d: -f1)
[ -n "$GUARD" ] && [ -n "$PUSH" ] \
  && ok || bad "could not locate the crash guard and the push (guard=$GUARD push=$PUSH)"
[ -n "$GUARD" ] && [ -n "$PUSH" ] && [ "$GUARD" -lt "$PUSH" ] \
  && ok || bad "the crash guard runs AFTER the push — the stale snapshot is already gone (guard=$GUARD push=$PUSH)"

# And before the success line, which is the one that lied.
SUCCESS=$(grep -n 'PR rows, summary written' "$SRC" | head -1 | cut -d: -f1)
[ -n "$SUCCESS" ] && [ "$GUARD" -lt "$SUCCESS" ] \
  && ok || bad "the crash guard runs after the success log line (guard=$GUARD success=$SUCCESS)"

# --- 3. the guard's BEHAVIOUR, run for real ---------------------------------
# Extracted from the script and executed with PYRC=1 against a fixture tree, so
# this exercises the shipped block rather than a description of it.
python3 - "$SRC" "$T/guard.sh" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
start = src.index('if [ "$PYRC" -ne 0 ]; then')
# through the CLOSING fi, not just to the first inner statement: a fragment cut
# mid-if is a syntax error, which fails every downstream assertion for a reason
# that has nothing to do with the code under test.
end = src.index("\nfi\n", start) + len("\nfi\n")
open(sys.argv[2], "w").write(src[start:end])
EXTRACT
[ -s "$T/guard.sh" ] && ok || bad "could not extract the crash guard from cost-rollup.sh"

printf 'Traceback (most recent call last):\nTypeError: cannot compare offset-naive and offset-aware datetimes\n' > "$T/pyerr"
OUT=$(bash -c '
  set -uo pipefail
  H="'"$T"'"; PYRC=1; PYERR="'"$T"'/pyerr"
  STAMP() { echo "2026-08-24 21:00:00Z"; }
  . "'"$T"'/guard.sh"
' 2>/dev/null; echo "rc=$?")

grep -q 'rc=1' <<<"$OUT" \
  && ok || bad "a crashed rollup must exit non-zero, so the caller knows (got: $OUT)"

# The operator-facing evidence: an ALERTS line naming the stale snapshot.
grep -q 'STALE cost snapshot' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "no ALERTS line — a crashed rollup is silent to the operator"
# ...carrying the actual exception, not just "it failed". Swallowing the error
# text is how a crash becomes a blank line in a log.
grep -q 'TypeError' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "the ALERTS line drops the exception text — the reason is the useful part"
grep -q 'rollup FAILED' "$T/logs/agent-rules.log" 2>/dev/null \
  && ok || bad "no failure line in agent-rules.log"

# Once per day, not once per hourly tick — an alert that repeats 24x/day
# becomes noise and gets filtered, which is how the next one goes unread.
ALERTS_BEFORE=$(wc -l < "$T/logs/ALERTS.log")
H="$T" bash -c '
  set -uo pipefail
  H="'"$T"'"; PYRC=1; PYERR="'"$T"'/pyerr"
  STAMP() { echo "2026-08-24 22:00:00Z"; }
  . "'"$T"'/guard.sh"' >/dev/null 2>&1
ALERTS_AFTER=$(wc -l < "$T/logs/ALERTS.log")
[ "$ALERTS_BEFORE" = "$ALERTS_AFTER" ] \
  && ok || bad "the crash alert repeats every run ($ALERTS_BEFORE -> $ALERTS_AFTER) — hourly noise"

# --- 4. stderr is captured, not discarded -----------------------------------
# cron sends the script's own stderr to /dev/null, so if the block's stderr is
# not captured the exception text is gone and the ALERTS line has nothing
# useful in it.
grep -q '2>"\$PYERR"' <(grep -vE '^[[:space:]]*#' "$SRC") \
  && ok || bad "the python block's stderr is not captured — the crash reason would be lost"
# NOT via process substitution: `2> >(tee ...)` runs async and can be read
# before the writer flushes, so the error tail comes back empty exactly when
# it is needed.
grep -q '2> >(' <(grep -vE '^[[:space:]]*#' "$SRC") \
  && bad "stderr goes through a process substitution — reading it races the writer" || ok

# --- 5. SUITE HYGIENE: no `grep file | grep -q` in any test ----------------
# This is here because THIS test was 40% flaky on correct code. `grep -q` exits
# at the first match, SIGPIPEs the upstream grep, and pipefail propagates the
# kill as a failure — so the assertion proving crashes are loud went randomly
# red. That is worse than a plain flake: a random red on a safety test is an
# invitation for the next person under deadline to weaken the assertion rather
# than debug it, and the assertion in question is the one guaranteeing a
# crashed rollup cannot push a stale snapshot quietly.
#
# Scope, deliberately: file-reading greps only. `some_function | grep -q` on a
# few lines of output shares the shape but the producer almost always finishes
# before grep exits, so those are noted as lower-risk debt rather than swept
# here. A 600-line file is big enough to lose the race regularly.
OFFENDERS=$(grep -ln 'grep [^|]*"\$[A-Z_]*" *| *grep -q' "$DIR"/tests/*.sh 2>/dev/null | tr '\n' ' ')
[ -z "$OFFENDERS" ] \
  && ok || bad "these tests pipe a file-grep into grep -q and will flake under pipefail: $OFFENDERS"

echo "rollup-crash-loud-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
