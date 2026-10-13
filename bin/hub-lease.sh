#!/bin/bash
# alert-writer: by-design — its three writes page that the jobs worker is unreachable, the same worker alert-line's beat → jobs-client path needs, and they are the no-lane-alert.sh fallback in front of every hub cron lane's gate.
# bin/hub-lease.sh — client for the hub-lease coordination worker.
# Subcommands: renew|check|promote.
# Sources $HARNESS/bin/jobs-client.sh and uses _jobs_req directly,
# so the fail-open contract and rc mapping are shared.
#
# renew   — POST /api/hub-lease, takes/renews the lease for this box.
#           Sends {holder, epoch}. On 200 with held=1 writes cache and exits 0;
#           on 409 writes updated cache with held=0 and exits 1. The epoch it
#           caches is always the one the SERVER answered with, never the one it
#           asked for. An ANSWERED renew (200 or 409) also reconciles the
#           hub-lease-epoch-check flag row into flags/ — it is the one lane
#           already on the network every minute, so `check` never pays for the
#           knob; an unreachable renew skips the sync rather than firing a
#           second request into the same outage.
#           A future integer epoch in flags/hub-lease-renew-paused pauses renew (rc 1, no request; BH-402 drill); an expired/invalid one is removed.
# check   — GET /api/hub-lease?holder=..., reports whether we hold it. Two modes,
#           on HUB_LEASE_EPOCH_CHECK (environment, then the harness env file) /
#           flags/hub-lease-epoch-check:
#           OFF (default, dark) — a cache younger than 60s answers from the file.
#           ON  — a fresh cache that says held=1 is RE-VALIDATED against the row:
#                 held additionally requires the row's epoch to still equal the
#                 cached one, so a promote (or an expired lease re-taken at
#                 epoch+1) stops the old holder inside the 60s window instead of
#                 at its next 409. A fresh cache that says held=0, and every
#                 unreachable-worker path, are unchanged in both modes:
#                 600s grace for the CURRENT holder only — and past that grace,
#                 the CONFIGURED hub fails OPEN (see below) instead of the one
#                 ALERT it used to be.
# promote [--holder] <box> [--reason R] [--override-live-lease]
#         — move the hub to <box> (default: this box) through the GUARDED route,
#           POST /api/hub/promote (BH-2272). <box> must be the registered hub or
#           a fleet.conf `# @standby` box/hub, or nothing is sent (rc 2). It
#           reads the live epoch, then sends {target, expected_epoch, actor,
#           reason, confirm:true, override_live_lease}; the worker's refusal
#           (403 promote-disabled, 409 lease_live/stale_epoch, 400 unknown_box)
#           is rc 1 with the worker's words on stderr. No lease row (the
#           worker answers 200 {"lease":null}) is rc 1, nothing sent. STOP THE
#           OLD HUB (or cut its lane gate) FIRST: a hub that cannot reach the worker fails open
#           (below) and keeps running after the epoch moves. The old
#           /api/hub-lease/promote force-promote is retired (410).
#
# ── FAIL-OPEN ON THE CONFIGURED HUB, AND THE SPLIT-BRAIN TRADE-OFF (BH-1000) ──
# On 2026-09-19 the hub_lease table was never applied to D1, the worker answered
# 500 on every read, and `check` exited 1 with no cache and no alert — so every
# gated cron lane on the hub skipped for 29 minutes and nothing paged. Fail
# CLOSED is the right answer when someone else might be the hub; it is the wrong
# answer when the box asking IS the configured hub, because the only mechanism
# that could hand the lease to another box is the same worker that is not
# answering. The trade-off in three sentences: a single configured hub whose
# worker is unreachable keeps running its own lanes, so the fleet does not stop.
# A second box could only become hub by renewing or being promoted through that
# same unreachable worker, so no second hub can appear while the outage lasts.
# The cost is that a `promote` issued DURING the outage is not seen here until
# the worker answers again — the old hub keeps running until then, which is why
# the condition pages `--critical` instead of staying quiet.
# BH-1922 broke that premise: the watchdog promotes through the jobs worker from
# Cloudflare's side, so a hub partitioned from `*.workers.dev` can be demoted
# while it still fails open. HUB_LEASE_FENCE_S bounds fail-open for that case;
# the watchdog's failover stays OFF until it is set on the hub.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
# BH-4080: HARNESS_HUB_BOX, the hub's fleet name when HUB_BOX_NAME is unset.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1

# ── Dependencies ──────────────────────────────────────────────────────────────
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# harness_env_dir, for the env-file leg of the knob below. jobs-client.sh already
# sources this library; sourcing it again is idempotent and keeps the dependency
# honest for a box whose jobs-client is missing.
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }
# One definition of "who is the hub", shared with bin/run-build.sh and friends.
# The fallback matters: a box whose checkout predates the lib must still answer
# the question, and it must answer it the same way.
[ -r "$HARNESS/bin/lib/hub-box.sh" ] && . "$HARNESS/bin/lib/hub-box.sh"
command -v hub_box_name >/dev/null 2>&1 || hub_box_name() { printf %s "${HUB_BOX_NAME:-$HARNESS_HUB_BOX}"; }

