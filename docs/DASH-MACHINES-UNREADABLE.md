# `/api/dash/machines` — unreadable Fly, and where orphans come from (2026-09-17)

BH-667. On 2026-09-17 the console reported `cromford` as **0 machines and 6
orphan jobs** while six pool machines were running, heartbeating and spending
money. Nothing was wrong with the lane: the Worker had no
`FLY_API_TOKEN_CROMFORD`, so it could not ask Fly — and published the gap
as a measurement. the operator nearly un-flipped a working lane over it.

The UI half ships in this repo (see below). The Worker half does not live here.
This file is what the console repo has to implement.

## 1. Where that route actually lives

The ticket asked for this to be established first, so: **not in this repo.**

- `grep -rn "dash/machines" .` finds only consumers — `console-ui/src/api.js:54`,
  `console-ui/src/screens/World.js:10`, `console-ui/tests/drive/fixtures.mjs:76`,
  `console-ui/tests/drive/world-drive.mjs:112`. No producer.
- `console-ui/functions/api/[[path]].js:8` proxies `/api/*` to
  `https://harness-console.operator.workers.dev`. That is the console Worker.
- Its source is the private repo `example-org/cromford-console`
  (`docs/CHANGELOG-NOTES.md:34`, `fleet.conf:54`). From a fleet box,
  `gh api repos/example-org/cromford-console` answers **404** with the box
  PAT, and `gh repo list example-org` shows only `cromford`,
  `project-6-runtime` and `forestry-belkirk-jekyll-demo`. `mcp/lib/tools.mjs`
  is in that repo too; it does not exist here.

So "the deployed Worker appears to be ahead of this repo" has a duller
explanation: the route was never in this repo. Whether the deployed Worker is
also ahead of `cromford-console`'s own main cannot be checked from a box.
Same split as `docs/DASH-COSTS-24H.md` and `docs/watchdog-spec.md`: the spec is
written here, the Worker change is made from the operator's local checkout.

## 2. Block shape when a project cannot be enumerated

Today, with the token unset, the Worker sends this — and it is the bug:

```json
"cromford": { "machine_count": 0, "machines": [], "orphan_jobs": [ 6 rows ] },
"fly_errors": [ { "project": "cromford", "error": "…token unset…" } ]
```

What it must send instead:

```json
"cromford": {
  "unreadable": true,
  "unreadable_reason": "FLY_API_TOKEN_CROMFORD unset",
  "machine_count": null
}
```

- `unreadable: true` whenever the Fly read failed for any reason — token
  missing, 401, 5xx, timeout. The reason string is the one that already goes
  into `fly_errors`.
- `machine_count: null`, or the key dropped. Never `0`. Absent is not zero.
- **`machines` and `orphan_jobs` are OMITTED**, not emptied. An empty array
  reads as "we looked and there was nothing".
- The `fly_errors[]` entry stays exactly as it is today, for older readers and
  for the FLY NOT ENUMERATED section, which already words a missing token as a
  normal state rather than a fault.
- A project whose read SUCCEEDS keeps today's shape, zero machines included:
  `machine_count: 0` with `machines: []` is a real measurement and must keep
  rendering as "no machines up".

## 3. Where orphan status comes from

An orphan is "the beat saw this job building, and Fly no longer has its
machine". Deriving that from the queue table alone cannot work: a
`build_queue` row stays `status='claimed'` for the **whole life of a build** and
only flips at reap, so "claimed 45 min, machine gone" and "claimed 45 min,
machine chewing through execute" are the same row.

Join to the jobs ledger instead. `GET /api/jobs` rows carry the truth —
`decorateJob` in `worker/jobs/src/lib/core.js` decorates every row with
`last_beat_at`, `beat_age_s`, `heartbeating` and `activity_age_s`.

Rules, in order:

1. **Block unreadable → do not compute orphans at all.** There is no machine
   list to compare against, so the answer is unknown, and unknown renders as no
   claim. Omit `orphan_jobs`.
