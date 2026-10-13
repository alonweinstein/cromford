#!/bin/bash
# bin/ci-apt-update.sh — `sudo apt-get update` for .github/workflows/harness-ci.yml,
# retried ONCE when a mirror is mid-sync. Every apt install step in that
# workflow calls this instead of running the update itself.
#
#   ci-apt-update.sh          update, retry once after CI_APT_RETRY_DELAY_S (default 20)
#
# WHY (BH-2128). Runs 36029556164 and 36029663354 went red in `apt-get update`
# with "File has unexpected size (46392 != 46384). Mirror sync in progress?".
# One attempt under `set -e` killed the shard, and because the install ran
# inside the step that runs the corpus, the job read as a test failure. apt's
# own Acquire::Retries covers a dropped connection; a size mismatch against a
# half-synced mirror needs a whole second pass a little later, so this does one.
#
# ONE RETRY, NEVER A LOOP. A mirror that is still broken after the back-off is a
# runner problem worth seeing, and the step goes red with an `::error title=CI
# infra (apt)` annotation that says so. The exit code is apt's own, never 0.
#
# THREE OUTCOMES:
#   rc 0     update succeeded (first or second attempt)
#   rc N     apt-get's rc from the second failed attempt
#   rc 2     CI_APT_RETRY_DELAY_S is not a whole number of seconds; apt is
#            never called. Refused, not clamped: a typo must not become 0 s.
#
# apt's stderr is left alone so the reason lands in the step log. On the Fly
# bh-ci image `sudo apt-get` resolves to the /usr/local/sbin flock wrapper
# (docs/CI-RUNNERS.md), exactly as the bare update did before.
set -uo pipefail

DELAY="${CI_APT_RETRY_DELAY_S-20}"
if ! [[ "$DELAY" =~ ^[0-9]+$ ]]; then
  echo "ci-apt-update.sh: CI_APT_RETRY_DELAY_S must be a whole number of seconds (got '$DELAY')" >&2
  exit 2
fi

update() { sudo apt-get -o Acquire::Retries=3 update -q >/dev/null; }

update && exit 0
rc=$?
echo "::warning title=CI infra (apt)::apt-get update failed (rc $rc), likely a mirror sync; retrying once in ${DELAY}s (BH-2128)"
sleep "$DELAY"
update && exit 0
rc=$?
echo "::error title=CI infra (apt)::apt-get update failed twice (rc $rc). This is a runner/mirror problem, not a test failure (BH-2128)"
exit "$rc"
