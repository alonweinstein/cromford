#!/bin/bash
# tests/iron-law-guard-signal-test.sh — the guard's CRASH path, driven for real.
#
# WHY THIS SUITE EXISTS (#409). The guard trapped only EXIT. On a SIGTERM it
# exited 143 with empty stdout, and its own audit line said the Bash call "ran
# UNGUARDED" while reporting rc=0 — because on an untrapped fatal signal bash
# runs the EXIT trap with $? of the last COMPLETED command. The CLI reads any
# exit other than 2 as a non-blocking hook error and runs the tool call. So the
# one moment the guard was most likely to be killed — a stage window expiring
# mid-build — was the one moment it stopped guarding, three times over.
#
# The contract this pins: a guard that dies before reaching a verdict BLOCKS
# (exit 2 + the refusal shape on stdout + one ALERTS line), and it stays quiet
# in exactly the cases where it has no standing to speak.
#
# WHY set -m AROUND EVERY SIGNAL LAUNCH. A non-interactive shell sets SIGINT and
# SIGQUIT to SIG_IGN for an asynchronous (`&`) child, and bash keeps an
# inherited-ignored signal ignored — so a plain `cmd & kill -INT` can never reach
# an INT trap and case B would pass against a guard with no traps at all. In
# production the hook is a FOREGROUND child of the CLI with default dispositions,
# and the stage window's `timeout --kill-after=120` signals the whole process
# group. Job control reproduces that; without it the fixture is vacuous.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/wait-for.sh" || exit 1  # BH-6049: signal on a readiness fact, not a fixed sleep
# traps_armed <pid>: the guard has installed its HUP, INT and TERM traps (SigCgt
# bits 0x4003). A signal before that kills it with 143 instead of the verdict 2.
traps_armed() {
  local m
  [ -r "/proc/$1/status" ] || { sleep 0.5; return 0; }  # determinism: ok no /proc (macOS): the old fixed wait is the only readiness signal
  m=$(awk '/^SigCgt:/ { print $2 }' "/proc/$1/status" 2>/dev/null)
  [ -n "$m" ] && (( (16#$m & 0x4003) == 0x4003 ))
}
# group_sleeping <pid>: a `sleep` stub runs somewhere under the guard. Walk the
# descendants, not the process group: GNU `timeout` (around the git child) puts
# its child in a new process group.
group_sleeping() {
  local c
  command -v pgrep >/dev/null 2>&1 || { sleep 0.7; return 0; }  # determinism: ok no pgrep: the old fixed wait is the only readiness signal
  for c in $(pgrep -P "$1" 2>/dev/null); do
    [ "$(cat "/proc/$c/comm" 2>/dev/null)" = sleep ] && return 0
    group_sleeping "$c" && return 0
  done
  return 1
}
mkdir -p "$T/logs" "$T/fakebin" "$T/repo"
# One clock read; every elapsed assertion below is a difference of two offsets
# from it, so the suite never compares against a second wall-clock baseline.
NOW=$(date +%s)
secs() { echo $(( $(date +%s) - NOW )); }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

GUARD="$DIR/bin/iron-law-guard.sh"

# One PreToolUse payload, the shape Claude Code sends (identical to the shape
# tests/iron-law-guard-test.sh feeds the same script).
payload() { # payload <command> [cwd]
  jq -nc --arg c "$1" --arg d "${2:-$T}" \
    '{session_id:"s1",hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}'
}

reset_logs() { : > "$T/logs/ALERTS.log"; : > "$T/logs/findings.log"; }
crash_lines() { grep -cF '[iron-law] guard crashed' "$T/logs/ALERTS.log" 2>/dev/null || true; }

# The guard, launched on a fifo THIS shell holds open read-write, so it blocks in
# the payload read with no EOF coming — the state a stage-window SIGTERM catches
# it in. GUARD_ENV is the env prefix; GUARD_SCRIPT the copy under test.
FIFO_N=0
GUARD_SCRIPT="$GUARD"
GUARD_ENV=(HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj)
start_held() { # start_held <command>
  FIFO_N=$((FIFO_N+1))
  HFIFO="$T/hold.$FIFO_N.fifo"
  mkfifo "$HFIFO"
  exec 9<>"$HFIFO"
  payload "$1" >&9
  : > "$T/out"; : > "$T/err"
  set -m
  env "${GUARD_ENV[@]}" bash "$GUARD_SCRIPT" <&9 >"$T/out" 2>"$T/err" &
  GPID=$!
  set +m
}
end_held() { exec 9>&-; }

# Does stdout carry the refusal shape the ticket names?
block_shape() { jq -e '.decision=="block" and (.reason|startswith("guard crashed"))' <"$T/out" >/dev/null 2>&1; }

# --- A/B/B2: a signal during the payload read is a BLOCK ---------------------
# One case per trappable signal. SIGKILL is not here on purpose: it is the
# `--kill-after=120` second stage and is untrappable by construction.
for SIG in TERM INT HUP; do
  reset_logs
  t0=$(secs)
  start_held "gh pr merge 1"
  wait_for 10 traps_armed "$GPID"
  kill -"$SIG" "$GPID" 2>/dev/null
  wait "$GPID" 2>/dev/null; RC=$?
  end_held
  t1=$(secs)
  [ "$RC" = 2 ] \
    && ok || bad "$SIG mid-read did not block the tool call (rc=$RC, want 2) — the CLI runs any non-2 hook exit"
  block_shape \
    && ok || bad "$SIG mid-read printed no refusal shape on stdout: $(cat "$T/out")"
  [ "$(crash_lines)" = 1 ] \
    && ok || bad "$SIG mid-read filed $(crash_lines) '[iron-law] guard crashed' ALERTS lines, want exactly 1"
  grep -q "act-time iron-law guard CRASHED" "$T/logs/ALERTS.log" \
    && bad "$SIG mid-read still claims the Bash call ran UNGUARDED: $(cat "$T/logs/ALERTS.log")" || ok
  [ $((t1-t0)) -le 2 ] \
    && ok || bad "$SIG mid-read took $((t1-t0))s to reach a verdict, want <= 2"
done

# --- C: a normal allowed command is untouched -------------------------------
reset_logs
payload "npm run build" | env HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj \
  bash "$GUARD" >"$T/out" 2>"$T/err"
RC=$?
[ "$RC" = 0 ] && ok || bad "an ordinary build command was not allowed (rc=$RC)"
[ ! -s "$T/out" ] && ok || bad "an allowed command printed on stdout: $(cat "$T/out")"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "an allowed command wrote to ALERTS: $(cat "$T/logs/ALERTS.log")"

# --- D: a REAL deny is never reported as a crash ----------------------------
reset_logs
payload "gh pr merge 1" | env HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj \
  HARNESS_TICKET=BH-409 bash "$GUARD" >"$T/out" 2>"$T/err"
RC=$?
[ "$RC" = 2 ] && ok || bad "a deliberate deny stopped exiting 2 (rc=$RC)"
grep -q "BLOCKED by the harness act-time iron-law guard" "$T/err" \
  && ok || bad "a deliberate deny gave the model no reason"
grep -q "family=actguard-pr-merge" "$T/logs/findings.log" \
  && ok || bad "a deliberate deny filed no pr-merge finding"
[ "$(crash_lines)" = 0 ] \
  && ok || bad "a deliberate deny was reported as a guard crash: $(cat "$T/logs/ALERTS.log")"

# --- E: a hung child with NO signal still degrades on the guard's own clock --
# The CLI abandons a PreToolUse hook at 30s and ignores whatever it prints, so
# that is the ONE deadline the guard cannot fail closed against. Its defence is
# bounding every child it spawns. A jq that never returns must therefore be cut
# short by the guard, not by the CLI.
reset_logs
cat > "$T/fakebin/jq" <<'STUB'
#!/bin/bash
sleep 10  # determinism: ok fixture — a child that outlives the guard's own bound
exec /usr/bin/jq "$@"
STUB
chmod +x "$T/fakebin/jq"
t0=$(secs)
payload "gh pr merge 1" | env PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_LANE=execute \
  HARNESS_LANE_PROJECT=testproj bash "$GUARD" >"$T/out" 2>"$T/err"
RC=$?
t1=$(secs)
[ "$RC" = 0 ] && ok || bad "a self-diagnosed degrade bricked the command (rc=$RC) — LOUD is a stated fail-open"
grep -q "iron-law guard INERT" "$T/logs/ALERTS.log" \
  && ok || bad "a hung child degraded SILENTLY: $(cat "$T/logs/ALERTS.log")"
[ $((t1-t0)) -le 8 ] \
  && ok || bad "a hung jq held the guard $((t1-t0))s, want <= 8 — the CLI's 30s budget decides instead of the guard"
rm -f "$T/fakebin/jq"

# --- F: an internal error (set -u abort) is a BLOCK --------------------------
reset_logs
sed 's|^trap .*EXIT$|&\nBROKEN_ON_PURPOSE="$THIS_VARIABLE_DOES_NOT_EXIST"|' "$GUARD" > "$T/broken-setu.sh"
payload "gh pr merge 1" | env HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj \
  bash "$T/broken-setu.sh" >"$T/out" 2>"$T/err"
RC=$?
[ "$RC" = 2 ] && ok || bad "a guard that died on an unbound variable let the command run (rc=$RC)"
[ "$(crash_lines)" = 1 ] && ok || bad "the set -u abort filed $(crash_lines) crash lines, want 1"
grep -qE '\[iron-law\] guard crashed: exited rc=[1-9][0-9]* before a verdict' "$T/logs/ALERTS.log" \
  && ok || bad "the crash line lost the real exit status: $(cat "$T/logs/ALERTS.log")"

# --- G: an early exit before any verdict is a BLOCK --------------------------
reset_logs
sed 's@^\[ -n "\$LANE" \] || ALLOW$@exit 7\n&@' "$GUARD" > "$T/broken-exit7.sh"
grep -q '^exit 7$' "$T/broken-exit7.sh" \
  || bad "case G could not inject its early exit — the anchor line moved, the case below proves nothing"
payload "gh pr merge 1" | env HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj \
  bash "$T/broken-exit7.sh" >"$T/out" 2>"$T/err"
RC=$?
[ "$RC" = 2 ] && ok || bad "a guard that exited before deciding let the command run (rc=$RC)"
[ "$(crash_lines)" = 1 ] && ok || bad "the early exit filed $(crash_lines) crash lines, want 1"
grep -q 'guard crashed: exited rc=7 before a verdict' "$T/logs/ALERTS.log" \
  && ok || bad "the crash line did not carry rc=7: $(cat "$T/logs/ALERTS.log")"

# --- H: a signal while a bounded child is in flight --------------------------
# Bash defers a trap until the foreground command returns, so what keeps this
# under the CLI's 30s budget is the `timeout` on the child, not the trap.
reset_logs
git init -q "$T/repo" 2>/dev/null || true
git -C "$T/repo" checkout -q -b feat 2>/dev/null || true
cat > "$T/fakebin/git" <<'STUB'
#!/bin/bash
exec sleep 20  # determinism: ok fixture — a child that hangs past the guard's bound
STUB
chmod +x "$T/fakebin/git"
GUARD_ENV=(PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj)
t0=$(secs)
FIFO_N=$((FIFO_N+1))
HFIFO="$T/hold.$FIFO_N.fifo"; mkfifo "$HFIFO"; exec 9<>"$HFIFO"
payload "git push" "$T/repo" >&9
printf '\0' >&9   # let the read COMPLETE, so the guard is inside the git child when the signal lands
: > "$T/out"; : > "$T/err"
set -m
env "${GUARD_ENV[@]}" bash "$GUARD" <&9 >"$T/out" 2>"$T/err" &
GPID=$!
set +m
wait_for 10 group_sleeping "$GPID"
kill -TERM "$GPID" 2>/dev/null
wait "$GPID" 2>/dev/null; RC=$?
end_held
t1=$(secs)
[ "$RC" = 2 ] && ok || bad "SIGTERM during a hung git child did not block (rc=$RC)"
block_shape && ok || bad "SIGTERM during a hung git child printed no refusal shape: $(cat "$T/out")"
[ "$(crash_lines)" = 1 ] && ok || bad "SIGTERM during a hung git child filed $(crash_lines) crash lines, want 1"
[ $((t1-t0)) -le 8 ] \
  && ok || bad "an unbounded git child held the guard $((t1-t0))s past a SIGTERM, want <= 8"
rm -f "$T/fakebin/git"
GUARD_ENV=(HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj)

# --- I: a signal while a slow (but returning) child is in flight -------------
reset_logs
cat > "$T/fakebin/jq" <<'STUB'
#!/bin/bash
sleep 3  # determinism: ok fixture — slow enough to hold the trap, short enough to return on its own
exec /usr/bin/jq "$@"
STUB
chmod +x "$T/fakebin/jq"
GUARD_ENV=(PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj)
t0=$(secs)
FIFO_N=$((FIFO_N+1))
HFIFO="$T/hold.$FIFO_N.fifo"; mkfifo "$HFIFO"; exec 9<>"$HFIFO"
payload "gh pr merge 1" >&9
printf '\0' >&9
: > "$T/out"; : > "$T/err"
set -m
env "${GUARD_ENV[@]}" bash "$GUARD" <&9 >"$T/out" 2>"$T/err" &
GPID=$!
set +m
sleep 0.5  # determinism: ok fixture — land the signal while the slow jq is still running
kill -TERM "$GPID" 2>/dev/null
wait "$GPID" 2>/dev/null; RC=$?
end_held
t1=$(secs)
[ "$RC" = 2 ] && ok || bad "SIGTERM during a slow jq did not block (rc=$RC)"
[ $((t1-t0)) -le 6 ] && ok || bad "SIGTERM during a slow jq took $((t1-t0))s, want <= 6"
rm -f "$T/fakebin/jq"
GUARD_ENV=(HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj)

# --- J: a SECOND signal after the verdict changes nothing --------------------
# One event, one ALERTS line. The `date` stub holds the crash handler open long
# enough for the second signal to land INSIDE it, which is the race the DECIDED
# short-circuit exists for.
reset_logs
cat > "$T/fakebin/date" <<'STUB'
#!/bin/bash
sleep 2  # determinism: ok fixture — hold the crash handler open across the second signal
exec /usr/bin/date "$@"
STUB
chmod +x "$T/fakebin/date"
GUARD_ENV=(PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj)
start_held "gh pr merge 1"
wait_for 10 traps_armed "$GPID"
kill -TERM "$GPID" 2>/dev/null
wait_for 10 group_sleeping "$GPID"   # the handler is inside the stub date's 2 s pause
kill -HUP "$GPID" 2>/dev/null
SECOND_KILL=$?
wait "$GPID" 2>/dev/null; RC=$?
end_held
[ "$SECOND_KILL" = 0 ] \
  && ok || bad "the second signal never reached a live process — case J proved nothing about the race"
[ "$RC" = 2 ] && ok || bad "a second signal changed the standing verdict (rc=$RC, want 2)"
[ "$(crash_lines)" = 1 ] \
  && ok || bad "one crash filed $(crash_lines) ALERTS lines — a second signal pages twice"
rm -f "$T/fakebin/date"
GUARD_ENV=(HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj)

# --- L: an UNMARKED session gets no opinion, crash path included -------------
# A settings file that leaks into a non-harness session must stay inert. The
# crash path is held to the same fence as the normal path.
reset_logs
GUARD_ENV=(-u HARNESS_LANE -u HARNESS_LANE_PROJECT -u HARNESS_LANE_WT HARNESS="$T")
start_held "gh pr merge 1"
wait_for 10 traps_armed "$GPID"
kill -TERM "$GPID" 2>/dev/null
wait "$GPID" 2>/dev/null; RC=$?
end_held
GUARD_ENV=(HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj)
[ "$RC" = 0 ] && ok || bad "a SIGTERM in an UNMARKED session produced a verdict (rc=$RC, want 0)"
[ ! -s "$T/out" ] && ok || bad "an unmarked session got a refusal on stdout: $(cat "$T/out")"
[ ! -s "$T/logs/ALERTS.log" ] \
  && ok || bad "an unmarked session paged on a crash: $(cat "$T/logs/ALERTS.log")"

echo "iron-law-guard-signal: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
