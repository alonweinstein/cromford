#!/bin/bash
# tests/lane-gate-test.sh — bin/lib/lane-gate.sh's GATE (BH-1132).
#
# WHY THE GATE EXISTS. 267 cron lines, ~40 inconsistent `flags/*` off-switches,
# and no way to stop one without ssh. alert-triage burned $793 in 12h (#1039).
# The gate is the one thing every lane calls before it spends anything, so the
# only interesting question is WHICH answers stop a lane and which cannot.
#
# What is proved here:
#   1. no flag, no row, no worker -> the lane RUNS (the whole fleet's default);
#   2. flags/lane-off-<id> stops it, and the tick exits 0 (a paused lane must
#      not page: cron mails on nonzero and pipeline-health counts nonzero);
#   3. flags/all-off stops every lane;
#   4. a D1 pause_flags row stops it with no file present;
#   5. a pause_flags row named all-off stops every lane;
#   6. project scope: flags/lane-off-<id>-<project> stops ONE project and
#      leaves its sibling running;
#   7. the 60s cache answers without a second worker call;
#   8. FAIL OPEN: an unreachable worker with nothing cached runs the lane, and
#      an unreachable worker with a PAUSED answer cached keeps it stopped;
#   9. one log line per lane per hour, however many ticks;
#  10. the gate leaves the caller's shell options alone — bin/preplan-tick.sh
#      runs with `set -u` and NO pipefail, and bin/jobs-client.sh (which the
#      gate sources to reach the D1 row) switches pipefail on at its top level;
#  11. RESUME. A row flipped back to 0 un-gates the lane on EVERY box, not only
#      the one the CLI ran on. This is the half that failed review: the gate
#      returned on `flags/<name>` BEFORE calling flag_sync, and flag_sync is
#      what CREATED that file from the active row — so `harness-ctl on` (or the
#      console) wrote active=0 and every other box stayed stopped for ever. A
#      stop that cannot be undone is not a switch.
#  12. a file with NO row still holds (a hand touch on the box, or an autohalt,
#      is not something the database may reconcile away);
#  18. an OUTAGE answer is cached for the same TTL as a successful one
#      (BH-1165 review): a worker that is down must not cost 78 lanes × every
#      box up to three 8-second curls per tick before they do their work.
#  19. the WRITE half of that outage (BH-1165 review round 2): the liveness
#      POST is attempted at most once per TTL while the worker is unreachable,
#      is not throttled at all while it answers, and never stops a lane.
#  13. the gate writes NO lanes row tick (the lanes table is keyed
#      (project, box) and is the triage lane's staleness row — a paused tick
#      posted by a gated sibling would silence the stale-lane pager).
# Run from anywhere: tests/lane-gate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1758300000          # frozen clock, injected as LANE_GATE_NOW
mkdir -p "$T/h/bin/lib" "$T/h/flags" "$T/h/state" "$T/h/logs" "$T/h/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
cp "$(rendered_registry)" "$T/h/catalog/lanes.json"

# A lane, reduced to the two lines every wired lane has: source the gate, gate,
# then do its work. "WORKED" on stdout is the only proof the body ran.
cat > "$T/h/bin/fake-lane.sh" <<'SH'
#!/bin/bash
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
# The worker stub stands in for bin/jobs-client.sh: flag_active is the real
# client's name and contract (rc 0 = the flag is ON).
[ -r "$HARNESS/bin/stub-jobs-client.sh" ] && . "$HARNESS/bin/stub-jobs-client.sh"
. "$HARNESS/bin/lib/lane-gate.sh"
lane_gate_or_exit "${LANE_ID:-merge-conductor}" "${LANE_PROJECT:-}"
echo WORKED
SH
chmod +x "$T/h/bin/fake-lane.sh"

# The stub worker. Every call appends to $T/calls so "did the cache save a
# request" is a countable fact and not an assumption. PAUSED lists the rows
# that exist and are active; UNREACHABLE makes every call fail, which is what
# a worker outage looks like to flag_active.
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
# The real client's contract, verbatim: flag_sync drives the FILE from the row
# and answers rc 0 reconciled / rc 2 no row / rc 1 the worker did not answer.
# A stub that collapsed 1 and 2 would pass on a lib that cannot tell an outage
# from an absent row, which is the bug this file exists to catch.
flag_sync() {
  echo "$1" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  case " ${PAUSED:-} " in
    *" $1 "*) mkdir -p "$HARNESS/flags"; touch "$HARNESS/flags/$1"; return 0 ;;
  esac
  return 2
}
flag_active() { flag_sync "$1" >/dev/null 2>&1 || true; [ -f "$HARNESS/flags/$1" ]; }
SH

