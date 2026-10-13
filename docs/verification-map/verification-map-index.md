# Verification-map index (generated README)

**What it is:** `docs/verification-map/README.md` is no longer hand-edited, and
since BH-1175 it is no longer committed either. It is an artifact built by
`bin/verification-map-build.sh` from three kinds of source file; the sources are
what git carries, and CI generates the index and then validates those sources:

```
docs/verification-map/
  index/head.md          the title and the intro, above the table
  index/tail.md          the `## Driving conventions` section, below the table
  entries/<KEY>.md       one file per TICKET, holding that ticket's table row(s)
  README.md              GENERATED and GIT-IGNORED — the banner on line 1 says so
  <feature>.md           the feature entries themselves (unchanged)
```

Before BH-798, every build that added a feature added a row to the same table in
the same file. Two builds in flight conflicted on a file neither ticket was
about, and the committed table had picked up a stray blank line in the middle of
it — which splits a markdown table in two, so the last rows stopped rendering as
a table. Now each build writes a new file of its own and nothing shares a line.

BH-798 made the README generated; it stayed COMMITTED, so every build still
rewrote it and the conflict moved rather than went. `merge=union` (BH-865) and a
retrofit resolver (BH-868) bought time. The measurement that ended it: the file
was in 105 of the last 200 merges to main, it conflicted on every rebase of the
2026-09-20 drain, and it turned main red three times in one day when the union
driver duplicated a row on a squash merge. BH-1175 took it out of git — a
generated file that nothing commits cannot be the thing two branches fight over.
See [verification-map-no-commit.md](verification-map-no-commit.md).

**How an operator reaches it:**

- `bin/verification-map-build.sh` — regenerate the README from the sources.
- `bin/verification-map-build.sh --check` — validate the committed SOURCES: no
  duplicate row, every document link resolves, no README tracked in a repo that
  ignores it. rc 0 valid, rc 1 a source is wrong (each verdict names its file),
  rc 2 a missing source or a malformed entry line.
- `bin/verification-map-build.sh --check-committed` — the OLD byte comparison,
  for a repo that still COMMITS its index. `mc_resolve_vmap_clean_merge` and
  `bin/verification-map-retrofit.sh` use it as their repair trigger; cromford
  itself reaches neither path.
- CI runs the generator and then `--check` in the `lint` job of
  `.github/workflows/harness-ci.yml`.
- `bin/harness-sync.sh` regenerates the index in the box checkout after every
  pull, and `bin/publish-share.sh` regenerates it in the pinned clone before
  sanitizing — that is how a box's primer and a reader of the public mirror
  still see an index nothing commits.
- `bin/verification-map.sh render <project>` copies the generated README into the
  PLAN primer at `state/<project>-context.md`, so the banner is what the next
  planner and the next builder read first.

**How to add a feature entry (what a build does now):**

1. Write the feature's own entry file, `docs/verification-map/<feature>.md`.
2. Write `docs/verification-map/entries/<TICKET-KEY>.md` holding the table row
   for it — one complete `| feature | [x.md](x.md) | lane |` row per line, and
   nothing else. A ticket that ships two features puts both rows in its one file.
3. Run `bin/verification-map-build.sh` and commit the feature document and the
   entry file. **Not the README** — it is git-ignored, and a `git add -f` of it
   is what `--check` refuses by name.

**How to drive it:**

| what | how |
|---|---|
| the generator and both failure modes, on fixtures | `bash tests/verification-map-build-test.sh` |
| the no-commit contract, on real git | `bash tests/verification-map-no-commit-test.sh` |
| the source validation exactly as CI runs it | `bin/verification-map-build.sh --check` (rc 0) |
| that the check really fires | `cp docs/verification-map/entries/BH-1175.md docs/verification-map/entries/BH-0.md`, re-run `--check` (rc 1, names both files), then delete the copy |
| that the primer still reads it | `bin/verification-map.sh render cromford --repo .` and read the `VERIFICATION MAP` section of `state/cromford-context.md` |

**Files it owns:**

- `bin/verification-map-build.sh` — the generator.
- `docs/verification-map/index/head.md`, `index/tail.md`, `entries/*.md` — the sources.
- `docs/verification-map/README.md` — the artifact (git-ignored).
- `.gitignore` — the fence that keeps it out of git.
- `.github/workflows/harness-ci.yml` — the `lint` job's generate-and-validate step.

**What must never regress:**

- **The sources stay in subdirectories.** `bin/verification-map.sh` counts
  feature entries with `find … -maxdepth 1 -type f -name '*.md'`; a source file
  at the map root would be counted and listed in every primer as if it were a
  feature, making the entry count wrong everywhere it is quoted.
- **The `generated files` heading lives in `index/tail.md`, and the BANNER stays
  a blockquote.** `bin/batch-resolve.sh` finds a repo's regenerate table by that
  heading, and since BH-865 cromford declares one on purpose. Both parsers
  read `index/tail.md` directly since BH-1175 — the README they used to read is
  not in git any more, and a parser pointed only at it finds an empty table and
  switches the batch merge train off silently (see
  [generated-files-train.md](generated-files-train.md)). The banner is still a
  blockquote so that "GENERATED — do not edit by hand" is never read as the
  table itself.
- **`--check` never writes.** A check that repairs what it was asked to report
  makes the problem invisible.
- **The index is never committed.** `.gitignore` is the fence and `--check` is
  the gate; `tests/verification-map-no-commit-test.sh` proves both.
- **A refused run leaves the old README byte-identical.** The file is composed
  into a temp file beside it and moved into place only after every source
  validated.
- **The `## Driving conventions` heading survives generation.**
  `bin/verification-map.sh` extracts that section by its heading for the primer.
