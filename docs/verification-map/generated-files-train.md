# Generated-files train (batch-resolve, armed for cromford)

**What it is:** `bin/batch-resolve.sh` lands approved sibling PRs whose ONLY
conflicts are in machine-written files as ONE merge-time train — one union
branch, one regenerate, one verification run, one queue entry — instead of one
rebase and one full CI run per PR. The lane has existed since BH-498, and it
does nothing on a repo that has not declared which of its files are generated.
BH-865 is that declaration for cromford: a `## Generated files` table in
`docs/verification-map/index/tail.md` and a two-line `.gitattributes`.

The tail it exists for: `docs/verification-map/README.md` was the single most
common hunk in this repo's dirty-PR list — a markdown table no code reads,
conflicting between tickets that have nothing to do with each other. BH-1175
finished that job by taking the file out of git altogether, so what this lane
now regenerates over a union is an ignored artifact and what it lands is the
entry files. **The table itself had to move with it**: both parsers read
`index/tail.md` directly, because a parser pointed at a path that is not in the
tree reads an empty table, and an empty table turns this lane off silently.

**How an operator reaches it:**

- `bin/batch-resolve.sh cromford` on the hub (also spawned by
  `bin/merge-conductor.sh` when `mc_batch_should_spawn` sees approved siblings).
- `logs/batch-resolve.log` is where it says what it did. A repo with no table
  logs "no regenerate table in AGENT_ARCHITECTURE.md or
  docs/verification-map/README.md — batch-resolve is off" and exits 0; an armed
  one logs that it is building a train. **That log line is the alarm for BH-1175
  having gone wrong**: it is what this repo would print if the table stopped
  being reachable from `index/tail.md`.
- The lane reads the table from **`origin/main`**, so this declaration arms it
  only once the PR has merged and the hub clone has fetched — a branch alone
  changes nothing.
- Kill switches, unchanged: `flags/batch-resolve-off`, `BATCH_RESOLVE=0`,
  `flags/automerge-disabled`, `BATCH_MAX_MEMBERS`, `BATCH_SPLIT_MAX`.

**What this repo declares:**

| where | what |
|---|---|
| `docs/verification-map/index/tail.md` | the `## Generated files` table: `docs/verification-map/README.md` → `bin/verification-map-build.sh`. Read from THIS file since BH-1175; the generated README still carries a copy for human readers |
| `docs/verification-map/index/tail.md` | `rules/CLAUDE.md` → `bin/render-rules.sh --write` (BH-1336): the one COMMITTED row. Five box scripts copy that render verbatim, so it cannot leave git until they render it themselves (BH-1336 child 2) — and until then a conflict on it is regenerated from the merged `rules/topics/`, never hand merged |
| `.gitattributes` | `merge=union` on `env-templates/project.env.example` + `env-templates/global.env.example`. The README's union line is gone with the file (BH-1175) |

The env templates are union-only: no script regenerates them, so they get no
table row. `path_allowed` accepts a union path with no regenerate command —
`union_paths` is the second half of the allow-list.

**The same table parser for resolver fix rounds (BH-968).** `bin/lib/mc/rebase.sh` now exposes `mc_regen_table <dir> <ref>` so later children do not have to shell out to `bin/batch-resolve.sh` or re-implement the parser. `bin/blocked-resolver.sh` sets `BR_REGEN_RUNG="${BR_REGEN_RUNG:-1}"`: a default of 1 means the execute stage may run the regenerate step during a fix round, 0 leaves the pre-BH-968 behaviour.

**How to drive it:**

| what | how |
|---|---|
| the whole declaration: table, union list, allow-list, the attribute proved on real sibling branches, the contract | `HARNESS_TEST_SANDBOX=1 bash tests/generated-files-train-test.sh` |
| the generator whose output carries the table | `HARNESS_TEST_SANDBOX=1 bash tests/verification-map-build-test.sh` |
| the table as the lane reads it | `bash -c 'eval "$(sed -n "/^regen_table()/,/^}/p" bin/batch-resolve.sh)"; show_base(){ git show "origin/main:$1" 2>/dev/null; }; regen_table'` — one tab-separated row |
| what git says about a declared path | `git check-attr merge env-templates/global.env.example bin/run-build.sh` (and `docs/verification-map/README.md`, which must now be `unspecified`) |
| the lane itself, on fixtures | `HARNESS_TEST_SANDBOX=1 bash tests/batch-resolve-test.sh` |
| the regenerate on the REBASE paths (conductor, pool, union-with-no-conflicts) | `HARNESS_TEST_SANDBOX=1 bash tests/generated-files-train.bh-969-test.sh` |

**Files it owns:**

- `.gitattributes` — the union declaration.
- `docs/verification-map/index/tail.md` — the `## Generated files` table (the
  README that carries it is generated from this file).
- `CLAUDE.md` — the `## Verification Contract` the lane runs over the union.
- `tests/generated-files-train-test.sh` — this feature's suite.

**What must never regress:**

- **No union attribute on a code path.** `bin/run-build.sh`,
  `bin/lib/merge-conductor-lib.sh` (the shim over `bin/lib/mc/`) and friends conflict for real reasons;
  union-merging them concatenates two edits nobody reviewed. The attribute file
  names explicit paths, never globs, and the suite fails on a `*`, a `bin/` or a
  `.sh` in it.
- **`env-templates/alerts.conf.example` is never unioned.** It is READ AT
  RUNTIME as a fallback (`bin/lib/alert-state.sh`), so a duplicated or
  interleaved rule there changes behaviour rather than just looking untidy.
- **Only paths a script regenerates byte-for-byte get a table row**, and the
  command named in the row must exist and be executable — `build_union` runs it
  verbatim. `docs/MERGE-CONDUCTOR.md` is prose with no generator and is
  deliberately excluded.
- **The contract must be runnable where the lane runs it.** `verify_cmd` falls
  back to `npm test`, which in a repo with no `package.json` is red on every
  attempt: a train that always fails verification splits twice, hands its members
  back with a red mark and lands nothing. Same for the root guard — the hub runs
  as root next to `/root/harness`, so each command in the contract carries
  `HARNESS_TEST_SANDBOX=1`.

**The union-order edge, and where it is handled (BH-969).** Two siblings each
append a row, union keeps both in ours-then-theirs order, and the generator sorts
keys naturally — so a union-merged README commonly failed
`bin/verification-map-build.sh --check-committed` until it was regenerated. BH-1175
took the README out of git, so this edge no longer exists in THIS repo (there is
nothing to union); it is still the shape in any repo that commits its index. In
the train
that regenerate is the very next step, by design, and since BH-969 it runs for
every command the table declares rather than only the ones a conflict recorded —
a train whose members conflict nowhere used to skip it entirely. An ordinary
conductor or pool rebase now regenerates too, via `mc_regen_generated`
([regen-on-rebase.md](regen-on-rebase.md)): the rebased head carries one extra
commit with the regenerated paths, so it no longer reaches CI with a stale
generated file. A generator that FAILS is still logged rather than blocking the
rebase, and that case is the one that routes to an agent fix round.