run() { # run [env assignments...] -> stdout of the lane
  env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" "$@" "$T/h/bin/fake-lane.sh" 2>/dev/null
}
reset() { rm -rf "$T/h/state/lane-gate" "$T/h/logs/lane-gate.log" "$T/calls"; rm -f "$T/h/flags"/*; : > "$T/calls"; }

# 1 — nothing set: the lane runs.
reset
[ "$(run)" = WORKED ] || bad "1 bare lane did not run"; [ "$(run)" = WORKED ] && ok

# 2 — the file flag stops it, and the exit is 0.
reset; touch "$T/h/flags/lane-off-merge-conductor"
OUT=$(run); RC=$?
[ -z "$OUT" ] && [ "$RC" -eq 0 ] && ok || bad "2 file flag: out='$OUT' rc=$RC (want empty, rc 0)"

# 3 — all-off stops a lane that has no flag of its own.
reset; rm -f "$T/h/flags/lane-off-merge-conductor"; touch "$T/h/flags/all-off"
[ -z "$(run)" ] && ok || bad "3 flags/all-off did not stop the lane"
rm -f "$T/h/flags/all-off"

# 4 — a D1 row alone stops it (no file anywhere).
reset
[ -z "$(run PAUSED=lane-off-merge-conductor)" ] && ok || bad "4 pause_flags row did not stop the lane"

# 5 — the all-off ROW stops a lane with no row of its own.
reset
[ -z "$(run PAUSED=all-off)" ] && ok || bad "5 all-off row did not stop the lane"

# 6 — project scope: one project off, its sibling still on.
reset; touch "$T/h/flags/lane-off-review-prs-project-2"
[ -z "$(run LANE_ID=review-prs LANE_PROJECT=project-2)" ] || bad "6a project flag did not stop that project"
[ -z "$(run LANE_ID=review-prs LANE_PROJECT=project-2)" ] && ok
[ "$(run LANE_ID=review-prs LANE_PROJECT=project-3)" = WORKED ] && ok || bad "6b a sibling project was stopped too"
rm -f "$T/h/flags/lane-off-review-prs-project-2"

# 7 — the cache: two ticks inside the TTL, one worker call per flag name. The
# file flag_sync drove is removed between them on purpose — otherwise the
# second tick would stop on the FILE and the assertion would pass on a lib with
# no cache at all.
reset
run PAUSED=lane-off-merge-conductor >/dev/null
N1=$(wc -l < "$T/calls" | tr -d ' ')
rm -f "$T/h/flags/lane-off-merge-conductor"
run PAUSED=lane-off-merge-conductor >/dev/null
N2=$(wc -l < "$T/calls" | tr -d ' ')
[ "$N2" = "$N1" ] && [ "$N1" -gt 0 ] && ok || bad "7 cache did not hold: $N1 then $N2 worker calls"

# 8 — fail open, both directions.
reset
[ "$(run UNREACHABLE=1)" = WORKED ] && ok || bad "8a unreachable worker with a cold cache stopped the lane"
reset
run PAUSED=lane-off-merge-conductor >/dev/null            # cache the PAUSED answer
rm -f "$T/h/flags/lane-off-merge-conductor"               # the row is what paused it
[ -z "$(run UNREACHABLE=1 LANE_GATE_CACHE_S=0)" ] && ok \
  || bad "8b unreachable worker un-paused a lane that was paused a moment ago"

# 9 — one log line per lane per hour.
reset; touch "$T/h/flags/lane-off-merge-conductor"
run >/dev/null; run >/dev/null; run >/dev/null
L=$(grep -c 'merge-conductor SKIPPED' "$T/h/logs/lane-gate.log" 2>/dev/null || echo 0)
[ "$L" = 1 ] || bad "9a three gated ticks wrote $L log lines (want 1)"
[ "$L" = 1 ] && ok
run LANE_GATE_NOW=$((NOW + 3601)) >/dev/null
L2=$(grep -c 'merge-conductor SKIPPED' "$T/h/logs/lane-gate.log" 2>/dev/null || echo 0)
[ "$L2" = 2 ] && ok || bad "9b an hour later the line did not repeat ($L2)"
rm -f "$T/h/flags/lane-off-merge-conductor"

# 11 — RESUME, for a lane row and for the master switch. The stub is the REAL
# client's contract: flag_sync DRIVES the file from the row (touch on active=1,
# rm on active=0) and answers rc 0/2/1. A gate that reads the file before
# reconciling it passes every other section in this file and still leaves the
# fleet stopped for ever.
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
flag_sync() {
  echo "$1" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  mkdir -p "$HARNESS/flags"
  case " ${PAUSED:-} " in
    *" $1 "*) touch "$HARNESS/flags/$1"; return 0 ;;
  esac
  case " ${CLEARED:-} " in
    *" $1 "*) rm -f "$HARNESS/flags/$1"; return 0 ;;   # the row exists and says OFF
  esac
  return 2                                             # no row at all
}
flag_active() { flag_sync "$1" >/dev/null 2>&1 || true; [ -f "$HARNESS/flags/$1" ]; }
SH

reset
run PAUSED=lane-off-merge-conductor >/dev/null          # stopped: the row drove the file
[ -f "$T/h/flags/lane-off-merge-conductor" ] || bad "11-setup the row never drove the file"
[ "$(run CLEARED=lane-off-merge-conductor LANE_GATE_CACHE_S=0)" = WORKED ] && ok \
  || bad "11a a lane stopped by a ROW never resumes when the row is flipped back"
reset
run PAUSED=all-off >/dev/null
[ "$(run CLEARED=all-off LANE_GATE_CACHE_S=0)" = WORKED ] && ok \
  || bad "11b all-on does not resume a box the CLI did not run on"

# 12 — a file with NO row still holds. flag_sync answers rc 2 and leaves it
# alone, so a hand touch on a box (or a cost autohalt) is not reconciled away by
# a database that never heard of it.
reset; touch "$T/h/flags/lane-off-merge-conductor"
[ -z "$(run LANE_GATE_CACHE_S=0)" ] && ok || bad "12 a hand-touched file was reconciled away by the DB"
rm -f "$T/h/flags/lane-off-merge-conductor"

# 13 — the caller's shell options survive. A control plane that changes how an
# unrelated pipeline reports failure is not additive, and this is the one place
# it could: sourcing bin/jobs-client.sh runs `set -uo pipefail` at top level.
reset
cat > "$T/h/bin/fake-client-lane.sh" <<'SH'
#!/bin/bash
set -u
HARNESS="${HARNESS:-/root/harness}"
. "$HARNESS/bin/lib/lane-gate.sh"
lane_gate_or_exit merge-conductor
set -o | awk '$1=="pipefail"{print $2}'
SH
chmod +x "$T/h/bin/fake-client-lane.sh"
# A jobs-client that behaves like the real one: pipefail ON at source time.
cat > "$T/h/bin/jobs-client.sh" <<'SH'
set -uo pipefail
flag_sync() { return 2; }
SH
PF=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" "$T/h/bin/fake-client-lane.sh" 2>/dev/null)
[ "$PF" = off ] && ok || bad "13 sourcing the client left pipefail '$PF' on a lane that runs without it"
rm -f "$T/h/bin/jobs-client.sh"

# 14 — no lanes-row tick is posted, ever. lane_tick is defined here and would
# record itself if the gate called it; the point of the assertion is that a
# gated sibling lane cannot refresh a triage lane's staleness clock.
reset; touch "$T/h/flags/lane-off-merge-conductor"
cat >> "$T/h/bin/stub-jobs-client.sh" <<'SH'
lane_tick() { echo "TICK $*" >> "$TICKS"; }
SH
: > "$T/ticks"
env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" TICKS="$T/ticks" \
  "$T/h/bin/fake-lane.sh" >/dev/null 2>&1
[ ! -s "$T/ticks" ] && ok || bad "14 the gate posted a lanes tick: $(cat "$T/ticks")"
rm -f "$T/h/flags/lane-off-merge-conductor"

# 15 — per-lane liveness. The stub records every _jobs_req, so which ROUTE the
# gate posts to is a fact and not an inference.
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
flag_sync() {
  echo "$1" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  mkdir -p "$HARNESS/flags"
  case " ${PAUSED:-} " in
    *" $1 "*) touch "$HARNESS/flags/$1"; return 0 ;;
  esac
  return 2
}
flag_active() { flag_sync "$1" >/dev/null 2>&1 || true; [ -f "$HARNESS/flags/$1" ]; }
flag_set()    { echo "flag_set $*" >> "$REQS"; }
# An unreachable worker fails EVERY request, not only flag_sync's: that is what
# section 19 counts, and a stub whose POST always succeeded would pass on a lib
# that hammers a dead worker on every tick.
# REFUSE is the worker ANSWERING a 4xx — the real client hands the status back
# through JOBS_HTTP, and an answer costs milliseconds, not the timeout the
# post throttle exists to stop paying.
_jobs_req()   { echo "$1 $2 $3" >> "$REQS"; JOBS_HTTP=""
                [ -n "${UNREACHABLE:-}" ] && return 1
                [ -n "${REFUSE:-}" ] && { JOBS_HTTP=400; return 1; }
                printf '{}'; }
SH
lreset() { reset; : > "$T/reqs"; }
lrun() { env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" REQS="$T/reqs" JOBS_BOX=box7 "$@" "$T/h/bin/fake-lane.sh" 2>/dev/null; }

lreset
lrun >/dev/null
grep -q 'POST /api/lanes/liveness' "$T/reqs" && ok || bad "15a a running tick posted no per-lane liveness row: $(cat "$T/reqs")"
grep -q '"outcome":"ran"' "$T/reqs" && ok || bad "15b the liveness row did not carry outcome=ran: $(cat "$T/reqs")"
grep -q '"box":"box7"' "$T/reqs" && ok || bad "15c the liveness row did not name the box: $(cat "$T/reqs")"
grep -q '/api/lanes/tick' "$T/reqs" && bad "15d the gate posted to /api/lanes/tick — that row is the triage lane's" || ok

lreset; touch "$T/h/flags/lane-off-merge-conductor"
lrun >/dev/null
grep -q '"outcome":"paused"' "$T/reqs" && ok || bad "15e a GATED tick posted no paused liveness row: $(cat "$T/reqs")"
rm -f "$T/h/flags/lane-off-merge-conductor"

# a project lane's row carries its project, so one project being off is visible
# without reading the switch name.
lreset; touch "$T/h/flags/lane-off-review-prs-project-2"
lrun LANE_ID=review-prs LANE_PROJECT=project-2 >/dev/null
grep -q '"project":"project-2"' "$T/reqs" && ok || bad "15f a project lane's liveness row did not carry the project: $(cat "$T/reqs")"
rm -f "$T/h/flags/lane-off-review-prs-project-2"

# 16 — a box-local file is REPORTED, never promoted to a row.
lreset; touch "$T/h/flags/lane-off-merge-conductor"
lrun >/dev/null
grep -q 'POST /api/lanes/flag-seen' "$T/reqs" && ok || bad "16a a hand-touched flag was invisible to the page: $(cat "$T/reqs")"
grep -q '"box":"box7"' "$T/reqs" && ok || bad "16b the sighting did not say which box holds it"
grep -q 'flag_set\|PUT /api/flags' "$T/reqs" && bad "16c the gate promoted a box-local file into a pause_flags row — one box's hand touch became a fleet stop" || ok

# and it is cleared ONCE when the file goes away.
rm -f "$T/h/flags/lane-off-merge-conductor"
: > "$T/reqs"
lrun LANE_GATE_CACHE_S=0 >/dev/null
grep -q '"active":0' "$T/reqs" && ok || bad "16d the sighting was never cleared, so the page keeps showing a stop that is gone: $(cat "$T/reqs")"
: > "$T/reqs"
lrun LANE_GATE_CACHE_S=0 >/dev/null
grep -q 'flag-seen' "$T/reqs" && bad "16e the clear repeats on every tick — one row, one write" || ok

# 17 — lane_paused answers instead of exiting.
lreset; touch "$T/h/flags/lane-off-merge-conductor"
cat > "$T/h/bin/fake-pred.sh" <<'SH'
#!/bin/bash
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "$HARNESS/bin/stub-jobs-client.sh"
. "$HARNESS/bin/lib/lane-gate.sh"
if lane_paused merge-conductor; then echo "PAUSED"; else echo "RUNNING"; fi
echo "STILL_HERE"
SH
chmod +x "$T/h/bin/fake-pred.sh"
OUT=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" REQS="$T/reqs" "$T/h/bin/fake-pred.sh" 2>/dev/null)
case "$OUT" in *PAUSED*STILL_HERE*) ok ;; *) bad "17a lane_paused did not answer 'paused' and return: '$OUT'" ;; esac
rm -f "$T/h/flags/lane-off-merge-conductor"
OUT=$(env HARNESS="$T/h" LANE_GATE_NOW="$NOW" CALLS="$T/calls" REQS="$T/reqs" LANE_GATE_CACHE_S=0 "$T/h/bin/fake-pred.sh" 2>/dev/null)
case "$OUT" in *RUNNING*STILL_HERE*) ok ;; *) bad "17b lane_paused did not answer 'running': '$OUT'" ;; esac


# 18 — AN OUTAGE IS CACHED TOO (BH-1165 review).
#
# The gate reads up to three switch names per tick, each a flag_sync with
# `curl -m 8 --connect-timeout 3` and a retry, and phase C took the number of
# lanes doing that from nine to 78 on every box. Caching only the SUCCESSFUL
# answer meant a worker that was down cost every lane every one of those round
# trips on every tick — and a per-minute lane (wake-loop, poll-commands,
# hub-lease) can spend longer in timeouts than its own cadence. The answer the
# outage path computes is cached like any other, so the SECOND tick inside the
# TTL asks nobody. It is the same answer either way; only the asking changes.
lreset
lrun UNREACHABLE=1 >/dev/null
N1=$(wc -l < "$T/calls" | tr -d ' ')
[ "$N1" -gt 0 ] && ok || bad "18a the first tick of an outage asked the worker nothing at all"
: > "$T/calls"
OUT=$(lrun UNREACHABLE=1)
N2=$(wc -l < "$T/calls" | tr -d ' ')
[ "$N2" -eq 0 ] && ok || bad "18b the second tick inside the TTL re-asked an unreachable worker $N2 time(s) — x77 lanes x every box"
# and it is still FAIL OPEN: the lane ran both times
case "$OUT" in *WORKED*) ok ;; *) bad "18c the cached outage answer stopped a lane instead of failing open: '$OUT'" ;; esac
# a PAUSED answer cached from an outage still holds, and still costs no call
lreset; touch "$T/h/flags/lane-off-merge-conductor"
lrun UNREACHABLE=1 >/dev/null; : > "$T/calls"
OUT=$(lrun UNREACHABLE=1); N2=$(wc -l < "$T/calls" | tr -d ' ')
case "$OUT" in *WORKED*) bad "18d the cached outage answer un-paused a lane an operator stopped" ;; *) ok ;; esac
[ "$N2" -eq 0 ] && ok || bad "18e a paused outage answer was re-fetched inside the TTL"
rm -f "$T/h/flags/lane-off-merge-conductor"

# 19 — THE WRITE HALF OF THE SAME OUTAGE (BH-1165 review round 2).
#
# Section 18 caches the gate's READS. The liveness POST every tick makes was
# still synchronous and uncached, so a worker that was down cost every tick of
# all 77 lanes on every box a full `curl -m 8 --connect-timeout 3` plus its
# retry — ~7s against a black hole, ~17s against a host that accepts and hangs —
# BEFORE the lane did any work. One attempt per TTL is the cap; a healthy
# worker is not throttled at all.
nposts() { local n; n=$(grep -c "${1:-POST /api/lanes/}" "$T/reqs" 2>/dev/null || true); printf '%s' "${n:-0}"; }
lreset
lrun UNREACHABLE=1 >/dev/null
P1=$(nposts)
[ "$P1" -gt 0 ] && ok || bad "19a the first tick of an outage attempted no post at all"
: > "$T/reqs"
OUT=$(lrun UNREACHABLE=1)
P2=$(nposts)
[ "$P2" -eq 0 ] && ok || bad "19b the second tick inside the TTL posted to an unreachable worker $P2 time(s) — x77 lanes x every box, every tick of the outage"
case "$OUT" in *WORKED*) ok ;; *) bad "19c the throttled post stopped a lane instead of failing open: '$OUT'" ;; esac
# the throttle EXPIRES — an outage that ends is noticed within one TTL
: > "$T/reqs"
lrun UNREACHABLE=1 LANE_GATE_NOW=$((NOW + 61)) >/dev/null
P3=$(nposts)
[ "$P3" -gt 0 ] && ok || bad "19d past the TTL the lane never tried the worker again"
# a REACHABLE worker is not throttled: every tick still writes its liveness row
lreset
lrun >/dev/null; lrun >/dev/null
P4=$(nposts 'POST /api/lanes/liveness')
[ "$P4" -eq 2 ] && ok || bad "19e two healthy ticks wrote $P4 liveness rows (want 2) — the throttle is eating live rows"
# a worker that ANSWERS a 4xx is not an outage: one lane posting something the
# worker refuses must not silence every other lane on this box for a minute
lreset
lrun REFUSE=1 >/dev/null; lrun REFUSE=1 >/dev/null
P5=$(nposts)
[ "$P5" -ge 2 ] && ok || bad "19f a 400 from the worker armed the outage throttle ($P5 attempts over two ticks)"

echo "lane-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
