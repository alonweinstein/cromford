# Post-merge QA on project-5, the dry run, and signed-out preview QA (BH-3438)

**What it is:** three pieces that together stop project-5's QA from being nothing.

1. **project-5 is on the post-merge QA lane.** `catalog/lanes.d/postmerge-qa.json`
   lists `project-5` and `cron/lanes/600-postmerge-qa.cron` carries a
   `# @box project-5` variant at minute :46. Until the project-5 QA account exists
   (`QA_TEST_USER_ID` + `QA_CLERK_SECRET_KEY` in `env/project-5.env`), each merged
   build is recorded `NOT_COVERED_NO_QA_ENV`, the lane's existing answer for an
   unconfigured project.
2. **`bin/postmerge-qa.sh <project> [build-dir] --dry-run`** prints one line,
   `DRY RUN postmerge-qa <project>: prod=… user=…|UNSET clerk_key=set|UNSET build=<dir>|none routes=…`,
   and exits. rc 0 when prod, user and key all resolved; rc 1 plus an `owed:` line
   otherwise. It runs before the lock, the switches, the model route and any gh,
   curl, node or qa-unbanned.sh call, and writes nothing. The key's value is never
   printed. Routes come from the build's `plan.md` `## QA screens` (the build dir
   given, else the newest `builds/<project>-*` with a plan), else `/`.
3. **Preview QA.** A skip now names its reason: `qa.md` reads
   `preview unavailable — QA skipped (fail-open): <last line wait-preview.sh wrote to stderr>`
   and the PR's evidence row `| preview QA | skipped — … |` carries it. The full
   stderr is in the build's `wait-preview.err` and still in `pipeline.log`.
   `catalog/preview-qa.conf` lists projects whose previews cannot sign in
   (`project-5 signed-out`, read by `bin/lib/preview-qa-mode.sh`). For those, the
   QA prompt says not to attempt a Clerk sign-in and to drive routes signed out,
   and `bin/lib/rb/result.sh` demotes a tier-1 PASS to tier-2 with
   `QA: SIGNED-OUT ONLY`, because authed screens were never observed.

**How an operator reaches it:** no UI. On box-project-5-1:

```bash
/root/harness/bin/postmerge-qa.sh project-5 --dry-run; echo rc=$?
```

Expect rc 1 with `user=UNSET clerk_key=UNSET` until the env is set, then rc 0.

**What to check on a live box:** `logs/postmerge-qa.log` (one line per build per
tick), `state/postmerge-qa-done.txt` (terminal outcomes), and in a build dir
`wait-preview.err` + `qa.md` for a preview-QA skip.

**Still owed outside this repo's code:** project-5 has no `vercel.conf` row, so
`bin/wait-preview.sh` has no Vercel snapshot for it and falls to the GitHub
Deployments API, which the fleet PAT is denied. Until that row exists every
project-5 preview-QA skip names that reason, and no project-5 preview is driven.

**Suites:** `tests/postmerge-qa.bh-3438-test.sh` (lane config, rendered crontab,
dry run), `tests/preview-qa.bh-3438-test.sh` (skip reason, registry, prompt, tier
gate).
