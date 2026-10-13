# Warm-bake guard

**What it is:** the Fly builder image's warm-bake dependency-install step now
skips cleanly when the cloned repo has no package manifest (`package.json`,
`pnpm-lock.yaml`, or `package-lock.json`). It logs one line and exits 0 so the
image builds cold, instead of failing on `npm install` ENOENT. The helper is
`fly/warm-bake.sh`.

**How an operator reaches it:** `bin/fly-image-build.sh <project>` bakes
`fly/Dockerfile`, which copies `fly/warm-bake.sh` into the image and runs it
against `/opt/warm/repo` when a repo slug is supplied. The nightly
`cron/hub.cron` `fly-image-refresh.sh` run rebuilds every pool image.

**How to drive it:**

| what | how |
|---|---|
| the helper directly, with stubbed `npm`/`corepack` | `bash tests/warm-bake-guard-test.sh` |
| a real no-manifest repo | `bash fly/warm-bake.sh $(mktemp -d)` should print the skip line and exit 0 |
| the full fleet-propagate pool loop | the same fixture suite runs `bin/fleet-propagate.sh` on a scratch harness |
| the app-existence probe, fail-closed semantics | `bash tests/fly-image-build-probe-test.sh` |
| the app-existence probe, against a 1 MB `fly apps list` | `bash tests/fly-image-build-probe.bh-806-test.sh` — runs the whole real `bin/fly-image-build.sh` with stub `fly`/`gh` and a scratch `$HARNESS`, plus the `grep -q`-under-pipefail audit of `bin/lander.sh`, `bin/load-project.sh` and `bin/run-build.sh` |
| what a failed pool bake writes to the log | `bash tests/fleet-propagate-first-fail.bh-806-test.sh` |
| on a Docker-capable host | `bin/fly-image-build.sh project-6` should complete without warm-bake ENOENT and without `known-fail` in the propagate summary |

**Files it owns on a live box / image:**

- `fly/warm-bake.sh` — the install guard.
- `fly/Dockerfile` — the warm-bake layer that copies and calls it.
- `bin/fly-image-build.sh` — the `# >>> app-exists probe` block, and
  `$HARNESS/state/fly/<project>.image` (the ref this run pushed).
- `bin/fleet-propagate.sh` — records per-pool `ok`/`fail`; no `known-fail` special case.
  It also decides WHETHER to bake at all: a pool inside its
  `POOL_IMAGE_MIN_AGE_MIN` window is recorded `debounced` and baked by a later
  tick — see [pool-image-debounce.md](pool-image-debounce.md).
  Every FAILED pool also appends one
  `pool <P>: fail — rc=<n>: <first failing line>` to
  `logs/fleet-propagate.log`, just before the run summary (bh-806).

**What must never regress:** a missing manifest must not make the image build
fail; a real install failure must still be reported as `fail` and make the
fleet-propagate alert `--critical`. An app that IS in `fly apps list` must never
be reported missing, and a list read that FAILED or came back empty must never
be read as "the app is absent" — it fails closed and stops, it never drives a
create. That is the bug bh-806 fixed, where `fly apps list | grep -q` under
`set -o pipefail` returned 141 on a match (SIGPIPE) and 0/10 pool images rebaked
for 11 hours. The listing must also never be searched through a pipe AFTER it is
captured: `printf '%s' "$APPS_JSON" | grep -q` is the same race, because a
builtin producer past one pipe buffer takes the same SIGPIPE on multi-line input
(measured 20/20 at 80 KB), and flyctl pretty-prints its `--json`.
