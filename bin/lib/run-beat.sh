# shellcheck shell=bash
# bin/lib/run-beat.sh — run_beat '<json>': send one kind:"run" beat, strictly.
#
# WHY (BH-2755): the triage run beats went out as `beat.sh … >/dev/null 2>&1 ||
# true`, and bin/beat.sh exits 0 on a box with no console configured. A box that
# could not beat looked exactly like a box that ran nothing, and the console's
# runs table just stopped. So the beat goes BEAT_STRICT=1, and a beat the
# console did not take is ONE logs/ALERTS.log line per box per UTC day, deduped
# by flags/alerted-run-beat-<box>-<yyyymmdd> (a noclobber create, so concurrent
# shards race to exactly one line).
#
# Always returns 0 and prints nothing: a failed beat never fails the run, and
# bin/launch-fastpath.sh's stdout is "declined keys only".
# Sourced by bin/launch-fastpath.sh and bin/triage-shard.sh.
run_beat() {
  local h="${HARNESS:-/root/harness}" rc=0 box day why
  BEAT_STRICT=1 "$h/bin/beat.sh" "${1:-}" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && return 0
  box=$( (hostname -s 2>/dev/null || hostname 2>/dev/null) | head -1 | tr -dc 'A-Za-z0-9._-')
  [ -n "$box" ] || box=unknown
  day=$(date -u +%Y%m%d)
  if [ "$rc" = 2 ]; then
    why="CONSOLE_URL/HARNESS_SECRET unset"
  else
    why="POST /api/beat returned non-2xx (rc=$rc)"
  fi
  mkdir -p "$h/flags" "$h/logs" 2>/dev/null
  if ( set -C; : > "$h/flags/alerted-run-beat-$box-$day" ) 2>/dev/null; then
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [run-beat] box=$box: triage run beat not delivered: $why — runs table will miss this box's triage rows today" \
      >> "$h/logs/ALERTS.log" 2>/dev/null
  fi
  return 0
}
