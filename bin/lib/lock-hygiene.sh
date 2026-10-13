#!/bin/bash
# bin/lib/lock-hygiene.sh — NO CHILD OF A LANE CARRIES THAT LANE'S LOCK.
#
# BH-651. bin/run-triage.sh holds the per-project tick lock on fd 9 and
# bin/triage-shard.sh holds the per-ticket key lock on fd 8. A flock lives on the
# OPEN FILE DESCRIPTION, so every process that inherits the descriptor keeps the
# lock alive — including a build the session detaches and walks away from. On
# 2026-09-17 pid 8911 (`run-build.sh cromford 421 BH-421`) was the only
# holder of locks/cromford.lock 43 minutes after its tick had exited, and
# every tick from 16:13Z to 16:48Z answered "previous run still active, skipping".
# One fork in run-triage.sh already closed fd 9 by hand; the other did not, which
# is the whole bug.
#
# So the closing lives HERE, once, and every spawn site calls it. A third fork
# added later is added to lock_run_unheld's argument list, not to a new copy of
# `9>&-` somebody has to remember.
#
# THE FD NUMBERS ARE THE CONTRACT:
#   fd 8 — bin/triage-shard.sh, locks/triage-key-<project>-<KEY>.lock
#   fd 9 — bin/run-triage.sh,   locks/<project>.lock
# A lane that starts holding a lock on a third fd adds it to both functions
# below. Closing an fd that is not open is a no-op in bash, so both are safe to
# call from a script that holds neither.
#
# Sourced, never executed. Nothing here runs on sourcing.

# lock_run_unheld <cmd> [args...] — run <cmd> with the lock fds closed.
# The exit code is the command's own: the subshell execs it, so `RC=$?` on the
# next line of the caller reads exactly what it read before this wrapper existed.
# The CALLER's own fds are untouched — the closing happens in the subshell — so
# the tick keeps its lock and the shard keeps its key while the child runs
# without either.
lock_run_unheld() {
  [ $# -gt 0 ] || return 0
  ( exec 8>&- 9>&-; exec "$@" )
}

# lock_spawn_unheld <cmd> [args...] — the same thing, DETACHED.
#
# Why this is a second function and not `lock_run_unheld … &`: backgrounding a
# FUNCTION call makes bash fork an async subshell to run it, and that subshell
# sits there waiting for the child — still holding fd 9 — for the child's whole
# life. It is the original bug wearing a helper's clothes, and
# tests/triage-shards-test.sh case 1 catches it. Backgrounding an explicit
# subshell instead costs exactly one fork: it closes the fds and execs, so the
# process that ends up running is the command itself.
#
# Redirections and env prefixes belong on the CALL (`FOO=1 lock_spawn_unheld cmd
# </dev/null >/dev/null 2>&1`); both reach the child. The caller does not wait.
lock_spawn_unheld() {
  [ $# -gt 0 ] || return 0
  ( exec 8>&- 9>&-; exec "$@" ) &
}

# lock_holders <lock-path> — who has this lock file open, oldest first.
# Prints at most three `pid=N age=Ss cmd=...` lines and nothing else. Never fails
# the caller: an unreadable /proc, a missing ps, and a lock nobody holds all
# print nothing and return 0, and the caller says "(holder unknown)".
#
# OLDEST FIRST is the classification: a tick that is genuinely still running is
# older than anything it spawned, and a leaked build from an earlier tick is
# older than the tick that just bounced off it. So the first line is the process
# worth naming in both the routine case and the leak.
#
# The scan itself runs with the lock fds closed, for the same reason everything
# else here does: a command substitution inherits them, and a scanner that found
# ITSELF holding the lock would report the leak it was looking for on every
# healthy box. The caller's own pid is skipped too — it is holding the file open
# precisely because it just failed to lock it.
#
# Bounded by design: one pass over /proc, `ps` only for a process that actually
# has the file open, three lines out, 100 characters of argv each.
lock_holders() {
  local target="${1:-}" out=""
  [ -n "$target" ] || return 0
  # The close is the FIRST thing the substitution does, before the pipeline is
  # built: sort/head/cut are children of this subshell too, and a `cut` holding
  # the inherited descriptor reported itself as the holder the first time this
  # was written with the close one level further in.
  out=$(
      exec 8>&- 9>&-
      {
      real=$(readlink -f "$target" 2>/dev/null)
      [ -n "$real" ] || real="$target"
      for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue
        for fd in "$p"/fd/*; do
          link=$(readlink "$fd" 2>/dev/null) || continue
          [ "$link" = "$real" ] || continue
          info=$(ps -o etimes=,args= -p "$pid" 2>/dev/null | head -1)
          [ -n "$info" ] || break
          read -r age args <<<"$info"
          case "${age:-}" in ''|*[!0-9]*) age=0 ;; esac
          printf '%s\tpid=%s age=%ss cmd=%.100s\n' "$age" "$pid" "$age" "${args:-?}"
          break
        done
      done
      } 2>/dev/null | sort -rn | head -3 | cut -f2- )
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}
