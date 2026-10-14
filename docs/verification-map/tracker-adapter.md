# Tracker contract and adapters (`bin/lib/tracker.sh`)

**What it is:** one set of ticket verbs every tracker answers the same way
(BH-4075, wave 2 of BH-3979): `list`, `read`, `comment`, `transition`,
`label_add`, `label_remove`, `link_pr`, `close_out`, `waiting_on`. The contract
and the dispatch live in `bin/lib/tracker.sh`. Each tracker is one adapter file:
`bin/lib/tracker/github-issues.sh` (functions `trk_gh_*`, every call through
`bin/lib/gh-rest.sh`), `bin/lib/tracker/board.sh` (functions `trk_board_*`,
the board routes in `docs/BOARD-API-CONTRACT.md`), `bin/lib/tracker/jira.sh`
(Jira Cloud, BH-4076, see [tracker-jira.md](tracker-jira.md)) and
`bin/lib/tracker/linear.sh` (functions `trk_linear_*`, Linear's GraphQL API,
BH-4077; see the Linear section below). It is sourced, never run.

**How an operator reaches it:** no cron line and no screen of its own. Today the
one reader of the adapter choice is `file_children` in `bin/lib/file-children.sh`,
which picks the child-filing lane from `tracker_adapter <project>`. The two lane
modules call the adapters for the parent ticket: `bin/lib/fc-issues.sh` reads the
parent's labels (`trk_gh_labels`, one GET), posts the split comment
(`trk_gh_comment`) and removes `ai-build` (`trk_gh_label_remove`);
`bin/lib/fc-board.sh` sends every board call through `_trk_board_curl` and reads,
comments on and moves the master with `trk_board_ticket_raw`,
`trk_board_comment` and `trk_board_transition`. The triage lane,
`bin/board-closeout.sh` and the prompts still make their own calls.

**Which tracker a project uses** is the D1 settings row
`tracker_adapter.<project>`, value `github-issues`, `board`, `jira` or
`linear`. There is no seed row. When there is no row, or the worker did not
answer, the fallback is fleet.conf column 4: `-` is `github-issues`, a board
prefix is `board`; only a row selects `jira` or `linear`. A row of `jira` or
`linear` reaching `file_children` logs `FILE_CHILDREN no child-filing lane for
<adapter> (<project>)`, returns 1 and files nothing on any tracker. A row with
any other value (`jira-server`, `Board`, `github`) is refused: `tracker_adapter`
returns 1 with one stderr line naming the row, and `file_children` logs
`FILE_CHILDREN tracker adapter unresolved for <project>` and files nothing.

```bash
bin/jobs-client.sh setting-get tracker_adapter.<project>          # rc 2 = no row
bin/jobs-client.sh setting-set tracker_adapter.<project> board "why"
```

**Return codes**, the same for every adapter: `0` ok; `1` failed (absent
ticket, refused write, a 200 that did not take); `3` this tracker does not
support the verb and nothing was sent; `44` `label_remove` only, the label was
not there (success); `75` rate-limited or unverifiable, passed through from
`gh_rest`, retry later.

**Context** is variables, never arguments: `TRK_SLUG` (GitHub),
`TRK_BOARD_BASE` / `TRK_BOARD_TOKEN` / `TRK_BOARD_TOKEN_VAR` (board), `TRK_LOG`,
`TRK_ERR`, `TRK_DRY` (1 = every write prints `DRYRUN <line>` and sends nothing),
`TRK_REQ_FILE`, `TRK_STRICT`.

**How to drive it** (no network, stubs on PATH):

| what | how |
|---|---|
| the eleven contract cases against both adapters | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-contract-test.sh` (cases in `tests/lib/tracker-contract.sh`) |
| the settings-row dispatch and the port's byte identity | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-port.bh-4075-test.sh` |
| a real dry run of a board split, filing nothing | `FILE_CHILDREN_DRY_RUN=1 bin/run-rollout.sh <board-project> <ticket-id> <KEY> /tmp/rollout-dry` |

The port suite compares the board lane's `decompose-board.log`,
`children/comment.json`, `children/move.json` and call list, and the issues
lane's gh call sequence, against goldens in `tests/fixtures/tracker-port/`
captured from the pre-port tree (`0dab314`) by the suite's own
`TRACKER_PORT_REGEN=<ref>` mode.

**What a live box shows:** nothing new in a build directory except
`children/comment.html` beside `comment.json` on a board split (the body the
adapter turns into the comment request). `decompose-board.log` and
`decompose-gh.log` read exactly as before.

**What usually lies:**

- No row is not an error. Every project runs on the fleet.conf fallback today.
- No root, no row: with neither `HARNESS` nor `H` set, the row is not read at
  all (the client's own default root is the live `/root/harness`, which a lib
  never reaches), and the answer is the fleet.conf fallback.
- A worker outage is silent here: `tracker_adapter` uses the fallback and
  `bin/jobs-client.sh` logs the outage to `logs/jobs-client.log` (with
  `JOBS_ALERT=0`, so no ALERTS line from this reader). A row that says `board`
  on a project the worker cannot reach is filed on the fleet.conf lane.
- A row of `board` on a `-` project routes to the board lane, which then fails
  closed with `no board base` because the project has no board. That is the
  honest outcome; the row is not "fixed up" from fleet.conf.
- `link_pr` is a comment on GitHub and the board (`PR: <url>`) and a real
  attachment on Linear. Nothing calls it yet.
