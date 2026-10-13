#!/bin/bash
# bin/lib/daily-digest-summary.sh — BH-3707 (BH-3688.4): the optional LLM
# paragraph of the daily digest. Sourced by bin/daily-digest.sh.
#
#   dd_summary <json-file> <out-file>
#
# The signature is frozen by the contract (BH-3703): rc 0 means the paragraph
# is in <out-file>; anything else means no paragraph and nothing written. Fewer
# than 2 args is rc 2. The digest sends with or without it.
#
# Off unless DAILY_DIGEST_LLM_SUMMARY=1. DAILY_DIGEST_LLM_MAX_USD caps the call
# (0 is off). Both knobs are registered in catalog/lanes.d/daily-digest.json.
#
# DEDUP BEFORE SPEND. The key is fp = sha256 of the digest JSON without its
# volatile as_of, and the jobs ledger row daily_digest_summary/<fp> is read
# BEFORE anything billable:
#   ok             -> the stored text is reused, no call;
#   empty, billed-failed or any other status -> terminal, no call;
#   no row (rc 2)  -> call;
#   unreadable     -> no call (fail closed).
# The model is model_routes stage.daily-digest (lane_role_model; rc 75 = no
# route, no call), and only the claude runner is taken. agent-call rc 74-79
# billed nothing, so it writes no row and the next tick retries. Any other
# non-zero is billed-failed. The answer loses its em and en dashes, collapses
# to one paragraph and is cut at 600 characters; one that cleans to empty is
# `empty`. Both are terminal. A call that succeeded but whose ok row could not
# be written still hands back its text: it was paid for, and the lane's day
# stamp stops a second send.

dd_summary() {
  if [ "$#" -lt 2 ]; then
    echo "usage: dd_summary <json-file> <out-file>" >&2
    return 2
  fi
  local json=$1 out=$2 on="${DAILY_DIGEST_LLM_SUMMARY:-0}" cap="${DAILY_DIGEST_LLM_MAX_USD:-0.10}"
  local root fp row lrc status model runner pf raw text rc
  [ "$on" = 1 ] || return 1
  [[ $cap =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ $cap =~ [1-9] ]] || return 1
  jq -e 'type == "object"' "$json" >/dev/null 2>&1 || return 1
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || return 1
  fp=$(jq -S -c 'del(.as_of)' "$json" | sha256sum | cut -c1-64)
  [[ $fp =~ ^[0-9a-f]{64}$ ]] || return 1

  # The ledger, before anything billable.
  declare -F job_ledger_row >/dev/null && declare -F job_ledger_put >/dev/null || return 1
  row=$(job_ledger_row daily_digest_summary "$fp"); lrc=$?
  case "$lrc" in
    0)
      status=$(jq -r '.status // ""' <<<"$row" 2>/dev/null)
      [ "$status" = ok ] || return 1
      text=$(jq -r '.detail | fromjson | .text // "" | strings' <<<"$row" 2>/dev/null) || return 1
      [ -n "$text" ] || return 1
      printf '%s\n' "$text" > "$out"
      return 0 ;;
    2) ;;
    *) return 1 ;;
  esac

  # The route.
  if ! declare -F lane_role_model >/dev/null; then
    # shellcheck source=lane-model.sh
    . "$root/bin/lib/lane-model.sh" 2>/dev/null || return 1
  fi
  model=$(lane_role_model stage.daily-digest) || return 1
  [ -n "$model" ] || return 1
  runner=$(lane_model_ladder stage.daily-digest | awk -F'\t' 'NR==1{print $3}')
  if [ "$runner" != claude ]; then
    echo "dd_summary: stage.daily-digest routes to runner ${runner:-<none>}, not claude; no paragraph" >&2
    return 1
  fi

  [ -r "$root/catalog/prompts/daily-digest-summary.md" ] || return 1
  pf=$(mktemp -t dd-summary-prompt.XXXXXX) || return 1
  raw=$(mktemp -t dd-summary-answer.XXXXXX) || { rm -f "$pf"; return 1; }
  { cat "$root/catalog/prompts/daily-digest-summary.md"
    printf '\n## Digest JSON\n'
    jq -c 'del(.as_of)' "$json"; } > "$pf"

  AGENT_CALL_LANE=daily-digest AGENT_CALL_FP="$fp" AGENT_CALL_BUDGET_USD_DAILY_DIGEST="$cap" AGENT_CALL_RUNNERS="$runner" "$root/bin/agent-call.sh" daily-digest fleet "$model" 300 "$raw" "@$pf" >/dev/null
  rc=$?
  if [ "$rc" != 0 ]; then
    rm -f "$pf" "$raw"
    if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then return 1; fi
    job_ledger_put daily_digest_summary "$fp" billed-failed "{\"rc\":$rc}" \
      || echo "dd_summary: ledger put billed-failed for $fp failed" >&2
    return 1
  fi
  text=$(jq -Rsr 'gsub("\\s*[—–]\\s*"; ", ") | gsub("\\s+"; " ") | sub("^[, ]+"; "") | sub("[, ]+$"; "") | .[0:600]' "$raw" 2>/dev/null)
  rm -f "$pf" "$raw"
  if [ -z "$text" ]; then
    job_ledger_put daily_digest_summary "$fp" empty \
      || echo "dd_summary: ledger put empty for $fp failed" >&2
    return 1
  fi
  job_ledger_put daily_digest_summary "$fp" ok "$(jq -nc --arg t "$text" '{text: $t}')" \
    || echo "dd_summary: ledger put ok for $fp failed; the text is used once" >&2
  printf '%s\n' "$text" > "$out"
  return 0
}
