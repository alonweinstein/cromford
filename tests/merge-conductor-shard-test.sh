#!/bin/bash
# tests/merge-conductor-shard-test.sh — the merge conductor's LOCK SHARD and its
# per-tick counters (docs/MERGE-CONDUCTOR.md section 2).
#
# WHAT BROKE AND WHY THIS EXISTS. The tick took ONE flock per project and
# `flock -n || skipped` the whole project when it was held. Measured on the hub
# 2026-09-15 21:00-23:00Z: 102 "an earlier conductor tick still holds this
# project's lock — skipped" lines in two hours (cromford 30, project-5 21,
# project-7 15, project-2 9, project-8 9, project-4 6, the rest 3 each) —
# one slow PR costing its repo the next one to three ticks in full.
#
# The claims under test are all about CONCURRENCY, so every one of them is
# driven with real processes and the real flock, never grepped:
#   1. two PRs of one project hold their locks at the same time; the same PR
#      twice does not
#   2. the merge section is mutually exclusive per project, is not a merge
#      failure when it times out, and leaks no fd to a child
#   3. a daemon that inherits the lock fd holds it for its own life (the known
#      fleet trap) and `9>&-` is what stops it
#   4. the spend budget is respected by concurrent workers, hands units back,
#      and is keyed per tick
#   5. the tick metrics line and tick-<project>.json carry the right shape
# No network, no gh, no agent: this file only ever sources the lib.
# Run from anywhere: tests/merge-conductor-shard-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

export HARNESS="$T/h"; mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/locks"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
export MC_TICK_ID=T1
LOG="$T/h/logs/merge-conductor.log"

# held <lockfile> — rc 0 when somebody else holds it right now.
held() { ! flock -n -x "$1" true; }
# hold_lock <lockfile> -> the pid holding it, which `kill` really does release.
#   `flock -x <file> sleep 20 &` looks like the obvious fixture and is a trap:
#   flock FORKS the command, so killing the pid $! gave you kills flock and
#   leaves the orphaned sleep holding the inherited fd — the very shape section
#   3 is about. `exec sleep` keeps one pid, and that pid owns the lock.
hold_lock() {
  # `-w`, not `-n`: `held` above PROBES with a real exclusive lock, so a
  # non-blocking holder loses a coin flip against the caller's own wait_for poll
  # (it did, about two runs in five). >/dev/null matters too — the holder would
  # otherwise inherit this command substitution's pipe and $( ) would not return
  # until it exited.
  ( exec 9>"$1"; flock -w 5 9 || exit 1; exec sleep 20 ) >/dev/null 2>&1 &
  echo $!
}
# wait_for <shell-condition> — poll until it holds, up to 5s. Not a sleep-and-hope:
# every caller states the condition it is waiting for and fails loudly if it
# never arrives.
wait_for() {
  local i=0
  while [ "$i" -lt 100 ]; do eval "$1" && return 0; sleep 0.05; i=$((i+1)); done
  return 1
}

# ============================================================================
# 1. The shard: one lock per PR, not one per project
# ============================================================================
L31=$(mc_pr_lock demo-os 31); L32=$(mc_pr_lock demo-os 32)
[ "$L31" = "$T/h/locks/merge-conductor-demo-os-31.lock" ] \
  && ok || bad "the PR lock must be locks/merge-conductor-<project>-<pr>.lock (got $L31)"
[ "$(mc_merge_lock demo-os)" = "$T/h/locks/merge-conductor-demo-os-merge.lock" ] \
  && ok || bad "the merge lock must be locks/merge-conductor-<project>-merge.lock (got $(mc_merge_lock demo-os))"
[ "$(mc_pr_lock 'demo/os' '9 9')" = "$T/h/locks/merge-conductor-demo_os-9_9.lock" ] \
  && ok || bad "a project or number with a path character must be made safe (got $(mc_pr_lock 'demo/os' '9 9'))"

# PR 31 is held by another "worker". PR 31 must be refused and PR 32 must not.
H31=$(hold_lock "$L31")
wait_for 'held "$L31"' || bad "the fixture could not take PR 31's lock"
held "$L31" && ok || bad "PR 31's lock must read as held while a worker has it"
held "$L32" && bad "PR 32's lock must be free while PR 31's is held" || ok
# ...and a holder of 32 lives alongside it: two PRs of one project hold their own
# locks at the same time, which is the whole point of the shard.
H32=$(hold_lock "$L32")
wait_for 'held "$L32"' || bad "the fixture could not take PR 32's lock"
held "$L31" && held "$L32" && ok || bad "two PRs of one project must hold their locks at the same time"
[ -z "$(ls "$T/h/locks"/merge-conductor-demo-os.lock 2>/dev/null)" ] \
  && ok || bad "no project-wide lock file may be created any more"