# ── Configuration knobs ────────────────────────────────────────────────────────
HUB_LEASE_HOLDER="${HUB_LEASE_HOLDER:-$("$HARNESS/bin/box-name.sh" 2>/dev/null)}"
[ -n "$HUB_LEASE_HOLDER" ] || { echo "hub-lease: HUB_LEASE_HOLDER is empty — cannot identify this box" >&2; exit 1; }

HUB_LEASE_CACHE_S="${HUB_LEASE_CACHE_S:-60}"
HUB_LEASE_GRACE_S="${HUB_LEASE_GRACE_S:-600}"
HUB_LEASE_NOW="${HUB_LEASE_NOW:-$(date +%s)}"
# These four are env + code default ON PURPOSE, not settings-table rows: the
# database the settings table lives in is the thing that is down when they
# matter. A documented exception to the DB-driven-config rule.
HUB_LEASE_FAIL_OPEN="${HUB_LEASE_FAIL_OPEN:-1}"   # 0 restores the old fail-closed behaviour
HUB_LEASE_PAGE_S="${HUB_LEASE_PAGE_S:-600}"       # "check failing for >10 minutes must page"
# How often THIS script will hand the same outage to the alerter again. It is
# the cadence of the fallback path (no bin/lane-alert.sh on the box: one line an
# hour straight into ALERTS.log). On a box that HAS lane-alert.sh, lane-alert
# owns the cadence from there: repeats on an open --id are suppressed and it
# sends one "still firing" reminder per ALERT_REMINDER_S (6 h), so this value is
# the floor, never the rate.
HUB_LEASE_ALERT_REPEAT_S="${HUB_LEASE_ALERT_REPEAT_S:-3600}"
# HUB_LEASE_FENCE_S — the SELF-FENCE (BH-1922). Seconds of unreachable worker
# after which this box stops acting as the hub: the held=1 grace is capped at it
# and the configured hub's fail-open ends at it (`check` exits 1 and pages
# `--critical --id hub-lease-fenced`). 0 or unset = no fence, the BH-1000
# behaviour. It must be set, below the watchdog's failover lease window, on the
# hub BEFORE `cfg:failover=on` arms automatic promotion: the watchdog reaches
# the jobs worker from Cloudflare's side, so it CAN promote while this box
# cannot hear the worker, and without the fence the old hub keeps running its
# lanes next to the new one for as long as the partition lasts. Read from the
# environment, then from the harness env file (crontab lines source nothing).
HUB_LEASE_FENCE_S="${HUB_LEASE_FENCE_S:-}"

CACHE="$HARNESS/state/hub-lease.json"
# The flag now carries the EPOCH of the last page, not merely its existence. An
# empty file (what an older fail-closed outage left behind) parses as 0, which
# means "never paged" — absent must never read as "already handled".
FLAG="$HARNESS/flags/alerted-hub-lease-unreachable"
KNOB_FLAG="$HARNESS/flags/alerted-hub-lease-knob"
SINCE="$HARNESS/state/hub-lease-failing-since"
FENCE_FLAG="$HARNESS/flags/alerted-hub-lease-fenced"
LOG="$HARNESS/logs/hub-lease.log"

# ── Helpers ───────────────────────────────────────────────────────────────────
_log() { mkdir -p "$HARNESS/logs" 2>/dev/null; echo "[hub-lease] $(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG" 2>/dev/null || true; }

_write_cache() {
  # write the lease JSON object plus computed fields atomically
  local json="$1" held="$2"
  mkdir -p "$HARNESS/state" 2>/dev/null || true
  local tmp; tmp=$(mktemp "$HARNESS/state/.hub-lease.XXXXXX" 2>/dev/null) || return
  printf '%s' "$json" > "$tmp"
  mv "$tmp" "$CACHE"
}

# Parse lease response: extract {holder, expired:bool, epoch, expires_at, updated_at}
# from a response that may be {"lease":{...}} or just {...}.
_parse_lease() {
  printf '%s' "$1" | jq -c '.lease // .' 2>/dev/null || echo '{}'
}

# Compute held: lease.holder == ME && lease.expired == false
_is_held() {
  local lh; lh=$(printf '%s' "$1" | jq -r '.holder // ""' 2>/dev/null)
  local ex; ex=$(printf '%s' "$1" | jq -r 'if has("expired") and (.expired|type) == "boolean" then (.expired|tostring) else "true" end' 2>/dev/null)
  [ "$lh" = "$HUB_LEASE_HOLDER" ] && [ "$ex" = "false" ] && return 0
  return 1
}

