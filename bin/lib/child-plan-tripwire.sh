#!/bin/bash
# bin/lib/child-plan-tripwire.sh — the child plan cost tripwire (BH-3478.4).
# Sourced, never run; sourcing only defines functions and captures this file's
# own directory. Called by the `# >>> child plan tripwire (BH-3478)` block of
# bin/lib/rb/plan.sh, which keeps the FIRST stdout line, drops stderr and logs
# `CHILD_PLAN_TRIPWIRE <verdict>` to $BUILD/pipeline.log.
#
# A split child is handed its parent planner's context pack
# (bin/lib/context-pack.sh) so it does not re-survey the codebase. This checks
# whether that worked: the child's plan spend against the parent's.
#
#   cpt_check <project> <child> <parent>        rc 0 always, one stdout line:
#     FIRE <child_usd> <parent_usd> <pct> <thr>  child*100 > thr*parent (strict)
#     OK   <child_usd> <parent_usd> <pct> <thr>
#     OFF                                        the knob is 0
#     UNMEASURED <why>                           bad arguments, no jobs client,
#                                                knob unreadable or invalid, a
#                                                read failed / unparseable /
#                                                truncated, no parent baseline
#   usd = the sum of cost_rows.cost_usd over stages `preplan` and `plan` for the
#   ticket KEY in <project> (ticket keys are per-board). One read per ticket and
#   stage, limit=2000; a full page is UNMEASURED, never summed (D12), and a
#   failed read is UNMEASURED, never $0 (D11). Null costs are skipped; rows of
#   any other stage are dropped even if the worker ignored `stage=`.
#   Known gaps: `<stage>-advisor` rows (BH-3491) are not summed, and a child's
#   own plan row may not have reached the worker yet; both err toward OK.
#
# Threshold: settings row `child_plan_tripwire_pct`; no row -> 50 (the
# documented fallback), outage -> UNMEASURED, a value that is not a
# non-negative number -> UNMEASURED plus one line in logs/child-plan-tripwire.log
# (never clamped), 0 -> OFF.
#
# On FIRE: ledger child_plan_tripwire "<project> <child>" = fired dedupes the
# page. Read first (fired -> nothing more; no row or an outage -> go on: a
# duplicate alert beats a silent one), then ONE warn line through
# bin/alert-line.sh, then the ledger PUT. No alert-line.sh (or no root) means
# no alert and no PUT, so the next build tries again. It never blocks the build
# and never writes a RESULT: "pause and diagnose" is an alert.
#
# Root is ${HARNESS:-${H:-}} only (D43); empty root and no client beside this
# file means UNMEASURED no jobs client.

_CPT_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# Same loader as _cp_ensure_client (bin/lib/context-pack.sh).
_cpt_ensure_client() {
  local c pf nu root="${HARNESS:-${H:-}}"
  _cpt_have_client && return 0
  for c in "${_CPT_SELF_DIR:+$_CPT_SELF_DIR/../jobs-client.sh}" "${root:+$root/bin/jobs-client.sh}"; do
    [ -n "$c" ] && [ -r "$c" ] && [ -r "$(dirname "$c")/lib/jobs/req.sh" ] || continue
    pf=$(set -o | awk '$1=="pipefail"{print $2}')
    nu=$(set -o | awk '$1=="nounset"{print $2}')
    # shellcheck source=/dev/null
    . "$c" >/dev/null 2>&1
    [ "$pf" = off ] && set +o pipefail
    [ "$nu" = off ] && set +u
    _cpt_have_client && return 0
  done
  return 1
}
_cpt_have_client() {
  local f
  for f in _jobs_req setting_get job_ledger_get job_ledger_put; do
    command -v "$f" >/dev/null 2>&1 || return 1
  done
}

