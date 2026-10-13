#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/routing.sh — BH-1369 (BH-1027.0): builder routing rows and the four flags/ files they drive. Sourced by bin/jobs-client.sh (JC_MODULES), never run.

# --- Builder routing (BH-1369) ------------------------------------------------
# THE FILES ARE STILL THE ROUTING. builder-fly-<p>, fly-pool-<p>,
# fly-pool-app-<p> and pool-halt-<p> under flags/ are what caps_route,
# pool-cap.sh, fleet-fly-block.sh and fly-machine-state.sh read. A `routing` row
# drives those files; it never replaces them. Shipped DARK: with the
# `routing_rows` setting off (the default: seeded `off`) the only request is the
# one settings GET that reads the knob (as machines_rows_on does; cached per
# process, so one per jobs-client call), never a /api/routing request, and
# every reader answers from the files alone. ROUTING_ROWS=off skips even that.
#
# THE KNOB IS READ ONCE PER PROCESS. routing_rows_on caches its answer, and a
# failed first read caches OFF, so a flip (either way) takes effect only when a
# process that sources jobs-client.sh next STARTS. A long-lived caller keeps
# the value it read at startup; restart it after a flip.
#
# fly-pool-<p> is created EMPTY when absent and its content is never rewritten:
# it is the pool-cap override bin/pool-cap.sh reads, and the row has no pool
# size. With the knob on, a fly1 or local row DELETES fly-pool-<p>, and that
# override goes with it: the row is the enrollment authority.
# A row read that fails in any way (transport, 5xx, empty body, 404) writes
# nothing, so an outage leaves flags/ byte-identical.
#
# ONE ROUTING READ PER PROCESS (BH-1627). With the knob on, every reader call
# syncs first, and the resolver asks per PR, not per project. So routing_sync
# remembers its answer per project, and after a routing_sync_all attempt no
# per-project GET is sent at all. A process therefore sends at most one
# /api/routing request per project, or exactly one when it syncs all. An outage
# costs one attempt, not one timeout per call. That is the same lifetime as the
# knob read: a row changed after the first read reaches the NEXT process. The
# files stay the answer either way, so a routing_set in the same process is
# seen at once. A reader called inside $(...) cannot write the memo back to its
# parent, so a caller that reads in subshells runs one routing_sync_all at top
# level first. Re-sourcing jobs-client.sh resets the memo, so source it once.
_routing_name_ok() { [ -n "${1:-}" ] && case "$1" in *[!A-Za-z0-9._-]*|.|..) return 1 ;; *) return 0 ;; esac; }

# routing_rows_on — rc 0 iff routing rows drive the files. $ROUTING_ROWS
#   non-empty decides alone (on -> 0); else setting routing_rows exact "on".
_ROUTING_ROWS_ON=""
routing_rows_on() {
  local val
  [ -n "$_ROUTING_ROWS_ON" ] && return "$_ROUTING_ROWS_ON"
  if [ -n "${ROUTING_ROWS:-}" ]; then
    [ "$ROUTING_ROWS" = "on" ] && return 0
    return 1
  fi
  _ROUTING_ROWS_ON=1
  val=$(setting_get routing_rows 2>/dev/null) || return 1
  [ "$val" = "on" ] && _ROUTING_ROWS_ON=0
  return "$_ROUTING_ROWS_ON"
}

