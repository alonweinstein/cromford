#!/bin/bash
# shellcheck shell=bash
# bin/lib/jobs/utilization.sh — BH-4008 (BH-3988 tracer): the utilization
# snapshot verbs over worker/jobs/src/routes/utilization.js. Sourced by
# bin/jobs-client.sh (JC_MODULES), never run.
#
# utilization_put <project> <hour> <verdict> <payload-json> [retention-days]
#   PUT /api/utilization {project, hour, verdict, payload, box, retention_days?}.
#   box is $JOBS_BOX (req.sh resolves it), else hostname. rc 0 when the worker
#   wrote the row; rc 1 on ANY failure: a payload that is not JSON (nothing is
#   sent), transport, a 4xx, a 5xx, and a 404 from a worker that does not have
#   the route yet. That 404 is _jobs_req's rc 2, and a not-deployed route is
#   not "written" (D9).
# utilization_rows <project> <since-iso>
#   GET /api/utilization?project=&since=. rc 0 and the body on stdout when it
#   is JSON with a non-empty `rows` array; rc 2 when `rows` is empty; rc 1 on
#   anything else, a 404 included: an undeployed route is an outage, never
#   "no rows" (D11). The worker answers that project's rows with
#   hour >= since, ascending, at most 500, plus `truncated` (BH-4012).

utilization_put() {
  [ $# -ge 4 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 1
  local body box="${JOBS_BOX:-$(hostname 2>/dev/null)}"
  body=$(jq -nc --arg p "$1" --arg h "$2" --arg v "$3" --argjson pl "$4" --arg b "$box" --arg r "${5:-}" \
    '{project:$p, hour:$h, verdict:$v, payload:$pl, box:$b}
     + (if $r == "" then {} else {retention_days:($r|tonumber)} end)' 2>/dev/null) || return 1
  [ -n "$body" ] || return 1
  _jobs_req PUT /api/utilization "$body" >/dev/null || return 1
}

utilization_rows() {
  [ $# -eq 2 ] && [ -n "$1" ] && [ -n "$2" ] || return 1
  local p s out n
  p=$(jq -rn --arg v "$1" '$v|@uri') && s=$(jq -rn --arg v "$2" '$v|@uri') || return 1
  out=$(_jobs_req GET "/api/utilization?project=$p&since=$s") || return 1
  n=$(printf '%s' "$out" | jq -r 'if (.rows|type) == "array" then (.rows|length) else empty end' 2>/dev/null)
  [ -n "$n" ] || return 1
  [ "$n" -gt 0 ] || return 2
  printf '%s' "$out"
}
