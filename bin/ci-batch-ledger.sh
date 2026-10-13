#!/bin/bash
# bin/ci-batch-ledger.sh — what did each merge-queue batch's CI run cost, and
# what did it test? One worker row per run (hub, cron every 30 min).
#
# WHY (BH-4971, BH-4964.3). BH-4968 made a merge-queue batch run its impact set
# instead of the whole corpus, and bin/ci-plan.sh now prints one notice per
# batch: `::notice title=ci-plan::mode=<m> count=<c> total=<t> n=<n> reason=<r>`.
# This lane pairs that notice with what the run billed, so the before/after
# median cost per batch can be read from GET /api/ci-batches instead of guessed.
#
# PER TICK, each step a stop when it fails:
#   1. no JOBS_URL or HARNESS_SECRET: log "not configured", exit 0, no read.
#   2. bin/lib/gh-budget.sh says the bucket is low: log, exit 0, no read.
#   3. the SKIP-SET, before any GitHub read: GET /api/ci-batches for the window.
#      Unreadable or truncated = no GitHub read this tick (an incomplete
#      skip-set would re-read recorded runs every tick).
#   4. the completed pull_request runs of harness-ci.yml created in the last
#      CI_BATCH_LEDGER_DAYS days, 100 a page, at most CI_BATCH_LEDGER_PAGES
#      pages. Kept: head_branch starting mergify/merge-queue/, not in the
#      skip-set at its current run_attempt, oldest first so a backfill drains
#      forward. A recorded run whose GitHub run_attempt is past the row's is a
#      re-run: it is read again and its row overwritten.
#   5. at most CI_BATCH_LEDGER_MAX of them (the rest are deferred to the next
#      tick): the run's jobs of EVERY attempt (filter=all, 100 a page, at most
#      CI_BATCH_LEDGER_PAGES pages), then the plan job's check-run annotations.
#      billed_min = sum of ceil(job seconds / 60) over jobs whose labels or runner name
#      contain CI_MINUTES_RUNNER_MATCH, the per-job rounding bin/ci-minutes-watch.sh
#      uses, WITHOUT its CI_MINUTES_BILL_MULT: the row stores rounded job-minutes
#      and a reader multiplies by the bill rate. No ci-plan notice (a run from
#      before BH-4968) = mode full-legacy, selected and total NULL. A jobs or
#      annotations read that FAILS, or a jobs list longer than the pages read,
#      records nothing; the next tick retries it. wall_s and conclusion are the
#      latest attempt's (GitHub's run_started_at moves to each attempt's start).
#   6. one PUT /api/ci-batches per run (an upsert on run_id). A failed PUT is a
#      log line and no row, so the next tick's skip-set read retries it.
# Worst case per tick: PAGES + (PAGES + 1) x MAX GitHub reads (125 at the
# defaults); a batch attempt runs well under 100 jobs, so a run is 2 reads in
# practice and a tick PAGES + 2 x MAX (45).
# Nothing local is written but the log.
#
# usage: ci-batch-ledger.sh [--dry-run]    --dry-run reads and prints each row; no PUT
# Kill switch: bin/harness-ctl.sh off ci-batch-ledger (flags/lane-off-ci-batch-ledger)
# Tests: tests/ci-batch-ledger.bh-4964-test.sh
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# >>> lane gate (BH-1165)
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit ci-batch-ledger
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# CI_MINUTES_RUNNER_MATCH is ci-minutes-watch's knob (one owner, one settings
# row): read off that lane's contract, then this lane's own knobs.
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply ci-minutes-watch
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply ci-batch-ledger
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"; [ -n "$BIN" ] || BIN="$H/bin"
for _L in gh-budget.sh gh-ci-read.sh gh-repo-token.sh; do
  # shellcheck source=/dev/null
  if [ -r "$BIN/lib/$_L" ]; then . "$BIN/lib/$_L"; elif [ -r "$H/bin/lib/$_L" ]; then . "$H/bin/lib/$_L"; fi
done
# shellcheck source=/dev/null
. "$BIN/jobs-client.sh" 2>/dev/null || . "$H/bin/jobs-client.sh" 2>/dev/null || true
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY=1
NOW="${NOW:-$(date +%s)}"
LOG="$H/logs/ci-batch-ledger.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
STAMP() { date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ'; }
log() { echo "$(STAMP) $*" >> "$LOG"; [ -n "$DRY" ] && echo "$*"; return 0; }
knob() { # knob <ENV> <default> — row/env via lane_env_apply, else the default; a positive integer
  local v="${!1:-}"
  case "$v" in ''|*[!0-9]*|0) v="$2" ;; esac
  printf '%s' "$v"
}
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$BIN/lib/deployment.sh}" || exit 1  # BH-4080: HARNESS_REPO
REPO="${CI_BATCH_LEDGER_REPO:-$HARNESS_REPO}"
MAX=$(knob CI_BATCH_LEDGER_MAX 20)
DAYS=$(knob CI_BATCH_LEDGER_DAYS 7)
PAGES=$(knob CI_BATCH_LEDGER_PAGES 5)
MATCH="${CI_MINUTES_RUNNER_MATCH:-monkci}"
SINCE=$(date -u -d "@$(( NOW - DAYS * 86400 ))" '+%Y-%m-%dT%H:%M:%SZ')

