# Ledger stamps and cursors (who wrote this time, and is it still true)

**What it is:** four small pieces of state that other lanes read as if they were
facts — a PR-ownership stamp, a rehydrate cursor, a catalog-sync stamp and a
ticket keymap. Each is written by one lane and trusted by another, and each of
them was wrong in a way nothing logged (BH-1042, from the 2026-09-19 audit).

**How an operator reaches it:** no UI. These are cron lanes on the hub and on
every box; the artifacts below are files on a live box.

| the state | written by | read by | the rule |
|---|---|---|---|
| `state/pr-owners/<owner>_<repo>.json` → `synced_as_of` | `bin/pr-owner-sweep.sh` (per-project cron), from the `as_of` its own PUT answered with | the D1 overlay in the same script | a `pr_owners` row overlays a PR only when `row.updated_at >= (synced_as_of // generated_at)`. Both sides are the WORKER's clock; `generated_at` is this box's own write time and only the fallback |
| the `since` cursor of `log_rehydrate` | `bin/jobs-client.sh` | `GET /api/decisions` / `/api/findings`, which compare `stamp >= since` as STRINGS | the cursor is `%Y-%m-%d %H:%M:%SZ` — the exact format `bin/decision-log.sh` and `bin/findings-log.sh` stamp lines with. A `T` there drops the whole boundary day |
| `state/catalog-synced` | `bin/harness-sync.sh` deploy path, one line, the manifest's tree sha | the same block next deploy | the sha gate keeps a routine deploy from being a PUT — but the stamp is checked against the DB first (`jobs-client.sh catalog-probe`), so a reset table voids it and re-pushes |
| `state/<project>.keymap.json` | `bin/triage-gate.sh` fingerprint pass, every consumed tick | the client-court guard in `bin/lib/rt/shards.sh` | closed tickets are not in the map, and a queue row's own `ticket_id` outranks it |

**Key lanes/scripts:**
- `bin/pr-owner-sweep.sh` — the overlay (`# THE D1 MIRROR OF THIS FILE`) and the
  file → PUT → stamp block below the classifier
- `bin/jobs-client.sh` — `log_rehydrate`, and the read-only `catalog_probe` /
  `catalog-probe` verb (rc 0 catalog, rc 2 no row, rc 1 no answer)
- `bin/harness-sync.sh` — the probe block just above the catalog push
- `bin/triage-gate.sh` keymap persist + `bin/lib/rt/shards.sh`
  `# >>> client-court guard`

**Preconditions / seed needs:** none for the suites — every one of them builds
its own scratch `$HARNESS`, its own bare git origin where it needs one, and
shims `curl`/`gh`. They must run with `HARNESS_TEST_SANDBOX=1` on a box next to
a live `/root/harness`, or `tests/lib/scratch.sh` refuses.

**How to drive it:**

| what | how |
|---|---|
| the overlay under clock skew, both directions | `HARNESS_TEST_SANDBOX=1 bash tests/pr-owner-sweep-server-clock.bh-1042-test.sh` |
| the rehydrate cursor and the boundary day | `HARNESS_TEST_SANDBOX=1 bash tests/jobs-client-rehydrate-boundary.bh-1042-test.sh` |
| the catalog stamp vs a reset DB, plus the probe verb itself | `HARNESS_TEST_SANDBOX=1 bash tests/harness-sync-catalog-reset.bh-1042-test.sh` |
| the keymap filter and the guard's lookup order | `HARNESS_TEST_SANDBOX=1 bash tests/triage-gate-keymap-stale.bh-1042-test.sh` |
| the neighbours these four must not cost | `tests/ledger-writethrough-test.sh`, `tests/pr-owner-sweep-test.sh`, `tests/jobs-client-ledger-verbs-test.sh`, `tests/repeat-family-test.sh`, `tests/harness-sync-stamps-test.sh`, `tests/client-court-gate-test.sh`, `tests/triage-gate-argmax-test.sh` |

**Verify it works on a live box:**
- `jq -r '.synced_as_of' /root/harness/state/pr-owners/*.json` — present after
  the next sweep tick, and it is the worker's stamp, not today's local time
- `grep rehydrated /root/harness/logs/jobs-client.log` — the count matches the
  rows that exist on the boundary day, not one short
- `grep 'budget catalog' /root/harness/logs/update-runners.log` — a
  `stamp voided` line appears only if the table really was reset; a normal
  deploy says nothing
- `jq -r 'to_entries[] | .key' /root/harness/state/<project>.keymap.json` — no
  key belonging to a ticket the board shows as done

**What must never regress:**
- **A row the worker stamped BEFORE our push must never overlay.** That is
  BH-435's failed-PUT protection, and the skew fix must not spend it.
- **An outage is not a reset.** `catalog-probe` rc 1 keeps the stamp. Only a
  worker that ANSWERED, and answered `source != "catalog"`, may void it.
- **The keymap fails open.** A status nobody here has seen counts as open.
  Dropping a live key costs a build; keeping a dead one costs one gate call.
- **A `board`-class shard line never consults a queue row or the keymap** — it
  already carries the raw ticket id.
- **No new page.** The only alert any of this can raise is `bin/jobs-client.sh`'s
  existing once-a-day `harness-jobs unreachable` line.

**Manual-only / not automatable:** the live-box checks above — they need a
deployed hub and a real `harness-jobs` worker, so no suite drives them.
