# Mission Control SETTINGS (every automatic mechanism, its switch and its knobs)

**What it is:** the `/settings` screen in `console-ui` — phase B of #1132. One
page carrying every registered lane the harness runs on its own, on a hub tab
and one tab per project, with the switch that stops it, the knobs that bound it,
and what it has cost today and over seven days.

Why it exists (the operator, 2026-09-20): *"stop any automatic mechanisms on the harness
for now … a UI settings page with all those harness components on a hub level
and on a project level so we can control each and see their stats."* Before it,
267 cron lines ran fleet-wide behind ~40 `flags/*` files with inconsistent
semantics, and nothing let an operator see every mechanism in one place or stop
one without ssh. The day the ticket was filed, alert-triage burned USD 793 in
12 hours (#1039) and the only way to stop it was a shell on the hub.

The screen is the READ and the WRITE surface; nothing here decides anything. It
renders phase A's registry and status, and its writes go through endpoints that
already existed.

**Two payloads, and which one is authoritative for what:**

- `GET /api/lanes/registry` — `catalog/lanes.json` as the worker baked it. The
  DECLARATION: which lanes exist, what each switch is called, and each knob's
  `type` / `min` / `max` / `unit` / `zero_means`. It is the source of the lane
  LIST and of every bound the page enforces.
- `GET /api/lanes/status[?project=]` — the LIVE half: which switches are thrown,
  what each knob currently reads and where that value came from, the last tick
  and its outcome, runs today, and the priced cost rows. It is the source of
  every VALUE, and of the project list behind the tabs (never a constant in the
  console — same lesson as `tests/fleet-projects-not-hardcoded-test.sh`).

Where the two disagree about which lanes exist, BOTH are shown and the row says
which side is missing (`NO STATUS` / `NOT IN REGISTRY`). A lane that quietly
vanishes from this page is the exact failure the page exists to prevent, so
"unknown" is rendered as unknown and never as `0`.

**Writes — three, all through endpoints that already existed:**

- A lane on/off is `PUT /api/flags` with
  `{name: "lane-off-<id>[-<project>]", active: 1|0, actor: "console", reason}`.
  A box lane on ONE box (BH-2327) is the same write with
  `name: "lane-off-<id>.box.<box>"`, from the BOXES table on `/settings/<id>`.
- A knob is `PUT /api/settings` with
  `{key: "lane.<id>[.<project>].<env>", value, actor: "console", note}`.
- The master switch is `POST /api/lanes/all-off` / `all-on` with
  `{actor, reason}`.

**The setting key is LOWERCASE, and that is load-bearing.**
`worker/jobs/src/routes/settings.js` validates every key against
`SETTING_KEY_RE = /^[a-z0-9_.-]{1,64}$/` on `PUT /api/settings`. A key carrying
the ENV name verbatim (`lane.merge-conductor.MC_MAX_PRS`, which is how #1132 §3
writes it in prose) is a `400` on **every** write. `settingKey()` in
`console-ui/src/lib/settings.js` lowercases the env name once, and
`tests/settings.test.js` pins both the produced key and the worker's own regex.
Any reader of these rows has to lowercase to match.

**Every write asks first, in the app.** `useConfirm()` from `src/ui/Modal.js` is
the one confirm surface — no `window.confirm`, `alert` or `prompt` anywhere:
native dialogs are off-brand, inaccessible, and they freeze browser automation
until a human dismisses them. An out-of-range knob is refused CLIENT-side and
never even opens the modal, because asking someone to confirm a value the worker
will reject is the wrong order to find out in.

**Behaviours a reviewer should be able to point at:**

- **An unreachable API keeps the last state on screen behind a banner**, never
  an empty table. An empty control panel and a control panel that cannot reach
  its API look identical and mean opposite things.
- **One busy latch for the page**, so a double click cannot double-write a flag.
- **No dead rows.** Every lane name links to `/settings/<lane>[?project=]`,
  which carries the lane's script, switch file, knob bounds and its recent
  priced cost rows as their own sortable table.
- **Sortable everywhere.** Both tables are the shared `SortableTable`, so every
  header sorts with `aria-sort` and the sort applies to the whole row array.
- **Mobile.** The table scrolls inside `.tablewrap` (`overflow-x:auto`,
  `max-width:100%`), never the page body; tabs wrap; knob inputs are 44px tap
  targets and the detail field list collapses to one column under 768px.

**How an operator reaches it:** Mission Control → **SETTINGS** (last tab, top
bar and bottom nav), or `/settings` directly. A project's lanes are
`/settings?project=<project>`.

**Primary lanes / files:**
- `console-ui/src/screens/Settings.js` — `SettingsScreen` (fetch + state),
  `SettingsView` (render), `LaneDetailScreen` / `LaneDetailView`.
- `console-ui/src/lib/settings.js` — `tabsFrom`, `laneRows`, `flagName`,
  `settingKey`, `validateKnob`, `zeroLabel`, `flagBody`, `settingBody`,
  `makeLaneActions`. Every name the page writes and every bound it enforces.
- `console-ui/src/api.js` — `lanesRegistry`, `lanesStatus`, `lanesAll`,
  `setCoordSetting` (and the pre-existing `setCoordFlag`).
- `console-ui/functions/api/coord/[[path]].js` — the Pages proxy allowlist. It
  now passes `PUT /settings` and `POST /lanes/all-off|all-on` alongside the
  `PUT /flags` it already passed. Without that one line the screen renders
  perfectly and every operator click answers `405`.
- `console-ui/src/app.js` — the `/settings` and `/settings/:lane` routes and the
  nav entry.

**Knobs:** none of its own. The page's whole job is the OTHER lanes' knobs, and
its bounds come from the registry rather than from anything in the console.

**How to drive it:**
- `cd console-ui && npm test` — the repo's console suite (`node --test`), of
  which three files are this feature:
  - `tests/settings.test.js` — tabs from the payload (and the hub-only
    fallback), row merging in both directions, the lowercase setting key against
    the worker's own regex, `zero_means` labels, knob validation (out of range,
    non-numeric, a float in an int knob, no declared bounds), the exact flag and
    settings bodies, and the action bundle: confirm-then-write, cancel writes
    nothing, a failed write never reads as success, an invalid knob never
    reaches the API, and both master switches.
  - `tests/settings-render.test.js` — renders the REAL components and reads the
    HTML back: hub and project tabs, eight sortable headers with `aria-sort`,
    `.tablewrap`, the knob inputs carrying the registry's `min`/`max`,
    `0 = unlimited` on screen, `aria-pressed` on both toggle states, the detail
    links, ALL OFF / ALL ON, the modal slot, and the banner case that keeps the
    last rows rendered.
  - `tests/settings-api.test.js` — the URLs and bodies `src/api.js` puts on the
    wire, plus the Pages proxy: the lane reads forward as GETs, `PUT /settings`
    and `POST /lanes/all-*` are allowed through with the bearer attached in the
    Pages runtime, and the allowlist stays narrow (no DELETE, no POST to
    anything else).