# routing_get <project> — print the row JSON. rc 1 bad arg/outage/empty body,
#   rc 2 no row (404).
routing_get() {
  local p="${1:-}" resp rc
  _routing_name_ok "$p" || return 1
  resp=$(_jobs_req GET "/api/routing/$p"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$resp" | jq -ce '.routing | select(type == "object" and (.builder | type) == "string")' 2>/dev/null || return 1
}

# _routing_apply <project> <builder> <pool_app> <halted> — converge the four
#   files. Touch only if absent, rm only if present, so an unchanged row leaves
#   mtimes alone.
_routing_apply() {
  local p="$1" builder="$2" app="$3" halted="$4" d="$JOBS_HARNESS/flags"
  mkdir -p "$d" 2>/dev/null || return 1
  case "$builder" in
    local) rm -f "$d/builder-fly-$p" "$d/fly-pool-$p" "$d/fly-pool-app-$p" ;;
    fly1)  [ -e "$d/builder-fly-$p" ] || : > "$d/builder-fly-$p"
           rm -f "$d/fly-pool-$p" "$d/fly-pool-app-$p" ;;
    pool)  [ -e "$d/builder-fly-$p" ] || : > "$d/builder-fly-$p"
           [ -e "$d/fly-pool-$p" ] || : > "$d/fly-pool-$p"
           if [ -n "$app" ]; then
             [ "$(cat "$d/fly-pool-app-$p" 2>/dev/null)" = "$app" ] || printf '%s\n' "$app" > "$d/fly-pool-app-$p"
           else rm -f "$d/fly-pool-app-$p"; fi ;;
    *) return 1 ;;
  esac
  if [ "$halted" = 1 ]; then [ -e "$d/pool-halt-$p" ] || : > "$d/pool-halt-$p"
  else rm -f "$d/pool-halt-$p"; fi
}

# _routing_apply_row <row-json> — validate a row and apply it.
_routing_apply_row() {
  local p b a h
  p=$(printf '%s' "$1" | jq -r '.project // empty' 2>/dev/null)
  b=$(printf '%s' "$1" | jq -r '.builder // empty' 2>/dev/null)
  a=$(printf '%s' "$1" | jq -r '.pool_app // empty' 2>/dev/null)
  h=$(printf '%s' "$1" | jq -r 'if .halted == 1 or .halted == true then 1 else 0 end' 2>/dev/null)
  _routing_name_ok "$p" || return 1
  [ -z "$a" ] || _routing_name_ok "$a" || return 1
  case "$b" in local|fly1|pool) ;; *) return 1 ;; esac
  _routing_apply "$p" "$b" "$a" "$h"
}

# routing_sync <project> — knob off: rc 0, no request. Else derive the files
#   from the row; any read failure returns its rc with the files untouched.
#   Once per project per process, and never after a routing_sync_all (above).
_ROUTING_MEMO=" "   # " <project>=<rc> " for every project this process synced
_ROUTING_ALL_RC=""   # the rc of this process's routing_sync_all, once attempted
_routing_memo_get() { case "$_ROUTING_MEMO" in *" $1="*) local t="${_ROUTING_MEMO#* "$1"=}"; return "${t%% *}" ;; esac; return 255; }
routing_sync() {
  local p="${1:-}" rc
  _routing_name_ok "$p" || return 1
  routing_rows_on || return 0
  [ -n "$_ROUTING_ALL_RC" ] && return "$_ROUTING_ALL_RC"
  _routing_memo_get "$p"; rc=$?; [ "$rc" -eq 255 ] || return "$rc"
  _routing_sync_one "$p"; rc=$?
  _ROUTING_MEMO="$_ROUTING_MEMO$p=$rc "
  return "$rc"
}
_routing_sync_one() {
  local p="$1" row rc
  row=$(routing_get "$p"); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ "$(printf '%s' "$row" | jq -r '.project' 2>/dev/null)" = "$p" ] || return 1
  _routing_apply_row "$row"
}

# routing_sync_all — knob off: rc 0, no request. Else apply every listed row.
#   Once per process: a second call answers the first call's rc.
routing_sync_all() {
  routing_rows_on || return 0
  [ -n "$_ROUTING_ALL_RC" ] && return "$_ROUTING_ALL_RC"
  _routing_sync_all_once; _ROUTING_ALL_RC=$?
  return "$_ROUTING_ALL_RC"
}
_routing_sync_all_once() {
  local resp rc row bad=0
  resp=$(_jobs_req GET /api/routing); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$resp" | jq -e '.routing | type == "array"' >/dev/null 2>&1 || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    _routing_apply_row "$row" || bad=1
  done < <(printf '%s' "$resp" | jq -c '.routing[]' 2>/dev/null)
  return "$bad"
}

