# Lookback (weekly repeat-failure review)

**What it is:** the hub lane `lookback` (BH-1795). Once a week it gathers the
repeat failures of the last `LOOKBACK_DAYS`, clusters them and files one
`ai-build` issue per cluster. BH-1795.0 ships the driver `bin/lookback.sh`,
the registry entry `catalog/lanes.d/lookback.json` and the shared contract
`bin/lib/lookback-common.sh` (bundle, clusters and ledger shapes, rc
convention). The collector (`bin/lookback-collect.sh`), the clustering call
(`lookback_cluster_run`), the filers (`lookback_file_harness`,
`lookback_file_board`) and the follow-up (`lookback_followup_run`) belong to
sibling slices. The driver calls each one only when it exists, so until they
land a Monday run logs `collector not installed` and exits 0.

**How a user reaches it:** there is **no UI route**. The lane's 14 knobs reach
the console settings page through `GET /api/lanes/registry`, which serves the
registry baked into the worker bundle, so they appear after the next worker deploy.

- trigger: `cron/hub.cron`, `45 6 * * 1 /root/harness/bin/hub-lease.sh check && /root/harness/bin/lookback.sh`
  (source `cron/lanes/465-lookback.cron`, rendered by `bin/render-cron.sh`)
- by hand on the hub: `/root/harness/bin/lookback.sh`, or `LOOKBACK_DRY=1 /root/harness/bin/lookback.sh`
  to cluster and report without filing
- switch: `flags/lane-off-lookback` (`bin/harness-ctl.sh off lookback`), or `flags/all-off`
- lock: `locks/lookback.lock`, `flock -n`, so a second instance exits 0

**Run dir** `state/lookback/<YYYY-MM-DD>/`: `bundle.json` (collector output)
and `clusters.json`. If `clusters.json` already parses as an array, a same-day
re-run reuses it and makes no second clustering call.

**Log lines** (`logs/lookback.log`), one per run:

| State | Line | rc |
|---|---|---|
| no collector | `collector not installed` | 0 |
| collector failed or bundle unparseable | `collector rc=<n>, week not reviewed` + one `logs/ALERTS.log` line `lookback: collector rc=<n>, week not reviewed` | 75 |
| zero items | `no repeat failures in window` (no job row, no alert) | 0 |
| non-empty week | `<N> items, <C> clusters, <F> filed`, plus ` (dry)` on a dry run and `, filing stopped (<why>)` when filing stopped | 0 |

`LOOKBACK_DRY=1` (or any value other than `0`) prints the item count, one
`<source> ok= n= truncated=` line per source and `incomplete=` on stdout, then
runs the job row and the clustering call as a live run does, and calls no filer.

**Summary:** a non-empty week sends exactly one
`bin/lane-alert.sh --severity <sev> --id lookback-<date> lookback "<text>"`.
`<sev>` is `info` for a live run and `warn` (the batched digest) for a dry one,
whose head is `lookback <date> DRY RUN: ...` and whose last line is
`dry run: nothing filed; go live with bin/harness-ctl.sh set lookback LOOKBACK_DRY 0`.
The text carries lines prefixed `filed:`, `would file:` (dry), `commented:`,
`not filed:` (including `not filed: app filing off:`), `over cap:` or
`over cap (week: <n> already filed):` (past `LOOKBACK_MAX_ISSUES` in the rolling
7 days), `week cap unverifiable (<why>), filing stopped`,
`ledger outage, filing stopped:`, `not dispatched:`, `followed up <fp>: ... fix yes|none|unknown`,
`measure: <T> clusters filed to date, <W> in the last 7 days, <F> followed up (<R> recurred, <S> stopped), <M> with a merged fix (<MR> of those recurred)`
(or `measure: ledger unreadable (<why>)`), `invalid model output`,
`clustering not configured`, `clustering not installed`,
`source <name>: not ok|truncated` and `bundle incomplete`. Nothing in the lane
uses `--critical`.

**Settings keys:** `lane.lookback.<env lowercased>`, for example
`lane.lookback.lookback_max_issues`. The driver reads `LOOKBACK_DAYS` (7),
`LOOKBACK_MAX_ISSUES` (5, per rolling 7 days from the ledger's `filed_at`),
`LOOKBACK_DRY` (0) and `LOOKBACK_APP_FILING` (0: app-target clusters are reported,
never filed on a product board). The other `LOOKBACK_*` knobs are
registered for the sibling slices and listed in the header of
`bin/lib/lookback-common.sh`. `LLM_*` are read by `bin/lib/llm-gate.sh`.

**Verify:** `HARNESS_TEST_SANDBOX=1 bash tests/lookback-lane.bh-1795-test.sh`
and `HARNESS_TEST_SANDBOX=1 bash tests/lookback-live.bh-3691-test.sh` drive the
real driver against a scratch `$HARNESS`.
