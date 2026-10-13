#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-fm-queue/common.sh — BH-4584 (BH-4574.2): what the queue
# doctor's three playbooks share. Sourced by bin/archie-fm-queue.sh, never run:
# no `set -e`, no `exit`, nothing at source time.
#
# The ledger is wave 1's (bin/lib/archie-fm.sh): afm_mode,
# afm_close and _afm_req, with AFM_PLAYBOOK set per call. The claim is this
# file's own (afq_claim), because a queue action is never retried on the same
# key: a dead tick's `started` row closes failed with one alert (the tick's
# afq_sweep_started, or a later claim of the same key), and the action recurs
# on a new key (a new head, a new batch) or not at all.
#
# The root is ${HARNESS:-${H:-}}; an empty root refuses (D43).
# Globals the caller sets: AFM_LOG, NOW, DAY, AFQ_RETRY_S.
# gh-rest: no-graphql

AFQ_ACTOR=archie-fm-queue

afq_root() { printf '%s' "${HARNESS:-${H:-}}"; }
afq_log() { afm_log "$@"; }

# afq_mode_cached <project> <max-age-s> <now> -> `<mode>\t<age-s>` and rc 0
#   from the box settings cache, the list lane-gate writes once a tick
#   (state/settings-cache.json: {fetched_at, values, seeded}). The lane asks
#   only after afm_mode could not read the settings. rc 1, no answer, when
#   max-age is 0 or not a number, the file is missing or not JSON, fetched_at
#   is not all digits, or the cache is from the future or older than max-age
#   (inclusive bound; fetched_at 0, a cache marked stale, is always too old).
#   The value: archie.manage.<project> (values, then seeded), then
#   archie.manage, then AFM_MODE_DEFAULT when the list has neither (afm_mode's
#   no-row rule). A value that is not on, observe or off is one warn line and
#   observe (afm_mode's rule).
afq_mode_cached() {
  local p="$1" max="$2" now="$3" r f fetched age v
  case "$max" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$max))" -gt 0 ] || return 1
  r=$(afq_root); [ -n "$r" ] || return 1
  f="$r/state/settings-cache.json"
  [ -r "$f" ] || return 1
  fetched=$(jq -r '.fetched_at' "$f" 2>/dev/null) || return 1
  case "$fetched" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#fetched}" -le 12 ] || return 1
  age=$(( 10#$now - 10#$fetched ))
  [ "$age" -ge 0 ] && [ "$age" -le "$((10#$max))" ] || return 1
  v=$(jq -r --arg k "archie.manage.$p" \
    '(.values // {}) as $v | (.seeded // {}) as $s | $v[$k] // $s[$k] // $v["archie.manage"] // $s["archie.manage"] // empty' \
    "$f" 2>/dev/null) || return 1
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  [ -n "$v" ] || v="${AFM_MODE_DEFAULT:-on}"
  case "$v" in
    on|observe|off) ;;
    *) afq_log "warn: the cached archie.manage value for $p is '$v', not on, observe or off; $p is read as observe"
       v=observe ;;
  esac
  printf '%s\t%s\n' "$v" "$age"
}

# afq_alert <text> — one ALERTS line through bin/alert-line.sh, prefixed with
#   the lane that owns the row (AFQ_ACTOR; archie-fm-watch sets its own).
afq_alert() {
  local r; r=$(afq_root); [ -n "$r" ] || return 1
  HARNESS="$r" "$r/bin/alert-line.sh" "${AFQ_ACTOR}: $*" >/dev/null 2>&1 || true
}

# afq_cap_default <playbook> -> the documented fallback when the
#   archie.cap.<playbook> row is absent (the seeds in worker/jobs/schema.sql).
afq_cap_default() {
  case "$1" in
    queue-culprit) printf 10 ;; queue-enqueue) printf 20 ;; queue-reconcile) printf 30 ;; queue-solo) printf 40 ;;
    *) printf 0 ;;
  esac
}

