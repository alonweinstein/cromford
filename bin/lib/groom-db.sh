#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # GROOM_OUT is the answer, read by the caller
# bin/lib/groom-db.sh — BH-2526: the three facts bin/alerts-groom.sh used to ssh
# a box for, read from the coordination DB instead. Sourced, defines functions
# only; nothing runs on source except loading bin/jobs-client.sh if the caller
# has not already.
#
# Each helper puts its answer in GROOM_OUT (first word is the verdict, the rest
# is the why) rather than printing it: the per-pass memo lives in the CALLING
# shell, and a `$(...)` capture would throw the memo away with the subshell.
# Every fact costs one request per project per pass, not one per alert row.
#
# FAIL SAFE, NOT OPEN. A helper that cannot read its source answers `unknown`,
# never the settling word: resolving closes a client-visible alert, so an
# outage must hold the row and say so, not settle it and not go quiet.
#
#   groom_watcher_state <project> [box]  -> recovered | failing <kind> | dead <box> <last_tick_at> | unknown <why>
#   groom_commented <project> <build-dir> -> yes | no | unknown <why>
#   groom_migration_applied <project> <pr#> -> applied | failed | none | unknown <why>

if ! declare -F _jobs_req >/dev/null 2>&1; then
  # shellcheck source=bin/jobs-client.sh
  [ -r "${HARNESS:-/root/harness}/bin/jobs-client.sh" ] && . "${HARNESS:-/root/harness}/bin/jobs-client.sh" 2>/dev/null
fi

GROOM_OUT=""
GROOM_LANES=""; GROOM_LANES_RC=""
declare -gA GROOM_ART=() GROOM_ART_RC=() GROOM_MIG=() GROOM_MIG_RC=()

# The triage lane's liveness row (lane_tick -> the `lanes` table, GET /api/lanes).
# The worker's `state` is the fleet's one definition of a dead box (shared with
# jobs-watchdog and fleet-slo), so `stale` wins over whatever the last tick was:
# a box that ran once and then died is dead, not recovered. `last_tick_kind` is
# the DB twin of the `rc=0|rc=skip|rc=1` the watcher log line carried.
groom_watcher_state() {
  local project="${1:-}" box="${2:-}" row
  GROOM_OUT="unknown no-project"
  [ -n "$project" ] || return 0
  declare -F lanes_list >/dev/null 2>&1 || { GROOM_OUT="unknown no-jobs-client"; return 0; }
  if [ -z "$GROOM_LANES_RC" ]; then
    GROOM_LANES=$(lanes_list 2>/dev/null); GROOM_LANES_RC=$?
  fi
  [ "$GROOM_LANES_RC" = 0 ] || { GROOM_OUT="unknown lanes-unreadable"; return 0; }
  # The owning box's row first. Otherwise (box unknown, or its row retired after
  # a move) the freshest non-retired row for the project; a never-ticked row
  # (tick_age -1) sorts last.
  row=$(awk -F'\t' -v p="$project" -v b="$box" '$1==p && $2==b && $3!="retired"' <<<"$GROOM_LANES" | head -1)
  [ -n "$row" ] || row=$(awk -F'\t' -v p="$project" '$1==p && $3!="retired" { a=($5<0)?999999999:$5; print a "\t" $0 }' <<<"$GROOM_LANES" \
                          | sort -n -k1,1 | head -1 | cut -f2-)
  [ -n "$row" ] || { GROOM_OUT="unknown no-lane-row"; return 0; }
  local rbox state kind at
  rbox=$(cut -f2 <<<"$row"); state=$(cut -f3 <<<"$row"); kind=$(cut -f6 <<<"$row"); at=$(cut -f9 <<<"$row")
  case "$state" in
    stale) GROOM_OUT="dead $rbox $at" ;;
    live)
      case "$kind" in
        run|skip) GROOM_OUT="recovered" ;;
        *)        GROOM_OUT="failing $kind" ;;
      esac ;;
    *) GROOM_OUT="unknown lane-$state" ;;
  esac
  return 0
}

