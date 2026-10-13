# Hub alert lanes claim rows (triage, medic, groom)

**What it is:** the three hub lanes that spend money on alerts — `alert-triage`,
`alerts-medic`, `alerts-groom` — reading and writing the `alerts` table through
the BH-1068 contract wrappers, behind the box flag `flags/alerts-db`. The claim
is the persisted "has anyone already paid for this row?" check, and it is made
BEFORE any `agent-call.sh`, so two lanes (or two boxes) cannot buy two sessions
for one condition. It also gives the hub a route to an alert whose box has
dropped off the tailnet: the row is in the table, so it is claimed and triaged
from here rather than waiting for that box's own 45-minute dead-man.

**The flag is the whole switch.** With `flags/alerts-db` absent (the default, and
every box until an operator flips it), `alerts_db_on` returns 1, `ALERTS_DB` stays
`0`, and the three lanes behave byte-for-byte as they did before — zero requests
to the jobs worker. Every DB call also FAILS OPEN: any rc but 0 and the lane
falls back to today's ssh/file path for that tick, with one line in its own log.
The per-box ssh grab in `alert-triage` runs ONLY on that fallback, or with the
flag off (BH-2366): with the flag on and the claim at rc 0 the hub grabs just its
own local queue, and a box entry whose quarantine mark missed is re-marked by
that box's `alert-flush.sh`, or flushed raw by its 45m dead-man. A retraction
on a box queue is dropped by that dead-man instead of paging, while its claim works.

**Rollout ordering (BH-1327): boxes first, hub second.** The flag means two
different things on the two sides, and turning them on in the wrong order
starves the lanes rather than breaking them.

1. **Box writer side first.** `flags/alerts-db` on each BOX is what makes
   `bin/lib/alert-state.sh`'s `alert_state_note` (reached from `bin/beat.sh` and
   `bin/lane-alert.sh`) write the condition through `alert_note` (BH-1070). Until
   that is on for a box, nothing that box raises has a row.
2. **Hub flag second.** `flags/alerts-db` on the hub turns on the three claiming
   lanes above. They claim ROWS — so on a table the writers have not filled yet,
   they claim nothing.

Flip the hub first and nothing fails: a console candidate with no table row is
claimed by nobody, `alert_claim` answers rc 0 with an empty set (a real answer,
and it means "no session" — `bin/alerts-medic.sh:454-463`), the family still
takes its local 6 h stamp, and the medic does not look at it again until that
stamp lapses — and then claims nothing again — until `bin/alerts-supersede.py`'s
72 h TTL closes the console row. Nobody is paged, and nothing is triaged.

**What starved looks like** in `logs/medic.log`, every pass, for families the
console still shows open:

```
medic db: 0 unclaimed row(s) added from the alerts table
medic claim: family <fkey> 0 of <n> rows claimed — no session
medic skip: the table claimed none of this pass's candidates — no session
```

Recovery is the same flip in the right order: turn on the box flags, the next
producer beat writes the row, the next medic pass claims it. Nothing is lost in
between — the console queue and the boxes' own quarantines are untouched by any
of this.

**How an operator reaches it:**

| lane | where it runs | what it does with the table |
|---|---|---|
| `alert-triage` | `bin/alert-triage.sh` (hub cron `*/10`) | `alert_claim alert-triage quarantined 0 200` after the deferral spool and before the ssh grab; each row rendered back into the quarantine's own `source<TAB>epoch<TAB>payload` shape; the hub's own local grab still runs and skips entries already marked `"dbrow":true`; the per-box ssh loop is skipped when the claim answered rc 0 and runs as before on any other rc or with the flag off, one `triage collect:` lane-log line per tick naming the path (BH-2366); `alert_state_set <id> triaged alert-triage` after each family's session; `alert_state_set <id> parked alert-triage` for every CLAIMED row of a family parked after `TRIAGE_CLIFF_MAX_REFUSALS` cliff refusals (BH-1327 — without it the 900 s lease re-offers the row and the lane refuses and re-parks it forever) |
| `alerts-medic` | `bin/alerts-medic.sh` (hub cron `*/30`) | `alerts_list --state new --older-than 1200 --limit 200` adds unclaimed rows as candidates; `alert_families medic 21600` widens the 6h brake fleet-wide; `alert_claim medic new` before dispatch, and ONLY claimed rows buy a session; `alert_state_set <id> parked medic` for every id a park covers |
| `alerts-groom` | `bin/alerts-groom.sh` (hub cron every 2h, and inline at `bin/alerts-medic.sh:18`) | `alert_state_key "$LINE"` per settled row, then ONE `alert_resolve` after the console resolve POST |

The prompts the two sessions receive are unchanged — rows are rendered back into
today's line shapes before the prompt is built, so `catalog/context-budgets.json`
and the ceilings in it are untouched.

**How to drive it:**

