#!/bin/bash
# orc-job.sh — run a detached job under a coordination row that heartbeats.
# Spec: docs/DB-COORDINATION-SPEC.md (phase 3). Client: bin/jobs-client.sh.
#
# WHY THIS EXISTS. The orchestrator launches long work by hand —
# `setsid claude -p ... &` for a build session, a fix, a QA pass — and that path
# had no row anywhere. On 2026-08-27 17:48Z a kill wave took two of them
# (a phase-2 build session and the project-2 #400 fix) and both died BLANK:
# no PR, no ALERTS line, no half-finished record. The failure was invisible
# until someone went looking for work that never arrived.
#
# Wrapping the launch fixes the evidence, not the kill:
#   setsid /root/harness/bin/orc-job.sh --project project-2 --key TK-400 \
#          --kind fix -- claude -p --dangerously-skip-permissions "..."
# opens a job row, beats it every ~150s for as long as the command runs, and
# closes it with the command's real rc. A SIGKILL now shows up as a row whose
# beats stopped, which bin/jobs-watchdog.sh turns into one ALERTS line.
#
# Everything is fail-open: with the worker unreachable there is no row, no beat
# and no noise — the command runs exactly as it would have without this wrapper.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
LOG="$H/logs/orc-jobs.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" 2>/dev/null

PROJECT=orchestrator; KEY=""; KIND=orchestrator; STAGE=execute; LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --key)     KEY="${2:-}"; shift 2 ;;
    --kind)    KIND="${2:-}"; shift 2 ;;
    --stage)   STAGE="${2:-}"; shift 2 ;;
    --label)   LABEL="${2:-}"; shift 2 ;;
    --)        shift; break ;;
    *)         break ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: orc-job.sh [--project P] [--key K] [--kind K] [--stage S] [--label L] -- <command...>" >&2; exit 2; }

if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"

JOB_ID=""; BEAT=""
if command -v job_open >/dev/null 2>&1; then
  CLAIM=$(job_open "$PROJECT" "$KEY" "$KIND" "$STAGE" "$STAGE/$PROJECT/claude" \
    "$(jq -nc --arg l "${LABEL:-$(basename "$1")}" --arg c "$1" '{label:$l,command:$c}' 2>/dev/null)")
  case "$?" in
    0) JOB_ID="$CLAIM"; export JOB_ID ;;
    9) # The SAME refusal the build pipeline honors. A hand-launched fix for a
       # ticket another box is already building is the duplicate this layer
       # exists to stop, and the orchestrator's launches are exactly where that
       # mistake gets made (it cannot see another box's in-flight work). Since
       # phase 6 a concurrency rule can refuse here too, and $CLAIM carries the
       # rule's own words either way.
       echo "$(STAMP) [orc-job] refused $PROJECT/$KEY $KIND: $CLAIM" >> "$LOG"
       echo "orc-job: claim refused — $CLAIM; not launching" >&2
       exit 3 ;;
    *) JOB_ID="" ;;
  esac
fi

if [ -n "$JOB_ID" ] && command -v job_beat_start >/dev/null 2>&1; then
  BEAT=$(job_beat_start "$JOB_ID") || BEAT=""
  # A first beat immediately, so a job killed inside its first interval is still
  # a row that beat once — which is what tells the watchdog it may be judged.
  job_heartbeat "$JOB_ID" "start" >/dev/null 2>&1 || true
fi

_finish() {
  local rc="${1:-1}" st
  case "$rc" in 0) st=done ;; *) st=failed ;; esac
  [ -n "$BEAT" ] && job_beat_stop "$BEAT"
  if [ -n "$JOB_ID" ] && command -v job_update >/dev/null 2>&1; then
    job_update "$JOB_ID" "status=$st" "stage=done" >/dev/null 2>&1 || true
    job_event "$JOB_ID" done "$st" "rc=$rc ${LABEL:-}" >/dev/null 2>&1 || true
  fi
  echo "$(STAMP) [orc-job] $PROJECT/${KEY:--} $KIND rc=$rc job=${JOB_ID:--}" >> "$LOG"
}
# The trap covers a TERM (a shutdown, an operator) — not a KILL, which by
# definition runs nothing. That case is the watchdog's, and it is the case this
# wrapper exists for.
trap '_finish 143; exit 143' TERM INT

"$@"
RC=$?
trap - TERM INT
_finish "$RC"
exit "$RC"