# Read HUB_LEASE_EPOCH_CHECK out of the harness env file. The gated consumers
# are bare crontab lines that source nothing, so a box-local `HUB_LEASE_EPOCH_CHECK=0`
# in global.env would otherwise be invisible exactly where it matters. Read the
# ONE variable with an anchored sed — never `set -a; . global.env`, which would
# pull a box's whole secret file into every gated lane a minute.
#
# The anchor accepts the spellings an env file is actually hand-edited in during
# an incident, because a kill switch that READS as set and is not is worse than
# no kill switch (review F2, probed on this script): an `export ` prefix, leading
# indentation, a trailing `# comment`, a trailing tab and a CRLF line ending all
# resolve to the same value. It still refuses a COMMENTED line — the template's
# `#HUB_LEASE_EPOCH_CHECK=1` stays inert, as a commented line must, because `#`
# is neither whitespace nor `export`. Anything this does NOT resolve to 1|0 is
# logged by _epoch_check_on rather than silently dropped.
#
# `tail -1`, not `head -1`: the LAST assignment wins, which is what `. global.env`
# does and therefore what every other reader of that file does. An incident edit
# is an APPEND (`echo 'HUB_LEASE_EPOCH_CHECK=0' >> global.env`) under a line the
# rollout already put there, and first-wins would drop it on the floor while the
# earlier valid `1` kept the log silent — the same reads-as-set-and-is-not mode
# this function exists to close (review B-1, probed on this script).
_epoch_check_env_file() {
  local dir; dir=$(harness_env_dir "$HARNESS" 2>/dev/null)
  [ -n "$dir" ] && [ -r "$dir/global.env" ] || return 0
  sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}HUB_LEASE_EPOCH_CHECK=//p' \
    "$dir/global.env" 2>/dev/null | tail -1 | sed 's/[[:space:]]*#.*$//' | tr -d '"'"'"' \t\r'
}

# Is the epoch re-validation on? Cheapest first, and never a network call of its
# own: an explicit 1|0 wins both ways (a box-local kill switch, and the handle
# the suite uses) — from the process environment first, then from the env file a
# cron lane never sources — else the flag FILE, which the D1 row
# `hub-lease-epoch-check` drives through flag_sync on the renew lane. A value
# that is neither 1 nor 0 is not an override: it falls through to the file, the
# same as unset — but it is LOGGED, so an operator who set one can SEE that what
# they typed was ignored instead of reading silence as agreement. Nothing set
# anywhere + no file = dark, and dark is silent.
#
# Two things the log has to get right, both probed on this script:
#   - It fires whenever something was ignored, INCLUDING when a later source
#     resolves the knob anyway (a junk export masked by a sane env-file value).
#     Deciding first and logging only on the fall-through made the contract
#     "any unresolvable value is logged" false for exactly the case an operator
#     later removes the masking line in (review I-1).
#   - It fires ONCE PER INCIDENT, not once per invocation, behind the same kind
#     of flag as the unreachable alert above: with the knob on, every gated lane
#     on the hub runs this, so an unattended typo wrote ~53 lines a minute into
#     a file documented as silent-when-healthy (review N-2). The flag is removed
#     the moment the knob resolves cleanly, so the next bad value is loud again.
# _env_file_knob <NAME> — the last `NAME=` in global.env, same parsing rules as
# _epoch_check_env_file above.
_env_file_knob() {
  local dir; dir=$(harness_env_dir "$HARNESS" 2>/dev/null)
  [ -n "$dir" ] && [ -r "$dir/global.env" ] || return 0
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" \
    "$dir/global.env" 2>/dev/null | tail -1 | sed 's/[[:space:]]*#.*$//' | tr -d '"'"'"' \t\r'
}

# _fence_s — the self-fence in seconds, 0 when off. Anything that is not a
# non-negative integer is 0: an unreadable fence is no fence, which is exactly
# the BH-1000 behaviour, and the watchdog's own default-off is what keeps that
# safe.
_fence_s() {
  local v="$HUB_LEASE_FENCE_S"
  [ -n "$v" ] || v=$(_env_file_knob HUB_LEASE_FENCE_S)
  _num "$v"
}

_epoch_check_on() {
  local v="${HUB_LEASE_EPOCH_CHECK:-}" ignored=""
  case "$v" in
    1|0) ;;
    *)
      [ -n "$v" ] && ignored="$v"
      v=$(_epoch_check_env_file)
      case "$v" in
        1|0|"") ;;
        *) ignored="$v" ;;
      esac
      ;;
  esac
  if [ -n "$ignored" ]; then
    if [ ! -f "$KNOB_FLAG" ]; then
      _log "knob: HUB_LEASE_EPOCH_CHECK=$ignored ignored — neither 1 nor 0;" \
           "falling through to flags/hub-lease-epoch-check"
      mkdir -p "$HARNESS/flags" 2>/dev/null || true
      : > "$KNOB_FLAG" 2>/dev/null || true
    fi
  else
    rm -f "$KNOB_FLAG" 2>/dev/null || true
  fi
  case "$v" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  [ -f "$HARNESS/flags/hub-lease-epoch-check" ]
}

