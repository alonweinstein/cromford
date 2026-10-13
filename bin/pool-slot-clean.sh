#!/bin/bash
# bin/pool-slot-clean.sh — free a pool machine's build slots before it takes a
# new build (BH-5021). Runs ON THE MACHINE.
#
# BH-4973, a hotfix, deferred three times on reused machines with
# `BUILD_DEFERRED all 1 slots busy`: a process from the previous build (or a
# grandchild that inherited its fd 8) still held locks/build-slot-1.lock. A pool
# machine runs one job at a time, so between jobs nothing may hold a slot, and
# whatever does is a stray. This finds it, logs it, and kills its process tree.
#
# Usage: pool-slot-clean.sh [--harness <dir>]   (default ${HARNESS:-/data/harness})
# Two callers, one output contract — ONE line on stdout:
#   SLOTCLEAN ok clean                     nothing held a slot          exit 0
#   SLOTCLEAN ok cleaned=<n> pids=<list>   holders killed, slots free   exit 0
#   SLOTCLEAN held lock=<name> pids=<list> still held after the kill    exit 1
#   SLOTCLEAN unreadable <why>             no /proc or no flock         exit 2
#   - bin/fly-pool.sh next_job_or_destroy, before a reuse handoff: held ->
#     destroy the machine instead of reusing it.
#   - fly/builder-runner.sh slot_preflight, before warm-up: held -> defer a plain
#     build at once (a hotfix goes on and takes run-build's extra slot).
#
# A lock is HELD only when `flock -n` says so: an fd open on the file without a
# lock is not a holder. Holders are found by their /proc/<pid>/fd links, so a
# /root/harness -> /data/harness symlink resolves. This script, PID 1 and every
# ancestor of this script are never signalled; an ancestor that holds a slot is
# reported held. Each holder is logged BEFORE it is signalled, one line per pid
# to stderr and <harness>/logs/pool-slot-clean.log, argv secrets redacted. The
# tree goes children first: TERM, POOL_SLOT_CLEAN_GRACE_S (default 5) to exit,
# then KILL. Lock files are never deleted; a free lock file is harmless.
# POOL_SLOT_CLEAN_GRACE_S is an operational timing on a machine that reads no
# settings rows, an env override with the default above (the PROJECT_2_EVENT_PAGES
# precedent), not a business parameter.
set -uo pipefail

H="${HARNESS:-/data/harness}"
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) H="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "usage: pool-slot-clean.sh [--harness <dir>]" >&2; exit 2 ;;
  esac
done
GRACE="${POOL_SLOT_CLEAN_GRACE_S:-5}"
case "$GRACE" in ''|*[!0-9]*) GRACE=5 ;; esac
LOG="$H/logs/pool-slot-clean.log"

[ -r /proc/self/status ] || { echo "SLOTCLEAN unreadable no /proc"; exit 2; }
command -v flock >/dev/null 2>&1 || { echo "SLOTCLEAN unreadable no flock"; exit 2; }

LOCKS=()
for l in "$H"/locks/build-slot-*.lock; do [ -e "$l" ] && LOCKS+=("$l"); done
[ "${#LOCKS[@]}" -gt 0 ] || { echo "SLOTCLEAN ok clean"; exit 0; }

# held <lock> -> 0 held, 1 free. A lock that cannot even be opened counts as
# held: a slot this script cannot prove free is not handed to a build.
held() { local rc=0; flock -n -E 75 "$1" true 2>/dev/null || rc=$?; [ "$rc" != 0 ]; }

# This shell may have inherited a slot fd from a caller. Close it first, so no
# child of this script holds a slot because this script did.
for f in /proc/$$/fd/*; do
  n=${f##*/}
  case "$n" in 0|1|2|255|*[!0-9]*) continue ;; esac
  t=$(readlink "$f" 2>/dev/null) || continue
  case "$t" in */locks/build-slot-*.lock) eval "exec $n>&-" ;; esac
done

say_log() { # one line to stderr and the log
  local line; line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
  printf '%s\n' "$line" >&2
  mkdir -p "$H/logs" 2>/dev/null && printf '%s\n' "$line" >> "$LOG" 2>/dev/null
  return 0
}

# pid -> ppid, every process, read once.
declare -A PPID_OF=()
while read -r p pp; do PPID_OF[$p]=$pp; done < <(
  cat /proc/[0-9]*/status 2>/dev/null | awk '/^Pid:/{p=$2} /^PPid:/{print p, $2}')
