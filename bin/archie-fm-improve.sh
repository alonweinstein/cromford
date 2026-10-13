#!/bin/bash
# bin/archie-fm-improve.sh — BH-4587 (BH-4574.5): Archie's self-improvement
# loop. A hub lane that reads the rows waves 1-4 already write to archie_actions,
# fingerprints each one by cause, and files ONE ai-build issue per cause that
# keeps coming back (bin/lib/archie-fm-improve/). Archie does not write the fix.
#
#   archie-fm-improve.sh [tick]            the cron line, hourly at :43
#   archie-fm-improve.sh --dry-list        one TSV line per fingerprint seen
#                                          (fp, count in the window, state,
#                                          cause); no row, no GitHub write
#   archie-fm-improve.sh section <from-iso> <to-iso>
#                                          "Factory fixes shipped" for a week;
#                                          bin/archie-learn.sh's weekly report
#                                          calls it. Read-only, no lock.
#
# TICK, in this order:
#   1. lane_gate_or_exit / lane_env_apply archie-fm-improve; ARCHIE_FMI_ENABLED=0
#      exits; the mode is afm_mode hub (archie.manage.hub > archie.manage > on),
#      and off exits before any read; flock -n locks/archie-fm-improve.lock
#      (held = skip, never wait). NOW is read once (ARCHIE_FMI_NOW only under
#      HARNESS_TEST_SANDBOX=1). The outer `timeout` (900 s) is the backstop; the
#      tick's own deadline is 780 s.
#   2. the settings (archie.improve.recur_n 3, window_days 7, tickets_per_day 3,
#      verify_days 7, verify_grace_s 3600, archie.cap.improve 10). A junk row is
#      one log line and no action.
#   3. READ: GET /api/archie/actions?day=<d>&limit=500 (and &playbook=improve)
#      for window_days + verify_days + 1 UTC days. A failed or truncated day
#      sets incomplete=1: filing and reopening still run (a lower bound that
#      reaches recur_n is true), verifying does not.
#   4. FINGERPRINT (afi_cause / afi_fp) and group into occurrences.
#   5. GITHUB LISTS (afi_issue_lists) BEFORE any claim: the archie-fm-improve
#      label list (state=all) and the open issues of $HARNESS_REPO. Unreadable
#      or over the page cap = no claim this tick, one log line.
#   6. per fingerprint (afi_handle): file, comment, track, reopen or verify.
#   7. one line in logs/archie-fm-improve.log per tick that did anything:
#      <ts> fps=<n> recurring=<n> filed=<n> commented=<n> reopened=<n> tracked=<n> verified=<n> would=<n> capped=<n> skipped=<n> failed=<n> incomplete=<0|1>
#
# EVERY GITHUB WRITE IS AN archie_actions ROW (playbook improve, pr 0), claimed
# before the write. Observe mode writes would_* rows and nothing else.
# NEVER: a git command, a push, a PR, a merge, a model call, or a state file.
#
# OFF: ARCHIE_FMI_ENABLED=0, flags/lane-off-archie-fm-improve,
# bin/harness-ctl.sh off archie-fm-improve, or archie.manage[.hub]=off.
# Registry: catalog/lanes.d/archie-fm-improve.json.
# Note: docs/notes/2026-10-11-BH-4587-archie-fm-improve.md.
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
CMD=tick; DRY_LIST=0; S_FROM=""; S_TO=""
case "${1:-}" in
  ''|tick) ;;
  --dry-list) DRY_LIST=1 ;;
  section)
    CMD=section; S_FROM="${2:-}"; S_TO="${3:-}"
    [ -n "$S_FROM" ] && [ -n "$S_TO" ] || { echo "usage: archie-fm-improve.sh section <from-iso> <to-iso>" >&2; exit 2; } ;;
  *) echo "usage: archie-fm-improve.sh [tick] | --dry-list | section <from-iso> <to-iso>" >&2; exit 2 ;;