# Reconcile that flag row into the file. Fail-open and rc-transparent by
# construction: the caller's exit code is decided before this runs, an outage
# (rc 1) or a missing row (rc 2) leaves the box exactly as it is, and a
# jobs-client.sh too old to define flag_sync is simply skipped.
_sync_epoch_flag() {
  command -v flag_sync >/dev/null 2>&1 && flag_sync hub-lease-epoch-check >/dev/null 2>&1
  return 0
}

_read_cache() {
  jq -c '{holder, epoch, expires_at, updated_at, as_of, held, fetched_at}' "$CACHE" 2>/dev/null || echo '{}'
}

_cache_age_s() {
  local fa; fa=$(jq -r '.fetched_at // 0' "$CACHE" 2>/dev/null)
  [ -n "$fa" ] && [ "$fa" -eq "$fa" ] 2>/dev/null || fa=0
  echo $(( HUB_LEASE_NOW - fa ))
}

# _cache_fetched_at — the cache's own timestamp, 0 when there is none.
_cache_fetched_at() {
  local fa; fa=$(jq -r '.fetched_at // 0' "$CACHE" 2>/dev/null)
  [ -n "$fa" ] && [ "$fa" -eq "$fa" ] 2>/dev/null || fa=0
  printf '%s' "$fa"
}

# _cache_held — 1, 0, or "none" when there is no cache to read.
_cache_held() {
  [ -r "$CACHE" ] || { printf 'none'; return; }
  local ch; ch=$(printf '%s' "$(_read_cache)" | jq -r '.held // 0' 2>/dev/null)
  case "$ch" in 1) printf '1' ;; *) printf '0' ;; esac
}

