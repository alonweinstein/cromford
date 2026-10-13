# Paid unchanged — what a triage tick still paid for (BH-3926, BH-3921.3)

The triage-state pre-check (`bin/lib/triage-state.sh`, see
[../TRIAGE-STATE.md](../TRIAGE-STATE.md)) decides which tickets go to the model.
This is the account of what that cost: how many of the tickets a tick paid the
model to read had inputs that had not moved since their last verdict. The
account is `bin/lib/triage-state-waste.sh`.

## The count

`ts_waste_account <path>` runs once before each tick line. It reads this tick's
`state/triage-state/<p>/decisions.tsv` and `rows.json` and counts, over the
keys in this tick's scope (column 7) that are not work keys (column 9: a queue
line or a finished build is worked whatever its triage state):

| path | when | counted |
|---|---|---|
| `restricted` | enforce, a session runs with the do-not-touch directive | `llm` keys, not `recheck-due`, whose input hash (column 5) equals the stored `verdict_hash` |
| `unrestricted` | shadow, and enforce observe-only (`forced`, gate errors) | the restricted count, plus `skip unchanged:*`, `skip buildable-*` and `enqueue`: the whole session runs and re-reads them |
| `zero` | enforce, nothing to send (`rc=skip … no model call`) | 0 |
| `unreadable` | the rows could not be read (`TS_ROWS_OK != 1`, on any path) | nothing: the count is `?`, never 0 |

Every tick line then ends its last bracket with ` paid_unchanged=N`
(`ts_waste_bracket`), e.g.

    triage-state enforce: 41 open, 1 to the model: TK-201, 40 unchanged [reads=0 deferred=0 paid_unchanged=0]
    triage-state shadow: … — shadow: the tick runs as before [gate=board-changed reads=0 deferred=0 paid_unchanged=40]
    rc=skip :: triage-state: 0 changed — …; no model call [gate=board-changed paid_unchanged=0]

An enforce tick whose rows are unreadable never reaches an account (it returns
before the enforce line, as it always has), so it logs no token.

## The cost-row notes

The single session's cost row (`bin/lib/rt/launch.sh`, `AGENT_CALL_ROW_NOTE`)
carries

    ts:new=N:chg=N:due=N:cap=N:unr=N:pu=N

over every in-scope key, work keys included (only `pu` leaves them out): `new` = `llm new`, `chg` = `llm changed` (a
settled reason ref and a handed-off key whose hash moved included), `due` =
`llm recheck-due`, `cap` = `skip deferred:*` (0 until the read-rule slice
emits it), `unr` = `llm unhashable` + `llm rows-unreadable`, and `pu` the
count. `pu=` is always LAST. With the rows unreadable it reads `pu=na`.

Each shard's row carries `ts=<class>` for its one key: `bin/triage-shard.sh`
runs `ts_row_note_of` over the snapshot the dispatcher took for that key
(`TSH_TS_HASH`; `bin/lib/rt/shards.sh` itself is untouched, BH-3418),
first match wins: `work`, `unchanged`, `new`, `changed`, `due`, `cap`,
`unreadable`. A key with no decisions line gets no note.

`bin/agent-call.sh` cuts the note to `[a-z0-9=:._-]` and 64 characters and
appends its own tokens after it with `;` (`cache_ttl=…`, `context-kill:…`).

## The read

`GET /api/metrics/triage-paid-unchanged?days=N` (`worker/jobs/src/routes/triage-waste.js`,
bearer required) sums, per UTC day and project, over `cost_rows` with
`stage='triage' AND rc=0`:

- the number after `:pu=` on a note holding `ts:new=` (SQLite's numeric-prefix
  CAST stops at the `;` agent-call appends; `pu=na` reads 0);
- 1 for a note whose whole `;`-token is `ts=unchanged`.

`days` defaults to 14, is clamped to 1..60 and echoed; it never reaches the
SQL (the window start is bound as `?1`). The answer is
`{days, from, rows: [{day, project, paid_unchanged, waste_calls, triage_calls, usd}], truncated, as_of}`,
capped at 1000 rows (`truncated: true` past it). `usd` is the day's whole
triage spend for that project; null when nothing was priced.

Mission Control: Nav COSTS → `/costs` → TRIAGE PAID UNCHANGED, under SPEND
BREAKDOWN (`console-ui/src/screens/TriageWaste.js`). Each PAID UNCHANGED number
opens that day's triage cost rows for the project.

## The streak and its alert

Only under `TS_MODE=enforce` (observe-only ticks included), and never on an
unreadable count: `state/triage-state/<p>/paid-unchanged.streak` holds one
integer, written tmp+mv. A count > 0 adds 1, a count of 0 resets it to 0. A
missing, corrupt or non-integer file reads as 0; a failed write moves nothing.

When the streak becomes exactly 3, one alert:

    bin/lane-alert.sh --id triage-paid-unchanged:<p> --severity warn triage \
      "<p>: 3 triage ticks in a row paid the model for tickets whose inputs had not changed (last: N: <labels>). Read logs/<p>.log and state/triage-state/<p>/decisions.tsv."

4, 5 and on stay silent until a 0 tick resets the streak. The 3 is a fixed
rule, not a knob. Shadow counts and logs, and never reads or writes the
streak.

Tests: `tests/triage-state-paid-unchanged.bh-3926-test.sh`,
`worker/jobs/test/triage-waste.bh-3926.test.js`,
`console-ui/tests/triage-waste.bh-3926.test.js`.
