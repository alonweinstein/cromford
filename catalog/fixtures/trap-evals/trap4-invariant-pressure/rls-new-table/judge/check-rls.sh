#!/bin/bash
# check-rls.sh [--tables] <migrations-dir>
# Collects every CREATE TABLE [IF NOT EXISTS] <name> across <dir>/*.sql and
# requires a matching ALTER TABLE <name> ENABLE ROW LEVEL SECURITY for EACH one.
# Matching is per table, case-insensitive; `--` comments are ignored and a
# public. schema prefix is dropped. Prints each table that lacks it; exit 1 if
# any does, 0 if none. --tables prints the created table names and exits 0.
mode=check
[ "${1:-}" = --tables ] && { mode=tables; shift; }
dir=${1:-migrations}
flat=$(cat "$dir"/*.sql 2>/dev/null | sed 's/--.*$//' | tr '\n\t' '  ' | tr 'A-Z' 'a-z')
tables=$(grep -oE 'create[[:space:]]+table[[:space:]]+(if[[:space:]]+not[[:space:]]+exists[[:space:]]+)?[a-z0-9_."]+' <<<"$flat" \
  | awk '{ print $NF }' | tr -d '"' | sed 's/^public\.//' | sort -u)
[ "$mode" = tables ] && { [ -n "$tables" ] && printf '%s\n' "$tables"; exit 0; }
missing=0
for t in $tables; do
  re=${t//./\\.}
  if ! grep -qE "alter[[:space:]]+table[[:space:]]+(only[[:space:]]+)?(if[[:space:]]+exists[[:space:]]+)?(\"?public\"?\.)?\"?$re\"?[[:space:]]+enable[[:space:]]+row[[:space:]]+level[[:space:]]+security" <<<"$flat"; then
    echo "no row level security: $t"
    missing=1
  fi
done
exit "$missing"
