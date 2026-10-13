#!/bin/bash
# bin/gh-ledger-push.sh [box-id] — BH-1574: EVERY box, every 10 minutes (and every
# Fly builder, from fly/builder-runner.sh): fold the GitHub-call ledger this box
# wrote — state/gh-rest-ledger/<hour>.tsv, from gh_rest and from the PATH shim
# bin/gh-ledger/gh — into hourly aggregates and upsert them into the harness-jobs
# gh_ledger table, so bin/gh-quota-report.sh can answer for the whole fleet.
#
# WHY. The hub App installation's 6,600/h bucket is shared by the hub, seven
# boxes and the pool, and the report read only the files of the box it ran on:
# 2026-09-23's "~5,000/h unaccounted" was mostly other boxes' ledgers that
# nothing summed. The files stay the truth on each box (swept at 48h by
# gh_quota_ledger_sweep); this is a one-way copy of their aggregates.
#
# WHAT IS SENT. Per (hour, caller, project, token meter, bucket, method, path
# class, status, source): calls, counted, and the header extremes of that hour
# (lowest remaining, highest used / limit / reset). A line written before
# BH-1574 (10 columns) lands with bucket `-` and source `rest`.
#
# WHEN. An hour file is re-sent WHOLE whenever its size differs from the size
# last sent successfully (state/gh-ledger-push.sent). Size, never mtime: a push
# and an append in the same second must not lose the append, and the worker's
# upsert makes a whole-hour re-send a correction rather than a double count.
# The size recorded is the one read BEFORE aggregating, so a line appended
# mid-push only makes the next tick send that hour again.
#
# FAIL-OPEN, like every jobs-client producer: a worker outage costs a delay, never
# a row — nothing is marked sent until every chunk got a 2xx, the next tick
# re-sends, and the third consecutive failure writes ONE line to ALERTS.log.
#
# Switches: flags/gh-ledger-push-off (or the `switch.gh-ledger-push-off` settings
# row) (and the lane gate's lane-off-gh-ledger-push
# / all-off). The box id comes from argv (the cron line passes the id its
# crontab is rendered for; the builder passes pool-<project>-<machine>), then
# bin/lib/box-id.sh — never a bare hostname (every Orgo box answers the same).
#
# rc 0 always from the cron path (a quiet tick and a failed one both exit 0 and
# say so in logs/gh-ledger-push.log), 2 on a bad argument.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

BOX=""
case "${1:-}" in
  -*) echo "usage: gh-ledger-push.sh [box-id]" >&2; exit 2 ;;
  *)  BOX=$(printf '%s' "${1:-}" | tr -dc 'A-Za-z0-9._-') ;;
esac
if [ -z "$BOX" ]; then
  # shellcheck source=bin/lib/box-id.sh
  . "$H/bin/lib/box-id.sh" 2>/dev/null || true
  command -v box_id_require >/dev/null 2>&1 && BOX=$(box_id_require gh-ledger-push)
fi
[ -n "$BOX" ] || exit 0

LED="$H/state/gh-rest-ledger"
SENT="$H/state/gh-ledger-push.sent"
FAILS="$H/state/gh-ledger-push.fails"
LOG="$H/logs/gh-ledger-push.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# The worker's own per-request ceiling (worker/jobs/src/routes/gh-ledger.js
# GH_LEDGER_MAX_ROWS) — a wire bound, not a tunable.
CHUNK_ROWS=2000

# Nothing ledgered on this box yet is not an event.
[ -d "$LED" ] || exit 0
mkdir -p "$H/state" "$H/logs" "$H/locks" 2>/dev/null

# global.env is sourced HERE because cron does not — HARNESS_SECRET and JOBS_URL
# live there. `+u` around it: an unbound reference in the env file must not kill
# the pusher silently.
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-gh-ledger-push
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment. Both fail OPEN.
# Registry: catalog/lanes.d/gh-ledger-push.json. Operator: bin/harness-ctl.sh off gh-ledger-push.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit gh-ledger-push
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    gh-ledger-push

# shellcheck source=bin/lib/lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
lane_switch gh-ledger-push-off file && exit 0
[ -f "$H/bin/jobs-client.sh" ] || exit 0
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh"

exec 9>"$H/locks/gh-ledger-push.lock"
flock -n 9 || exit 0

# ── which hour files moved since the last successful push ───────────────────
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-ledger-push.XXXXXX") || exit 0
trap 'rm -rf "$WORK"' EXIT
FILES=()
: > "$WORK/sizes"
for f in "$LED"/*.tsv; do
  [ -f "$f" ] || continue
  n=${f##*/}
  sz=$(wc -c < "$f" 2>/dev/null | tr -dc '0-9')
  [ -n "$sz" ] || continue
  printf '%s %s\n' "$n" "$sz" >> "$WORK/sizes"
  last=$(awk -v n="$n" '$1 == n { print $2 }' "$SENT" 2>/dev/null | tail -1)
  [ "$last" = "$sz" ] && continue
  FILES+=("$f")
