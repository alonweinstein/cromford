#!/bin/bash
# bin/ci-retry.sh — run a CI tool install, retried with back-off when the
# package index hiccups. For .github/workflows/harness-ci.yml.
#
#   ci-retry.sh <label> <command> [args...]
#
#   CI_RETRY_ATTEMPTS   total attempts, whole number >= 1   (default 3)
#   CI_RETRY_DELAY_S    first back-off, whole seconds; it doubles after each
#                       failed attempt: 15 s, then 30 s     (default 15)
#
# WHY. Run 36408393883 (shard 0) went red in `install semgrep` on
# "Could not find a version that satisfies the requirement semantic-version~=
# 2.10.0 (from semgrep)" / "No matching distribution found" — PyPI's index
# answering without a release that exists, for one request. pip's own
# --retries covers a dropped connection, not an index page that came back
# wrong; that needs the whole install again a little later. One attempt under
# `set -e` failed the shard, and in the merge queue that failed the whole batch
# (a bisect and a retest of up to eight PRs).
#
# BOUNDED, NEVER A LOOP, NEVER A SKIP. An index still broken after the last
# attempt is worth seeing: the step goes red with an `::error title=CI infra
# (<label>)` annotation, and the exit code is the command's own, never 0. The
# caller's own checks after the install (`semgrep --version`, ci-tool-present)
# still run under `set -e`, so nothing here can turn a failed install into a
# pass. Same shape as bin/ci-apt-update.sh (BH-2128), for installs that are not
# apt.
#
# EXIT CODES:
#   0   the command succeeded on some attempt
#   N   the command's rc from the last failed attempt
#   2   no command, or CI_RETRY_ATTEMPTS / CI_RETRY_DELAY_S is not a whole
#       number (attempts >= 1); the command is never run. Refused, not
#       clamped: a typo must not become zero attempts or a zero back-off.
#
# The command's stdout and stderr are left alone, so pip's reason lands in the
# step log.
set -uo pipefail

LABEL="${1:-}"
[ $# -ge 2 ] && [ -n "$LABEL" ] || { echo "ci-retry.sh: usage: ci-retry.sh <label> <command> [args...]" >&2; exit 2; }
shift
ATTEMPTS="${CI_RETRY_ATTEMPTS-3}"
DELAY="${CI_RETRY_DELAY_S-15}"
if ! [[ "$ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$ATTEMPTS" -lt 1 ]; then
  echo "ci-retry.sh: CI_RETRY_ATTEMPTS must be a whole number >= 1 (got '$ATTEMPTS')" >&2
  exit 2
fi
if ! [[ "$DELAY" =~ ^[0-9]+$ ]]; then
  echo "ci-retry.sh: CI_RETRY_DELAY_S must be a whole number of seconds (got '$DELAY')" >&2
  exit 2
fi

n=1
while :; do
  "$@" && exit 0
  rc=$?
  if [ "$n" -ge "$ATTEMPTS" ]; then
    echo "::error title=CI infra ($LABEL)::'$*' failed $n time(s), last rc $rc. This is a package-index/runner problem, not a test failure"
    exit "$rc"
  fi
  echo "::warning title=CI infra ($LABEL)::'$*' failed (rc $rc, attempt $n of $ATTEMPTS), likely a transient index error; retrying in ${DELAY}s"
  sleep "$DELAY"
  DELAY=$((DELAY * 2))
  n=$((n + 1))
done
