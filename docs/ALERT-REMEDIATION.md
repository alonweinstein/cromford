# Alert pre-emption: two tiers of remediation, and terminal states

**Why this exists.** On 2026-08-25 seven alert classes paged the operator in one round.
Four of them needed a query, not a human:

| # | What paged | What was actually true |
|---|---|---|
| 1 | a pool machine "hung or orphaned" for a day | Fly had **purged** the machine; a destroyed machine never earns a `reaped` line, so the ghost re-alerted every tick |
| 2 | project-2 migration-PR pings | the SQL was already applied to prod |
| 3 | an project-3 PR aging with no merge owner | the PR was closed and superseded — its work had landed as another PR |
| 4 | a project-1 build with "no board close-out" | its RESULT was `BUILD_DEFERRED`, a **terminal** state the close-out sweep has no handler for, so it pages forever |

Class 4 is the general shape worth naming: *some verdicts are END states*. An
alert lane that only knows "pending" and "done" will page on an end state until
someone silences it by hand. Remediation handlers can answer "this is over"
(`exit 10`) as well as "this is fixed" (`exit 0`).

## Where the hook lives

Every alert lane in the harness converges on `bin/beat.sh` with a `fleet_alert`
beat. That is the one choke point, so that is where the question gets asked —
**before** the alert is quarantined for the triage lane (or, with the quarantine
kill switch set, posted straight to the console).

```
lane → beat.sh ─┬─ TIER 1  bin/remediations/<namespace>.sh   (static, read-only)
                │            exit 0 / 10 ──────────────► suppressed, logged, no page
                │            anything else ─┐
                │                           │
                │   no handler ─────────────┤
                │                           ▼
                ├─ TIER 2  bin/remediate-agent.sh          (LLM, may try to FIX)
                │            opt-in: flags/remediation-agent-enabled
                │            REMEDIATED / TERMINAL **with EVIDENCE**
                │                          ──────────────► suppressed, logged, no page
                │            anything else ─┐
                │                           ▼
                └────────────► quarantine → alert-triage → the operator
                                  (alert line carries "[remediator tried: …]")
```

Tier 1 answers "is this already settled?" from a query. Tier 2 answers the same
question and, when the answer is no, may try to settle it — inside a written
authority contract. Both share one attempt per akey per 6h. Everything that is
not a proven, evidenced settlement pages exactly as it does today.

## Handler lookup

The `akey` is colon-separated (`health:hungmachine:2862174f059658`). beat.sh
tries the most specific file first:

1. `bin/remediations/<field1>-<field2>.sh`
2. `bin/remediations/<field1>.sh`

**No handler → tier 2, if the pilot flag is set on this box; otherwise current
behaviour, unchanged.** With tier 2 off, a namespace nobody has written a handler
for still costs no log line and no throttle budget — it must not consume the one
attempt the namespace next door might want.

A field that is not `[A-Za-z0-9_-]` can never name a file: field 2 is dropped
(so `migration:example-org/project-3#229` falls back to `migration.sh`), and a bad
field 1 aborts the hook entirely.

### Namespaces with a handler today

| akey namespace | handler | evidence it settles on |
|---|---|---|
| `health:hungmachine:<machine-id>` | `health-hungmachine.sh` | Fly reports the machine `destroyed`, `stopped`, or `purged` → **0** |
| `health:stalepr:<project>` | `health-stalepr.sh` | every PR the line names is `CLOSED` or `MERGED` on GitHub → **0** |
| `health:uncommented:<project>:<n>` | `health-uncommented.sh` | every uncommented result is a terminal end state → **10** |
| `hb-unreach:<box>:<hour>` | `hb-unreach.sh` | the box answers a second ssh probe 15s later → **0** |

### Aged-out families: `uncommented` and `emptyurl`

Two namespaces subtract before they page, because the page itself was the bug.
`bin/pipeline-health.sh` checks 4 and 5 counted every uncommented build RESULT
older than an hour as a debt, with no ceiling and no consult of the ledger, so a
July record was owed a close-out forever: 398 project-1 records with the oldest
at 652h, plus three EMPTY-URL dirs each paging under their own key every 6
hours. Both checks now drop a record when either is true:

