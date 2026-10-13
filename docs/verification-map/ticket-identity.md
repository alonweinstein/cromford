# One identity per ticket (the launch-path identity guard)

**What it is:** a board ticket id may have ONE build identity. Every other
dedupe in this fleet keys on the build KEY — `job_open "$PROJECT" "$KEY" build`
and the worker's double-build guard both match on `(project, ticket_id=KEY,
kind)`, and the board ticket id rides only in the row's `meta` — so a decomposed
child launched under its `<PARENT>.<n>` TITLE LABEL while the board's own key
for the same ticket is something else is invisible to all of them. `TK-1766.5`
and `TK-1789` were one board ticket, two claims, two plans, two PRs.

`bin/lib/ticket-identity.sh` answers the question. `ticket_identity_conflict
<harness> <project> <ticket-id> <key>` prints `<other-key>\t<source>\t<state>`
and returns 0 on a conflict, 1 when nothing conflicts, 2 when a source could not
be consulted and nothing positive was found. Sources, cheapest first, first hit
wins:

| source | what it reads | state it reports |
|---|---|---|
| `keymap` | `state/<project>.keymap.json` (rebuilt every tick by `bin/triage-gate.sh`) | `board-key` |
| `issues-key` | `bin/fleet-conf.sh <project> board_prefix` = `-` (the GitHub-Issues lane) + `preplan_key_prefix` (`bin/lib/preplan-lib.sh`, which reads the rendered launch line in `prompts/<project>.md`) — the board's key for issue N is `<PREFIX>-N` by construction, so it needs no keymap and no round trip | `board-key` |
| `build-record` | `builds/<project>-*/job.json` + the dir's `RESULT` — and on a Fly-routed project the stub's `QUEUED_FLY` hands off to its pool TWIN, `builds/pool-<project>-<KEY>-*/RESULT`, which is where the PR line actually lands (`bin/fly-pool.sh:751`) | `pr_created`, `merged` |
| `ledger` | `job_builds_running <project>` (running `build` rows, board id from `meta`) | `running` |
| `queue` | `queue_list <project> claimed` then `queue_list <project> queued` — the rows `queue_put "$PROJECT" "$KEY" "$TICKET"` wrote, whether a box has taken one yet or not. The `status` column is re-checked in the reader, so a worker that ignored the filter widens the list instead of answering wrong; a row whose `meta` parses to a non-`build` `kind` is skipped, because `build_queue` also carries the merge conductor's pool REBASE rows; and a row refuses only a launch that is BEHIND it (below) | `claimed`, `queued` |

**A GitHub-Issues board has no keymap, ever (BH-1139).** The `keymap` source is
written by `bin/triage-gate.sh` from a BOARD API, and an issues project has
none — so on that lane source (a) is permanently empty, and `build-record`,
`ledger` and `queue` can only see a duplicate once a second build already
exists. The FIRST launch under a decomposed child's dotted TITLE LABEL therefore
had nothing to refuse it: `bin/run-decompose.sh`'s issues lane titles the child
`TK-2411.2: <slice>` while filing it as issue `#2487`, so `TK-2411.2` and
`TK-2487` are one issue with two identities, `job_open` and the worker's
double-build guard each see only one of them, and every child of every split
could be planned, executed and PR'd twice.

That board's key is DERIVABLE, which is the whole fix: its key for issue N is
`<PREFIX>-N` by construction — `run-decompose` writes `children.txt` that way,
and `bin/orphan-reconcile.sh`, `bin/preplan-candidates.sh`, `bin/hotfix-seen.sh`
and `bin/dep-verify.sh` all derive it the same way through `preplan_key_prefix`,
which reads the rendered launch line in `prompts/<project>.md` (the one place
that prefix is written down — `fleet.conf` has no column for it). So the
`issues-key` source asks that same function rather than growing a second answer
that could disagree with the line triage actually runs, and it is asked SECOND,
straight after the keymap: a registry read and a prompt grep, before the
build-tree scan and before either round trip.

**Every leg of it fails OPEN and SILENT — never rc 2.** No `bin/fleet-conf.sh`
on the box, no row for the project in the registry, an in-app board, a
non-numeric ticket id, no `bin/lib/preplan-lib.sh`, no launch line in the
prompt: the source says nothing and the other four decide. `unknown` is for a
source that could not be CONSULTED; these are a derivation that is not
available, and turning them into rc 2 would print `could not consult the ledger`
on every board-project launch on the fleet. The board-lane gate is the load-
bearing one: an IN-APP board's key for ticket 4711 is whatever the board
assigned (`AB-12`), so deriving `AB-4711` there would refuse a launch naming a
key that exists nowhere — the one failure this lane promises never to produce.

