# GitHub default identity

**What it is:** which credential a `gh` call actually goes out on. The target
state (#424) is that every box's default GitHub identity is a GitHub App
installation token — `ghs_*`, scoped to one repo, rate-limited per installation
(6600/h on this installation), dead in an hour — minted and cached by
`bin/gh-token.sh` and handed to a lane by `bin/lib/gh-app-auth.sh`. The reason is
a wall: one PAT is one 5000/h REST bucket for every lane on every box, and on
2026-09-15 project-5 was taking a `GraphQL: API rate limit already exceeded`
about once an hour. `bin/lib/gh-repo-token.sh` is the seam every other lane asks. Since BH-765
(2026-09-18) it asks the App installation token FIRST when the box is armed,
then the default PAT, then the org-admin one, and it pages when none of the
three can see the repo. It used to know only the two PATs, so every consumer
that met a repo the default PAT cannot see spent the one org-admin account
bucket while the App token — already minted and cached — was never asked. Its
`gh_repo_pat_for` still answers the PAT-ONLY question for the one consumer whose
sentence is about the PATs (the canary below).

Today the fleet is half way there. Some lanes ask for an App token; the rest
still run on the PAT, and every box is still logged into `github.com` as a
person in gh's keyring. This entry says how to tell which one you are on.

**How an operator reaches it.** Two ways in, and they do not share a mechanism.

*Cron lanes* resolve the identity in-process through the library. They never
read a login shell profile, so a profile snippet does not change what a lane
sends. GitHub-talking lanes in this checkout, and whether they ask for an App
token today:

| where | lane | App token today |
|---|---|---|
| `cron/<box>.cron` | `bin/run-triage.sh` | yes — sources `bin/lib/gh-app-auth.sh`, calls `gh_auth_for` |
| `cron/<box>.cron` | `bin/review-prs.sh` | writes yes (BH-872) — it sources `bin/lib/gh-app-auth.sh` and wraps the verdict post and each review dismissal in `gh_auth_for "$SLUG"` … `gh_auth_reset`, so a bot verdict is readable as a bot's. Its READS stay on the default token, with `bin/lib/gh-ci-read.sh` → `gh-token.sh --read` as the one retry — for Actions runs and, since BH-872, for the `pulls/N/reviews` rows it dedupes against |
| `cron/<box>.cron` | `bin/merge-queue.sh` | yes (BH-438) — `mc_use_token "$SLUG"` from `bin/lib/mc/log.sh`, right after it sources the lib and above every `gh` call it makes |
| `cron/<box>.cron` | `bin/reconcile-prs.sh` | yes (BH-469) — `gh_default_auth_for_slug` per PR url, tagged `app:`/`pat:`; no visibility probe, so it pages for nothing |
| `cron/<box>.cron` | `bin/postmerge-qa.sh` | yes (BH-441) — `gh_auth_for "$SLUG"` once, right after the fleet.conf slug is validated and above the deploy gate's first `gh api`; `gh_auth_reset` above the final `exit 0` |
| `cron/<box>.cron` | `bin/deploy-train.sh` | yes (BH-439) — sources `bin/lib/gh-app-auth.sh`, `gh_auth_for` / `gh_auth_for_url` before the first `gh` call |
| `cron/hub.cron` | `bin/merge-conductor.sh` | yes — `use_token` per repo: `gh_default_auth_for_slug` since BH-469, `gh_auth_for` + the PAT probe on a box whose lib is older; which credential answered is logged once per tick per repo (BH-597), the words app/default PAT only |
| `cron/hub.cron` | `bin/merge-sweep.sh` | yes (BH-469) — `gh_default_auth_for_slug` inside `sweep_use_token_for`, so the BH-796 ladder's App rung is the default identity itself; a minted token settles visibility and the admin-PAT probe (pinned to the sweep's own default token) stays the fallback. CI reads still go through `bin/lib/gh-ci-read.sh`; which credential answered is logged once per tick per repo (BH-597), the words app/admin/default PAT only |
| `cron/hub.cron` | `bin/blocked-resolver.sh` | yes (BH-438) — `br_use_token` asks `gh_auth_for` first and falls to the `gh_repo_use_token` PAT probe only when the App token is not available |
| `cron/hub.cron` | `bin/wake-loop.sh` | yes — `gh_auth_armed`, then `gh-token.sh --warm` off the critical path |
| `cron/hub.cron` | `bin/fly-pool-tick.sh`, `bin/fly-dispatch.sh` → `bin/fly-pool.sh` | yes — `--min-life` tokens for pool machines, and since BH-765 the reap-time PR verify gate resolves its own credential through `bin/lib/gh-repo-token.sh` (app → default → admin) instead of reading `env/github-admin.env` itself |
| `cron/hub.cron` | `bin/jobs-watchdog.sh`, `bin/alerts-groom.sh` | yes (BH-441) — armed PER ROW, because the slug (ledger row) or the PR URL (alert line) differs row to row: `gh_auth_for "$SLUG"` / `gh_auth_for_url "https://$PRURL"` above that row's `gh` call, `gh_auth_reset` above the final `exit 0` |
| `cron/hub.cron` | `bin/flaky-detect.sh`, `bin/flaky-quarantine.sh` | yes (BH-441) — `gh_auth_for "$SLUG"` once, AFTER the `gh_repo_use_token` PAT probe so the App token wins when the box is armed and the probe's export stands when it is not; `gh_auth_reset` next to the existing `gh_repo_token_reset` at the script end |
| `cron/hub.cron` | `bin/rule-miner.sh` | yes (BH-440) — `gh_auth_for` per fleet repo in the revert scan, then for `example-org/cromford` before the clone and the PR steps |
| `cron/hub.cron` | `bin/review-rescue.sh` | yes (BH-469) — `gh_default_auth_for_slug "$SLUG"` before the rescue, `rescue_reset` after it; rc 1 is still the invisible-repo alert |
| not a cron line | `bin/main-red-detector.sh` | yes (BH-469) — `gh_default_auth_for_slug` per repo in the scan loop, tagged `app:`/`pat:` |
| `cron/<box>.cron` | `bin/rebase-train.sh` | no — the PAT |
| `cron/hub.cron` | `bin/review-autopilot.sh`, `bin/pipeline-health.sh`, `bin/poll-commands.sh`, `bin/watchdog-responder.sh`, `bin/alert-triage.sh`, `bin/alerts-medic.sh`, `bin/doorbell-coverage-check.sh`, `bin/cost-rollup.sh`, `bin/tickets-snapshot-push.sh`, `bin/rebase-train.sh` | no — the PAT |
| `cron/hub.cron` | `bin/check-migration-prs.sh`, `bin/migration-autopilot.sh`, `bin/outcome-metrics.sh`, `bin/reopen-metrics.sh` | yes (BH-442) — `gh_auth_for` per repo before the first `gh` call, `gh_auth_reset` at the end of the repo section |
| not a cron line | `bin/run-build.sh` (launched by `bin/run-triage.sh`), `bin/run-decompose.sh` | yes — `gh_auth_for` / a fresh `gh-token.sh` mint |