# routing_list — TSV: project builder pool_app halted updated_at. rc as _jobs_req.
routing_list() {
  local resp rc
  resp=$(_jobs_req GET /api/routing); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$resp" | jq -r '.routing[] | [.project, .builder, (.pool_app // ""), (.halted // 0), (.updated_at // "")] | @tsv' 2>/dev/null
}

# routing_set <project> <local|fly1|pool> [pool_app] [halted 0|1] [actor] [reason] — files FIRST,
#   then PUT the row. rc 1 on bad args (nothing written) or on PUT failure
#   (files already written). Not gated on the knob, so a row can be seeded
#   before the flip — the file write is today's mechanism either way.
routing_set() {
  local p="${1:-}" b="${2:-}" a="${3:-}" h="${4:-0}" actor="${5:-}" reason="${6:-}" body
  _routing_name_ok "$p" || return 1
  case "$b" in local|fly1|pool) ;; *) return 1 ;; esac
  [ -z "$a" ] || _routing_name_ok "$a" || return 1
  case "$h" in 0|1) ;; *) return 1 ;; esac
  _routing_apply "$p" "$b" "$a" "$h" || return 1
  # actor/reason ride into the row's audit trail (BH-2010: routing_changes); the
  # worker records a write with no actor as "api".
  body=$(jq -nc --arg p "$p" --arg b "$b" --arg a "$a" --argjson h "$h" --arg ac "$actor" --arg r "$reason" \
    '{project:$p, builder:$b, halted:$h} + (if $a == "" then {} else {pool_app:$a} end)
     + (if $ac == "" then {} else {actor:$ac} end) + (if $r == "" then {} else {reason:$r} end)' 2>/dev/null) || return 1
  _jobs_req PUT /api/routing "$body" >/dev/null || return 1
}

# routing_row_from_files <project> — print `builder|pool_app|halted`, the row
#   these four files express, the way caps_route reads them (BH-1627). Pure read.
routing_row_from_files() {
  local p="${1:-}" d="$JOBS_HARNESS/flags" b=local a="" h=0
  _routing_name_ok "$p" || return 1
  if [ -f "$d/builder-fly-$p" ]; then b=fly1; [ -f "$d/fly-pool-$p" ] && b=pool; fi
  [ "$b" = pool ] && a=$(cat "$d/fly-pool-app-$p" 2>/dev/null)
  [ -f "$d/pool-halt-$p" ] && h=1
  printf '%s|%s|%s\n' "$b" "$a" "$h"
}

# routing_row_drift <project> <builder> <pool_app> <halted> — print, one per
#   line, each file change _routing_apply would make for that row; nothing when
#   the row leaves the files byte-identical (BH-1627). Pure read, rc 0.
routing_row_drift() {
  local p="$1" b="$2" a="$3" h="$4" d="$JOBS_HARNESS/flags" wbf=0 wfp=0 wa="" hbf=0 hfp=0 ha hh=0
  case "$b" in
    local) ;;
    fly1) wbf=1 ;;
    pool) wbf=1; wfp=1; wa="$a" ;;
    *) echo "$p: builder '$b' is not local|fly1|pool"; return 0 ;;
  esac
  [ -e "$d/builder-fly-$p" ] && hbf=1
  [ -e "$d/fly-pool-$p" ] && hfp=1
  ha=$(cat "$d/fly-pool-app-$p" 2>/dev/null)
  [ -e "$d/pool-halt-$p" ] && hh=1
  [ "$wbf" = "$hbf" ] || echo "$p: builder-fly-$p would be $([ "$wbf" = 1 ] && echo created || echo removed)"
  [ "$wfp" = "$hfp" ] || echo "$p: fly-pool-$p would be $([ "$wfp" = 1 ] && echo created || echo removed)"
  if [ "$wa" != "$ha" ] || { [ -z "$wa" ] && [ -e "$d/fly-pool-app-$p" ]; }; then
    echo "$p: fly-pool-app-$p '$ha' would become $([ -n "$wa" ] && echo "'$wa'" || echo removed)"
  fi
  [ "$h" = "$hh" ] || echo "$p: pool-halt-$p would be $([ "$h" = 1 ] && echo created || echo removed)"
  return 0
}

