# Served-sha watch (Vercel production vs main HEAD)

**What it is:** a hub lane, `bin/served-sha-watch.sh`, run every 5 minutes by
`cron/lanes/251-served-sha-watch.cron` behind `hub-lease.sh check`. For every
row of `vercel.conf` (`<project> <teamId> <projectId> <domain>`) it reads main
HEAD from GitHub, the sha the production domain serves from Vercel, and the
state of HEAD's production deployments. Then it judges the project `in-sync`,
`wait`, `alert` or `unreadable` (`ssw_judge` in `bin/lib/served-sha-watch.sh`).
It exists because project-3 #467 merged, Vercel never built it, and prod served a
~5h old build with nothing noticing (BH-4916).

This slice (BH-4936) only judges, persists and logs. **It sends no alert and
starts no deploy.** #4937 (alert) and #4938 (autodeploy) add those as hooks.

## How to reach it

- Cron: `*/5 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/served-sha-watch.sh`
  (hub only, `catalog/lanes.d/served-sha-watch.json`).
- By hand on the hub: `/root/harness/bin/served-sha-watch.sh; tail -3 /root/harness/logs/served-sha-watch.log`.
- Off: `bin/harness-ctl.sh off served-sha-watch` (flag `flags/lane-off-served-sha-watch`),
  or `SERVED_SHA_LAG_MIN=0`. Either way the tick makes no request.
- Knobs: `SERVED_SHA_LAG_MIN` (default 20 minutes), `SERVED_SHA_AUTODEPLOY`
  (0, read and handed to hooks only), `SERVED_SHA_HTTP_TIMEOUT` (20 s),
  `SERVED_SHA_CONF`, `SERVED_SHA_VERCEL_AUTH`, `SERVED_SHA_NOW` (test seam).
  Vercel base URL: `ENDPOINT_VERCEL` (`catalog/lanes.d/_lib.endpoint-vercel.json`,
  default `https://api.vercel.com`).

## What it writes on a live hub

- `state/served-sha-watch/<project>.json`: `{head, first_seen, served,
  dep_state, last_verdict, checked_at}` while a project is `wait` or `alert`.
  An `unreadable` tick leaves it byte-for-byte as it was, and an `in-sync` tick
  deletes it.
- `logs/served-sha-watch.log`: one line per project that is not in sync, e.g.
  `demo-os alert served=9f8e7d6c head=2b2272a4 age=25m deployment: none`, or
  `demo-os unreadable (alias:500)`. Then one summary,
  `checked=N in_sync=N wait=N alert=N unreadable=N`.

## How to drive it in a test

`tests/served-sha-watch.bh-4936-test.sh` runs the real script through
`tests/lib/served-sha-fixture.sh`. `ssw_fx_setup` builds a scratch `$HARNESS`
with project `demo-os` and stub `curl`/`gh` that answer from `$T/fx/*.json` (+ `.code`).
`ssw_fx_head`, `ssw_fx_served`, `ssw_fx_list` and `ssw_fx_compare` set the
answers, and `ssw_fx_run` runs one tick with `NOW=1790000000`. Requests land in
`$T/req/argv.lines` and `$T/req/gh.lines`. A hook suite drops a file into
`$T/h/bin/lib/served-sha-watch.d/`.

## What usually lies

- `unreadable` is not `in-sync`. A GitHub 429, a Vercel 5xx, an unread compare
  or a served deployment with no git sha (a CLI deploy) are all `unreadable`,
  and the summary counts them separately.
- An expired Vercel CLI token reads as `unreadable` (alias 403). This lane does
  not refresh it. `bin/vercel-deploy-snapshot.sh` nudges the CLI every 4 minutes.
- `deployment: ready` with an older served sha means the domain is pinned
  (Instant Rollback / paused promotion), not that a build is missing.
- `wait` with `age=0m` on a new HEAD with no committer date is the
  `first_seen` fallback starting its clock, not a fresh commit.
