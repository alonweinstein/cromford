#!/bin/bash
# box-for.sh <project> — resolve which fleet box owns a project's watcher.
# Prints "local" (the hub runs it) or a box hostname (ssh root@<box>).
# Source of truth: fleet.conf column 6, read through bin/fleet-conf.sh (with
# REGISTRY_SOURCE=db that is the D1 registry, then its cache, then fleet.conf —
# BH-5649); legacy rows without a box column fall
# back to the naming convention <HARNESS_BOX_PREFIX><project-minus-"-os">
# (project-1 is the hub itself; the prefix is bin/lib/deployment.sh's,
# box- by default). Unknown project -> exit 1, prints nothing.
set -uo pipefail
PROJECT="${1:?project}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BOX=$("$HERE/fleet-conf.sh" "$PROJECT" box 2>/dev/null || true)
if [ -n "$BOX" ]; then echo "$BOX"; exit 0; fi
# Legacy fallback — only for projects that exist in fleet.conf at all.
"$HERE/fleet-conf.sh" "$PROJECT" repo >/dev/null 2>&1 || exit 1
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$HERE/lib/deployment.sh}" || exit 1
case "$PROJECT" in
  project-1) echo local ;;
  *) echo "${HARNESS_BOX_PREFIX}${PROJECT%-os}" ;;
esac
