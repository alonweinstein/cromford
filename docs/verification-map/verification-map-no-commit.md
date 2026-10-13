# The verification-map index is generated and NOT committed (BH-1175)

**What it is:** `docs/verification-map/README.md` is git-ignored. The per-ticket
entry files under `docs/verification-map/entries/` are the source of truth, and
the index is rebuilt wherever somebody needs to read it — in CI, in the public
share mirror, and on every box after a sync.

**Why.** BH-798 made the index generated but left it committed, so every build
still rewrote the same file. The measurement that ended that arrangement, taken
on 2026-09-20:

| | |
|---|---|
| merges to main that touched the file (last 200) | 105 |
| rebases in that day's drain that conflicted on it | every one |
| main-red freezes it caused in one day | 3 (e71b2de1, dd2cee5a, 855c0b42) |

The three freezes are the interesting part. `merge=union` resolved the conflict
by concatenating both sides, which on a squash merge duplicated a row; the drift
check then refused the duplicated table and main went red for a file no ticket
was about. Union merging was the best available answer while the file had to be
in git. Taking it out of git removes the contested cell instead of resolving it,
and the whole class of failure goes with it.

**How an operator reaches it:**

- `bin/verification-map-build.sh` — write the index. Nothing stages it.
- `bin/verification-map-build.sh --check` — validate the committed sources.
- `.github/workflows/harness-ci.yml`, `lint` job, step *verification-map index
  generates and its sources validate* — generate (fatal on failure), then check.
- `bin/publish-share.sh` step 1b — regenerates into the pinned clone before
  `bin/share/sanitize.py`, so the public mirror still carries the index.
- `bin/harness-sync.sh`, right after the `git pull` — regenerates in the box
  checkout, because `bin/verification-map.sh` renders the PLAN primer from that
  file and a fresh checkout does not have it.

**What `--check` grades, and what it stopped grading.**

It no longer compares bytes against a committed copy: there is no committed
copy, and "the file on disk is older than its sources" is not a defect when
every reader regenerates first. It grades what git actually carries:

| verdict | rc | what it means |
|---|---|---|
| entry file does not parse | 2 | a non-blank line that is not one complete `\| … \|` row, named by `file:line` |
| a source is missing | 2 | no `index/head.md`, `index/tail.md` or `entries/` |
| duplicate row | 1 | two entry files produce the same row — the main-red shape, and a duplicated row regenerates to itself so bytes never showed it |
| dead document link | 1 | an entry links a document that does not exist under `docs/verification-map/` |
| tracked index | 1 | the README is both git-ignored and tracked, which is the repo stating two contradictory things |
| valid | 0 | |

`--check-committed` keeps the old byte comparison for repos that still commit
their index. `mc_resolve_vmap_clean_merge` and `bin/verification-map-retrofit.sh`
use it as their repair trigger, because their question really is about bytes;
pointing them at plain `--check` would have retired both repairs silently.

**How to drive it:**

| what | how |
|---|---|
| the no-commit contract, on real git | `bash tests/verification-map-no-commit-test.sh` |
| the generator and every `--check` verdict, on fixtures | `bash tests/verification-map-build-test.sh` |
| that the merge train is still armed without a committed README | `bash tests/generated-files-train-test.sh` (GT-2, GT-4) |
| that the index is really out of git | `git ls-files -- docs/verification-map/README.md` (empty) and `git check-ignore -q docs/verification-map/README.md` (rc 0) |
| the repair paths that still need bytes | `bash tests/verification-map-retrofit-test.sh` |

**What the harness's own lanes had to learn.** Taking a committed file out of
git is a MODIFY/DELETE for every branch that still commits it, and git resolves
a modify/delete by leaving "ours" in the worktree with **no conflict markers**.
48 of the 63 PRs open when this landed were in that shape, and the marker-based
`*.md` union resolver cannot help with a file that has none, so all three rebase
lanes called it a real conflict and the batch train re-tracked it:

| lane | before | now |
|---|---|---|
| `mc_resolve_conflicts` (conductor rebase, pool rebase) | rc 1, the path handed to a fix round | `mc_resolve_deleted_ignored` takes the deletion |
| `bin/lib/mc/rebase.sh` (the unsourced copy of the same function) | same | same guard, kept in step by hand |
| `build_union` in `bin/batch-resolve.sh` | `checkout --theirs` + `add` re-tracked it, and `verify_union`'s first command then refused the union | `deleted_ignored` takes the deletion |
| the build primer (`bin/verification-map.sh`) | rendered "this repo has not adopted the verification map" in a worktree with no ignored files | `ensure_index` builds it; a map with entries never reads as un-adopted |
| the share mirror | `git add -A` skipped the file it had just generated (the mirror inherits `.gitignore`) | `git add -f` for that one path |

