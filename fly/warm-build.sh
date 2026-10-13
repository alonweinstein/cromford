#!/bin/bash
# fly/warm-build.sh <repo-dir>
#
# The warm-bake BUILD step (fly/Dockerfile, warm stage, the RUN after the
# install), under a timeout of its own (BH-3463). It runs the repo's production
# build once so the image carries .next/cache and *.tsbuildinfo.
#
# IT NEVER FAILS THE IMAGE. The warm layer is an optimization. A `next build`
# that hung inside this step used to hold the whole remote build until
# bin/fleet-propagate.sh's outer bake timeout killed it, so no image was pushed
# at all. Now the build gets WARM_BUILD_TIMEOUT_S seconds (a build ARG that
# bin/fly-image-build.sh resolves from the pool.warm_build_timeout_s row, then
# env, then 600). On a timeout the image ships with checkout + node_modules
# only, and this script always exits 0.
#
# WHAT IT PRINTS. bin/fleet-propagate.sh reads these lines out of the build log:
#   warm-build: step build start timeout=<T>s
#   warm build OK                                         -> pools.<p>.warm=warm
#   warm-build: TIMED OUT after <T>s — ... (warm=cold)    -> warm=cold, a capture
#                                                            and one warn line
#   warm build FAILED — ... (rc=N)                        -> warm=cold, quiet
#   warm-build: step build elapsed=<E>s rc=<RC>
# Markers left in the repo for the runner's logs: .warm-build-failed on any
# failure, .warm-build-timeout as well on a timeout.
#
# The env file (fly/warm-env/<project>.env, baked to /opt/warm-env/) is sourced
# first, so WARM_BUILD_CMD there overrides the repo's build script. WARM_ENV_FILE
# overrides the path (tests). No checkout means nothing to build: exit 0.
set -uo pipefail

REPO="${1:-/opt/warm/repo}"
[ -e "$REPO/.git" ] || { echo "warm-build: no checkout at $REPO — nothing to build"; exit 0; }
cd "$REPO" || exit 0

PM="npm"; [ -f pnpm-lock.yaml ] && PM="corepack pnpm"
ENVF="${WARM_ENV_FILE:-}"
[ -z "$ENVF" ] && [ -n "${WARM_PROJECT:-}" ] && ENVF="/opt/warm-env/$WARM_PROJECT.env"
if [ -n "$ENVF" ] && [ -f "$ENVF" ]; then
  set -a; # shellcheck disable=SC1090
  . "$ENVF"; set +a
fi
CMD="${WARM_BUILD_CMD:-$PM run build}"

T="${WARM_BUILD_TIMEOUT_S:-600}"
case "$T" in
  ''|*[!0-9]*) T_OK=0 ;;
  *) T_OK=1; [ "$T" -gt 0 ] 2>/dev/null || T_OK=0 ;;
esac
if [ "$T_OK" = 0 ]; then
  echo "warm-build: WARM_BUILD_TIMEOUT_S=$T is not a number of seconds — using 600"
  T=600
fi

echo "warm-build: step build start timeout=${T}s"
S=$(date +%s)
RC=0
# GNU timeout puts itself and the build in their own process group and signals
# the group, so `next build`'s workers die with it. -k 30: a build that ignores
# TERM is KILLed half a minute later (rc 137).
timeout -k 30 "$T" sh -c "$CMD" || RC=$?
E=$(( $(date +%s) - S ))

if [ "$RC" = 0 ]; then
  rm -f .warm-build-failed .warm-build-timeout
  echo "warm build OK"
elif [ "$RC" = 124 ] || { [ "$RC" = 137 ] && [ "$E" -ge "$T" ]; }; then
  touch .warm-build-failed .warm-build-timeout
  echo "warm-build: TIMED OUT after ${T}s — baking checkout+node_modules only (warm=cold)"
else
  rm -f .warm-build-timeout
  touch .warm-build-failed
  echo "warm build FAILED — baking checkout+node_modules only (rc=$RC)"
fi
echo "warm-build: step build elapsed=${E}s rc=${RC}"
exit 0