* **terminal** — the PR merged, the merge sweep recorded it closed unmerged, or
  the build dir carries a `SUPERSEDED` marker. `bin/lib/closeout-terminal.sh`
  answers this through `bin/jobs-client.sh` (`job_ledger_get merge`, then
  `job_pr_facts`), and `bin/sweep-stale-builds.sh` calls the same function so
  the two lanes agree on what "over" means. An outage or a missing row is NOT
  terminal — fail-open here means keep alerting.
* **aged out** — the RESULT is older than `CLOSEOUT_AGE_OUT_H` (default 168h, a
  hub knob in `env/global.env`). A page nobody acted on in a week is not going
  to be acted on now.

**Age-out is a recorded decision, not silence.** Every aged-out dir is appended
once to `state/closeout-aged-out.tsv` — columns `project`, `build dir`, `RESULT`
first line, `reason` — and that file is the audit trail; it is a set keyed on the
build dir, so re-running adds nothing and nothing is ever pruned. Each project
also gets one summary line per run in `logs/pipeline-health.log`
(`<project> close-out: aged-out N, terminal N, still-open N` and
`<project> empty-url: aged-out N, still-open N`). The summary goes to that log
and nowhere else: a summary that paged would be the problem restated.

The alert still fires whenever still-open > 0, under the same
`uncommented:<project>:<n>` key, and its line now names what it ignored. The
`emptyurl` key moved from one-per-record to `emptyurl:<project>:<n>` — same
namespace, so the retraction epilogue resolves the old per-record keys on the
first run after deploy and then stays quiet.

`health-uncommented.sh` is unchanged and still fails open. It judges the same
dirs it always did, so it can only ever page where it paged before, never
suppress more.

Every other namespace (`caploss`, `lander`, `mq-*`, `provenance`, `tier3`,
`flystall`, `deployfail`, `hb-stale`, `pool-fail`, `migration`, …) has no static
handler. On a box with the tier-2 pilot flag they go to the LLM remediator;
everywhere else they page exactly as they did before this feature existed.

**The migration-PR gap, closed 2026-08-25.** Class 2 above used to emit
`kind:"migration_check"` and write `ALERTS.log` directly, so neither tier ever
saw the single most mechanically answerable alert class in the harness.
`bin/check-migration-prs.sh` now beats a `fleet_alert` under the `migration`
namespace, and its `ALERTS.log` line moved to `migrations.log`.

That second half matters as much as the first, and it generalises:
`bin/poll-commands.sh` tails `ALERTS.log` every minute and re-beats each new
line to the console as `kind:"alert"`. So **a direct `ALERTS.log` write is a
second, unhooked path to the same page** — a lane that writes one alongside its
beat still pages even when the hook settled the beat. Message text is unchanged
in both places; only the file and the beat kind moved.

Other lanes in `bin/` still write `ALERTS.log` directly. They are inventoried in
this feature's PR body; only the migration lane was converted here.

## The invocation contract

```
timeout 60 bin/remediations/<handler>.sh "<akey>" "<line>" "<payload-json>" </dev/null
```

Cwd-independent (handlers resolve `$HARNESS`, default `/root/harness`). Stdin is
closed. One line of stdout is the handler's summary of what it did.

| exit | meaning | effect |
|---|---|---|
| `0` | REMEDIATED — the condition is fixed or was never real | suppressed: not quarantined, not beat |
| `10` | TERMINAL — an expected end state, nothing is owed | suppressed, logged as terminal |
| anything else, timeout, crash, missing handler | FAIL OPEN | tier 2 if the pilot flag is set, otherwise the alert proceeds **exactly** as it does today |

### Fail-open is the load-bearing property

A handler must never be able to swallow an alert it did not prove settled. That
is worth more than every suppression this feature will ever make: a missed page
is an outage nobody hears about, a redundant page is a mild annoyance. So the
hook runs in a subshell, every internal failure path returns "fail open", and
`tests/remediation-hook-test.sh` spends most of its assertions on the failure
cases — crash, timeout, non-zero, missing handler, unreadable akey — proving the
alert still lands in the quarantine file.

Two beat shapes skip the hook entirely: `triaged:true` (a human-facing
escalation a triage lane already decided to send) and `resolved:true` (a
retraction — remediating it would suppress the very notice that it cleared).

## The 6h throttle

At most **one remediation attempt per akey per 6 hours**, SHARED by both
tiers — a static attempt and an agent attempt on the same key consume the same
window, because the throttle bounds remediation, not handlers. Recorded in
`state/remediation-attempts.tsv` under the same `flock` discipline the
quarantine file uses. A repeat inside the window skips straight to the normal
path — it is not suppressed, it is simply not re-probed.

