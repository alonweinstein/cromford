# Connecting a board

Cromford talks to every tracker through one set of verbs: list, read, comment,
transition, add and remove a label, link a PR, and close out. Each tracker has
an adapter for those verbs under `bin/lib/tracker/`, and
[bin/lib/tracker.sh](../bin/lib/tracker.sh) picks one per project.

A project uses the tracker it was enrolled with. To pick another, set the
settings row `tracker_adapter.<project>` to `github-issues`, `board`, `jira` or
`linear`. Any other value is refused. Settings rows are written with
`bin/jobs-client.sh setting-set <key> <value>`.

This page names settings and credentials only. Their values live under
`/etc/harness/env/` on the box, never in a settings file or a log.

## GitHub Issues

This is the default, and it needs nothing beyond your GitHub credential.

- **Reads:** open issues labeled `ai-build`, with their comments and labels,
  over GitHub's REST API.
- **Writes:** comments, labels, and open or closed state. Linking a PR is a
  `PR: <url>` comment, because issues have no PR-link field.
- **Credential:** the GitHub App or the token from your setup
  (`GH_APP_ID` and `GH_APP_PRIVATE_KEY_FILE`, or `GH_TOKEN`). See the
  [deployment guide](SELF-HOST.md#2-what-you-need).
- **Webhook:** the jobs worker takes GitHub deliveries at
  `POST /webhooks/github`, signed with `GITHUB_WEBHOOK_SECRET`.

GitHub has no "waiting on" or triage verdict fields, so the adapter reports
them as empty instead of guessing.

## Jira Cloud

Source: [bin/lib/tracker/jira.sh](../bin/lib/tracker/jira.sh).

- **Reads:** issues from a bounded JQL search, and their comments, over REST v3
  through Atlassian's gateway (`https://api.atlassian.com/ex/jira/<cloudId>`).
  Jira Server and Data Center are not supported.
- **Writes:** comments, labels and transitions. It asks Jira which transitions
  exist, so no status name is hard-coded. Linking a PR is a `PR: <url>` comment.
- **Credentials**, in the project's env file: `JIRA_BASE`, `JIRA_EMAIL`,
  `JIRA_API_TOKEN`, and optionally `JIRA_SITE`.
- **Settings rows:** `tracker_jira.<project>.write_projects`,
  `comment_projects` and `read_projects` are allowlists of Jira project keys.
  Also `label` (default `ai-build`), `waiting_on_field`,
  `triage_verdict_field` and `status_map`.

The allowlist is a hard guard. With no write row, nothing is written. Before
every write the adapter reads the issue back and refuses unless Jira answers
with the same key in the same project.

**Not yet:** today only the readiness check reads Jira tickets through this
adapter. The rest of the pipeline doesn't drive a Jira project end to end.

## Linear

Source: [bin/lib/tracker/linear.sh](../bin/lib/tracker/linear.sh).

- **Reads:** your team's open issues with a label (default `ai-build`), over
  Linear's GraphQL API.
- **Writes:** comments, labels and state. Linking a PR is a real Linear
  attachment. Labels are never created, so a label your workspace doesn't have
  is an error.
- **States:** mapped by Linear's state type (unstarted, started, completed,
  canceled). Review is the state named "In Review".
- **Credential**, in the project's env file: `LINEAR_API_KEY`, a Linear
  personal API key. A key in `global.env` is not used.
- **Settings rows:** `tracker_linear.<project>.team` is your team key, such as
  `TK`, and it is required. `label` (default `ai-build`) and `states` are
  optional. `states` is a JSON object from `todo`, `in_progress`, `review`,
  `done` or `closed` to one of your state names, for example
  `{"review":"QA"}`.

To move a project from GitHub Issues to Linear:

```bash
echo 'LINEAR_API_KEY=<key>' >> /etc/harness/env/<project>.env
bin/jobs-client.sh setting-set tracker_linear.<project>.team TK
bin/jobs-client.sh setting-set tracker_adapter.<project> linear
```

Set `tracker_adapter.<project>` back to `github-issues`, or delete the row, to
return to GitHub Issues. A project has one tracker at a time.

**What works today:** the triage gate reads your Linear team, not GitHub. Its
board fingerprint is the open issues carrying the build label, so a new issue,
a state or label change, a description edit or a new comment from a person
wakes the triage tick, and the key's own comments do not. `--thread` and
`--signal` read the Linear thread. The launch check (`--buildable`) blocks a
ticket whose newest comment is the key's own. Only issues of your team are
ever read. An env file that sets `LINEAR_API_KEY` to nothing, or rows that do
not load, make every tick `SKIP token-unresolved` with one ALERTS line a day.

**Not yet:** a build can't run from a Linear issue. While the row says `linear`, `bin/run-build.sh` refuses the project, and
the close-out and needs-human lanes post nothing to GitHub. Without that
refusal they would treat `TK-142` as GitHub issue #142. The same refusal
applies to a `jira` row.

Every other lane is stopped one level lower: `bin/gh-ledger/gh`, the `gh` first
on every lane's PATH, refuses a GitHub issue write (create, comment, close,
edit, labels, by `gh issue -R` or `gh api` on `repos/<repo>/issues…`) on the
repo of a project whose row is `jira` or `linear`, with one ALERTS line. Writes
on a pull request number still go through. `flags/tracker-gh-guard-off` turns
it off.

## Webhooks for Jira and Linear

Without webhooks, Cromford polls. With them, a real change wakes triage right
away. The jobs worker takes `POST /webhooks/jira` and `POST /webhooks/linear`
([source](../worker/jobs/src/lib/tracker-webhooks.js)). Each checks its own
signature and drops repeat deliveries. Changes made by the accounts listed in
`webhook_self.jira` or `webhook_self.linear` are ignored.

Both are off until you arm them:

1. Set the worker secret `JIRA_WEBHOOK_SECRET` or `LINEAR_WEBHOOK_SECRET`.
2. In Jira or Linear, add a webhook to `https://<jobs-host>/webhooks/jira` (or
   `/webhooks/linear`) with the same secret.
3. Set the row `webhook_route.jira.<project key>` or
   `webhook_route.linear.<team key>` to your repo as `owner/repo`.

Before step 1 a delivery gets a `503`. After it, a bad signature gets a `401`,
and a delivery with no route row is accepted and does nothing.
