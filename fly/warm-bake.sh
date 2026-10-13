#!/bin/bash
# fly/warm-bake.sh <repo-dir>
#
# Guarded dependency install for the Fly builder warm-bake layer. Detects the
# package manager from the repo's manifest/lockfiles and runs the right install,
# or skips cleanly when the repo has no package.json/lockfile at all (e.g. a
# greenfield repo like project-6 that has no JavaScript yet).
#
# IT PRINTS THE SHA IT INSTALLED AGAINST. `warm-bake: repo sha <40 hex>` goes to
# the build log, and bin/fleet-propagate.sh greps it into
# state/fleet-propagate.json as pools.<project>.warm_sha — which is how a green
# bake on a REUSED layer is told apart from a fresh one (a reused layer prints
# nothing, so warm_sha is empty). No git, no line: never an error.
#
# PER-PROJECT INSTALL FLAGS. fly/warm-env/<project>.env is baked to
# /opt/warm-env/ and the Dockerfile hands this script WARM_PROJECT, so a repo
# that needs `--legacy-peer-deps` sets WARM_NPM_FLAGS there rather than teaching
# this script about that repo. WARM_ENV_FILE overrides the path (tests).
# The repo's own .npmrc needs nothing: the install runs from the repo directory.
set -uo pipefail

REPO="${1:-.}"

if [ ! -d "$REPO" ]; then
  echo "warm-bake: repo directory does not exist: $REPO" >&2
  exit 2
fi

cd "$REPO"

SHA=$(git rev-parse HEAD 2>/dev/null)
[ -n "$SHA" ] && echo "warm-bake: repo sha $SHA"

ENVF="${WARM_ENV_FILE:-}"
[ -z "$ENVF" ] && [ -n "${WARM_PROJECT:-}" ] && ENVF="/opt/warm-env/$WARM_PROJECT.env"
if [ -n "$ENVF" ] && [ -f "$ENVF" ]; then
  set -a; # shellcheck disable=SC1090
  . "$ENVF"; set +a
fi
: "${WARM_NPM_FLAGS:=}"

# WARM_NPM_FLAGS is a flag STRING from a config file, so the split is the point.
# shellcheck disable=SC2086
if [ -f pnpm-lock.yaml ]; then
  exec corepack pnpm install --frozen-lockfile
elif [ -f package-lock.json ]; then
  exec npm ci $WARM_NPM_FLAGS
elif [ -f package.json ]; then
  exec npm install $WARM_NPM_FLAGS
fi

echo "warm-bake: no package manifest in $REPO, skipping install"
exit 0