kill "$H31" "$H32" 2>/dev/null
wait_for '! held "$L31"' && ok || bad "a PR lock must be released when its worker dies (there is no expiry to wait for)"

# ============================================================================
# 2. The merge section: short, mutually exclusive, and rc 99 is not a failure
# ============================================================================
# The "merge call": records its entry and exit so an overlap is visible in the
# file afterwards. Two of them race; a serialised pair reads in-out-in-out.
mark() { echo "in $1" >> "$T/marks.txt"; sleep 0.3; echo "out $1" >> "$T/marks.txt"; echo "merged-$1"; }
: > "$T/marks.txt"
( O=$(mc_merge_locked demo-os mark A); echo "A rc=$? out=$O" >> "$T/rcs.txt" ) &
M1=$!
( O=$(mc_merge_locked demo-os mark B); echo "B rc=$? out=$O" >> "$T/rcs.txt" ) &
M2=$!
wait "$M1" "$M2" 2>/dev/null
[ "$(wc -l < "$T/marks.txt")" = 4 ] && ok || bad "both merge calls must run (got $(cat "$T/marks.txt"))"
[ "$(awk '{print $1}' "$T/marks.txt" | tr '\n' ' ')" = "in out in out " ] \
  && ok || bad "the merge section must be mutually exclusive per project (got $(tr '\n' ' ' < "$T/marks.txt"))"
[ "$(grep -c 'rc=0 out=merged-' "$T/rcs.txt")" = 2 ] \
  && ok || bad "mc_merge_locked must pass the command's own rc and stdout back (got $(cat "$T/rcs.txt"))"
! held "$(mc_merge_lock demo-os)" && ok || bad "the merge lock must be released the moment the call returns"

# A merge lock somebody else holds: rc 99 (nothing written, try next tick), and
# never the command's own failure rc, which callers count as a strike.
HM=$(hold_lock "$(mc_merge_lock demo-os)")
wait_for 'held "$(mc_merge_lock demo-os)"' || bad "the fixture could not take the merge lock"
: > "$T/ran.txt"
OUT=$(MC_MERGE_LOCK_WAIT=1 mc_merge_locked demo-os bash -c 'echo ran >> "'"$T"'/ran.txt"; exit 1'); RC=$?
[ "$RC" = 99 ] && ok || bad "a merge lock that cannot be had in MC_MERGE_LOCK_WAIT must answer 99 (got $RC)"
[ ! -s "$T/ran.txt" ] && ok || bad "the merge call must NOT have run while another worker held the lock"
# A different project is not blocked by it — the lock is per project.
OUT=$(MC_MERGE_LOCK_WAIT=1 mc_merge_locked issuer echo other); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = other ] && ok || bad "one project's merge lock must not block another's (rc $RC out $OUT)"
kill "$HM" 2>/dev/null

# The project's SHARED GIT CHECKOUT is the other thing two workers must not be
# in at once: mc_merge_tree, mc_patch_id and mc_no_overlap each set the remote's
# credentials, fetch, read, and then CLEAR the credentials — and a clear from
# one worker lands in the middle of the other's fetch. Same contract, fd 7.
[ "$(mc_git_lock demo-os)" = "$T/h/locks/merge-conductor-demo-os-git.lock" ] \
  && ok || bad "the git lock must be locks/merge-conductor-<project>-git.lock (got $(mc_git_lock demo-os))"
: > "$T/marks.txt"
( mc_git_locked demo-os mark G1 >/dev/null ) &
G1=$!
( mc_git_locked demo-os mark G2 >/dev/null ) &
G2=$!
wait "$G1" "$G2" 2>/dev/null
[ "$(awk '{print $1}' "$T/marks.txt" | tr '\n' ' ')" = "in out in out " ] \
  && ok || bad "two funnel reads of one project must not overlap in its checkout (got $(tr '\n' ' ' < "$T/marks.txt"))"
HG=$(hold_lock "$(mc_git_lock demo-os)")
wait_for 'held "$(mc_git_lock demo-os)"' || bad "the fixture could not take the git lock"
MC_GIT_LOCK_WAIT=1 mc_git_locked demo-os true; RC=$?
[ "$RC" = 99 ] && ok || bad "a git lock that cannot be had must answer 99, which callers read as 'not answered', never as a negative answer (got $RC)"
MC_GIT_LOCK_WAIT=1 mc_git_locked issuer true && ok || bad "the git lock must be per project"
kill "$HG" 2>/dev/null
# The merge lock and the git lock are different fds (8 and 7), so one may be
# taken inside the other without either deadlocking or silently passing.
wait_for '! held "$(mc_git_lock demo-os)"' || bad "the git lock was not released"
NEST=$(mc_merge_locked demo-os mc_git_locked demo-os echo nested); RC=$?
[ "$RC" = 0 ] && [ "$NEST" = nested ] && ok || bad "the merge lock and the git lock must not collide (rc $RC out $NEST)"

