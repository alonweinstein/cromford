# Verification-map README retrofit (a PR's hand-added rows moved into `entries/`)

**Status since BH-1175:** this lane is DISARMED for cromford and still live
for target repos. `docs/verification-map/README.md` is not committed here any
more, so both hooks return on their first guard (no README in the tree) and no
merge can conflict on it. Everything below describes the repos that still commit
a generated index — and the one change this ticket made to the lane: its trigger
is now `--check-committed`, because plain `--check` grades the SOURCES and would
answer "in sync" for a glued README, retiring the repair without a word. See
[verification-map-no-commit.md](verification-map-no-commit.md).

**What it is:** `docs/verification-map/README.md` became a GENERATED artifact in
BH-798. Every PR cut before that change still carries its map row as a hand edit
of the README, so merging main into it conflicts on a file the ticket is not
about. The only mechanical resolver that matched the README was the `*.md` UNION
arm of `mc_resolve_conflicts`, and union is the wrong operation for a generated
file: it leaves a duplicated header and a row that no entry file backs, so the
rung pushes a head on which `bin/verification-map-build.sh --check-committed`
exits 1 and the park spends a fix round on a mechanical problem.

BH-868 replaces that with the right operation — move the rows the PR APPENDED
into `docs/verification-map/entries/<TICKET>.md`, take main's README, rebuild it
from its sources, assert `--check-committed`. Anything that is not a pure row
append is refused and left to the fix round.

**How an operator reaches it:**

| lane | where it lives | when it acts |
|---|---|---|
| the mechanical rung | `mc_resolve_vmap_readme` in `bin/lib/mc/rebase.sh`, called by `mc_resolve_conflicts` before the `*.md` union case | the merge of main CONFLICTS on the README: `bin/blocked-resolver.sh` (`cron/hub.cron`, \*/10) via `br_mechanical` → `mc_rebase`, and the conductor's own rebase/merge-sweep lane |
| the clean-merge repair | `mc_resolve_vmap_clean_merge`, called by `mc_rebase` on the branch where the merge SUCCEEDED | the merge of main is clean but the README no longer rebuilds to itself — the shape the `merge=union` attribute puts every branch in |
| the operator CLI | `bin/verification-map-retrofit.sh` | by hand only |

**Why there are two hooks.** `.gitattributes` on main carries
`docs/verification-map/README.md merge=union` (BH-865; removed for this repo by BH-1175,
still present in a target repo that commits its index). Git's union driver therefore
resolves that file WITHOUT a conflict: it glues main's generated table onto the PR's
hand table and the merge is clean, so `mc_resolve_conflicts` — which only ever sees
`--diff-filter=U` paths — is never reached, and the rung used to commit and push a
README with a duplicated header and a row no entry file backs. `mc_resolve_vmap_clean_merge`
runs after a clean merge, does nothing at all unless `--check-committed` is already out
of sync, and otherwise runs the same core and commits the result. A decline leaves the merge
exactly as git made it.

By hand, on the hub:

```
bin/verification-map-retrofit.sh --dry-run /root/repos/cromford 808
bin/verification-map-retrofit.sh /root/repos/cromford 808
bin/verification-map-retrofit.sh --all-open /root/repos/cromford
```

The dry run prints the entry file it WOULD write and the rows, pushes nothing and
comments nothing. A real run commits on the PR's own branch (a new merge commit
on top of the head it read — nothing is rewritten), pushes with
`--force-with-lease`, then posts one PR comment with the before/after row count.
A failed push produces no comment.

**Exit codes:**

| rc | meaning |
|---|---|
| 0 | retrofitted — the branch was pushed |
| 1 | not this script's business (no `bin/verification-map-build.sh`, or main has no generated layout) |
| 2 | a conflicted path outside the README — out of scope, the fix round owns it, and the script never touches those files |
| 3 | refused: the README change is not a pure row append, or the branch has no ticket key |
| 4 | the PR head moved between the read and the push — nothing spent |
| 5 | NOTHING to retrofit: the PR appended no row and its merged README already rebuilds to itself |

