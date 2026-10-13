# Conductor held pages + mode contract (BH-1201.0)

**What it is:** the interface every other BH-1201 child imports. The merge
conductor holds a PR when it cannot spend on it (`STUCK`: nothing moved) or must
not (`BUDGET`: the tick's budget is gone). This chunk makes that hold a D1 row the
whole fleet can read, publishes the conductor's MODE as a settings row, and ships
the reader helper that answers "is this lane held".

**No behaviour change on any lane.** The conductor does not write these rows yet
and no reader consults them yet. Until the conductor child ships, the settings row
is absent and `conductor_mode` prints `unknown` — that is the documented cold-start
state, and `unknown` HOLDS (fail closed on spend; a hold is re-offered next tick,
not dropped).

**How you reach it:** in the console, `/merge-queue` (Kanban header → MERGE
QUEUE) renders the held pages read-only in its HELD PAGES section (BH-3158).
Two ways in without the console, both bearer-gated:

- from a box, the client: `bin/jobs-client.sh held-pages-list [limit]`,
  `held-page-put`, `held-page-release`, `conductor-mode-publish`
- directly:
  `curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/conductor/held"`
  → `{"rows":[],"n_total":0}` on a cold table

**The primary lane:** none yet, by design. `bin/merge-conductor.sh`
(`cron/hub.cron`, \*/5) is the lane that will publish the mode and the held pages
once its own BH-1201 child lands; this chunk only provides the store and the
verbs, and the ticket says so explicitly.

## The table

`conductor_held_pages`, in `worker/jobs/schema.sql` and mirrored verbatim under
`CREATED_TABLES.conductor_held_pages` in `worker/jobs/src/lib/core.js` (a test
compares the two strings whitespace-normalised). Two apply mechanisms, so the
table is never waiting on a human: `bin/harness-sync.sh` applies `schema.sql`
statement by statement before `wrangler deploy`, and `ensureTable` self-creates it
on first use for a D1 that predates BH-1201 (BH-1043: a table that waits on a hand
apply ships DEAD).

`PRIMARY KEY (repo, number, state, head, kind)` — the identity of the HOLD, not of
the PR. A PR whose head moved or whose state changed is a new hold with its own
age, because the question a reader asks is "how long has it been stuck like THIS",
and one PR can be held for two reasons at once. `first_held_at` never moves on
re-sighting; `last_seen_at` is bumped every tick.
`CREATE INDEX idx_conductor_held_first ON conductor_held_pages(first_held_at)` —
oldest-first is the only order anyone reads this table in.

## Key routes

All three are in `ROUTES` (bearer `HARNESS_SECRET`), none in `OPEN_ROUTES`, and all
three call `ensureTable(env, "conductor_held_pages")` before their first statement.

- `PUT /api/conductor/held` `{repo, number, state, head, kind, text, mark?, mode}`
  → 200 `{ok:true}`. ONE statement:
  `INSERT ... ON CONFLICT(repo, number, state, head, kind) DO UPDATE SET text=excluded.text, mark=excluded.mark, mode=excluded.mode, last_seen_at=excluded.last_seen_at`.
  `first_held_at` is deliberately NOT in the update list. 400 on a malformed field:
  `repo` `/^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/`, `number` a positive integer (a
  string `"12"` or `12.5` is refused, never truncated), `state` one of the 13
  `MC_STATES` words (`bin/lib/mc/log.sh:98`), `head` 1..64 chars, `kind`
  `STUCK|BUDGET`, `text` 1..2000 chars, `mode` one of the four conductor MODE words
  (`bin/merge-conductor.sh:218`). An absent or empty `mark` stores NULL.
- `GET /api/conductor/held?limit=N` → 200 `{rows, n_total}` ordered
  `first_held_at ASC, repo, number`. An ABSENT `limit` is the documented default of
  100; an integer out of range clamps into 1..500; a present-but-non-integer value
  (`limit=abc`, `limit=1.5`, a blank `limit=`) is a **400**. That refusal is the one
  place this family departs from the sibling list routes in this worker, which all
  spell it `Number(raw) || default`: `limit=abc` is a caller bug, and a silent
  100-row page reads to it as the whole table (D11). `n_total` is a measured
  `COUNT(*)` over the whole table, not the page length.
- `POST /api/conductor/held/release` `{repo, number, state, head, kind, why}` →
  200 `{released: 0|1}`, `meta.changes` from the DELETE. A release of an absent row
  is `{released:0}` and never a 404 — 0 is a real answer, and a 404 reads as "the
  worker is not deployed" to a fail-open client. `why` is **required** (a string,
  1..2000): a release is the one destructive verb in this family, so the reason is
  demanded from the caller that already knows it. `why` is persisted as the
  `reason` of one `held_page` `config_changes` row (name `<repo>#<number>`,
  `before_json` holding `state`, `head`, `kind`, `text`, `mode`, `first_held_at`,
  `after_json` the text `'null'`), written in the same batch as the DELETE and
  only when a row was actually there (BH-3156). An absent or empty `why` is a
  400 that deletes nothing, and `bin/lib/jobs/conductor.sh` refuses an empty one
  client-side (rc 1, no request) so a fail-open caller does not read the 400 as an
  outage.

## The two settings keys

Published by `conductor_mode_publish <mode> <summary>` in `bin/lib/jobs/conductor.sh`:

- `merge-conductor.mode` — one of `merge|actions|observe|kill-switch`
- `merge-conductor.held_pages` — the tick summary, e.g. `12 STUCK=5 BUDGET=7`, or
  `0`, truncated to the settings 256-char limit

The mode is a settings row rather than a field on the lanes tick body because
`settings` already has GET-by-key, the readers' 60 s cache
(`state/settings-cache.json` via `_lg_settings_refresh`) and console visibility.

## The reader helper

`bin/lib/conductor-mode.sh`:

- `conductor_mode` prints exactly one of `merge|actions|observe|kill-switch|unknown`.
  It reads the settings row through `_lg_setting_lookup` when `lane-gate.sh` is
  loaded, else `setting_get` (rc 2 = no row). Any other value, an rc 1/2, or no
  client at all prints `unknown`. It NEVER tests a flag file, another lane's
  `state/`, or a log file — the suite pins this by touching
  `flags/automerge-disabled` while the worker answers `merge` and asserting no hold.
- `conductor_hold_active <lane-id> <KNOB_ENV>` — rc 0 (hold) when `conductor_mode`
  is `kill-switch|observe|unknown` AND `lane_knob <lane-id> <KNOB_ENV>` is not `0`
  (empty, unset or unregistered reads as 1 = hold on). Prints the mode word for the
  caller's log line.

## How you drive it

```
cd worker/jobs && node --test test/conductor-held.bh-1201.test.js   # routes, upsert, order, release, 400s, 401s
cd worker/jobs && node --test test/route-table.test.js              # the three routes are in the CHAIN in their index.js position
HARNESS_TEST_SANDBOX=1 tests/conductor-mode.bh-1201-test.sh         # the client verbs and the reader helper, against a fake curl
```

The JS suite runs against a real `schema.sql` database on `node:sqlite` with the
table DROPPED, so the self-create is proven rather than assumed; it skips if
`node:sqlite` is unavailable on the runtime.
