#!/bin/bash
# shellcheck shell=bash
# bin/lib/model-watch.sh — BH-3425 (BH-3422.0) contract: the model-watch id
# normalizer and the jobs verbs over the model_watch table
# (worker/jobs/src/routes/model-watch.js). Sourced, never run. Callers source
# bin/jobs-client.sh first for _jobs_req; this lib is NOT in its JC_MODULES.
#
# mw_norm_id <model id>
#   Prints the one key every shape of a model id collapses to: lowercased, any
#   `vendor/` prefix and `:free`-style suffix stripped, `.` turned into `-`, a
#   trailing `-YYYYMMDD` snapshot stripped. rc 1 and nothing on empty input or
#   an empty key.
# mw_record <json>                    POST /api/model-watch
# mw_get [status] [vendor]            GET  /api/model-watch?status=&vendor=
# mw_set_state <json>                 PUT  /api/model-watch/state
# mw_usage <model id> <since>         GET  /api/model-watch/usage?model=&since=
#
# Each verb prints the response body on a 2xx. Every failure is rc 1 with
# nothing on stdout: any non-2xx (a 409 included), a transport error, an
# unconfigured client, a missing required argument (then no request is made).

_mw_uri() { jq -rn --arg v "$1" '$v|@uri'; }

mw_norm_id() {
  local id=${1:-}
  [ -n "$id" ] || return 1
  id=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
  id=${id##*/}
  id=${id%%:*}
  id=${id//./-}
  id=$(printf '%s' "$id" | sed -E 's/-[0-9]{8}$//')
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

mw_record() {
  [ -n "${1:-}" ] || return 1
  local out
  out=$(_jobs_req POST /api/model-watch "$1") || return 1
  printf '%s\n' "$out"
}

mw_get() {
  local out
  out=$(_jobs_req GET "/api/model-watch?status=$(_mw_uri "${1:-}")&vendor=$(_mw_uri "${2:-}")") || return 1
  printf '%s\n' "$out"
}

mw_set_state() {
  [ -n "${1:-}" ] || return 1
  local out
  out=$(_jobs_req PUT /api/model-watch/state "$1") || return 1
  printf '%s\n' "$out"
}

mw_usage() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  local out
  out=$(_jobs_req GET "/api/model-watch/usage?model=$(_mw_uri "$1")&since=$(_mw_uri "$2")") || return 1
  printf '%s\n' "$out"
}
