#!/bin/bash
# bin/orchestrator-burn.sh — hub cron (hourly): track the orchestrator's own
# token burn from its session transcripts, in API-equivalent dollars.
#
# Why (2026-08-24): the v1 mega-conversation burned ~$6.8K equivalent in one
# day ($1K+ extra usage on the operator's account) and nobody saw it until the bill.
# Sums today's usage blocks across /root/.claude/projects/-root-orchestrator,
# writes one row per day (upsert) to logs/orchestrator-burn.csv and ALERTs
# once per day past $150 equivalent.
set -uo pipefail
H=/root/harness
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-orchestrator-burn
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off orchestrator-burn.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit orchestrator-burn
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    orchestrator-burn
CSV="$H/logs/orchestrator-burn.csv"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
HDR="date,api_calls,fresh_in,output,cache_read,cache_write,usd_equiv,peak_cache_read,avg_cache_read"
[ -f "$CSV" ] || echo "$HDR" > "$CSV"
# ONE-TIME HEADER UPGRADE, same shape as cost.csv's 13->14 migration. Appending
# 9-field rows under the old 7-column header does not error: a reader parks the
# extra values in a restkey and the two new columns read empty forever, which
# is indistinguishable from "we never measured it". Adding a column is a
# migration even when it looks like an edit.
if [ -s "$CSV" ] && [ "$(head -1 "$CSV" | awk -F, '{print NF}')" = 7 ]; then
  { echo "$HDR"; tail -n +2 "$CSV"; } > "$CSV.up" && mv "$CSV.up" "$CSV"
fi

ROW=$(python3 - <<'PYEOF'
import json, glob, os, datetime
# UTC, NOT LOCAL. The row's date is compared against the transcripts' UTC
# timestamps below and, on the shell side, against the day key this row
# replaces. This box's local clock is UTC-5, so between 00:00 and 05:00 UTC
# `date.today()` named YESTERDAY while the shell's `date -u +%F` named today:
# the dedupe stripped rows for a day the row was not for, and each of those
# five hourly ticks APPENDED a duplicate of the previous day. Six rows a day,
# every day, from the tracker's first commit.
UTC = datetime.timezone.utc
day = datetime.datetime.now(UTC).date()
start = datetime.datetime(day.year, day.month, day.day, tzinfo=UTC)
tot = {'in':0,'out':0,'cr':0,'cw':0,'peak':0}; calls = 0
for f in glob.glob('/root/.claude/projects/-root-orchestrator/*.jsonl'):
    if datetime.datetime.fromtimestamp(os.path.getmtime(f), UTC) < start: continue
    for line in open(f, errors='replace'):
        if '"usage"' not in line: continue
        try: d = json.loads(line)
        except: continue
        ts = d.get('timestamp', '')
        if ts[:10] != str(day): continue
        u = (d.get('message') or {}).get('usage') if isinstance(d.get('message'), dict) else None
        if not u: continue
        calls += 1
        tot['in'] += u.get('input_tokens', 0); tot['out'] += u.get('output_tokens', 0)
        cr = u.get('cache_read_input_tokens', 0) or 0
        tot['cr'] += cr; tot['cw'] += u.get('cache_creation_input_tokens', 0)
        # PEAK context, not just the total. The daily cache_read sum rises with
        # legitimate volume too, so it cannot distinguish "a busy day" from "one
        # session grew to a million tokens" -- and only the second is the
        # pathology this ledger is meant to catch. The peak is the number that
        # moves when a session runs away, and the average is what it should be
        # compared against.
        if cr > tot['peak']:
            tot['peak'] = cr
usd = tot['in']/1e6*15 + tot['cw']/1e6*18.75 + tot['cr']/1e6*1.5 + tot['out']/1e6*75
avg = int(tot['cr'] / calls) if calls else 0
print(f"{day},{calls},{tot['in']},{tot['out']},{tot['cr']},{tot['cw']},{usd:.2f},{tot['peak']},{avg}")
PYEOF
) || exit 0
[ -n "$ROW" ] || exit 0
# THE ROW DECIDES WHAT IT REPLACES. Reading the day a second time, from a
# second clock, is what let the producer and the dedupe disagree — and a
# disagreement between two readings of "today" is invisible in the output,
# because a duplicate row is byte-identical to the row it duplicates. One
# reading, carried, cannot drift from itself.
DAY=$(printf '%s' "$ROW" | cut -d, -f1)
case "$DAY" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) exit 0 ;; esac
# UNDER A LOCK, AND THROUGH A TEMP FILE (BH-1032). This was `grep -v > .tmp`
# then `{ cat .tmp; echo ROW; } > $CSV` with nothing holding either step: the
# truncating redirect empties the file BEFORE the new content lands, so an
# hourly tick that overlapped a slow one (or the one-time header upgrade above)
# could read a file mid-truncation and write back a ledger with days missing,
# and a crash between the two steps left the file empty outright. Both problems
# are one flock and one atomic mv. `.tmp.$$` because two shells sharing a fixed
# `.tmp` name is the same race one level down.
#
# FAIL OPEN, NEVER CLOSED: a box without flock, or with an unwritable locks/,
# runs the rewrite unlocked exactly as it always did. An overlapping rewrite is
# a bad hour; a tracker that stops writing is a dead ledger.
mkdir -p "$H/locks" 2>/dev/null
_burn_rewrite() {
  { grep -v "^$DAY," "$CSV" 2>/dev/null || true; echo "$ROW"; } > "$CSV.tmp.$$" \
    && mv -f "$CSV.tmp.$$" "$CSV"
  rm -f "$CSV.tmp.$$"
}
if command -v flock >/dev/null 2>&1 && : 2>/dev/null > "$H/locks/orchestrator-burn.lock"; then
  ( flock -w 30 9 || true; _burn_rewrite ) 9>"$H/locks/orchestrator-burn.lock"
