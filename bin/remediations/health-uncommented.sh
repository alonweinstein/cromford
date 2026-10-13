#!/bin/bash
# Remediation handler — akey health:uncommented:<project>:<n>
#
# pipeline-health pages when a build has a RESULT and no COMMENTED marker after
# an hour: "the sweep is not clearing them". That reads as a wedge, but some
# verdicts are END states the close-out sweep has no handler for and never will
# — a project-1 build came back BUILD_DEFERRED (duplicate of an owner-side build)
# and paged forever because nothing was ever going to comment it out.
#
# Terminal, for this lane's purposes:
#   BUILD_DEFERRED with no resume attempt spent — resume-dead-builds refunds and
#     retries a deferral it caused (resume-attempts > 0); an ORIGINAL deferral it
#     explicitly leaves alone, so nobody closes it out. That is an end state.
#   BUILD_REFUSED while flags/pool-halt-<project> is set — the refusal already
#     tripped its own brake and pages under its own key; this is the echo.
#   QUEUED_FLY with a newer exact-key pool result carrying RELAYED — the local
#     dir is a routing stub and the owning box has custody of the real result.
#   a SUPERSEDED marker in the build dir.
# Exit 10 (terminal) only when EVERY uncommented result is one of those. One
# genuinely-pending result -> non-zero, and the alert pages exactly as today.
# READ-ONLY: reads build dirs, writes nothing.
set -uo pipefail
H="${HARNESS:-/root/harness}"
# BH-1372: a halted routing row materialises flags/pool-halt-<p> before the read below.
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
AKEY="${1:-}"

PROJ=$(cut -d: -f3 <<<"$AKEY")
case "$PROJ" in ''|*[!A-Za-z0-9_-]*) echo "no project in akey"; exit 1 ;; esac

NOW=$(date -u +%s)
N=0; TERMINAL=0; VERDICTS=""; PENDING=""
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }
# Same selection as pipeline-health check 4, so the handler judges exactly the
# dirs that produced the count in the alert.
for D in "$H"/builds/"$PROJ"-* "$H"/builds/pool-"$PROJ"-*; do
  [ -d "$D" ] || continue
  [ -f "$D/RELAYED" ] && continue
  [ -f "$D/RESULT" ] && [ ! -f "$D/COMMENTED" ] || continue
  [ $(( NOW - $(stat -c %Y "$D/RESULT" 2>/dev/null || echo "$NOW") )) -gt 3600 ] || continue
  N=$((N+1))
  B=$(basename "$D")
  V=$(head -1 "$D/RESULT" 2>/dev/null | awk '{print $1}')
  A=$(cat "$D/resume-attempts" 2>/dev/null || echo 0)
  case "$A" in ''|*[!0-9]*) A=0 ;; esac
  if [ -f "$D/SUPERSEDED" ]; then
    TERMINAL=$((TERMINAL+1)); VERDICTS="$VERDICTS $B=SUPERSEDED"
  elif "$H/bin/queued-fly-relayed.sh" "$PROJ" "$D"; then
    TERMINAL=$((TERMINAL+1)); VERDICTS="$VERDICTS $B=QUEUED_FLY(relayed)"
  elif [ "$V" = "BUILD_DEFERRED" ] && [ "$A" -eq 0 ]; then
    TERMINAL=$((TERMINAL+1)); VERDICTS="$VERDICTS $B=BUILD_DEFERRED"
  elif [ "$V" = "BUILD_REFUSED" ] && [ -f "$H/flags/pool-halt-$PROJ" ]; then
    TERMINAL=$((TERMINAL+1)); VERDICTS="$VERDICTS $B=BUILD_REFUSED(halted)"
  else
    PENDING="$PENDING $B=${V:-empty}"
  fi
done

[ "$N" -gt 0 ] || { echo "$PROJ: no uncommented results found — condition unverifiable"; exit 1; }
[ -n "$PENDING" ] && { echo "$PROJ: $N uncommented, still owed a close-out:$PENDING"; exit 1; }
echo "$PROJ: all $TERMINAL uncommented result(s) are terminal end states:$VERDICTS"
exit 10