- `cd console-ui && npm run build` — the CI job "Mission Control SPA — unit
  tests + build" runs both.
- On a live console: open `/settings`, switch a lane off, and watch that lane's
  next tick record `paused` rather than running.

## QA screens (a browser pass)

1. **`/settings`** (hub tab) — the primary flow: the table renders every hub
   lane; click a column header and the sort flips with its arrow; toggle a lane
   off and the modal names the flag file; confirm and the row flips and the
   status refetches.
2. **`/settings?project=<project>`** — only project-scoped lanes, and each
   row's detail link carries `?project=`. Switch tabs back and forth and the
   tab strip never collapses mid-fetch.
2b. **`/settings`, BOX LANES** (hub tab only, BH-2327) — under HUB LANES, all
   23 `scope: "box"` lanes, each linked to `/settings/<id>`. The STATE toggle is
   the lane's fleet-wide `lane-off-<id>`; BOXES OFF (sortable) reads `<off>/<boxes>`,
   `—` when the status reported no per-box state. A box lane is drawn here and
   NOT again as a `NOT IN REGISTRY` row in HUB LANES. Project tabs are unchanged.
2c. **`/settings/<box-lane>`** (e.g. `/settings/disk-clean`) — a BOXES section:
   one row per box (BOX, STATE `button.toggle` with `aria-pressed` and an
   `aria-label` "<lane> on <box> is on|off", SWITCH `flags/lane-off-<id>.box.<box>`,
   LAST TICK, PAUSED BY), sorted by box. Toggle one box: the in-app modal names
   the switch and says every other box keeps running. Empty state: "No box has
   ticked this lane or been switched yet". An older worker with no `boxes` key
   renders NO PER-BOX STATE; a capped read adds "a box may be missing".
3. **`/settings/<lane>`** and **`/settings/<lane>?project=<project>`** — the
   lane detail: script, switch file, knob bounds, and the recent cost rows, with
   a ticket that names a build opening `/builds/<build_dir>`.
4. **Knob validation, on `/settings`** — type a value above a knob's `max` and
   press Enter: refused inline with the bound named, nothing written. A knob
   whose key would exceed 64 characters renders disabled with the reason.
5. **ALL OFF**, from the header — the danger-toned modal, then the `ALL OFF`
   tag on the page header.
6. **Any of the above at 375px** — the table scrolls inside its own container,
   the page body never scrolls sideways, tabs wrap, and knob inputs are 44px
   tap targets.

**The payload shapes this screen reads** are written down in
[lanes-status-contract.md](lanes-status-contract.md) — the status and registry
responses field by field, how the console degrades on each missing one, and the
two key rules (lowercase, 64 characters) that phase A's reader has to match.

**Not yet exercised against a live worker.** Phase A's `/api/lanes/*` routes are
a separate PR; until they are deployed this screen renders its banner and its
last state, which is the honest answer to "the API is not there yet" and is what
`tests/settings-render.test.js` pins. Nothing on the page has been driven
against a real registry, a real status payload or a real box, and the first
toggle from a browser is the step that proves the write path end to end.
