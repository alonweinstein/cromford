#!/bin/bash
# bin/issue-state-ledger.sh — hub cron (*/15), BH-938: record the open/closed
# state of every GitHub issue of the GitHub-issues projects in harness-jobs
# ledgers(kind=issue_state, key=<project>#<n>, status=closed|open).
#
# The console's DEAD column counted build rows whose issue had long since
# closed (project-5: dead_failed=29, every issue merged or superseded). The
# worker that builds that column is not in this repo, so the Pages Function
# console-ui/functions/api/dash/kanban/pipeline.js joins these rows at read
# time and holds back dead build cards whose issue is closed. This lane is the
# half that knows which issues are closed.
#
# Projects: every fleet.conf row whose board_prefix is `-` and whose repo is
# not `-`. A board-API project's "closed" is a board status, not an issue
# state, so it is out of scope and never read.
#
# Per project, each tick:
#   - watermark = ledgers(kind=issue_state_wm, key=<project>).status, an ISO
#     updated_at. Absent -> ISSUE_STATE_BACKFILL_DAYS back. A ledger OUTAGE
#     skips the project: the watermark is never guessed.
#   - page repos/<repo>/issues?state=all&since=<wm>&sort=updated&direction=asc
#     through gh_rest. Any non-0 (rc 75 = rate limited, not "nothing there")
#     stops the project.
#   - PUT each issue's row; a pull request in the list is skipped on purpose.
#   - WRITE BEFORE ADVANCE: the watermark moves only past items that were
#     written (or deliberately skipped), contiguously, and is itself written
#     once when the project stops for any reason. A failed PUT stops the
#     project there. `since` is inclusive, so the boundary item is re-read and
#     re-PUT next tick, which is a harmless upsert.
# Bounds: ISSUE_STATE_MAX_PUTS puts per tick (all projects) and
# ISSUE_STATE_MAX_PAGES pages per project. Hitting either persists the
# watermark and logs "DEFERRED <project> at <wm>"; the next tick resumes.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-issue-state-ledger
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off issue-state-ledger.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit issue-state-ledger
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    issue-state-ledger

mkdir -p "$H/locks" "$H/logs" || exit 1
LOG=$H/logs/issue-state-ledger.log
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG"; }

# Dedupe, never a wait: a tick that finds the previous one still reading leaves.
exec 9>"$H/locks/issue-state-ledger.lock"
flock -n 9 || exit 0

DAYS=${ISSUE_STATE_BACKFILL_DAYS:-14}; case "$DAYS" in ''|*[!0-9]*) DAYS=14 ;; esac
MAXPUTS=${ISSUE_STATE_MAX_PUTS:-300};  case "$MAXPUTS" in ''|*[!0-9]*) MAXPUTS=300 ;; esac
MAXPAGES=${ISSUE_STATE_MAX_PAGES:-10}; case "$MAXPAGES" in ''|*[!0-9]*) MAXPAGES=10 ;; esac

# Nothing is read from GitHub without somewhere to write it.
# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
if ! command -v job_ledger_put >/dev/null 2>&1 || ! command -v job_ledger_get >/dev/null 2>&1; then
  log "no jobs client ($H/bin/jobs-client.sh) — nothing read, nothing written"
  exit 0
fi
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" 2>/dev/null || { log "no $H/bin/lib/gh-rest.sh — nothing read, nothing written"; exit 1; }
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"

