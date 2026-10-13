#!/bin/bash
# bin/cost-caps-seed-sync.sh — keep the registry-seed cap rows on the reviewed
# catalog files (BH-4155 review F1/B1). Exit 0 on every path.
#
# WHY. Since BH-4155 a `registry-seed` row for conf.cost-caps.* /
# conf.lane-caps.* binds ABOVE catalog/cost-caps.conf and catalog/lane-caps.conf
# (bin/lib/cost-budget.sh, bin/lib/lane-caps.sh), and worker/jobs/schema.sql
# seeds those rows INSERT OR IGNORE, which never moves a row that exists. So
# without this hook a reviewed commit that tightens a cap in the catalog merges,
# reaches every box, and changes no running cap: the old seed row keeps
# answering above it. bin/cost-caps-seed.sh is the one path that moves a seed
# row (POST /api/cost-caps/seed: insert absent, follow moved, prune missing,
# never an operator row), and until this hook it was run by hand.
#
# WHEN. bin/harness-sync.sh runs it after the worker phase on the box that holds
# cloudflare.env (the hub), i.e. on every deploy there. Keyed on the CONTENT of
# the two live catalog files, not on a commit: state/cost-caps-seeded holds the
# sha256 of the pair the last successful seed sent, so a sync that changes
# neither file costs one sha256sum and sends nothing.
#
# FAILURE. No stamp, so the next harness-sync retries. One ALERTS line per
# catalog content (state/cost-caps-seed-alerted holds the hash it alerted for),
# not one per five-minute sync. Either file missing: nothing to seed, silent
# (bin/cost-caps-seed.sh would refuse, and C1 deletes both files with this hook).
#
# AUDIT. Every run that sends appends the seed's own changed_keys/pruned_keys
# answer to logs/cost-caps-seed-sync.log, so a cap the catalog moved names the
# keys it moved next to the commit that moved them.
set -uo pipefail
H="${HARNESS:-/root/harness}"
LOG="$H/logs/cost-caps-seed-sync.log"
STAMPF="$H/state/cost-caps-seeded"
ALERTF="$H/state/cost-caps-seed-alerted"
COST_F="$H/catalog/cost-caps.conf"
LANE_F="$H/catalog/lane-caps.conf"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

[ -r "$COST_F" ] && [ -r "$LANE_F" ] || exit 0
[ -x "$H/bin/cost-caps-seed.sh" ] || exit 0
SUM=$(cat "$COST_F" "$LANE_F" | sha256sum | cut -d' ' -f1)
[ -n "$SUM" ] || exit 0
[ "$(cat "$STAMPF" 2>/dev/null)" = "$SUM" ] && exit 0

mkdir -p "$H/logs" "$H/state" 2>/dev/null
OUT=$(HARNESS="$H" timeout "${COST_CAPS_SEED_TIMEOUT_S:-60}" "$H/bin/cost-caps-seed.sh" 2>&1)
RC=$?
if [ "$RC" -eq 0 ]; then
  printf '%s\n' "$SUM" > "$STAMPF.tmp" && mv -f "$STAMPF.tmp" "$STAMPF"
  rm -f "$ALERTF"
  { echo "$(STAMP) seeded catalog ${SUM:0:12}"; printf '%s\n' "$OUT" | sed 's/^/  /'; } >> "$LOG"
  exit 0
fi
{ echo "$(STAMP) seed FAILED rc=$RC for catalog ${SUM:0:12}"; printf '%s\n' "$OUT" | sed 's/^/  /'; } >> "$LOG"
if [ "$(cat "$ALERTF" 2>/dev/null)" != "$SUM" ]; then
  printf '%s\n' "$SUM" > "$ALERTF"
  HARNESS="$H" "$H/bin/alert-line.sh" "[$(hostname)] cost-caps seed did NOT land (bin/cost-caps-seed.sh rc=$RC: $(printf '%s' "$OUT" | tail -1 | head -c 200)) — the running cost/lane caps still answer the OLD registry-seed rows, not catalog/cost-caps.conf + catalog/lane-caps.conf as committed; every harness-sync on this box retries, or run bin/cost-caps-seed.sh here by hand (logs/cost-caps-seed-sync.log)" >/dev/null 2>&1 || true
fi
exit 0
