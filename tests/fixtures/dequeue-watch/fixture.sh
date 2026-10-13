#!/bin/bash
# shellcheck shell=bash
# tests/fixtures/dequeue-watch/fixture.sh — BH-3730 (BH-3719.4): the sandbox
# seam tests/dequeue-watch.bh-3719-test.sh hands bin/dequeue-watch.sh through
# DEQUEUE_WATCH_FIXTURE. The lane sources it AFTER its libs, and only when
# HARNESS_TEST_SANDBOX=1, so every function here replaces the real one.
#
# Everything lives under $DQW_FIX_DIR, and every call appends ONE line to
# $DQW_FIX_DIR/requests.log, in call order, so a case can count calls and check
# their order across GitHub, the worker and the stubbed scripts:
#   REST GET <path>          gh_rest (answers $DQW_FIX_DIR/rest/<path with / ? & = as _>,
#                            rc 75 when that file is absent: unread, never empty)
#   JOBS <M> <path> <body>   _jobs_req, a file-backed fake of the routes the lane reaches
#   FN <name> <args>         mc_requeue_mergify (the conductor's Mergify write; its
#                            own call shape is pinned by tests/dequeue-watch-act.bh-3719-test.sh)
# The gh shim on PATH and the scripts under the scratch bin/ log there too.
#
# Switches (env): EVENTS_FAIL=1 (the events POST answers rc 1), CLAIM_FAIL=1,
# ROUNDS_FAIL=1 (the fix-round count read; ROUNDS_FAIL_PR=<n> for one PR only),
# VERDICTS_FAIL=1, GH_BUDGET_LOW=1.
# Files: $DQW_FIX_DIR/verdict (the standing word, absent = none), main-red
# (present = main is red).

: > "${DQW_FIX_DIR:?}/fixture-sourced"
_fx_log() { printf '%s\n' "$*" >> "$DQW_FIX_DIR/requests.log"; }
_fx_key() { printf '%s' "$1" | tr '/?&=' '____'; }

gh_rest() {
  local m="$1" p="$2" f
  _fx_log "REST $m $p"
  f="$DQW_FIX_DIR/rest/$(_fx_key "$p")"
  [ "$m" = GET ] && [ -r "$f" ] || { GH_REST_STATUS=500; return 75; }
  GH_REST_STATUS=200
  cat "$f"
}

gh_budget_low() { [ "${GH_BUDGET_LOW:-0}" = 1 ] && return 0; return 1; }
gh_auth_for() { return 0; }
mc_queue_provider() { printf 'mergify'; }
main_red_flag() { [ -e "$DQW_FIX_DIR/main-red" ] || return 1; printf 'main-red-%s' "$1"; }
jobs_configured() { return 0; }
lane_model() { printf 'model-under-test\n'; }
lane_model_ladder() { printf '0\tstub\tclaude\tmodel-under-test\n'; }
mc_requeue_mergify() { _fx_log "FN mc_requeue_mergify $*"; return 0; }

