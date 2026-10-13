#!/bin/bash
# healthcheck.sh <project> — daily prod liveness beat (cron).
# Curls the client-facing prod domain; a non-2xx/3xx (or timeout) raises a
# fleet_alert beat (deduped per day) + ALERTS line. Catches the "app dark /
# LLM features silently down" class (project-3 2026-07-15..20) at day-1, not day-5.
# If the app exposes /api/health (see per-board follow-up tickets), it is
# preferred over / so LLM/key failures surface too.
set -uo pipefail
PROJECT="${1:?project}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
# shellcheck source=bin/lib/flag-on.sh
. "$HARNESS/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$HARNESS/flags/$1-$2" ]; }

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-healthcheck
# (or its project row) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off healthcheck <project>.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit healthcheck "$PROJECT"
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    healthcheck "$PROJECT"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# ── timezone check (BH-445) ─────────────────────────────────────────────────
# Before the /tmp sweep and before the prod-URL early exits, so it runs for a
# project with no prod surface too. Guarded on the lib's presence (fixtures copy
# this file alone) and never changes this script's exit code.
# shellcheck disable=SC1090,SC1091
[ -r "$HARNESS/bin/lib/tz-check.sh" ] && { . "$HARNESS/bin/lib/tz-check.sh"; tz_check "$HARNESS" || true; }

# ── /tmp age sweep (2026-08-23 heap audit) ─────────────────────────────────
# /tmp is tmpfs on this fleet, so stale build checkouts are RAM: project-2 carried
# 6GB (incl. a July zombie's cwd), project-4 4GB, and pipeline-health's 85% gate
# never fired because chronic waste sat just under it. Every healthcheck tick,
# drop top-level /tmp entries older than 3 days — except live session/state
# dirs and anything a running process still calls cwd. Cheap when clean.
# HEALTHCHECK_TMP_ROOT is set nowhere in production — it exists so a fixture can
# run this whole script without a sweep of the real /tmp on the box running it.
LIVE_CWDS=$(readlink /proc/[0-9]*/cwd 2>/dev/null | sort -u)
find "${HEALTHCHECK_TMP_ROOT:-/tmp}" -maxdepth 1 -mindepth 1 -mtime +3 \
  ! -name "claude-*" ! -name "edit-feedback-*" ! -name "node-compile-cache" \
  ! -name "systemd-*" ! -name "rtk-*" 2>/dev/null | while read -r E; do
  grep -qF "$E" <<<"$LIVE_CWDS" || rm -rf "$E" 2>/dev/null
done

# --- Fly builder trial (Phase 2) — HUB-ONLY queue-health section --------------
# On the hub (env/fly.env present) and only for a flagged, provisioned project:
# alert if the queue has been backed up with the machine NOT started for >45 min,
# or any .failed jobs exist. Fail-open: never blocks the prod check below.
# shellcheck source=/dev/null
[ -f "$HENV/fly.env" ] && [ -r "$HARNESS/bin/jobs-client.sh" ] && [ -d "$HARNESS/bin/lib/jobs" ] \
  && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
