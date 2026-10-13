#!/bin/bash
# One-shot: waits for the build queue to drain, then quiesces the harness so
# the operator can resize the Orgo VM safely. Launched by the orchestrator 2026-07-22.
# `--resume` (after the resize) lifts the pauses this script put on THIS box.
set -u
H="${HARNESS:-/root/harness}"
Q=$H/logs/READY-QUEUE.log
LOG=$H/logs/quiesce.log
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# >>> resume
# Drops only this box's local holds (flag_clear --local-only); a pause someone
# wrote as a row is the row's, and stays.
if [ "${1:-}" = --resume ]; then
  PROJECTS=$("$H/bin/fleet-projects-or-alert.sh" quiesce) || {
    echo "$(STAMP) resume: empty project list, nothing lifted" >> "$LOG"
    exit 1
  }
  # shellcheck source=bin/jobs-client.sh
  [ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
  for p in $PROJECTS; do
    if command -v flag_clear >/dev/null 2>&1; then flag_clear --local-only "paused-$p" >/dev/null 2>&1
    else rm -f "$H/flags/paused-$p"; fi
  done
  echo "$(STAMP) RESUMED — this box's quiesce pauses lifted" >> "$LOG"
  echo RESUMED
  exit 0
fi
# <<< resume
echo "$(STAMP) quiesce watcher started" >> "$LOG"

# 1. Wait until: no run-build in flight AND queue has no ticket lines
#    (ignore the NOTE header line; queue lines start with a ticket key like TK-/TK-/TK-)
while true; do
  building=$(pgrep -c -f 'bin/run-build.sh' || true)
  pending=$(grep -cE '^[A-Z]+-[0-9]+' "$Q" 2>/dev/null || echo 0)
  if [ "$building" -eq 0 ] && [ "$pending" -eq 0 ]; then
    # settle window: re-check after 10 min so a watcher mid-pickup isn't missed
    sleep 600
    building=$(pgrep -c -f 'bin/run-build.sh' || true)
    pending=$(grep -cE '^[A-Z]+-[0-9]+' "$Q" 2>/dev/null || echo 0)
    [ "$building" -eq 0 ] && [ "$pending" -eq 0 ] && break
  fi
  sleep 300
done
echo "$(STAMP) queue drained, no builds in flight — quiescing" >> "$LOG"

# 2. Pause all watchers
# >>> pause all
# Every registry project. A watcher this loop does not name is a watcher that
# keeps launching builds into a box being resized out from under it — and an
# EMPTY list is the worst version of that: the loop runs zero times, the script
# carries on, and prints SAFE_TO_RESIZE having paused nobody. There is no set -e
# here to catch it, so the list is read once and checked before any flag moves.
PROJECTS=$("$H/bin/fleet-projects-or-alert.sh" quiesce) || {
  echo "$(STAMP) FATAL: empty project list — NOT quiescing, NOT safe to resize" >> "$LOG"
  exit 1
}
# BH-4153: a LOCAL hold on paused-<p> (flag_set --local-only), never the
# fleet row. The resize stops THIS box; a paused-<p> row would stop every box
# and the worker's claim-time pause check for all of them. A row written after
# the hold (a console pause or resume) still wins, and `--resume` lifts it.
# No client: the file, as before (box-local too).
# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
for p in $PROJECTS; do
  if command -v flag_set >/dev/null 2>&1; then
    flag_set --local-only "paused-$p" on "quiesce-for-resize" >/dev/null 2>&1 \
      || echo "$(STAMP) paused-$p: the local hold was not written" >> "$LOG"
  else
    touch "$H/flags/paused-$p"   # no client: the legacy file
  fi
done
# <<< pause all

# 3. Let any in-flight triage session finish
sleep 180

# 4. Push every non-main local branch that isn't on the remote yet (never main).
# These are ticket branches, so each push goes through bin/lib/hold-push.sh
# (BH-2504): a held ticket's branch is left local, and the lease is what origin
# held when this looked (`new` when origin has no such branch).
# shellcheck source=bin/lib/hold-push.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/hold-push.sh" 2>/dev/null || . "$H/bin/lib/hold-push.sh"
for r in /root/repos/*; do
  [ -d "$r/.git" ] || continue
  cd "$r"
  for b in $(git for-each-ref --format='%(refname:short)' refs/heads | grep -vx main); do
    if ! rsha=$(git rev-parse --verify -q "origin/$b"); then rsha=new
    elif [ -z "$(git rev-list "origin/$b..$b" 2>/dev/null)" ]; then continue
    # A fast-forward only, as the plain push this replaced was: a lease would
    # otherwise let a diverged local copy overwrite what origin holds.
    elif ! git merge-base --is-ancestor "origin/$b" "$b" 2>/dev/null; then
      echo "$(STAMP) NOT pushed $r $b: it has diverged from origin/$b" >> "$LOG"; continue; fi
    HOLD_PUSH_LOG="$LOG" hold_push "$(basename "$r")" - "$r" origin "$b" "$b" "$rsha" >> "$LOG" 2>&1 \
      && echo "$(STAMP) pushed $r $b" >> "$LOG"
  done
done

# 5. Consistent local snapshot of harness state (same disk — consistency point, not offsite backup)
mkdir -p "$H/backups"
SNAP="$H/backups/harness-pre-resize-$(date -u +%Y%m%d%H%M).tgz"
tar czf "$SNAP" -C /root harness/env harness/state harness/logs harness/prompts harness/bin harness/flags 2>>"$LOG"
chmod 600 "$SNAP"

echo "$(STAMP) QUIESCED — watchers paused on this box, branches pushed, snapshot $SNAP. Safe to resize. After it: bin/quiesce-for-resize.sh --resume" >> "$LOG"
echo "SAFE_TO_RESIZE $SNAP"