**Two conditions, and both carry weight.** The guard acts only where the merged
tree's own `.gitignore` says the path must not be in git — a modify/delete on a
TRACKED path is left exactly as it was, a real conflict a human owns. And it
acts only on a BASE-side deletion. The mirror image, where the BRANCH deleted a
tracked-but-ignored file and the base still edits it, is data loss: taking the
deletion there discards the base's edit with no conflict, no log line a reviewer
would read as loss, and no way back. Any repo can have a file that is both
tracked and ignored — this one had `locks-worker/.wrangler/cache/cf.json` until BH-5518 C2 — and
the resolver runs against every target repo's `.gitignore`, so the orientation
is checked rather than assumed.

The two twins read the orientation from OPPOSITE stages, because their merges
run in opposite directions: `mc_resolve_deleted_ignored` merges the base INTO
the branch, so the base is stage 3 and a base-side deletion is stage 3 absent;
`deleted_ignored` merges each member INTO a worktree that IS the base, so the
base is stage 2 and a base-side deletion is stage 2 absent. Getting one of them
backwards is silent loss, which is why each says so at its own `case`.
`tests/verification-map-no-commit-test.sh` NC-8 and NC-9 pin both directions
against real merges.

**`--check` refuses a TRACKED index whether or not `.gitignore` still covers
it.** The narrower "tracked AND ignored" verdict left the way back in wide open:
a PR that drops the ignore line and forces the file in passes its own gate, and
main quietly commits the artifact again while every lane built around this
ticket still assumes otherwise. A gate whose subject can delete the gate is not
a gate. The refusal names the missing ignore line too, so the fix restores both
halves. NC-10 pins it.

**Files it owns:**

- `.gitignore` — the fence.
- `bin/verification-map-build.sh` — `--check` (sources) and `--check-committed` (bytes).
- `bin/batch-resolve.sh` `regen_table`, `bin/lib/mc/rebase.sh` (behind the
  `bin/lib/merge-conductor-lib.sh` shim) `mc_regen_table` — both read the
  `## Generated files` table from
  `docs/verification-map/index/tail.md`.
- `bin/harness-sync.sh`, `bin/publish-share.sh` — the two regenerate-on-deploy
  points; the mirror also force-stages the index it generated.
- `mc_resolve_deleted_ignored` in `bin/lib/mc/rebase.sh` (behind the
  `bin/lib/merge-conductor-lib.sh` shim), `deleted_ignored` in
  `bin/batch-resolve.sh` — the modify/delete guard, one behaviour in two places
  that must not drift (BH-684 emptied the lib's third copy into the module).
- `ensure_index` in `bin/verification-map.sh` — the build worktree's index.
- `bin/readiness-report.sh`, `bin/planned-files-cheap.sh` — the two readers that
  fall back to the committed sources when there is no index in the checkout.

**What must never regress:**

- **The `## Generated files` table stays readable from `index/tail.md`.**
  `bin/batch-resolve.sh` exits 0 having done nothing when that table is empty, so
  a table that moves out of a parser's reach switches the batch merge train off
  for this repo — silently, on the repo whose conflict tail the lane exists for.
  `tests/verification-map-no-commit-test.sh` NC-4 drives the real parser over a
  tree with no committed README.
- **No merge attribute for the path.** A driver declared for a file git never
  sees is a rule with no subject that comes back into force the day somebody
  re-adds the file. `tests/generated-files-train-test.sh` GT-7 pins it.
- **Every reader either regenerates or falls back.** A reader that needs the
  index and neither regenerates it nor reads the entries renders "ABSENT" on
  every box, which is a true statement about the checkout and a false one about
  the repo.
- **A deleted-and-ignored path never reaches a fix round.** It is mechanical, it
  is decided by `.gitignore`, and paying an Opus round for it once per open PR
  is the exact cost this epic exists to remove.
- **`--check-committed` has no consumer in the fleet today** (no target repo
  ships `bin/verification-map-build.sh`). It is kept because the two repair
  paths it feeds are generic, not because a repo is using it right now.
