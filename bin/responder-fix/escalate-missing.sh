#!/bin/bash
# bin/responder-fix/escalate-missing.sh <condition> <project> — the scripted
# remedy for the responder's `evidence_missing` condition (BH-2548).
#
# Items arrive on stdin, one `<project>\t<key>\t<why the evidence is missing>`
# per line, all for <project>. It sends ONE fleet_alert beat naming them — the
# escalation the tooled pass was forced to make on a MISSING item ("evidence
# unavailable"), without buying a decision call and a tooled call to write it.
# The akey is per project per UTC hour, so a re-send inside the hour collapses.
#
# Exit code is beat.sh's under BEAT_STRICT=1: a beat that did not land is rc≠0,
# and bin/lib/responder-fix.sh then hands the items to the model instead of
# stamping them handled. Selected by the settings row
# lane.watchdog-responder.responder_fix_evidence_missing (default: this script).
set -uo pipefail
H="${HARNESS:-/root/harness}"
COND="${1:-}"; P="${2:-}"
[ -n "$COND" ] && [ -n "$P" ] || { echo "usage: escalate-missing.sh <condition> <project> < items" >&2; exit 64; }
KEYS=""; WHY=""
while IFS=$'\t' read -r IP IK ID; do
  [ -n "${IK:-}" ] || continue
  KEYS="${KEYS:+$KEYS, }${IP}:${IK}"
  [ -z "$WHY" ] && WHY="${ID:-reason not recorded}"
done
[ -n "$KEYS" ] || { echo "escalate-missing.sh: no items on stdin" >&2; exit 65; }
PAYLOAD=$(jq -nc --arg p "$P" --arg k "responder:missing:$P:$(date -u +%Y%m%d%H)" \
  --arg l "RESPONDER: evidence unavailable for $KEYS ($WHY). The board could not be read this pass, so nothing was decided on these tickets. Check the $P board API and token." \
  '{kind:"fleet_alert", project:$p, akey:$k, line:$l}') || exit 70
BEAT_STRICT=1 "$H/bin/beat.sh" "$PAYLOAD"