esac
if [ "$CMD" = tick ] && [ "${ARCHIE_FMI_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  DL=(); [ "$DRY_LIST" = 1 ] && DL=(--dry-list)
  ARCHIE_FMI_TIMED=1 exec timeout -k 60 900 bash "$0" ${DL[@]+"${DL[@]}"}
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# BH-4080: HARNESS_REPO's default lives in the deployment defaults home.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" || exit 1
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-queue/common.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-improve/common.sh" 2>/dev/null || true
  . "$SELF/lib/archie-fm-improve/tickets.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${ARCHIE_FMI_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$ARCHIE_FMI_FIXTURE"
fi
for f in afm_mode afm_close afm_log _afm_req _jobs_req setting_get afq_claim afq_close afq_close_stale \
         afi_cause afi_fp afi_read_days afi_occurrences afi_settings_load afi_section afi_issue_lists afi_handle; do
  command -v "$f" >/dev/null 2>&1 || { echo "archie-fm-improve: $f is not defined (a lib is missing)" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "archie-fm-improve: jq missing" >&2; exit 1; }

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${ARCHIE_FMI_NOW:-} =~ ^[0-9]+$ ]]; then NOW=$ARCHIE_FMI_NOW; fi
[ -n "$NOW" ] || NOW=$(date -u +%s)
DAY=$(date -u -d "@$NOW" +%F)
AFQ_ACTOR=archie-fm-improve
AFM_ROUTE_ABSENT=0; AFM_ROW=""
WORK=$(mktemp -d "${TMPDIR:-/tmp}/afi.XXXXXX") || { echo "archie-fm-improve: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
AFI_ROWS="$WORK/rows.jsonl"; AFI_IMP="$WORK/imp.jsonl"; AFI_OCC="$WORK/occ.jsonl"
AFI_LBL="$WORK/lbl.jsonl"; AFI_OPEN="$WORK/open.jsonl"
: > "$AFI_ROWS"; : > "$AFI_IMP"; : > "$AFI_OCC"; : > "$AFI_LBL"; : > "$AFI_OPEN"

if [ "$CMD" = section ]; then
  # Read-only: no lock, no gate, no log line. Prints ONE "Factory fixes
  # shipped:" line first, whatever happens.
  AFM_LOG=""
  if ! SF=$(afi_epoch "$S_FROM") || ! ST=$(afi_epoch "$S_TO"); then
    echo "Factory fixes shipped: not measured (the week '$S_FROM' to '$S_TO' is not two dates)"; exit 0
  fi
  afi_section "$SF" "$ST"
  exit 0
fi

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
AFM_LOG="$H/logs/archie-fm-improve.log"
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit archie-fm-improve
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply archie-fm-improve
case "${ARCHIE_FMI_ENABLED:-1}" in
  0) exit 0 ;;
  1) ;;
  *) afi_log "warn: ARCHIE_FMI_ENABLED=${ARCHIE_FMI_ENABLED} is not 0 or 1; using the default 1" ;;
esac
if ! AFI_MODE=$(afm_mode hub); then afi_log "archie.manage could not be read; nothing done this tick"; exit 0; fi
[ "$AFI_MODE" = off ] && exit 0
if [ "$DRY_LIST" = 0 ]; then
  exec 9>"$H/locks/archie-fm-improve.lock" || exit 0
  flock -n 9 || exit 0