else
  _burn_rewrite
fi

# ── Push the day to the harness-jobs metrics ledger (2026-08-29) ────────────
# FAIL-OPEN AND AFTER THE FILE. The CSV above is written first and stays the
# local fallback; if the worker is down this block prints nothing, changes
# nothing, and the tracker behaves exactly as it did before. The DB row is keyed
# on the same day this row carries, so the hourly re-push is an upsert.
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    orchestrator-burn
if [ -f "$H/bin/jobs-client.sh" ]; then # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh"
  IFS=, read -r _d _calls _in _out _cr _cw _usd _peak _avg <<< "$ROW"
  # `command -v` before the call, not just `|| true`. bin/ syncs as a whole but
  # not atomically with every other box, so a NEWER producer can land beside an
  # OLDER jobs-client.sh that has no metric_* helper — and a missing function is
  # "command not found" on stderr every hour, which is noise in exactly the logs
  # this wave exists to make readable. Absent helper = no push, silently, which
  # is the same fail-open outcome as an unreachable worker.
  command -v metric_burn >/dev/null 2>&1 && \
  metric_burn "$_d" "$_calls" "$_in" "$_out" "$_cr" "$_cw" "$_usd" "$_peak" "$_avg" || true
fi

# usd_equiv is no longer the last field -- the ledger grew two columns, and
# ${ROW##*,} would silently start alerting on avg_cache_read instead.
USD=$(printf '%s' "$ROW" | cut -d, -f7)
OVER=$(awk -v u="$USD" 'BEGIN{print (u+0 > 150) ? 1 : 0}')
FLAG="$H/flags/alerted-orc-burn-$DAY"
if [ "$OVER" = 1 ] && [ ! -f "$FLAG" ]; then
  touch "$FLAG"
  echo "$(STAMP) [orchestrator-burn] today's orchestrator usage is \$${USD} API-equivalent (>150) — check turn volume/context before the bill does" >> "$H/logs/ALERTS.log"
fi
exit 0