# _num <value> — the value when it is a non-negative integer, else 0. An empty
# or corrupt marker must mean "never", never "recently".
_num() {
  case "${1:-}" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

# _req_capture <var-of-response> <method> <path> [body]
#   _jobs_req in the CURRENT shell, with its stdout parked in a file. The old
#   `resp=$(_jobs_req ...)` ran it in a subshell, so JOBS_HTTP and JOBS_BODY —
#   the worker's status and its reason — died with that subshell and every
#   non-2xx was logged as "worker unreachable" (BH-1000).
_req_capture() {
  local __out="$1"; shift
  local tmp rc
  mkdir -p "$HARNESS/state" 2>/dev/null || true
  tmp=$(mktemp "$HARNESS/state/.hub-lease-resp.XXXXXX" 2>/dev/null) || tmp=""
  if [ -z "$tmp" ]; then
    # No writable state dir: fall back to a command substitution. The rc is
    # captured from _jobs_req FIRST and returned by hand — `printf -v X "$(f)"`
    # returns printf's status, not f's, so a worker error would come back as
    # rc 0 with an empty body: `check` would read that empty body as "someone
    # else holds the lease" and exit 1 on every gated hub lane with no clock,
    # no page and no log line. That is the very incident this ticket removes
    # (BH-1000 fix round 1). Only the REASON is lost here (JOBS_HTTP/JOBS_BODY
    # die with the subshell), never the verdict.
    local __v; __v=$(_jobs_req "$@" 2>/dev/null); rc=$?
    printf -v "$__out" '%s' "$__v"
    return $rc
  fi
  _jobs_req "$@" > "$tmp" 2>/dev/null; rc=$?
  printf -v "$__out" '%s' "$(cat "$tmp" 2>/dev/null)"
  rm -f "$tmp" 2>/dev/null || true
  return $rc
}

# _reason — what the worker actually said, for a log line or an alert.
# "transport" (not a blank) when there was no HTTP answer at all: the whole
# point of BH-1000 is being able to tell "500, table missing" from "no answer".
_reason() {
  printf 'http=%s %s' "${JOBS_HTTP:-transport}" "$(printf '%s' "${JOBS_BODY:-}" | tr -d '\n' | cut -c1-200)"
}

# _page <elapsed-seconds> — ONE critical alert, at most once per
# HUB_LEASE_ALERT_REPEAT_S. The flag is written BEFORE the alert is sent so a
# crash in between under-pages by one hour rather than paging every minute.
_page() {
  local elapsed="$1" last msg
  last=$(_num "$(cat "$FLAG" 2>/dev/null)")
  [ "$elapsed" -ge "$HUB_LEASE_PAGE_S" ] || return 0
  [ $(( HUB_LEASE_NOW - last )) -ge "$HUB_LEASE_ALERT_REPEAT_S" ] || return 0
  mkdir -p "$HARNESS/flags" "$HARNESS/logs" 2>/dev/null || true
  printf '%s' "$HUB_LEASE_NOW" > "$FLAG" 2>/dev/null || true
  msg="hub-lease check has failed for $(( elapsed / 60 )) min on $HUB_LEASE_HOLDER ($(_reason)) — hub lanes are running FAIL-OPEN on this box; see logs/jobs-client.log"
  if [ -x "$HARNESS/bin/lane-alert.sh" ]; then
    "$HARNESS/bin/lane-alert.sh" --critical --id hub-lease-check-failing hub-lease "$msg" >/dev/null 2>&1 || true
  else
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [hub-lease] $msg" >> "$HARNESS/logs/ALERTS.log" 2>/dev/null || true
  fi
  _log "paged: $msg"
}

# _fence <elapsed-seconds> — the self-fence tripped. ONE critical alert per
# outage (the flag is cleared by _recover), then the caller exits 1.
_fence() {
  local elapsed="$1" msg
  [ -f "$FENCE_FLAG" ] && return 0
  mkdir -p "$HARNESS/flags" "$HARNESS/logs" 2>/dev/null || true
  : > "$FENCE_FLAG" 2>/dev/null || true
  msg="hub-lease worker unreachable for $(( elapsed / 60 )) min on $HUB_LEASE_HOLDER ($(_reason)) — SELF-FENCED at HUB_LEASE_FENCE_S=$(_fence_s): hub lanes are STOPPED on this box, the watchdog may have promoted a standby"
  if [ -x "$HARNESS/bin/lane-alert.sh" ]; then
    "$HARNESS/bin/lane-alert.sh" --critical --id hub-lease-fenced hub-lease "$msg" >/dev/null 2>&1 || true
  else
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [hub-lease] $msg" >> "$HARNESS/logs/ALERTS.log" 2>/dev/null || true
  fi
  _log "fenced: $msg"
}

# _recover — the outage is over. Resolve the condition exactly once, and only
# if a page was really sent (an empty flag is the OLD fail-closed marker and
# was never announced to anyone).
_recover() {
  local held="$1" last
  rm -f "$SINCE" 2>/dev/null || true
  if [ -f "$FENCE_FLAG" ]; then
    rm -f "$FENCE_FLAG" 2>/dev/null || true
    [ -x "$HARNESS/bin/lane-alert.sh" ] \
      && "$HARNESS/bin/lane-alert.sh" --resolve --id hub-lease-fenced hub-lease "hub-lease worker answering again on $HUB_LEASE_HOLDER — self-fence lifted" >/dev/null 2>&1
  fi
  last=$(_num "$(cat "$FLAG" 2>/dev/null)")
  if [ "$last" -gt 0 ]; then
    [ -x "$HARNESS/bin/lane-alert.sh" ] \
      && "$HARNESS/bin/lane-alert.sh" --resolve --id hub-lease-check-failing hub-lease "hub-lease check recovered on $HUB_LEASE_HOLDER" >/dev/null 2>&1
    rm -f "$FLAG" 2>/dev/null || true
  elif [ "$held" = 1 ]; then
    rm -f "$FLAG" 2>/dev/null || true
  fi
}

# ── Subcommands ────────────────────────────────────────────────────────────────

cmd_renew() {
  # BH-402 drill pause (FD_RENEW_PAUSE_FLAG in bin/lib/failover-drill-common.sh,
  # hard-coded here so renew never sources the drill lib). Checked before any
  # request; a deadline at or before now, or anything that is not an integer,
  # is removed so a SIGKILLed drill cannot strand the lease.
  local pf="$HARNESS/flags/hub-lease-renew-paused"
  if [ -e "$pf" ]; then
    local d; d=$(tr -d '[:space:]' < "$pf" 2>/dev/null)
    if [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -gt "$HUB_LEASE_NOW" ]; then
      _log "renew: paused by flags/hub-lease-renew-paused until $(date -u -d "@$d" '+%Y-%m-%dT%H:%M:%SZ')"
      exit 1
    fi
    rm -f "$pf"
    _log "renew: pause flag expired/invalid, removed"
  fi
  local cached; cached=$(_read_cache)
  local epoch; epoch=$(printf '%s' "$cached" | jq -r '.epoch // 0' 2>/dev/null)
  local body; body=$(jq -nc --arg h "$HUB_LEASE_HOLDER" --argjson e "$epoch" '{holder: $h, epoch: $e}')
  local resp=""; _req_capture resp POST /api/hub-lease "$body"; local rc=$?
  case $rc in
    0)
      local lease; lease=$(_parse_lease "$resp")
      local held=1; _is_held "$lease" || held=0
      # Enrich cache with computed fields
      local now_iso; now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      local cache_json; cache_json=$(printf '%s' "$lease" | jq -c --argjson h "$held" --argjson fa "$HUB_LEASE_NOW" --arg asof "$now_iso" \
        '. + {held: $h, fetched_at: $fa, as_of: $asof}')
      _write_cache "$cache_json" "$held"
      _sync_epoch_flag
      [ "$held" = 1 ] && exit 0 || exit 1
      ;;
    9)
      # 409 — lease held by another box, write the latest server state
      local lease; lease=$(_parse_lease "$resp")
      local now_iso; now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      local cache_json; cache_json=$(printf '%s' "$lease" | jq -c --argjson fa "$HUB_LEASE_NOW" --arg asof "$now_iso" \
        '. + {held: 0, fetched_at: $fa, as_of: $asof}')
      _write_cache "$cache_json" 0
      _sync_epoch_flag
      exit 1
      ;;
    *)
      # No _sync_epoch_flag here: the flag GET goes to the same worker that just
      # failed, so it can only fail too — it would double this minute's timeout
      # budget (~17s → ~34s) and write a second _jobs_log line a minute for a
      # request that cannot succeed. The next answered renew reconciles the row
      # within a minute.
      #
      # The worker's own words, verbatim. "unreachable" was printed here for 29
      # minutes while the worker was answering 503 with the actual cause.
      _log "renew: _jobs_req rc=$rc — $(_reason)"
      exit 1
      ;;
  esac
}

