# worker-schema-ensure-columns

- **Family key:** `dc4787efd501` (the first 12 hex of `printf worker-schema-ensure-columns | sha1sum`)
- **30-day count when promoted:** 1 — this is an INCIDENT family, not a miner family
- **Projects:** cromford (the jobs worker)
- **Ruled by:** nobody. It was earned by #2462 (BH-2303) and scoped in BH-2473.

## The one finding it was mined from

#2462 added `["lane_id", "TEXT"]` to `cost_rows` in `ADDED_COLUMNS`
(`worker/jobs/src/lib/core.js`) and, in the same PR,
`CREATE INDEX … ON cost_rows(lane_id, ts)` to `worker/jobs/schema.sql`.
`lane_id` reaches a live D1 only through `ensureColumns`, which runs after the
deploy. `bin/harness-sync.sh` `worker_schema_apply` applies schema.sql BEFORE
`wrangler deploy`, so on live D1 the index failed with `no such column`, the
deploy was skipped, and every deploy after it failed the same way. Every schema
test in CI applied the file to a fresh database, where the CREATE TABLE makes
every column, so none of them saw it.

## What it catches

In ONE diff: an added `["col", "TYPE"]` tuple (the `ADDED_COLUMNS` shape) under
`worker/<w>/src/`, and an added single-line `CREATE [UNIQUE] INDEX … ON t(c1, …)`
in `worker/<w>/schema.sql` of the same worker whose column list names that col.
Since BH-6005 a schema PR carries only a fragment, so the check reads an index
added in `worker/<w>/schema.d/*.sql` the same way.

This is a fast heuristic for review and merge-sweep. A diff cannot carry main's
schema, so it only sees the same-diff shape. The authoritative gate is
`bin/worker-schema-upgrade.sh`, which the `worker-jobs` CI job runs over the
PR's base and which `tests/worker-schema-upgrade.bh-2473-test.sh` runs before a
PR is opened.

## The objectivity test

- **Measurable observation:** an index column name that also appears as the
  first element of an added `["col", "TYPE"]` tuple under the same worker's
  `src/`, both on added lines of the same diff.
- **Named tool:** `checks/worker-schema-ensure-columns/check.sh`, through
  `bin/checks-run.sh <diff>`.
- **Explicit threshold:** one or more such index columns.

## Known false positives

- **The column is ALSO added to the table's CREATE, and the table is new in the
  same diff.** A brand-new table is created with every column, so the index
  applies. The check does not know the table is new. The remedy is to leave the
  tuple out of `ADDED_COLUMNS` (a new table needs no ALTER), which is right anyway.
- **A same-named tuple for a DIFFERENT table.** The match is by column name
  within a worker, not by table, because `ADDED_COLUMNS` continuation lines do
  not carry the table name. A hit on an unrelated table costs one human read.
- **A `["x", "TEXT"]`-shaped literal under `worker/<w>/src/` that is not an
  `ADDED_COLUMNS` entry.** Same shape, same read.

## Known false negatives

- **The column was added to `ADDED_COLUMNS` in an EARLIER PR** and only the
  index is new. The diff has no tuple, so this check is silent; the replay in
  `bin/worker-schema-upgrade.sh` catches it (main's CREATE lacks the column).
- **A multi-line `CREATE INDEX`** whose `ON t(` is not on the first line.
- **Main's `ADDED_COLUMNS` are not replayed by the upgrade script either**, so a
  column main adds only through ensureColumns fails there LOUD, not silent.
