#!/bin/bash
# bin/lib/preplan-hitrate.sh — the pre-plan hit rate, read from the answer of
# GET /api/preplans/adoption (BH-3437). Sourced by bin/pipeline-health.sh.
# Pure: no network, no files, no harness root.
#
# HIT RATE is adopted / (adopted + stale + miss). OFF is left out: a build that
# was told not to look for a pre-plan did not miss one. It is NOT the route's
# `rate` (adopted / bought), which the cadence cut reads and which says nothing
# about builds that found no pre-plan at all. That blind spot is why
# cromford sat at 0 adopted / 76 miss for a week with nothing saying so.
#
# preplan_hitrate_eval <adoption-json> <min-builds>
#   stdout:
#     LOG <p> <adopted>/<builds> hit (<pct>%) miss <m>  [two spaces]  <p> ...
#         one line, every project in the answer. A project with no builds
#         reads `<p> — no builds`, never 0%.
#     ZERO <p> <builds>
#         one per project with builds >= min-builds and no hit. min-builds 0
#         means off: nothing is ever printed.
#   rc 0 on a parsed answer (an empty projects list prints nothing). rc 1 when
#   the answer is not the adoption shape or a count is not a number: that is
#   unknown, never zero, and the caller fires nothing on it.
preplan_hitrate_eval() {
  local j="${1:-}" min="${2:-}"
  case "$min" in ''|*[!0-9]*) return 1 ;; esac
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$j" | jq -r --argjson min "$min" '
    if type == "object" and (.projects | type) == "array" then . else error("not an adoption answer") end
    | [ .projects[]
        | if (.project | type) == "string" and (.adopted | type) == "number"
             and (.stale | type) == "number" and (.miss | type) == "number"
          then {p: .project, a: .adopted, m: .miss, b: (.adopted + .stale + .miss)}
          else error("bad project row") end ] as $r
    | (if ($r | length) > 0 then
         "LOG " + ([ $r[] | if .b > 0 then "\(.p) \(.a)/\(.b) hit (\(100 * .a / .b | floor)%) miss \(.m)"
                           else "\(.p) — no builds" end ] | join("  "))
       else empty end),
      ($r[] | select($min > 0 and .b >= $min and .a == 0) | "ZERO \(.p) \(.b)")
  ' 2>/dev/null || return 1
}
