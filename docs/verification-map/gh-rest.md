# GitHub REST decision reads (`bin/lib/gh-rest.sh`)

**What it is:** the sourced library every decision path reads GitHub through.
It exists because of #768 (2026-09-18 02:49-03:05Z): the GraphQL-backed CLI got
rate-limited, answered an empty string, and the lane read that silence as "no
such PR" — five PRs rewritten RESULT_UNVERIFIED, TK-2302 launched three times.
So the library answers with three exit codes instead of one:

| rc | means | what the caller does |
|---|---|---|
| 0 | 2xx, body on stdout | act on it; an empty list (`[]`) is a real "nothing there" |
| 44 | HTTP 404 | ABSENT, act on it |
| 75 | unverifiable | 403/429 rate limit, any other non-2xx, 000/network, a malformed slug or number, or an EMPTY body on a 2xx GET. Skip this tick, log, change nothing. |

`GH_REST_STATUS` (three digits, `000` when no status line came back) and
`GH_REST_REASON` (`rate-limit` | `network` | `empty` | `bad-args` | empty) are
set in the shell that calls a helper.

**The caller rule:** when you need `GH_REST_STATUS` after a helper, run the
helper as a plain command with `> file` and read the file. A helper inside
`$( )` still returns the right rc, but its status stays in the subshell that
then died — that is BH-781's "every alert said HTTP 000 for a 403 the library
had classified correctly".

**The shape that makes the rule cheap (BH-1485).** The rule kept being broken
because writing it out is four lines and breaking it is eight characters: 21
call sites still read `st=$(gh_rest_pr_state …)`, so a rate limit, a 5xx and a
dead client all logged `HTTP 000` — including `bin/lib/mc/rebase.sh`'s
stack-parent read, through an hour of a measurably exhausted hourly quota.
`bin/lib/gh-rest-var.sh` (sourced from the end of `gh-rest.sh`) gives each
helper a variable-assigning variant — `gh_rest_var`, `gh_rest_pr_state_var`,
`gh_rest_pr_list_var`, `gh_rest_issue_state_var` — which does the
mktemp/redirect/read/rm in one place and returns the helper's own rc unchanged.
A converted site moves the variable from the left of the `=` to the front of the
argument list, and its log line reads `HTTP <status> <reason>`
(`HTTP 403 rate-limit`, `HTTP 000 network`). `tests/gh-rest-no-subshell-lint.sh`
fails on any `$(gh_rest…` under `bin/`, pinned at zero.

**How an operator reaches it:** no UI. The lanes below read through it.

**Converted lanes.** #781..#784 move the lanes onto these helpers, each adding
the `# gh-rest: no-graphql` marker to the file it converts. On the contract as
of BH-782 (#784's launch-gate slice): `bin/preplan-candidates.sh`,
`bin/triage-gate.sh`, `bin/overlap-guard.sh`, `bin/dep-verify.sh` and
`bin/lib/gh-pr-list.sh` — see [launch-gates-rest.md](launch-gates-rest.md) for
what each does with a 44 or a 75. `bin/blocked-resolver.sh` is converted too
(#783 — [blocked-resolver-rest.md](blocked-resolver-rest.md)). The remaining
siblings of #770 convert the rest (`bin/fly-pool.sh`, `bin/batch-resolve.sh`,
the conductor lib and the hotfix lanes).

**Primary lanes / scripts:**
- `bin/lib/gh-rest.sh` — `gh_rest`, `gh_rest_pr_state`, `gh_rest_pr_list`,
  `gh_rest_issue_state`, `gh_rest_comment`, `gh_rest_close`, `gh_rest_alert`.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/gh-rest-lib-test.sh` — 146 assertions: the
  status/rc matrix (both HTTP protos, CRLF headers, 403/429 rate-limit sniff,
  401/5xx/3xx, 000/network, empty-body-on-GET, `[]` vs `''`), malformed
  arguments with zero network calls, the five wrappers, the ALERTS line, temp
  file hygiene after every call (including a caller under `set -e`, which must
  reach 75 and leave nothing behind), and four mutants.
- `HARNESS_TEST_SANDBOX=1 bash tests/gh-no-graphql-decision-guard-test.sh` — the
  marker guard: a `bin/**/*.sh` carrying `# gh-rest: no-graphql` may not decide
  anything from `gh pr`, `gh issue` or `gh run` unless the line carries
  `# gh-guard-allow: <reason>`. The scanner peels `timeout …`, `NAME=value`,
  `env`, `if`/`while`/`!` and friends off a line and splits on a backtick as
  well as `$(`, so `$(timeout 20 gh pr view … --json state)` — the shape
  `bin/triage-gate.sh` and `bin/lib/revdep-lib.sh` really write — is a hit, not
  a miss. A tree with no marked file exits 2, never 0.
- `bash -n bin/lib/gh-rest.sh` and `shellcheck --severity=error bin/lib/gh-rest.sh`
  — both run for every `bin/**/*.sh` in `.github/workflows/harness-ci.yml`.

**Preconditions / seed needs:** `jq` on PATH. The suites need nothing else:
`gh` is a stub that replays fixture responses, so no token and no network.

**Verify it works on a box with `gh` authenticated** (read-only, four REST
reads, no writes):

```bash
. bin/lib/gh-rest.sh
gh_rest_pr_state example-org/cromford 794 > /tmp/o; echo "rc=$? status=$GH_REST_STATUS"; cat /tmp/o
gh_rest_issue_state example-org/cromford 999999999 >/dev/null; echo "rc=$?"
```

Observed 2026-09-19 15:27Z on the hub: `rc=0 status=200` and `closed` for the
first (PR #794 is closed), `rc=44` for the second, and no `gh-rest.*` file left
in `$TMPDIR`.

**Manual-only / not automatable:** nothing here. There is no screen: this is a
sourced shell library.