The claim is written **before** the handler runs, so a handler that hangs or
dies cannot be re-run on every tick for the rest of the window. Entries older
than two windows are pruned on each claim.

This also bounds the wall clock a cron lane pays, and tier 2 moved that number:
a handler may take 60s and the agent wrapper up to 360s, so the worst case is
now **420s per akey per 6h** on a box where the pilot flag is set, against 60s
where it is not. That is a real cost of the pilot and the reason it is opt-in.

## Tier 2: the LLM remediator

Tier 1 covers four namespaces. Everything else — and everything a handler failed
open on — reached a human untried. Tier 2 (`bin/remediate-agent.sh`) gives every
one of those alerts ONE bounded attempt first, and unlike a handler it may try
to FIX rather than only verify.

It is deliberately shaped like a handler: same argv, one line of stdout, same
exit codes (`0` remediated / `10` terminal / anything else fail open). The hook
does not know which tier answered, which is why adding it changed `rem_try` and
nothing else in `beat.sh`.

```
timeout 360 bin/remediate-agent.sh "<akey>" "<line>" "<payload-json>" </dev/null
  └─ agent-call.sh remediate <project> <model> 300 <transcript> @<prompt-file>
```

- **Stage `remediate`**, so model routing (`RUNNER_REMEDIATE`), the failover
  ladder, the per-call dollar bound and the `cost.csv` row all work the way they
  do for every other lane. Its context budget is the `alert-remediator` row in
  `catalog/context-budgets.json`.
- **Two bounds, not one.** `agent-call.sh` bounds the model call at 300s; the
  hook bounds the whole wrapper at 360s. The outer one is what a cron lane
  calling `beat.sh` actually gets when the inner one is the thing that fails.
- **Working dir is a scratch dir** under `state/remediation-scratch/`, created
  per run and removed after. Never a repo checkout — an unattended session with
  a working tree as its cwd is how a build's worktree gets committed to.
- **Prompt** is `prompts/remediator.md` with `{{AKEY}}`, `{{LINE}}` and
  `{{PAYLOAD}}` substituted (in python, not sed — an alert line carries `&`, `/`
  and quotes, and every one of those is a sed bug waiting to rewrite the
  authority contract it is being pasted next to).

### The pilot flag

```
touch /root/harness/flags/remediation-agent-enabled     # hub only, by hand
```

Absent by default, and this repo creates it nowhere — a fresh box behaves
exactly as it did before tier 2 existed. To widen the pilot fleet-wide once the
hub run has produced a week of `logs/remediation.log` and `logs/remediator/`
transcripts worth reading:

1. Read the transcripts, not the summaries. The question is not "did it get the
   verdict right" but "what did it TRY" — an escalation reached by way of three
   forbidden commands is a failure even though it escalated.
2. Compare `logs/remediation.log` REMEDIATED lines against the alerts that
   re-fired within the next 24h. A suppression followed by the same akey
   re-alerting is a wrong suppression.
3. Check the cost: `grep ',remediate,' logs/cost.csv`. The daily cap bounds
   runs, not dollars.
4. Then add the `touch` above to `bin/bootstrap-machine.sh` so new boxes get it,
   and run it once on each existing box. There is no fleet-wide switch on
   purpose; turning this on is a per-box decision with a per-box blast radius.

### The evidence rule

A `REMEDIATED` or `TERMINAL` verdict is honoured **only** when the agent also
printed an `EVIDENCE:` line quoting the condition check it re-ran after its
work. Missing evidence is downgraded to `ESCALATE` and the alert pages.

This is the whole reason tier 2 can be trusted with more authority than tier 1.
An agent that can write text can claim anything; an agent that must quote a
check has to have run one. It applies to `TERMINAL` as well as `REMEDIATED`,
because `TERMINAL` suppresses the alert just as completely — an unevidenced
"nothing is owed here" is the same failure wearing a calmer word.

### Verdicts and what they do

