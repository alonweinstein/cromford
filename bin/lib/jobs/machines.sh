#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/machines.sh — BH-1194: the rows whose subject is a MACHINE or the fleet rather than a job: the Fly machine registry (BH-1054) and the shared facts a single box may not decide alone — account leases and the GitHub rate budget (BH-1043). Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# --- Fly machine registry (BH-1054, routes BH-1055) -------------------------
# The routes are LIVE (`PUT /api/machines`, `PUT /api/machines/observe`,
# `PATCH /api/machines/<id>`, `GET /api/machines`); the `fly_machines_rows` flag
# is the only thing between a caller and a row. Every helper fails open: on any
# API problem it returns nonzero and prints nothing, so a worker outage never
# changes a caller's exit code. The flag is resolved env-first so an operator can
# turn the registry dark on one box without touching the DB.
#
# RC FROM `_jobs_req`, passed straight through by these verbs: rc 1 transport or
# an error status, rc 2 the worker answered 404 (an older deploy without these
# routes). Every caller treats any nonzero the same way: keep the file.

# machines_rows_on — rc 0 iff the Fly machine registry rows are enabled.
#   Resolution: $FLY_MACHINES_ROWS non-empty decides alone (on -> rc 0, else rc 1);
#   otherwise setting_get fly_machines_rows exact "on" -> rc 0; anything else rc 1.
#   Prints nothing.
machines_rows_on() {
  local val
  if [ -n "${FLY_MACHINES_ROWS:-}" ]; then
    [ "$FLY_MACHINES_ROWS" = "on" ] && return 0
    return 1
  fi
  val=$(setting_get fly_machines_rows 2>/dev/null) || return 1
  [ "$val" = "on" ] && return 0
  return 1
}

