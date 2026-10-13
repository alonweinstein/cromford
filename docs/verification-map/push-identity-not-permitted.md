# Push identity not permitted (`IDENTITY_NOT_PERMITTED`)

**What it is:** GitHub answers `mergeStateStatus: BLOCKED` for two different
facts, and the merge lanes used to read only one of them. When something on the
base branch gates the merge — a required status check, a required review,
required conversation resolution, a branch lock — `BLOCKED` means the PR is not
ready and waiting is right. When **nothing** gates it, there is no context to
wait for: the branch restricts *who may push* and the token the lane runs on is
not on that list. Nothing that happens to the PR will ever change that, so the
lanes now say so by name instead of retrying.

**The incident (BH-800, 2026-09-18):** the hub ran on a GitHub App installation
token. `example-org/cromford`'s `main` requires no check and no review, but
its protection restricts pushes to human logins. For 40 minutes
`bin/merge-sweep.sh` wrote 42 identical `skipped: mergeState=BLOCKED (will
retry)` lines while `bin/merge-conductor.sh` wrote `mergeState BLOCKED (required
context not green)` about a branch with `required_status_checks = null`, and
spent the BH-636 flake ladder — a second `actions/runs` read per row, a CI
re-run at rung 0 — on every one of them. Nothing named the token. Nothing paged.

**How an operator reaches it:** the two hub cron lanes. There is no UI.
- `cron/hub.cron:52` (`6,16,26,36,46,56`) → `bin/merge-sweep.sh`
- `cron/hub.cron:58` (`*/5`) → `bin/merge-conductor.sh`

**Primary lanes / scripts:**
- `bin/lib/gh-push-identity.sh` — the shared classifier: `gh_token_identity`,
  `gh_branch_protection`, `gh_push_blocked_verdict`, `gh_push_allowlist_summary`,
  `gh_identity_alert`. Both lanes source it and both behave exactly as they did
  before BH-800 when it is absent.
- `bin/merge-sweep.sh` — the `# >>> identity not permitted` block in the
  non-`CLEAN` branch, on a `gh pr view` read that now also carries
  `baseRefName`.
- `bin/merge-conductor.sh` — the `# >>> identity block` immediately before the
  flake ladder; the ladder and BOTH close/reopen CI kicks — the stuck detector's
  and the one a head with no workflow run at all gets — are guarded on its
  answer. None of the three can add a push permission.
- `bin/lib/mc/classify.sh` — `mc_classify`'s `UNSTABLE|BLOCKED` arm
  reads the named variable `MC_IDENTITY_BLOCKED` / `MC_IDENTITY_WORD`.

**The four verdicts** (`gh_push_blocked_verdict`, from the protection document):

| verdict | when | what the lane does |
|---|---|---|
| `protected` | a required check, a required review, `required_conversation_resolution.enabled` or `lock_branch.enabled` is set | exactly today's behaviour: the bare skip line / `mergeState BLOCKED (required context not green)`, and the flake ladder runs as it always has |
| `allowlisted` | nothing gates the merge AND this identity IS in `restrictions` | retry, and say the identity is on the list so the cause is somewhere we cannot see (a ruleset, a queue). No page. |
| `identity` | nothing gates the merge, there IS a `restrictions` list, and this identity is not on it | the distinct line, one ALERT per (lane, repo, identity, UTC day), no flake rerun, no CI re-kick, no ledger row, no merge attempt |
| `unexplained` | nothing gates the merge and there is **no `restrictions` block at all**, or the identity could not be named (`unknown`) | the bare line annotated `— branch protection unexplained`. **Never paged**: there is no allow-list to be absent from, so telling an admin to add somebody to one would be an invented instruction. |

The App list and the user list are compared separately: `app/<slug>` and
`<slug>[bot]` are matched against `restrictions.apps[].slug` only, and every
other identity against `restrictions.users[].login` only. A *user* named
`cromford` does not allow-list the `cromford` **App**, and an App slug
does not allow-list a same-named PAT.

