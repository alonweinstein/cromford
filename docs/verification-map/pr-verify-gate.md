# Reap-time PR_CREATED verification (a failed read is UNKNOWN, never a state)

**What it is:** when the pool reaps a finished build whose `RESULT` first line
says `PR_CREATED <url>`, it checks the SHAPE of that url and then asks GitHub
whether the PR really exists before the result is handed on. A PR that is OPEN or MERGED passes untouched. A PR that
GitHub affirmatively says is gone (REST 404, with the repo itself visible to the
same token) or closed-unmerged has its first line rewritten to
`RESULT_UNVERIFIED PR_CREATED …`, which no close-out handler matches, plus one
ALERTS.log line for the alert medic. That rewrite is the irreversible,
operator-visible action in this lane: it strands a real PR from every close-out
path, so everything here is built around never doing it on a guess.

**The shape check comes first (BH-765, 2026-09-18):** a first line that claims
`PR_CREATED` but carries no PR url in field 2 — four project-5 builds wrote
`PR_CREATED  | SIZE: 614 product lines … | STACKED on ticket/TK-2212` — is a
BUILDER defect, decided from the line, before any credential is involved. It is
rewritten `RESULT_MALFORMED <original line>` with one alert that says the
builder wrote a url-less claim and that no gh call was made. Before this, field
2 came out as the literal `|`, the reader answered `UNKNOWN unparseable-url`,
and the alert blamed a gh token that was working fine while the first line
stayed `PR_CREATED  | …` — which `bin/blocked-resolver.sh` reads as
rebuild-landed and `bin/board-closeout.sh` (`PR_CREATED http*`) never matches.
`bin/run-build.sh`'s result ratchet (#749) refuses to WRITE such a line; this is
the read side, for machine images that predate it.

**Which credential it verifies with (BH-765):** `bin/lib/gh-repo-token.sh`,
sourced at the top of `bin/fly-pool.sh` — the App installation token first when
the box is armed, then the default PAT, then the org-admin one. The gate no
longer reads `env/github-admin.env` itself, so it stops spending the one
org-admin bucket on repos the other two can see. When the seam answers `none` no
PR read is made at all: a 404 from a credential that cannot see the repo is the
2026-09-12 shape and may never be read as "no such PR".

**Why it reads REST (BH-709, 2026-09-17):** the check used
`gh pr view --json state`, which is GraphQL. The org-admin PAT's GraphQL budget
is chronically exhausted on this fleet, so the view exited non-zero, the state
came back empty, and the empty string was compared against `OPEN` as if it were
a state. 75 alerts across 17 tickets in one day blamed "a builder death" for
PRs that were open the whole time — PR 707 was open 2m23s before its own alert.
The read is now REST (`gh api -i repos/<slug>/pulls/<n>`, a different budget)
and **the HTTP status is read before the body is interpreted**.

**The reader is the fleet's contract, and it asks ONCE (BH-781, 2026-09-19):**
`bin/fly-pool.sh` no longer carries its own REST reader. It sources
`bin/lib/gh-rest.sh` and calls `gh_rest_pr_state`, whose three exit codes are
the whole vocabulary — `0` act on the body, `44` an affirmative 404, `75`
UNVERIFIABLE. The two-try loop and its pause are gone with it: `75` means "skip
this tick, leave state exactly as it is", and the next `*/10` reap is the retry.
A second in-tick read would spend a request on the same rate limit and leave
`GH_REST_STATUS` ambiguous for the alert that follows. The credential is armed
for the whole block (`gh_repo_use_token` before the read, `gh_repo_token_reset`
after) because the library reads the AMBIENT `gh` auth.

**How an operator reaches it:** there is no UI and no command to run by hand.

| lane | where it lives | when it acts |
|---|---|---|
| the gate, its url shape check, the one-read verify block, and the library it sources | `bin/fly-pool.sh` — `# >>> pr verify gate (BH-709)`, `# >>> pr url shape (BH-765)`, `# >>> PR_CREATED verify` (BH-781) and `# >>> pr verify rest (BH-709)`, which now holds only the guarded source of `bin/lib/gh-rest.sh` | `cron/hub.cron` `*/10 * * * * bin/fly-pool-tick.sh`, inside the reap loop, once per reaped build whose RESULT says `PR_CREATED` |

**How to drive it:** `bash tests/fly-pool-pr-verify.bh-781-test.sh`,
`bash tests/fly-pool-pr-verify-rest-test.sh` and
`bash tests/fly-pool-prurl-shape-test.sh` (exit 0 = all pass; each wants
`HARNESS_TEST_SANDBOX=1` when it runs as root next to a live `/root/harness`).
Each extracts the marked blocks verbatim, runs them against a `mktemp -d`
`$HARNESS` with a stub `gh` on PATH, and asserts on the artifacts: the first
line of `$LOCAL/RESULT` and the contents of `logs/ALERTS.log`. No network, no
real machine, no real ledger.

**The answers** (`gh_rest_pr_state <slug> <num>`, one read):

| rc | body | what the gate does |
|---|---|---|
| `0` | `open` or `merged` (`.state == "closed"` AND `.merged_at != null`) | nothing — RESULT untouched, no log line |
| `0` | `closed` (unmerged) | relabel + the builder-death alert, reason "a CLOSED, unmerged PR" |
| `44` | an affirmative 404 on the PR | ask the SAME identity for the REPO: `0` → relabel ("no such PR (REST 404, repo visible to the `<app\|default\|admin>` token)"); `44` → the 2026-09-12 INVISIBLE alert, RESULT untouched; `75` → one UNVERIFIABLE alert naming the PROBE's own status, RESULT untouched |
| `75` | 403 / 429 / 5xx / any other code, no status line at all (network, DNS, no `gh`), an EMPTY body on a 2xx, a 200 that parses to neither field, or a malformed slug/number (zero requests) | RESULT byte-identical, exactly one `gh_rest_alert` line naming `HTTP <code>` and the token label. Never the words "no such PR", never a relaunch, never a requeue change. |
| — | `bin/lib/gh-rest.sh` absent (a box mid-sync) | treated as `75`: there is no reader to ask, so there is no answer |