# afq_cap_ok <playbook> <project> -> rc 0 when today's cap leaves room for one
#   more mode=on action; anything unreadable is rc 1. Its own read, not wave
#   1's afm_cap_ok: since BH-4784 that one counts restack|fix_round actions
#   (count_by=action) and memoizes a full cap in AFM_CAP_FULL for the tick,
#   which would never cap a queue playbook and would leak one playbook's full
#   cap into the next. This counts today's mode=on done+requested rows of
#   <playbook> (the worker's default count, by outcome).
afq_cap_ok() {
  local pb="$1" p="$2" cap rc resp used
  cap=$(setting_get "archie.cap.$pb"); rc=$?
  case "$rc" in
    0) cap=$(printf '%s' "$cap" | tr -d '[:space:]') ;;
    2) cap=$(afq_cap_default "$pb") ;;
    *) afq_log "$p: archie.cap.$pb unreadable (rc=$rc); nothing done"; return 1 ;;
  esac
  if ! [[ $cap =~ ^[0-9]+$ ]]; then
    afq_log "$p: archie.cap.$pb='$cap' is not a whole number; nothing done"; return 1
  fi
  if [ "$((10#$cap))" = 0 ]; then afq_log "$p: archie.cap.$pb=0, the playbook is off"; return 1; fi
  resp=$(_afm_req GET "/api/archie/actions?day=$DAY&playbook=$pb&limit=1"); rc=$?
  if [ "$rc" = 2 ]; then AFM_ROUTE_ABSENT=1; return 1; fi
  used=$(jq -r --arg pb "$pb" \
    '(.counts[$pb].on.done // 0) + (.counts[$pb].on.requested // 0) | if type == "number" then . else empty end' \
    <<<"$resp" 2>/dev/null)
  if [ "$rc" != 0 ] || [ -z "$used" ]; then
    afq_log "$p: today's $pb count unreadable (rc=$rc http=${JOBS_HTTP:-none}); nothing done"; return 1
  fi
  if [ "$used" -ge "$((10#$cap))" ]; then
    afq_log "$p: cap reached ($used of $((10#$cap)) $pb actions today); nothing done"; return 1
  fi
  return 0
}

# afq_setting_secs <key> <fallback> -> a whole number of seconds; rc 1 when the
#   row is unreadable or not a whole number (no action on a guess, D11).
afq_setting_secs() {
  local v rc
  v=$(setting_get "$1"); rc=$?
  case "$rc" in
    0) v=$(printf '%s' "$v" | tr -d '[:space:]') ;;
    2) v=$2 ;;
    *) afq_log "$1 unreadable (rc=$rc); that check waits for the next tick"; return 1 ;;
  esac
  [[ $v =~ ^[0-9]+$ ]] || { afq_log "$1='$v' is not a whole number of seconds; that check waits"; return 1; }
  printf '%s' "$((10#$v))"
}

# afq_claim <playbook> <key> <project> <slug> <n> <mode> <action> <why> <evidence-json>
#   POST the row BEFORE anything is written anywhere: outcome started (mode on)
#   or would (observe, which is then already closed).
#   rc 0  created: this tick owns it (AFM_ROW is the row)
#   rc 3  it exists and is not ours. A `started` row older than AFQ_RETRY_S
#         was left by a tick that died: it is closed failed with ONE alert and
#         never reclaimed (every queue action is keyed on its inputs, so it
#         recurs on a new key or not at all). afq_sweep_started closes the
#         ones whose key is never claimed again.
#   rc 9  the key exists with a different payload (409); rc 2 the route is
#         absent (404); rc 1 the worker did not answer
afq_claim() {
  local pb="$1" key="$2" p="$3" slug="$4" n="$5" mode="$6" action="$7" why="$8" ev="$9" out body resp rc
  local AFM_PLAYBOOK="$pb"
  AFM_ROW=""
  out=started; [ "$mode" = on ] || out=would
  body=$(jq -nc --arg k "$key" --arg p "$p" --arg r "$slug" --argjson n "$n" --arg pb "$pb" \
    --arg m "$mode" --arg a "$action" --arg o "$out" --arg w "$why" --argjson e "$ev" --arg act "$AFQ_ACTOR" \
    '{dedupe_key: $k, project: $p, repo: $r, pr: $n, playbook: $pb, mode: $m, action: $a,
      outcome: $o, why: $w, evidence: $e, actor: $act}') || return 1
  resp=$(_afm_req POST /api/archie/actions "$body"); rc=$?
  case "$rc" in
    0) ;;
    2) AFM_ROUTE_ABSENT=1; return 2 ;;
    9) afq_log "$slug#$n: $key exists with a different payload (409); refused"; return 9 ;;
    *) afq_log "$slug#$n: the action could not be recorded (rc=$rc http=${JOBS_HTTP:-none}); nothing done"; return 1 ;;
  esac
  AFM_ROW=$(jq -c '.action // empty' <<<"$resp" 2>/dev/null)
  [ -n "$AFM_ROW" ] || { afq_log "$slug#$n: the worker's answer carried no row; nothing done"; return 1; }
  [ "$(jq -r '.created == true' <<<"$resp")" = true ] && return 0
  afq_close_stale
  AFM_ROW=""
  return 3
}

