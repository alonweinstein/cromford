#!/bin/bash
# bin/archie-fm-queue.sh — BH-4584 (BH-4574.2): Archie's queue doctor. A hub
# lane that watches every Mergify merge queue and the conductor's view of it,
# and runs three playbooks (bin/lib/archie-fm-queue/):
#   queue-reconcile  corrects a conductor row GitHub disagrees with: a PR
#                    merged on GitHub but logged ejected is settled MERGED; a
#                    dependency hold whose dependency landed is released (a
#                    stale sibling row corrected) or reported (one alert); a
#                    stale WAIT_CI row with every check green gets one keyed
#                    conductor run.
#   queue-culprit    a failed Mergify batch: each member merged ALONE onto
#                    current main with the batch's failing suites, on the CI
#                    pool (#4548's pq_dispatch); only a member that reproduces
#                    gets a head-bound BLOCK verdict and one PR comment.
#   queue-enqueue    an approved, green, clean PR nobody enqueued (external
#                    authors included) is enqueued once through the conductor's
#                    own mc_enqueue_mergify.
#
#   archie-fm-queue.sh [tick] [--project <p>] [--pr <owner/repo#n>]
#     no argument is a tick: the cron line, every 10 minutes. --project and
#     --pr narrow one tick to one project or one PR.
#
# TICK, in this order:
#   1. lane_gate_or_exit / lane_env_apply archie-fm-queue; ARCHIE_FMQ_ENABLED=0
#      exits; flock -n locks/archie-fm-queue.lock (held = skip, never wait);
#      NOW read once (ARCHIE_FMQ_NOW only under HARNESS_TEST_SANDBOX=1). The
#      outer `timeout` (1860 s) is the backstop for a hang; the tick's own
#      deadline is 1500 s, and a keyed conductor run or an enqueue starts only
#      while its bound fits. A TERM trap closes this tick's `started` row
#      failed; bash runs it only once a foreground child (a keyed conductor
#      run) returns, so a tick killed outright leaves the row `started`, and
#      the first tick past ARCHIE_FMQ_RETRY_S closes it failed with one alert
#      (afq_sweep_started, over today's and yesterday's rows, before step 2).
#   2. per project (bin/fleet-conf.sh --projects, at most
#      ARCHIE_FMQ_PROJECTS_PER_TICK, one slot further round the list each
#      tick): the mode from archie.manage.<project> > archie.manage > `on`
#      (wave 1's afm_mode; the same kill switch). off = nothing read. When
#      that read fails, the mode comes from the box settings cache if it is at
#      most ARCHIE_FMQ_MODE_CACHE_MAX_S old (afq_mode_cached, default 1200,
#      0 = off); else the project is skipped this tick, and the line names
#      the cause (http=<code>, curl_rc=<n>, no-secret, or unknown).
#   3. reconcile FIRST, so a PR GitHub merged is never enqueued or verdicted on
#      a stale row; then ONE open-PR list read (a full page logs `truncated`);
#      then culprit; then enqueue over that list.
#   4. one line in logs/archie-fm-queue.log per tick that did anything:
#      <ts> projects=<n> prs=<n> settled=<n> released=<n> reported=<n> kicked=<n> enqueued=<n> blocked=<n> innocent=<n> solo_pending=<n> would=<n> capped=<n> skipped=<n> failed=<n>
#
# EVERY ACTION IS AN archie_actions ROW (worker/jobs/src/routes/archie-actions.js),
# claimed before any write, keyed on its inputs (the head, the batch, the main
# tip), with a per-playbook day cap (settings archie.cap.<playbook>, the
# CI-minute cap archie.cap.queue-solo). Observe mode writes would_* rows and
# nothing else.
#
# NEVER: a merge, a push, a model call, a Mergify config change, or a state
# file of its own. The writes are mc_enqueue_mergify, conductor_settle /
# mc_transition under the conductor's PR lock, a lead verdict row, one PR
# comment, one keyed conductor run, and pq_dispatch.
#
# OFF: ARCHIE_FMQ_ENABLED=0, flags/lane-off-archie-fm-queue, bin/harness-ctl.sh
# off archie-fm-queue, or archie.manage[.<project>]=off.
# Registry: catalog/lanes.d/archie-fm-queue.json.
# Note: docs/notes/2026-10-05-BH-4584-archie-fm-queue.md.
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
[ "${1:-}" = tick ] && shift
ONLY_PROJECT=""; ONLY_PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) ONLY_PROJECT="${2:-}"; shift 2 ;;
    --pr) ONLY_PR="${2:-}"; shift 2 ;;
    *) echo "usage: archie-fm-queue.sh [tick] [--project <p>] [--pr <owner/repo#n>]" >&2; exit 2 ;;
  esac