# A `commented` artifact (written by bin/commented-mirror.sh on the owning box)
# whose ref is this build dir. Matched on the dir's exact basename, so a dir
# that only shares a prefix never matches; a `withdrawn` ref is not a path and
# never matches either.
groom_commented() {
  local project="${1:-}" dir="${2%/}" want
  GROOM_OUT="unknown no-project"
  [ -n "$project" ] && [ -n "$dir" ] || return 0
  declare -F job_artifact_feed >/dev/null 2>&1 || { GROOM_OUT="unknown no-jobs-client"; return 0; }
  if [ -z "${GROOM_ART_RC[$project]+x}" ]; then
    GROOM_ART[$project]=$(job_artifact_feed commented "$project" "" 500 2>/dev/null)
    GROOM_ART_RC[$project]=$?
  fi
  [ "${GROOM_ART_RC[$project]}" = 0 ] || { GROOM_OUT="unknown artifacts-unreadable"; return 0; }
  want="${dir##*/}"
  if awk -F'\t' -v w="$want" '$2 ~ /^\// { n=split($2, a, "/"); if (a[n]==w) f=1 } END { exit !f }' <<<"${GROOM_ART[$project]}"; then
    GROOM_OUT="yes"
  else
    GROOM_OUT="no"
  fi
  return 0
}

# The stage_events of the project's newest kind=migration jobs, written by
# bin/migration-autopilot.sh:mig_job_close with the PR number in the detail
# (`PR#<n> ...`). Any FAILED/FLAGGED for the PR holds it; otherwise one APPLIED
# settles it. A detail read that fails makes the whole answer `unknown`: a
# missing event is not a non-event.
groom_migration_applied() {
  local project="${1:-}" pr="${2:-}" lim="${ALERTS_GROOM_MIGRATION_JOBS:-20}" resp ids id ev hits
  GROOM_OUT="unknown no-project"
  [ -n "$project" ] && [[ "$pr" =~ ^[0-9]+$ ]] || return 0
  declare -F _jobs_req >/dev/null 2>&1 || { GROOM_OUT="unknown no-jobs-client"; return 0; }
  [[ "$lim" =~ ^[0-9]+$ ]] && [ "$lim" -ge 1 ] || { GROOM_OUT="unknown bad-ALERTS_GROOM_MIGRATION_JOBS=$lim"; return 0; }
  if [ -z "${GROOM_MIG_RC[$project]+x}" ]; then
    GROOM_MIG[$project]=""; GROOM_MIG_RC[$project]=0
    if resp=$(_jobs_req GET "/api/jobs?project=$project&kind=migration&limit=$lim" 2>/dev/null) \
       && ids=$(jq -r '.jobs[]?.id // empty' <<<"$resp" 2>/dev/null); then
      for id in $ids; do
        if ev=$(_jobs_req GET "/api/jobs/$id" 2>/dev/null) \
           && ev=$(jq -r '.events[]? | [(.verdict // "-"), (.detail // "-")] | @tsv' <<<"$ev" 2>/dev/null); then
          [ -n "$ev" ] && GROOM_MIG[$project]+="$ev"$'\n'
        else
          GROOM_MIG_RC[$project]=1; break
        fi
      done
    else
      GROOM_MIG_RC[$project]=1
    fi
  fi
  [ "${GROOM_MIG_RC[$project]}" = 0 ] || { GROOM_OUT="unknown migration-jobs-unreadable"; return 0; }
  # PR#<n> followed by a non-digit or the end, so PR#421 is not PR#42.
  hits=$(awk -F'\t' -v re="PR#${pr}([^0-9]|$)" '$2 ~ re { print $1 }' <<<"${GROOM_MIG[$project]}")
  if grep -qxE 'FAILED|FLAGGED' <<<"$hits"; then GROOM_OUT="failed"
  elif grep -qx 'APPLIED' <<<"$hits"; then GROOM_OUT="applied"
  else GROOM_OUT="none"; fi
  return 0
}