| what | how |
|---|---|
| all of it — flag off, the claim, the filtered grab, claim-before-buy, the DB brake, the park write-through, the groom resolve, and every fail-open path | `HARNESS_TEST_SANDBOX=1 bash tests/alerts-claims.bh-1071-test.sh` |
| the cliff-park write-through, its ordering and scope, and the triaged miss lines | `HARNESS_TEST_SANDBOX=1 bash tests/alerts-claims.bh-1327-test.sh` |
| the ssh-grab skip on a working claim, the loop on rc 1/2/9 and flag off, and `alert-flush.sh`'s re-mark pass | `HARNESS_TEST_SANDBOX=1 bash tests/alert-triage-no-ssh.bh-2314-test.sh` |
| the wrappers these lanes call | `HARNESS_TEST_SANDBOX=1 bash tests/alerts-client.bh-1068-test.sh` |
| the lanes' existing behaviour is unchanged (flag off) | `HARNESS_TEST_SANDBOX=1 bash tests/triage-split-test.sh`, then the same for `medic-split-test.sh`, `alert-loop-test.sh`, `prompt-ceiling-test.sh` |

(`HARNESS_TEST_SANDBOX=1` is required when you run these as root on a box with a
live `/root/harness` — `tests/lib/scratch.sh` refuses otherwise, which is the
guard, not a failure.)

`tests/alerts-claims.bh-1071-test.sh` runs the three real scripts end to end in a
scratch `$HARNESS` with a fake `curl` (recording every request into `req.log` and
answering per host), a fake `ssh` that really drains a second "remote" tree, a
fake `gh`, and a stubbed `agent-call.sh` that records the prompt it was handed
and the request count at the moment it was called — that number is what proves
the `triaged` stamp follows the session instead of outrunning it.

**What it looks like on a live box, after a flag-on tick on the hub:**

- `logs/alert-triage.log` — `triage claim: N row(s) claimed from the alerts table`
  before the `triage pass:` line; on an outage
  `triage claim rc=1 — alerts table unreachable, ssh grab runs unfiltered this tick`.
  Then exactly one of `triage collect: table claim ok, per-box ssh grab skipped (…)`
  or `triage collect: per-box ssh grab ran (claim rc=N)` / `(flag off)`.
- `logs/medic.log` — `medic db: N unclaimed row(s) added from the alerts table`,
  `medic claim: K of N candidate row(s) claimed`, and
  `medic claim: family <fkey> 0 of <n> rows claimed — no session` when a sibling
  lane holds every row of a family.
- A state stamp that does not land says so where the lane is read, not nowhere.
  Both are best effort by design (the work is already done and the local files
  are already written), so one is survivable; the same id every tick is not.
  The wording names WHICH id it is talking about, because the triage lane stamps
  two different kinds (BH-1327):
  - `triaged stamp rc=<n> for <id> — the row is re-offered when its lease lapses`
    — a row this lane CLAIMED. True: the 900 s lease brings it back.
  - `triaged stamp: no table row for <id> (a beat alertid this lane never
    claimed) — nothing to stamp, nothing is re-offered` — a 404 for an `alertid`
    that came off a beat (`bin/lane-alert.sh`, `bin/claude-auth-check.sh`) from a
    box whose writer side is off. There is no row and no lease.
  - `triaged stamp rc=<n> for <id> (a beat alertid this lane never claimed) — no
    lease here to re-offer it` — the same kind of id, but an outage rather than a
    404. A row may exist on a writer-on box; this lane holds no lease on it.
  - `parked stamp rc=<n> for <id> — parked in …, not by this lane in the table;
    if the row is still quarantined the lease re-offers it` — the cliff park
    could not be mirrored. The local park file stands either way. (rc 9 means
    the medic parked it first, so it is out of the queue regardless.)
- `logs/alerts-groom.log` — `resolved rows=N` right after `pass done: resolved N`,
  or `resolved rows=0 (alerts table rc=…; console resolve already done)`.
- `logs/jobs-client.log` — nothing new on a healthy worker; a `[jobs-client]`
  line there is the outage the fail-open paths above are reacting to.
- The console Alerts screen is unchanged: same rows, nothing new to click.

**Known limits** (deliberate, acknowledged in the BH-1071 review, unchanged by
BH-1327):

- **A failed session that is not a refusal is still stamped `triaged`.** If
  `agent-call.sh` returns rc 1 — the runner ran and failed — the lane logs the
  session line and the write-through stamps the family's rows `triaged` anyway.
  That is parity with the file path, which consumes the family's 6 h stamp in
  exactly the same case; the refusal families (rc 79 cliff, rc 74 gate) are the
  ones that re-spool with their pre-tick stamp restored.
- **A failed `parked` PATCH is never retried.** Best effort: the park FILE is the
  primary record and it stands, the miss is logged with its rc, and the lease
  re-offers the row once more at :900 — where the lane refuses it again and
  appends its lines to the park file again. So a persistent PATCH failure does
  cost one extra park-file line per further refusal. Bounded by the outage, and
  visible in the lane log rather than silent.

**Where it does NOT apply:** the boxes' own `bin/alert-flush.sh` (BH-1070) and
the writer side in `bin/beat.sh` / `bin/lib/alert-state.sh` are separate slices;
this one only reads and claims. `bin/alerts-supersede.py` is untouched, and the
console's own `/api/alerts/open` and `/api/alerts/resolve` calls are unchanged in
count and order.
