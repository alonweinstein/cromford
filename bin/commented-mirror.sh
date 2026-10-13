#!/bin/bash
# bin/commented-mirror.sh <project> — BH-2526: a build dir's COMMENTED file,
# mirrored into a job_artifacts `commented` row, so the hub's alerts groomer
# (bin/alerts-groom.sh rule 3) can read "this build's result was handled" from
# the DB instead of ssh-ing to the box that holds the dir.
#
# Runs on the OWNING box, from bin/lib/rt/gate.sh on every triage tick (SKIP
# ticks included). Every existing `touch COMMENTED` site stays as it is; this is
# the one writer that turns the file into a row.
#
#   COMMENTED, no .commented-db stamp -> PUT commented <dir> on the dir's job id
#                                        (job.json .job_id), then write the stamp.
#   .commented-db stamp, no COMMENTED -> the build was relaunched in place
#                                        (resume-dead / run-build cleared it):
#                                        PUT commented `withdrawn` on the stamped
#                                        job id, then remove the stamp.
#
# WRITE, THEN STAMP. The stamp is only a "don't re-PUT" cache: losing it costs
# one idempotent re-PUT (the row upserts on job_id + kind). A PUT that fails
# leaves no stamp and stops the loop (the worker is down; the next tick retries).
#
# Bounded: COMMENTED_MIRROR_MAX actions per tick (settings row via the
# run-triage lane's knobs, default 25, 0 = off, not a whole number = do nothing
# and say so). Oldest dir first; the rest are counted `deferred` and drained on
# later ticks. A dir with no job id is skipped and counted `nojob`.
# Dedupe lock per project (flock -n): a second copy exits, it never waits.
set -uo pipefail
PROJECT="${1:-}"
[ -n "$PROJECT" ] || exit 0
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS}/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
# shellcheck source=bin/jobs-client.sh
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null || exit 0
declare -F job_artifact_put >/dev/null 2>&1 || exit 0
[ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || exit 0

LOG="$HARNESS/logs/commented-mirror.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$HARNESS/logs" "$HARNESS/locks" 2>/dev/null
exec 8>"$HARNESS/locks/commented-mirror-$PROJECT.lock"; flock -n 8 || exit 0

MAX="${COMMENTED_MIRROR_MAX-25}"
if ! [[ "$MAX" =~ ^[0-9]+$ ]]; then
  echo "$(STAMP) [$PROJECT] skipped: COMMENTED_MIRROR_MAX=$MAX is not a whole number" >> "$LOG"
  exit 0
fi
MAX=$((10#$MAX))
[ "$MAX" -gt 0 ] || exit 0

PUT=0 WD=0 NOJOB=0 DEFER=0 DONE=0 STOP=""
# Oldest mtime first, the dirs that need an action only.
while IFS= read -r D; do
  [ -n "$D" ] || continue
  if [ -f "$D/COMMENTED" ] && [ ! -f "$D/.commented-db" ]; then
    JID=$(jq -r '.job_id // ""' "$D/job.json" 2>/dev/null)
    [ -n "$JID" ] || { NOJOB=$((NOJOB+1)); continue; }
    [ "$DONE" -lt "$MAX" ] || { DEFER=$((DEFER+1)); continue; }
    DONE=$((DONE+1))
    job_artifact_put commented "$D" "$(jq -nc --arg b "$JOBS_BOX" '{box:$b}')" "$JID" || { STOP=" stopped: PUT to job $JID failed, the next tick retries"; break; }
    printf '%s\n' "$JID" > "$D/.commented-db" && PUT=$((PUT+1))
  elif [ ! -f "$D/COMMENTED" ] && [ -f "$D/.commented-db" ]; then
    JID=$(tr -dc 'A-Za-z0-9._:-' < "$D/.commented-db")
    [ -n "$JID" ] || { rm -f "$D/.commented-db"; continue; }
    [ "$DONE" -lt "$MAX" ] || { DEFER=$((DEFER+1)); continue; }
    DONE=$((DONE+1))
    job_artifact_put commented withdrawn "$(jq -nc --arg d "$D" '{dir:$d}')" "$JID" || { STOP=" stopped: withdraw on job $JID failed, the next tick retries"; break; }
    rm -f "$D/.commented-db" && WD=$((WD+1))
  fi
done < <(
  for D in "$HARNESS/builds/$PROJECT"-*/ "$HARNESS/builds/pool-$PROJECT"-*/; do
    [ -d "$D" ] || continue
    D="${D%/}"
    [ -f "$D/COMMENTED" ] || [ -f "$D/.commented-db" ] || continue
    [ -f "$D/COMMENTED" ] && [ -f "$D/.commented-db" ] && continue
    printf '%s\t%s\n' "$(stat -c %Y "$D" 2>/dev/null || echo 0)" "$D"
  done | sort -n -k1,1 | cut -f2-
)
# Silent when there was nothing to do: this runs on every triage tick.
[ "$DONE" -gt 0 ] || [ "$NOJOB" -gt 0 ] || exit 0
echo "$(STAMP) [$PROJECT] put=$PUT withdrawn=$WD nojob=$NOJOB deferred=$DEFER$STOP" >> "$LOG"
exit 0
