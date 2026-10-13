#!/bin/bash
# bin/worker-schema-upgrade.sh — replay the live upgrade path of a worker's
# schema.sql: main's file first, then the PR's file over it (BH-2473).
#
# WHY. bin/harness-sync.sh `worker_schema_apply` puts worker/<w>/schema.sql on
# a database that ALREADY holds main's schema, and it does so BEFORE `wrangler
# deploy`. Every schema test CI ran applied the file to a FRESH database, where
# the CREATE TABLE makes every column. #2462 (BH-2303) added
# `CREATE INDEX … ON cost_rows(lane_id, ts)` while `lane_id` reached live D1
# only through ensureColumns (ADDED_COLUMNS in worker/jobs/src/lib/core.js),
# which runs after deploy: on the live database the index failed with `no such
# column`, the deploy was skipped, and every later deploy failed the same way.
# A fresh database cannot see that. This replays what live D1 actually gets.
#
# HOW. Both files are split with d1_schema_statements (bin/lib/d1-schema.sh),
# exactly as worker_schema_apply splits them. One in-memory sqlite database,
# autocommit (isolation_level=None, one execute() per statement, the way each
# D1 `--command` commits), takes every BASE statement and then every HEAD
# statement in file order. HEAD goes in full, not as the delta: that is
# worker_schema_apply's no-stamp path and a superset of its delta path, since
# every statement is IF NOT EXISTS / OR IGNORE. Unlike worker_schema_apply this
# does not stop at the first failing HEAD statement: it names every one, which
# is the same verdict with more to read.
#
# KNOWN LIMIT: main's ensureColumns columns are NOT replayed onto the base.
# A PR that indexes a column main's ADDED_COLUMNS adds but main's CREATE TABLE
# omits fails here although live D1 has the column. That fails LOUD, not
# silent. As of 2026-09-25 one column is in that corner:
# merge_trains.train_group is in ADDED_COLUMNS but not in its CREATE, so an
# index on it would fail here although live D1 has it.
#
# Usage:  worker-schema-upgrade.sh --files <base.sql> <head.sql>
#         worker-schema-upgrade.sh --base <git-ref> [--root <dir>]
#           every worker/*/ in <root> (default: this script's repo) that has
#           a schema.d/ or a schema.sql. head = the composition of the working
#           tree's schema.d/ (bin/schema-build.sh) when it exists, else the
#           working tree's schema.sql. base = `git show <ref>:worker/<w>/schema.sql`
#           when <ref> tracks it, else the composition of <ref>'s schema.d/
#           (schema-build.sh --ref). A worker with neither at <ref> is a NEW
#           worker: its base is empty, which is a fresh database. A schema.d/
#           that does not compose is rc 2, never an empty base. Labels stay
#           worker/<w>/schema.sql either way.
# Output: `SCHEMA-UPGRADE FAIL <label> statement <n>/<m>: <error> :: <head>`
#         per failing HEAD statement, then one summary line —
#         `SCHEMA-UPGRADE: ok (<w>: base <a> + head <b> statements)` or
#         `SCHEMA-UPGRADE: <n> statement(s) fail over <ref>`.
# rc 0 = every statement applied; 1 = a HEAD statement failed; 2 = could not
# run (no python3/sqlite3, unreadable or empty head, a BASE statement that
# fails on a fresh db, an unresolvable ref, no worker schema at all). rc 2 is
# red in CI: a check that did not run never reads as a pass.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$SELF/lib/d1-schema.sh" || exit 2

die2() { echo "SCHEMA-UPGRADE: could not run — $*"; exit 2; }

command -v python3 >/dev/null 2>&1 || die2 "no python3 on PATH"
python3 -c 'import sqlite3' 2>/dev/null || die2 "python3 has no sqlite3 module"

TMP=$(mktemp -d) || die2 "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