ONE IDENTITY IS NOT ENOUGH FOR THE PR CREATE (BH-848). `gh pr create` is GraphQL,
and an App installation token's GraphQL budget is a different, much smaller thing
than its REST budget — a pool build's create died on `API rate limit already
exceeded for installation ID …` while REST on the same token was fine. So
`bin/run-build.sh`'s `# >>> pr create call` now climbs `bin/lib/gh-pr-create.sh`'s
ladder instead of making one call: rung `graphql` (`gh pr create`), rung
`graphql-adopt` (`gh pr list --head <branch> --state open`, the adopt that used
to sit in `bin/run-build.sh` — the same GraphQL budget, so it is not the fix, but
a box whose REST quota is the exhausted one adopts on it), rung `rest-adopt`
(`GET repos/<slug>/pulls?head=<owner>:<branch>&state=open`), rung `rest` (`POST
repos/<slug>/pulls`), and then rungs `rest:default-pat` and `rest:admin-pat` —
the token `gh_auth_for` displaced (`_GHAA_DEFAULT_TOK`) and `GH_ADMIN_TOKEN` read
from the env bundle `bin/lib/env-path.sh` resolves, each set for the ONE call and
never exported. A pool machine has no second identity (`bin/fly-pool.sh` replaces
the PAT line in the bundle with the App token), so there the ladder ends at rung
`rest` and says so in `pipeline.log`. Rungs are named by WORD in the log; no token
value is ever written. `PR_CREATE_REST_FALLBACK=0` or
`flags/pr-create-rest-fallback-off` stops the ladder after `graphql-adopt`, which
is the pre-#848 create-then-adopt exactly — the flag removes what #848 ADDED,
never what it replaced.
See [pr-url-reconcile.md](pr-url-reconcile.md).

The non-cron issue lanes `bin/unblocked-children.sh`, `bin/decompose-parent-close.sh`,
`bin/dep-verify.sh`, `bin/preplan-candidates.sh`, `bin/lib/revdep-lib.sh`,
`bin/load-project.sh` and `bin/guardrail-promote.sh` arm the same way (BH-440).