done
if [ -n "$ONLY_PR" ] && ! [[ $ONLY_PR =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]]; then
  echo "archie-fm-queue: --pr wants <owner/repo#n>, got '$ONLY_PR'" >&2; exit 2
fi
if [ "${ARCHIE_FMQ_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  CEIL=1860
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_FMQ_TICK_CEILING_S:-} =~ ^[0-9]+$ ]]; then CEIL=$ARCHIE_FMQ_TICK_CEILING_S; fi
  ARCHIE_FMQ_TIMED=1 exec timeout -k 60 "$CEIL" bash "$0" tick ${ONLY_PROJECT:+--project "$ONLY_PROJECT"} ${ONLY_PR:+--pr "$ONLY_PR"}
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/merge-conductor-lib.sh" 2>/dev/null || true
  . "$SELF/lib/ticket-ownership.sh" 2>/dev/null || true
  . "$SELF/lib/pause.sh" 2>/dev/null || true
  . "$SELF/lib/autoenqueue.sh" 2>/dev/null || true
  . "$SELF/lib/mc-batch-eject.sh" 2>/dev/null || true
  . "$SELF/lib/mc-prequeue.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-queue/common.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-queue/reconcile.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-queue/enqueue.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-queue/culprit.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_FMQ_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_FMQ_FIXTURE"
fi
for f in afm_mode afm_cap_ok afm_close _afm_req _jobs_req setting_get gh_rest_var gh_rest_pr_list_var mc_init mc_row_get \
         mc_transition mc_pr_lock mc_attempt_has conductor_settle mc_enqueue_mergify mc_queue_provider vd_standing \
         _ae_required_checks bej_draft_members pq_key pq_cache_get pq_cache_put \
         afq_claim afq_sweep_started afq_reconcile afq_culprit afq_enqueue afq_mode_cached; do
  command -v "$f" >/dev/null 2>&1 || { echo "archie-fm-queue: $f is not defined (a lib is missing)" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "archie-fm-queue: jq missing" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_FMQ_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$ARCHIE_FMQ_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
DAY=$(date -u -d "@$NOW" +%F)
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
AFM_LOG="$H/logs/archie-fm-queue.log"
AFM_H="$H"

# knob_int <name> <value> <default> <min> <max>: out of range is one warn line
# and the default, never a silent clamp (D11).
knob_int() {
  local v=$2
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$4" ] && [ "$((10#$v))" -le "$5" ]; then
    printf '%s' "$((10#$v))"
  else
    afq_log "warn: $1=$v is outside $4..$5; using the default $3"
    printf '%s' "$3"
  fi
}

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit archie-fm-queue
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie-fm-queue
case "${ARCHIE_FMQ_ENABLED:-1}" in
  0) exit 0 ;;
  1) ;;
  *) afq_log "warn: ARCHIE_FMQ_ENABLED=${ARCHIE_FMQ_ENABLED} is not 0 or 1; using the default 1" ;;
esac
exec 9>"$H/locks/archie-fm-queue.lock" || exit 0
flock -n 9 || exit 0

