# The migration gate (a PR that carries schema says so)

**What it is:** the block in `bin/run-build.sh` between `# >>> migration gate`
and `# <<< migration gate` that looks at a build's diff before the PR opens and
answers two separate questions:

| question | answered by | what it feeds |
|---|---|---|
| which files in this diff are migration-shaped? | `migration_files_changed` in `bin/lib/migration-files.sh` | `MIG_FILES` → the `pipeline.log` line, `gates.json` `.migration_files`, the Evidence row |
| which of them does the appliability classifier lint? | `migration_sql_added` in `bin/lib/migration-files.sh` | `ADDED_SQL` → `bin/check-migration-appliable.sh`, `MIG_NOTE`, the forced tier 2 |

The two sets differ on purpose. Reporting is wide: added or changed
(`--diff-filter=ACMR`) `scripts/migrations/*.sql`, anything under
`prisma/migrations/**` including `manual/`, any `*.sql` under `prisma/`, and
`prisma/schema.prisma` / `prisma/schema/*.prisma`. Linting is narrow: ADDED
`scripts/migrations/*.sql` only, because that set is the app's own
`/api/internal/migrations` allowlist and Prisma's apply path was never written
against it.

The word that reaches the PR page comes out of `# >>> gates json`, widest first:

| word | means |
|---|---|
| `none` | no migration-shaped file in the diff |
| `present` | migration-shaped files, none of them linted (a Prisma migration) |
| `clean` | added `scripts/migrations/*.sql`, and the classifier passed it |
| `flagged` | the classifier found statements outside the allowlist — tier 2 forced |
| `gate-failed` | the classifier exited non-zero without a verdict — nothing judged the SQL |

**How a reviewer reaches it:** the Evidence table in the PR body, and the same
block in `<build>/evidence.md` — the `| migration gate | … |` row, rendered by
`bin/evidence-summary.sh`. When files were found the row names them:
`| migration gate | present — prisma/migrations/manual/2026-09-22-x.sql, prisma/schema/misc.prisma |`.
The one-line `Digest:` keeps the word only; paths would blow its 512-char cap.

**How to drive it:**

| what | how |
|---|---|
| the lib against a real git repo, both functions, all six path shapes plus the negatives | `HARNESS_TEST_SANDBOX=1 bash tests/migration-gate.bh-1355-test.sh` (section A) |
| the production gate block, extracted by its `# >>>` markers and run over a branch that adds only `prisma/migrations/manual/*.sql` | same suite, section B |
| the `gates.json` write — all five words | same suite, section C |
| the rendered Evidence row and `--json` | same suite, section D |
| the gate inside a whole PR-open render | `HARNESS_TEST_SANDBOX=1 bash tests/evidence-block-test.sh` |

**Files it writes on a live box:**

- `<build>/pipeline.log` — `MIGRATION GATE: N migration file(s) in diff: <paths>`
  when anything was found, and the existing
  `MIGRATION GATE: N flagged statement(s) — forced tier 2` when the classifier
  refused.
- `<build>/gates.json` — `.migration` (the word) and `.migration_files` (the
  list, `[]` when empty).
- `<build>/migration-gate.txt` — the classifier's own output, only when it ran.
  `bin/merge-sweep.sh` reads `scripts/migrations/…sql` back out of this file
  after a tier-2 merge, so its contents stay exactly what the classifier wrote.

**What must never regress:**

- **The gate never blocks a PR.** It is advisory. An unresolvable base, a
  detached head or a missing repo makes both lib functions print nothing and
  return 0 — never a crash, never a failed build.
- **`none` means nothing migration-shaped is in the diff**, not "nothing the
  classifier lints". That was BH-1355: project-5 PR #3082 added
  `prisma/migrations/manual/2026-09-22-TK-3071-analysis-config-in-flight.sql`
  and its Evidence block said `none`.
- **…and the gate does not cry wolf either.** A branch with no migration-shaped
  file still says `none`, still logs no `MIGRATION GATE` line, and still writes
  an empty `.migration_files`.
- **The classifier's input never widens by accident.** A `prisma/` file must
  never reach `bin/check-migration-appliable.sh`: a Prisma-generated
  `DROP INDEX` would force tier 2 on every PR that carried one. Widening the
  lint is a policy change, not a reporting change.
- **The classifier's word outranks the file list.** `flagged` and `gate-failed`
  are never softened to `present` or `clean`.
- **An old `gates.json` with no `migration_files` key renders byte-identically**
  to how it rendered before BH-1355 — `bin/evidence-summary.sh` is re-run months
  later against archived records.
- **Paths are table-safe and bounded.** A branch name is client-authored text:
  `clean 400` strips pipes and control characters before the row is printed.

**Manual-only / not automatable:** nothing. There is no UI and no network call —
the gate is git, jq and printf, and the suite drives every path.