# replay <label> <base.sql> <head.sql> — prints the FAIL lines and one
# `REPLAY <nfail> <nbase> <nhead>` line; rc 0 ran, 2 could not run.
replay() {
  local label="$1" base="$2" head="$3" nb nh
  local -a bs hs
  [ -r "$head" ] || { echo "SCHEMA-UPGRADE: could not run — $label: head $head is unreadable"; return 2; }
  mapfile -t -d '' hs < <(d1_schema_statements "$head")
  nh=${#hs[@]}
  [ "$nh" -gt 0 ] || { echo "SCHEMA-UPGRADE: could not run — $label: head reads as 0 statements"; return 2; }
  bs=()
  if [ -s "$base" ]; then
    mapfile -t -d '' bs < <(d1_schema_statements "$base")
    [ "${#bs[@]}" -gt 0 ] || { echo "SCHEMA-UPGRADE: could not run — $label: base is not empty but reads as 0 statements"; return 2; }
  fi
  nb=${#bs[@]}
  # Statements go NUL-delimited on stdin: base count first, then base, then head.
  { printf '%s\0' "$nb"; [ "$nb" -gt 0 ] && printf '%s\0' "${bs[@]}"; printf '%s\0' "${hs[@]}"; } \
    | python3 -c '
import sqlite3, sys
label = sys.argv[1]
parts = sys.stdin.buffer.read().decode("utf-8").split("\0")
if parts and parts[-1] == "":
    parts.pop()
nb = int(parts[0])
base, head = parts[1:1 + nb], parts[1 + nb:]
db = sqlite3.connect(":memory:", isolation_level=None)
for i, s in enumerate(base, 1):
    try:
        db.execute(s)
    except sqlite3.Error as e:
        print("SCHEMA-UPGRADE: could not run — %s: BASE statement %d/%d fails on a fresh db (%s) :: %s"
              % (label, i, nb, e, " ".join(s.split())[:120]))
        sys.exit(2)
nfail = 0
for i, s in enumerate(head, 1):
    try:
        db.execute(s)
    except sqlite3.Error as e:
        nfail += 1
        print("SCHEMA-UPGRADE FAIL %s statement %d/%d: %s :: %s"
              % (label, i, len(head), e, " ".join(s.split())[:120]))
print("REPLAY %d %d %d" % (nfail, nb, len(head)))
' "$label"
}

# run_one <label> <worker> <base.sql> <head.sql> [note] — accumulates into
# NFAIL / OKS; exits 2 on could-not-run.
NFAIL=0; OKS=""
run_one() {
  local label="$1" w="$2" base="$3" head="$4" note="${5:-}" out rc line f b h
  out=$(replay "$label" "$base" "$head"); rc=$?
  line=$(printf '%s\n' "$out" | grep '^REPLAY ' | tail -1)
  printf '%s\n' "$out" | grep -v '^REPLAY '
  [ "$rc" = 0 ] && [ -n "$line" ] || exit 2
  read -r _ f b h <<<"$line"
  NFAIL=$((NFAIL + f))
  OKS="${OKS:+$OKS; }$w: base $b + head $h statements${note:+, $note}"
}

case "${1:-}" in
  --files)
    [ $# = 3 ] || die2 "usage: --files <base.sql> <head.sql>"
    [ -r "$2" ] || die2 "base $2 is unreadable"
    REF="$2"
    run_one "$3" "$(basename "$3")" "$2" "$3"
    ;;
  --base)
    REF="${2:-}"; [ -n "$REF" ] || die2 "usage: --base <git-ref> [--root <dir>]"
    ROOT="$SELF/.."
    if [ "${3:-}" = "--root" ]; then ROOT="${4:-}"; [ -d "$ROOT" ] || die2 "no such root '$ROOT'"; fi
    git -C "$ROOT" rev-parse --verify -q "$REF^{commit}" >/dev/null 2>&1 \
      || die2 "git cannot resolve ref '$REF' in $ROOT"
    N=0
    for D in "$ROOT"/worker/*/; do
      W=$(basename "$D"); H="$ROOT/worker/$W/schema.sql"
      [ -d "$ROOT/worker/$W/schema.d" ] || [ -f "$H" ] || continue
      N=$((N + 1))
      if [ -d "$ROOT/worker/$W/schema.d" ]; then
        H="$TMP/$W.head.sql"
        "$SELF/schema-build.sh" --root "$ROOT" --worker "$W" --to "$H" 2> "$TMP/$W.err"; rc=$?
        [ "$rc" = 0 ] || { cat "$TMP/$W.err"; die2 "worker/$W/schema.d could not be composed (schema-build rc $rc)"; }
      fi
      NOTE=""
      if git -C "$ROOT" cat-file -e "$REF:worker/$W/schema.sql" 2>/dev/null; then
        git -C "$ROOT" show "$REF:worker/$W/schema.sql" > "$TMP/$W.base.sql" \
          || die2 "git show $REF:worker/$W/schema.sql failed"
      elif git -C "$ROOT" cat-file -e "$REF:worker/$W/schema.d" 2>/dev/null; then
        "$SELF/schema-build.sh" --root "$ROOT" --ref "$REF" --worker "$W" --to "$TMP/$W.base.sql" 2> "$TMP/$W.err"; rc=$?
        [ "$rc" = 0 ] || { cat "$TMP/$W.err"; die2 "worker/$W/schema.d at $REF could not be composed (schema-build rc $rc)"; }
      else
        : > "$TMP/$W.base.sql"
        echo "SCHEMA-UPGRADE: worker/$W has no schema.sql or schema.d at $REF — a NEW worker, so its base is a fresh database"
        NOTE="new worker"
      fi
      run_one "worker/$W/schema.sql" "$W" "$TMP/$W.base.sql" "$H" "$NOTE"
    done
    [ "$N" -gt 0 ] || die2 "no worker/*/schema.sql or schema.d under $ROOT"
    ;;
  *)
    die2 "usage: worker-schema-upgrade.sh --files <base.sql> <head.sql> | --base <git-ref> [--root <dir>]"
    ;;
esac

if [ "$NFAIL" -gt 0 ]; then
  echo "SCHEMA-UPGRADE: $NFAIL statement(s) fail over $REF"
  exit 1
fi
echo "SCHEMA-UPGRADE: ok ($OKS)"
exit 0
