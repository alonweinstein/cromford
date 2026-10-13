# Hotfix post-deploy apply and close-out

**What it is:** the second half of the hotfix lane (#370.4, BH-378).
`bin/hotfix-migrate.sh` records `deferred-to-deploy` when the app cannot see the
SQL yet — the migration endpoint's own rule is that a file is pending only once
the merge carrying it is deployed. `bin/hotfix-after-deploy.sh` is what comes
back afterwards: once `bin/deploy-verify.sh` has logged `deploy-verify OK` for
the merge sha, it applies those files through the same driver, posts a SECOND
proof comment on the PR, records the outcome in the build's ledger, and — for a
project on the GitHub-Issues lane — comments "deployed &lt;sha&gt;, live at
&lt;url&gt;" on the issue and closes it. Nothing here can change the deploy
verdict; a file that did not apply is an ALERT and the issue stays open.

| half | where it lives | when it acts |
|---|---|---|
| the post-deploy stage (apply, second proof, ledger, issue close-out) | `bin/hotfix-after-deploy.sh` | once per merge sha, from the deploy gate |
| the caller | the `2*\|3*` success arm of `bin/deploy-verify.sh`, immediately AFTER the `deploy-verify OK` log line | only when `$BUILD/hotfix-migrate.json` exists and the script is executable |
| how the caller is reached | `bin/deploy-request.sh:22` (the conductor's settle lane) and `:27` (`setsid` from run-build's `PR_MERGED` path) | detached, after a tier-1 auto-merge |
| the apply driver | `bin/apply-migrations.sh <project> --files <basename>…` — the same `apply_one` the `*/15` cron tick runs | per file named in the ledger, in ledger order |

**How an operator reaches it:** no cron line and no UI — it runs inside the
detached deploy gate. By hand, on the box that built it:
`SLUG=… PR_URL=… bin/hotfix-after-deploy.sh <project> <build-dir> <merge-sha>`
(`SLUG`/`PR_URL` are optional: they resolve from `fleet.conf` and the build's
`RESULT` line). `docs/DB-COORDINATION-SPEC.md` § "Hotfix go-live (BH-370)" is
the ops page; `docs/verification-map/hotfix-migrate.md` is the pre-merge half.

**How to drive it:**

| what | how |
|---|---|
| the whole stage against stubs (apply order, retry, verdict words, proof marker, ledger, close-out, in-app-board lane, held/flagged ledgers) | `bash tests/hotfix-after-deploy-test.sh` |
| the production caller: the hook runs only AFTER the `deploy-verify OK` line, and its failure never becomes a deploy failure | case 6 of that suite — it runs the REAL `bin/deploy-verify.sh` with stubbed `gh`/`curl` |
| the deploy gate is otherwise unchanged | `bash tests/deploy-verify-fallback-test.sh` |
| a REAL proof (stubs prove the shape, not the endpoint) | on the next endpoint-project hotfix that defers, run the by-hand command above after the merge deploys, then read the ledger's `after_deploy` and both comments |

**Files it writes:**

- `$BUILD/hotfix-migrate.json` — the same ledger, gaining
  `after_deploy: {sha, status, files}` where `status` is `applied` or `failed`
  and `files` is the per-file status words. Written AFTER the apply it records,
  atomically (tmp + `mv`), preserving every other key.
- `$BUILD/hotfix-after-deploy.jsonl` / `.err` — the driver's own answer, verbatim.
- one more comment on the PR, first line
  `<!-- hotfix-migrate-afterdeploy fp=<fp> status=applied|failed -->`, then the
  driver's per-file JSON. A different marker from the pre-merge
  `hotfix-migrate-proof`, so the merge conductor's accept logic is untouched.
- on success, for a `board_prefix` `-` project with an OPEN issue: one issue
  comment naming the sha and the production URL, then `gh issue close`.
- on failure, ONE line in `logs/ALERTS.log`:
  `<stamp> [<project>] HOTFIX POST-DEPLOY APPLY FAILED (<sha8>): PR <url> files: <f=status,…> (build <dir>)`
  plus one `fleet_alert` beat keyed `hotfixafter:<project>:<sha>`.

**Knobs:** `HOTFIX_AFTERDEPLOY_RETRY_WAIT` (seconds, default 60) — the single
pause before the one retry when the `*/15` tick owns the driver's lock.

**What must never regress:**

- **It never closes an issue on SQL that did not apply.** Only the endpoint's
  literal `applied` / `already-applied` words are success; `refused`,
  `request failed`, `not-pending`, `busy`, an unreadable result line and
  `ok:true` beside a refusal are all `failed` — alert, ledger, exit 1, issue
  left open.
- **It never runs before the deploy is verified.** The hook sits in the
  deployments-API `OK` arm only, after the log line. The `SMOKE_ONLY` path never
  observed a successful deployment of the sha and does not call it.
- **It never masks the deploy verdict.** `bin/deploy-request.sh:22,27` read
  `deploy-verify.sh`'s exit code; this stage's rc 1 must not reach them.
- **An absent ledger is silent and free; an unparseable one is loud.** No ledger
  means this was not a hotfix build: exit 0 with zero API calls. Unreadable JSON
  exits 1 rather than guessing what happened to the SQL.
- **Nothing queues.** The driver's lock is `flock -n`; one pause, one retry, then
  an honest `busy` failure — the `*/15` tick will still apply the file.
