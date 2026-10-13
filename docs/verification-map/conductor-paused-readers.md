# The alert readers stand still while the merge conductor is paused

**What it is:** the two hub lanes that turn alert lines into model sessions —
`bin/alert-triage.sh` and `bin/alerts-medic.sh` — hold the alerts the merge
conductor raised about its OWN pull requests for as long as the conductor is not
running its own merges. A held line is re-offered, never dropped. Alongside it
`GET /api/lanes/status` publishes what the conductor said about itself, so an
operator can see the pause and the size of it from the Mission Control settings
screen rather than by reading two lane logs on the hub.

**Why:** a lane paying for a Fable investigation of `example-org/x#11 STUCK — 95m
in WAIT_CI` while the conductor that raised it is in `kill-switch` is buying a
diagnosis of a wait somebody has already stopped, and two lanes acting on one
pull request is the incident the conductor exists to prevent. Holding costs a
tick; not holding costs a session and a second writer.

**The source of truth is the D1 settings row `merge-conductor.mode`, and nothing
else.** No flag file, no box-local state, no log. Both lanes read it through
`bin/lib/conductor-mode.sh` (`conductor_hold_active <lane-id> <KNOB_ENV>`), which
holds on `kill-switch`, `observe` and `unknown`. **`unknown` HOLDS** — an
unreachable worker, or the cold-start state before the conductor child publishes
anything, fails closed on SPEND.

## The two hold blocks

| Lane | Marker | Where | What a held line does |
|---|---|---|---|
| `bin/alert-triage.sh` | `# >>> conductor hold (BH-1201)` | after STEP 0's retirement, before the family split | goes back to `state/alert-triage-deferred.tsv` under its `.lock` flock; not counted, not stamped in `state/alert-families.json`, no `agent-call.sh` |
| `bin/alerts-medic.sh` | `# >>> conductor hold (BH-1201)` | after the unseen filter, before `CANDIDATES` is written | dropped from this pass's candidates; never claimed (`alert_claim`), never parked, never stamped, never written to `state/medic-seen.txt`, so the console and the alerts table re-offer it next pass |

The match is `\[(?:orchestrator/)?merge-conductor\]` — the same regex
`bin/triage-spool-retire.sh` uses — against the beat's `.line` in triage and
against the row's line (everything after the first tab) in the medic. Nothing
else matches: `[merge-conductor-x]`, `[orchestrator/merge-sweep]`,
`[blocked-resolver]`, a `[pipeline-health]` line that merely names the conductor,
a beat with an empty or missing `line` and an unparseable payload are all kept.

**Held is not dropped.** The triage spool is drained first on the next tick, and
a line that outlives its ceiling retires on STEP 0's audited path into
`state/alert-triage-expired-<date>.tsv` with a reason column
(`EXPIRED-CONDSTATE` at `TRIAGE_CONDSTATE_MAX_AGE_H` for a per-PR budget note,
`EXPIRED-AGE` at `TRIAGE_SPOOL_MAX_AGE_H` for everything else). The medic's rows
stay `new` with their 900 s lease untouched.

## Knobs

- `lane.alert-triage.triage_conductor_hold` (`TRIAGE_CONDUCTOR_HOLD`) — int,
  default 1, 0..1, `zero_means: off`.
- `lane.alerts-medic.medic_conductor_hold` (`MEDIC_CONDUCTOR_HOLD`) — same shape.

An explicit `0` (a settings row, or the env var as the documented fallback) opts
that lane out and wins even under `kill-switch`. Anything else — empty, unset —
reads as on, because a knob nobody wrote must not silently disable a hold.

**Key routes/screens:**
- `GET /api/lanes/status` (bearer) — the `merge-conductor` lane object carries
  `mode` and `held_pages`, read from the settings rows `merge-conductor.mode`
  and `merge-conductor.held_pages`. Both are `null` when no row exists, which is
  NOT the same answer as zero. No other lane object has either key. The payload
  shape is in [lanes-status-contract.md](lanes-status-contract.md).
- Mission Control SETTINGS (`console-ui/src/screens/Settings.js`) — the two
  knobs render with bounds 0..1 and source `default` until somebody writes a row.

**Preconditions:** `bin/lib/conductor-mode.sh` present on the box (a box whose
sync has not landed it behaves exactly as it did before — no function, no hold).
The `merge-conductor.mode` row is written by the conductor child; until it
exists, the mode is `unknown` and both lanes hold every conductor line. Both
lanes are OFF on the hub (`flags/lane-off-alert-triage`,
`flags/lane-off-alerts-medic`), so this is observed only once one is turned on.

**Verify it works:**
- `logs/alert-triage.log` carries
  `triage pass: held N conductor line(s): conductor paused (mode=kill-switch) — not consumed, not stamped, no session`
  and the line is in `state/alert-triage-deferred.tsv`.
- `logs/medic.log` carries
  `medic pass: held N conductor alert(s): conductor paused (mode=kill-switch) — left unclaimed and unstamped`
  and the row is still `new` on the console.
- Neither line appears on the go path (`mode=merge`): that tick is byte-identical
  to today's.

**Driven by:** `HARNESS_TEST_SANDBOX=1 bash tests/conductor-readers.bh-1201-test.sh`
(the real lanes end to end against a fake worker) and
`cd worker/jobs && node --test test/lanes-status-conductor.bh-1201.test.js`
(the real `GET /api/lanes/status` handler over a node:sqlite D1).

**Manual-only / not automatable:** turning either lane on. Nothing in this
feature does it, and nothing in its suites does either.
