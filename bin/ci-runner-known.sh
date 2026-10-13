#!/bin/bash
# bin/ci-runner-known.sh — "does the CI_RUNNER value name a fleet we actually
# run on?" One answer, run by the `lint` job of .github/workflows/harness-ci.yml
# against the live repo variable.
#
#   ci-runner-known.sh <value>     <value> is the raw JSON text of CI_RUNNER
#
# WHY (BH-1323). Where CI runs is a data switch (BH-1209/BH-1206): every job is
#
#   runs-on: ${{ fromJSON(vars.CI_RUNNER || '"ubuntu-latest"') }}
#
# so the fleet moves with one API call and a re-run. The fallback is what makes
# that safe to flip, and it is also the hole. Mistype the value, or delete the
# variable, and `vars.CI_RUNNER` renders empty, fromJSON takes the fallback, and
# the ENTIRE run goes green on a hosted image nobody chose — no red job, no
# queued job, nothing in the log saying which fleet graded the merge. This script
# is what turns that silence into one red step.
#
# THE MATCH IS EXACT BYTES, NEVER NORMALISED JSON. A trailing space inside the
# quotes (`"monkci-ubuntu-24.04-4 "`) is a runner label GitHub has nothing
# registered for, so every job queues forever; piping the value through `jq -c`
# first would erase exactly that difference and bless the outage. Same for a
# subset of the pool's labels, or a re-ordered array: a value that is not one of
# the two lines below is a value nobody has run CI on.
#
# ADDING A FLEET IS TWO EDITS IN ONE PR: a line here, and a row in the
# `## Known fleets` table of docs/CI-RUNNERS.md.
# tests/harness-ci-runners.bh-1323-test.sh runs the guard over the doc's table,
# so a list and a table that disagree is a red suite rather than a surprise the
# next time somebody flips the switch.
#
# THREE OUTCOMES, NEVER TWO:
#   rc 0   the value is byte-identical to a known fleet
#   rc 1   anything else, INCLUDING the empty string — an unset variable is the
#          same silent hosted fallback as a typo, and the caller does the same
#          thing with both: stop the run and fix the variable
#   rc 2   misuse (no value passed). NEVER 0: a guard that answered "known" to a
#          call it did not understand is a green step that checked nothing.
#
# It writes nothing, reads no network, and takes nothing from the environment —
# the value arrives as an argument because `${{ vars.X }}` interpolated into a
# `run:` line is a template injection, and env: is the sanctioned path.
set -uo pipefail

# The fleets, one line each, byte for byte as the repo variable holds them.
MONKCI='"monkci-ubuntu-24.04-4"'                  # MonkCI hosted runners, current
FLYPOOL='["self-hosted","linux","bh-ci"]'         # the Fly bh-ci pool, fallback

if [ $# -ne 1 ]; then
  echo "usage: ci-runner-known.sh <CI_RUNNER-json-value>" >&2
  exit 2
fi

VALUE="$1"

# Quoted patterns: the Fly value carries [ ] and would otherwise be read as a
# glob bracket expression.
case "$VALUE" in
  "$MONKCI")
    echo "ci-runner-known: CI_RUNNER is $MONKCI — MonkCI hosted runners"
    exit 0 ;;
  "$FLYPOOL")
    echo "ci-runner-known: CI_RUNNER is $FLYPOOL — the Fly bh-ci pool"
    exit 0 ;;
esac

if [ -z "$VALUE" ]; then
  echo "ci-runner-known: CI_RUNNER is unset — every job silently falls back to the hosted image" >&2
else
  echo "ci-runner-known: CI_RUNNER is $VALUE, which names no fleet CI has ever run on" >&2
fi
{
  echo "ci-runner-known: the known fleets are, byte for byte:"
  echo "    $MONKCI   MonkCI hosted runners (current)"
  echo "    $FLYPOOL   the Fly bh-ci pool (fallback)"
  echo "ci-runner-known: set one of them with"
  echo "    gh api -X PATCH repos/${GITHUB_REPOSITORY:-<owner>/<repo>}/actions/variables/CI_RUNNER -f value='<value above>'"
  echo "ci-runner-known: a NEW fleet is a line in bin/ci-runner-known.sh and a row in the '## Known fleets' table of docs/CI-RUNNERS.md, in the same PR."
} >&2
exit 1
