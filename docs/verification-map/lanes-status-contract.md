# `GET /api/lanes/status` — the payload contract

**Why this file exists.** Phase B of #1132 (the Mission Control SETTINGS
screen) was built against phase A's routes before they existed, so the shape it
assumes lived only in its own test fixtures. A contract that exists only in a
fixture is a contract one side can change without the other noticing, and the
symptom would be a control panel that renders and controls nothing. This is the
shape the console actually reads, written down once.

Phase A owns the implementation; this file is what phase B was built to consume.
Where they differ, the console is the side that has to change — but the
difference has to be found here rather than by an operator clicking a switch
that does nothing.

## The routes

```
GET  /api/lanes/registry            the baked catalog/lanes.json
GET  /api/lanes/status[?project=]   the live half
POST /api/lanes/all-off             {actor, reason}
POST /api/lanes/all-on              {actor, reason}
```

Reached from the browser through the Pages proxy as `/api/coord/lanes/*`
(`console-ui/functions/api/coord/[[path]].js` strips `coord` and attaches the
bearer). Knob and switch WRITES do not get their own routes — they go through
the endpoints that already existed, `PUT /api/flags` and `PUT /api/settings`.

## `GET /api/lanes/status?project=<project>`

```jsonc
{
  "as_of": "2026-09-20T11:04:00Z",   // ISO 8601; rendered as "as of HH:MM"
  "projects": ["project-4", "project-3"], // drives the tab strip — see note below
  "all_off": false,                   // the fleet-wide master switch (a pause_flags ROW)
  "all_off_flag_boxes": [],           // BH-1165: boxes holding a hand-touched flags/all-off
                                      //   FILE — every lane there is gated and ALL ON
                                      //   cannot clear it
  "lanes": [
    {
      "id": "merge-conductor",          // stable; the flag and key are built from it
      "name": "Merge conductor",        // falls back to `id` when absent
      "scope": "hub",                   // "hub" | "project"
      "project": null,                  // the project on a project-scoped row
      "cadence": "*/5",                 // free text; the registry's value is the fallback
      "script": "bin/merge-conductor.sh",
      "off": false,                     // the switch as it is RIGHT NOW
      "off_source": null,               // "flag" | "all-off" | "db" — why it is off
      "held_by": [],                    // every switch NAME holding it (rows and sightings)
      "flag_boxes": [],                 // BH-1165: boxes holding a flags/ FILE no row drove
      "modifiers": [],                  // active `partial` aliases: they change, never stop
      "enables": [],                    // `absent` aliases: what ARMS the lane
      "paused_since": null,             // ISO 8601; rendered as "paused HH:MM"
      "last_tick_at": "2026-09-20T11:00:00Z",   // BH-1165: this LANE's own row in lane_ticks
      "last_outcome": "ran",            // "ran" | "paused" from the gate; "ok" from the legacy lanes row
      "runs_today": 41,                 // integer
      "cost_today": 12.5,               // USD, number
      "cost_7d": 88.25,                 // USD, number
      "cost_attribution": "lane",       // "lane" | "shared" | "none"
      "knobs": {
        "MC_MAX_PRS": {
          "value": 8,
          "source": "settings",         // "settings" | "env" | "default"
          "min": 1, "max": 50,          // optional here; the REGISTRY is authoritative
          "type": "int",                // "int" | "number" | "string"
          "zero_means": null            // "unlimited" | "off" | null
        }
      },
      "cost_rows": [                    // the lane DETAIL view only
        { "at": "2026-09-20T10:30:00Z", "stage": "merge", "ticket": "BH-1039",
          "usd": 41.2, "build_dir": "bh-1039-abc" }
      ],
      "mode": null,                     // BH-1201: merge-conductor ONLY
      "held_pages": null,               // BH-1201: merge-conductor ONLY
      "boxes": [                        // BH-2327: scope "box" lanes ONLY
        { "box": "orgo-2", "switch_name": "lane-off-disk-clean.box.orgo-2",
          "off": true, "off_source": "db",   // "db" | "flag" | null
          "paused_since": "2026-09-25T10:00:00Z", "paused_by": "console",
          "paused_reason": "turned off on orgo-2 from Mission Control",
          "last_tick_at": "2026-09-25T11:00:00Z", "last_outcome": "paused" }
      ],
      "boxes_off": 1,                   // BH-2327: how many of `boxes` are off
      "boxes_complete": true            // BH-2327: false when lane_ticks hit its 2000-row cap
    }
  ]
}
```