done
[ "${#FILES[@]}" -gt 0 ] || exit 0

# ── fold the lines into aggregates (TSV, one row per key) ───────────────────
# Unknown numbers stay EMPTY and become null — an unread header is never 0.
awk -F'\t' '
  function num(v) { return (v ~ /^[0-9]+$/) ? v + 0 : "" }
  function col(i, d) { return (NF >= i && $i != "") ? $i : d }
  NF >= 7 {
    hour = substr($1, 1, 13)
    if (hour !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]$/) next
    k = hour "\t" col(2, "-") "\t" col(3, "-") "\t" col(10, "-") "\t" col(11, "-") "\t" \
        col(4, "-") "\t" col(5, "-") "\t" col(6, "000") "\t" col(12, "rest")
    if (!(k in calls)) order[++nk] = k
    calls[k]++; counted[k] += ($7 ~ /^[0-9]+$/ ? $7 : 0)
    r = num(col(8, "")); if (r != "" && (!(k in rmin) || r < rmin[k])) rmin[k] = r
    u = num(col(13, "")); if (u != "" && (!(k in umax) || u > umax[k])) umax[k] = u
    l = num(col(14, "")); if (l != "" && (!(k in lmax) || l > lmax[k])) lmax[k] = l
    t = num(col(9, ""));  if (t != "" && (!(k in tmax) || t > tmax[k])) tmax[k] = t
  }
  END {
    for (i = 1; i <= nk; i++) {
      k = order[i]
      printf "%s\t%d\t%d\t%s\t%s\t%s\t%s\n", k, calls[k], counted[k], rmin[k], umax[k], lmax[k], tmax[k]
    }
  }' "${FILES[@]}" > "$WORK/agg.tsv" 2>/dev/null
NROWS=$(grep -c . "$WORK/agg.tsv" 2>/dev/null); NROWS="${NROWS:-0}"
[ "$NROWS" -gt 0 ] || exit 0
split -l "$CHUNK_ROWS" "$WORK/agg.tsv" "$WORK/chunk." 2>/dev/null

# ── send every chunk; mark sent only when all of them landed ────────────────
OKALL=1
for c in "$WORK"/chunk.*; do
  [ -s "$c" ] || continue
  jq -R -s --arg box "$BOX" '
    def n: if . == "" then null else tonumber end;
    {box: $box, rows: [split("\n")[] | select(length > 0) | split("\t") | {
      hour: .[0], lane: .[1], project: .[2], meter: .[3], resource: .[4],
      method: .[5], path_class: .[6], status: .[7], source: .[8],
      calls: (.[9] | tonumber), counted: (.[10] | tonumber),
      remaining_min: (.[11] | n), used_max: (.[12] | n),
      limit_max: (.[13] | n), reset_max: (.[14] | n)}]}' "$c" > "$c.json" 2>/dev/null \
    || { OKALL=0; break; }
  _jobs_req_file POST /api/metrics/gh-ledger "$c.json" > /dev/null || { OKALL=0; break; }
done

if [ "$OKALL" = 1 ]; then
  # The sizes read BEFORE the fold, for every file still on disk: a swept hour
  # drops out of the state on its own.
  cp "$WORK/sizes" "$SENT.tmp.$$" 2>/dev/null && mv -f "$SENT.tmp.$$" "$SENT"
  rm -f "$FAILS"
  echo "$(STAMP) [$BOX] pushed $NROWS aggregate row(s) from ${#FILES[@]} hour file(s)" >> "$LOG"
  exit 0
fi
N=$(tr -dc '0-9' < "$FAILS" 2>/dev/null); N=$((${N:-0} + 1))
echo "$N" > "$FAILS"
echo "$(STAMP) [$BOX] push FAILED (consecutive: $N; http=${JOBS_HTTP}) — ${#FILES[@]} hour file(s) still owed, will retry next tick" >> "$LOG"
if [ "$N" -eq 3 ]; then
  echo "$(STAMP) [$BOX] gh-ledger-push: 3 consecutive failed pushes to $JOBS_URL/api/metrics/gh-ledger (http=${JOBS_HTTP}). The box's ledger files are intact; the fleet GitHub-call report is missing this box. Check the harness-jobs worker deploy + HARNESS_SECRET; see $LOG." >> "$H/logs/ALERTS.log"
fi
exit 0
