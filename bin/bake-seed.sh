#!/bin/bash
# bin/bake-seed.sh — read or seed the bake.<name>.version settings rows that
# pin every dependency fly/Dockerfile bakes (BH-1528; manifest:
# bin/lib/bake-deps.sh). Run it on the hub (it talks to the jobs worker through
# bin/jobs-client.sh, as the hub box).
#
#   bin/bake-seed.sh
#       report: one line per manifest dependency — its row (or MISSING) and,
#       where the manifest approves one, this host's installed version. Exit 1
#       when any row is missing, so it doubles as the post-merge check.
#   bin/bake-seed.sh [--force] <name>=<version> ...
#       write rows. Without --force an existing row is left alone (seeding is
#       for the missing ones; a deliberate bump says --force). An unknown name
#       or a value that is not an exact x.y.z (a leading v is allowed) is
#       refused before anything is written, so a typo can never half-apply.
#       The row written is the bare version: bake.<name>.version = "22.23.2".
#
# The first build after a row changes rebakes only that dependency's layer (see
# fly/Dockerfile's STAGES note). Overrides (tests only): HARNESS.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/jobs-client.sh
. "$HERE/jobs-client.sh" 2>/dev/null || { echo "FATAL: bin/jobs-client.sh not loadable" >&2; exit 1; }
# shellcheck source=bin/lib/cli-version.sh
. "$HERE/lib/cli-version.sh" || exit 1
# shellcheck source=bin/lib/bake-deps.sh
. "$HERE/lib/bake-deps.sh" || exit 1

report() {
  local name probe row missing=0 host
  while read -r name _ probe; do
    row=$(bake_row_version "$name"); [ $? = 1 ] && { echo "FATAL: settings unreachable" >&2; return 1; }
    host="-"; [ "$probe" != - ] && host=$(cli_version_of "$probe" 2>/dev/null)
    [ -n "$row" ] || { row=MISSING; missing=1; }
    printf '%-11s bake.%s.version=%s  host=%s\n' "$name" "$name" "$row" "$host"
  done < <(bake_deps)
  return "$missing"
}

# validate <pair>... -> rc 0 only when every pair names a manifest dependency
# and carries a dotted version; prints every problem, not just the first.
validate() {
  local pair name v bad=0
  for pair in "$@"; do
    name="${pair%%=*}"; v="${pair#*=}"
    bake_dep_names | grep -qx "$name" || { echo "refused: $name is not in bin/lib/bake-deps.sh" >&2; bad=1; continue; }
    # Strict x.y.z (BH-1528 review F6): the row is fleet-wide, and "1.48" would
    # resolve to some 1.48.x at install time, fail bake_verify, and refuse every
    # project for a night. A leading "v" is fine: the build parses it away.
    [ "$pair" != "$name" ] && [[ "${v#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "refused: $pair is not an exact x.y.z version" >&2; bad=1; }
  done
  return "$bad"
}

seed() { # seed <force> <pair>...
  local force="$1" pair name v rc=0; shift
  for pair in "$@"; do
    name="${pair%%=*}"; v=$(cli_version_parse "${pair#*=}")
    if [ "$force" != 1 ] && [ -n "$(bake_row_version "$name")" ]; then
      echo "kept:    bake.$name.version=$(bake_row_version "$name") (exists; --force to replace)"; continue
    fi
    if setting_set "bake.$name.version" "$v" "BH-1528: pinned version fly/Dockerfile bakes for $name"; then
      echo "written: bake.$name.version=$v"
    else echo "FAILED:  bake.$name.version=$v (worker unreachable or refused)" >&2; rc=1; fi
  done
  return "$rc"
}

FORCE=0
[ "${1:-}" = --force ] && { FORCE=1; shift; }
[ $# -eq 0 ] && { report; exit $?; }
validate "$@" || exit 2
seed "$FORCE" "$@"