| last lines the agent prints | effect |
|---|---|
| `EVIDENCE: …` + `VERDICT: REMEDIATED …` | suppressed (exit 0) |
| `EVIDENCE: …` + `VERDICT: TERMINAL …` | suppressed as a terminal end state (exit 10) |
| `VERDICT: REMEDIATED …` with no `EVIDENCE:` | **pages**, logged `FAILOPEN-noevidence` |
| `VERDICT: ESCALATE …` | **pages**, logged `FAILOPEN-escalate` |
| no `VERDICT:` line, or a word nobody defined | **pages**, logged `FAILOPEN-parse` |
| `agent-call` rc 124 / 137 | **pages**, logged `FAILOPEN-timeout` |
| `agent-call` any other non-zero | **pages**, logged `FAILOPEN-crash` |
| over the daily cap | **pages**, logged `FAILOPEN-cap`, no model call made |
| an identical payload already answered, or already failed 3 times, inside the dedup window | **pages**, logged `FAILOPEN-dedup`, no model call made |

A non-zero `agent-call` never suppresses even when the output file happens to
contain the word REMEDIATED — a lane that failed did not produce a verdict, it
produced debris.

### Enriched pages

When tier 2 fails open, its one-line diagnosis is appended to the alert line
before the alert is quarantined:

```
project-3: harness PR(s) #229 open >12h awaiting merge [remediator tried: #229 is open with a failing check on the head commit; needs a human rebase]
```

Written for the person reading it at 3am: what is actually wrong and what they
must do. Every step of the append is guarded and any failure leaves the payload
byte-identical — the alert was already going to page, and an enrichment bug must
never be the thing that costs one.

## The authority contract

Verbatim MUST rules in `prompts/remediator.md`. Summarised:

**ALLOWED** — idempotent and reversible, which is the test each one passes:
read anything under `/root/harness`; GitHub **reads** through `gh` with a
minimal `--json` field list; `ssh` re-probes of a box (reads only); re-running
an idempotent harness status/health script; removing a stale lock or flag
file **only** with quoted evidence its owner process is dead; filing or
annotating an alert, or posting a board comment, through the existing `bin/`
lanes.

**FORBIDDEN — page instead:** `gh pr merge` or any merge / close / edit of a PR;
any `git push`, to any branch (a PR branch that needs a rebase is an ESCALATE:
the rebase train pushes it through its hold check, BH-2741); any production database write, migrations included; any
Vercel action; destroying, stopping or starting a Fly machine or box; reading or
printing anything under `env/` or any secret; installing anything; editing any
file under `bin/` or `rules/`.

**When in doubt: ESCALATE.** A redundant page is a mild annoyance; a suppressed
real alert is an outage nobody hears about. The agent is never penalised for
escalating.

### What is enforced mechanically, and what is not

The deny list is authored once, in `bin/remediator-settings.json`, and handed to
`claude` twice from that one file: as `--settings` and as `--disallowedTools`
(via `AGENT_SETTINGS` / `AGENT_DISALLOWED_TOOLS`, two generic passthroughs added
to `agent-call.sh`). One file, so the two copies cannot drift; the test asserts
the list the runner receives has the same length as the file's.

Being honest about the gaps, because a deny list is easy to over-credit:

- `--disallowedTools` is the layer this lane relies on.
- The settings `permissions.deny` block is belt-and-braces and is **not
  verified** to bind under `--dangerously-skip-permissions`, which
  `agent-call.sh` passes on every claude call. Same posture as
  `--max-budget-usd`: wired, stated, unproven.
- **Every `git push` is denied by prefix** (`Bash(git push:*)`, BH-2741). The
  lane used to be allowed a lease push to a PR branch, which a prefix match
  cannot express; it now has no push at all, so the prefix is the whole rule.
  A push spelled another way (`git -C x push`, a wrapper) is still carried only
  by the MUST rules and the transcript.
- Nothing binds a runner other than `claude`. If `RUNNER_REMEDIATE` is ever
  pointed at codex or grok, the mechanical layer is gone entirely and only the
  prompt remains.

That residue is why the pilot is opt-in on one box, and why every run leaves a
transcript.

### Auditability

Every run's full output is written to
`logs/remediator/<utc>-<akey>-<pid>.txt` and that path is recorded in
`logs/remediation.log`. A lane that may act on production without a human
watching leaves a transcript or it does not run.

## The daily cap

The 6h throttle bounds one akey. Nothing in it bounds an alert **storm** across
hundreds of distinct akeys — which is exactly the shape that turns a helpful
lane into an unbounded bill.

At most `REMEDIATE_DAILY_CAP` agent runs per UTC day, default **20**, counted in
`state/remediation-agent-<YYYYMMDD>.count` and claimed under `flock` **before**
the run — a run that hangs or is killed has still spent its slot. Over cap = fail
open, page as today, `FAILOPEN-cap` in the log, and no model call is made.

