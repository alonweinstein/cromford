# Builds merged-flag sweep (BH-3971)

**What it is:** `bin/builds-merged-sweep.sh`, a one-time sweep that is safe to
re-run. It reads every console `builds` row with `merged=1` and checks its PR
against GitHub's merge fact, which is `merged_at` and nothing else. A keyed row
whose PR was closed without merging is set to stage `pr_closed`, `merged=0`.
That is the row the old reconcile bug left behind (project-3 TK-166, PR #331).
Real merges are not touched.

**How to reach it:** run it on the hub, where `env/cloudflare.env` lives. It is
not a cron lane.

```
/root/harness/bin/builds-merged-sweep.sh            # dry run: classifies, writes nothing
/root/harness/bin/builds-merged-sweep.sh --apply    # corrects keyed closed-unmerged rows
```

Options: `--project P` (bound as a D1 param), `--max-reads N` (single GitHub
reads per run, default 300), and `--rows-file F` (a JSON array of `builds` rows
used instead of the D1 read, for when the hub token cannot read D1). The rows
are read from the Cloudflare D1 query API with `CONSOLE_D1_ID` (default
`harness-console-db`'s id) and the account from `console_pages_account_id`.

**Where it writes:**
- `logs/builds-merged-sweep.log`: one line per row
  (`<bkey> <url> merged|closed_unmerged|open|unknown -> corrected|corrected(dry)|kept|reported|reported:keyless|failed|skipped:<why>`),
  then one `summary` line
  (`mode= rows= prs= merged= closed_unmerged= corrected= would_correct= failed= open= unknown= keyless= no_url= reads= capped=`).
- `state/builds-merged-sweep/run-<UTC stamp>-<pid>.tsv`: the per-run record, with the ticket key for each row.
- `state/builds-merged-sweep/verified-merged.tsv`: URLs proven merged. Merged is
  final, so a re-run never reads them from GitHub again.
- With `--apply`, one `BEAT_STRICT=1` build beat per correction. When the jobs
  ledger's `merge`/`pr_merged` row for the URL says `merged`, it is then set to
  `closed`, so `bin/pipeline-health.sh` stops skipping the record.
- One ALERTS line when rows were left as they were (open, keyless or failed).
  It names the run TSV. A failed D1 read is a different ALERTS line, it names
  the token scope needed, and the script exits 1.

**How to drive it:**

| what | how |
|---|---|
| the sweep suite (rows file, D1 cursor paging, apply, ledger, retries, classifier table) | `HARNESS_TEST_SANDBOX=1 bash tests/builds-merged-sweep.bh-3971-test.sh` |
| reconcile requires `merged_at` | `HARNESS_TEST_SANDBOX=1 bash tests/reconcile-prs-merge-fact.bh-3971-test.sh` |
| the PLAN_BLOCKED comment quotes the plan | `HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-plan-excerpt.bh-3971-test.sh` |

**Verify it works:** after `--apply`, the corrected build shows in Mission
Control's pipeline under dead/failed with stage `closed without merging`, and
the log line for its bkey reads `closed_unmerged -> corrected`.

**What usually lies:**
- A dry run's `corrected=` is always 0. What it WOULD change is `would_correct=`.
- `unknown` is never a finding. A 404, a rate limit or a capped read leaves the
  row exactly as it was. A summary with `capped=` above 0 says `INCOMPLETE`;
  re-run it.
- A corrected row moves to the dead column with a fresh `updated_at`. It stays
  on the default board for the 7-day archive window, and then `pipeline.js`'s
  read-time archive hides it. A GitHub-issue ticket whose issue is closed is
  hidden at once by BH-938's join.
- `failed` (the console refused the beat, or this box has no console) leaves
  the row at `merged=1`, so the next run picks it up again.

**Manual-only:** the `--apply` run itself. It writes to the production console,
so a build box never runs it.