2. A claimed row whose job is beating **recently** — `heartbeating` true AND
   `beat_age_s < orphan_beat_max_s` — is **never** an orphan, whatever the
   machine count says. The ticket's 2-minute case.
3. A claimed row with no beat at all (`beat_age_s === null`), or
   `beat_age_s >= orphan_beat_max_s`, **and** no live machine for that job in
   the (readable) machine list, **is** an orphan. The ticket's 30-minutes case.
   The fix must not suppress orphan detection — a real orphan is how a build
   that vanished mid-flight gets noticed at all.

**Careful with `heartbeating`.** In `decorateJob` it is `last_beat_at !== null`
— "has ever beaten", not "is beating now". A row that beat once an hour ago and
died has `heartbeating: true` forever. So rule 2 needs the beat AGE as well; the
ticket's shorthand ("a claimed row whose job is heartbeating is NOT an orphan")
is only safe read together with its own acceptance tests, which are about beat
age. Implementing the shorthand literally would make every once-beaten dead job
permanently non-orphan.

## 4. `orphan_beat_max_s` is a setting, not a constant

The 30-minute line is a business parameter, so it is a knob in the operator
settings store (`GET /api/coord/settings`, documented in
`docs/verification-map/settings-knobs.md`), editable without a deploy.
**1800 seconds is the documented fallback** used only when the setting is
absent — not a bare constant in the Worker.

## 5. MCP `machines` tool

`mcp/lib/tools.mjs:395-401` (console repo) maps the same payload for agents and
has the same failure mode: an agent asking "how many machines are up" gets a
confident `0`. Pass `unreadable` and `unreadable_reason` through, report
`machine_count` as `null`, and print "cannot read — <reason>" in the text
rendering rather than a number. An agent acting on a fabricated zero is worse
than a human doing it: it will not stop to check `flyctl`.

## 6. Worker-side acceptance tests (the ticket's, verbatim)

To be written in the console repo, the unreadable one red first:

1. A project with a readable token, 3 machines and 3 claimed heartbeating jobs
   → `machine_count: 3`, `orphan_jobs: 0`.
2. A project with **no token**, 6 claimed heartbeating jobs → block marked
   unreadable, `machine_count` null/absent, and `orphan_jobs` **not** 6. This is
   the exact 2026-09-17 cromford case.
3. A claimed row whose job last beat 30+ minutes ago with no live machine →
   counted as an orphan.
4. A claimed row with a heartbeat 2 minutes old → never an orphan.

## 7. Deploy order: UI first, Worker whenever

The UI half ships in the same PR as this file, and it handles **both** shapes:
`console-ui/src/lib/fly.js` marks a block unreadable on any of three signals —
the new `unreadable` flag, an absent `machine_count` (null, or the key dropped
with no machine list), or an entry for that project in the existing
`fly_errors`. The third is what the deployed Worker sends today, so the console
stops claiming "0 machines, 6 orphan jobs" as soon as this PR is deployed,
without waiting for the Worker. When the Worker starts sending `unreadable`,
the same code path lights up from the flag instead.

Readers, for the record: `FlyTile` (`console-ui/src/screens/Fleet.js`) renders
"cannot read" in place of "N/M up" plus a warn line with the reason, and keeps
its job rows because those come from the jobs ledger, not from Fly. `FlyProject`
(`console-ui/src/screens/Machines.js`) renders a "cannot read this project's Fly
machines" empty state with the reason, no machine table and no orphan banner.
Tests: `console-ui/tests/fly.test.js`, `console-ui/tests/fly-render.test.js`.

## Operator step, separate from all of the above

Set the Worker secrets `FLY_API_TOKEN_CROMFORD` and (later)
`FLY_API_TOKEN_HARNESS_CONSOLE`. BH-667 deliberately does not do this: the
readout has to be honest with the token absent regardless.
