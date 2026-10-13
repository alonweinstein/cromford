#!/bin/bash
# SCALE-PLAN wave 6a — per-build metrics. Hourly cron per box: walks build
# dirs with a RESULT, derives lifecycle timestamps + outcome from artifacts
# (no run-build.sh edits — deterministic post-hoc parse), appends one CSV row
# per build to logs/metrics.csv. The console org view (6b, local CC) ingests
# this via a `metrics` beat or scp. Idempotent via state/metrics-seen.txt.
# CSV: build_dir,project,key,started,pr_at,merged_at,result_kind,size,fix_rounds,conflict_defers,duration_min
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-metrics-collect
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off metrics-collect.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit metrics-collect
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    metrics-collect
CSV="$HARNESS/logs/metrics.csv"
SEEN="$HARNESS/state/metrics-seen.txt"; touch "$SEEN"
[ -s "$CSV" ] || echo "build_dir,project,key,started,pr_at,merged_at,result_kind,size,fix_rounds,conflict_defers,duration_min" > "$CSV"

# Refuse on an empty registry. project-of.sh resolves per build, so an
# unreadable fleet.conf does not error — it blanks the project column on every
# row written from here on, and those rows are marked seen and never revisited.
"$HARNESS/bin/fleet-projects-or-alert.sh" metrics-collect >/dev/null || exit 1

for D in "$HARNESS"/builds/*/; do
  B=$(basename "$D")
  case "$B" in ext-*|mq-*) continue ;; esac
  [ -f "$D/RESULT" ] || continue
  grep -q "^$B$" "$SEEN" && continue
  # Which project a build belongs to comes from the registry, not from a
  # four-name regex. Builds for every project enrolled after the original four
  # were landing here with an EMPTY project column — not a gap anyone notices,
  # just a project that reads as having shipped nothing, which is then what
  # reopen-metrics.sh divides by.
  P=$("$HARNESS/bin/project-of.sh" --prefix "$B" 2>/dev/null || echo "")
  KEY="$B"; [ -n "$P" ] && KEY="${B#"$P"-}"
  KEY=$(sed -E 's/-[0-9]{12}$//' <<<"$KEY")
  START=$(head -1 "$D/pipeline.log" 2>/dev/null | grep -oE '^[0-9-]+ [0-9:]+Z' || echo "")
  END=$(tail -1 "$D/pipeline.log" 2>/dev/null | grep -oE '^[0-9-]+ [0-9:]+Z' || echo "")
  PRAT=$(grep -m1 -E '\] PR( |_)' "$D/pipeline.log" 2>/dev/null | grep -oE '^[0-9-]+ [0-9:]+Z' || echo "")
  KIND=$(head -1 "$D/RESULT" | awk '{print $1}')
  MERGED=""; [ "$KIND" = "PR_MERGED" ] && MERGED="$END"
  SIZE=$(grep -oE '^SIZE: [SMLX]+L?' "$D/plan.md" 2>/dev/null | awk '{print $2}' || echo "")
  FIX=$(grep -c "FIX ROUND" "$D/pipeline.log" 2>/dev/null); FIX=${FIX:-0}
  DEFER=$(grep -c "serialized on file overlap" "$D/pipeline.log" 2>/dev/null); DEFER=${DEFER:-0}
  DUR=""
  if [ -n "$START" ] && [ -n "$END" ]; then
    DUR=$(( ($(date -d "$END" +%s 2>/dev/null || echo 0) - $(date -d "$START" +%s 2>/dev/null || echo 0)) / 60 ))
    [ "$DUR" -lt 0 ] && DUR=""
  fi
  echo "$B,$P,$KEY,$START,$PRAT,$MERGED,$KIND,$SIZE,$FIX,$DEFER,$DUR" >> "$CSV"
  echo "$B" >> "$SEEN"
done
tail -2000 "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
exit 0
