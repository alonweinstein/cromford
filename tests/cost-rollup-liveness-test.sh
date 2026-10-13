#!/bin/bash
# tests/cost-rollup-liveness-test.sh — the cost rollup's liveness contract,
# extracted VERBATIM by its markers from bin/cost-rollup.sh and
# bin/pipeline-health.sh and driven against a scratch tree.
#
# WHAT IT PINS (2026-09-15). bin/cost-rollup.sh is the only writer of
# state/cost/, every dollar figure on every screen reads what it wrote, and it
# had no lock, no deadline and no liveness signal. "The hourly refresh stopped"
# was discoverable only by stat-ing four files — which someone did that morning,
# read a LOCAL 10:50 mtime as 10:50Z, and reported a five-hour stall in a lane
# that had last run 28 minutes earlier. Three things close that:
#
#   stamp    a successful run writes the ledgers row cost-rollup/last-success
#            in explicit UTC (BH-4158: a row, no longer state/cost/last-success)
#   lock     a second run does not queue behind the first, it exits; and a
#            holder past 2x the cron interval is an ALERT naming the pid, not a
#            log line nobody reads
#   detector pipeline-health pages ONCE when the stamp ages out, falls back to
#            summary.json's mtime when there is no row yet, and RESOLVES
#            itself once when the rollup comes back
#
# Run from anywhere: tests/cost-rollup-liveness-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: wait_holder, not a fixed sleep
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/logs" "$T/state/cost" "$T/flags" "$T/locks" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v flock >/dev/null || { echo "jq/flock missing — skipping"; exit 0; }

awk '/^# >>> rollup timebox lock/{f=1;next} /^# <<< rollup timebox lock/{exit} f' "$DIR/bin/cost-rollup.sh" > "$T/lock.sh"
awk '/^# >>> rollup last success/{f=1;next} /^# <<< rollup last success/{exit} f' "$DIR/bin/cost-rollup.sh" > "$T/stamp.sh"
awk '/^# >>> cost rollup liveness/{f=1;next} /^# <<< cost rollup liveness/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/live.sh"
[ -s "$T/lock.sh" ] && [ -s "$T/stamp.sh" ] && [ -s "$T/live.sh" ] \
  && ok || bad "could not extract all three blocks — markers missing?"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/cap.sh"

