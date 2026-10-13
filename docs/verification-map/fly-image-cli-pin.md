# Baked-CLI pin and drift floor (Fly builder images)

**What it is:** the Fly builder image pins the exact `claude` / `codex` version
it installs (BH-1517), and the nightly refresh lane compares what is baked
against the hub's own current versions and alerts when a builder falls behind
(BH-1531 made that comparison honest).

**How an operator reaches it:** no UI. `bin/fly-image-build.sh <project>`
resolves the versions and passes them to `fly deploy` as `--build-arg`; the
nightly `cron/hub.cron` `bin/fly-image-refresh.sh` run (05:40Z) rebuilds every
pool image and does the bookkeeping.

**Preconditions / seed needs:** settings rows `cli.claude_code.version` and
`cli.codex.version` (written by `bin/cli-update.sh`) are the wanted versions;
this host's own installed CLI is the documented fallback when a row is absent
or unusable. `CLI_DRIFT_MAX_PATCH` (default 3) is the floor. Row writes are
gated on `machines_rows_on`.

**How to drive it:**

| what | how |
|---|---|
| version resolution, build-arg plumbing, the Dockerfile verify block, the floor | `bash tests/fly-image-cli-pin.bh-1517-test.sh` |
| an unusable row (`latest`), the `.cli`-only-with-a-ref rule, the floor on a FAILED rebuild | `bash tests/fly-image-cli-pin.bh-1531-test.sh` |
| on the hub, after a nightly run | `tail -3 logs/fly-image-refresh.log`, then `cat state/fly/<project>.cli` |

**Files it owns on a live box:**

- `state/fly/<project>.cli` — `claude=X` / `codex=Y` for the image
  `state/fly/<project>.image` points at. Written ONLY when this run parsed a
  pushed image ref; on the ref-not-parsed path both files are left untouched.
- settings `fly_image_cli.<project>` — the DB twin of that file, refreshed on
  EVERY nightly iteration (a failed rebuild included), not only after a
  successful one.
- `flags/alerted-fly-image-drift-<project>-<YYYYMMDD>` — the one-alert-per-
  project-per-UTC-day dedupe for the `CLI drift` ALERTS line.

**What must never regress:** `.cli` must never describe a build that did not
land (that is what makes the floor a stale-builder detector rather than a
same-run self-compare); the drift floor must still run when the rebuild FAILED,
which is the night the pool is actually stuck on an old image; a settings row
with no dotted number must never reach `--build-arg` — it is ignored with a
WARN naming the row, the host fallback decides, and a build with nothing to pin
still refuses outright (never `latest`).