Tier 1 has no daily cap and does not need one: a static handler costs a `gh`
query.

## The payload dedup

The daily cap bounds how many agent runs a day can hold. It says nothing about
paying twice for the SAME question, and the 6h akey throttle in `beat.sh` is the
caller's — this script is runnable by hand, and an akey whose alert line changed
is a different question anyway.

So before the cap is claimed, tier 2 fingerprints what the model is about to be
asked: `sha256(akey + line + key-sorted payload JSON)`, first 32 hex characters.
One row per fingerprint in `state/remediation-payload-dedup.tsv`, tab-separated:

```
last_ts   fingerprint   attempts   outcome   akey
```

`outcome` is one of `pending`, `ok`, `empty`, `failed`. The row is written as
`pending` under `flock` **immediately before** the call and settled immediately
after it — `failed` on a non-zero `agent-call` (124/137 included), `empty` on
rc 0 with no `VERDICT:` line, `ok` otherwise. A run killed between the two
leaves `pending`, which counts as a spent failed attempt.

Inside `REMEDIATE_DEDUP_WINDOW` seconds (default **86400**), measured from the
last attempt:

- `ok` or `empty` → no further call, ever. An empty answer was billed too, and
  the identical question buys the identical nothing.
- `failed` or `pending` → retried until `attempts` reaches
  `REMEDIATE_DEDUP_CAP` (default **3**), then no further call.
- Nothing on file, or a row older than the window → a new episode, `attempts`
  restarts at 1.

A hit fails open: `FAILOPEN-dedup` in the log, the reason on the page, exit 1.
A cached verdict is never replayed as a suppression — evidence expires, and the
evidence rule above exists precisely to forbid acting on a day-old check. A hit
found before the cap claim costs no cap slot, so a storm of one identical
payload cannot starve the real remediations behind it.

If the marker cannot be written at all (the ledger path unwritable, the lock not
taken within 5s), **no call is made**: an unrecorded spend is the one this guard
cannot bound. A failure to write the OUTCOME after a call that did happen logs
one `dedup-settle` line and leaves the row `pending`, which costs one retry and
never an alert. Rows older than twice the window are pruned on every write.

Knobs: `REMEDIATE_DEDUP_WINDOW`, `REMEDIATE_DEDUP_CAP`. A non-numeric or zero
value falls back to the default, never to "unlimited". The ledger stores a hash,
a count, an outcome and the sanitised akey — never the payload and never the
alert line.

## Rules for tier-1 handlers

These are the rules for the static handlers under `bin/remediations/`. Tier 2's
rules are the authority contract above — a wider set, because it may act.

Handlers are **read-only probes**. A handler may:

- query GitHub with `gh` (read commands, minimal `--json` field lists)
- query Fly with `flyctl` / the Machines API (read)
- `ssh` a box for a read
- read local harness state (`builds/`, `flags/`, `logs/`, `state/`)

A handler must **never** merge, push, write a production database, post to a
board, apply a migration, or destroy a machine. It runs unattended, on a box
that can merge and deploy, to decide that nobody needs to be told — that is the
worst possible place for a write. `tests/remediation-hook-test.sh` greps every
shipped handler for those verbs and fails the build on a hit.

**Suppress only on positive evidence.** "I could not reach Fly", "gh returned
nothing", "the build dir is missing" are all reasons to exit non-zero and let it
page. Silence is not evidence.

## Adding a handler

1. Name the file for the namespace: `bin/remediations/<field1>-<field2>.sh`, or
   `<field1>.sh` to cover a whole namespace.
2. `chmod 755` it — beat.sh only dispatches to an executable file, and `bin/*.sh`
   landing in git as 644 has broken the pool before (commit `70b1a78`).
3. Read `$1` (akey), `$2` (line), `$3` (payload json). Probe. Print one line.
4. Exit `0` (fixed / never real), `10` (terminal end state), or non-zero.
5. State `READ-ONLY` in the header comment and keep it true.
6. Add a row to the mapping table above and a fixture case to
   `tests/remediation-hook-test.sh` — including the case that must still page.

## Logging

One line per attempt, tab-separated, to `logs/remediation.log`:

```
2026-08-25 20:14:07Z    health:hungmachine:2862174f059658   health-hungmachine.sh   exit=0    REMEDIATED   2862174f059658 (project-3): Fly says state=purged — machine is gone, not hung
```

