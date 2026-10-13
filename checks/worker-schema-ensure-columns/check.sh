#!/bin/bash
# checks/worker-schema-ensure-columns/check.sh
#
# FAMILY dc4787efd501 — "an index in schema.sql on a column only ensureColumns
# creates". An INCIDENT family (BH-2473), not a miner ruling: #2462 (BH-2303)
# added `["lane_id", "TEXT"]` to cost_rows in ADDED_COLUMNS
# (worker/jobs/src/lib/core.js) and, in the same PR,
# `CREATE INDEX … ON cost_rows(lane_id, ts)` to worker/jobs/schema.sql.
# bin/harness-sync.sh applies schema.sql BEFORE `wrangler deploy`, and
# ensureColumns only runs after it, so on live D1 the index failed with `no such
# column`, the deploy was skipped, and every later deploy stalled the same way.
#
# WHAT IT CATCHES. In ONE diff: an added `["col", "TYPE"]` tuple (the
# ADDED_COLUMNS shape) under worker/<w>/src/, and an added single-line
# `CREATE [UNIQUE] INDEX … ON t(c1, c2 …)` in worker/<w>/schema.sql or in a
# worker/<w>/schema.d/*.sql fragment of the same worker whose column list names
# that col. One hit per such index column.
#
# A FAST HEURISTIC, NOT THE GATE. A diff cannot carry main's schema, so this
# only sees the same-diff shape. The authoritative check is
# bin/worker-schema-upgrade.sh, which CI runs over the PR's base.
#
# Reads the normalized added-line stream on stdin (path<TAB>line<TAB>text).
# Prints "path:line<TAB>reason" per hit. rc 0 = clean, 1 = hits, 2 = the
# scanner died. DETECTION ONLY: it reads stdin and writes stdout. Nothing else.
# No interval quantifiers ({n}): /usr/bin/awk is mawk on Ubuntu runners.
set -uo pipefail
OUT=$(awk -F'\t' '
  # ["col", "TYPE"] tuples under worker/<w>/src/ — every one on the line.
  $1 ~ /^worker\/[^\/]+\/src\// {
    w = $1; sub(/^worker\//, "", w); sub(/\/.*$/, "", w)
    t = $3
    while (match(t, /\[[ \t]*"[A-Za-z_][A-Za-z0-9_]*"[ \t]*,[ \t]*"[A-Za-z][A-Za-z ]*"[ \t]*\]/)) {
      m = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
      sub(/^\[[ \t]*"/, "", m); sub(/".*$/, "", m)
      ADDED[w "|" tolower(m)] = 1
    }
    next
  }
  # CREATE [UNIQUE] INDEX … ON t(cols) in worker/<w>/schema.sql or a fragment.
  $1 ~ /^worker\/[^\/]+\/(schema\.sql|schema\.d\/[^\/]+\.sql)$/ {
    t = $3; u = toupper(t)
    if (u !~ /^[ \t]*CREATE[ \t]+(UNIQUE[ \t]+)?INDEX[ \t]/) next
    if (!match(u, /[ \t]ON[ \t]+[A-Z0-9_"`]+[ \t]*\(/)) next
    tbl = substr(t, RSTART, RLENGTH); rest = substr(t, RSTART + RLENGTH)
    sub(/^[ \t]*[Oo][Nn][ \t]+/, "", tbl); sub(/[ \t]*\($/, "", tbl); gsub(/["`]/, "", tbl)
    sub(/\).*$/, "", rest)
    w = $1; sub(/^worker\//, "", w); sub(/\/.*$/, "", w)
    n++; IW[n] = w; IP[n] = $1; IL[n] = $2; IT[n] = tbl; IC[n] = rest
    next
  }
  END {
    for (i = 1; i <= n; i++) {
      k = split(IC[i], cols, ",")
      for (j = 1; j <= k; j++) {
        c = cols[j]; gsub(/["` \t]/, "", c); sub(/(ASC|DESC|asc|desc)$/, "", c)
        if (!((IW[i] "|" tolower(c)) in ADDED)) continue
        printf "%s:%s\tindex on %s(%s), a column only ensureColumns creates; schema.sql applies BEFORE deploy, so live D1 lacks it and every worker deploy stalls (BH-2473, family dc4787efd501)\n", IP[i], IL[i], IT[i], c
      }
    }
  }
')
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "worker-schema-ensure-columns: could not run — the scanner exited $RC" >&2
  exit 2
fi
[ -n "$OUT" ] || exit 0
printf '%s\n' "$OUT"
exit 1
