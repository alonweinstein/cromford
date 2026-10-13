#!/bin/bash
# tests/conductor-cadence.bh-1389-test.sh — BH-1389: the hub merge-conductor
# cron line fires every 30 minutes, not every 5.
#
# Webhooks wake the conductor through bin/wake-loop.sh (C2) and the keyed tick
# (BH-1387) is proven live, so the cron line is a backstop and */30 is enough.
# The change is two source lines: the fragment's schedule and the registry's
# `cadence`. Both feed GENERATED files (cron/hub.cron, catalog/lanes.json; not
# committed, BH-1247), so every assertion reads the REAL renderers' output
# through tests/lib/rendered.sh — the text the hub would install.
#
#   (a) the hub render has exactly one line running merge-conductor.sh, on */30
#   (b) the composed registry's merge-conductor cadence is */30
#   (c) that line still runs the lease check and the cadence-backstop gate first
#   (d) the fragment keeps # @hub-lanes and drops the stale "Phase C" sentence
#   (e) conductor minutes {0,30} never meet the blocked-resolver's minutes
#   (f) no */5 schedule is left on any hub line running merge-conductor.sh
#
# No network, no git, nothing written outside $T.
# Run from anywhere: bash tests/conductor-cadence.bh-1389-test.sh (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/rendered.sh
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

CRON=$(rendered_cron hub) || exit 1
REG=$(rendered_registry) || exit 1
FRAG="$DIR/cron/lanes/410-merge-conductor.cron"

# Cron lines only: comments mention the script too.
grep -v '^[[:space:]]*#' "$CRON" | grep -F -- '/bin/merge-conductor.sh' > "$T/mc.txt"

# (a) one line, on */30
N=$(grep -c . "$T/mc.txt")
[ "$N" = 1 ] && ok || bad "(a) the hub render must run merge-conductor.sh on exactly one line, found $N"
SCHED=$(awk '{print $1, $2, $3, $4, $5; exit}' "$T/mc.txt")
[ "$SCHED" = '*/30 * * * *' ] && ok || bad "(a) the conductor's schedule must be '*/30 * * * *', got '$SCHED'"

# (b) the registry
CAD=$(jq -r '.lanes[] | select(.id=="merge-conductor") | .cadence' "$REG")
[ "$CAD" = '*/30 * * * *' ] && ok || bad "(b) catalog/lanes.json merge-conductor cadence must be '*/30 * * * *', got '$CAD'"

# (c) lease, then gate, then lane — on the same line
grep -qF -- '/root/harness/bin/hub-lease.sh check && { /root/harness/bin/lib/cadence-backstop.sh merge-conductor; [ $? -ne 3 ]; } && /root/harness/bin/merge-conductor.sh >> /root/harness/logs/merge-conductor-cron.log 2>&1' "$T/mc.txt" \
  && ok || bad "(c) the conductor line lost its lease check or its cadence-backstop gate: $(cat "$T/mc.txt")"

# (d) the fragment's directive and comment block
grep -qx '# @hub-lanes' "$FRAG" && ok || bad "(d) cron/lanes/410-merge-conductor.cron lost its # @hub-lanes directive"
grep -qF 'Phase C removes the sweep line' "$FRAG" \
  && bad "(d) the fragment still says 'Phase C removes the sweep line above' — the sweep line is gone (BH-1388)" || ok

# (e) minute disjointness with the blocked-resolver
expand_min() { # <minute field> — one minute per line, 0..59
  local f="$1" part m
  for part in ${f//,/ }; do
    case "$part" in
      '*')    seq 0 59 ;;
      '*/'*)  seq 0 "${part#*/}" 59 ;;
      *-*)    seq "${part%-*}" "${part#*-}" ;;
      *)      echo "$part" ;;
    esac
  done
}
grep -v '^[[:space:]]*#' "$CRON" | grep -F -- '/bin/blocked-resolver.sh' > "$T/br.txt"
[ -s "$T/br.txt" ] && ok || bad "(e) no blocked-resolver line in the hub render — nothing to check disjointness against"
expand_min "$(awk '{print $1; exit}' "$T/mc.txt")" | sort > "$T/mc.min"
[ "$(tr '\n' ' ' < "$T/mc.min")" = '0 30 ' ] && ok || bad "(e) conductor minutes must be {0,30}, got $(tr '\n' ' ' < "$T/mc.min")"
awk '{print $1}' "$T/br.txt" | while read -r f; do expand_min "$f"; done | sort > "$T/br.min"
BOTH=$(comm -12 "$T/mc.min" "$T/br.min" | tr '\n' ' ')
[ -z "$BOTH" ] && ok || bad "(e) the conductor and the blocked-resolver share minute(s): $BOTH"

# (f) no */5 left on the conductor
grep -q '^\*/5 ' "$T/mc.txt" && bad "(f) a */5 schedule is still on a merge-conductor.sh line" || ok

echo "conductor-cadence.bh-1389: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