An agent attempt writes **two** lines, on purpose:

```
2026-08-25 21:02:44Z   migration:example-org/project-3#229   remediate-agent   exit=0   ESCALATE       the SQL is genuinely unapplied; a human must run it   transcript=/root/harness/logs/remediator/20260825T210244Z-migration_example-org_project-3_229-8812.txt
2026-08-25 21:02:44Z   migration:example-org/project-3#229   tier2-dispatch    exit=1   FAILOPEN-escalate   the SQL is genuinely unapplied; a human must run it
```

The wrapper's line carries the transcript path; `beat.sh`'s dispatch line is the
record that the attempt happened **at all**, and it is the only line that exists
when the wrapper is killed at the 360s bound.

Verdicts: `REMEDIATED`, `TERMINAL`, `FAILOPEN`, `FAILOPEN-timeout`, and from
tier 2 also `FAILOPEN-escalate`, `FAILOPEN-noevidence`, `FAILOPEN-parse`,
`FAILOPEN-crash`, `FAILOPEN-cap`, `FAILOPEN-dedup`. Every fail-open verdict shares the `FAILOPEN`
prefix, so `grep FAILOPEN` still means "this alert paged". Summaries are
truncated to one 300-character line. The payload is never logged, and neither
tier prints secrets.

## Kill switch

```
touch /root/harness/flags/remediation-disabled       # kills BOTH tiers
rm    /root/harness/flags/remediation-agent-enabled  # kills only tier 2
```

`remediation-disabled` bypasses the whole hook: no lookup, no handler, no agent,
no log line. Every alert takes the path it took before this feature shipped. It
is checked in `beat.sh` and again inside `remediate-agent.sh`, because a kill
switch that only holds on one call path is not a kill switch.

Removing `remediation-agent-enabled` leaves tier 1 running and drops tier 2 —
the right lever when the static handlers are fine and the agent is the thing
misbehaving.

(The older `flags/alert-quarantine-disabled` is separate — it controls the
quarantine step that comes *after* this one.)

### Runner-lane outages: `lanedown-*` heals itself

There is no tier-1 handler for `lanedown-<box>-<lane>` or
`lanedown-stale-<box>-<lane>`, and none is needed: `bin/lane-reprobe.sh`
(`docs/SCHEDULER.md` §6) re-probes a down lane on its own schedule, and the
first ok probe clears it and resolves both ids.

`lanedown-stale-<box>-<lane>` is the standing warn. It fires when a lane has
been down `LANE_DOWN_STANDING_S` (default 24h), once per outage and not once a
day: the lane stamps `standing_at` in the lane's record after `bin/lane-alert.sh`
returns 0, and a stamped record never sends it again. If the send fails,
`standing_at` stays empty and the next due probe tries again. A new outage
starts a new record, so it can warn again. The text names the box, the age, the
UTC start and the last vendor error, for example:

```
RUNNER LANE grok on hub down 2d 21h (since 2026-09-21 00:00:00Z). Last error: xAI: team credit limit reached. That fallback tier is unavailable there; re-probing every 21600s.
```

**Remedy:** fix what the last error names (vendor credits, a revoked or
missing key), then wait for the next re-probe, or run
`/root/harness/bin/lane-reprobe.sh` on the hub. A manual run only probes
records that are due, the same as a cron tick.

## Related

- `bin/alerts-groom.sh` — the after-the-fact half: resolves alerts already
  showing on the console when their subject is verifiably settled. This hook is
  the before-the-fact half; the two ask overlapping questions on purpose.
- `bin/alert-flush.sh` — force-escalates anything still quarantined after 45
  minutes, so a dead triage lane can never silence a real fire.
- `bin/fly-machine-state.sh` — the shared Fly machine-state probe, used by both
  `bin/pipeline-health.sh` and `health-hungmachine.sh` so the alert and its
  remediation ask the same question.
- `bin/alerts-medic.sh` — the console-side cousin: it works a whole pass of
  already-open alerts within its own allow-list. Tier 2 here works exactly one
  akey, before the alert is ever open. Overlapping questions, on purpose.
- `tests/remediation-hook-test.sh` — tier 1. `tests/remediator-agent-test.sh` —
  tier 2, with `agent-call.sh` stubbed; no test in either file makes an LLM call
  or touches the real `ALERTS.log`.
