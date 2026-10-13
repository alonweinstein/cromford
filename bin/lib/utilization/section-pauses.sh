#!/bin/bash
# shellcheck shell=bash
# bin/lib/utilization/section-pauses.sh — BH-4010 (BH-3988 tracer, slice 3): the
# pauses section of a utilization snapshot. Sourced by bin/utilization-push.sh
# (every bin/lib/utilization/section-*.sh is), never run; needs
# bin/jobs-client.sh loaded for _jobs_req and held_pages_whole.
#
# util_section_pauses <project>
#   Prints {pauses:[{kind,name,since,stops_builds}...], basis:{pauses:"measured"|"unmeasured"}},
#   in this order:
#   flag   flags/paused-<p> (stops_builds true), flags/all-off (true) and
#          flags/automerge-disabled (false); name = the file name, since = its
#          mtime as YYYY-MM-DDTHH:MM:SSZ.
#   pause  GET /api/pauses?active=1 rows whose scope is "fleet" or <p>;
#          name = <scope>/<what>, since = created_at, stops_builds when what is
#          builds or triage (reviews and merges do not stop a build).
#   hold   held_pages_whole 500 (GET /api/conductor/held) rows whose repo is
#          `bin/fleet-conf.sh <p> repo`; name = "<repo>#<number> <kind>",
#          since = first_held_at, stops_builds false. A project with no repo
#          (empty or "-") has no holds to match and skips the read.
#   basis.pauses is "unmeasured" when _jobs_req is absent, the pauses read
#   failed, had no .pauses array or said truncated:true, or the held read failed
#   or was truncated (rc 3). The flag entries are listed either way and a
#   failed worker read still returns rc 0, so an outage never hides a flag pause.
# rc 1 and nothing printed when there is no project or no harness root
# (${HARNESS:-${H:-}}: a lib never defaults to a path, D43).

util_section_pauses() {
  local p="${1:-}" root="${HARNESS:-${H:-}}" items='[]' basis=measured f name stop since out repo rows rc
  [ -n "$p" ] && [ -n "$root" ] || return 1
  for f in "paused-$p:true" "all-off:true" "automerge-disabled:false"; do
    name="${f%:*}"; stop="${f##*:}"
    [ -f "$root/flags/$name" ] || continue
    since=$(date -u -d "@$(stat -c %Y "$root/flags/$name")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || since=""
    items=$(jq -c --arg n "$name" --arg s "$since" --argjson b "$stop" \
      '. + [{kind:"flag", name:$n, since:(if $s == "" then null else $s end), stops_builds:$b}]' <<<"$items") || return 1
  done
  if command -v _jobs_req >/dev/null 2>&1 && out=$(_jobs_req GET '/api/pauses?active=1') \
    && printf '%s' "$out" | jq -e '(.pauses|type) == "array" and .truncated != true' >/dev/null 2>&1; then
    # Bodies go in on stdin, never argv (a single argument is capped at 128 KiB).
    items=$({ printf '%s\n' "$items"; printf '%s' "$out"; } | jq -sc --arg p "$p" '.[0] + [.[1].pauses[]
      | select(.scope == "fleet" or .scope == $p)
      | {kind:"pause", name:"\(.scope)/\(.what)", since:.created_at,
         stops_builds:(.what == "builds" or .what == "triage")}]') || return 1
  else
    basis=unmeasured
  fi
  repo=$("$root/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  if [ -n "$repo" ] && [ "$repo" != "-" ]; then
    if command -v held_pages_whole >/dev/null 2>&1; then
      rows=$(held_pages_whole 500); rc=$?
    else
      rc=1
    fi
    if [ "$rc" = 0 ]; then
      rows=$(printf '%s' "$rows" | jq -R -s -c --arg r "$repo" '[
        split("\n")[] | select(. != "") | split("\t") | select(.[0] == $r)
        | {kind:"hold", name:"\(.[0])#\(.[1]) \(.[4])", since:.[8], stops_builds:false}]') || return 1
      items=$({ printf '%s\n' "$items"; printf '%s' "$rows"; } | jq -sc '.[0] + .[1]') || return 1
    else
      basis=unmeasured
    fi
  fi
  printf '%s' "$items" | jq -c --arg b "$basis" '{pauses:., basis:{pauses:$b}}'
}