**Before the answers:** field 2 that does not match
`^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$` never reaches the read.
The first line becomes `RESULT_MALFORMED <original>`, one alert names the
builder, and no credential is resolved, no request is made and no retry is
slept.

**Files it writes on a live box:**

- `builds/pool-<project>-<KEY>-<n>/RESULT` — first line rewritten to
  `RESULT_MALFORMED PR_CREATED …` when field 2 is not a PR url, or to
  `RESULT_UNVERIFIED PR_CREATED …` on the two affirmative shapes only. The
  rewrite is the LAST thing the branch does, after the read that justified it.
- `logs/ALERTS.log` — one line per decision that is not OPEN/MERGED:
  - `… reaped RESULT claims PR_CREATED but GitHub answers <what> at '<url>' — rewritten RESULT_UNVERIFIED …` (the relabel)
  - `… gh-rest: <KEY> PR_CREATED <url> HTTP <code> (<reason>) token=<default|explicit>, unverifiable, left as-is this tick` (the library's register, BH-781 — `gh_rest_alert`; the reason word is one of `rate-limit`, `network`, `empty`, `bad-args`)
  - `… reaped RESULT claims PR_CREATED but field 2 is '<x>', not a PR URL — the BUILDER wrote a url-less claim … — rewritten RESULT_MALFORMED. No gh call was made: this is not a token or visibility problem. …` (BH-765)
  - `… repo <slug> is INVISIBLE to the <app|default|admin> gh token (tried the App installation token: …; the default PAT: …; the admin PAT: …) — …` (the 2026-09-12 token-scope register, with BH-765's tried-words clause)
- `logs/fly-pool.log` — the matching `MALFORMED` / `UNVERIFIED` / `UNVERIFIABLE`
  `say` line.

**Knobs:** `GHRT_TOKEN_MIN_LIFE` (default
`1800`) — how much life the App token the seam hands this gate must still have,
and how long an `app` verdict is cached before it is re-probed. It needs to be set nowhere; the
default is what the lane has always done. There is no kill switch: skipping the
gate would put PRs that do not exist back on the board.

**What must never regress:**

- **A malformed url never blames a credential and never reaches REST.** Field 2
  that is not a PR url is decided from the line: no token is resolved, no
  request goes out, no retry is slept, and the alert says so.
- **The credential comes from `bin/lib/gh-repo-token.sh`, never from
  `env/github-admin.env` read by hand.** The suite greps the extracted gate for
  that filename and fails if it comes back.
- **A failed read is never a state.** Only `ABSENT 404` (with a visible repo)
  and `CLOSED` may relabel. 403, 429, 5xx, an empty answer, a 200 that parses
  to nothing and an unparseable URL all leave the RESULT exactly as the builder
  wrote it.
- **The repo probe reads its own status code.** A rate-limited probe is not a
  visible repo — that conflation is what made the 2026-09-12 shape possible,
  and it is what BH-709 reintroduced from the other side.
- **`.merged_at` is read alongside `.state`.** A PR the harness merged reads
  `state: closed`; on `.state` alone every merged handoff would be relabeled.
  `gh_rest_pr_state` answers `merged` for exactly that shape.
- **One read per tick, and no sleep.** A contended answer is always "next
  reap", never an in-tick wait — the `*/10` tick is the retry.
- **No `gh pr view` in this gate.** GraphQL is a budget we do not control here.
  The suite proves it from the stub's invocation log, not from a grep.
- **The gate is idempotent.** It only ever matches a first line that still
  starts with `PR_CREATED `, so a re-reap of an already-relabeled record makes
  no API call and writes nothing.
- **It fails open.** An unwritable `ALERTS.log` must not abort the pool tick.
- **The relabel vocabulary stays `RESULT_UNVERIFIED` / `RESULT_MALFORMED`.**
  Both start with `RESULT_`, so neither matches the `PR_CREATED *` readers. `bin/run-triage.sh`,
  `bin/blocked-resolver.sh`, `bin/triage-gate.sh`, `bin/merge-conductor.sh` and
  `bin/pipeline-health.sh` all read that first line.

**Manual-only / not automatable:** repairing RESULT files that a previous
version already mislabelled (`builds/` is machine state, not repo code), and
watching a real reap on the hub:

```sh
tail -20 /root/harness/logs/fly-pool.log
grep -c 'reaped RESULT claims PR_CREATED' /root/harness/logs/ALERTS.log
grep 'could NOT be read over REST' /root/harness/logs/ALERTS.log | tail -5
grep -c 'rewritten RESULT_MALFORMED' /root/harness/logs/ALERTS.log
head -1 /root/harness/builds/pool-cromford-*/RESULT | sort | uniq -c
```

**Both failed-create words are owned downstream (BH-614).** The relabel
vocabulary here is unchanged. What changed is who reads it:
`bin/blocked-resolver.sh` and `bin/pr-url-reconcile.sh` now read
`RESULT_MALFORMED PR_CREATED …` as a failed create on the same terms as
`bin/run-build.sh`'s `PR_CREATE_FAILED`, and the reap closes that record's queue
row `failed` instead of `done` — a build that opened no PR is not finished work.
`RESULT_UNVERIFIED` is untouched by all of that: an unread PR is not a failed
create. See [pr-create-failed-owned.md](pr-create-failed-owned.md).
