#!/bin/bash
# shellcheck shell=bash
# bin/lib/utilization/section-builds.sh — BH-4008 (BH-3988 tracer): the builds
# section of a utilization snapshot. Sourced by bin/utilization-push.sh (every
# bin/lib/utilization/section-*.sh is), never run; needs bin/jobs-client.sh
# loaded for _jobs_req.
#
# util_section_builds <project>
#   Prints {builds:{running,pool_cap,free_slots}, basis:{builds:"measured"|"unmeasured"}}.
#   running     open build jobs: GET /api/jobs?project=&status=running&kind=build&limit=500.
#               null when the read failed, or when it came back at the 500 cap
#               (a capped list is not a count, D12).
#   pool_cap    `effective` from bin/concurrency-plan.sh <p> --json (the cap that
#               binds on the project's route): an integer, "unlimited", or null
#               when that read failed or said anything else.
#   free_slots  "unlimited" when the cap is and running is known; max(cap-running,0)
#               when both are integers; otherwise null, never 0.
#   basis.builds is "unmeasured" whenever any of the three is null.
# rc 1 and nothing printed when there is no project or no harness root
# (${HARNESS:-${H:-}}: a lib never defaults to a path, D43).

UTIL_JOBS_LIMIT=500

util_section_builds() {
  local p="${1:-}" root="${HARNESS:-${H:-}}" out running=null cap=null eff uri
  [ -n "$p" ] && [ -n "$root" ] || return 1
  uri=$(jq -rn --arg v "$p" '$v|@uri') || return 1
  if command -v _jobs_req >/dev/null 2>&1 \
    && out=$(_jobs_req GET "/api/jobs?project=$uri&status=running&kind=build&limit=$UTIL_JOBS_LIMIT"); then
    running=$(printf '%s' "$out" | jq -r --argjson cap "$UTIL_JOBS_LIMIT" \
      'if (.jobs|type) == "array" and (.jobs|length) < $cap then (.jobs|length) else "null" end' 2>/dev/null)
    [[ "$running" =~ ^[0-9]+$ ]] || running=null
  fi
  if eff=$("$root/bin/concurrency-plan.sh" "$p" --json 2>/dev/null | jq -r '.[0].effective // empty' 2>/dev/null); then
    case "$eff" in
      unlimited) cap='"unlimited"' ;;
      *) [[ "$eff" =~ ^[0-9]+$ ]] && cap=$((10#$eff)) ;;
    esac
  fi
  jq -nc --argjson r "$running" --argjson c "$cap" '
    (if $c == "unlimited" and $r != null then "unlimited"
     elif ($c|type) == "number" and ($r|type) == "number" then ([$c - $r, 0]|max)
     else null end) as $f
    | {builds:{running:$r, pool_cap:$c, free_slots:$f},
       basis:{builds:(if $r == null or $c == null or $f == null then "unmeasured" else "measured" end)}}'
}