AFQ_RETRY_S=$(knob_int ARCHIE_FMQ_RETRY_S "${ARCHIE_FMQ_RETRY_S:-1800}" 1800 60 86400)
MAXP=$(knob_int ARCHIE_FMQ_PROJECTS_PER_TICK "${ARCHIE_FMQ_PROJECTS_PER_TICK:-0}" 0 0 100)
AFQ_KICK_TIMEOUT_S=$(knob_int ARCHIE_FMQ_KICK_TIMEOUT_S "${ARCHIE_FMQ_KICK_TIMEOUT_S:-240}" 240 30 900)
AFQ_SOLO_TIMEOUT_S=$(knob_int ARCHIE_FMQ_SOLO_TIMEOUT_S "${ARCHIE_FMQ_SOLO_TIMEOUT_S:-2400}" 2400 300 86400)
AFQ_BATCH_WINDOW_S=$(knob_int ARCHIE_FMQ_BATCH_WINDOW_S "${ARCHIE_FMQ_BATCH_WINDOW_S:-21600}" 21600 600 172800)
AFQ_MODE_CACHE_MAX_S=$(knob_int ARCHIE_FMQ_MODE_CACHE_MAX_S "${ARCHIE_FMQ_MODE_CACHE_MAX_S:-1200}" 1200 0 3600)
# The settings read's status word (bin/lib/jobs/req.sh JOBS_STATUS_FILE): a
# read inside $( ) loses JOBS_HTTP, so the cause of a failure rides in a file.
AFQ_MODE_ST=$(mktemp "${TMPDIR:-/tmp}/afq-mode.XXXXXX" 2>/dev/null) || AFQ_MODE_ST=""
trap '[ -n "$AFQ_MODE_ST" ] && rm -f "$AFQ_MODE_ST"' EXIT
AFQ_DEADLINE=$(( $(date +%s) + 1500 ))
afq_time_left() { printf '%s' "$(( AFQ_DEADLINE - $(date +%s) ))"; }
afq_on_term() {
  trap - TERM INT HUP
  if [ -n "$AFM_ROW" ] && [ "$(jq -r .outcome <<<"$AFM_ROW" 2>/dev/null)" = started ]; then
    afm_close failed "" "the tick was stopped mid-action (its backstop or a signal); not retried on this key" \
      && afq_log "$(jq -r '.repo + "#" + (.pr | tostring)' <<<"$AFM_ROW"): the tick was stopped mid-action; the row is failed"
  fi
}
trap 'afq_on_term; exit 143' TERM INT HUP
mc_init

NPROJ=0; NPRS=0
AFQ_N_SETTLED=0; AFQ_N_RELEASED=0; AFQ_N_REPORTED=0; AFQ_N_KICKED=0; AFQ_N_ENQUEUED=0; AFQ_N_BLOCKED=0
AFQ_N_INNOCENT=0; AFQ_N_PENDING=0; AFQ_N_WOULD=0; AFQ_N_CAPPED=0; AFQ_N_SKIPPED=0; AFQ_N_FAILED=0

afq_sweep_started "$ONLY_PROJECT" "$ONLY_PR"
read -r -a PROJS <<<"$("$H/bin/fleet-conf.sh" --projects 2>/dev/null | tr '\n' ' ')"
if [ "${#PROJS[@]}" = 0 ]; then
  afq_log "warn: bin/fleet-conf.sh --projects answered nothing; nothing read"
  exit 0
