# Fleet registry (BH-5649 read path, BH-5650 writes, BH-5651 switch; waves 1-3 of BH-5633)

**What it is:** the project, box, lane-membership and account-to-box registry
in harness-jobs D1, with a reader that `bin/fleet-conf.sh` and
`bin/render-cron.sh` use when `REGISTRY_SOURCE=db`. The code default `file`
reads only the committed `fleet.conf` and `catalog/lanes.d`. Since BH-5651,
`bin/harness-sync.sh` appends `REGISTRY_SOURCE=db` to `env/global.env` when the
registry answers with the checkout's project set; `REGISTRY_SOURCE=file` there
is the kill switch. On a db box `$H/fleet.conf` is an export of the registry.
Operators change it with `bin/registry.sh` (BH-5650); every write is audited.
No UI.

**How a user reaches it:** an operator shell on the hub. There is no screen.

**Key routes/screens:**
- `GET /api/registry` — the full registry and its version (bearer `HARNESS_SECRET`)
- `GET /api/registry/version` — `{version, updated_at}`, the cheap probe
- `POST /api/registry/import` — the seeder's write path; also needs header
  `x-registry-admin-token` equal to the worker secret `REGISTRY_ADMIN_TOKEN`
- `bin/registry-seed.sh [--emit] [--root <dir>] [--actor <name>]` — builds the
  import payload from the committed files; `--emit` prints it with no call
- `bin/fleet-conf.sh` / `bin/box-for.sh` / `bin/render-cron.sh` with
  `REGISTRY_SOURCE=db` — read the API, then `state/registry/`, then the files
- Write routes (BH-5650, `worker/jobs/src/routes/registry-write.js`), each with
  the bearer AND `x-registry-admin-token`: `POST /api/registry/projects`,
  `PATCH|DELETE /api/registry/projects/<project>`, `POST /api/registry/boxes`
  (optional `like: <box_id>`), `PATCH|DELETE /api/registry/boxes/<box>`,
  `POST /api/registry/boxes/<box>/drain`, `POST /api/registry/lane-boxes`,
  `DELETE /api/registry/lane-boxes/<lane>/<box_id>`,
  `POST /api/registry/box-accounts`,
  `DELETE /api/registry/box-accounts/<account>/<kind>/<box>` (URL-encode `*`).
  Answer `{ok, changed, version}`; 0 changes = no audit row, same version.
- `bin/registry.sh show | add-box <name> --ip <ip> --like <box-id> [--id <id>]
  | move-project <p> --box <box> | drain-box <box> | add-project <p> --repo
  <slug> --prod <url|-> --offset <0-9> --box <box>` — the operator CLI
- `GET /api/registry` `.known_lanes` — every lane the audit ever held a
  membership for; the render gives such a lane with no rows zero boxes
- `cron/boxes/_template.d/` — the box fragments of a box with no own directory
- `bin/registry-sync.sh` — the `*/5` lane on every box: run
  `bin/registry-export.sh --install` every tick, then re-render and apply the
  crontab only when the registry version changed (db mode only)
- `bin/registry-export.sh` (BH-5651) — `--fleet-conf [--template f]` and
  `--cost-accounts --template f` print the export; `--install <root>
  [--checkout d]` replaces `$H/fleet.conf` and the box maps of
  `$H/catalog/cost-accounts.json` (db mode only, only on a byte change, refuses
  a render whose project set is not the registry's); `--snapshot <dir> [--keep
  N]` writes a dated snapshot; `--registry f` reads that file instead of the
  read ladder
- Lane `registry-export` (BH-5651, hub only, `41 3 * * *`) — `bin/registry-export.sh
  --snapshot /root/harness/state/registry/export`; keeps `REGISTRY_EXPORT_KEEP`
  (14) dirs `state/registry/export/<YYYYmmddTHHMMSSZ>/` with `registry.json`,
  `import.json`, `fleet.conf`, `cost-accounts.json`; `latest` points at the
  newest; three failed runs in a row write one ALERTS line
- `bin/registry-seed.sh --from-export <dir|import.json> [--force]` — restore D1
  from a snapshot (docs/RESTORE.md §7). Without `--force` the seed refuses a
  registry at version 1 or more

**Selectors:** none (no UI).

**Preconditions / seed needs:** `bin/harness-sync.sh` applied the BH-5649 block
of `worker/jobs/schema.sql`; the worker secret `REGISTRY_ADMIN_TOKEN` is set and
the same value is in the operator env; `bin/registry-seed.sh` ran once.

**Verify it works:**
1. `curl -s -o /dev/null -w '%{http_code}\n' -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/registry/version"` answers 200 (503 `registry schema not applied` means the schema is missing).
2. The same URL with no bearer answers 401.
3. `bin/registry-seed.sh --emit | jq '.projects | map(select(.status == "active")) | length'` equals the row count of `fleet.conf`.
4. A second `bin/registry-seed.sh` prints `changed=0` and the same version.
5. `diff <(REGISTRY_SOURCE=db bin/fleet-conf.sh --projects) <(bin/fleet-conf.sh --projects)` prints nothing, and `state/registry/` holds `registry.json`, `fleet.conf` and `version`.
6. `bin/registry.sh show` prints `registry: version=<v> ...` and one line per box.
7. `REGISTRY_ADMIN_TOKEN=wrong bin/registry.sh drain-box <box>` exits 1 with `http=403`, and `show` prints the same version after it.
8. After `bin/registry.sh add-box <name> --ip <ip> --like <id>`, `REGISTRY_SOURCE=db bin/render-cron.sh <new-id>` renders the like box's lane lines with the names changed.
9. On a db box, `grep -c '^REGISTRY_SOURCE=db' /root/harness/env/global.env` prints 1, and `diff <(REGISTRY_SOURCE=db REGISTRY_CACHE_TTL_S=0 bin/fleet-conf.sh --projects) <(awk '!/^[[:space:]]*(#|$)/ {print $1}' /root/harness/fleet.conf)` prints nothing.
10. On the hub, `ls -l /root/harness/state/registry/export/latest/` lists `registry.json`, `import.json`, `fleet.conf` and `cost-accounts.json`.
11. With a seeded registry, `bin/registry-seed.sh` (no `--force`) exits 1 with `the registry is already seeded`.

**What usually lies:**
- A db-mode answer that came from the committed file because the API failed.
  Check `state/registry/outage` and the `[registry]` line in `logs/ALERTS.log`.
- A cache younger than `REGISTRY_CACHE_TTL_S` answers without a call, so a
  just-seeded change can take up to that long to show.
- The BH-4082 `projects` table (console Projects form) is a different table.
- The runtime `$H/fleet.conf` on a db box is the export, not the committed
  file and not a source. It can be up to one `registry-sync` tick behind D1.
  Read `state/registry/version` and compare it with the version that
  `bin/registry.sh show` prints.
- A hand edit to `$H/fleet.conf` on a db box is reverted on the next
  `registry-sync` tick. Change the registry with `bin/registry.sh`.
- A write answers for D1 at once, but another box reads it only after its
  cache TTL (reads) or its next `registry-sync` tick (crontab).
- `drain-box` refuses (409) while an active project names the box: move the
  projects first.

**Manual-only / not automatable:** setting the worker secret and the first
seed run against prod are operator steps. The restore drill
(docs/RESTORE.md §7) is a hand step.