# afq_close_stale — AFM_ROW, when it is a `started` row older than AFQ_RETRY_S,
#   was left by a tick that died: closed failed with ONE alert (the CAS on its
#   updated_at means two closers never both alert). rc 0 closed, rc 1 not.
afq_close_stale() {
  local pb key slug n upd ts age
  [ "$(jq -r '.outcome // ""' <<<"$AFM_ROW" 2>/dev/null)" = started ] || return 1
  IFS=$'\t' read -r pb key slug n upd < <(jq -r '[.playbook, .dedupe_key, .repo, (.pr | tostring), (.updated_at // "")] | @tsv' <<<"$AFM_ROW")
  # An unreadable stamp is age 0: never stale, so nothing is closed on it.
  ts=""; [ -n "$upd" ] && ts=$(date -u -d "$upd" +%s 2>/dev/null)
  [[ $ts =~ ^[0-9]+$ ]] || ts=$NOW
  age=$(( NOW - ts ))
  [ "$age" -ge "$AFQ_RETRY_S" ] || return 1
  afm_close failed "" "the tick that started it did not finish; not retried on this key" || return 1
  afq_alert "$slug#$n $pb action $key was left started by a tick that stopped ${age}s ago; closed failed and not retried. What it was doing is in logs/${AFQ_ACTOR}.log$([ "$n" -gt 0 ] && printf ': https://github.com/%s/pull/%s' "$slug" "$n")"
  afq_log "$slug#$n: a started $pb row ${age}s old was closed failed, one alert"
}