`mode` and `held_pages` are present on the `merge-conductor` lane object and on
no other — every other lane's object carries neither key. They are the two
settings rows the conductor publishes for itself, `merge-conductor.mode`
(`merge`/`actions`/`observe`/`kill-switch`) and `merge-conductor.held_pages`
(the conductor's own summary string, e.g. `"3 STUCK=2 BUDGET=1"` or `"0"`),
handed back verbatim. **`null` means no row**, which is not the same answer as a
conductor holding nothing — the console must not render it as `0`.

`boxes`, `boxes_off` and `boxes_complete` (BH-2327) are present on a
`scope: "box"` lane and on no other: a hub or project lane carries none of the
three keys, because absent means "not switched per box", which is not the same
answer as an empty fleet. `boxes` is every box that ticked the lane, every box
with a `lane-off-<id>.box.<box>` row (active or not, so a box switched off and
then decommissioned can still be cleared) and every box reporting a file of
that name, sorted by box. `off_source: "db"` is an active row; `"flag"` is a
file on that box that no row drove. A per-box file is reported here and only
here: it never makes the lane-level `off` true and never appears in
`held_by`/`flag_boxes`, since it stops one box, not the fleet.
`boxes_complete: false` means the `lane_ticks` read filled its 2000-row LIMIT,
so a box may be missing from the list.

## What the console does with each field, and how it degrades

Every field is optional in practice: the screen renders from whatever arrives
and never throws on a missing key. What it will NOT do is invent a value.

- **`projects`** is the tab strip, and the console holds the last non-empty list
  across a fetch. An empty or absent list does not collapse the strip to HUB, so
  a project whose status 404s keeps its tab and the operator keeps a way back.
- **`lanes[]`** is merged with the registry in both directions. A lane the
  registry declares and the status never mentions renders with a `NO STATUS` tag
  and **null** counts, not zeros — "unknown" and "did nothing" are different
  answers. A lane the status carries and this bundle's registry does not renders
  with `NOT IN REGISTRY` and no knob inputs, because there are no declared
  bounds to enforce against.
- **`off: null` or absent** disables the toggle and renders "unknown" rather
  than defaulting to on. A switch that shows a state it did not read is worse
  than one that admits it does not know.
- **`knobs{}`** supplies VALUES; the registry supplies BOUNDS. A knob absent
  from this map falls back to the registry default and is labelled `default`.
- **`runs_today`/`cost_today`/`cost_7d` are `null` and `cost_rows` is `[]`**
  when `cost_attribution` is `"shared"` (the lane's stage signature is shared
  with another lane) and when it is `"none"` (no `cost_stage` and no
  `cost_project_filter`, BH-3557). The screen renders `—` with "no model cost of
  its own" for `"none"`; the fleet's spend is on /costs SPEND BREAKDOWN.
- **`cost_rows`** only has to be present on the lane the detail view is showing.
  A row carrying `build_dir` links to `/builds/<build_dir>`; one without still
  renders its ticket. An empty array renders "NO COST ROWS" with the note that a
  lane spending money with no attributed rows is itself a finding.

## The settings key is lowercase, and bounded at 64 characters

`PUT /api/settings` validates every key against
`SETTING_KEY_RE = /^[a-z0-9_.-]{1,64}$/` (`worker/jobs/src/index.js`). So:

```
lane.<id>.<env>              hub-scoped
lane.<id>.<project>.<env>    project-scoped
```

with the **whole key** lowercased, not only the env segment — a lane id or
project slug carrying an uppercase character builds a key the worker refuses.
**Phase A's reader has to lowercase too**, or it will never find a row the
console wrote and will silently fall back to env or the registry default with no
error anywhere.

The 64-character bound is not theoretical:
`lane.review-autopilot.project-8.autopilot_daily_cap_usd` is 65
characters. The console checks the whole key before the write, disables that
knob's input and says why, rather than letting the click buy a 400. If phase A
wants those knobs settable, the id or the env name has to get shorter — a
constraint worth knowing while the catalog is still being written.

## The flag name

```
lane-off-<id>              hub-scoped
lane-off-<id>-<project>    project-scoped
```

`PUT /api/flags` takes `{name, active: 1|0, actor, reason}` and the name becomes
a file under `flags/` on every box, so it lives in the character set that cannot
escape that directory.

## How to drive it

The console half is pinned by `console-ui/tests/settings.test.js`,
`settings-render.test.js` and `settings-api.test.js` — see
[mission-control-settings.md](mission-control-settings.md), which also carries
the QA screen list for a browser pass. Those fixtures are this document in
executable form; a change here that is not made there is a change the tests will
not catch.

## BH-1165 — what phase C added to this payload

- **`off_source: "flag"` is now reachable, and only with a row behind it.**
  Through phase A a file under `flags/` that no `pause_flags` row drove was
  box-local and invisible here, so the page reported such a lane as ON — a hand
  `touch` or a cost autohalt looked like nothing at all. `bin/lib/lane-gate.sh`
  now REPORTS what it found (`POST /api/lanes/flag-seen`) into
  `lane_flag_sightings`, and the status route joins it. It is still never
  guessed: no sighting, no `"flag"`.
- **On a sighting, `paused_by` is the BOX and `paused_reason` says the row does
  not exist.** There is no actor to name: nobody wrote a row, so the honest
  answer to "who stopped this" is "a file on that box". A sighting also goes
  stale the way any last-seen row does — it is cleared by the next tick of that
  lane on that box, so a decommissioned box can leave one standing; `seen_at`
  (rendered as `paused_since`) is what says how old the observation is.
- **A sighting named `all-off` holds every lane on that box.** The gate's
  sighting marker is keyed on the flag NAME, so on a box where somebody touched
  `flags/all-off` the first lane to reach its hourly refresh posts the row with
  its own id and the other 77 are throttled — matching a sighting only by lane
  id reported 1 lane of 79 as off while the box was fully stopped. The master
  sighting is lifted out and applied to every lane, and reported once more at the
  top level as `all_off_flag_boxes`. That is deliberately NOT `all_off`:
  `all_off` is the `pause_flags` row ALL ON clears from this page, and a file on
  a box only an ssh can remove.
- **The sighting is not a decision.** Nothing gates on that table. Writing the
  file back into `pause_flags` would turn one box's hand touch into a
  fleet-wide stop the next time every other box reconciled — a reporting
  mechanism changing what it reports. A `pause_flags` row therefore still
  outranks a sighting in `off_source` (`"db"`), because the row is the one an
  operator can clear from this page; `flag_boxes` says where the file is, so the
  operator knows a toggle here will not move it.
- **`last_tick_at` / `last_outcome` are per LANE.** `lane_ticks` is keyed
  `(lane, project, box)` and every gated or ungated tick writes one
  (`POST /api/lanes/liveness`, outcome `ran` or `paused`). The `lanes` table
  stays the FALLBACK for the lane the registry marks `stats.lanes_row`, so the
  triage staleness pager keeps reading exactly what it read before. A lane
  nothing has ticked still reports `null` — unknown is not zero.
- **A knob may be a `string`.** 217 knobs joined the registry when every lane
  was wired, and about eighty of them are a model slug, a list of boxes or a
  regex. The console renders a text input for those and validates them against
  the worker's own rule (non-empty, trimmed, ≤256 characters, no line break)
  instead of refusing them as "must be a decimal number".
- **A knob may also be `settable: false`, and then it is not on this page at
  all.** 85 of those 217 are the command a lane runs, the host it sends
  `Bearer $HARNESS_SECRET` to, the path it deletes under, the identity it claims
  or a test seam. They stay in the registry (so `tests/lanes-registry-test.sh`
  section 7 keeps announcing a new one, and `harness-ctl show` keeps printing
  them) and out of `laneRows`; `validateKnob` refuses one and so does
  `PUT /api/settings`, which returns 400 `… is not settable from the control
  plane`. `bin/lib/lane-gate.sh` ignores a row for one even if it exists.
- **`unlimited` is a row, not a magic zero.**
  `lane.<id>[.<project>].<env lowercased>.unlimited` says it in words. It is
  honoured only where the registry says `zero_means: "unlimited"`, and refused
  with a log line where `0` means *off* — there, "unlimited" would be the exact
  opposite of what was asked.