cmd_check() {
  # The epoch we are about to answer "held" from, when it came from a cache
  # fresh enough to have been trusted outright. Empty means there is nothing to
  # re-validate against and _is_held alone decides, exactly as it does today.
  local cached_epoch=""

  # 1. Cache fresh → skip network, unless the re-validation is on
  if [ -r "$CACHE" ]; then
    local age; age=$(_cache_age_s)
    if [ "$age" -lt "$HUB_LEASE_CACHE_S" ] 2>/dev/null; then
      local cached; cached=$(_read_cache)
      local ch; ch=$(printf '%s' "$cached" | jq -r '.held // 0' 2>/dev/null)
      # A cache that says we do NOT hold it is final in both modes: a non-holder
      # has nothing to re-validate and never pays for a request.
      [ "$ch" = 1 ] || exit 1
      _epoch_check_on || exit 0
      cached_epoch=$(printf '%s' "$cached" | jq -r '(.epoch|tonumber?) // empty' 2>/dev/null)
    fi
  fi

  # 2. Network check
  local resp=""; _req_capture resp GET "/api/hub-lease?holder=$HUB_LEASE_HOLDER"; local rc=$?
  case $rc in
    0)
      local lease; lease=$(_parse_lease "$resp")
      local held=1; _is_held "$lease" || held=0
      # Fencing: the cached epoch we were about to trust must still be the row's
      # epoch. A promote, or an expired lease re-taken at epoch+1, moves it —
      # and the old holder stops now rather than at its next 409. Both sides go
      # through the same `tonumber?`, so a "1" from the wire equals a cached 1;
      # a row with no epoch at all yields empty and is never equal (absent is
      # not "unchanged").
      if [ "$held" = 1 ] && [ -n "$cached_epoch" ]; then
        local row_epoch; row_epoch=$(printf '%s' "$lease" | jq -r '(.epoch|tonumber?) // empty' 2>/dev/null)
        [ -n "$row_epoch" ] && [ "$row_epoch" = "$cached_epoch" ] || held=0
      fi
      local now_iso; now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      local cache_json; cache_json=$(printf '%s' "$lease" | jq -c --argjson h "$held" --argjson fa "$HUB_LEASE_NOW" --arg asof "$now_iso" \
        '. + {held: $h, fetched_at: $fa, as_of: $asof}')
      _write_cache "$cache_json" "$held"
      # The worker ANSWERED, so whatever outage there was is over — even when
      # the answer is "you are not the hub". Clearing the clock and resolving a
      # sent page is not conditional on winning the lease.
      _recover "$held"
      [ "$held" = 1 ] && exit 0 || exit 1
      ;;
    1|2)
      # Transport/404 — apply grace if CURRENT holder (held=1) AND within window
      if [ -r "$CACHE" ]; then
        local cached; cached=$(_read_cache)
        local ch; ch=$(printf '%s' "$cached" | jq -r '.held // 0' 2>/dev/null)
        if [ "$ch" = 1 ]; then
          local fa; fa=$(jq -r '.fetched_at // 0' "$CACHE" 2>/dev/null)
          [ -n "$fa" ] && [ "$fa" -eq "$fa" ] 2>/dev/null || fa=0
          local elapsed=$(( HUB_LEASE_NOW - fa ))
          # The self-fence caps the grace too: a grace longer than the fence
          # would keep the lanes up past the point the watchdog may promote.
          local grace="$HUB_LEASE_GRACE_S" fence; fence=$(_fence_s)
          [ "$fence" -gt 0 ] && [ "$fence" -lt "$grace" ] 2>/dev/null && grace="$fence"
          if [ "$elapsed" -lt "$grace" ] 2>/dev/null; then
            exit 0
          fi
        fi
      fi

      # ── FAIL OPEN, LOUDLY (BH-1000) ───────────────────────────────────────
      # Every condition here is load-bearing:
      #   rc 1, never 2 — a 404 is the worker ANSWERING "no such route", i.e.
      #     not deployed yet, and that box has no business running hub lanes.
      #   this box is the CONFIGURED hub — nobody else may assume the role.
      #   the cache does not say someone ELSE holds the lease (held=0). A
      #     cache naming another holder is a real claim and outranks an outage.
      # A cache that is ABSENT is not a held=0: it is no information, and the
      # configured hub is the one box that may act without it (_cache_held says
      # "none"). A cache that is PRESENT but unreadable — truncated, corrupt —
      # reads as held=0 and so fails CLOSED here, on purpose and not by
      # accident: a file we wrote and can no longer parse is a fact about this
      # box, not an absence of facts, and the conservative branch still writes
      # the ALERTS line below. Widening that to fail open is its own change,
      # with its own ticket; it is not this one.
      local held_state; held_state=$(_cache_held)
      if [ "$rc" = 1 ] && [ "$HUB_LEASE_FAIL_OPEN" != 0 ] \
         && [ "$HUB_LEASE_HOLDER" = "$(hub_box_name)" ] \
         && [ "$held_state" != 0 ]; then
        local since
        if [ -r "$SINCE" ]; then
          since=$(_num "$(cat "$SINCE" 2>/dev/null)")
        else
          # Back-date to the last time we KNOW the lease was ours, so an outage
          # that already burned its grace pages on this tick and not ten
          # minutes after we noticed it.
          if [ "$held_state" = 1 ]; then since=$(_cache_fetched_at); else since="$HUB_LEASE_NOW"; fi
          mkdir -p "$HARNESS/state" 2>/dev/null || true
          printf '%s' "$since" > "$SINCE" 2>/dev/null || true
        fi
        # A clock we cannot read is repaired ON DISK, not only in memory: an
        # empty or half-written failing-since (a full state/ partition lets the
        # write above allocate an inode and store nothing) reads as 0, and a
        # repair that lives only in this process re-seats `since` to each
        # tick's own now — elapsed stays 0, `_page` returns at its threshold
        # check, and the box runs fail-open with the lanes up and nothing
        # paging. Persisting it means the NEXT tick past the threshold pages.
        [ "$since" -gt 0 ] 2>/dev/null || {
          since="$HUB_LEASE_NOW"
          mkdir -p "$HARNESS/state" 2>/dev/null || true
          printf '%s' "$since" > "$SINCE" 2>/dev/null || true
        }
        # The self-fence (BH-1922): past HUB_LEASE_FENCE_S the watchdog may
        # already have promoted a standby through a worker this box cannot
        # hear, so fail-open ends here and the lanes stop.
        local out=$(( HUB_LEASE_NOW - since )) fence_s; fence_s=$(_fence_s)
        if [ "$fence_s" -gt 0 ] && [ "$out" -ge "$fence_s" ]; then
          _fence "$out"
          exit 1
        fi
        _page "$out"
        exit 0
      fi

      # Grace exhausted or not current holder — alert once per outage, but
      # only when we have a cache (no cache = no claim to alert about).
      if [ -r "$CACHE" ] && [ ! -f "$FLAG" ]; then
        mkdir -p "$HARNESS/flags" 2>/dev/null || true
        touch "$FLAG" 2>/dev/null || true
        local msg; msg="[hub-lease] hub-lease worker unreachable — grace exhausted for $HUB_LEASE_HOLDER — lease coordination is degraded"
        mkdir -p "$HARNESS/logs" 2>/dev/null || true
        echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $msg" >> "$HARNESS/logs/ALERTS.log" 2>/dev/null || true
      fi
      exit 1
      ;;
    *)
      _log "check: _jobs_req rc=$rc — unexpected"
      exit 1
      ;;
  esac
}