# machine_put <project> <app> <machine_id> <role> [key] [ticket] [auth_account] [image] [state]
#   rc 0 -> PUT /api/machines succeeded.
#   rc 1 -> empty required arg or API failure; rc 2 -> the worker answered 404
#           (route not deployed). Prints nothing either way.
machine_put() {
  local project="${1:-}" app="${2:-}" machine_id="${3:-}" role="${4:-}"
  local key="${5:-}" ticket="${6:-}" auth_account="${7:-}" image="${8:-}" state="${9:-spawned}" body
  [ -n "$project" ] && [ -n "$app" ] && [ -n "$machine_id" ] && [ -n "$role" ] || return 1
  body=$(jq -nc     --arg p "$project" --arg a "$app" --arg m "$machine_id" --arg r "$role"     --arg k "$key" --arg t "$ticket" --arg ac "$auth_account" --arg i "$image"     --arg s "$state" --arg b "$JOBS_BOX"     '{project:$p, app:$a, machine_id:$m, role:$r, state:$s, actor:$b}
     + (if $k == "" then {} else {key:$k} end)
     + (if $t == "" then {} else {ticket:$t} end)
     + (if $ac == "" then {} else {auth_account:$ac} end)
     + (if $i == "" then {} else {image:$i} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/machines "$body" >/dev/null
}

# machines_observe <project> <app> <listing-json-file>
#   Reads a JSON array of Fly machine snapshots and PUTs them as observations.
#   rc 1 -> missing file, non-array payload, or API failure; rc 2 -> 404 from the
#           worker. Prints nothing either way.
machines_observe() {
  local project="${1:-}" app="${2:-}" file="${3:-}" body
  [ -n "$project" ] && [ -n "$app" ] && [ -n "$file" ] && [ -f "$file" ] || return 1
  jq -e 'type == "array"' "$file" >/dev/null 2>&1 || return 1
  body=$(jq -nc --arg p "$project" --arg a "$app" --arg b "$JOBS_BOX" --slurpfile machines "$file"     '{project:$p, app:$a, actor:$b, machines: [$machines[0][] | {machine_id:.id, state:.state, updated_at:.updated_at}]}' 2>/dev/null) || return 1
  _jobs_req PUT /api/machines/observe "$body" >/dev/null
}

# machine_close <project> <app> <machine_id> <state> [detail]
#   PATCH /api/machines/<machine_id> to record a terminal or corrective state.
#   `state` must be in the contract's vocabulary — `destroy_failed` is in it and
#   is NOT terminal, because the pool sweep retries that destroy.
#   rc 1 -> empty required arg or API failure; rc 2 -> 404 from the worker.
#           Prints nothing either way.
machine_close() {
  local project="${1:-}" app="${2:-}" machine_id="${3:-}" state="${4:-}" detail="${5:-}" body
  [ -n "$project" ] && [ -n "$app" ] && [ -n "$machine_id" ] && [ -n "$state" ] || return 1
  body=$(jq -nc --arg p "$project" --arg a "$app" --arg s "$state" --arg d "$detail" --arg b "$JOBS_BOX"     '{project:$p, app:$a, state:$s, actor:$b}
     + (if $d == "" then {} else {detail:$d} end)' 2>/dev/null) || return 1
  _jobs_req PATCH "/api/machines/$machine_id" "$body" >/dev/null
}

# machines_list [project] [live]
#   GET /api/machines with optional project filter and live=1 flag.
#   Prints TSV: machine_id project app role key ticket state spawned_at last_seen.
#   API failure -> rc 1, a 404 -> rc 2; no output either way.
machines_list() {
  local project="${1:-}" live="${2:-}" q="" resp
  [ -n "$project" ] && q="project=$project"
  [ "$live" = "live" ] && q="${q:+$q&}live=1"
  resp=$(_jobs_req GET "/api/machines${q:+?$q}") || return $?
  printf '%s' "$resp" | jq -r '.machines[]? | [
    .machine_id, .project, .app, .role,
    (.key // ""), (.ticket // ""), .state,
    (.spawned_at // ""), (.last_seen // "")
  ] | @tsv' 2>/dev/null
}

# --- Shared facts: account leases and the GitHub budget (BH-1043) ------------
# Two things every box used to keep its OWN copy of, both of which are only
# true fleet-wide (audit of 2026-09-19, §2.4):
#
#   * how many builds an account is carrying. bin/lib/pool-account.sh counts
#     FILES under state/quota/leases/<account>/<machine-id>, per box, so two
#     boxes at cap 4 put 8 sessions on an account rated for ~4.
#   * how much GitHub rate budget is left. The bucket belongs to the TOKEN; the
#     fleet shares one identity; nine boxes each read "4,800 remaining" and each
#     believed it had 4,800 to spend.
#
# The lease helpers keep a THREE-WAY rc, and the difference matters more than
# usual: rc 1 means the worker said no (the account is full fleet-wide) and rc 2
# means nobody knows. A caller that collapsed them would read an outage as a
# saturated fleet and put every machine back on the one capped default token,
# which is the failure this whole feature exists to stop.

# account_lease_claim <account> <machine-id> [project] [key] [cap] [ttl-s]
#   rc 0 -> claimed. Prints "<live>\t<cap>" after the write.
#   rc 1 -> REFUSED: the cap is full, counted over rows that have not expired
#           and are not this machine's own. A renew by the same machine is
#           always rc 0.
#   rc 2 -> unknown (unreachable, 5xx, 404 on a worker not yet redeployed).
account_lease_claim() {
  local a="${1:-}" m="${2:-}" p="${3:-}" k="${4:-}" cap="${5:-}" ttl="${6:-}" body resp rc
  [ -n "$a" ] && [ -n "$m" ] || return 2
  body=$(jq -nc --arg a "$a" --arg m "$m" --arg b "$JOBS_BOX" --arg p "$p" --arg k "$k" \
                --arg c "$cap" --arg t "$ttl" \
    '{account:$a,machine_id:$m,box:$b}
     + (if $p == "" then {} else {project:$p} end)
     + (if $k == "" then {} else {ticket_key:$k} end)
     + (if $c == "" then {} else {cap:($c|tonumber)} end)
     + (if $t == "" then {} else {ttl_s:($t|tonumber)} end)' 2>/dev/null) || return 2
  resp=$(_jobs_req POST /api/account-leases/claim "$body"); rc=$?
  case "$rc" in
    0) printf '%s' "$resp" | jq -r '[(.live // 0),(.cap // 0)] | @tsv' 2>/dev/null; return 0 ;;
    9) return 1 ;;
    *) return 2 ;;
  esac
}

# account_lease_release <machine-id> [account]
#   The machine is gone; free whatever it held. Fail-open: rc 1 on an outage and
#   the TTL frees the row anyway, which is exactly what a machine that vanished
#   without a release relies on.
account_lease_release() {
  local m="${1:-}" a="${2:-}" body
  [ -n "$m" ] || return 1
  body=$(jq -nc --arg m "$m" --arg a "$a" \
    '{machine_id:$m} + (if $a == "" then {} else {account:$a} end)' 2>/dev/null) || return 1
  _jobs_req POST /api/account-leases/release "$body" >/dev/null
}

# account_lease_count <account>
#   The live lease count for an account across the WHOLE fleet. rc 0 and the
#   number, or rc 1 and nothing — never 0 on an outage, because "no numbers"
#   and "no leases" send a picker in opposite directions.
account_lease_count() {
  local a="${1:-}" resp n
  [ -n "$a" ] || return 1
  resp=$(_jobs_req GET "/api/account-leases?account=$a") || return 1
  n=$(printf '%s' "$resp" | jq -r '.live // empty' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$n"
}

# account_lease_counts
#   The WHOLE fleet's live counts in one call, as "<account>\t<n>" lines. A
#   picker that ranks every account would otherwise make one request per
#   candidate per machine it spawns; a pool tick launching ten machines across
#   seven accounts turns 70 round trips into 10. rc 1 and nothing on an outage.
account_lease_counts() {
  local resp
  resp=$(_jobs_req GET /api/account-leases) || return 1
  printf '%s' "$resp" | jq -r '(.counts // {}) | to_entries[] | [.key, .value] | @tsv' 2>/dev/null
}

# ── Fleet cooldowns (BH-2353) ─────────────────────────────────────────────────
# The client half of worker/jobs/src/routes/cooldowns.js. Callers go through
# bin/lib/fleet-cooldown.sh, not these. Same three-way rc as the leases:
# 0 ok, 1 the worker said none, 2 unknown.

# cooldown_put <kind> <vendor> <subject> <until> [since] [reason]
#   rc 0 the row is stored, 2 otherwise. There is no rc 1: _jobs_req runs in
#   $( ), so a 400 and a 500 both arrive as rc 1 and cannot be told apart.
cooldown_put() {
  local k="${1:-}" v="${2:-}" s="${3:-}" u="${4:-}" si="${5:-}" r="${6:-}" body resp
  case "$u" in ''|*[!0-9]*) return 2 ;; esac
  case "$si" in *[!0-9]*) return 2 ;; esac
  body=$(jq -nc --arg k "$k" --arg v "$v" --arg s "$s" --argjson u "$u" --arg si "$si" \
                --arg r "$r" --arg b "${JOBS_BOX:-}" \
    '{kind:$k,vendor:$v,subject:$s,until:$u}
     + (if $si == "" then {} else {since:($si|tonumber)} end)
     + (if $r == "" then {} else {reason:$r} end)
     + (if $b == "" then {} else {box:$b} end)' 2>/dev/null) || return 2
  resp=$(_jobs_req POST /api/cooldowns "$body") || return 2
  printf '%s' "$resp" | jq -e '.ok == true' >/dev/null 2>&1 || return 2
}

# cooldown_clear <kind> <vendor> <subject>
#   rc 0 a row was removed, 1 none existed, 2 unknown.
cooldown_clear() {
  local body resp n
  body=$(jq -nc --arg k "${1:-}" --arg v "${2:-}" --arg s "${3:-}" \
    '{kind:$k,vendor:$v,subject:$s}' 2>/dev/null) || return 2
  resp=$(_jobs_req POST /api/cooldowns/clear "$body") || return 2
  n=$(printf '%s' "$resp" | jq -r '.cleared // empty' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) return 2 ;; esac
  [ "$n" -ge 1 ] && return 0
  return 1
}

# cooldown_list <kind>
#   Prints vendor<TAB>subject<TAB>until<TAB>since<TAB>reason<TAB>box per live
#   row. rc 0 rows, 1 a complete empty answer, 2 unknown. A TRUNCATED answer is
#   rc 2 too, with the rows it got still printed: a miss in a capped list is not
#   "not cooling".
cooldown_list() {
  local k="${1:-}" resp
  case "$k" in ''|*[!a-z]*) return 2 ;; esac
  resp=$(_jobs_req GET "/api/cooldowns?kind=$k") || return 2
  printf '%s' "$resp" | jq -e '.rows | type == "array"' >/dev/null 2>&1 || return 2
  printf '%s' "$resp" | jq -r '.rows[]
    | [.vendor, .subject, .until, (.since // ""), (.reason // ""), (.box // "")] | @tsv' 2>/dev/null
  printf '%s' "$resp" | jq -e '.truncated == true' >/dev/null 2>&1 && return 2
  printf '%s' "$resp" | jq -e '.rows | length > 0' >/dev/null 2>&1 || return 1
  return 0
}

# gh_budget_row_put <json>
#   Publish one rate_limit reading for a token fingerprint. The json is the row
#   the worker stores: {fingerprint, fetched_at, core:{...}, graphql:{...}}.
#   The upsert is MONOTONIC on fetched_at server-side, so a slow box's older
#   reading can never overwrite a newer one.
gh_budget_row_put() {
  local body="${1:-}"
  [ -n "$body" ] || return 1
  printf '%s' "$body" | jq -e '.fingerprint' >/dev/null 2>&1 || return 1
  _jobs_req POST /api/gh-budget "$body" >/dev/null
}

# gh_budget_row_get <fingerprint> [max-age-s]
#   Print the shared reading for this token, or rc 1. With a max age, a row
#   older than that is NOT an answer — a stale figure handed out as current is
#   worse than no figure, because the caller would skip its own read to get it.
gh_budget_row_get() {
  local fp="${1:-}" max="${2:-}" resp row age now
  [ -n "$fp" ] || return 1
  resp=$(_jobs_req GET "/api/gh-budget?fingerprint=$fp") || return 1
  row=$(printf '%s' "$resp" | jq -c '.row // empty' 2>/dev/null)
  [ -n "$row" ] || return 1
  if [ -n "$max" ]; then
    now=$(date -u +%s)
    age=$(printf '%s' "$row" | jq -r '.fetched_at // 0' 2>/dev/null)
    case "$age" in ''|*[!0-9]*) return 1 ;; esac
    [ "$(( now - age ))" -lt "$max" ] || return 1
  fi
  printf '%s\n' "$row"
}