fi
case "${ARCHIE_FMI_RETRY_S:-1800}" in
  ''|*[!0-9]*) afi_log "warn: ARCHIE_FMI_RETRY_S=${ARCHIE_FMI_RETRY_S} is not a whole number; using the default 1800"; AFQ_RETRY_S=1800 ;;
  *) AFQ_RETRY_S=$((10#${ARCHIE_FMI_RETRY_S:-1800})) ;;
esac
AFI_DEADLINE=$(( $(date +%s) + 780 ))
AFI_REPO=${HARNESS_REPO:-}
afi_on_term() {
  trap - TERM INT HUP
  if [ -n "$AFM_ROW" ] && [ "$(jq -r .outcome <<<"$AFM_ROW" 2>/dev/null)" = started ]; then
    afm_close failed "" "the tick was stopped mid-action (its backstop or a signal); not retried on this key" \
      && afi_log "$(jq -r .dedupe_key <<<"$AFM_ROW"): the tick was stopped mid-action; the row is failed"
  fi
}
trap 'afi_on_term; exit 143' TERM INT HUP

afi_settings_load || exit 0
READ_D=$(( AFI_WINDOW_D + AFI_VERIFY_D + 1 ))
if ! afi_read_days "$(( NOW - (READ_D - 1) * 86400 ))" "$READ_D"; then
  afi_log "archie_actions route absent (HTTP 404 from the jobs worker); nothing done"; exit 0
fi
afi_occurrences
AFI_N_FPS=$(jq -sr --argjson a "$(( NOW - AFI_WINDOW_D * 86400 ))" '[.[] | select(.t > $a) | .fp] | unique | length' "$AFI_OCC")

GH_OK=1
if [ -z "$AFI_REPO" ] || ! command -v gh_rest >/dev/null 2>&1; then
  afi_log "not configured (HARNESS_REPO='$AFI_REPO', gh_rest $(command -v gh_rest >/dev/null 2>&1 && echo loaded || echo absent)); no claim"
  GH_OK=0
elif ! afi_issue_lists; then
  GH_OK=0
fi

FPS=$( { jq -r --argjson a "$(( NOW - AFI_WINDOW_D * 86400 ))" 'select(.t > $a) | .fp' "$AFI_OCC"
         jq -r '.fp // empty' "$AFI_LBL"; } | LC_ALL=C sort -u)

if [ "$DRY_LIST" = 1 ]; then
  for fp in $FPS; do
    cnt=$(afi_occ_of "$fp" "$(( NOW - AFI_WINDOW_D * 86400 ))" | jq length)
    c=$(afi_occ_of "$fp" | jq -r '.[0].c // empty'); iss=$(afi_issue_of "$fp")
    if [ "$GH_OK" = 0 ]; then state=unknown
    elif [ -n "$iss" ]; then state=$(jq -r '"#\(.n) \(.state)" + (if .reason == "" then "" else " \(.reason)" end)' <<<"$iss")
    elif [ "$cnt" -ge "$AFI_RECUR_N" ]; then state=recurring
    else state=watching; fi
    [ -n "$c" ] || c=$(jq -r '.cause // empty' <<<"${iss:-null}")
    printf '%s\t%s\t%s\t%s\n' "$fp" "$cnt" "$state" "$c"
  done
  [ "$AFI_INCOMPLETE" = 1 ] && echo "# incomplete: a day could not be read in full (see logs/archie-fm-improve.log)" >&2
  exit 0
fi

if [ "$GH_OK" = 1 ]; then
  afi_cap_load
  # A started row this lane left behind (a tick that died after its claim)
  # whose day-keyed key is never claimed again: closed failed, one alert.
  while IFS= read -r AFM_ROW; do
    [ -n "$AFM_ROW" ] && afq_close_stale >/dev/null 2>&1
  done < <(jq -c --arg a "$AFQ_ACTOR" 'select(.outcome == "started" and .mode == "on" and .actor == $a)' "$AFI_IMP")
  AFM_ROW=""
  for fp in $FPS; do
    rc=0; afi_handle "$fp" || rc=$?
    [ "$rc" = 2 ] && AFM_ROUTE_ABSENT=1
    [ "$AFM_ROUTE_ABSENT" = 1 ] && { afi_log "archie_actions route absent (HTTP 404 from the jobs worker); the tick stopped"; break; }
    if [ "$(( AFI_DEADLINE - $(date +%s) ))" -le 0 ]; then
      afi_log "the tick's 780 s deadline passed; the rest wait for the next tick"; AFI_INCOMPLETE=1; break
    fi
  done
fi
SUM=$((AFI_N_FILED + AFI_N_COMMENTED + AFI_N_REOPENED + AFI_N_TRACKED + AFI_N_VERIFIED + AFI_N_WOULD + AFI_N_CAPPED + AFI_N_SKIPPED + AFI_N_FAILED + AFI_INCOMPLETE + AFI_N_RECUR))
[ "$GH_OK" = 0 ] && [ -n "$FPS" ] && SUM=$((SUM + 1))
[ "$SUM" -gt 0 ] && afi_log "fps=$AFI_N_FPS recurring=$AFI_N_RECUR filed=$AFI_N_FILED commented=$AFI_N_COMMENTED reopened=$AFI_N_REOPENED tracked=$AFI_N_TRACKED verified=$AFI_N_VERIFIED would=$AFI_N_WOULD capped=$AFI_N_CAPPED skipped=$AFI_N_SKIPPED failed=$AFI_N_FAILED incomplete=$AFI_INCOMPLETE"
exit 0