# _promote_usage <msg> — a bad promote command line: say why, send nothing.
_promote_usage() {
  echo "hub-lease: promote: $1" >&2
  echo "usage: hub-lease.sh promote [--holder] <box> [--reason TEXT] [--override-live-lease]" >&2
  exit 2
}

# _registered_holders — every box that may hold the hub lease, one per line:
# the hub itself and each box and hub named by a fleet.conf standby directive
# (`# @standby <box> <hub-name> <hub-id>`, bin/fleet-conf.sh --standby). rc 1
# when the registry cannot be read, which the caller treats as "refuse".
_registered_holders() {
  local fc="$HARNESS/bin/fleet-conf.sh" out
  [ -r "$fc" ] || fc="$(dirname "${BASH_SOURCE[0]}")/fleet-conf.sh"
  [ -r "$fc" ] || return 1
  out=$(bash "$fc" --standby 2>/dev/null) || return 1
  hub_box_name; echo
  printf '%s\n' "$out" | awk 'NF >= 2 {print $1; print $2}'
}

# BH-2272. This used to take "$1" verbatim, so `promote --holder X` sent
# {"holder":"--holder"} to a route that promoted any name: every real hub's
# check then failed closed. Parse, check the name against the registry, and go
# through the guarded route, or send nothing.
cmd_promote() {
  local holder="" have_holder=0 reason="bin/hub-lease.sh promote" override=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --holder)
        [ $# -ge 2 ] && [ -n "$2" ] && [ "${2#-}" = "$2" ] || _promote_usage "--holder needs a box name"
        [ "$have_holder" = 0 ] || _promote_usage "more than one holder given"
        holder="$2"; have_holder=1; shift 2 ;;
      --holder=*)
        [ -n "${1#--holder=}" ] || _promote_usage "--holder needs a box name"
        [ "$have_holder" = 0 ] || _promote_usage "more than one holder given"
        holder="${1#--holder=}"; have_holder=1; shift ;;
      --reason)
        [ $# -ge 2 ] && [ -n "$2" ] || _promote_usage "--reason needs text"
        reason="$2"; shift 2 ;;
      --reason=*) reason="${1#--reason=}"; shift ;;
      --override-live-lease) override=true; shift ;;
      -*) _promote_usage "unknown option $1" ;;
      *)
        [ "$have_holder" = 0 ] || _promote_usage "unexpected argument $1"
        holder="$1"; have_holder=1; shift ;;
    esac
  done
  [ -n "$holder" ] || holder="$HUB_LEASE_HOLDER"

  local registered
  registered=$(_registered_holders) || { echo "hub-lease: promote: cannot read fleet.conf to check '$holder' is a registered hub or standby — refusing" >&2; exit 2; }
  if ! grep -Fxq -- "$holder" <<<"$registered"; then
    echo "hub-lease: promote: '$holder' is not the registered hub or a fleet.conf @standby box — refusing (registered: $(printf '%s' "$registered" | sort -u | tr '\n' ' '))" >&2
    exit 2
  fi

  local cur rc epoch
  _req_capture cur GET "/api/hub-lease?holder=$HUB_LEASE_HOLDER"; rc=$?
  epoch=$(printf '%s' "$cur" | jq -r '(.lease // {}).epoch // empty' 2>/dev/null)
  # An empty hub_lease table is a 200 with an explicit "lease": null (the GET
  # route's readLease), not a failed read: say so instead of "http=200" (BH-2282).
  if [ "$rc" -eq 0 ] && printf '%s' "$cur" | jq -e 'has("lease") and .lease == null' >/dev/null 2>&1; then
    echo "hub-lease: promote: no lease row (the hub_lease table is empty; the first box to renew bootstraps it at epoch 1) — nothing sent" >&2
    _log "promote: no lease row"
    exit 1
  fi
  if [ "$rc" -ne 0 ] || ! [[ "$epoch" =~ ^[0-9]+$ ]]; then
    echo "hub-lease: promote: cannot read the live epoch ($(_reason)) — nothing sent" >&2
    _log "promote: epoch read failed rc=$rc $(_reason)"
    exit 1
  fi

  local body; body=$(jq -nc --arg t "$holder" --argjson e "$epoch" --arg a "hub-lease.sh@$HUB_LEASE_HOLDER" \
    --arg r "$reason" --argjson o "$override" \
    '{target: $t, expected_epoch: $e, actor: $a, reason: $r, confirm: true, override_live_lease: $o}')
  local resp; _req_capture resp POST /api/hub/promote "$body"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "hub-lease: promote to $holder refused: $(_reason)" >&2
    _log "promote: $holder refused $(_reason)"
    exit 1
  fi
  printf '%s\n' "$resp"
  _log "promote: $holder at epoch $epoch -> $(printf '%s' "$resp" | jq -r '(.lease // {}).epoch // "?"' 2>/dev/null)"
  local lease; lease=$(_parse_lease "$resp")
  if _is_held "$lease"; then
    local now_iso; now_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local cache_json; cache_json=$(printf '%s' "$lease" | jq -c --argjson fa "$HUB_LEASE_NOW" --arg asof "$now_iso" \
      '. + {held: 1, fetched_at: $fa, as_of: $asof}')
    _write_cache "$cache_json" 1
  fi
  exit 0
}

# ── Main ───────────────────────────────────────────────────────────────────────
case "${1:-}" in
  renew)   cmd_renew ;;
  check)   cmd_check ;;
  promote) shift; cmd_promote "$@" ;;
  *)
    echo "usage: hub-lease.sh renew|check|promote [--holder] NAME [--reason TEXT] [--override-live-lease]" >&2
    exit 2
    ;;
esac