# afq_sweep_started [project] [slug#n] — once per tick, before any playbook:
#   every `started` row of this lane's four playbooks created today or
#   yesterday (UTC) and older than AFQ_RETRY_S goes through afq_close_stale.
#   Most queue keys carry a head, a main tip or a batch, so a dead tick's key
#   is often never claimed again; this sweep is what closes it. An unreadable
#   day is one log line and waits for the next tick.
afq_sweep_started() {
  local proj="${1:-}" only="${2:-}" pb day resp rc row
  local AFM_PLAYBOOK
  for day in "$DAY" "$(date -u -d "@$(( NOW - 86400 ))" +%F)"; do
    for pb in queue-reconcile queue-culprit queue-solo queue-enqueue; do
      AFM_PLAYBOOK=$pb
      resp=$(_afm_req GET "/api/archie/actions?day=$day&playbook=$pb&limit=500"); rc=$?
      if [ "$rc" = 2 ]; then AFM_ROUTE_ABSENT=1; return 0; fi
      if [ "$rc" != 0 ] || ! jq -e '.actions | type == "array"' <<<"$resp" >/dev/null 2>&1; then
        afq_log "the $pb rows of $day could not be read (rc=$rc http=${JOBS_HTTP:-none}); the started-row sweep waits"; continue
      fi
      [ "$(jq -r '.truncated == true' <<<"$resp")" = true ] && afq_log "the $pb rows of $day are a full page (500); only those were swept"
      while IFS= read -r row; do
        [ -n "$row" ] || continue
        AFM_ROW=$row
        afq_close_stale || true
      done < <(jq -c --arg a "$AFQ_ACTOR" --arg p "$proj" --arg o "$only" '.actions[]
          | select(.outcome == "started" and .mode == "on" and .actor == $a)
          | select($p == "" or .project == $p) | select($o == "" or (.repo + "#" + (.pr | tostring)) == $o)' <<<"$resp")
      AFM_ROW=""
    done
  done
  return 0
}

# afq_close <playbook> <outcome> [action] [why] [evidence-json] — wave 1's CAS.
afq_close() { local AFM_PLAYBOOK="$1"; shift; afm_close "$@"; }

# afq_flag <name> — the conductor's flag_on: the DB row reconciled first.
afq_flag() {
  if command -v flag_active >/dev/null 2>&1; then flag_active "$1"
  else local r; r=$(afq_root); [ -n "$r" ] && [ -f "$r/flags/$1" ]; fi
}

# afq_merges_on <project> -> rc 0 only when the conductor itself would merge
#   or enqueue this tick: merge AND actions flags up, no kill switch, no
#   observe flag, and no fleet or project merges pause (merge-conductor.sh's
#   own reading of the same flags).
afq_merges_on() {
  afq_flag merge-conductor-merge && afq_flag merge-conductor-actions || return 1
  afq_flag automerge-disabled && return 1
  afq_flag merge-conductor-observe && return 1
  if command -v pause_active >/dev/null 2>&1; then
    pause_active fleet merges && return 1
    pause_active "$1" merges && return 1
  fi
  return 0
}

# afq_provider <slug> -> mergify | github | none (mc_queue_provider). Anything
#   but mergify: no enqueue and no culprit hunt on that repo.
afq_provider() { mc_queue_provider "$1"; }

# afq_pr_fresh <slug> <n> — ONE pulls read, never answered from the ETag
#   cache. rc 0 and AFQ_PR_* set (STATE open|closed, MERGED_AT or empty, HEAD,
#   MS mergeable_state, DRAFT, BASE, REF, USER, BODY, LABELS comma-joined);
#   rc 2 unreadable (GH_REST_STATUS says why), and the AFQ_PR_* are empty.
afq_pr_fresh() {
  local j row
  AFQ_PR_STATE=""; AFQ_PR_MERGED_AT=""; AFQ_PR_HEAD=""; AFQ_PR_MS=""; AFQ_PR_DRAFT=""; AFQ_PR_BASE=""
  AFQ_PR_REF=""; AFQ_PR_USER=""; AFQ_PR_BODY=""; AFQ_PR_LABELS=""
  GH_ETAG=0 gh_rest_var j GET "repos/$1/pulls/$2" || return 2
  row=$(jq -r '[(.state // ""), (.merged_at // ""), (.head.sha // ""), (.mergeable_state // ""), (.draft // false | tostring),
                (.base.ref // ""), (.head.ref // ""), (.user.login // ""), ([.labels[]?.name] | join(","))] | join("\u001f")' <<<"$j" 2>/dev/null) \
    || return 2
  # \x1f, not a tab: a tab is IFS whitespace, so an empty merged_at would shift every field after it.
  IFS=$'\x1f' read -r AFQ_PR_STATE AFQ_PR_MERGED_AT AFQ_PR_HEAD AFQ_PR_MS AFQ_PR_DRAFT AFQ_PR_BASE AFQ_PR_REF AFQ_PR_USER AFQ_PR_LABELS <<<"$row"
  case "$AFQ_PR_STATE" in open|closed) ;; *) AFQ_PR_STATE=""; return 2 ;; esac
  AFQ_PR_BODY=$(jq -r '.body // ""' <<<"$j" 2>/dev/null)
  return 0
}

# afq_checks_green <slug> <head> [required-names] -> rc 0 when the head's
#   check-runs are all completed and success/neutral/skipped (at least one),
#   or, with names, when the newest run of each name is; rc 1 not green; rc 2
#   unreadable (a partial page included).
afq_checks_green() {
  local slug="$1" head="$2" req="${3:-}" j
  gh_rest_var j GET "repos/$slug/commits/$head/check-runs?per_page=100" || return 2
  jq -e '(.check_runs | type) == "array" and (.total_count // 0) <= (.check_runs | length)' <<<"$j" >/dev/null 2>&1 || return 2
  jq -e --arg req "$req" '
    def ok: .status == "completed" and ((.conclusion // "") | IN("success", "neutral", "skipped"));
    .check_runs as $r
    | if $req == "" then ($r | length) > 0 and all($r[]; ok)
      else all($req | split("\n")[] | select(length > 0);
             . as $n | [$r[] | select(.name == $n)] | sort_by(.id) | last // null | . != null and ok)
      end' <<<"$j" >/dev/null 2>&1 && return 0
  return 1
}

# afq_rows_of <slug> -> the conductor rows (pr-state.tsv) for that repo.
afq_rows_of() { awk -F'\t' -v p="$1#" 'index($1, p) == 1' "$MC_ROWS" 2>/dev/null; }

# afq_pr_lock <project> <n> — the conductor's PR lock, -n, on fd 8 (released
#   by afq_pr_unlock). rc 1: the conductor is working this PR; skip it.
afq_pr_lock() {
  exec 8>"$(mc_pr_lock "$1" "$2")" || return 1
  flock -n 8 && return 0
  exec 8>&-; return 1
}
afq_pr_unlock() { flock -u 8 2>/dev/null; exec 8>&-; }
