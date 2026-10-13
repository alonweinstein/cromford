#!/bin/bash
# tests/jobs-worker-test.sh — runs the harness-jobs worker's own node tests from
# the same place as every other suite, so `tests/` stays the one door.
# The worker is dependency-free ESM; node --test drives its fetch handler with a
# stubbed D1. See worker/jobs/test/index.test.js for what that does and does not
# prove.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "jobs-worker-test: SKIPPED — node is not installed on this box"; exit 0; }

# WORKER_JOBS_CI_JOB=1 is set by harness-ci.yml's tests-shard step, which runs
# only when the "Jobs worker — routes + schema" job runs too (both need
# corpus == '1'). That job runs `npm test` in worker/jobs, which covers every
# test/*.test.js file, so running these node files again in a shard is the same
# test twice. Without the flag (a builder's bin/test-impact-gate.sh, a laptop)
# they run here. tests/dedicated-job-coverage-test.sh checks all of this.
if [ "${WORKER_JOBS_CI_JOB:-}" = 1 ]; then
  echo "jobs-worker-test: not repeated here — the Jobs worker CI job runs worker/jobs npm test on this run"
  exit 0
fi

# THE REGISTRY IS RENDERED BEFORE NODE RUNS (BH-1247). worker/jobs/src/lib/core.js
# imports catalog/lanes.json with a STATIC ESM import, resolved at load time, and
# that file is GENERATED from catalog/lanes.d/ and no longer committed — so in a
# fresh checkout every test below dies on ERR_MODULE_NOT_FOUND before it asserts
# anything. CI's own `worker-jobs` job renders for exactly this reason; this
# suite reaches the same code from a `decisions-shard` job, which does not.
#
# It renders into the CHECKOUT and not into $T on purpose: the import path is
# baked into the bundle and cannot be pointed elsewhere, which is the whole
# reason bin/lib/lanes-registry.sh renders to the canonical path. The file is
# git-ignored, and every other consumer regenerates it on demand.
if [ -x "$DIR/bin/lanes-build.sh" ] && [ -d "$DIR/catalog/lanes.d" ]; then
  "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null 2>&1 \
    || { echo "FAIL: jobs-worker-test: catalog/lanes.json could not be composed from catalog/lanes.d — worker/jobs imports it statically and nothing below would run"; exit 1; }
fi

# worker/jobs has one dependency since BH-5618 (@sentry/cloudflare), and
# test/sentry.bh-5618.test.js imports it. Install it when it is absent; a
# failed install FAILS the suite and never skips it.
if [ ! -r "$DIR/worker/jobs/node_modules/@sentry/cloudflare/package.json" ]; then
  (cd "$DIR/worker/jobs" && npm_config_cache="$T/npm-cache" npm ci --no-audit --no-fund) >"$T/npm.log" 2>&1
  NRC=$?
  if [ "$NRC" -ne 0 ]; then cat "$T/npm.log"; echo "FAIL: jobs-worker-test: npm ci failed (rc=$NRC) in worker/jobs"; exit 1; fi
fi

node --test "$DIR"/worker/jobs/test/*.test.js
