# Per-project lanes default to the App identity

**What it is:** the eleven lanes that are invoked with a PROJECT name now resolve
that project's GitHub identity once, near the top, instead of spending whatever
`GH_TOKEN` the box happened to hold. Each one sources `bin/lib/gh-app-auth.sh`
and `bin/lib/gh-limit-logger.sh` behind `[ -r … ] &&` guards and calls
`gh_default_auth_for_project "$PROJECT"`, which resolves the slug out of
fleet.conf and arms that repo's App installation token (`ghs_*`, 6600/h per
installation, dead in an hour) with `GH_LIMIT_IDENTITY=app:<slug>` for the
rate-limit logger. The reason is the wall: one PAT is one 5000/h REST bucket for
every lane on every box. See [github-default-identity.md](github-default-identity.md)
for which credential a `gh` call goes out on across the whole fleet.

`gh_default_auth_for_project` is slice 1's (#469, PR #911) and lands separately.
Every call site here is guarded with `command -v`, and where a lane already armed
through `gh_auth_for` / `gh_auth_for_url` that call survives as the else-branch —
so on a checkout without #469 these regions fork nothing and each lane behaves
byte for byte as it did. `bin/gh-token.sh --status` is the half of this ticket
that works today, with or without #469.

**How an operator reaches it.** The lanes are cron entry points (`cron/<box>.cron`
and `cron/hub.cron`), except `bin/run-build.sh`, which `bin/run-triage.sh`
launches. Each region is delimited in the shipped script:

| lane | where the region sits | the `gh` consumer it is for |
|---|---|---|
| `bin/run-triage.sh` | `# >>> triage github auth`, below the `set -a; . global.env` block | the triage shards it dispatches (they inherit the environment) |
| `bin/run-build.sh` | two regions: the lib sources, then the arming call above the coordination claim | the whole build pipeline's `gh` calls; falls back to `gh_auth_for "$GH_AUTH_SLUG"` when fleet.conf has no row |
| `bin/run-product.sh` | after the env block | the stage sessions it launches |
| `bin/review-prs.sh` | after the `bin/lib/gh-ci-read.sh` source | `gh pr merge`, `pr view`, `pr diff`, two `pr review`s |
| `bin/rebase-train.sh` | after the env line | the train's PR list and status reads |
| `bin/deploy-train.sh` | next to the existing `gh-app-auth.sh` source | the departure's PR lookups (the rollback push keeps its own `gh_auth_for "$SLUG"`) |
| `bin/check-migration-prs.sh` | sources at the top, the call inside `for PROJECT in "${!REPOS[@]}"` | `gh pr list` per project |
| `bin/wake-loop.sh` | sources next to the `--warm` block, the call inside `push_children()`, then the reset | `closed_diff`'s `gh issue list` |
| `bin/claude-auth-check.sh` | sources after `STAMP()`, the call inside `gh_visibility_canary`'s loop AFTER `gh_repo_pat_for`, then the reset | nothing today — the canary's own question is PAT-only by design (BH-765), so the call sits BELOW the probe and cannot tag a PAT call `app:` |
| `bin/fly-pool.sh` | after the `bin/lib/gh-repo-token.sh` source | the tick's reap-time PR verify reads |

The two lanes that arm per row (`wake-loop`, `claude-auth-check`) reset to the
process default immediately afterwards, because
`wake-loop` launches other lanes and a child that inherited repo A's installation
token as its default would `gh_auth_reset` back to A's token instead of the PAT.

**How to drive it:**

| what | how |
|---|---|
| every lane's region: it arms the cached App token, tags the identity, sources the logger, resets where it must, and fails open on a box with neither library | `bash tests/gh-default-auth-lanes-test.sh` — the regions are extracted VERBATIM from the shipped scripts by their markers and run in a scratch shell against a stubbed GitHub |
| `--status` on four `/rate_limit` bodies (`.rate`, `.resources.core`, unauthenticated, empty) | the same suite, cases 8–12, driving the real `bin/gh-token.sh` CLI |
| the triage lane still billing the App token after its block moved below the env load | `bash tests/triage-gh-app-token-test.sh` |
| the mint, cache and PAT fallback underneath all of it | `bash tests/gh-token-test.sh`, `bash tests/gh-token-rotate-test.sh` |
| that `check-migration-prs.sh` is no longer a raw-`gh` file | `bash tests/gh-app-ratchet-test.sh` (its baseline line is gone) |

`tests/gh-default-identity-test.sh` (#469, the helper itself) is not on the merge
base; this suite carries a stand-in for the helper's contract and says so on
stdout when it uses one.

**What a live box shows:**

- `bin/gh-token.sh --status` — one line per TOKEN (BH-426; it was one line per
  cache file), `<identity> remaining=<n>/<m> expires_at=<iso|-> graphql=<n>/<m>
  rest_resets_at=<iso|-> graphql_resets_at=<iso|->`. App rows keep the bare slug
  as the identity; the two PATs report as `pat:default` and `pat:admin`, deduped
  by token value. Since BH-470 it parses `.resources.core` as well as the
  deprecated `.rate` object, and an unauthenticated or unparseable answer prints
  `remaining=0/0` plus ONE stderr line naming the identity. It never prints
  `?/?` any more. `--status --json` prints the same rows as a JSON array — see
  [gh-quota.md](gh-quota.md).
- `logs/gh-rate.log` — one `gh-rate <slug> remaining=<n>/<m>` line per MINT
  (counts only, never a token value), and once #469 lands, `gh-limit
  identity=app:<slug>` lines from these lanes when GitHub refuses a call.
- `logs/<project>.log` — the triage tick's own `triage github auth: App
  installation token for <slug>` line.
- `state/gh-app-tokens/<owner>-<repo>.json` — the cache every lane reads. Eleven
  lanes on one project buy ONE token.

**Knobs:** none new. `env/github-app.env`, `GH_APP_TOKENS=0` and
`flags/gh-app-tokens-off` are the same three offs as the rest of the rollout — on
an unarmed box every region leaves `GH_TOKEN` exactly as it found it and forks no
process at all.

**What must never regress:**

1. An unarmed box is untouched: `GH_TOKEN` stays the lane's own, no mint, no fork.
2. A box whose `bin/lib/` has neither library still runs every region to rc 0.
3. Eleven lanes on one project share one mint — nobody bypasses the cache.
4. No token value in any log line, and `--status`'s stderr note names the slug only.
5. `--status` never prints `?/?`; `0/0` always arrives with its stderr note, and a
   genuine `remaining: 0` from GitHub still prints as `0/<limit>`.
