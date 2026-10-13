#!/bin/bash
# Remediation handler — akey health:hungmachine:<machine-id>
#
# pipeline-health pages when a pool machine spawned >3.5h ago was never reaped
# and shows no artifact movement. The machine being GONE produces exactly that
# shape: a destroyed machine never earns a "reaped" line, so the ghost paged
# every tick for a day (project-3 2862174f059658, 2026-08-24/25).
#
# Ask Fly. destroyed / stopped / purged means gone, not hung -> exit 0. Anything
# else (including "cannot ask Fly") -> non-zero, and it pages exactly as today.
# READ-ONLY: this handler never touches the machine.
set -uo pipefail
H="${HARNESS:-/root/harness}"
AKEY="${1:-}"; LINE="${2:-}"

MID=$(cut -d: -f3 <<<"$AKEY")
case "$MID" in ''|*[!0-9a-f]*) echo "no machine id in akey"; exit 1 ;; esac

# The machine's owning project (which app, which token) comes from the alert
# line's "[pool/<project>]" tail; fall back to the pool log, which is where that
# tail was copied from in the first place. Whether that project can actually be
# asked is fly-machine-state.sh's call, not this one's.
PROJ=$(grep -oE "\[pool/[a-z0-9-]+\]" <<<"$LINE" | head -1 | tr -d '[]' | cut -d/ -f2)
[ -n "$PROJ" ] || PROJ=$(grep -F "$MID" "$H/logs/fly-pool.log" 2>/dev/null \
  | grep -oE "\[pool/[a-z0-9-]+\]" | head -1 | tr -d '[]' | cut -d/ -f2)
[ -n "$PROJ" ] || { echo "$MID: no owning project found — cannot ask Fly"; exit 1; }

STATE=$("$H/bin/fly-machine-state.sh" "$PROJ" "$MID" 2>/dev/null || echo unknown)
case "$STATE" in
  destroyed|stopped|purged)
    echo "$MID ($PROJ): Fly says state=$STATE — machine is gone, not hung"; exit 0 ;;
  *)
    echo "$MID ($PROJ): Fly says state=$STATE — not provably gone, alerting"; exit 1 ;;
esac
