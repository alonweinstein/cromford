#!/bin/sh
# fly/testhost/entrypoint.sh — boot of a bh-testhost-example-org machine (#1597).
#
# THE TEST HOSTS SHIPPED WITHOUT THE TMPFS THE DOCS PROMISED. /srv/tmp was the
# machine's 7.8 GB root overlay, and bin/remote-gate.sh's runs filled it. The
# gate now mounts the tmpfs itself (its prep job, under a lock, only when
# nothing is on /srv/tmp), sized by the settings row lib.remote-gate.
# remote_gate_tmpfs_size. This entrypoint is the boot-time half:
#
#   1. Nothing can be live at boot, so the litter the gate's sweep is written to
#      find — everything under /srv/tmp, and /tmp's tmp.* and scratch.* — goes
#      now, before sshd hands out the first session. That alone guarantees the
#      FIRST gate run after a boot finds /srv/tmp empty and mounts the tmpfs.
#   2. When the machine's env carries REMOTE_GATE_TMPFS_SIZE (the deploy step
#      in docs/REMOTE-GATE.md passes the row's value), the tmpfs is mounted here
#      and no run ever lands on the root disk at all. With no value nothing is
#      guessed: step 1 has already made the first run's mount certain.
#
# It never fails the boot: every step is best effort, and a machine that cannot
# mount still serves runs exactly as it did before (the gate warns per run).
set -u
SIZE="${REMOTE_GATE_TMPFS_SIZE:-}"

mkdir -p /srv/tmp /srv/runs
# UNDER THE SAME LOCK THE GATE'S PREP TAKES (#1604 review, I3). Fly's ssh
# server does not wait for this CMD, so a gate that started this machine can be
# creating its run dir while the wipe runs; the prep and the run-dir mkdir both
# hold /srv/tmp.mount.lock, so they now wait for the wipe and the mount, and the
# wipe never removes (or the mount never hides) a run that is being set up.
exec 9>/srv/tmp.mount.lock
flock 9 2>/dev/null || echo "testhost-entrypoint: could not take /srv/tmp.mount.lock; wiping unlocked"
if ! findmnt -n -t tmpfs /srv/tmp >/dev/null 2>&1; then
  # Only what predates this boot: a run dir a gate made after the machine came
  # up (before this entrypoint got the lock) is live, not litter.
  up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
  case "$up" in
    ''|*[!0-9]*) echo "testhost-entrypoint: no /proc/uptime; not wiping /srv/tmp (the gate's sweep will)" ;;
    *) find /srv/tmp -mindepth 1 -maxdepth 1 ! -newermt "@$(( $(date +%s) - up ))" -exec rm -rf {} + 2>/dev/null ;;
  esac
  left=$(find /srv/tmp -mindepth 1 ! -path /srv/tmp/runs -print -quit 2>/dev/null)
  [ -z "$left" ] || { echo "testhost-entrypoint: $left appeared since boot; not mounting over it (the first quiet gate run mounts)"; SIZE=""; }
  case "$SIZE" in
    [1-9]*)
      if printf '%s' "$SIZE" | grep -Eq '^[1-9][0-9]*[kKmMgG]?$'; then
        mount -t tmpfs -o "size=$SIZE" tmpfs /srv/tmp 2>/dev/null \
          && echo "testhost-entrypoint: mounted a $SIZE tmpfs on /srv/tmp" \
          || echo "testhost-entrypoint: mount -t tmpfs -o size=$SIZE failed; the first gate run retries"
      else
        echo "testhost-entrypoint: REMOTE_GATE_TMPFS_SIZE='$SIZE' is not a mount size; the first gate run mounts /srv/tmp"
      fi ;;
    *) echo "testhost-entrypoint: no REMOTE_GATE_TMPFS_SIZE in the machine env; the first gate run mounts /srv/tmp" ;;
  esac
fi
mkdir -p /srv/tmp/runs
exec 9>&-   # release the lock before the long sleep
up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
case "$up" in
  ''|*[!0-9]*) ;;
  *) find /tmp -mindepth 1 -maxdepth 1 \( -name 'tmp.*' -o -name 'scratch.*' \) ! -newermt "@$(( $(date +%s) - up ))" \
       -exec rm -rf {} + 2>/dev/null ;;
esac

exec sleep infinity