Lanes that never call `gh` (`clock-sync.sh`, `disk-clean.sh`, `metrics-collect.sh`
and friends) are out of scope of the identity. `bin/main-red-detector.sh` still
has no crontab line, so it is run by hand or by another lane, not by cron — the
row above says what its calls go out on when it does run.
`bin/board-invariants.sh` is armed the same way (BH-442) for
each board repo before its first `gh` call, with a reset at the end of the loop.

BH-441 armed six more entry points that no crontab line names — they are launched
by a lane, by the conductor, or by hand: `bin/deploy-verify.sh` and
`bin/wait-preview.sh` (one arm for their one repo), `bin/pre-arm-guards.sh`,
`bin/main-red-detector.sh` (arm and reset inside the `for SLUG in $REPOS` loop, so
each repo's calls go out on its own token — since BH-469 that arm is
`gh_default_auth_for_slug`, which also tags the identity),
`bin/fly-image-build.sh` (armed above
`gh auth token`, which honours `GH_TOKEN`, so the readability probe and the
image's warm clone share one identity instead of the probe passing on a token the
clone does not have — the `--build-secret gh_token` Fly's builder receives is now
an App token with at least `gh-token.sh`'s `MIN_LIFE` of 300 s left) and
`bin/remediations/health-stalepr.sh` (`gh_auth_for_url` for a full PR
URL, `gh_auth_for` for a bare `#123`).

The five lanes BH-469 converted (`bin/merge-conductor.sh`, `bin/merge-sweep.sh`,
`bin/reconcile-prs.sh`, `bin/review-rescue.sh`, `bin/main-red-detector.sh`) also
source `bin/lib/gh-limit-logger.sh`, a `gh` shell function around the real binary.
It changes nothing a call returns; when stderr carries a GitHub rate-limit refusal
it appends one `gh-limit identity=<app:|pat:><slug>` line to `logs/gh-rate.log`.
`timeout N gh …` and `env -u GH_TOKEN gh …` exec the binary and bypass it — a
shell fact, said here so a silent log is not read as a quiet fleet.

*Interactive shells* on a box get whatever gh's keyring holds. On this fleet that
is still a person. Making the App token the default for a shell is the one-time
step below, and no box has run it yet.

**Operator verification commands.** Every answer below was taken from
box-small on 2026-09-17, running the command as written.

| command | answer | what it means |
|---|---|---|
| `env -u GH_TOKEN gh api user --jq .login` | `operator`, rc 0 | the keyring login is a PAT, and it is a person. Expected on every box until the logout step runs there. |
| `GH_TOKEN=$(/root/harness/bin/gh-token.sh example-org/cromford) gh api user --jq .login` | `gh: Resource not accessible by integration (HTTP 403)`, rc 1 | this IS the App token. An installation is not a user, so `/user` refuses it. The refusal is the discriminator, not a failure. |
| `GH_TOKEN=$(/root/harness/bin/gh-token.sh <owner/repo>) gh api repos/<owner/repo> --jq .full_name` | `example-org/cromford`, rc 0 | the positive proof: the token can see exactly its own repo. |
| `/root/harness/bin/gh-token.sh --status` | one line per TOKEN (BH-426: every App cache file, then `pat:default` and `pat:admin`, deduped by token value), e.g. `example-org/cromford remaining=3311/6600 expires_at=2026-09-17T10:00:54Z graphql=4980/5000 rest_resets_at=2026-09-17T10:31:00Z graphql_resets_at=2026-09-17T10:31:00Z`, rc 0 | the App bucket per repo, plus the GraphQL bucket the merge path also spends. `remaining=0/0` plus one stderr line (it was `?/?` before BH-470, seen for an expired `example-org/project-7` entry) means the `rate_limit` read itself failed — read it as unknown, never as unlimited. `--status --json` is the same rows machine-readable; see [gh-quota.md](gh-quota.md). |
| `tail -3 /root/harness/logs/gh-rate.log` | `2026-09-17 09:00:29Z gh-rate example-org/cromford remaining=6498/6600` | what each mint saw. Counts only; no token value is ever written here. |

Never run a command whose output is the token itself. `gh-token.sh <slug>` only
ever appears inside `GH_TOKEN=$(…)`.

**The one-time logout step: `bin/ensure-box-gh-app-default.sh` (BH-469).** It
takes a slug or a fleet.conf project and, in this order: refuses when the box
does not mint App tokens; refuses when the mint did not return a `ghs_` token;
writes `/etc/profile.d/harness-gh-default.sh` (the gh-token.sh COMMAND, never a
token value) plus one `/root/.bashrc` source line; sets git's
`credential.https://github.com.helper` to an INLINE shell helper that mints
through `bin/gh-token.sh`, with `useHttpPath` on so the token is scoped to the
repo git actually asks for (no second script to ship: git runs a `!`-helper as
`sh -c`, so a shell function is a complete helper); and only then runs
`gh auth logout --hostname github.com`. Re-running it is safe.
`bin/bootstrap-machine.sh` calls it from its `# >>> box gh default` block, before
the first clone, and its `# >>> gh preflight` block now WARNS instead of dying
when a box has no keyring login.

NO EXISTING BOX HAS RUN IT. Nothing in this PR runs the ensure step on a live
box: bootstrap calls it for NEW boxes, and rolling it out to the fleet is an
operator action (#424). `/root/.config/gh/hosts.yml` on the boxes still names
`operator` until someone runs it there.

**Landing with #469 / #470.** Probe your checkout before believing any of this
is there:

- `[ -x /root/harness/bin/ensure-box-gh-app-default.sh ]` — #469's one-time step,
  LANDED (it reaches a box on the next `bin/harness-sync.sh`; running it is still
  an operator action). Its order is the safety argument, and it is the order the
  script header states:
  (1) refuse if the box does not mint App tokens at all; (2) refuse if the mint
  did not return an installation token, because `gh-token.sh` prints the PAT when
  a mint fails and swapping a working login for the PAT we already have is all
  downside; (3) write `/etc/profile.d/harness-gh-default.sh` plus one `.bashrc`
  line; (4) set git's github.com credential helper to the inline `gh-token.sh`
  minter (`useHttpPath`, falling back to `$GH_TOKEN`, then to nothing — it never
  invents a credential);
  (5) only then `gh auth logout --hostname github.com`. At no instant is the box
  without a credential path. It is idempotent, so re-running it is safe.
  Bootstrap calls it from the `# >>> box gh default` block.
- `declare -F gh_default_auth_for_project` — defined by #469, LANDED. The
  per-lane wiring is BH-470's, [gh-default-auth-lanes.md](gh-default-auth-lanes.md);
  it is guarded on `command -v gh_default_auth_for_project`, and with #469 on
  the branch that guard is satisfied. A lane neither ticket wires still answers
  "no — the PAT" in the rows above.
- `grep gh-limit /root/harness/logs/gh-rate.log` — #469's rate-limit logger,
  LANDED: one `identity=app:<slug>` / `identity=pat:<slug>` line per refusal.
  Empty until a lane is actually rate-limited, which is the normal state — read
  zero matches as "nobody was refused", not as "the logger is missing".
- `--status` prints `0/0` with a note on stderr instead of `?/?` — this is BH-470
  and it is on this branch, with or without #469.

**How to drive it:**

| what | how |
|---|---|
| mint, cache, lock and fallback | `bash tests/gh-token-test.sh` |
| the cache rotating a token before it expires | `bash tests/gh-token-rotate-test.sh` |
| a real mint against GitHub (opt-in, needs credentials) | `bash tests/gh-token-live-test.sh` |
| the triage lane billing the App token | `bash tests/triage-gh-app-token-test.sh` — **red on main @ 44165ea**, see below |
| the PAT fallback and its invisible-repo alert | `bash tests/gh-repo-token-test.sh` |
| the ladder itself: which rung wins per repo, that a mint printing the PAT is never called `app`, that an unarmed box spawns nothing, that the lib and `bin/gh-token.sh` cannot recurse, and the tried-words in the alert | `bash tests/gh-repo-token-app-first-test.sh` (BH-765) |
| the merge path arming the App token, and the raw-`gh` ratchet over `bin/` | `bash tests/gh-app-ratchet-test.sh` — blocks 5, 6 and 7 run the lib, the resolver's `br-token` block and the real queue script and read the token their `gh` calls go out on |
| the merge sweep's own ladder: which rung a repo is probed on, that a rate-limited 403 is not read as an invisible repo, and that the App rung is minted once per (repo, run) | `bash tests/merge-sweep-token-ladder-test.sh` (BH-796) |
| the default identity: the tag, the two-repo case, the rate-limit logger, the ensure step (including git's inline credential helper, run the way git runs it), bootstrap's two blocks, merge-sweep's token routing, and `bin/main-red-detector.sh` + `bin/reconcile-prs.sh` run WHOLE over two repos where only one can be minted for | `bash tests/gh-default-identity-test.sh` (BH-469) |
| the review lane's writes going out on the App token while its reads keep the default one | `bash tests/review-prs-dedupe-test.sh` cases 14 and 15 — the gh stub records `$GH_TOKEN` per call, so the assertion is about the token the call actually carried |

`tests/gh-default-auth-lanes-test.sh` (#470) exists and is green on this branch
(101 pass, 0 fail): it drives the eleven BH-470 lanes over the helper this ticket
defines, with a stub, and is the evidence that those lanes go live when it lands.

`tests/triage-gh-app-token-test.sh` fails on main @ 44165ea, 4 pass / 3 fail:
"armed -> GH_TOKEN is the minted App token (got: pattok)", "exactly one mint for
the tick (mints: 0)", "the tick logs that it bills the App token for the repo".
So the code path is there (`bin/run-triage.sh` line 28 calls `gh_auth_for`) but
nothing currently proves the triage lane actually spends the App token. Read the
"yes" in the triage row above as wired, not as verified, until that suite is
green. It is one of 25 suites already red on this merge base and is not
something this entry introduced.

**Files it owns on a live box:**

- `state/gh-app-tokens/<owner>-<repo>.json` — the cached token, `.repo`,
  `.expires_at`. The token value is in this file. Never cat it into a log.
- `logs/gh-rate.log` — one `gh-rate <slug> remaining=<n>/<n>` line per mint.
- `/root/.config/gh/hosts.yml` — the keyring login. After the logout step lands
  and runs, it should hold no `github.com` user. Today it holds `operator`.
- `/etc/profile.d/harness-gh-default.sh`, one `/root/.bashrc` source line, and
  git's `credential.https://github.com.helper` — all three are installed by
  `bin/ensure-box-gh-app-default.sh`, and on no box until someone runs it there.
- `logs/gh-rate.log` also carries the `gh-limit` lines from
  `bin/lib/gh-limit-logger.sh`, under a tag of their own next to the `gh-rate`
  mint lines. Counts and GitHub's own wording only; token-shaped runs in a
  message are written as `<redacted>`.

**Knobs:** `env/github-app.env` carries `GH_APP_ID`, `GH_APP_PRIVATE_KEY_FILE`,
`GH_APP_TOKENS`, `GH_APP_INSTALLATION_<OWNER>` and `GH_APP_API_BASE`;
`flags/gh-app-tokens-off` kills minting for writes and ordinary lane auth but
deliberately not `--read`; `GHRT_TOKEN_MIN_LIFE` (default `1800`) is how much
life `bin/lib/gh-repo-token.sh` demands of the App token it hands a consumer; `GH_TOKEN` in `env/global.env` is the PAT the fallback
finds. Setup is in `docs/OPERATOR-SETUP.md`, "GitHub App installation tokens" —
it is not repeated here.

**What must never regress:**

1. An unarmed box is untouched. `gh_auth_for` returns 1 without spawning a
   process and without setting `GH_TOKEN` when `env/github-app.env` is absent,
   `GH_APP_TOKENS=0`, or `flags/gh-app-tokens-off` exists.
2. The ensure step refuses to log anything out unless the mint returned an
   installation token, and logs out LAST, after the profile snippet and the git
   credential helper.
3. No token value in a log, a comment, a filename or a board post. The budget
   cache keys on a token fingerprint; `gh-rate.log` carries counts.
4. `bin/lib/gh-repo-token.sh` asks the App installation token first when the box
   is armed, then the default PAT, then the org-admin one, and its
   invisible-repo alert still fires — now naming what each of the three
   answered — rather than skipping quietly. `bin/claude-auth-check.sh`'s canary
   asks `gh_repo_pat_for`, not the ladder: its sentence is "DEFAULT GH TOKEN
   CANNOT SEE <repo>", and fed the merged verdict it would go silent on a blind
   default PAT that an App token happened to cover. An `app` verdict is cached
   for `GHRT_TOKEN_MIN_LIFE` seconds (default 1800) and then re-probed, because
   the credential behind it dies in an hour.
5. `remaining=0/0` from `--status`, together with its one stderr line, is a
   FAILED status read (BH-470 replaced the old `?/?` with it). Nothing may treat
   it as headroom. A genuine `remaining: 0` from GitHub prints as `0/<limit>`.
6. `GH_LIMIT_IDENTITY` is read from the token that is actually exported when
   `gh_default_auth_for_slug` returns — including the one the
   `gh_repo_use_token` fallback exports, which since BH-765 can itself be an App
   token. The tag is a fact about the token, never about a return code.
