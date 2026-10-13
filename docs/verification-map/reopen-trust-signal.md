# Reopen trust signal

**What it is:** the 14-day reopen rate per project (tickets or issues the client
bounced back after review/done, over merged builds). A project over
`REOPEN_DEMOTE_RATE` (default 0.15, with at least `REOPEN_MIN_SAMPLE` builds,
default 10) loses tier-1 auto-merge until the rate falls. It only ever demotes.

**How it is reached:** there is no screen. The hub lane `bin/reopen-metrics.sh`
(`cron/hub.cron`, `15 4`, lane `reopen-metrics`) writes
`state/reopen-rate.json` on the hub, then one `ledgers` row per fleet.conf
project: `kind=reopen_rate`, `key=<project>`, `status=measured`,
`detail={"reopens_14d":N,"builds_total":D}`. Every build, on any box, reads its
project's row in the `# >>> reopen trust signal` block of `bin/run-build.sh`
through `reopen_rate_get` (`bin/lib/jobs/settings.sh`). It falls back to the
local file only when there is no row, the worker is down or the row is
malformed.

**Key artifacts:**
- `GET $JOBS_URL/api/ledger?kind=reopen_rate`: every row (bearer `HARNESS_SECRET`)
- `GET $JOBS_URL/api/ledger?kind=reopen_rate&key=<project>`: one project, 404 when absent
- `$BUILD/pipeline.log`: one `TRUST: reopen signal from <db row <updated_at>|file <path>|none>: N/D — <note|no demotion>` line per build
- `logs/ALERTS.log` on the hub: `[reopen-metrics] reopen_rate rows not written for: <projects>` when a PUT failed

**Preconditions:** `HARNESS_SECRET` and `JOBS_URL` in the box's `global.env`
(the same credentials the build's job claim already uses).

**Verify it works:**
1. On the hub, after the `15 4` run or a manual `bin/reopen-metrics.sh`:
   `curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/ledger?kind=reopen_rate" | jq '.ledgers | length'`
   equals `bin/fleet-conf.sh --projects | wc -l`, and each row's `detail`
   equals that project's entry in `state/reopen-rate.json`.
2. On a watcher box, which has no `state/reopen-rate.json`, after its next build:
   `grep -h 'TRUST: reopen signal from' /root/harness/builds/*/pipeline.log | tail -1`
   names `db row`, not `none`.

**Manual-only / not automatable:** forcing a demotion in production needs a
project that really is over the threshold. Don't hand-write a hot row to test
it, because every build of that project would drop to tier 2 until the next
`15 4` run overwrote the row. `tests/reopen-rate-db.bh-117-test.sh` drives the
demotion against a stubbed worker instead.
