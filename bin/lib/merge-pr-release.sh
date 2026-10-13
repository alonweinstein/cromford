#!/bin/bash
# shellcheck shell=bash
# bin/lib/merge-pr-release.sh — free a merge_pr command key after a "head moved"
# refusal, whatever entry point sent the command (BH-4917).
#
# WHY: the console worker (example-org/cromford-console) keys a merge_pr
# command on <project>:<ticket>:merge_pr and hands an existing row under that
# key back to every later request. A "refused: head moved since sha <8>" ack is
# terminal (BH-932), so the key stuck on the old head. #4439 renamed the row off
# the key, but only in the Pages proxy and only when the request carried a
# verdict_sha; a merge_pr from the MCP tool, Telegram or a box command never
# goes through there, and project-3 #467 needed a new ticket key to merge.
# WHAT: mpr_release_head_moved <command-id> <log> asks the console's own Pages
# endpoint, POST <console_pages_url>/api/merge-pr/release {id}, to rename that
# ONE row the way #4439 does (ckey || ':refused:' || id). The write happens
# inside the console through its CONSOLE_DB binding
# (console-ui/functions/api/merge-pr/release.js), authed with HARNESS_SECRET,
# so the hub keeps no D1 access (BH-3905). The endpoint's guarded UPDATE
# re-checks type, terminal status and the result prefix, so a row the console
# does not hold as a terminal head-moved refusal is never touched, and a replay
# changes nothing. The row is kept.
# RETURNS: 0 released (released >= 1); 1 no-match (the call worked, 0 rows:
# Pages already renamed it, or the ack did not land as refused); 2 bad id (no
# call); 3 not-configured (no harness root, console-pages lib or HARNESS_SECRET:
# no call, no ALERT); 4 failed (unreachable, HTTP non-2xx, an unreadable body:
# one ALERT line, never counted as released). One line per call to <log>.
# The secret is handed to curl on stdin, never argv.
# Side-effect-free when sourced, safe under the caller's `set -u`.

_mpr_log() { # _mpr_log <log> <id> <outcome>
  [ -n "$1" ] || return 0
  printf '%s merge_pr %s key release: %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$2" "$3" >> "$1" 2>/dev/null
  return 0
}

mpr_release_head_moved() {
  local id="${1:-}" log="${2:-}" root="${HARNESS:-${H:-}}" url work code why released
  case "$id" in ''|*[!0-9]*) return 2 ;; esac
  if [ -z "$root" ]; then _mpr_log "$log" "$id" "not-configured (no harness root)"; return 3; fi
  command -v console_pages_url >/dev/null 2>&1 || . "$root/bin/lib/console-pages.sh" 2>/dev/null
  if ! command -v console_pages_url >/dev/null 2>&1; then
    _mpr_log "$log" "$id" "not-configured (console-pages lib missing)"; return 3
  fi
  if [ -z "${HARNESS_SECRET:-}" ]; then _mpr_log "$log" "$id" "not-configured (no HARNESS_SECRET)"; return 3; fi
  url="$(console_pages_url)/api/merge-pr/release"
  work=$(mktemp -d "${TMPDIR:-/tmp}/mpr.XXXXXX") || { _mpr_log "$log" "$id" "failed (no temp dir)"; return 4; }
  jq -nc --argjson id "$id" '{id:$id}' > "$work/q.json"
  code=$(printf 'Authorization: Bearer %s\n' "$HARNESS_SECRET" \
    | curl -sS --max-time 15 -X POST -H @- -H 'Content-Type: application/json' \
        --data-binary "@$work/q.json" -o "$work/r.json" -w '%{http_code}' "$url" 2>/dev/null) || code="${code:-000}"
  [ -n "$code" ] || code=000
  why=""; released=""
  case "$code" in
    2??)
      if jq -e '.released | type == "number"' "$work/r.json" >/dev/null 2>&1; then
        released=$(jq -r '.released' "$work/r.json")
      else why="the answer carried no count"; fi ;;
    *) why=$(jq -r '.error // empty' "$work/r.json" 2>/dev/null | head -c 200) ;;
  esac
  rm -rf "$work"
  if [ -n "$released" ]; then
    if [ "$released" -ge 1 ] 2>/dev/null; then _mpr_log "$log" "$id" released; return 0; fi
    _mpr_log "$log" "$id" no-match; return 1
  fi
  _mpr_log "$log" "$id" "failed (HTTP $code${why:+, $why})"
  case "$code" in
    000) why="the console at $url is unreachable" ;;
    401|403) why="the console Pages project refused the hub's HARNESS_SECRET at $url (set HARNESS_SECRET there to the hub's env/global.env value)" ;;
    404) why="$url answered 404 (console-ui is not deployed with BH-4917 yet)" ;;
    *) why="$url answered HTTP $code${why:+ ($why)}" ;;
  esac
  HARNESS="$root" "$root/bin/alert-line.sh" --severity warn --id merge-pr-release \
    "[poll-commands] merge_pr $id keeps its key after a head-moved refusal: $why" >/dev/null 2>&1 || true
  return 4
}