**The queued window, and why it needed a fourth source (BH-1140).** On a
Fly-routed project — most of the fleet — `bin/run-build.sh` enqueues at the
`QUEUED_FLY` path and `job_open`, the running row the `ledger` source reads, only
happens on the pool machine much later. In that window the first three sources
all legitimately answer nothing: no running row, no pool twin (so `build-record`
returns rc 1 for a stub without one, which it must keep doing), and on project-4 no
keymap either (below). A project-4 split filed as `TK-1784` could therefore be
enqueued and then built a second time under a title label before a pool machine
claimed the row — the exact duplicate this guard exists to refuse. The `queue`
source closes it: the board id is already on the queue row, so it is one more
question, not a redesign.

**The window runs to `job_open`, not to the claim.** `queue_claim` runs on the
HUB the moment `bin/fly-pool.sh` spawns or reuses a machine; `job_open` — the
running row the `ledger` source reads — runs on the MACHINE, after boot, clone
and the context gate. Between those two the row reads `claimed`, there is still
no running row, still no twin and still no keymap, and a machine that dies after
the claim holds it there until `bin/jobs-watchdog.sh`'s stale sweep releases the
row. So the `queue` source asks for `claimed` as well as `queued`, claimed
first: a claim is the later, stronger fact, the same ordering rule that puts
`running` ahead of the whole source. `done` and `failed` are finished attempts
and are never asked for at all.

