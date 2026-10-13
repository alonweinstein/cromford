# Jira Cloud tracker adapter (`bin/lib/tracker/jira.sh`)

**What it is:** the third adapter of the tracker contract
([tracker-adapter.md](tracker-adapter.md)), BH-4076, wave 3 of BH-3979.
Functions `trk_jira_*` answer the contract's verbs (`list`, `read`, `comment`,
`transition`, `label_add`, `label_remove`, `link_pr`, `close_out`) against Jira
Cloud REST v3. It is sourced, never run. Jira Server/Data Center is not
supported.

**How an operator reaches it:** no cron line and no screen. A project uses it
when its settings row `tracker_adapter.<project>` is `jira` (fleet.conf column 4
never yields `jira`). Today the readers are `bin/triage-gate.sh
--buildable[-strict]` (through `tracker_waiting_on` or directly) and
`file_children`, which answers `FILE_CHILDREN no child-filing lane for jira
(<project>)` and files nothing. No fleet project is on Jira yet.

**Context:** `trk_jira_context <project>` is the only thing that sets
`TRK_JIRA_*`, and it blanks them all first, so an inherited value never widens
an allowlist. Root is `HARNESS` (or `H`); no root, no context.

- Credentials come from `<env dir>/<project>.env` only: `JIRA_BASE`
  (must be `https://api.atlassian.com/ex/jira/<cloudId>`), `JIRA_EMAIL`,
  `JIRA_API_TOKEN` (a scoped API token; Basic auth), optional `JIRA_SITE`
  (`https://<name>.atlassian.net`, used only for `url`, else `url` is null).
- Settings rows (all optional, ≤ 256 chars; `rc 2` no row = the fallback):

| row | value | absent |
|---|---|---|
| `tracker_jira.<project>.write_projects` | project keys every verb may touch | no writes at all |
| `tracker_jira.<project>.comment_projects` | keys where only `comment`/`link_pr` may write | none |
| `tracker_jira.<project>.read_projects` | keys `list`/`read` may touch (write and comment keys are readable too) | only those |
| `tracker_jira.<project>.label` | the build label `list` filters on | `ai-build` |
| `tracker_jira.<project>.waiting_on_field` | `customfield_<n>` | waitingOn null |
| `tracker_jira.<project>.triage_verdict_field` | `customfield_<n>` | triageVerdict null |
| `tracker_jira.<project>.status_map` | `alias=Jira Status;alias=Jira Status` | status args are Jira status names |

  A key that is not `[A-Z][A-Z0-9_]{1,9}`, a bad label or field id, a malformed
  status_map, or a worker that did not answer fails the context (rc 1, one
  stderr line naming the row), and then every verb answers 1 before any request.

```bash
bin/jobs-client.sh setting-set tracker_adapter.<project> jira "why"
bin/jobs-client.sh setting-set tracker_jira.<project>.write_projects SANDBOX "sandbox only"
```

**The guard:** every verb takes an issue KEY (`CROM-12`; numeric ids, lowercase,
whitespace and anything else are refused with no request). Its project must be
on the tier's list: write verbs (`transition`, `label_*`, `close_out`) need
`write_projects`; `comment`/`link_pr` need write or comment; reads need any of
the three. A write then GETs the issue and refuses unless Jira answers with the
same key in the same project, because Jira answers a moved issue's old key with
the new issue. A refused write in a dry run is still rc 1 and prints no DRYRUN
line. Refusals print `jira: <KEY> is in project <P>, not on <project>'s <tier>
allowlist`.

**Return codes:** the contract's. HTTP 2xx 0; 401/403 1 with a stderr line
naming the credential variables; other 4xx 1; 429, 5xx, no answer 75.
`transition` to a status no transition leads to is 3 with no write; two
transitions to the same status is 1 (never picks); a 204 whose status did not
move is 1. `close_out` resolves its transition first (the given status, else
the `done` alias, else the one done-category transition), so it posts nothing
when it cannot move the issue. `label_remove` of a label the issue lacks is 44
with no write. `list` past 4 pages of 50 is 1 (`list incomplete`); a thread of
200+ comments is 1 (`not read to the end`).

**How to drive it** (no network, gateway stub `tests/lib/tracker-jira-stub.sh`,
fixtures `tests/fixtures/tracker-jira/`):

| what | how |
|---|---|
| the eleven contract cases for Jira | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-contract-test.sh` |
| the sandbox guard | `HARNESS_TEST_SANDBOX=1 bash tests/jira-sandbox-guard-test.sh` |
| JQL, paging, ADF, transitions, the triage gate | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-jira.bh-4076-test.sh` |

**What a live box shows:** nothing yet. With `TRK_LOG` set, every write is
logged as `curl -X <M> <path> auth=Basic($JIRA_EMAIL:$JIRA_API_TOKEN)`.

**What usually lies:**

- The fixtures are hand-written to Atlassian's documented v3 shapes, not
  recorded from a sandbox site; no site or token exists on any box yet.
- `link_pr` is a `PR: <url>` comment, not a Jira remote link.
- Jira tickets have no dependency read in the gate: in-app `Blocked by` text and
  Jira issue links are not checked.
- The triage tick's RUN/SKIP fingerprint for a Jira project is the generic arm's
  (no Jira fingerprint); only `--buildable[-strict]` reads Jira.
- A failed `/myself` in the gate does not discard the fields: waitingOn and
  triageVerdict still block, and only the newest-comment check falls to the
  unreadable answer.
- A transition verify GET that fails after a 204 returns its own rc (75 on a
  429/5xx), not the "did not move" rc 1.
- A comment that posts but whose answer is lost is 75, and a retry can post it
  twice; Jira has no idempotency key for comments.
- In a dry run `label_remove` prints its DRYRUN line without checking the label
  is there, the same as the GitHub adapter.
