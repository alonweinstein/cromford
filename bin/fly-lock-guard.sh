#!/bin/bash
# bin/fly-lock-guard.sh [locks-dir] — kill orphaned `flyctl agent run` daemons
# that hold a fly-pool / fly-dispatch lock fd. Prints the number killed.
#
# WHY (2026-09-12, project-5 pool dark 66 min with 26 queued builds and 1 live):
# fly-pool.sh takes `exec 8>locks/fly-pool-<p>.lock; flock -n 8` and then runs
# flyctl commands. `machine exec` auto-starts the flyctl agent when none is
# running — as a daemon, re-parented to init, INHERITING fd 8. The tick ends,
# the daemon lives on with the lock, and every later tick's `flock -n` fails
# silently (exit 0, no log line). Same shape for fly-dispatch.sh's fd 9.
#
# Two defences: fly-pool.sh/fly-dispatch.sh now `flyctl agent start` BEFORE
# taking their lock (an agent that already exists is never born inside the
# locked section), and fly-pool-tick.sh runs this guard first so an agent that
# still slipped through is killed — it respawns on demand, nothing is lost.
LOCKS="${1:-/root/harness/locks}"
LOG="${FLY_LOCK_GUARD_LOG:-/root/harness/logs/fly-pool.log}"
n=0
for p in /proc/[0-9]*; do
  pid=${p#/proc/}
  args=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null) || continue
  case "$args" in *"flyctl agent run"*|*"fly agent run"*) ;; *) continue;; esac
  held=$(ls -l "$p/fd" 2>/dev/null | grep -oE "$LOCKS/fly-[a-z0-9-]+\.lock" | sort -u | tr '\n' ' ')
  [ -n "$held" ] || continue
  kill "$pid" 2>/dev/null || continue
  n=$((n+1))
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [fly-lock-guard] killed orphan flyctl agent pid $pid holding $held— it respawns on demand; the lock is free again" >> "$LOG"
done
echo "$n"
