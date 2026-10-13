#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/box-console-commands.sh — BH-2653 (BH-2528.0). The shell client
# for the box_console_commands queue (worker/jobs/schema.sql): four verbs over
# the worker's /api/box-console-commands routes. Sourced, never executed, and
# only after bin/jobs-client.sh is loaded (_jobs_req).
#
# NOT A JC_MODULES MODULE. It builds on _jobs_req without editing the jobs
# client, so the fixture suites that copy bin/lib/jobs/ are untouched. Nothing
# runs at source time: function definitions only.
#
# rc map, per verb: 0 only on a 2xx (with the documented body where one is
# documented), 1 on an outage, an unset JOBS_URL, a bad answer or bad input (no
# request is made for bad input), 2 on a 404, 9 on a 409. JOBS_HTTP is left as
# _jobs_req set it. A read that fails prints nothing.
#
# payload travels as a JSON STRING holding the console payload text
# byte-for-byte. It goes to jq on stdin, never on argv, so a payload over the
# 128 KB argv cap still arrives whole (_jobs_req spills it to a file).

# _bccmd_ready — rc 0 when a request can be made. Otherwise one stderr line and
# rc 1, with no request.
_bccmd_ready() {
  if declare -F _jobs_req >/dev/null 2>&1 && [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ]; then
    return 0
  fi
  echo "box-console-commands: coordination DB not configured (JOBS_URL or the shared harness key is unset)" >&2
  return 1
}

_bccmd_bad() { echo "box-console-commands: $*" >&2; return 1; }

_bccmd_posint() { case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac; }

# box_ccmd_forward <id> <box> <type> <project> <payload-json> — POST
#   /api/box-console-commands. Prints the 2xx body ({created:true|false}).
#   An empty project travels as null.
box_ccmd_forward() {
  [ "$#" -eq 5 ] || _bccmd_bad "box_ccmd_forward needs <id> <box> <type> <project> <payload-json>, got $# args" || return 1
  local id="$1" box="$2" type="$3" project="$4" payload="$5" body rc
  [ -n "$id" ] && [ -n "$box" ] && [ -n "$type" ] || _bccmd_bad "box_ccmd_forward: id, box and type must be non-empty" || return 1
  printf '%s' "$payload" | jq -e . >/dev/null 2>&1 || _bccmd_bad "box_ccmd_forward $id: payload is not JSON" || return 1
  _bccmd_ready || return 1
  body=$(printf '%s' "$payload" | jq -Rsc --arg id "$id" --arg box "$box" --arg type "$type" --arg project "$project" \
    '{command_id:$id, box:$box, type:$type, project:(if $project == "" then null else $project end), payload:.}') || return 1
  # Not in $(...): JOBS_HTTP must survive into the caller's shell.
  _jobs_req POST /api/box-console-commands "$body" >/dev/null; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "${JOBS_BODY:-}"
}

# box_ccmd_claim <box> <limit> — POST /api/box-console-commands/claim. Prints
#   the claimed rows, a JSON array. Any other 2xx body is rc 1.
box_ccmd_claim() {
  local box="${1:-}" limit="${2:-}" body rc
  [ -n "$box" ] || _bccmd_bad "box_ccmd_claim needs <box> <limit>" || return 1
  _bccmd_posint "$limit" || _bccmd_bad "box_ccmd_claim: limit must be a positive integer, got '$limit'" || return 1
  _bccmd_ready || return 1
  body=$(jq -nc --arg box "$box" --argjson limit "$limit" '{box:$box, limit:$limit}') || return 1
  _jobs_req POST /api/box-console-commands/claim "$body" >/dev/null; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "${JOBS_BODY:-}" | jq -ce 'if type == "array" then . else error("not an array") end' 2>/dev/null || return 1
}

# box_ccmd_result <id> <box> <ok 0|1> <result> [body-file] — POST
#   /api/box-console-commands/<id>/result. body is the file's text, or null
#   when no file is given. Prints the 2xx body.
box_ccmd_result() {
  [ "$#" -eq 4 ] || [ "$#" -eq 5 ] || _bccmd_bad "box_ccmd_result needs <id> <box> <ok> <result> [body-file], got $# args" || return 1
  local id="$1" box="$2" ok="$3" result="$4" bf="${5:-}" body path rc
  [ -n "$id" ] && [ -n "$box" ] || _bccmd_bad "box_ccmd_result: id and box must be non-empty" || return 1
  case "$ok" in 0|1) ;; *) _bccmd_bad "box_ccmd_result: ok must be 0 or 1, got '$ok'"; return 1 ;; esac
  if [ "$#" -eq 5 ]; then
    [ -f "$bf" ] && [ -r "$bf" ] || _bccmd_bad "box_ccmd_result $id: body file '$bf' is not readable" || return 1
  fi
  _bccmd_ready || return 1
  if [ "$#" -eq 5 ]; then
    body=$(jq -nc --arg box "$box" --argjson ok "$ok" --arg result "$result" --rawfile body "$bf" \
      '{box:$box, ok:$ok, result:$result, body:$body}') || return 1
  else
    body=$(jq -nc --arg box "$box" --argjson ok "$ok" --arg result "$result" \
      '{box:$box, ok:$ok, result:$result, body:null}') || return 1
  fi
  path="/api/box-console-commands/$(jq -rn --arg v "$id" '$v|@uri')/result" || return 1
  _jobs_req POST "$path" "$body" >/dev/null; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "${JOBS_BODY:-}"
}

# box_ccmd_expire <ttl_s> — POST /api/box-console-commands/expire. Prints the
#   answer, an object whose expired and stale_claimed are arrays. Any other
#   2xx body is rc 1.
box_ccmd_expire() {
  local ttl="${1:-}" body rc
  _bccmd_posint "$ttl" || _bccmd_bad "box_ccmd_expire: ttl_s must be a positive integer, got '$ttl'" || return 1
  _bccmd_ready || return 1
  body=$(jq -nc --argjson ttl "$ttl" '{ttl_s:$ttl}') || return 1
  _jobs_req POST /api/box-console-commands/expire "$body" >/dev/null; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "${JOBS_BODY:-}" | jq -ce 'if type == "object" and (.expired|type) == "array" and (.stale_claimed|type) == "array"
    then . else error("bad expire answer") end' 2>/dev/null || return 1
}