fi
START=$(( (NOW / 600) % ${#PROJS[@]} ))
for P in "${PROJS[@]:$START}" "${PROJS[@]:0:$START}"; do
  [ "$AFM_ROUTE_ABSENT" = 1 ] && break
  [ -z "$ONLY_PROJECT" ] || [ "$ONLY_PROJECT" = "$P" ] || continue
  SLUG=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null)
  case "$SLUG" in */*) ;; *) continue ;; esac
  [ -z "$ONLY_PR" ] || [ "${ONLY_PR%#*}" = "$SLUG" ] || continue
  if [ "$MAXP" -gt 0 ] && [ "$NPROJ" -ge "$MAXP" ]; then
    afq_log "ARCHIE_FMQ_PROJECTS_PER_TICK=$MAXP reached; $P and the rest wait for the next tick"; break
  fi
  [ -n "$AFQ_MODE_ST" ] && : > "$AFQ_MODE_ST"
  if ! MODE=$(JOBS_STATUS_FILE="$AFQ_MODE_ST" afm_mode "$P"); then
    CAUSE=""; [ -n "$AFQ_MODE_ST" ] && CAUSE=$(head -c 64 "$AFQ_MODE_ST" 2>/dev/null | tr -d '\n')
    CAUSE=${CAUSE:-unknown}
    if CACHED=$(afq_mode_cached "$P" "$AFQ_MODE_CACHE_MAX_S" "$NOW"); then
      MODE=${CACHED%%$'\t'*}
      afq_log "$P: the archie.manage settings could not be read ($CAUSE); using the box settings cache from ${CACHED#*$'\t'}s ago: mode=$MODE"
    else
      afq_log "$P: the archie.manage settings could not be read ($CAUSE); skipped this tick (no action without the ledger)"
      continue
    fi
  fi
  [ "$MODE" = off ] && continue
  NPROJ=$((NPROJ + 1))
  AFQ_CLOSED=""; AFQ_CLOSED_FOR=""; AFQ_MAIN=""
  afq_reconcile "$P" "$SLUG" "$MODE"
  [ "$AFM_ROUTE_ABSENT" = 1 ] && break
  LIST_OK=0; rc=0; gh_rest_pr_list_var LIST "$SLUG" open "" 100 || rc=$?
  if [ "$rc" = 0 ] && jq -e 'type == "array"' <<<"$LIST" >/dev/null 2>&1; then
    LIST_OK=1; NPRS=$((NPRS + $(jq length <<<"$LIST")))
    [ "$(jq length <<<"$LIST")" -ge 100 ] && afq_log "$P: the open PR list is a full page (100), truncated; only what was read is acted on"
  else
    afq_log "$P: the open PR list could not be read (rc=$rc HTTP ${GH_REST_STATUS:-000}); no enqueue this tick"
  fi
  afq_culprit "$P" "$SLUG" "$MODE"
  [ "$AFM_ROUTE_ABSENT" = 1 ] && break
  if [ "$LIST_OK" = 1 ]; then
    afq_enqueue "$P" "$SLUG" "$MODE" "$LIST"
  fi
  [ "$AFM_ROUTE_ABSENT" = 1 ] && break
done
[ "$AFM_ROUTE_ABSENT" = 1 ] && afq_log "archie_actions route absent (HTTP 404 from the jobs worker); nothing done"
SUM=$((AFQ_N_SETTLED + AFQ_N_RELEASED + AFQ_N_REPORTED + AFQ_N_KICKED + AFQ_N_ENQUEUED + AFQ_N_BLOCKED + AFQ_N_INNOCENT \
      + AFQ_N_PENDING + AFQ_N_WOULD + AFQ_N_CAPPED + AFQ_N_SKIPPED + AFQ_N_FAILED))
[ "$SUM" -gt 0 ] && afq_log "projects=$NPROJ prs=$NPRS settled=$AFQ_N_SETTLED released=$AFQ_N_RELEASED reported=$AFQ_N_REPORTED kicked=$AFQ_N_KICKED enqueued=$AFQ_N_ENQUEUED blocked=$AFQ_N_BLOCKED innocent=$AFQ_N_INNOCENT solo_pending=$AFQ_N_PENDING would=$AFQ_N_WOULD capped=$AFQ_N_CAPPED skipped=$AFQ_N_SKIPPED failed=$AFQ_N_FAILED"
exit 0
