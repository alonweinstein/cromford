#!/bin/bash
# shellcheck shell=bash
# tests/lib/registry-cache.bh-5651.sh — BH-5651: a fleet registry CACHE for the
# shell suites, so they read the fleet through bin/lib/registry.sh (the reader a
# box in db mode uses) and not through a fleet.conf file. Sourced after
# tests/lib/scratch.sh; defines functions, runs nothing.
#
#   rcache_install <harness-root> <rows-file|repo-root>
#                  write <harness-root>/state/registry/{registry.json,
#                  fleet.conf,version}, the files the ladder's step 1 serves
#                  with no HTTP, and export REGISTRY_SOURCE=db
#                  REGISTRY_CACHE_TTL_S=86400 JOBS_URL= into the caller.
#                  A FILE is fixture rows in fleet.conf shape
#                  (<project> <repo> <prod> <prefix> <offset> [box [ip]]),
#                  status active, position = row order. A DIRECTORY is a repo
#                  root: bin/registry-seed.sh --emit --root <dir>, minus actor.
#                  RCACHE_REGISTRY_JSON=<file>, when set, replaces the --emit
#                  for a directory (tests/registry-parity.bh-5651-test.sh runs
#                  the suites in a tree with no fleet.conf to emit from).
#                  The answer must pass registry_valid; rc 1 (stderr) if not.
#   rcache_run <harness-root> <cmd...>
#                  run <cmd> in db mode against that cache, in the same env
#                  rcache_install exports, without changing the caller's env.
#
# The fleet.conf in the cache is rendered with _rg_render from bin/lib/registry.sh,
# so it is byte for byte what a fetch would write. TTL 86400 keeps a scratch
# cache fresh for the whole suite; with JOBS_URL empty a stale cache is served
# anyway (ladder step 2), so a slow run never reaches a network.

__rcache_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

rcache_install() {
  local root="${1:-}" src="${2:-}" d tmp
  [ -n "$root" ] && [ -n "$src" ] || { echo "rcache_install: usage: rcache_install <harness-root> <rows-file|repo-root>" >&2; return 1; }
  d="$root/state/registry"
  mkdir -p "$d" || { echo "rcache_install: cannot create $d" >&2; return 1; }
  tmp="$d/.rcache.json"
  if [ -d "$src" ]; then
    if [ -n "${RCACHE_REGISTRY_JSON:-}" ]; then
      jq -S 'del(.actor) | .version = 1' "$RCACHE_REGISTRY_JSON" > "$tmp" \
        || { echo "rcache_install: RCACHE_REGISTRY_JSON=$RCACHE_REGISTRY_JSON is not JSON" >&2; return 1; }
    else
      "$__rcache_repo/bin/registry-seed.sh" --emit --root "$src" | jq -S 'del(.actor) | .version = 1' > "$tmp" \
        || { echo "rcache_install: bin/registry-seed.sh --emit --root $src failed" >&2; return 1; }
    fi
  elif [ -f "$src" ]; then
    awk -v OFS='\t' '!/^[[:space:]]*(#|$)/ { print $1, $2, $3, $4, $5, $6, $7 }' "$src" | jq -R -s -S '
      def dash: if . == "" then null else . end;
      (split("\n") | map(select(length > 0) | split("\t"))) as $r
      | { version: 1,
          projects: ($r | to_entries | map({project: .value[0], repo: .value[1], prod: .value[2],
              board_prefix: .value[3], cron_offset: (.value[4] | tonumber), box: (.value[5] | dash),
              status: "active", position: .key})),
          boxes: ($r | map(select(.[5] != "")) | group_by(.[5])
              | map({box: .[0][5], tailnet_ip: (map(.[6]) | map(select(. != "")) | first)})),
          lane_boxes: [], box_accounts: [] }' > "$tmp" \
      || { echo "rcache_install: the rows in $src did not parse" >&2; return 1; }
  else
    echo "rcache_install: $src is neither a rows file nor a repo root" >&2; return 1
  fi
  (
    # shellcheck source=bin/lib/registry.sh
    . "$__rcache_repo/bin/lib/registry.sh" || exit 1
    registry_valid "$tmp" || { echo "rcache_install: the registry built from $src fails registry_valid" >&2; exit 1; }
    _rg_render "$tmp" > "$d/fleet.conf" || exit 1
    jq -r '.version' "$tmp" > "$d/version" || exit 1
    mv -f "$tmp" "$d/registry.json"
  ) || { rm -f "$tmp"; return 1; }
  export REGISTRY_SOURCE=db REGISTRY_CACHE_TTL_S=86400 JOBS_URL=
}

rcache_run() {
  local root="$1"; shift
  env REGISTRY_SOURCE=db REGISTRY_CACHE_TTL_S=86400 JOBS_URL= HARNESS="$root" "$@"
}