declare -A KEEP=([1]=1 [$$]=1)
a=$$
while [ -n "${PPID_OF[$a]:-}" ] && [ "${PPID_OF[$a]}" != 0 ]; do a=${PPID_OF[$a]}; KEEP[$a]=1; done
# A child of this script (a $(...) or a pipeline) is ours too.
ours() { local x=$1 i=0; while [ -n "$x" ] && [ "$x" != 0 ] && [ "$i" -lt 64 ]; do [ "$x" = $$ ] && return 0; x=${PPID_OF[$x]:-}; i=$((i+1)); done; return 1; }

gone() { # gone <pid> -> 0 when it has exited (a zombie has, and its fds are closed)
  [ -r "/proc/$1/stat" ] || return 0
  [ "$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" = Z ]
}
age_of() {
  local st up tck
  st=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20)
  up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null); up=${up%.*}
  tck=$(getconf CLK_TCK 2>/dev/null || echo 100)
  case "$st$up$tck" in ''|*[!0-9]*) echo "?"; return ;; esac
  echo $(( up - st / tck ))
}
cmd_of() { # argv as one line, secrets redacted, then cut to 200 chars
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null \
    | sed -E 's/([A-Za-z0-9_]*(TOKEN|SECRET|KEY|PASSWORD)[A-Za-z0-9_]*)=[^ ]*/\1=<redacted>/gI' | head -c 200
}
descendants() { # post-order: deepest first, so a tree dies children first
  local c
  for c in "${!PPID_OF[@]}"; do
    [ "${PPID_OF[$c]}" = "$1" ] && { descendants "$c"; echo "$c"; }
  done
}

# Every fd link on the machine, read once: "<pid> <target>".
FDS=$(find /proc/[0-9]*/fd -maxdepth 1 -type l -printf '%h %l\n' 2>/dev/null | sed -E 's#^/proc/([0-9]+)/fd #\1 #')

TARGETS=(); KILLED=(); declare -A SEEN=()
for l in "${LOCKS[@]}"; do
  held "$l" || continue
  real=$(readlink -f "$l"); base=${l##*/}
  while read -r p _; do
    [ -n "$p" ] || continue
    [ -z "${SEEN[$p]:-}" ] || continue
    SEEN[$p]=1
    if [ -n "${KEEP[$p]:-}" ] || ours "$p"; then
      say_log "holder lock=$base pid=$p ppid=${PPID_OF[$p]:-?} age=$(age_of "$p") cmd=$(cmd_of "$p") (this script or its ancestor — not signalled)"
      continue
    fi
    say_log "holder lock=$base pid=$p ppid=${PPID_OF[$p]:-?} age=$(age_of "$p") cmd=$(cmd_of "$p")"
    for c in $(descendants "$p") "$p"; do
      [ -n "${KEEP[$c]:-}" ] && continue
      ours "$c" && continue
      TARGETS+=("$c")
    done
  done < <(awk -v r="$real" '{p=$1; $1=""; sub(/^ /,""); if ($0 == r) print p}' <<<"$FDS" | sort -un)
done

if [ "${#TARGETS[@]}" -gt 0 ]; then
  for p in "${TARGETS[@]}"; do kill -TERM "$p" 2>/dev/null && KILLED+=("$p"); done
  i=0
  while [ "$i" -lt $((GRACE * 5)) ]; do
    alive=0; for p in "${TARGETS[@]}"; do gone "$p" || alive=1; done
    [ "$alive" = 0 ] && break
    sleep 0.2; i=$((i+1))
  done
  for p in "${TARGETS[@]}"; do gone "$p" || { say_log "pid=$p ignored TERM for ${GRACE}s — KILL"; kill -KILL "$p" 2>/dev/null; }; done
fi

# The re-probe is the truth. A killed holder's fds close as it exits, so give
# the kernel a moment before calling a slot still held.
STILL=""; i=0
while :; do
  STILL=""
  for l in "${LOCKS[@]}"; do held "$l" && { STILL=${l##*/}; break; }; done
  [ -z "$STILL" ] && break
  [ "${#TARGETS[@]}" -gt 0 ] && [ "$i" -lt 10 ] || break
  sleep 0.2; i=$((i+1))
done
PIDS=$(IFS=,; echo "${KILLED[*]:-}")
if [ -n "$STILL" ]; then
  HP=""; for p in "${!SEEN[@]}"; do HP="${HP:+$HP,}$p"; done
  say_log "SLOTCLEAN held lock=$STILL pids=${HP:-unknown}"
  echo "SLOTCLEAN held lock=$STILL pids=${HP:-unknown}"
  exit 1
fi
if [ "${#KILLED[@]}" -gt 0 ]; then
  say_log "SLOTCLEAN ok cleaned=${#KILLED[@]} pids=$PIDS"
  echo "SLOTCLEAN ok cleaned=${#KILLED[@]} pids=$PIDS"
else
  echo "SLOTCLEAN ok clean"
fi
exit 0