# ============================================================================
# 3. THE KNOWN FLEET TRAP: a daemon forked inside a flock'd section INHERITS the
#    fd and holds the lock for its own life. A deploy verifier did exactly that
#    on project-5 (03:54-04:02Z, 2026-09-14) and every tick in between skipped
#    the project. The lane spawns close the fd; this proves both directions, so
#    a future lane that forgets `9>&-` fails here rather than on the fleet.
# ============================================================================
L40=$(mc_pr_lock demo-os 40)
( exec 9>"$L40"; flock -n 9 || exit 1; setsid sleep 20 >/dev/null 2>&1 & echo $! > "$T/leaky.pid" ) &
wait $! 2>/dev/null
wait_for '[ -s "$T/leaky.pid" ]' || bad "the leaky child never started"
held "$L40" && ok || bad "a child that inherits fd 9 must keep the lock after its parent exits — if this fails the trap is no longer real and the 9>&- test below proves nothing"
kill "$(cat "$T/leaky.pid")" 2>/dev/null
wait_for '! held "$L40"' >/dev/null

L41=$(mc_pr_lock demo-os 41)
( exec 9>"$L41"; flock -n 9 || exit 1; setsid sleep 20 >/dev/null 2>&1 9>&- & echo $! > "$T/clean.pid" ) &
wait $! 2>/dev/null
wait_for '[ -s "$T/clean.pid" ]' || bad "the clean child never started"
wait_for '! held "$L41"' \
  && ok || bad "a lane spawned with 9>&- must NOT hold its parent's PR lock (this is the wedge the shard exists to make impossible)"
kill "$(cat "$T/clean.pid")" 2>/dev/null

# ============================================================================
# 4. The spend budgets: a file, not a variable, because the workers are subshells
# ============================================================================
[ "$(mc_count_get demo-os prs)" = 0 ] && ok || bad "an absent counter must read 0"
[ "$(mc_count_file demo-os)" = "$T/h/state/merge-conductor/tick/T1.demo-os" ] \
  && ok || bad "the counters of one project in one tick live in ONE file (got $(mc_count_file demo-os))"
mc_count_inc demo-os prs >/dev/null; mc_count_inc demo-os prs >/dev/null
[ "$(mc_count_get demo-os prs)" = 2 ] && ok || bad "mc_count_inc must count (got $(mc_count_get demo-os prs))"
# Eight workers race for a budget of three. Exactly three may win, whatever the
# scheduler does — this is the assertion a bash variable could never satisfy.
: > "$T/takes.txt"
for i in 1 2 3 4 5 6 7 8; do
  ( mc_tick_budget_take demo-os merge 3 && echo "took $i" >> "$T/takes.txt" ) &
done
wait 2>/dev/null
[ "$(grep -c '^took ' "$T/takes.txt")" = 3 ] \
  && ok || bad "a budget of 3 must be taken exactly 3 times by 8 concurrent workers (got $(grep -c '^took ' "$T/takes.txt"))"
[ "$(mc_count_get demo-os budget-merge)" = 3 ] \
  && ok || bad "the counter must end at the limit (got $(mc_count_get demo-os budget-merge))"
mc_tick_budget_take demo-os merge 3 && bad "a spent budget must refuse" || ok
mc_tick_budget_left demo-os merge 3 && bad "mc_tick_budget_left must agree that it is spent" || ok
# A unit handed back is a unit another PR may spend: a spawn refused at the
# parallel cap must not cost the project a rebase it never ran.
mc_tick_budget_give demo-os merge
mc_tick_budget_left demo-os merge 3 && ok || bad "a returned unit must be spendable again"
mc_tick_budget_take demo-os merge 3 && ok || bad "and takeable"
# the budgets and the metrics share one file, so one must never eat the other
[ "$(mc_count_get demo-os prs)" = 2 ] \
  && ok || bad "a budget take must not clobber a metrics counter in the same file (prs=$(mc_count_get demo-os prs))"
[ "$(grep -c . "$(mc_count_file demo-os)")" -ge 2 ] \
  && ok || bad "the counter file must hold a line per counter (got $(cat "$(mc_count_file demo-os)"))"
