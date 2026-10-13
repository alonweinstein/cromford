#!/bin/bash
# shellcheck shell=bash
# bin/lib/utilization-quiet.sh — BH-4012 (BH-3988.4): the went-quiet predicate
# behind bin/utilization-quiet.sh. Pure: one jq program, no clock, no network,
# no harness root. Sourced, never run.
#
# util_quiet <rows-json-array> <merges_prior_week> <min_rows>
#   <rows> is GET /api/utilization?project=&since= `.rows` for ONE project.
#   Prints one line `<result>\t<why>` and always returns 0:
#     unmeasured  min_rows or merges not a non-negative integer, rows not a
#                 JSON array, or fewer rows than min_rows (never fewer than 1).
#                 The caller must not read this as quiet OR as not-quiet.
#     quiet       EVERY row has tickets.ready exactly 0, builds.free_slots a
#                 number > 0 or "unlimited", and a verdict other than paused
#                 or unknown; AND merges_prior_week > 0.
#     not-quiet   anything else; the why is the first of: `0 merges prior
#                 week`, `ready>0 at <hour>`, `verdict <v> at <hour>`,
#                 `free_slots <v> at <hour>`, `ready unmeasured at <hour>`,
#                 each naming the LATEST row that fails that test.
#   A null or missing ready is unmeasured, never 0 (D11): such a row is not
#   starved, so the window is not quiet.

util_quiet() {
  local rows="${1-}" merges="${2-}" min="${3-}" out
  if ! [[ "$min" =~ ^[0-9]+$ ]]; then printf 'unmeasured\tmin_rows not an integer\n'; return 0; fi
  if ! [[ "$merges" =~ ^[0-9]+$ ]]; then printf 'unmeasured\tmerges unreadable\n'; return 0; fi
  out=$(printf '%s' "$rows" | jq -r --arg m "$merges" --arg min "$min" '
    def g(f): try f catch null;
    def hr: (g(.hour) // "?") | tostring;
    def ready: g(.payload.tickets.ready);
    def free: g(.payload.builds.free_slots);
    def latest(f): [.[] | select(f)] | last;
    ($m | tonumber) as $m | ([($min | tonumber), 1] | max) as $min |
    if type != "array" then "unmeasured\trows unparseable"
    elif length < $min then "unmeasured\t\(length) rows < \($min)"
    elif $m == 0 then "not-quiet\t0 merges prior week"
    elif latest((ready | type) == "number" and ready > 0) != null
      then latest((ready | type) == "number" and ready > 0) | "not-quiet\tready>0 at \(hr)"
    elif latest(g(.verdict) as $v | $v == "paused" or $v == "unknown") != null
      then latest(g(.verdict) as $v | $v == "paused" or $v == "unknown") | "not-quiet\tverdict \(.verdict) at \(hr)"
    elif latest(free as $f | ((($f | type) == "number" and $f > 0) or $f == "unlimited") | not) != null
      then latest(free as $f | ((($f | type) == "number" and $f > 0) or $f == "unlimited") | not)
        | "not-quiet\tfree_slots \(free | tojson) at \(hr)"
    elif latest(ready != 0) != null
      then latest(ready != 0) | "not-quiet\tready unmeasured at \(hr)"
    else "quiet\t\(length) rows starved, \($m) merges prior week"
    end' 2>/dev/null)
  [ -n "$out" ] || out=$'unmeasured\trows unparseable'
  printf '%s\n' "$out"
  return 0
}