# 1. no worker to record into
if ! command -v jobs_configured >/dev/null 2>&1 || ! jobs_configured || [ -z "${HARNESS_SECRET:-}" ]; then
  log "not configured (JOBS_URL/HARNESS_SECRET unset) — nothing recorded"
  exit 0
fi
# 2. the GitHub budget
if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low ci-batch-ledger; then
  log "skipped: the GitHub API budget is low (bin/lib/gh-budget.sh) — no reads this tick"
  exit 0
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ci-batch-ledger.XXXXXX") || { log "mktemp failed — nothing read"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

# 3. the skip-set, before any GitHub read
ENC=$(jq -rn --arg r "$REPO" '$r | @uri')
if ! _jobs_req GET "/api/ci-batches?repo=$ENC&since=$SINCE&limit=5000" > "$TMP/ledger" 2>/dev/null; then
  log "ledger unreadable (http=${JOBS_HTTP:-none}) — no GitHub reads this tick"
  exit 0
fi
# run_id -> the attempt its row was read at (a row without one counts as 1)
if ! SKIP=$(jq -ce 'if (.rows | type) == "array" then [.rows[] | {key: (.run_id | tostring), value: (.run_attempt // 1)}] | from_entries else error("no rows") end' "$TMP/ledger" 2>/dev/null); then
  log "ledger unreadable (http=${JOBS_HTTP:-none}, no rows array) — no GitHub reads this tick"
  exit 0
fi
if [ "$(jq -r '.truncated' "$TMP/ledger")" = true ]; then
  log "ledger truncated at 5000 rows since $SINCE — the skip-set is incomplete, no GitHub reads this tick"
  exit 0
fi

command -v gh_repo_use_token >/dev/null 2>&1 && { gh_repo_use_token "$REPO" 2>/dev/null \
  || { log "repo=$REPO: no token can read it — nothing recorded"; exit 0; }; }

# 4. the run list
echo '[]' > "$TMP/runs"; FULL=0
for (( pg = 1; pg <= PAGES; pg++ )); do
  if ! gh_ci_api "$REPO" -X GET "repos/$REPO/actions/workflows/harness-ci.yml/runs" -f status=completed \
       -f event=pull_request -f "created=>=$SINCE" -f per_page=100 -f "page=$pg" > "$TMP/page" 2>/dev/null \
     || ! jq -e '.workflow_runs | type == "array"' "$TMP/page" >/dev/null 2>&1; then
    log "repo=$REPO: runs page $pg unreadable — nothing recorded this tick"
    exit 0
  fi
  jq -c --slurpfile p "$TMP/page" '. + $p[0].workflow_runs' "$TMP/runs" > "$TMP/runs.n" && mv "$TMP/runs.n" "$TMP/runs"
  [ "$(jq '.workflow_runs | length' "$TMP/page")" -ge 100 ] || { FULL=0; break; }
  FULL=1
