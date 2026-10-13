#!/bin/bash
# bin/sweep-stale-builds.sh — close abandoned build rows in the console ledger.
#
#   sweep-stale-builds.sh [--dry-run] [--hours N] [--max N]
#
# WHY THIS EXISTS. A build row whose attempt died without ever opening a PR has
# an empty pr_url, and bin/reconcile-prs.sh can only ever fix rows that HAVE a
# pr_url. So dead attempts accumulate forever in a non-terminal stage — 232 of
# them by 2026-08-24 — and Mission Control counts them as in flight. Nothing
# else in the fleet will ever close them.
#
# WHY IT IS A HUB JOB. The console can see that a row is old; it cannot see that
# a build is STILL RUNNING. The queue half of that answer comes from the D1
# build_queue rows, fleet-wide (since #229/#231). The pool half comes from the
# D1 machines rows (GET /api/machines?live=1) once fly_machines_rows is on
# (BH-2522), and from the hub's own state/fly-pool/ files while it is off —
# the pool runs on the hub, so those files are here. The mtimes under builds/
# are read on the hub only. No box is ssh'd to. Closing a row out from under a
# live builder would make it flap — the builder's next beat reopens it — so
# this script's real job is the subtraction, not the deletion.
#
# FAIL CLOSED. If an evidence source cannot be read, the live set is UNKNOWN,
# and unknown is not empty: the whole run is skipped rather than swept on a
# guess. A sweep that closes fewer rows is a nuisance; one that closes a running
# build is a bug that looks like the harness eating its own work.
#
# NEVER CLAIM A GREEN NOTHING. An empty feed, or an empty survivor set, is
# reported as exactly that and exits without a success line. The bug this whole
# lane came from was a query that returned {} being read as "all healthy".
#
# EXIT CODES (BH-1954). The hub lane runs this last in an `&&` chain with its
# output sent to /dev/null, so nothing there reads the rc; the ALERTS line is
# the operator signal. The rc is for a human or a test running it directly.
#   0  a clean sweep or a no-op: no console env, lock held, empty feed,
#      0 survivors, --dry-run
#   1  usage: an unknown argument, or survivors over --max (the brake)
#   3  a fail-closed refusal, always with ONE ALERTS line and no close POST:
#      feed unreadable, no bin/jobs-client.sh, build_queue read failed, a
#      build_queue page came back full (the live set may be truncated), or,
#      with fly_machines_rows on, the machines rows unreadable or a full page
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-sweep-stale-builds
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off sweep-stale-builds.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit sweep-stale-builds
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    sweep-stale-builds

DRY=0; HOURS=24; MAX=500
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --hours) HOURS=$(printf %s "${2:-24}" | tr -dc '0-9'); shift ;;
    --max)   MAX=$(printf %s "${2:-500}" | tr -dc '0-9'); shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done
HOURS="${HOURS:-24}"; MAX="${MAX:-500}"

LOG="$HARNESS/logs/sweep-stale-builds.log"
ALERTS="$HARNESS/logs/ALERTS.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { mkdir -p "$HARNESS/logs"; echo "$(STAMP) [sweep] $*" >> "$LOG"; }
BEAT="$HARNESS/bin/beat.sh"