# A budget of 0 is a budget, not an unlimited one.
mc_tick_budget_take demo-os rebase 0 && bad "a 0 budget must never be takeable" || ok
# Budgets are per project and per tick: another project, and the next tick,
# start fresh with no reset step anywhere.
mc_tick_budget_take issuer merge 3 && ok || bad "one project's spend must not touch another's"
MC_TICK_ID=T2 mc_tick_budget_take demo-os merge 3 && ok || bad "the next tick must start from an empty budget"
[ "$(MC_TICK_ID=T2 mc_count_get demo-os budget-merge)" = 1 ] \
  && ok || bad "the counter is keyed by tick id (got $(MC_TICK_ID=T2 mc_count_get demo-os budget-merge))"

# ============================================================================
# 5. Tick observability: one structured line per project per tick, and the same
#    numbers as JSON for a later SLO/DORA reader.
# ============================================================================
export MC_TICK_ID=T3
for _ in 1 2 3 4 5; do mc_count_inc obs prs >/dev/null; done
mc_count_inc obs locked >/dev/null
mc_count_inc obs merges >/dev/null
mc_count_inc obs rebases >/dev/null; mc_count_inc obs rebases >/dev/null
mc_count_inc obs rereviews >/dev/null
mc_count_inc obs exhausted >/dev/null
: > "$LOG"
mc_tick_metrics obs 1000 1042
LINE=$(grep -c 'TICK obs ' "$LOG")
[ "$LINE" = 1 ] && ok || bad "exactly one metrics line per project per tick (got $LINE)"
grep -q 'TICK obs tick=T3 secs=42 prs=5 locked=1 merges=1 rebases=2 rereviews=1 budget_exhausted=1' "$LOG" \
  && ok || bad "the metrics line shape is wrong: $(grep 'TICK obs' "$LOG")"
J="$T/h/state/merge-conductor/tick-obs.json"
[ -f "$J" ] && ok || bad "the tick must write state/merge-conductor/tick-<project>.json"
[ "$(jq -r '[.tick,.project,.duration_secs,.prs_seen,.prs_locked,.merges,.rebases,.rereviews,.budget_exhausted]|join(",")' "$J")" \
  = "T3,obs,42,5,1,1,2,1,1" ] && ok || bad "the JSON must carry the same numbers: $(cat "$J")"
[ "$(jq -r '[.duration_secs,.prs_seen]|map(type)|join(",")' "$J")" = "number,number" ] \
  && ok || bad "the counters must be JSON numbers, not strings: $(cat "$J")"
[ "$(jq -r '.started_at,.finished_at' "$J" | tr '\n' ' ')" = "1000 1042 " ] \
  && ok || bad "the JSON must carry the tick's own window: $(cat "$J")"
# The last tick overwrites, and a clock that went backwards is not a negative.
mc_tick_metrics obs 2000 1990
[ "$(jq -r .duration_secs "$J")" = 0 ] && ok || bad "a finish before the start must read 0, not a negative duration"
# GC: this tick's counters survive, yesterday's do not.
touch -d '2 days ago' "$T/h/state/merge-conductor/tick/old.counter" 2>/dev/null || touch "$T/h/state/merge-conductor/tick/old.counter"
mc_tick_gc
[ -f "$(mc_count_file obs)" ] && ok || bad "mc_tick_gc must leave this tick's counters alone"

# ============================================================================
# 6. Lock files do not accumulate for ever, and a live one is never unlinked
# ============================================================================
OLDLK=$(mc_pr_lock demo-os 900); NEWLK=$(mc_pr_lock demo-os 901)
: > "$OLDLK"; : > "$NEWLK"
touch -d '30 days ago' "$OLDLK" 2>/dev/null || touch -t 202501010101 "$OLDLK"
LIVE=$(mc_pr_lock demo-os 902); HL=$(hold_lock "$LIVE")
wait_for 'held "$LIVE"' || bad "the fixture could not take the live PR lock"
touch -d '30 days ago' "$LIVE" 2>/dev/null || touch -t 202501010101 "$LIVE"
mc_pr_lock_gc
[ ! -f "$OLDLK" ] && ok || bad "a PR lock file nothing has touched in MC_PR_LOCK_TTL_DAYS must be collected"
[ -f "$NEWLK" ] && ok || bad "this week's PR lock files must be left alone"
[ -f "$LIVE" ] && ok || bad "a lock a worker is HOLDING must never be unlinked, however old the file is"
[ -f "$(mc_merge_lock demo-os)" ] && ok || bad "the per-project merge lock must not match the PR-lock GC pattern"
kill "$HL" 2>/dev/null

echo "merge-conductor-shard-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