`--all-open` prints one summary line per PR
(`#<n> <branch> RETROFITTED|NOTHING|REFUSED|CODE-CONFLICT|HEAD-MOVED|UNREADABLE`)
and exits 3 if any PR was refused. **`NOTHING` and `RETROFITTED` are different
answers on purpose:** most open PRs were never in this cohort, and a sweep that
prints `RETROFITTED` for a PR it never touched reports the ticket's acceptance met
while the red ones stay red.

**Every retrofit costs one re-review.** The push moves the head, which drops the
sha-bound approval, so the conductor buys a fresh head-bound review of each PR the
sweep touches. That is the trade the ticket makes: one review instead of one fix
round. It is also why `NOTHING` matters — a sweep that "retrofitted" 90 PRs would
buy 90 reviews.

**What it refuses** (all rc 3, no entry file, no push): an edited existing row, a
removed row, an added header or `|---|` separator, a line of prose, a row whose
`[x.md](x.md)` target main's table already carries, and an `entries/<KEY>.md`
already on the head with different rows. An added blank line is tolerated and
dropped (the stray-blank-line bug BH-798 fixed).

**In the mechanical rung the refusal FALLS THROUGH** to today's union resolver
rather than failing the rung: a repo without the build script, a branch with no
ticket key, or a refused classification behaves exactly as it did before this
ticket. That promise is only true because **a decline puts the tree back**: the
core restores the README it overwrote (conflict markers and all — the union arm
needs them) and removes the `entries/<KEY>.md` it wrote. Without that restore the
rung FAILED instead of unioning, and the untracked entry file survived
`git merge --abort` inside the conductor's REUSED scratch clone
(`$MC_H/tmp/conductor/<slug>`), where the next PR's retrofit would have committed
another ticket's row into an unrelated PR.

`logs/merge-conductor.log` carries which happened —
`verification-map README retrofitted into docs/verification-map/entries/<KEY>.md`,
`verification-map README repaired after a CLEAN union merge into …`, or
`verification-map README retrofit declined (rc <n>: <the core's own reason>) — union resolver takes it`.

**How to drive it:**

| what | how |
|---|---|
| the row classifier and every refusal, the resolve inside a real conflicted merge, the CLI against a real bare remote and a stubbed `gh`, `--all-open`, and the REAL `mc_resolve_conflicts` on a README-only conflict | `HARNESS_TEST_SANDBOX=1 bash tests/verification-map-retrofit-test.sh` |
| the CLEAN union merge (a fixture whose commits carry `.gitattributes`), the `NOTHING` answer, the decline that restores the tree, and `mc_resolve_vmap_clean_merge` | same suite, cases 13-20 |
| the union fall-through for repos with no build script (unchanged behaviour) | same suite, last section |
| the generated-path rung it sits beside | `HARNESS_TEST_SANDBOX=1 bash tests/generated-path-conflicts-test.sh` |
| the README generator itself | `bash tests/verification-map-build-test.sh` |

**Preconditions:** the PR must be in the same repository (fork PRs are refused),
`gh` must be authenticated for the repo, and `<repo-path>` must be a local
checkout with an `origin` remote whose URL is a GitHub slug — the hub's
`/root/repos/cromford`. Every PR read and the comment go over **REST**
(`bin/lib/gh-rest.sh`), never the GraphQL-backed `gh pr view`/`gh pr list`: an
`--all-open` sweep over ~90 PRs is exactly the burst that rate-limits the
account, and a GraphQL limit answers with a silence a caller reads as "no such
PR" (#768). The dry run enforces the same preconditions as a real run, so a
`WOULD write` line is never printed for a PR the real run would decline.

**Files it writes:** on a PR branch, `docs/verification-map/entries/<KEY>.md` and
the regenerated `docs/verification-map/README.md`, in one commit. On the hub,
`logs/merge-conductor.log` lines from the hook. No state file and no ledger: the
tree itself carries the idempotency (entry file present + README generated → the
next run is a no-op).