if [ -f "$HENV/fly.env" ] && { if command -v routing_builder >/dev/null 2>&1; then [ "$(routing_builder "$PROJECT" 2>/dev/null)" != local ]; else flag_on builder-fly "$PROJECT"; fi; } \
     && [ -f "$HARNESS/state/fly/$PROJECT.json" ]; then
  QDIR="$HARNESS/state/build-queue/$PROJECT"
  FAILED=$(ls "$QDIR"/*.failed.json 2>/dev/null | wc -l | tr -dc '0-9')
  # >>> rows parked count (BH-1026.3)
  # Once bin/fly-pool.sh stops writing the sidecar, counting files here answers
  # 0 for every parked build — and 0 reads as "nothing parked", which is the one
  # answer this alert must never give by accident (D12). With the flag on the
  # count is this project's `failed` fly ROWS; on an unreadable list the sidecar
  # count STANDS rather than silently collapsing to zero.
  # The modules directory is checked too: bin/jobs-client.sh REFUSES to load
  # half a client with an `exit 1`, and this script is the fleet's prod liveness
  # beat — a half-synced bin/ must not be able to stop it before the prod check.
  #
  # AND IT IS THE PARKS, NOT EVERY `failed` ROW. The sidecar this replaces only
  # ever held bin/fly-pool.sh's died-twice and deferred-out parks, while `failed`
  # is the terminal status for every way a fly build can end badly — an
  # ABANDONED ladder, "open PR already exists", a spawn-cap refusal, a closed
  # ticket — and terminal rows are never pruned. Counting all of them would page
  # a number that can only grow and never returns to 0, which is the same lie as
  # a silent 0 wearing the other sign. The reason test is exactly
  # br_from_queue's park trigger in bin/blocked-resolver.sh, because "parked" is
  # its question: these are the rows the resolver will re-enter.
  # shellcheck source=/dev/null
  [ -r "$HARNESS/bin/jobs-client.sh" ] && [ -d "$HARNESS/bin/lib/jobs" ] \
    && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
  if command -v build_queue_rows_only_on >/dev/null 2>&1 && build_queue_rows_only_on \
     && command -v queue_list >/dev/null 2>&1; then
    RFT=$(mktemp "${TMPDIR:-/tmp}/hc-failed.XXXXXX" 2>/dev/null) || RFT=""
    if [ -n "$RFT" ]; then
      queue_list "$PROJECT" failed fly > "$RFT" 2>/dev/null
      # Column 9 is REASON (bin/lib/jobs/queue.sh documents the ten columns).
      [ "$?" -ne 1 ] && FAILED=$(awk -F'\t' \
        '$9 ~ /died ([0-9]+ times|twice)/ || $9 ~ /deferred [0-9]+ times/ {n++} END{print n+0}' \
        "$RFT" 2>/dev/null | tr -dc '0-9')
      rm -f "$RFT"
    fi
  fi
  # <<< rows parked count
  if [ "${FAILED:-0}" -gt 0 ]; then
    HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] FLY: $FAILED .failed build job(s) in queue"
    "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "flyfailed:$PROJECT:$(date -u +%Y%m%d)" \
      --arg l "Fly builder: $FAILED failed build job(s) for $PROJECT — investigate or drop flags/builder-fly-$PROJECT" \
      '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" 2>/dev/null || true
  fi
  # stalled queue: oldest queued job older than 45 min while machine not started.
  OLDEST=$(ls -1t "$QDIR"/*.json 2>/dev/null | grep -v '\.failed\.json$' | tail -1)
  if [ -n "$OLDEST" ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$OLDEST" 2>/dev/null || echo "$(date +%s)") ))
    ST=$("$HARNESS/bin/fly-api.sh" "$PROJECT" state 2>/dev/null || echo unknown)
    if [ "$AGE" -gt 2700 ] && [ "$ST" != "started" ]; then
      HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] FLY: queue stalled ${AGE}s, machine=$ST"
      "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "flystall:$PROJECT:$(date -u +%Y%m%d%H)" \
        --arg l "Fly builder queue stalled for $PROJECT: oldest job $((AGE/60))m old, machine=$ST" \
        '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" 2>/dev/null || true
    fi
  fi
fi

# >>> hardened report
# Sits BEFORE the prod-url early exits on purpose: a project with no prod
# surface ("-" in fleet.conf) still reports its box's hardening figure.
# By healthcheck time the */10 harden-state re-arm lane has had dozens of
# ticks, so N<M here does not mean "a writer is mid-release" — it means that
# lane is dead. `unknown` (chattr unusable, lock timeout, no output at all) is
# never read as OK: a figure nobody could take is not a pass.
HS=$("$HARNESS/bin/harden-state.sh" --status 2>/dev/null) || true
HS="${HS:-hardened=unknown}"
echo "$HS"
HS_OK=0
case "$HS" in
  hardened=*/*)
    HN=${HS#hardened=}; HM=${HN#*/}; HN=${HN%/*}
    [[ "$HN" =~ ^[0-9]+$ && "$HM" =~ ^[0-9]+$ ]] && [ "$HN" -eq "$HM" ] && HS_OK=1 ;;
esac
if [ "$HS_OK" -ne 1 ]; then
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] HARDEN: $HS on $(hostname) — the */10 harden-state re-arm lane should have fixed this; check 'crontab -l | grep harden-state' and logs/harden-state.log"
  # Deduped per box per day by the akey, so the console shows one row while
  # ALERTS.log keeps a line per run. The beat is written AFTER the ALERTS line
  # and fails open: a console that is down must not swallow the finding.
  "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "hardened:$(hostname):$(date -u +%Y%m%d)" \
    --arg l "harden-state short on $(hostname): $HS — a released file stayed writable, or the re-arm cron lane is dead" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')" 2>/dev/null || true
fi
# <<< hardened report

PROD=$("$HARNESS/bin/prod-url.sh" "$PROJECT") || exit 0
[ "$PROD" = "-" ] && exit 0  # fleet.conf "-" = no prod surface to check (e.g. JIRA-only watchers)

URL="$PROD"
HCODE=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$PROD/api/health")
case "$HCODE" in
  2*) URL="$PROD/api/health";;  # richer endpoint exists and is healthy — use it
  5*)
    # The health endpoint EXISTS and says unhealthy (db/llm down while the
    # homepage still serves). Falling back to / here is how the project-4 llm outage
    # went unalerted (2026-08-05): an unhealthy health endpoint must alert, not
    # disable the check. One retry for edge blips, then alert with the body.
    sleep 30
    HCODE2=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$PROD/api/health")
    case "$HCODE2" in
      2*) URL="$PROD/api/health";;
      *)
        BODY=$(curl -s -m 20 "$PROD/api/health" | head -c 200)
        HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] HEALTHCHECK: $PROD/api/health returned HTTP $HCODE2 body=$BODY"
        "$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "health:$PROJECT:$(date -u +%Y%m%d)" \
          --arg l "prod /api/health UNHEALTHY: HTTP $HCODE2 $BODY — app may serve pages while LLM/DB features are down" \
          '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')"
        exit 1
        ;;
    esac
    ;;
esac

# Liveness semantics: ANY 2xx-4xx proves the server is answering (project-1 +
# project-2 serve 404 at bare / — the app lives behind authed paths; 307/401
# are auth redirects). Down = 5xx, or 000 (DNS/TLS/timeout/conn-refused).
CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 30 -L "$URL")
case "$CODE" in
  2*|3*|4*) exit 0 ;;
esac
# one retry before alerting — transient edge blips are common
sleep 30
CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 30 -L "$URL")
case "$CODE" in
  2*|3*|4*) exit 0 ;;
esac
HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[$PROJECT] HEALTHCHECK: $URL returned HTTP $CODE"
"$HARNESS/bin/beat.sh" "$(jq -nc --arg p "$PROJECT" --arg akey "health:$PROJECT:$(date -u +%Y%m%d)" \
  --arg l "prod healthcheck failing: $URL -> HTTP $CODE" \
  '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}')"
exit 1