# _fx_q <query> <name> — one decoded query parameter.
_fx_q() {
  local kv v
  for kv in ${1//&/ }; do
    [ "${kv%%=*}" = "$2" ] && { v="${kv#*=}"; printf '%b' "${v//%/\\x}"; return 0; }
  done
}

_jobs_req() {
  local m="$1" path="$2" body="${3:-}" db="$DQW_FIX_DIR/db" route q f out
  JOBS_HTTP=""; JOBS_BODY=""
  _fx_log "JOBS $m $path $body"
  mkdir -p "$db/actions"; touch "$db/events.jsonl"
  route="${path%%\?*}"; q=""; [ "$route" = "$path" ] || q="${path#*\?}"
  case "$m $route" in
    "POST /api/dequeue-watch/events")
      [ "${EVENTS_FAIL:-0}" = 1 ] && { JOBS_HTTP=500; return 1; }
      # The real route answers the stored row (SELECT *), class included once
      # the lane classified it, so the fixture does too.
      f=$(jq -c --argjson b "$body" 'select(.repo == $b.repo and .pr == $b.pr and .head == $b.head and .run_id == $b.run_id)' \
           "$db/events.jsonl" | head -1)
      if [ -n "$f" ]; then
        out=$(jq -nc --argjson r "$f" '{recorded: true, first: false, row: $r}')
      else
        printf '%s\n' "$body" | jq -c . >> "$db/events.jsonl"
        out=$(printf '%s' "$body" | jq -c '{recorded: true, first: true, row: .}')
      fi ;;
    "PUT /api/dequeue-watch/events/state")
      jq -c --argjson b "$body" 'if .repo == $b.repo and .pr == $b.pr and .head == $b.head and .run_id == $b.run_id then . + $b else . end' \
        "$db/events.jsonl" > "$db/ev.tmp" && mv "$db/ev.tmp" "$db/events.jsonl"
      out='{"row":{}}' ;;
    "GET /api/dequeue-watch/events")
      out=$(jq -sc --arg r "$(_fx_q "$q" repo)" --arg pr "$(_fx_q "$q" pr)" --arg fp "$(_fx_q "$q" llm_fp)" \
        '{rows: map(select(.repo == $r and ($pr == "" or (.pr | tostring) == $pr) and ($fp == "" or .llm_fp == $fp))), truncated: false}' \
        "$db/events.jsonl") ;;
    "POST /api/dequeue-watch/actions/claim")
      [ "${CLAIM_FAIL:-0}" = 1 ] && { JOBS_HTTP=500; return 1; }
      f="$db/actions/$(printf '%s' "$body" | jq -r '"\(.repo)_\(.pr)_\(.head)_\(.class)"' | tr '/' '_')"
      if ( set -C; : > "$f" ) 2>/dev/null; then
        printf '%s' "$body" | jq -c '. + {status: "claimed"}' > "$f"
        out=$(jq -c '{claimed: true, row: .}' "$f")
      else
        out=$(jq -c '{claimed: false, row: .}' "$f")
      fi ;;
    "PUT /api/dequeue-watch/actions/state")
      f="$db/actions/$(printf '%s' "$body" | jq -r '"\(.repo)_\(.pr)_\(.head)_\(.class)"' | tr '/' '_')"
      [ -s "$f" ] || { JOBS_HTTP=404; return 2; }
      jq -c --argjson b "$body" '. + $b' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      out=$(jq -c '{row: .}' "$f") ;;
    "GET /api/dequeue-watch/actions")
      [ "${ROUNDS_FAIL:-0}" = 1 ] && [ "$(_fx_q "$q" action)" = fix-round ] && { JOBS_HTTP=500; return 1; }
      [ -n "${ROUNDS_FAIL_PR:-}" ] && [ "$(_fx_q "$q" action)" = fix-round ] && [ "$(_fx_q "$q" pr)" = "$ROUNDS_FAIL_PR" ] \
        && { JOBS_HTTP=500; return 1; }
      out=$(cat "$db/actions/"* 2>/dev/null | jq -sc --arg r "$(_fx_q "$q" repo)" --arg pr "$(_fx_q "$q" pr)" \
        --arg h "$(_fx_q "$q" head)" --arg c "$(_fx_q "$q" class)" --arg a "$(_fx_q "$q" action)" --arg s "$(_fx_q "$q" status)" \
        '{rows: map(select(.repo == $r and ($pr == "" or (.pr | tostring) == $pr) and ($h == "" or .head == $h)
                  and ($c == "" or .class == $c) and ($a == "" or .action == $a) and ($s == "" or .status == $s))),
          truncated: false}') ;;
    "POST /api/fix-rounds") out='{"job":{"id":"TK-1","status":"queued"}}' ;;
    "PUT /api/metrics/flakes") out='{"ok":true}' ;;
    "GET /api/verdicts")
      [ "${VERDICTS_FAIL:-0}" = 1 ] && { JOBS_HTTP=500; return 1; }
      if [ -s "$DQW_FIX_DIR/verdict" ]; then
        out=$(jq -nc --arg v "$(cat "$DQW_FIX_DIR/verdict")" \
          '{standing: {verdict: $v, source: "lead", id: 1, created_at: "2026-09-29T03:00:00Z"}}')
      else out='{"standing":null}'; fi ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=200; JOBS_BODY="$out"
  printf '%s\n' "$out"
}
