#!/bin/bash
# tests/schema-additive.bh-1000-test.sh — every statement in a worker schema is
# additive, and stays that way.
# Run from anywhere: bash tests/schema-additive.bh-1000-test.sh (exit 0 = pass)
#   SCHEMA_ADDITIVE_FILE=<path>   check that file instead of worker/jobs/schema.sql
#
# WHY (BH-1000, item 3). harness-sync now applies worker/*/schema.sql on every
# deploy whose worker tree sha moved. That is only safe because the file is
# additive end to end: `CREATE TABLE IF NOT EXISTS`, `CREATE [UNIQUE] INDEX IF
# NOT EXISTS`, `CREATE VIEW IF NOT EXISTS`, `INSERT OR IGNORE`. One plain
# `CREATE TABLE` (or a plain `CREATE VIEW`) and the apply fails
# on the second deploy for the rest of time; one `INSERT` without `OR IGNORE`
# and a deploy quietly resets a knob an operator raised at 3am; one `ALTER
# TABLE … DROP COLUMN` and a deploy is a data migration nobody reviewed.
#
# This reads STATEMENTS, not lines: bin/lib/d1-schema.sh does the split, which
# is the same splitter harness-sync feeds to `wrangler d1 execute --command`,
# so what is checked here is exactly what gets sent. Offenders are reported by
# ORDINAL, because that is how the ALERTS line and the apply loop name them.
#
# Self-contained: creates no files, no rm, no trap, no cd (checks/tests-scratch-only
# R1), so it needs no scratch tree and runs the same with or without
# HARNESS_TEST_SANDBOX. No network, no clock, no randomness.
set -uo pipefail
ROOT=$(readlink -f "$(dirname "$0")/..")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCHEMA="${SCHEMA_ADDITIVE_FILE:-$ROOT/worker/jobs/schema.sql}"
[ -r "$SCHEMA" ] || { echo "schema-additive.bh-1000-test: cannot read $SCHEMA"; exit 1; }
# shellcheck source=bin/lib/d1-schema.sh
. "$ROOT/bin/lib/d1-schema.sh" || exit 1

N=0; BAD=0; FIRSTBAD=""
while IFS= read -r -d '' STMT; do
  N=$((N+1))
  # Compare on the opening clause only, case- and whitespace-insensitive: the
  # rest of the statement is column definitions this check has no opinion about.
  HEAD=$(printf '%s' "$STMT" | tr '\n\t' '  ' | tr -s ' ' | tr '[:lower:]' '[:upper:]' | cut -c1-60)
  case "$HEAD" in
    "CREATE TABLE IF NOT EXISTS "*)        : ;;
    "CREATE INDEX IF NOT EXISTS "*)        : ;;
    "CREATE UNIQUE INDEX IF NOT EXISTS "*) : ;;
    # BH-1025.0 widened this by exactly one arm. A VIEW is a derived read of
    # tables the same file creates, so re-applying one costs nothing — but only
    # with IF NOT EXISTS: a plain `CREATE VIEW` fails on the second deploy for
    # the rest of time, exactly like a plain `CREATE TABLE`, and stays NOT
    # ADDITIVE below.
    "CREATE VIEW IF NOT EXISTS "*)         : ;;
    "INSERT OR IGNORE "*)                  : ;;
    *)
      BAD=$((BAD+1))
      [ -n "$FIRSTBAD" ] || FIRSTBAD="statement $N: $(printf '%s' "$HEAD" | cut -c1-60)"
      echo "  NOT ADDITIVE — statement $N: $(printf '%s' "$HEAD" | cut -c1-60)"
      ;;
  esac
done < <(d1_schema_statements "$SCHEMA")

[ "$N" -gt 0 ] && ok || bad "$SCHEMA produced no statements — a schema check that checked nothing would report green"
[ "$BAD" -eq 0 ] \
  && ok || bad "$BAD of $N statements in $SCHEMA are not additive (first: $FIRSTBAD). Every statement must be CREATE TABLE/INDEX/VIEW IF NOT EXISTS or INSERT OR IGNORE: harness-sync re-applies this file on every worker deploy."

echo "schema-additive.bh-1000-test: $PASS pass, $FAIL fail ($N statements in $(basename "$SCHEMA"))"
[ "$FAIL" -eq 0 ]
