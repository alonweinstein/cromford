#!/bin/bash
# Deploy hand-off shim: routes a merged sha to the wave-4b deploy train when
# the project has a version endpoint (VERSION_URL in its env), else falls back
# to the per-merge deploy-verify path. Called by run-build.sh, review-prs.sh,
# and merge-queue.sh after any verified merge.
# usage: deploy-request.sh <project> <slug> <merge-sha> <build-dir>
set -uo pipefail
PROJECT="${1:?}"; SLUG="${2:?}"; MSHA="${3:?}"; BUILD="${4:?}"
# The env wins where one is set (the conductor exports HARNESS; the fixtures
# drive a scratch tree). /root/harness everywhere else, as before.
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; . "$HENV/$PROJECT.env" 2>/dev/null; set +a
if [ -n "${VERSION_URL:-}" ]; then
  DQ="$HARNESS/state/deploy-queue/$PROJECT"; mkdir -p "$DQ"
  # >>> deploy queue row (BH-1026.1)
  # THE ROW FIRST, THEN THE FILE — and the file in every branch. If only one of
  # the two can survive a crash here it must be the row: the train ADOPTS a file
  # that has no row, and nothing re-creates a row for a file that is already
  # gone. A row write that fails costs one log line and nothing else.
  #
  # IN A SUBSHELL, deliberately. bin/jobs-client.sh `exit 1`s the shell that
  # sources it when a module is missing (BH-1194's half-load refusal), and
  # sourced at this file's top level a half-synced box would lose the FILE write
  # too — the one failure this block may never cause. rc 3 = not armed (no
  # client, no function, knob off) and is silent; rc 0 = row written or already
  # there; anything else is a real failure and says so once.
  if [ -r "$HARNESS/bin/jobs-client.sh" ]; then
    (
      # shellcheck source=/dev/null
      . "$HARNESS/bin/jobs-client.sh" 2>/dev/null || exit 3
      command -v deploy_queue_rows_on >/dev/null 2>&1 || exit 3
      deploy_queue_rows_on || exit 3
      deploy_queue_put "$PROJECT" "$MSHA" "$BUILD" >/dev/null
    ) 2>/dev/null
    DQRC=$?
    case "$DQRC" in
      0|3) ;;
      *) mkdir -p "$HARNESS/logs"
         echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] deploy-request: deploy_queue row for ${MSHA:0:8} not written (rc=$DQRC) — the file is still written and the train reads it" \
           >> "$HARNESS/logs/deploy-train.log" ;;
    esac
  fi
  # <<< deploy queue row (BH-1026.1)
  printf '%s %s\n' "$MSHA" "$BUILD" > "$DQ/$(date -u +%s)-${MSHA:0:8}"
  exit 0
fi
# BH-3387: a project whose deploy.<project>.kind row says `none` has no GitHub
# production deployment, so there is nothing for a verifier to poll and nothing
# to page about. One SKIP line (stdout too: mc_dv_run records it), the stale
# deployfail pages closed in the background, and no verifier. smoke-only, no row
# and an outage all launch the verifier as before; it takes its own branch.
# shellcheck source=bin/lib/deploy-kind.sh
. "$HARNESS/bin/lib/deploy-kind.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/deploy-kind.sh" 2>/dev/null || deploy_kind() { return 2; }
if [ "$(deploy_kind "$PROJECT" 2>/dev/null)" = none ]; then   # the verifier names a bad value
  LINE="$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] deploy-verify SKIP: $PROJECT has no GitHub production deployment (deploy.kind=none)"
  echo "$LINE" >> "$BUILD/pipeline.log"; echo "$LINE"
  (setsid "$HARNESS/bin/deploy-kind-resolve.sh" "$PROJECT" </dev/null >/dev/null 2>&1 9>&- &)
  exit 0
fi
if [ "${MC_DV_INLINE:-0}" = 1 ]; then
  # The caller is ALREADY the merge conductor's detached deploy-verify lane job
  # (mc_dv_run, 2026-09-14): it has its own state dir, its own result file and
  # it closed the tick's lock fd on the way out. So the verifier runs in the
  # FOREGROUND here and its exit code becomes the lane's result. The routing
  # above stays the one copy of "train or verifier" in the fleet.
  exec "$HARNESS/bin/deploy-verify.sh" "$PROJECT" "$SLUG" "$MSHA" "$BUILD"
else
  # 9>&- : callers (merge-conductor tick) hold their per-project flock on fd 9; a
  # detached verifier that inherits it keeps the lock for its whole poll and every
  # later tick logs "an earlier conductor tick still holds this lock" (03:30-03:43Z 09-14).
  (setsid "$HARNESS/bin/deploy-verify.sh" "$PROJECT" "$SLUG" "$MSHA" "$BUILD" </dev/null >> "$BUILD/deploy-verify.log" 2>&1 9>&- &)
fi
exit 0