- `waiting_on` is `bin/triage-gate.sh --buildable` verbatim. GitHub Issues has
  no turn or verdict, so it answers `OK` unless a contested hold blocks it.
- GitHub's `tracker_read` refuses (rc 1) a thread at the 200-comment read cap
  rather than decide on a truncated thread.

## Linear (`bin/lib/tracker/linear.sh`, BH-4077)

Every call is one POST of `{query, variables}` to `TRK_LINEAR_API` (default
`https://api.linear.app/graphql`), with `Authorization: <key>`: a personal API
key, no `Bearer`. One lane calls it: `bin/triage-gate.sh --buildable[-strict]`
reads a Linear project's ticket with `trk_linear_gate_raw`. Triage, run-build
and close-out still make their own GitHub calls, so they refuse a Linear
project (`tracker_off_github`, below), and so does `file_children`.

**A project's context** is `trk_linear_context <project>`: `LINEAR_API_KEY`
from `<env dir>/<project>.env` only, and the settings rows
`tracker_linear.<project>.team` (required), `.label` and `.states`. It blanks
every `TRK_LINEAR_*` first. A missing key, no team row, a malformed row or a
settings outage is rc 1 with one stderr line and a blank context.

**The gate read** (`trk_linear_gate_raw <identifier>`) is one request for the
viewer and the issue's comments. It sends only an identifier of the context's
team and refuses an answer from another team (Linear answers a moved issue's
old identifier with the new issue). A comment by the key's own account is
internal, which is what `BLOCKED newest-comment-system` reads. A thread past
250 comments is rc 1. The gate takes this arm only when the env file sets
`LINEAR_API_KEY` and the row is `linear`; a context that does not load is
`BLOCKED token-unresolved`.

**`tracker_off_github <project>`** (in `bin/lib/tracker.sh`) answers rc 0 and
the adapter when the row is `jira` or `linear`. Such a project still sits at
fleet.conf column 4 `-`, and the GitHub-Issues lanes strip `TK-142` to issue
#142. `bin/run-build.sh` exits 2 with an ALERTS line before it creates
anything, `bin/board-closeout.sh` exits 4 and `bin/needs-human-hold.sh` exits 0,
each without a GitHub call. A settings outage answers rc 1 (GitHub), as before.

**Context:** `TRK_LINEAR_TOKEN` (the key, only on curl's argv),
`TRK_LINEAR_TOKEN_VAR` (its name, which is what `TRK_LOG` shows),
`TRK_LINEAR_TEAM` (the team key; `list` needs it, the other verbs do not),
`TRK_LINEAR_LABEL` (the list filter, default `ai-build`), `TRK_LINEAR_STATES`
(optional JSON from contract status to state name), plus the shared `TRK_LOG`,
`TRK_ERR`, `TRK_DRY`, `TRK_REQ_FILE`.

**Ids:** the Linear identifier (`CRO-12`) or the issue UUID. `id` and `key` are
both the identifier. Every write reads the issue first (UUID, labels, team
states), and that read is sent even in a dry run.

**Status:** `todo|in_progress|review|done|closed`, anything else is 3. A name in
`TRK_LINEAR_STATES` wins, case-insensitive; a name the team has no state for is
1 and nothing is sent. Otherwise by state type, lowest `position` first:
`todo` = unstarted, `in_progress` = started, `done` = completed, `closed` =
canceled, and `review` is the state named "In Review". `close_out` moves to
`done` by default. A 200 whose issue did not land in the target state is 1.

**Return codes:** 429, 5xx, no answer, or a `RATELIMITED` error on any status
(Linear sends it on a 400) is 75. Any other 4xx, a 200 whose `errors` is not
empty (an unknown issue answers `Entity not found` that way), or a mutation
answering `success: false` is 1. `list` follows up to 10 pages and is 1 if
there are more; `read` is 1 when the thread has more than 250 comments.

**Labels:** a workspace label or one of the issue's team, matched
case-insensitively; a label only on another team, or no such label, is 1. The
adapter never creates a label. `label_remove` of a label the issue does not
carry is 44.

**`link_pr`:** `attachmentLinkURL` with the title `PR #<n> <owner/repo>`. Only a
`https://github.com/<o>/<r>/pull/<n>` URL; anything else is 1, nothing sent.

**`waiting_on`** is the shared one: `OK` unless a contested hold blocks it.
Linear has no waiting-on-client turn, and its Asks / triage inbox are out of scope.

| what | how |
|---|---|
| the contract cases and the Linear-only cases, against hand-written GraphQL answers | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-linear.bh-4077-test.sh` (answers in `tests/fixtures/tracker-linear/`) |
| the project context, the gate arm and the three refusals | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-linear-context-test.sh` (answers in `tests/fixtures/tracker-linear-context/`) |
| live, against the test workspace (needs its key) | the block below |

```bash
export HARNESS=/root/harness
. bin/lib/tracker.sh; tracker_load linear
trk_linear_context <project>   # needs the tracker_linear.<project>.team row
tracker_list; tracker_read <KEY-n>; tracker_comment <KEY-n> f; tracker_link_pr <KEY-n> <PR url>; tracker_close_out <KEY-n> f
```

**What usually lies:** the fixtures are written to Linear's documented schema,
not recorded from a workspace; the list filter (`labels: { some: { name:
{ eqIgnoreCase } } }`) is the first thing to check if a live `tracker_list`
comes back empty.