# Readers. Knob off: the files alone, zero requests. Knob on: reconcile first,
#   then the FILE answers, so an outage answers exactly what the file says.
routing_builder() { # prints pool | fly1 | local, the same tests caps_route uses
  local p="${1:-}" d="$JOBS_HARNESS/flags"
  _routing_name_ok "$p" || return 1
  if routing_rows_on; then routing_sync "$p" >/dev/null 2>&1 || true; fi
  if [ -f "$d/builder-fly-$p" ] && [ -f "$d/fly-pool-$p" ]; then echo pool
  elif [ -f "$d/builder-fly-$p" ]; then echo fly1
  else echo local; fi
}

routing_pool_app() { # prints the pool app; rc 1 and nothing when there is none
  local p="${1:-}" app
  _routing_name_ok "$p" || return 1
  if routing_rows_on; then routing_sync "$p" >/dev/null 2>&1 || true; fi
  app=$(cat "$JOBS_HARNESS/flags/fly-pool-app-$p" 2>/dev/null)
  [ -n "$app" ] || return 1
  printf '%s\n' "$app"
}

routing_halted() { # rc 0 iff flags/pool-halt-<p> exists
  local p="${1:-}"
  _routing_name_ok "$p" || return 1
  if routing_rows_on; then routing_sync "$p" >/dev/null 2>&1 || true; fi
  [ -f "$JOBS_HARNESS/flags/pool-halt-$p" ]
}

# --- P4: plan-driven model routing, SHADOW MODE (worker/jobs/src/routes/route-rules.js)
# The rules are rows (route_rules), their writes are audited (route_rule_changes),
# and every build records what they WOULD have picked (route_shadow). Nothing
# here changes what a build runs on: bin/lib/route-rules.sh reads these to write
# a shadow row, and bin/route-shadow-report.sh reads the rows back. Transport
# only, fail-open like the rest of this file: rc 0 + the worker's JSON on a 2xx.

# route_rules_list -> GET /api/route-rules (every rule, priority order)
route_rules_list() {
  _jobs_req GET /api/route-rules
}

# route_rule_put <json-file> -> PUT /api/route-rules with the file as the body:
#   the WHOLE row {name, priority, effect, mode, match, execute_role,
#   review_tier, test_scope, tier_bump, note, actor, reason, expected_version}.
#   A 409 (stale expected_version) or a 400 is a non-zero rc; the worker's body
#   is in JOBS_BODY.
route_rule_put() {
  local f="${1:-}" body
  [ -s "$f" ] || return 1
  body=$(jq -c . "$f" 2>/dev/null) || return 1
  _jobs_req PUT /api/route-rules "$body"
}

# route_shadow_put <json> -> POST /api/route-shadow (one row per build dir)
route_shadow_put() {
  [ -n "${1:-}" ] || return 1
  _jobs_req POST /api/route-shadow "$1"
}

# route_shadow_list [since-iso] [project] [limit] -> GET /api/route-shadow
route_shadow_list() {
  local q=""
  [ -n "${1:-}" ] && q="since=$(jq -rn --arg v "$1" '$v|@uri')"
  [ -n "${2:-}" ] && q="${q:+$q&}project=$(jq -rn --arg v "$2" '$v|@uri')"
  [ -n "${3:-}" ] && q="${q:+$q&}limit=$(jq -rn --arg v "$3" '$v|@uri')"
  _jobs_req GET "/api/route-shadow${q:+?$q}"
}

# route_shadow_bounce <project> [rule] [days] -> GET /api/route-shadow/bounce
#   {reviewed, blocked, rate}: the first-review BLOCK share (rate null = not
#   measured, never 0).
route_shadow_bounce() {
  local q
  [ -n "${1:-}" ] || return 1
  q="project=$(jq -rn --arg v "$1" '$v|@uri')&days=$(jq -rn --arg v "${3:-30}" '$v|@uri')"
  [ -n "${2:-}" ] && q="$q&rule=$(jq -rn --arg v "$2" '$v|@uri')"
  _jobs_req GET "/api/route-shadow/bounce?$q"
}
