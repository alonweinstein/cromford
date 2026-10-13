#!/bin/bash
# shellcheck shell=bash
# bin/lib/utilization.sh — BH-4008 (BH-3988 tracer): the utilization verdict.
# Sourced by bin/utilization-push.sh, never run. jq only: no network, no clock.
#
# util_verdict <snapshot-json>
#   Prints `<verdict>\t<why>`, rc 0, and the verdict is always one the PUT
#   accepts (starved|paused|blocked|saturated|busy|unknown).
#   - not a JSON object:                 unknown	snapshot unparseable
#   - .tickets.ready or .builds.free_slots null or absent (precedence rule 1):
#                                        unknown	inputs unmeasured: <paths>
#   Then the rest of the precedence (BH-4009), first match wins, over
#   b = .builds, t = .tickets and pauses = .pauses (absent or not an array: []):
#   2 paused     a pauses[] entry with stops_builds true:
#                                        paused	pause <kind>:<name> stops builds
#                or b.pool_cap 0:        paused	pool cap 0
#   3 saturated  free_slots 0 and ready > 0:
#                                        saturated	ready <r>, 0 free slots, running <n>
#   4 busy       running > 0, or ready > 0 with free slots ("unlimited" or > 0):
#                                        busy	running <n>, ready <r>
#   5 blocked    ready 0 and blocked + held + parked > 0:
#                                        blocked	blocked <b> held <h> parked <p>
#   6 starved    ready 0, none blocked/held/parked, free slots:
#                                        starved	nothing ready, blocked, held or parked; free slots <f>
#   - none of them (a ready that is not a number): unknown	no verdict rule matched
#   In rules 5 and 6 a null blocked/held/parked prints as `?`, counts as 0, and
#   the why ends `; unmeasured: <names>`.
#   Rule 1 comes first on purpose: a ticket read that failed (rate limited) or
#   an unreadable cap must never be read as 0 ready or 0 free, which is what a
#   later rule would turn into `starved`.

util_verdict() {
  local out
  out=$(printf '%s' "${1:-}" | jq -r '
    def q: if . == null then "?" else tostring end;
    if type != "object" then "unknown\tsnapshot unparseable"
    else
      [ (if (.tickets.ready? // null) == null then "tickets.ready" else empty end),
        (if (.builds.free_slots? // null) == null then "builds.free_slots" else empty end) ] as $miss
      | if ($miss|length) > 0 then "unknown\tinputs unmeasured: \($miss|join(" "))"
        else
          (.builds // {}) as $b | (.tickets // {}) as $t
          | (if (.pauses|type) == "array" then .pauses else [] end) as $pauses
          | ([$pauses[] | select(type == "object" and .stops_builds == true)] | first) as $stop
          | $t.ready as $r | $b.free_slots as $f | ($b.running // 0) as $n
          | (($f == "unlimited") or (($f|type) == "number" and $f > 0)) as $free
          | ([$t.blocked, $t.held, $t.parked] | map(if type == "number" then . else 0 end) | add) as $stuck
          | ([["blocked", $t.blocked], ["held", $t.held], ["parked", $t.parked]]
             | map(select(.[1] == null) | .[0])) as $unm
          | (if ($unm|length) > 0 then "; unmeasured: \($unm|join(" "))" else "" end) as $tail
          | if $stop != null then "paused\tpause \($stop.kind // "?"):\($stop.name // "?") stops builds"
            elif $b.pool_cap == 0 then "paused\tpool cap 0"
            elif ($r|type) != "number" then "unknown\tno verdict rule matched"
            elif $f == 0 and $r > 0 then "saturated\tready \($r), 0 free slots, running \($n)"
            elif $n > 0 or ($r > 0 and $free) then "busy\trunning \($n), ready \($r)"
            elif $r == 0 and $stuck > 0 then
              "blocked\tblocked \($t.blocked|q) held \($t.held|q) parked \($t.parked|q)\($tail)"
            elif $r == 0 and $free then "starved\tnothing ready, blocked, held or parked; free slots \($f)\($tail)"
            else "unknown\tno verdict rule matched" end
        end
    end' 2>/dev/null)
  [ -n "$out" ] || out=$'unknown\tsnapshot unparseable'
  printf '%s\n' "$out"
}
