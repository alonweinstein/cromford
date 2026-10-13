#!/bin/bash
# shellcheck shell=bash
# bin/lib/dequeue-watch/llm.sh — BH-3729 (slice 4 of BH-3719): the LLM fallback
# for a dequeue the rules leave unclassified. Sourced by the lane
# (bin/dequeue-watch.sh, a sibling slice), never run; nothing here runs on source.
#
#   dqw_llm_classify <P> <repo> <pr> <head> <run_id> <suites> <fail-lines-file>
#     Prints one class (rule-break | scanner-fp | semantic-test |
#     textual-conflict | flake | unclassified) or nothing. rc 0 always, except
#     bad input (rc 1: no root, an unreadable FAIL-lines file).
#
# DEDUP BEFORE SPEND. The key is fp = sha1("<repo>|<suites>|<normalized FAIL
# lines>"), the lines with hex (7+) and digit runs folded to N, trimmed and
# sort -u'd, so a re-run of the same failure on a new sha is the same fp.
#   1. dqw_events_list <repo> "" "" <fp>: unreadable -> no call. A row with
#      llm_class -> that answer (`none` prints nothing), no call. A row with
#      llm_attempted_at and no llm_class -> terminal, no call.
#   2. the model comes from the dequeue.classify route (lane_model), the runner
#      from its rung 0, pinned through AGENT_CALL_RUNNERS. No route -> no call.
#   3. llm_fp + llm_attempted_at are stamped on the event BEFORE the call; a
#      failed stamp -> no call.
#   4. one bin/agent-call.sh call, budget DEQUEUE_WATCH_LLM_USD (default 0.05).
#   5. the first answer line, trimmed, must be exactly one class word. Anything
#      else, a failed call included, is recorded as llm_class=none: billed and
#      terminal, never asked again for that fp.
#
# NO ROOT DEFAULT (D43): the root is $HARNESS, then $H; with neither it returns
# 1 and builds no path.

_dqw_llm_log() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') llm: $*" >> "$h/logs/dequeue-watch.log" 2>/dev/null || true
}

dqw_llm_classify() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 1
  [ "$#" -eq 7 ] || { _dqw_llm_log "usage: dqw_llm_classify <P> <repo> <pr> <head> <run_id> <suites> <fail-lines-file> (got $# args)"; return 1; }
  local P="$1" repo="$2" pr="$3" head="$4" run_id="$5" suites="$6" fl="$7"
  [ -r "$fl" ] || { _dqw_llm_log "$repo#$pr FAIL-lines file $fl unreadable"; return 1; }
  local norm fp ev rows cls model runner sop prompt out rc ans stamp

  norm=$(sed -E 's/[0-9a-fA-F]{7,}/N/g; s/[0-9]+/N/g; s/^[[:space:]]+//; s/[[:space:]]+$//' "$fl" | grep -v '^$' | sort -u)
  fp=$(printf '%s|%s|%s' "$repo" "$suites" "$norm" | sha1sum | cut -c1-40)

  if ! ev=$(dqw_events_list "$repo" "" "" "$fp" 2>/dev/null) \
     || ! rows=$(printf '%s' "$ev" | jq -ce --arg fp "$fp" '.rows | if type == "array" then map(select((.llm_fp // $fp) == $fp)) else error("x") end' 2>/dev/null); then
    _dqw_llm_log "$repo#$pr ${head:0:12} fp $fp llm-ledger-unreadable, no call"
    return 0
  fi
  cls=$(printf '%s' "$rows" | jq -r 'map(select((.llm_class // "") != "")) | .[0].llm_class // ""')
  if [ -n "$cls" ]; then
    _dqw_llm_log "$repo#$pr ${head:0:12} fp $fp already answered '$cls', no call"
    [ "$cls" = none ] || printf '%s\n' "$cls"
    return 0
  fi
  if [ "$(printf '%s' "$rows" | jq 'map(select((.llm_attempted_at // "") != "")) | length')" -gt 0 ]; then
    _dqw_llm_log "$repo#$pr ${head:0:12} fp $fp llm-attempted-no-answer, terminal, no call"
    return 0
  fi

  if ! declare -F lane_model >/dev/null || ! declare -F lane_model_ladder >/dev/null; then
    # shellcheck source=../lane-model.sh
    . "$h/bin/lib/lane-model.sh" 2>/dev/null || { _dqw_llm_log "$repo#$pr no-route: bin/lib/lane-model.sh could not be loaded, no call"; return 0; }
  fi
  model=$(lane_model DEQUEUE_WATCH_MODEL dequeue.classify 2>/dev/null) && [ -n "$model" ] \
    && runner=$(lane_model_ladder dequeue.classify 2>/dev/null | awk -F'\t' 'NR==1{print $3}') && [ -n "$runner" ] \
    || { _dqw_llm_log "$repo#$pr no-route for role dequeue.classify, no call"; return 0; }

  sop="$h/catalog/prompts/dequeue-classify.md"
  [ -r "$sop" ] || { _dqw_llm_log "$repo#$pr prompt $sop unreadable, no call"; return 0; }

  stamp=$(jq -nc --arg fp "$fp" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '{llm_fp: $fp, llm_attempted_at: $at}')
  dqw_event_state "$repo" "$pr" "$head" "$run_id" "$stamp" >/dev/null 2>&1 \
    || { _dqw_llm_log "$repo#$pr ${head:0:12} fp $fp attempt stamp failed, no call"; return 0; }

  prompt="$(cat "$sop")

## Failing suites
$suites

## FAIL lines
$(head -40 "$fl")"
  out=$(mktemp) || { _dqw_llm_log "$repo#$pr mktemp failed after the stamp, recorded as none"; out=""; }
  rc=1
  if [ -n "$out" ]; then
    AGENT_CALL_BUDGET_USD="${DEQUEUE_WATCH_LLM_USD:-0.05}" AGENT_CALL_RUNNERS="$runner" AGENT_CALL_LANE=dequeue-watch "$h/bin/agent-call.sh" dequeue-classify "$P" "$model" 120 "$out" "$prompt" >/dev/null 2>&1
    rc=$?
    ans=$(head -1 "$out" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    rm -f "$out"
  fi
  if [ "$rc" != 0 ] || ! [[ "${ans:-}" =~ ^(rule-break|scanner-fp|semantic-test|textual-conflict|flake|unclassified)$ ]]; then
    _dqw_llm_log "$repo#$pr ${head:0:12} fp $fp call rc $rc answered '$(printf '%s' "${ans:-}" | cut -c1-60)', recorded as none"
    ans=none
  fi
  dqw_event_state "$repo" "$pr" "$head" "$run_id" "$(jq -nc --arg c "$ans" '{llm_class: $c}')" >/dev/null 2>&1 \
    || _dqw_llm_log "$repo#$pr ${head:0:12} fp $fp llm_class=$ans could not be recorded"
  [ "$ans" = none ] || printf '%s\n' "$ans"
  return 0
}
