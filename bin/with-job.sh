#!/bin/bash
# with-job.sh — run ANY command under a coordination row that heartbeats.
# Spec: docs/DB-COORDINATION-SPEC.md (phase 4). Client: bin/jobs-client.sh.
#
#   with-job.sh [--key K] [--kind K] [--label L] <lane> <command...>
#   e.g.  setsid /root/harness/bin/with-job.sh review/project-3/claude \
#             /root/harness/bin/review-rescue.sh project-3
#
# WHY THIS EXISTS. Phase 3 gave the pipelines rows: run-build, run-triage,
# agent-call's stage boundaries, and bin/orc-job.sh for a hand-launched
# `claude -p`. Everything ELSE the fleet runs — the detached one-off scripts the
# orchestrator fires with `setsid ... &`, the sweeps, the rescues — still ran
# with no row anywhere, which is the same silence phase 3 set out to remove:
# on 2026-08-27 17:48Z two detached sessions died blank and the only evidence
# was work that never arrived. A wrapper cannot stop a SIGKILL. It can make one
# leave a row whose beats stopped, which bin/jobs-watchdog.sh turns into a
# single ALERTS line naming the lane.
#
# THE LANE IS THE FIRST ARGUMENT ON PURPOSE. <stage>/<project>/<runner> is
# already the key the budget catalog is indexed by (worker/jobs/src/index.js
# `laneCandidates`), so "this lane has a declared ceiling" and "this lane can
# claim a row" are one fact with one spelling. bin/orc-job.sh keeps its
# --project/--kind flags because it wraps a ticket's build session, where the
# ticket — not the lane — is the thing being claimed.
#
# FAIL OPEN, always. Worker unreachable, HARNESS_SECRET unset, jobs-client
# missing: there is no row, no beat, no noise, and the command runs EXACTLY as
# it would have without this wrapper. The wrapper's own rc is always the
# command's rc. A ledger that can stop the fleet is worse than no ledger.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$H/logs/with-job.log"
mkdir -p "$H/logs" 2>/dev/null

KEY=""; KIND=""; LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --key)   KEY="${2:-}"; shift 2 ;;
    --kind)  KIND="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    --)      shift; break ;;
    -*)      echo "with-job.sh: unknown option $1" >&2; exit 2 ;;
    *)       break ;;
  esac
done
LANE="${1:-}"; shift || true
case "$LANE" in
  */*) ;;
  *) echo "usage: with-job.sh [--key K] [--kind K] [--label L] <stage/project/runner> <command...>" >&2; exit 2 ;;
esac
[ $# -gt 0 ] || { echo "usage: with-job.sh [--key K] [--kind K] [--label L] <stage/project/runner> <command...>" >&2; exit 2; }
LABEL="${LABEL:-$(basename "$1")}"

# cron does not source global.env for us, and HARNESS_SECRET lives there.
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"

if command -v job_lane_open >/dev/null 2>&1; then
  # NOT in a command substitution: job_lane_open sets JOB_ID and JOB_BEAT, and a
  # subshell would take both with it — an open claim, an orphaned beater, and a
  # row nothing ever closes.
  job_lane_open "$LANE" "$KEY" "$KIND" \
    "$(jq -nc --arg l "$LABEL" --arg c "$1" '{label:$l,command:$c}' 2>/dev/null)"
  case "$?" in
    0) : ;;
    9) # The SAME refusal the build pipeline honours. Two things can produce
       # it: the phase-1 double-build guard, which only a KEYED claim can ever
       # reach, and a phase-6 concurrency rule, which is keyed on repo / box /
       # lane and so can bind an unkeyed sweep too. JOB_REFUSED carries the
       # rule's own words either way.
       echo "$(STAMP) [with-job] refused $LANE ${KEY:--}: ${JOB_REFUSED:-$JOB_INFLIGHT}" >> "$LOG"
       echo "with-job: claim refused — ${JOB_REFUSED:-$JOB_INFLIGHT}; not launching" >&2
       exit 3 ;;
    *) : ;;   # fail-open: no row, run anyway
  esac
fi

_finish() { # _finish <rc>
  local rc="${1:-1}" id="${JOB_ID:--}"   # job_lane_close clears JOB_ID; log what we had
  command -v job_lane_close >/dev/null 2>&1 && job_lane_close "$rc" "$LANE $LABEL"
  echo "$(STAMP) [with-job] $LANE ${KEY:--} $LABEL rc=$rc job=$id" >> "$LOG"
}
# Covers a TERM (a shutdown, an operator) — never a KILL, which by definition
# runs nothing. The KILL case is the watchdog's, and it is the case this
# wrapper exists for.
trap '_finish 143; exit 143' TERM INT

"$@"
RC=$?
trap - TERM INT
_finish "$RC"
exit "$RC"