# ============================================================================
# 1. the stamp: a successful run says WHEN, in UTC, unambiguously
# ============================================================================
( export T="$T"; bash -c 'set -uo pipefail; H="$T"; CD="$T/state/cost"; STAMP() { echo TS; }
  job_ledger_put() { printf "%s %s %s %s\n" "$@" > "$T/stamp-put.txt"; }; . "$0"' "$T/stamp.sh" )
read -r SK SKEY SST S < "$T/stamp-put.txt" 2>/dev/null
[ "$SK $SKEY $SST" = "cost-rollup last-success ok" ] && ok || bad "the stamp must be the cost-rollup/last-success row: $(cat "$T/stamp-put.txt" 2>/dev/null)"
[ ! -e "$T/state/cost/last-success" ] && ok || bad "the stamp must no longer be written to state/cost/last-success"
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$S" \
  && ok || bad "last-success must be an explicit-UTC ISO stamp, got: $S"
# and it must round-trip through date(1), because that is how the detector reads it
date -u -d "$S" +%s >/dev/null 2>&1 && ok || bad "last-success does not parse as a date: $S"

# ============================================================================
# 2. the lock: dedupe, never a queue
# ============================================================================
runlock() { # runlock -> "$T/lockout.txt" gets REACHED_END when the block let us through
  : > "$T/lockout.txt"
  ( export HARNESS="$T" T="$T" COST_ROLLUP_TIMEBOXED=1 "$@"
    bash -c '
      set -uo pipefail
      H="$T"; CD="$T/state/cost"
      STAMP() { sleep "${WALLCLOCK_STUB_SLEEP_S:-0}"; date -u "+%Y-%m-%d %H:%M:%SZ"; }
      . "$0"
      echo REACHED_END >> "$T/lockout.txt"' "$T/lock.sh" >/dev/null 2>"$T/lockerr.txt" )
}

# 2a. nothing holding it: the run proceeds and marks itself
rm -f "$T/locks/cost-rollup.running"
runlock
grep -q REACHED_END "$T/lockout.txt" && ok || bad "an unheld lock must let the run through: $(cat "$T/lockerr.txt")"

# 2b. held by someone else: exit, do not wait, and say who
flock -x "$T/locks/cost-rollup.lock" -c 'sleep 60' &  # determinism: ok the holder doubles as the 60s hang guard, killed below
HOLDER=$!; wait_holder "$HOLDER"
printf '%s %s\n' 4242 '2026-09-15T09:50:00Z' > "$T/locks/cost-rollup.running"
: > "$T/logs/agent-rules.log"; : > "$T/logs/ALERTS.log"
runlock
grep -q REACHED_END "$T/lockout.txt" \
  && bad "a held lock must stop the run, not let it interleave writes" || ok
# TEST-CHANGE BH-5292: was `ELAPSED -lt 5`. the operator changed the rule (2026-10-07):
# no wall-clock asserts. DEDUPE-NOT-QUEUE is proved by order instead: the run
# came back while the holder is STILL holding. A run that queued behind the
# lock could only return after the holder's 60s ended, so the holder would be
# gone (and REACHED_END written). A slowed STAMP still passes.
kill -0 "$HOLDER" 2>/dev/null && ok || bad "the lock is DEDUPE, never a queue — the run returned only after the holder let go"
grep -q 'cost-rollup: skipped — pid 4242 has held the lock since 2026-09-15T09:50:00Z' "$T/logs/agent-rules.log" \
  && ok || bad "the skip must name the holder and when it started: $(cat "$T/logs/agent-rules.log")"
[ ! -s "$T/logs/ALERTS.log" ] && ok \
  || bad "a fresh overlap is normal and must not page: $(cat "$T/logs/ALERTS.log")"

# 2c. held past 2x the cron interval: that holder is wedged, and every tick
#     since has been a no-op. One ALERTS line, naming the pid to kill.
touch -d '3 hours ago' "$T/locks/cost-rollup.running"
runlock
L=$(cat "$T/logs/ALERTS.log")
grep -q '\[cost-rollup\] a rollup run (pid 4242' <<<"$L" && grep -q 'held locks/cost-rollup.lock for 18[0-9]m' <<<"$L" \
  && ok || bad "a wedged holder must page with its pid and its age: $L"
grep -q 'state/cost/ is frozen' <<<"$L" \
  && ok || bad "the wedged-holder line must say what it costs: $L"
# 2d. and only once a day
: > "$T/logs/ALERTS.log"; runlock
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "the wedged-holder alert must fire once a day: $(cat "$T/logs/ALERTS.log")"

# 2d-bis. A box that CANNOT lock must still run. `exec 9>` on an unwritable
#     path kills a non-interactive shell, and `flock -n` on a box without
#     util-linux returns non-zero — which reads as "held" and would make this
#     lane exit 0 every hour forever. An overlapping rollup is a bad hour; a
#     rollup that never runs again is a dead cost lane.
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
NL="$T/nolock"; mkdir -p "$NL/logs" "$NL/state/cost" "$NL/flags"
: > "$NL/locks"          # a FILE where the lock directory has to go
: > "$T/lockout.txt"
( export HARNESS="$NL" T="$T" COST_ROLLUP_TIMEBOXED=1
  bash -c '
    set -uo pipefail
    H="'"$NL"'"; CD="'"$NL"'/state/cost"
    STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
    . "$0"
    echo REACHED_END >> "$T/lockout.txt"' "$T/lock.sh" >/dev/null 2>"$T/lockerr.txt" )
grep -q REACHED_END "$T/lockout.txt" \
  && ok || bad "a box that cannot take the lock must still run: $(cat "$T/lockerr.txt")"
grep -q 'running WITHOUT a lock' "$NL/logs/agent-rules.log" 2>/dev/null \
  && ok || bad "running unlocked must say so: $(cat "$NL/logs/agent-rules.log" 2>/dev/null)"

# 2e. the deadline: a run re-execs itself under `timeout` so a wedge cannot
#     outlive the hour even when nobody is watching.
cat > "$T/fakebin/timeout" <<'SH'
#!/bin/bash
printf '%s\n' "$*" > "$TIMEOUT_SINK"
exit 0
SH
chmod +x "$T/fakebin/timeout"
( export HARNESS="$T" T="$T" PATH="$T/fakebin:$PATH" TIMEOUT_SINK="$T/timeout.txt" COST_ROLLUP_TIMEOUT_S=900
  unset COST_ROLLUP_TIMEBOXED
  bash -c 'set -uo pipefail; H="$T"; CD="$T/state/cost"; STAMP() { echo TS; }; . "$0"' "$T/lock.sh" >/dev/null 2>&1 )
grep -qE '^-k 60 900 ' "$T/timeout.txt" 2>/dev/null \
  && ok || bad "the run must re-exec under its configured deadline: $(cat "$T/timeout.txt" 2>/dev/null)"

# ============================================================================
# 3. the detector: pages once when the stamp ages out, resolves once when back
# ============================================================================
echo '{}' > "$T/state/health-alerted.json"
drive() {
  : > "$T/alerts.txt"
  ( export HARNESS="$T" T="$T" "$@"
    bash -c '
      set -uo pipefail
      H="$T"; NOW=$(date +%s); DEDUP="$T/state/health-alerted.json"
      STAMP() { sleep "${WALLCLOCK_STUB_SLEEP_S:-0}"; date -u "+%Y-%m-%d %H:%M:%SZ"; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      job_ledger_row() { [ -f "$T/row" ] || return 2; jq -nc --arg d "$(cat "$T/row")" "{status:\"ok\",detail:\$d}"; }
      . "$T/cap.sh"; . "$0"' "$T/live.sh" >/dev/null 2>"$T/liveerr.txt" )
}
# The stamp is the ledgers row (BH-4158), stubbed from $T/row. summary.json is
# older than every row below, so the row is what each case turns on.
echo '{}' > "$T/state/cost/summary.json"; touch -d '6 hours ago' "$T/state/cost/summary.json"

# 3a. fresh: silence
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$T/row"
rm -f "$T/state/cost-rollup-stale"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "a fresh rollup must not page: $(cat "$T/alerts.txt")"

# 3b. an hour old — one cron interval — is still healthy
date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ' > "$T/row"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "one interval late is not stale: $(cat "$T/alerts.txt")"

# 3c. past 2x the interval: one page, naming the age and what is frozen
date -u -d '5 hours ago' '+%Y-%m-%dT%H:%M:%SZ' > "$T/row"
drive
L=$(head -1 "$T/alerts.txt")
[ "$(grep -c '|costrollupstale:hub|' "$T/alerts.txt")" = 1 ] && grep -q '^86400|' <<<"$L" \
  && ok || bad "a stale rollup must page once a day: $(cat "$T/alerts.txt")"
grep -q 'last succeeded 30[0-9]m ago (ledger cost-rollup/last-success), past 120m' <<<"$L" \
  && ok || bad "the stale line must quote the age, the source and the threshold: $L"
[ -f "$T/state/cost-rollup-stale" ] && ok || bad "the stale marker must be written so the resolve can fire once"

# 3d. it comes back: exactly one RESOLVED, and the TTL stamp is cleared so a
#     recurrence re-pages immediately instead of waiting out the dedupe window
jq -n '{"costrollupstale:hub": 1}' > "$T/state/health-alerted.json"
date -u '+%Y-%m-%dT%H:%M:%SZ' > "$T/row"
: > "$T/logs/ALERTS.log"; : > "$T/logs/pipeline-health.log"
drive
[ "$(grep -c 'RESOLVED costrollupstale:hub' "$T/logs/ALERTS.log")" = 1 ] \
  && grep -q 'RESOLVED costrollupstale:hub' "$T/logs/pipeline-health.log" \
  && ok || bad "a recovered rollup must resolve, once, in both logs: $(cat "$T/logs/ALERTS.log")"
[ "$(jq -r 'has("costrollupstale:hub")' "$T/state/health-alerted.json")" = false ] \
  && ok || bad "the resolve must clear the dedupe stamp"
[ ! -f "$T/state/cost-rollup-stale" ] && ok || bad "the stale marker must be cleared"
# 3e. and not again on the next tick
: > "$T/logs/ALERTS.log"; drive
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "the resolve must fire once, not every tick: $(cat "$T/logs/ALERTS.log")"

# 3f. no row yet falls back to summary.json's mtime — and says so, because
#     "the rollup is stale" and "there is no row to read yet" are different
#     facts and must not read the same.
rm -f "$T/row" "$T/state/cost/last-success" "$T/state/cost-rollup-stale"
touch -d '5 hours ago' "$T/state/cost/summary.json"
drive
grep -q 'summary.json mtime (no ledger row yet)' "$T/alerts.txt" \
  && ok || bad "the fallback must name itself: $(cat "$T/alerts.txt")"
touch "$T/state/cost/summary.json"; rm -f "$T/state/cost-rollup-stale"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "a fresh summary.json mtime is not stale: $(cat "$T/alerts.txt")"

# 3g. an unreadable stamp must not take the detector down — it falls back
echo 'not a date at all' > "$T/row"
touch -d '5 hours ago' "$T/state/cost/summary.json"; rm -f "$T/state/cost-rollup-stale"
drive
grep -q 'summary.json mtime' "$T/alerts.txt" \
  && ok || bad "an unparseable stamp must fall back, not crash: $(cat "$T/alerts.txt") err=$(cat "$T/liveerr.txt")"

# 3h. neither file: there is no rollup here to watch, and nothing is claimed,
#     even with a stale row in the ledger
date -u -d '5 hours ago' '+%Y-%m-%dT%H:%M:%SZ' > "$T/row"
rm -f "$T/state/cost/last-success" "$T/state/cost/summary.json" "$T/state/cost-rollup-stale"
drive
[ ! -s "$T/alerts.txt" ] && ok || bad "no rollup state at all must page nothing: $(cat "$T/alerts.txt")"

echo "cost-rollup-liveness-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
