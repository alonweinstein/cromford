#!/bin/bash
# bin/lib/port-cursor.sh — client for the port watermark (BH-5227).
# Sourced, never executed; defines functions only, and nothing runs at source
# time.
#
# The worker side is worker/jobs/src/routes/port-cursor.js (GET|PUT
# /api/port/cursor); the caller is bin/port-to-cromford.sh. The caller must
# already have sourced bin/jobs-client.sh: this lib uses its _jobs_req and never
# loads it, so with no _jobs_req in scope every function answers rc 2.
#
# port_cursor_get <owner/name>
#   Prints the last upstream sha ported to the target, or NOTHING (rc 0) when
#   the worker says the target has no row. rc 2 on any answer that is not one of
#   those two: an outage, an unset JOBS_URL, a body without upstream_sha. An
#   unreadable cursor is never "no cursor" — that would re-port everything.
#
# port_cursor_put <owner/name> <sha> <prev-sha|-> <pr_url>
#   Compare-and-set: moves the cursor to <sha> only while it still holds <prev>
#   (`-` = the target has no row yet). rc 0 moved, rc 1 lost (409; the stored
#   row goes to stderr), rc 2 anything else.

port_cursor_get() {
  local target="${1:-}" q resp out
  [ -n "$target" ] || return 2
  declare -F _jobs_req >/dev/null || return 2
  q=$(jq -rn --arg t "$target" '$t | @uri') || return 2
  resp=$(_jobs_req GET "/api/port/cursor?target=$q") || return 2
  out=$(printf '%s' "$resp" | jq -er 'if type == "object" and has("upstream_sha") then
      (if .upstream_sha == null then ""
       elif (.upstream_sha | type) == "string" and (.upstream_sha | test("^[0-9a-f]{40}$"))
       then .upstream_sha else error("unusable") end)
    else error("unusable") end' 2>/dev/null) || return 2
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

port_cursor_put() {
  local target="${1:-}" sha="${2:-}" prev="${3:-}" url="${4:-}" body resp rc
  [ -n "$target" ] && [ -n "$sha" ] && [ -n "$prev" ] || return 2
  declare -F _jobs_req >/dev/null || return 2
  body=$(jq -nc --arg t "$target" --arg s "$sha" --arg p "$prev" --arg u "$url" \
    '{target:$t, sha:$s, prev:(if $p == "-" then null else $p end),
      pr_url:(if $u == "" then null else $u end)}') || return 2
  resp=$(_jobs_req PUT /api/port/cursor "$body"); rc=$?
  case "$rc" in
    0) return 0 ;;
    9) printf 'port_cursor_put: cursor moved; stored row: %s\n' "$resp" >&2; return 1 ;;
    *) return 2 ;;
  esac
}