iso_ok() { [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; }

PUTS=0; CLOSED=0; OPEN=0; DEFERRED=0; SKIPPED=0; STOPPED=0; NPROJ=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/issue-state.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# ingest <project> <repo> — returns 0 when the project was read to the end,
# 1 when it stopped or deferred. Either way the watermark reached is written.
ingest() {
  local p=$1 repo=$2 wm rc since page=1 n item num state reason upd count stop=""
  wm=$(job_ledger_get issue_state_wm "$p"); rc=$?
  case "$rc" in
    0) if ! iso_ok "$wm"; then log "SKIP $p watermark [$wm] is not an ISO time"; SKIPPED=$((SKIPPED + 1)); return 1; fi ;;
    2) wm=$(date -u -d "@$(( $(date +%s) - DAYS * 86400 ))" '+%Y-%m-%dT%H:%M:%SZ') ;;
    *) log "SKIP $p watermark read failed (ledger rc $rc) — not guessed"; SKIPPED=$((SKIPPED + 1)); return 1 ;;
  esac
  since=$wm
  local start_wm=$wm
  command -v gh_default_auth_for_slug >/dev/null 2>&1 && { gh_default_auth_for_slug "$repo" >/dev/null 2>&1 || true; }
  while :; do
    if [ "$page" -gt "$MAXPAGES" ]; then stop="DEFERRED"; break; fi
    rc=0
    gh_rest GET "repos/$repo/issues?state=all&since=$since&sort=updated&direction=asc&per_page=100&page=$page" > "$TMP/page" || rc=$?
    if [ "$rc" != 0 ]; then
      log "STOP $p page $page gh rc $rc status ${GH_REST_STATUS:-?} ${GH_REST_REASON:-} — watermark held at $wm"
      stop="STOP"; break
    fi
    if ! jq -c '.[] | [.number, .state, (.state_reason // "-"), .updated_at, has("pull_request")]' "$TMP/page" > "$TMP/items" 2>/dev/null; then
      log "STOP $p page $page is not an issue list — watermark held at $wm"
      stop="STOP"; break
    fi
    count=$(grep -c . "$TMP/items")
    while IFS= read -r item; do
      num=$(jq -r '.[0]' <<<"$item"); state=$(jq -r '.[1]' <<<"$item")
      reason=$(jq -r '.[2]' <<<"$item"); upd=$(jq -r '.[3]' <<<"$item")
      if ! iso_ok "$upd"; then log "STOP $p item #$num has no usable updated_at — watermark held at $wm"; stop="STOP"; break; fi
      # A pull request is not an issue; skipping it is a decision, so the
      # watermark may pass it (a PR-heavy window would otherwise pin it).
      if [ "$(jq -r '.[4]' <<<"$item")" = true ]; then wm=$upd; continue; fi
      case "$state" in closed|open) ;; *) log "STOP $p #$num state [$state] — watermark held at $wm"; stop="STOP"; break ;; esac
      if [ "$PUTS" -ge "$MAXPUTS" ]; then stop="DEFERRED"; break; fi
      if ! job_ledger_put issue_state "$p#$num" "$state" "issue-state-ledger: $reason"; then
        log "STOP $p PUT $p#$num failed — watermark held at $wm"; stop="STOP"; break
      fi
      PUTS=$((PUTS + 1)); wm=$upd
      if [ "$state" = closed ]; then CLOSED=$((CLOSED + 1)); else OPEN=$((OPEN + 1)); fi
    done < "$TMP/items"
    [ -n "$stop" ] && break
    [ "$count" -lt 100 ] && break
    page=$((page + 1))
  done
  if [ "$wm" != "$start_wm" ]; then
    job_ledger_put issue_state_wm "$p" "$wm" "issue-state-ledger" \
      || log "STOP $p watermark PUT failed at $wm — next tick re-reads from $start_wm"
  fi
  if [ "$stop" = DEFERRED ]; then log "DEFERRED $p at $wm"; DEFERRED=$((DEFERRED + 1)); fi
  if [ "$stop" = STOP ]; then STOPPED=$((STOPPED + 1)); fi
  [ -z "$stop" ]
}

PROJECTS=$("$H/bin/fleet-conf.sh" --projects) || { log "fleet-conf.sh --projects failed — nothing read"; exit 1; }
for p in $PROJECTS; do
  bp=$("$H/bin/fleet-conf.sh" "$p" board_prefix 2>/dev/null) || continue
  repo=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || continue
  [ "$bp" = - ] || continue
  case "$repo" in ''|-) continue ;; esac
  NPROJ=$((NPROJ + 1))
  ingest "$p" "$repo"
  # The put cap is per tick: once spent, the rest wait for the next one.
  if [ "$PUTS" -ge "$MAXPUTS" ]; then break; fi
done

log "projects=$NPROJ puts=$PUTS closed=$CLOSED open=$OPEN deferred=$DEFERRED skipped=$SKIPPED stopped=$STOPPED"
exit 0