A protection read that fails is never a verdict: 403 on every rung of the token
ladder annotates the bare line with `— branch protection unreadable 403`, 404
with `— branch protection unprotected`, an rc-0 body that is not JSON with
`— branch protection unreadable unparseable`, and none of them page. Everything
the read cannot settle leaves both lanes exactly as they behave today — the
feature can add a line and an alert, never silently swallow a row.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/gh-push-identity.bh-800-test.sh` — the
  classifier, the token ladder, the alert dedup (including the next-UTC-day
  rollover) and the no-token-in-any-artifact rule.
- `HARNESS_TEST_SANDBOX=1 bash tests/merge-sweep-identity.bh-800-test.sh` — the
  sweep script run whole against a scratch `$HARNESS` with a fake `gh`.
- `HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-identity.bh-800-test.sh` —
  `mc_classify` directly, then `bin/merge-conductor.sh` run whole, including one
  case with the actions flag ON so the refused close/reopen is a real assertion.

**Preconditions / seed needs:** none beyond the fixtures. On a live box the lane
needs a repo whose base branch has `required_status_checks == null`,
`required_pull_request_reviews == null`, neither toggle on, and a `restrictions`
block the running identity is not in.

**What a live box shows:**
- `logs/merge-sweep.log`:
  `<pr> IDENTITY_NOT_PERMITTED <slug> <identity>: mergeState BLOCKED on <base>
  with no required checks and no required reviews — this identity cannot push to
  <slug> (push allow-list: …)`
- `logs/merge-conductor.log`: the same line per row, and
  `state/merge-conductor/pr-state.tsv`'s reason column beginning
  `IDENTITY_NOT_PERMITTED <identity>:` with the state still `WAIT_CI`.
- `logs/ALERTS.log`: exactly one line per (lane, repo, identity, UTC day).
- `flags/alerted-identity-not-permitted-merge-sweep-example-org_cromford-app_cromford-<yyyymmdd>`
  (the sweep's dedup marker) and an `identityalert <slug> <identity> <yyyymmdd>`
  line in `state/merge-conductor/attempts.txt` (the conductor's).
- `state/merge-conductor/tick/<tick>.idv-<slug_base>` — the per-tick verdict
  cache that holds the protection read to one per repo per tick. The PR workers
  are concurrent subshells (`MC_PR_PARALLEL` defaults to 0 = unlimited), so the
  file is written and read inside one `flock` on itself: without that, every
  worker of the repo starts in the same second, finds no file and buys its own
  read — and one that read the file mid-write would come back empty and run the
  flake ladder anyway.

**Why the row stays `WAIT_CI`:** `BLOCKED_HUMAN` feeds `bin/blocked-resolver.sh`,
whose ladder ends in a closed PR. Closing every approved PR of a repo because a
config row is missing is a worse outcome than holding them, so only the reason,
the ladder skip, the two CI-kick skips and the alert change.

**The operator audit** — what each repo the harness merges into actually
requires, and who may push to it:

```
# The repo list comes from fleet.conf, never from a list typed into this file —
# the slugs there are the ones the lanes actually merge into.
for R in $(awk '!/^#/ && NF {print $2}' /root/harness/fleet.conf); do
  echo "== $R"
  gh api "repos/$R/branches/main/protection" \
    -q '{users:[.restrictions.users[]?.login], apps:[.restrictions.apps[]?.slug],
         checks:.required_status_checks, reviews:.required_pull_request_reviews}'
done
```

A repo whose `apps` is empty while `users` is set is one where an App-identity
merge cannot land. The fix is a repo admin adding the App to
`repos/<slug>/branches/main/protection/restrictions/apps` — this box holds no
authority to do it, which is why the condition pages instead of retrying.

**Manual-only / not automatable:** the audit above and the allow-list change
itself need a token with `Administration: read` (audit) and a repo admin
(change). Neither is something a build session may do.
