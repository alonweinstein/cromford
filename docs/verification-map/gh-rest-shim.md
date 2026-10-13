# `gh` REST shim

**What it is:** the `gh` entry point (`bin/gh-rest-shim`) that turns the
`gh pr|issue|run|repo` calls this harness makes into single REST requests, and
passes everything else through to the real binary with a log line. The
dispatcher resolves the real `gh`, provides a kill switch, passes
`api`/`auth`/`--version`/`help` through unlogged, sources
`bin/lib/gh-shim/*.sh` and dispatches to `gshim_cmd_<group>_<verb>`. It ships
the shared `gshim_*` helpers (`gshim_api`, `gshim_passthru`, `gshim_parse`,
`gshim_slug`, `gshim_fields_ok`, `gshim_emit`, `gshim_bodyfile`, `gshim_input`,
`gshim_paginate`, `gshim_tmp`).

The full contract — what each verb becomes, what the sub-fetches cost, the exit
codes, the knobs — is [../GH-REST.md](../GH-REST.md).

**How an operator reaches it:** they do not, yet. **The shim is on no PATH, on
any box or builder.** Nothing in `bin/update-runners.sh`,
`bin/bootstrap-machine.sh`, `bin/harness-sync.sh` or any `cron/` fragment
references it, and #790 closed without landing install logic. Installing it is
an operator procedure and a separate ticket:
`ln -sfn /root/harness/bin/gh-rest-shim /usr/local/bin/gh`, plus a `PATH=`
header for cron lanes, which no fragment under `cron/` carries today. Until
then every `gh` call on every box goes to the real binary, and
`$HARNESS/logs/gh-passthrough.log` does not exist on any box.

**Primary lanes / scripts:**
- `bin/gh-rest-shim` — the entry point: real-binary resolution, depth counter,
  kill switch, the shared helpers, dispatch.
- `bin/lib/gh-shim/pr-read.sh` — `pr view`, `pr list`.
- `bin/lib/gh-shim/pr-write.sh` — `pr create|edit|close|reopen|comment|review|diff|merge`.
- `bin/lib/gh-shim/issue-read.sh` — `issue view`, `issue list`.
- `bin/lib/gh-shim/issue-write.sh` — `issue create|edit|comment|close`.
- `bin/lib/gh-shim/actions.sh` — `run view|rerun|list`.
- `bin/lib/gh-shim/repo.sh` — `repo view`, `repo clone`.
- `bin/lib/gh-shim/read-maps.sh` — the jq mappers and the paging helpers the
  read handlers share.

21 handlers across those seven files. Two verbs the harness calls have no
handler and are not getting one: `gh pr checks --watch`
(`bin/hotfix-migrate.sh:72`) and `gh run watch --exit-status`
(`bin/lib/hotfix-migrate-workflow.sh:342`). A long-poll watch is not one REST
call. Both are listed in the census marked `!`, and the budget suite asserts
they pass through AND log it.

**Which suite proves which claim:**

| claim | suite |
|---|---|
| dispatcher, shared helpers, kill switch, depth cap, rate-limit classifier | `tests/gh-shim-translate.bh-787-test.sh` |
| `pr view` / `pr list` shape and the on-demand sub-fetches | `tests/gh-shim-pr-read-test.sh`, `tests/gh-shim-pr-read.bh-788-test.sh` |
| `issue view` / `issue list`, the `.pull_request` drop before `--limit` | `tests/gh-shim-issue-read-test.sh`, `tests/gh-shim-issue-read.bh-788-test.sh` |
| `repo view` / `repo clone`, no token in argv or git config | `tests/gh-shim-repo-test.sh`, `tests/gh-shim-repo.bh-788-test.sh` |
| `pr` write verbs, merge-queue pass-through, fork-branch refusal | `tests/gh-shim-pr-write.bh-789-test.sh` |
| `issue` write verbs | `tests/gh-shim-issue-write.bh-789-test.sh` |
| `run view` / `rerun` / `list` | `tests/gh-shim-actions.bh-789-test.sh` |
| no token prefix reaches argv or a log | `tests/gh-shim-token-prefix.bh-789-test.sh` |
| the pass-through budget and the census subset ratchet | `tests/gh-passthrough-budget.bh-791-test.sh` |

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/gh-passthrough-budget.bh-791-test.sh` —
  drives all 45 census lines through the real shim, asserts the pass-through
  log stays empty for the 43 translated ones, asserts the two `!` lines log at
  `depth=1`, and asserts every `gh <group> <verb>` in `bin/**/*.sh`, `catalog/`
  and `skills/` is in the census. Three mutation checks at the bottom.
- `HARNESS_TEST_SANDBOX=1 bash tests/gh-shim-translate.bh-787-test.sh` — the
  contract suite: real-binary resolution (including `$GH_REAL` pinned and
  unusable), kill switch, pass-through log, the `caller=` field, the rate-limit
  classifier with the reset time rendered exactly, the ten shared helpers, a
  200 KB page walk, dispatch via probe handlers, two mutation checks.
- `bash -n bin/gh-rest-shim` and `shellcheck --severity=error bin/gh-rest-shim`
  — CI names the file explicitly in `.github/workflows/harness-ci.yml`; the
  `bin/*.sh` globs miss it.

**Preconditions / seed needs:** none. Every suite builds its own scratch
environment; nothing reaches the network.

**Two deviations the shim header discloses:**
1. `GH_REST_SHIM_DEPTH` carries a counter and step 3 refuses at 3 (`exit 127`,
   "shim loop"), where the spec's bare `1` cannot tell a loop from a nest.
2. Real-binary resolution skips any PATH dir holding `_fence.sh` rather than
   walking past this script's own dir, and a `-R` that does not normalise to
   exactly `owner/repo` is discarded to the pass-through rather than spent as a
   doomed request.

**Verify it works:** `HARNESS_TEST_SANDBOX=1 bash tests/gh-passthrough-budget.bh-791-test.sh`
reports `196 passed, 0 failed`.
