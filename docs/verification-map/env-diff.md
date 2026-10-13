# Env diff (announce runner / billing / model / effort env changes)

**What it is:** `bin/env-diff.sh`, a `*/15` cron lane on every box. It parses
(never sources) the top-level `*.env` files of the box's env dir
(`/etc/harness/env`, or `$HARNESS/env`) and keeps every assignment whose key is
`RUNNER_*` or `*_BILLING` / `*_MODEL` / `*_EFFORT` as a `file<TAB>KEY<TAB>value`
row. It diffs those rows against `state/env-diff/snapshot.tsv`. Any difference is
ONE `fleet_alert`, `"triaged":true`, `project:"fleet"`, whose line reads
`ENV CHANGE on <box>: global.env GROK_BILLING subscription→api; … (runner/billing
config is architecture: confirm this was intended)`. Absent reads `∅`.

**Why it exists:** BH-19 (the operator, 2026-09-24): "A billing-mode change is an
architecture change and must never be silent." The ticket's home,
`bin/fleet-heartbeat.sh`, was deleted by BH-1031, so this is its companion lane.

**How an operator reaches it:** `bin/render-cron.sh <box>` carries
`*/15 * * * * /root/harness/bin/env-diff.sh >/dev/null 2>&1` for project-4, hub,
project-6, project-1, project-3, project-10, project-9, small, project-2 and
project-5. The output is `logs/env-diff.log` (a baseline line on the first run,
then one line per change set plus the full item list), the console alert, and
on a box with no console, one line in `logs/ALERTS.log`.

**How to drive it:**

| what | how |
|---|---|
| the whole suite (the real script, a stub `beat.sh`, a scratch env dir) | `HARNESS_TEST_SANDBOX=1 bash tests/env-diff.bh-19-test.sh` |
| on a live box, once | `/root/harness/bin/env-diff.sh; tail -3 /root/harness/logs/env-diff.log` |
| what the box last saw | `cat /root/harness/state/env-diff/snapshot.tsv` |
| the knobs a box resolves | `bin/harness-ctl.sh show env-diff` |

**Knobs:** on the `env-diff` lane (`catalog/lanes.d/env-diff.json`):
`ENV_DIFF` (1; 0 = off), `ENV_DIFF_MAX_ITEMS` (20 items in the line before
`(+N more; full list in logs/env-diff.log)`), `ENV_DIFF_BOX` (the box name,
default `hostname`, env file only). Off: `flags/lane-off-env-diff`.

**What must never regress:**

- **Deduped per change, not per tick.** The akey is
  `envdiff:<box>:<hash of the change items>`. An unchanged tick sends nothing.
- **Delivery before bookkeeping.** The snapshot advances only when `beat.sh`
  (`BEAT_STRICT=1`) returns 0, or returns 2 (no console) and the ALERTS.log line
  was written. A failed POST advances nothing, so the next tick re-sends the same
  akey.
- **A baseline is not a change.** The first run, or a lost snapshot, writes the
  snapshot and sends nothing.
- **Absent is not removed.** An env file that cannot be read keeps its previous
  rows; a missing env dir, or one with no readable file, touches nothing.
- **No secret leaves the box.** A value is stored as `sha256:<12 hex>` and
  reported as `changed (value redacted)` when the key name has
  KEY/TOKEN/SECRET/PASS in it, OR the value itself looks like a credential
  (BH-1993, `value_is_secret`): URL userinfo (`https://user:tok@host`), a
  `?token=` / `&api_key=` / `?client_secret=`-style query parameter, a token prefix (`sk-`, `sk-or-`,
  `ghp_`, `ghs_`, `gho_`, `ghu_`, `github_pat_`, `xai-`) or a 32+ character
  letters-and-digits run. The old snapshot is masked the same way as it is read,
  so a raw value left by the pre-BH-1993 script is never echoed and is rewritten
  masked, including the carried-forward rows of an env file the tick cannot
  read. Driven by `bash tests/env-diff.bh-1993-test.sh`.