# _cpt_sum <project> <ticket> <stage> — prints the sum, or the reason on rc 1.
_cpt_sum() {
  local p="$1" t="$2" s="$3" resp n
  resp=$(_jobs_req GET "/api/metrics/cost-rows?project=$(jq -rn --arg v "$p" '$v|@uri')&ticket=$(jq -rn --arg v "$t" '$v|@uri')&stage=$(jq -rn --arg v "$s" '$v|@uri')&limit=2000" 2>/dev/null) \
    || { echo "read failed"; return 1; }
  n=$(printf '%s' "$resp" | jq -er '.cost_rows | if type == "array" then length else error end' 2>/dev/null) \
    || { echo unparseable; return 1; }
  [ "$n" -ge 2000 ] && { echo "truncated (2000-row page)"; return 1; }
  printf '%s' "$resp" | jq -r --arg s "$s" '[.cost_rows[] | select(type == "object" and .stage == $s) | .cost_usd
    | if type == "number" then . elif type == "string" then (tonumber? // empty) else empty end] | add // 0' 2>/dev/null \
    || { echo unparseable; return 1; }
}

cpt_check() {
  local p="${1:-}" c="${2:-}" pa="${3:-}" root="${HARNESS:-${H:-}}" thr rc t s v line text
  local cp cl pp pl
  case "$p$c$pa" in *[!A-Za-z0-9._-]*) echo "UNMEASURED bad arguments"; return 0 ;; esac
  [ -n "$p" ] && [ -n "$c" ] && [ -n "$pa" ] && [ "$c" != "$pa" ] || { echo "UNMEASURED bad arguments"; return 0; }
  _cpt_ensure_client || { echo "UNMEASURED no jobs client"; return 0; }

  thr=$(setting_get child_plan_tripwire_pct 2>/dev/null); rc=$?
  case "$rc" in
    0) ;;
    2) thr=50 ;;
    *) echo "UNMEASURED knob unreadable"; return 0 ;;
  esac
  if ! [[ "$thr" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "UNMEASURED invalid knob child_plan_tripwire_pct=$thr"
    [ -n "$root" ] && mkdir -p "$root/logs" 2>/dev/null \
      && printf '%s [%s/%s] child_plan_tripwire_pct=%s is not a non-negative number; tripwire unmeasured (D11, no clamp)\n' \
           "$(date -u '+%F %TZ')" "$p" "$c" "$thr" >> "$root/logs/child-plan-tripwire.log" 2>/dev/null
    return 0
  fi
  [ "$(jq -rn --arg t "$thr" '$t | tonumber == 0')" = true ] && { echo OFF; return 0; }

  for t in "$c" "$pa"; do
    for s in preplan plan; do
      v=$(_cpt_sum "$p" "$t" "$s") || { echo "UNMEASURED $t $s $v"; return 0; }
      case "$t.$s" in
        "$c.preplan") cp=$v ;; "$c.plan") cl=$v ;; "$pa.preplan") pp=$v ;; *) pl=$v ;;
      esac
    done
  done

  # One jq does the arithmetic (no bash integer math): the verdict word, both
  # sums, the percentage; printf does the rounding.
  line=$(jq -rn --argjson cp "$cp" --argjson cl "$cl" --argjson pp "$pp" --argjson pl "$pl" --arg t "$thr" '
    ($cp + $cl) as $c | ($pp + $pl) as $p | ($t | tonumber) as $thr
    | if $p <= 0 then "NOBASE"
      else [(if $c * 100 > $thr * $p then "FIRE" else "OK" end), $c, $p, ($c / $p * 100)] | map(tostring) | join(" ") end' 2>/dev/null) \
    || { echo "UNMEASURED sum failed"; return 0; }
  [ "$line" = NOBASE ] && { echo "UNMEASURED no parent baseline"; return 0; }
  set -- $line
  line=$(LC_ALL=C printf '%s %.2f %.2f %.1f %s' "$1" "$2" "$3" "$4" "$thr")
  echo "$line"
  [ "$1" = FIRE ] || return 0

  [ "$(job_ledger_get child_plan_tripwire "$p $c" 2>/dev/null)" = fired ] && return 0
  [ -n "$root" ] && [ -x "$root/bin/alert-line.sh" ] || return 0
  set -- $line
  # shellcheck disable=SC2016  # the variable NAMES are the text; never their values
  text="[child-plan-tripwire] $p/$c: plan spend \$$2 is $4% of parent $pa's \$$3 (threshold $5%). The context pack did not save the re-survey. Diagnose: curl -s -H \"Authorization: Bearer \$HARNESS_SECRET\" \"\$JOBS_URL/api/metrics/cost-rows?ticket=$c\""
  "$root/bin/alert-line.sh" --severity warn --id "child-plan-tripwire:$p:$c" --project "$p" "$text" >/dev/null 2>&1
  JOBS_BOX="${JOBS_BOX:-}" job_ledger_put child_plan_tripwire "$p $c" fired "$2 $3 $4 $5 parent=$pa" >/dev/null 2>&1
  return 0
}