[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || { say "no CONSOLE_URL/HARNESS_SECRET — not running"; exit 0; }
exec 9>"$HARNESS/locks/sweep-stale-builds.lock" 2>/dev/null || true
flock -n 9 2>/dev/null || { say "another sweep is running"; exit 0; }

# ---------- 1. the candidate feed ----------
FEED=$(curl -sS --max-time 60 -H "Authorization: Bearer $HARNESS_SECRET" \
  "$CONSOLE_URL/api/builds/stale?hours=$HOURS" 2>&1)
if ! jq -e '.builds' >/dev/null 2>&1 <<<"$FEED"; then
  say "stale feed unreadable — NOT sweeping. body: $(head -c 300 <<<"$FEED")"
  echo "$(STAMP) [sweep] stale-build feed unreadable, sweep skipped — $(head -c 200 <<<"$FEED")" >> "$ALERTS"
  exit 3
fi
CANDIDATES=$(jq -c '[.builds[]? | select(.bkey != null and .bkey != "")]' <<<"$FEED")
NCAND=$(jq 'length' <<<"$CANDIDATES")
if [ "${NCAND:-0}" -eq 0 ]; then
  # Not a success. The bug that created this lane was an empty result read as health.
  say "feed returned 0 candidates — nothing swept (this is not a clean sweep, it is an empty feed)"
  exit 0
fi
say "feed: $NCAND candidates older than ${HOURS}h"

# ---------- 2. what is actually alive ----------
# Three sources, all cheap, none of them ssh:
#   build_queue rows (D1)          queued or claimed, fleet-wide
#   machines rows (D1), flag on    a live pool machine carrying the key
#     state/fly-pool/<p>/*.json    the same, from the hub's files, flag off
#   builds/<...>-<KEY>-<ts>/       a directory still being written to, on the hub
LIVE_KEYS="$HARNESS/state/.sweep-live.$$"; : > "$LIVE_KEYS"
trap 'rm -f "$LIVE_KEYS" "$LIVE_KEYS.k"' EXIT

# ---------- 2a. the queue evidence comes from D1, not from ssh ----------------
# This used to be read off every box (state/build-queue/<p>/*.json) in the same
# ssh call as the pool and build-dir evidence. Two things broke that:
#   * a watcher NO LONGER WRITES that file once its row lands (2026-09-11), so
#     the ssh read now returns empty on exactly the boxes it was meant to cover,
#     and the sweep would count a queued build as dead;
#   * a row the hub has not materialised yet exists on NO box at all, so no
#     amount of ssh could see it.
# The rows answer both, fleet-wide, in two calls.
#
# QUEUED AND CLAIMED ARE BOTH LIVE. `claimed` means a dispatcher has taken
# custody and a machine is on it — the most alive a build gets before its dir
# exists. Terminal rows (done/failed) are deliberately absent: those keys SHOULD
# be sweepable.
#
# FAIL CLOSED, like every other evidence source here. If the ledger cannot be
# read, the live set is UNKNOWN, and unknown is not empty — the sweep does
# nothing this run rather than closing a row on a guess. A skipped sweep is a
# nuisance; closing a running build is the harness eating its own work.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# The same "is this build's ticket already over?" question bin/pipeline-health.sh
# checks 4 and 5 ask, answered by the same function so the two lanes agree
# (2026-09-15). Here it is ANNOTATION, not authority: it never overrides a HOLD.
# That rule is older and stricter than this one, and a survivor that the ledger calls merged was going to be
# closed anyway — what changes is that the audit line now says why.
# shellcheck source=bin/lib/closeout-terminal.sh
[ -r "$HARNESS/bin/lib/closeout-terminal.sh" ] && . "$HARNESS/bin/lib/closeout-terminal.sh"
if ! command -v queue_list >/dev/null 2>&1; then
  say "no bin/jobs-client.sh on this box — the queue evidence is UNKNOWN, NOT sweeping"
  echo "$(STAMP) [sweep] no bin/jobs-client.sh on this box, stale-build sweep skipped (queue evidence unknown)" >> "$ALERTS"
  exit 3
fi
# The worker's hard page cap (worker/jobs/src/routes/queue.js), not a business
# threshold. Asking for more is silently clamped to 500, and then a full page
# could never be told apart from a whole one, so this must not exceed the cap.
# A page with this many rows may be truncated: that is a refusal, not a live set.
QUEUE_PAGE=500
for QST in queued claimed; do
  if ! QROWS=$(queue_list "" "$QST" "" "" "$QUEUE_PAGE" 2>/dev/null); then
    say "build_queue read failed for status=$QST — the queue evidence is UNKNOWN, NOT sweeping"
    echo "$(STAMP) [sweep] coordination DB unreadable, stale-build sweep skipped (queue evidence would be a guess)" >> "$ALERTS"
    exit 3
  fi
  QROWN=$(printf '%s\n' "$QROWS" | grep -c . || true); QROWN="${QROWN:-0}"
  if [ "$QROWN" -ge "$QUEUE_PAGE" ]; then
    say "build_queue status=$QST returned a full page ($QROWN of $QUEUE_PAGE) — the live set may be truncated, NOT sweeping"
    echo "$(STAMP) [sweep] build_queue status=$QST returned a full page ($QROWN of $QUEUE_PAGE) — live set may be truncated, stale-build sweep skipped" >> "$ALERTS"
    exit 3
  fi
  printf '%s\n' "$QROWS" | awk -F'\t' 'NF>=2 && $1 != "" && $2 != "" { printf "K\t%s\t%s\n", $1, $2 }' >> "$LIVE_KEYS"
done
QN=$(grep -c . "$LIVE_KEYS" 2>/dev/null | head -1); QN="${QN:-0}"
say "queue evidence: $QN live key(s) from build_queue rows (no ssh)"

# ---------- 2b. the pool evidence is the machines rows (BH-2522) --------------
# This used to be an ssh read of every box's state/fly-pool/. Once
# fly_machines_rows is on, bin/fly-pool.sh keeps one row per pool machine
# (put on spawn/reuse, machines_observe every tick, close on destroy), and
# bin/fly-pool-rows-parity.sh only flips the flag after every pool file has its
# keyed row. So the rows are the fleet-wide answer, in one call. Same fail-closed
# rule and the same page cap as the queue read above: GET /api/machines is
# LIMIT 500 in the worker, and a page that full may be truncated.
# Flag off: the pool files on this box are the evidence (collect_local below).
POOL_FILES=1
if command -v machines_rows_on >/dev/null 2>&1 && machines_rows_on; then
  POOL_FILES=0
  MACHINES_PAGE=500
  if ! MROWS=$(machines_list "" live 2>/dev/null); then
    say "machines rows read failed — the pool evidence is UNKNOWN, NOT sweeping"
    echo "$(STAMP) [sweep] machines rows unreadable, stale-build sweep skipped (pool evidence would be a guess)" >> "$ALERTS"
    exit 3
  fi
  MROWN=$(printf '%s\n' "$MROWS" | grep -c . || true); MROWN="${MROWN:-0}"
  if [ "$MROWN" -ge "$MACHINES_PAGE" ]; then
    say "machines rows returned a full page ($MROWN of $MACHINES_PAGE) — the live set may be truncated, NOT sweeping"
    echo "$(STAMP) [sweep] machines rows returned a full page ($MROWN of $MACHINES_PAGE) — live set may be truncated, stale-build sweep skipped" >> "$ALERTS"
    exit 3
  fi
  # machines_list TSV: machine_id project app role key ticket state spawned_at last_seen
  printf '%s\n' "$MROWS" | awk -F'\t' 'NF>=5 && $2 != "" && $5 != "" { printf "K\t%s\t%s\n", $2, $5 }' > "$LIVE_KEYS.m"
  MN=$(grep -c . "$LIVE_KEYS.m" || true); MN="${MN:-0}"
  cat "$LIVE_KEYS.m" >> "$LIVE_KEYS"; rm -f "$LIVE_KEYS.m"
  say "pool evidence: $MN live key(s) from machines rows (no ssh)"
else
  say "fly_machines_rows off — pool evidence from this box's files"
fi

# Collectors emit two record kinds, resolved together below:
#   K<TAB><project><TAB><key>   an explicit key from a queue or pool json/row
#   D<TAB><basename>            a build directory that is still being written to
# Build-dir names are NOT split here: "alpha-os-TK-1-202608240100" cannot be cut
# by regex, because both the project and the ticket key contain hyphens and the
# boundary is genuinely ambiguous. They are matched against the known project
# list instead, which is exact.
collect_local() { # collect_local <root> <read-pool-files 0|1>
  local R="$1" PD=""
  [ "${2:-1}" = 1 ] && PD="$R/state/fly-pool/*/"
  # shellcheck disable=SC2086  # PD is a glob on purpose, empty when the rows are the evidence
  for D in "$R"/state/build-queue/*/ $PD; do
    [ -d "$D" ] || continue
    local P; P=$(basename "$D")
    for F in "$D"*.json; do
      [ -f "$F" ] || continue
      jq -r --arg p "$P" 'select(type=="object") | ["K", $p, (.key // "")] | @tsv' "$F" 2>/dev/null
    done
  done
  find "$R/builds" -maxdepth 1 -type d -mmin -120 2>/dev/null | while read -r B; do
    printf 'D\t%s\n' "$(basename "$B")"
  done
}

resolve_dirs() { # rewrite D records into K records using the real project list
  local projects="$1" line kind name P rest key
  while IFS=$'\t' read -r kind name rest; do
    if [ "$kind" != D ]; then printf '%s\t%s\t%s\n' "$kind" "$name" "$rest"; continue; fi
    for P in $projects; do
      case "$name" in
        "$P"-*|pool-"$P"-*|fly-"$P"-*)
          rest="${name#pool-}"; rest="${rest#fly-}"; rest="${rest#"$P"-}"
          key="${rest%-*}"                      # strip the trailing -<timestamp>
          [ -n "$key" ] && printf 'K\t%s\t%s\n' "$P" "$key"
          break ;;
      esac
    done
  done
}

collect_local "$HARNESS" "$POOL_FILES" >> "$LIVE_KEYS" 2>/dev/null
ALL_PROJECTS=$("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null | tr '\n' ' ')
resolve_dirs "$ALL_PROJECTS" < "$LIVE_KEYS" | cut -f2,3 | grep -v '^\s*$' | sort -u > "$LIVE_KEYS.k" 2>/dev/null
mv -f "$LIVE_KEYS.k" "$LIVE_KEYS" 2>/dev/null
NLIVE=$(grep -c . "$LIVE_KEYS" 2>/dev/null || true); NLIVE="${NLIVE:-0}"
say "live keys across the fleet: $NLIVE"

# ---------- 3. subtract ----------
SURVIVORS="$HARNESS/state/.sweep-survivors.$$"; : > "$SURVIVORS"
HELD=0; TERMN=0
while IFS=$'\t' read -r BKEY PROJ TKEY STAGE AGE PRURL; do
  [ -n "$BKEY" ] || continue
  if [ -n "$TKEY" ] && grep -qxF "$(printf '%s\t%s' "$PROJ" "$TKEY")" "$LIVE_KEYS" 2>/dev/null; then
    say "HOLD $BKEY ($PROJ $TKEY) — still live on a box"
    HELD=$((HELD+1)); continue
  fi
  # Survivors only: a HOLD is never asked, so live evidence keeps costing
  # nothing. An outage answers rc 1 and the row is simply unannotated.
  # Not named TERM: that is the exported terminal-type variable every child
  # process inherits, and this loop spawns curl.
  TERMST=""
  if [ -n "${PRURL:-}" ] && type closeout_terminal >/dev/null 2>&1; then
    TERMST=$(closeout_terminal "$PRURL" "" 2>/dev/null) || TERMST=""
    [ -n "$TERMST" ] && TERMN=$((TERMN+1))
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$BKEY" "$PROJ" "$TKEY" "$STAGE" "$AGE" "$TERMST" >> "$SURVIVORS"
done < <(jq -r '.[] | [.bkey, (.project // ""), (.ticket_key // ""), (.stage // ""), (.updated_at // ""), (.pr_url // "")] | @tsv' <<<"$CANDIDATES")

NSURV=$(grep -c . "$SURVIVORS" 2>/dev/null || true); NSURV="${NSURV:-0}"
if [ "$NSURV" -eq 0 ]; then
  say "0 survivors of $NCAND candidates (held live: $HELD) — nothing swept"
  rm -f "$SURVIVORS"; exit 0
fi
[ "$NSURV" -le "$MAX" ] || { say "REFUSING: $NSURV survivors exceeds --max $MAX — rerun with a higher cap if that is really intended"; rm -f "$SURVIVORS"; exit 1; }

# ---------- 4. close, in batches, with an audit trail ----------
if [ "$DRY" = 1 ]; then
  say "DRY RUN — would close $NSURV (held live: $HELD · terminal per ledger: $TERMN)"
  while IFS=$'\t' read -r BKEY PROJ TKEY STAGE AGE TERMST; do
    say "would close $BKEY project=$PROJ ticket=$TKEY stage=$STAGE updated_at=$AGE${TERMST:+ terminal=$TERMST}"
  done < "$SURVIVORS"
  rm -f "$SURVIVORS"; exit 0
fi

CLOSED=0; FAILED=0
while :; do
  BATCH=$(head -100 "$SURVIVORS"); [ -n "$BATCH" ] || break
  BODY=$(cut -f1 <<<"$BATCH" | jq -Rnc '{closed: [inputs | select(. != "")]}')
  RESP=$(curl -sS --max-time 60 -X POST -H "Authorization: Bearer $HARNESS_SECRET" \
    -H 'Content-Type: application/json' -d "$BODY" "$CONSOLE_URL/api/builds/close" 2>&1)
  if jq -e '.ok == true' >/dev/null 2>&1 <<<"$RESP"; then
    N=$(jq -r '.updated // 0' <<<"$RESP")
    CLOSED=$((CLOSED + N))
    # One audit line per row, so 232 mutations can be read back later.
    while IFS=$'\t' read -r BKEY PROJ TKEY STAGE AGE TERMST; do
      say "CLOSED $BKEY project=$PROJ ticket=$TKEY was_stage=$STAGE updated_at=$AGE${TERMST:+ terminal=$TERMST}"
    done <<<"$BATCH"
  else
    FAILED=$((FAILED + $(grep -c . <<<"$BATCH")))
    say "batch REFUSED by the console: $(head -c 200 <<<"$RESP")"
  fi
  sed -i.bak '1,100d' "$SURVIVORS" 2>/dev/null || { tail -n +101 "$SURVIVORS" > "$SURVIVORS.n"; mv "$SURVIVORS.n" "$SURVIVORS"; }
  rm -f "$SURVIVORS.bak"
done
rm -f "$SURVIVORS"

say "swept $CLOSED of $NCAND candidates (held live: $HELD · terminal per ledger: $TERMN · failed: $FAILED)"
"$BEAT" "$(jq -nc --arg rk "sweep:$(date +%s)" --argjson c "$CLOSED" --argjson h "$HELD" \
  --argjson f "$FAILED" --argjson n "$NCAND" --arg ts "$(STAMP)" \
  '{kind:"fleet_event",rkey:$rk,project:"fleet",event:"stale_build_sweep",
    candidates:$n,closed:$c,held_live:$h,failed:$f,ts:$ts}')" >/dev/null 2>&1 || true
[ "$FAILED" -eq 0 ] || echo "$(STAMP) [sweep] $FAILED stale-build rows were refused by the console — see $LOG" >> "$ALERTS"
exit 0
