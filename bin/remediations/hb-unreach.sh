#!/bin/bash
# Remediation handler — akey hb-unreach:<box>:<utc-hour>
#
# DORMANT SINCE BH-1031 (state→DB slice 6), kept deliberately: bin/fleet-heartbeat.sh
# was the only producer of this akey and it is deleted — box liveness is now the
# `lanes` row, which needs no ssh and cannot be fooled by one dropped
# connection. The handler stays because it is correct for any lane that emits
# the family again, and a re-probe is the right answer whenever one does.
#
# fleet-heartbeat paged the first time a box missed one ssh probe. A single
# missed probe is usually the network, not the box: a reboot, a Tailscale
# re-key, one dropped connection. Re-probe once after a short pause. Reachable
# -> exit 0. Still down -> non-zero and it pages exactly as today, which is the
# case that actually needs a human.
# READ-ONLY: runs `true` on the far box, nothing else.
set -uo pipefail
AKEY="${1:-}"
HOST=$(cut -d: -f2 <<<"$AKEY")
case "$HOST" in ''|*[!A-Za-z0-9._-]*) echo "no box in akey"; exit 1 ;; esac

# Seam for tests only; the fleet always uses the 15s default.
sleep "${REM_REPROBE_SLEEP:-15}"
if timeout 25 ssh -n -o BatchMode=yes -o ConnectTimeout=8 \
     -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "root@$HOST" true 2>/dev/null; then
  echo "$HOST: reachable on re-probe — transient ssh blip"
  exit 0
fi
echo "$HOST: still unreachable on re-probe — alerting"
exit 1
