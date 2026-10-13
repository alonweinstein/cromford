# GitHub PAT charge alert (the "App tokens everywhere" counter)

**What it is:** `bin/gh-pat-charge-alert.sh`, a hub lane at `17 * * * *`. For
the last complete UTC hour it reads the fleet's GitHub-call ledger — the same
`GET /api/metrics/gh-ledger?since=<hour>&until=<hour>` read that
`bin/gh-quota-report.sh --fleet` makes against the rows `bin/gh-ledger-push.sh`
upserts from every box — and keeps each (box, bucket) whose bucket (`meter`,
the ledger's column 10 from `gh_quota_bucket`) matches `^(graphql-)?pat-` with
COUNTED calls `>= GH_PAT_CHARGE_ALERT_MIN` (default 1). Each such pair gets ONE
`logs/ALERTS.log` line per UTC day:

```
PAT CHARGE on hub: 329 counted GitHub call(s) in 2026-09-24T10 UTC on pat-default = the gh keyring login (operator); top callers: blocked-resolver.sh 213, tickets-snapshot-push.sh 101, wake-loop.sh 11 (fleet ledger). Remedy: resolve an App installation token before the call — gh_default_auth_for_slug / gh_auth_for in bin/lib/gh-app-auth.sh. …
```

**Why it exists:** the fleet is moving to "App tokens everywhere, keyring logged
out". On 2026-09-24 the hub still charged ~330 calls/hour to `pat-default`
(gh's keyring login, operator) and five more boxes had PAT callers.
`gh-quota-report.sh` only reports when asked; this lane says it unprompted and
goes quiet when the last PAT caller is converted.

**How to drive it:**

| what | how |
|---|---|
| the suite (curl-stubbed worker, a `gh` stub that must never run) | `HARNESS_TEST_SANDBOX=1 bash tests/gh-pat-charge-alert-test.sh` |
| on the hub, once | `/root/harness/bin/gh-pat-charge-alert.sh; tail -1 /root/harness/logs/gh-pat-charge-alert.log` |
| re-check a given hour | `GH_PAT_CHARGE_ALERT_HOUR=2026-09-24T10 /root/harness/bin/gh-pat-charge-alert.sh` (a pair already alerted that UTC day stays deduped) |
| the whole picture | `bin/gh-quota-report.sh --fleet hour` |

**Knobs:** on the `gh-pat-charge-alert` lane: `GH_PAT_CHARGE_ALERT` (1; 0 =
off), `GH_PAT_CHARGE_ALERT_MIN` (1), `GH_PAT_CHARGE_ALERT_HOUR` (env only, a
re-check seam). Off: `flags/lane-off-gh-pat-charge-alert` or
`bin/harness-ctl.sh off gh-pat-charge-alert`.

**What must never regress:**

- **Zero GitHub API calls.** It reads harness-jobs and files only; the suite
  fails if `gh` runs or a github.com URL is requested.
- **No token value is ever written.** Only bucket labels (`pat-default`,
  `pat-<sha1 prefix>`), which are already non-credentials.
- **counted=0 is not a charge.** A 304 or 000 is ledgered with counted 0.
- **Once per (box, bucket, UTC day).** Marker
  `state/gh-pat-charge-alert/<day>/<box>__<bucket>`; earlier days are pruned.
- **Worker down is said, not silent.** The lane falls back to this box's own
  `state/gh-rest-ledger/<hour>.tsv`, logs `source=local why=…`, and the alert
  reads "this box's ledger only".
- **rc 0 always** from cron; one `logs/gh-pat-charge-alert.log` line per run.
