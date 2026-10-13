#!/bin/bash
# bin/box-self-report.sh — EVERY box, hourly at :27 (BH-2532.4, BH-2626): the
# box states its own runner CLI versions and the md5 of its rendered
# /root/.claude/CLAUDE.md, and POSTs them to /api/boxes/self-report through
# box_self_report_set (bin/lib/jobs/boxes.sh).
#
# Why: bin/rules-drift-check.sh (hourly) and bin/cli-version-check.sh (daily)
# learned both facts by ssh-ing every box from the hub. Both now read
# box_self_reports first and ssh only a box whose row is stale, absent or
# untrusted, so a box that reports keeps being checked when the hub's ssh hop
# does not answer.
#
# THE SAME READINGS THE HUB TAKES, so the hub compares like with like:
#   - versions: ver() below is cli-version-check.sh's probe `ver` verbatim,
#     run against the binaries this lane's cron PATH resolves (the PATH the
#     probe calls "cron PATH"). No output is `missing`, and the worker drops a
#     report's whole CLI half when either CLI reads missing.
#   - rules hash: `md5sum <CLAUDE.md> | cut -d' ' -f1`, or `-` when the file is
#     absent: byte for byte the m() digest in rules-drift-check.sh's probe. It
#     is the hash of the RENDERED file (canon plus any CLAUDE.local.md overlay),
#     never rules_commit.
#
# BOUNDED AND NEVER RETRIED: the work runs as a child under `timeout 30`. A
# child that fails or times out leaves ONE line in logs/box-self-report.log and
# writes nothing; the hub reads the silence as a stale row and falls back to
# ssh. DEDUPE: flock -n on locks/box-self-report.lock, skip if held, never wait.
#
# Off: BOX_SELF_REPORT_ENABLED=0 (settings row
# lane.box-self-report.box_self_report_enabled) or bin/harness-ctl.sh off
# box-self-report. Test seams: HARNESS, BOX_SELF_REPORT_CLAUDE_DIR,
# BOX_SELF_REPORT_TIMEOUT. Never set these in cron.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-box-self-report
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off box-self-report.
# The --report child is launched by the gated parent and inherits its
# environment, so it does not gate (or post the lane's liveness) a second time.
if [ "${1:-}" != --report ]; then
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit box-self-report
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    box-self-report
fi

LOG="$HARNESS/logs/box-self-report.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# --- the child: read the three facts and post them ------------------------------
# stdout is the summary the parent logs; rc is box_self_report_set's rc, or 3
# when there is no jobs client to post with.
if [ "${1:-}" = --report ]; then
  # shellcheck source=/dev/null
  [ -f "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
  declare -F box_self_report_set >/dev/null 2>&1 || { echo "no jobs client (box_self_report_set undefined)"; exit 3; }
  ver() { local o; o=$(timeout 10 "$1" --version 2>/dev/null | head -1); printf '%s' "$o" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1; }
  CLI=$(ver claude); CLI="${CLI:-missing}"
  CODEX=$(ver codex); CODEX="${CODEX:-missing}"
  F="${BOX_SELF_REPORT_CLAUDE_DIR:-/root/.claude}/CLAUDE.md"
  RH=$([ -f "$F" ] && md5sum "$F" 2>/dev/null | cut -d' ' -f1 || echo -)
  echo "claude=$CLI codex=$CODEX rules=${RH:0:8}"
  box_self_report_set "$CLI" "$CODEX" "$RH"
  exit $?
fi

# --- the parent: off switch, dedupe, one bounded child --------------------------
[ "${BOX_SELF_REPORT_ENABLED:-}" = 0 ] && exit 0
mkdir -p "$HARNESS/locks" "$HARNESS/logs"
exec 9>"$HARNESS/locks/box-self-report.lock"
flock -n 9 || exit 0
OUT=$(timeout "${BOX_SELF_REPORT_TIMEOUT:-30}" "$0" --report 9>&- 2>/dev/null); RC=$?
if [ "$RC" -ne 0 ]; then
  echo "$(STAMP) box-self-report: failed rc=$RC, no confirmed write${OUT:+ ($(printf '%s' "$OUT" | tr '\n' ' ' | head -c 200))}" >> "$LOG"
  exit 0
fi
echo "$(STAMP) box-self-report: $OUT" >> "$LOG"
exit 0
