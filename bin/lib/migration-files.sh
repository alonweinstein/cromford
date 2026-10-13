#!/bin/bash
# bin/lib/migration-files.sh — which files in a diff are migration-shaped.
#
# Sourceable, side-effect free, safe under the caller's `set -u`: it defines two
# functions, reads one git repo and prints paths. Nothing else.
#
# WHY (BH-1355). The migration gate's whole file detection was one pathspec,
# `scripts/migrations/*.sql`, so everything under `prisma/` was invisible to it.
# project-5 PR #3082 added
# `prisma/migrations/manual/2026-09-22-TK-3071-analysis-config-in-flight.sql`
# and changed `prisma/schema/misc.prisma`, and its Evidence block told the
# reviewer `migration gate: none`. No damage that time — project-5's
# migrate-manual.yml applies added files on merge — but the gate exists so a
# human is TOLD a PR carries schema, and a `none` on a PR that adds SQL is the
# gate lying.
#
# TWO QUESTIONS, TWO FUNCTIONS, DELIBERATELY DIFFERENT ANSWERS:
#
#   migration_files_changed  what the EVIDENCE names — every migration-shaped
#                            file added or changed in the diff, whatever applies
#                            it. This is reporting, and it is wide.
#   migration_sql_added      what the appliability classifier LINTS — added
#                            `scripts/migrations/*.sql` and nothing else, byte
#                            for byte the query it has always run. That set is
#                            the app's own /api/internal/migrations allowlist;
#                            Prisma's apply path was never written against it,
#                            so widening the lint would force tier 2 on every PR
#                            carrying a Prisma-generated statement. Reporting a
#                            Prisma migration and linting one are separate
#                            decisions and this ticket only made the first.
#
# `--diff-filter=ACMR` is "added or changed": renames count, because Prisma
# migration folders get renamed on a rebase and a rename still ships schema.
# Deletions do not — removing SQL is `bin/scope-gate.sh`'s business, and it
# already protects `prisma/`.
#
# Both functions are advisory and must never be able to fail a build: an
# unresolvable base, a detached head or a missing repo prints nothing and
# returns 0. The gate that calls them never blocks a PR.

# migration_files_changed <base> <dir> — one path per line, sorted, unique.
migration_files_changed() {
  local base="${1:-}" dir="${2:-.}"
  git -C "$dir" diff --name-only --diff-filter=ACMR "$base"...HEAD -- \
      'scripts/migrations/*.sql' \
      'prisma/migrations/**' \
      'prisma/*.sql' \
      'prisma/**/*.sql' \
      'prisma/schema.prisma' \
      'prisma/schema/*.prisma' \
    2>/dev/null | sort -u || true
}

# migration_sql_added <base> <dir> — the classifier's input, unchanged.
migration_sql_added() {
  local base="${1:-}" dir="${2:-.}"
  git -C "$dir" diff --name-only --diff-filter=A "$base"...HEAD -- \
      'scripts/migrations/*.sql' 2>/dev/null || true
}