**A row refuses only a launch that is BEHIND it.** This is the one source read
from BOTH ends of a duplicate. The `# >>> ticket identity guard` block runs
twice per build: once on the hub before the Fly enqueue, and again on the pool
MACHINE (`fly/builder-runner.sh` -> `bin/run-build.sh`), where it sits above
`job_open` and above the machine's own `queue_claim` while the HUB already
claimed the row when it spawned that machine (`bin/fly-pool.sh`). So on the
machine this launch's OWN row reads `claimed`. A reader that refused on any
sibling row would refuse the launch that is holding the claim — and a
machine-side `BUILD_DEFERRED` is REQUEUED by the reap, not closed ("a deferral
is REQUEUED, not closed", `bin/fly-pool.sh`), so a ticket that ever holds two
rows would never build at all: claim one, defer on the other, requeue, claim the
other, defer, until `bin/jobs-watchdog.sh`'s `QDEFER_MAX` parks both `failed`
and `bin/blocked-resolver.sh` abandons both — about eighteen machines, zero
builds, two abandoned records, for a ticket with ONE legitimate build in it.
That is worse than the duplicate this guard exists to catch, and two rows for
one ticket is not hypothetical: it is the project-4 `TK-1784` / `TK-1766.0` pair, and
a death-requeue beside a deferral-parked duplicate, `jobs-watchdog`'s deferral
requeue and `blocked-resolver`'s fresh enqueue each produce it.

So the rows are ranked — `claimed` 2, `queued` 1, **no row of our own** 0 — and:

- a sibling FURTHER ALONG refuses (we are queued, a box already has that one);
- a sibling BEHIND us does not (we hold the claim; its own launch will meet our
  `running` row at the `ledger` source when its turn comes);
- a pair in the SAME state is settled by `_ti_older`: older `enqueued_at` wins,
  and an equal or absent timestamp falls through to the normalized key. Both
  sides compute that order identically, so exactly one of the two stands down
  and the other builds — never neither, which was the livelock, and never both,
  which would be the duplicate;
- a launch with NO row of its own — the hand launch or label launch in the blind
  window, the case this source was written for — is behind every row and is
  still refused by all of them.

**...and a page it could not read may be holding our own row.** The two statuses
are two round trips, so a PARTIAL outage is a real shape: `claimed` fails while
`queued` answers. On the pool machine our own row is the CLAIMED one, so our
rank would read 0 — "no row of our own", the rank every sibling is ahead of —
and a merely queued sibling would refuse the launch that is holding the claim:
the livelock above, reopened one transient error at a time. So the highest rank
that went UNREAD is remembered, and while no row of our own was read, a
candidate no further along than that rank does not refuse; the launch falls to
rc 2 and proceeds, saying so. The refusal survives wherever the unread page
cannot change the answer — a CLAIMED sibling on a healthy page is ahead of us
whatever an unread `queued` page holds, and a row of our own that WAS read ranks
us for the tie-break exactly as before.

**`build_queue` is shared, so the rows are scoped to builds.** The merge
conductor enqueues pool REBASE rows on the same table
(`mc_pool_rebase_enqueue`, `bin/lib/mc/rebase.sh`): `ticket_id` is the PR
NUMBER, the key is `RB-<num>-<head8>`, and the meta says `{"kind":"rebase",…}`.
Board ticket ids are integer strings (`bin/triage-gate.sh` builds the keymap
from `.id | tostring`) in the same range as PR numbers, so an unscoped reader
refuses board ticket 1592 the moment PR #1592 has a rebase queued — a build
refused IN ERROR, every tick, naming a key no operator can launch. The `ledger`
source has always been scoped this way (`job_builds_running` selects `kind ==
"build"`); the `queue` source is scoped the same way. A build row carries NO
`kind` at all (`bin/run-build.sh`'s QMETA is `stack_base`/`hotfix`,
`bin/blocked-resolver.sh`'s is `deferrals` plus a note), so the test is "no
kind, or kind `build`" — never "no meta".

**Where the sources still do NOT reach (BH-866 / BH-1140, known and filed).**
Two gaps left, each narrowing the guard rather than making it wrong, and each
failing OPEN — each failing case is the duplicate this guard was built to catch,
never a refused-in-error build. (The one shape that could produce a
refused-in-error build is a pair of rows refusing each other; the ranking and
`_ti_older` above exist to prevent exactly that, so a tie always leaves one of
the two building.)

The third gap is CLOSED. A board whose list endpoint omits `key` had an EMPTY
keymap until BH-1169: `bin/triage-gate.sh` now derives
`<board.keyPrefix>-<ticket.number>` for rows whose listing omits `key`, so the
project-4 `keymap` source answers the same ids the `# >>> board child keys` block
in `bin/run-decompose.sh` already derived. A board with no `keyPrefix` still
derives nothing — a keymap entry may only ever name the BOARD's key for an id.

- **A row this guard cannot page to.** `queue_list` takes the worker's default
  page — 200 rows, oldest first — so a project holding more than 200 rows in ONE
  state would hide the newest of them. It is asked per status for that reason
  (an unfiltered ask would page through the project's whole history), and the
  states it asks for are the transient ones. If a project ever parks 200+
  `queued`/`claimed` rows at once, this source degrades to the coverage it had
  before BH-1140; it never answers wrong.
- **The row that stands down is deferred, not cancelled.** The tie-break decides
  which of two rows for one ticket builds; it does not remove the other. The
  loser keeps cycling claim -> defer -> requeue against the winner until
  `bin/jobs-watchdog.sh`'s `QDEFER_MAX` parks it and `bin/blocked-resolver.sh`
  takes its fresh rounds — and once the winner has FINISHED, nothing the loser
  can ask on a pool machine still says so: the ledger row is closed, the queue
  row is gone, and `build-record` reads this box's `builds/` tree, which on a
  pool machine is not the hub's. So the loser eventually builds the duplicate
  the guard refused earlier, one full build later instead of concurrently.
  Pre-existing — the pair of rows is written by `bin/fly-pool.sh`'s
  death-requeue, `jobs-watchdog`'s deferral requeue and `blocked-resolver`'s
  fresh enqueue, none of which this lane owns — and it fails open toward that
  duplicate, never toward a refused-in-error build. Closing it means the loser's
  row being CLOSED rather than re-offered, which belongs to whichever of those
  three wrote it.

**How an operator reaches it:**

- `bin/run-build.sh`, the `# >>> ticket identity guard` block — every launch
  route enters this script, and the block sits ABOVE `# >>> hotfix detect`, so it
  precedes the Fly enqueue, the wip gate, the slot flock and the queue claim. A
  refused duplicate takes no lock, holds no slot, writes no queue row and spends
  no model tokens. Refusal is `BUILD_DEFERRED duplicate identity: …` + exit 3,
  which `_job_finish` parks and the triage tick re-offers.
- `bin/free-slots.sh <project> <ticket-id> <KEY>` — the same refusal as an
  answer a triage prompt can ask BEFORE it launches. First token `0`,
  parenthetical opens `identity:`. The two ticket args are optional; with none,
  the output is byte-for-byte what it has always been.
- The in-app prompts (`prompts/project-4.md`, `project-1.md`, `project-3.md`,
  `project-2.md`, `project-8.md`, `project-9.md`, `TEMPLATE.md`)
  name that command in their duplicate-work bullet.
- `bin/run-decompose.sh`, the `# >>> board child keys` block — the other end of
  the same problem: a `<KEY>.<n>` label never reaches `children.txt`, so a label
  cannot become a launch key in the first place. The re-map reads the key the
  board sends, or derives it from the parent's prefix plus the board `number`
  for boards (project-4) whose list endpoint omits `key`. A re-map that FAILS still
  parks the parent `in_progress`: the children are already filed by then, so a
  claimable parent would have the next tick file a second set.

**How to drive it:**

| what | how |
|---|---|
| the lib, all five sources, the two-rows-one-ticket tie-break and every negative | `HARNESS_TEST_SANDBOX=1 bash tests/ticket-identity-guard-test.sh` (§1a-e) |
| the run-build block, extracted verbatim by its markers | the same suite, §2 |
| `bin/free-slots.sh` with and without the ticket args | the same suite, §3, plus `tests/free-slots-test.sh` unchanged |
| the decompose re-map | `HARNESS_TEST_SANDBOX=1 bash tests/run-decompose-board-keys-test.sh` |
| the re-map's failure park, on a non-default board prefix | `HARNESS_TEST_SANDBOX=1 bash tests/run-decompose.bh-1340-test.sh` |

**Files it owns on a live box:**

- `builds/<dir>/pipeline.log` — `identity guard REFUSED: …`, `identity guard:
  off (TICKET_IDENTITY_GUARD=0)`, or `identity guard could not consult the
  ledger — proceeding on local evidence only`.
- `builds/<dir>/RESULT` — `BUILD_DEFERRED duplicate identity: …`.
- `logs/<project>.log` — one line per refusal.
- `logs/ALERTS.log` + `flags/alerted-identity-<project>-<tid>-<other>-<YYYYMMDD>`
  — one alert per (project, ticket, other key, day). The ticket is re-offered
  every tick; an alert per tick is a pager that gets muted.

**Knob:** `TICKET_IDENTITY_GUARD` in `env/global.env`, default 1. `0` logs one
line and never refuses. The block reads that file directly — `run-build.sh`
does not source `env/global.env` until ~300 lines further down, so a knob read
from the environment alone would be a switch that does nothing where it is
documented to be set. An exported variable still wins over the file.

**What must never regress:** a GitHub-Issues child launched under its dotted
title label is refused and the refusal NAMES the issue's own key (`TK-2487`), so
the operator's next command is the right one — while a launch under that key
itself, in any case, is never refused, and an in-app board never has a key
derived for it at all; an issues-lane launch (`866` + `BH-866`) skips the
guard entirely — the two strings differ, so only the `-<id>` suffix check stops
it paying a build-tree scan and a ledger round trip for a question with one
identity in it; the Fly hop — most of the fleet is pool-routed, and a
stub whose twin is never read makes `pr_created`/`merged` dead code on exactly
the boards this ticket came from; a sibling the merge sweep already merged is
reported `merged`, never "an open PR" (the sweep writes the ledger row and
leaves the build's `RESULT` saying `PR_CREATED`); a queued sibling is reported `queued` and never as a
build that exists (nothing is building yet in that window), while a ticket that
is both queued and running is reported `running` — the stronger, later fact; a
queue row a pool machine has CLAIMED is a build in flight and is reported
`claimed`, because `queue_claim` runs on the hub and `job_open` runs on the
machine long after — while a `done` or `failed` row is a finished attempt and
holds nothing; a launch that HOLDS the claim is never refused by a merely queued
sibling, and two rows in the same state never refuse each other (exactly one of
the pair stands down) — the same block runs on the machine the hub already
claimed for, and a requeued deferral would otherwise livelock the ticket until
both rows were abandoned; a launch whose own row sat on a page the worker could
not serve is not refused by a sibling at or below that page's rank either — a
partial outage must not put that livelock back one transient error at a time; a queue row the merge conductor wrote for a pool REBASE
(`kind=rebase`, `ticket_id` = the PR number, key `RB-<num>-<head8>`) is NOT a
board ticket and must never refuse the board ticket whose id happens to equal
that PR number; a launch under the ticket's OWN key is never
refused; a `-r2` rebuild or a `RESUME_BUILD` re-enters the same key and is never
a conflict; keys compare case-insensitively; a sibling whose PR is ledgered
`closed`/`abandoned` or marked `SUPERSEDED` is over and does NOT hold the ticket
(that is [pr-reconcile-terminal.md](pr-reconcile-terminal.md) working); and an
unreachable jobs worker with no local evidence PROCEEDS — refusal needs evidence,
because a D1 outage that refused every launch would stop the fleet.
