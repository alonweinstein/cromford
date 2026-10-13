#!/bin/bash
# bin/lib/advisor.sh — WHETHER a claude session gets `--advisor <model>` (BH-3491).
#
#   . bin/lib/advisor.sh
#   advisor_for_project <project>          -> "model=<v|> source=db|env|none", rc 0
#   advisor_for_call <stage> <project> <main-model>
#                                          -> the value to pass to --advisor, or nothing
#   advisor_launch_refused <out.json> <out.err>
#                                          -> rc 0 when the CLI refused the flag at
#                                             launch (no API turn ran), else rc 1
#   advisor_refused_flag <account> <value> -> the per-account/model/UTC-day flag path
#   ADVISOR_CONSULT_LINE                   -> the one instruction line the session gets
#
# The advisor is DATA: a settings row `advisor.<project>`, else `advisor.default`,
# read through lane-gate's settings fetch and its cache, the same way
# project-account.sh reads `account.<project>`. A stale cached row still counts
# as a settings answer. Only when this box has no settings answer at all does env
# AGENT_ADVISOR_MODEL apply. Nothing configured = no advisor. The value `off` is
# the explicit unset (the worker refuses an empty value).
#
# The stages come from AGENT_ADVISOR_STAGES (registry knob, lib `advisor`,
# default "execute fix"; `none` = off). When nothing exported it (a box without
# the registry, LANE_GATE_DISABLE=1) the list is empty and the advisor stays off.

_adv_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v _lg_setting_lookup >/dev/null 2>&1 && [ -r "$_adv_dir/lane-gate.sh" ]; then
  . "$_adv_dir/lane-gate.sh" >/dev/null 2>&1 || true
fi

# shellcheck disable=SC2034 # read by bin/agent-call.sh
ADVISOR_CONSULT_LINE='Consult the advisor before committing to an approach that deviates from plan.md, when the same error repeats twice, and before you write the final summary.'

# The values the CLI documents for --advisor: an alias or a full claude id.
_adv_value_ok() {
  case "${1:-}" in
    fable|opus|sonnet) return 0 ;;
    claude-*) case "$1" in *[!a-z0-9.-]*) return 1 ;; esac; return 0 ;;
  esac
  return 1
}

advisor_for_project() {
  local p="${1:-}" v="" src=none state=none
  case "$p" in ''|*[!A-Za-z0-9._-]*) printf 'model= source=none\n'; return 0 ;; esac
  if command -v _lg_setting_lookup >/dev/null 2>&1; then
    _lg_settings_refresh >/dev/null 2>&1 || true
    state=$(_lg_settings_state 2>/dev/null || printf none)
    if [ "$state" != none ]; then
      v=$(_lg_setting_lookup "advisor.$p" 2>/dev/null) || v=$(_lg_setting_lookup advisor.default 2>/dev/null) || v=""
      src=db
    fi
  fi
  if [ "$state" = none ]; then
    v="${AGENT_ADVISOR_MODEL:-}"; src="env"
  fi
  if [ "$v" = off ]; then
    v=""
  elif [ -n "$v" ] && ! _adv_value_ok "$v"; then
    printf 'advisor: refused value for %s (%s): not fable|opus|sonnet|claude-<id>\n' "$p" "$src" >&2
    v=""
  fi
  [ -n "$v" ] || src=none
  printf 'model=%s source=%s\n' "$v" "$src"
}

advisor_refused_flag() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 1
  printf '%s/flags/advisor-refused-%s-%s-%s' "$h" "${1:-default}" "${2:-}" "$(date -u +%Y%m%d)"
}

advisor_for_call() {
  local st="${1:-}" p="${2:-}" main="${3:-}" v f
  [ -n "$st" ] || return 0
  case " $(printf '%s' "${AGENT_ADVISOR_STAGES:-}" | tr ',' ' ') " in
    *" none "*) return 0 ;;
    *" $st "*) ;;
    *) return 0 ;;
  esac
  v=$(advisor_for_project "$p" 2>/dev/null); v="${v#model=}"; v="${v%% *}"
  [ -n "$v" ] || return 0
  # Pairing precheck (code.claude.com/docs/en/advisor): a Fable main accepts only
  # a Fable advisor; an Opus/Sonnet/Haiku main takes any of them. Anything else is
  # not a claude main we know pairs, so nothing is passed.
  case "$main" in
    claude-fable-*) case "$v" in fable|claude-fable-*) ;; *) return 0 ;; esac ;;
    claude-opus-*|claude-sonnet-*|claude-haiku-*) ;;
    *) return 0 ;;
  esac
  # Refused on this account today already: do not launch into the same refusal.
  f=$(advisor_refused_flag "${ACCT_NAME:-default}" "$v") && [ -f "$f" ] && return 0
  printf '%s' "$v"
}

# A refusal is the CLI stopping BEFORE any API turn: no JSON at all, or an
# envelope with zero tokens and at most one (empty) turn — 2.1.284 reports
# num_turns 1 for a launch failure (see the BH-3491 build's advisor-shape.txt).
# And the text must name the advisor: stderr, or an is_error envelope's .result.
# A session that ran and failed is never read as a refusal, whatever it says.
advisor_launch_refused() {
  local j="${1:-}" e="${2:-}"
  if [ -s "$j" ] && jq -e . "$j" >/dev/null 2>&1; then
    jq -e '((.usage.input_tokens // 0) == 0) and ((.usage.output_tokens // 0) == 0)
           and ((.num_turns // 0) <= 1)' "$j" >/dev/null 2>&1 || return 1
    jq -e '.is_error == true and ((.result // "") | test("advisor"; "i"))' "$j" >/dev/null 2>&1 && return 0
  fi
  grep -qi 'advisor' "$e" 2>/dev/null
}