done
[ "$FULL" = 1 ] && log "repo=$REPO: window not fully read (CI_BATCH_LEDGER_PAGES=$PAGES pages all full) — older runs wait"
jq -c --argjson skip "$SKIP" 'def done: ($skip[.id | tostring] // 0) >= (.run_attempt // 1);
  [unique_by(.id)[]
    | select((.head_branch // "") | startswith("mergify/merge-queue/"))] as $q
  | {queue: ($q | length),
     already: ([$q[] | select(done)] | length),
     todo: ([$q[] | select(done | not)] | sort_by(.run_started_at // "", .id))}' \
  "$TMP/runs" > "$TMP/cand" || { log "repo=$REPO: run list did not parse — nothing recorded"; exit 0; }
read -r QN ALREADY TODO <<<"$(jq -r '"\(.queue) \(.already) \(.todo | length)"' "$TMP/cand")"

# 5. each candidate, up to MAX
REC=0; PFAIL=0; UNREAD=0; DEFER=0
[ "$TODO" -gt "$MAX" ] && DEFER=$(( TODO - MAX ))
while IFS= read -r RUN; do
  [ -n "$RUN" ] || continue
  ID=$(jq -r .id <<<"$RUN")
  # Every attempt's jobs: the default filter=latest drops a re-run's earlier,
  # already-billed attempts.
  echo '{"jobs":[]}' > "$TMP/jobs"; JOK=""; JTOTAL=0
  for (( jp = 1; jp <= PAGES; jp++ )); do
    if ! gh_ci_api "$REPO" "repos/$REPO/actions/runs/$ID/jobs?filter=all&per_page=100&page=$jp" > "$TMP/jpage" 2>/dev/null \
       || ! jq -e '.jobs | type == "array"' "$TMP/jpage" >/dev/null 2>&1; then
      JOK=""; break
    fi
    jq -c --slurpfile p "$TMP/jpage" '.jobs += $p[0].jobs' "$TMP/jobs" > "$TMP/jobs.n" && mv "$TMP/jobs.n" "$TMP/jobs"
    JTOTAL=$(jq -r '.total_count // 0' "$TMP/jpage")
    JOK=1
    [ "$(jq '.jobs | length' "$TMP/jpage")" -ge 100 ] || break
  done
  if [ -z "$JOK" ]; then
    log "run $ID: jobs unreadable — unread, retried next tick"; UNREAD=$(( UNREAD + 1 )); continue
  fi
  JN=$(jq '.jobs | length' "$TMP/jobs")
  if [ "$JN" -lt "$JTOTAL" ]; then
    log "run $ID: $JN of $JTOTAL jobs read in CI_BATCH_LEDGER_PAGES=$PAGES pages — unread, retried next tick"; UNREAD=$(( UNREAD + 1 )); continue
  fi
  BILLED=$(jq -r --arg m "$MATCH" '[.jobs[] | select(.started_at and .completed_at)
      | select([.labels[]?, (.runner_name // "")] | map(ascii_downcase) | any(contains($m | ascii_downcase)))
      | (((.completed_at | fromdateiso8601) - (.started_at | fromdateiso8601)) / 60) | select(. > 0) | ceil]
      | add // 0' "$TMP/jobs")
  CID=$(jq -r 'first(.jobs | sort_by(.run_attempt // 1) | reverse[] | select((.name // "") | startswith("CI plan"))) | .check_run_url // "" | split("/") | last' "$TMP/jobs")
  NOTICE=""
  if [ -n "$CID" ]; then
    if ! gh_ci_api "$REPO" "repos/$REPO/check-runs/$CID/annotations?per_page=100" > "$TMP/ann" 2>/dev/null \
       || ! jq -e 'type == "array"' "$TMP/ann" >/dev/null 2>&1; then
      log "run $ID: plan annotations unreadable (check-run $CID) — unread, retried next tick"; UNREAD=$(( UNREAD + 1 )); continue
    fi
    NOTICE=$(jq -r 'map(select(.title == "ci-plan")) | last | .message // ""' "$TMP/ann")
  fi
  BODY=$(jq -cn --argjson r "$RUN" --arg repo "$REPO" --arg n "$NOTICE" --argjson billed "${BILLED:-0}" '
      def kv($k): ($n | capture("(^| )" + $k + "=(?<v>[^ ]*)") | .v) // null;
      def int($k): kv($k) | if . != null and test("^[0-9]+$") then tonumber else null end;
      (if $n == "" then null else kv("mode") end) as $mode
      | (($n | capture(" reason=(?<v>.*)$") | .v) // null) as $reason
      | {run_id: $r.id, repo: $repo, head_ref: $r.head_branch, head_sha: $r.head_sha,
         mode: ($mode // "full-legacy"),
         selected: (if $mode then int("count") else null end),
         total: (if $mode then int("total") else null end),
         escalation: (if $mode == "full" and $reason then ($reason | sub("^full: "; "") | sub("; tiers: .*$"; "")) else null end),
         conclusion: $r.conclusion, run_attempt: ($r.run_attempt // 1), started_at: $r.run_started_at, completed_at: $r.updated_at,
         wall_s: (if $r.run_started_at and $r.updated_at
                  then (($r.updated_at | fromdateiso8601) - ($r.run_started_at | fromdateiso8601)) else null end),
         billed_min: $billed}') || { log "run $ID: row did not build — unread"; UNREAD=$(( UNREAD + 1 )); continue; }
  if [ -n "$DRY" ]; then echo "$BODY"; continue; fi
  if _jobs_req PUT /api/ci-batches "$BODY" >/dev/null 2>&1; then
    REC=$(( REC + 1 ))
  else
    log "PUT failed run $ID (http=${JOBS_HTTP:-none}) — retried next tick"; PFAIL=$(( PFAIL + 1 ))
  fi
done < <(jq -c --argjson k "$MAX" '.todo[:$k][]' "$TMP/cand")
command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset

# 6. the summary
[ "$DEFER" -gt 0 ] && log "repo=$REPO: deferred $DEFER to next tick (CI_BATCH_LEDGER_MAX=$MAX)"
log "repo=$REPO queue_runs=$QN already=$ALREADY recorded=$REC put_failed=$PFAIL unread=$UNREAD deferred=$DEFER${DRY:+ (dry run, nothing sent)}"
exit 0
