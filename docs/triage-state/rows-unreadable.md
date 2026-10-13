# Triage state: rows unreadable (BH-3925, BH-3921.2)

Code: `ts_rows_unreadable_tick` in `bin/lib/triage-state-unreadable.sh`, called
once per tick by `ts_tick` (`bin/lib/triage-state.sh`). Tests:
`tests/triage-state-unreadable.bh-3925-test.sh`.

## The rule

The pre-check reads every `triage_state` row in one call before it decides
anything. When that read fails (the jobs worker is unreachable, or answers
something that is not a JSON array), `ts_precheck` sets `TS_ROWS_OK=0` and every
open ticket is decided `llm rows-unreadable`.

Under `TRIAGE_STATE_MODE=enforce` that used to buy a full-board model session on
exactly the tick we know least about. Now the hook does this:

| situation | what the tick does |
|---|---|
| rows readable | removes the streak file; the tick runs as before |
| mode `shadow` or `off` | runs as before; the shadow line still says `(rows unreadable: every ticket to the model)` |
| no `decisions.tsv` this tick | runs as before. The pre-check never got as far as the rows read (no board fingerprint, no jq/python3, a failed decision pass), so `TS_ROWS_OK=0` is only its default |
| a `forced` / `forced-env` tick | runs as before (`ts_tick` never calls the hook) |
| `gate-error` or an unknown reason | runs as before |
| work in scope: a queue line, a queue dir, a finished build, a `remote-results-pending` tick, or an `UNBLOCKED` / `STACKABLE` / `board prs:` scope line | runs **restricted**: `TS_ENFORCING=1`, `TS_SKIPSET` is every `decisions.tsv` key with no work (column 9 not `1`) that no `UNBLOCKED` / `STACKABLE` line names (`revdep_keys`, bin/lib/revdep-lib.sh), and the prompt gets `TRIAGE STATE UNREADABLE: do NOT re-triage any ticket this tick; work only the queue lines, finished-build close-outs, UNBLOCKED/STACKABLE launches and PR lines in scope.` The streak is not changed |
| no work in scope | **skipped**: `rc=skip :: triage-state: rows unreadable — tick skipped, no model call (streak N)`, `LANE_TICK skip`, the job row closed with `meta=triage-state: rows unreadable`, then `exit 0` |

The reasons acted on are the ones `_ts_enforce_reason` accepts, plus
`no-gate-state` and `gate-fetch-failed`. Those two stay observe-only for a tick
whose rows ARE readable.

A skip never calls `rt_gate_consume`. `state/<p>.gate.pending` survives, so
the next tick offers the same change again. A daily sweep that is skipped does
not stamp the full-sweep clock.

## The streak and the alert

`state/triage-state/<p>/rows-unreadable.streak`: line 1 is the count of skipped
ticks in a row, and an optional line 2 reads `alerted`. It is written through a
temp file and `mv -f`. A count that does not parse reads as 0. Only a skip bumps
it, and only a readable tick removes it.

When the count reaches `TRIAGE_STATE_UNREADABLE_ALERT_AFTER` and the file is not
yet `alerted`, one alert goes out:

    bin/lane-alert.sh --id triage-rows-unreadable:<p> --severity warn triage "<p>: triage skipped N ticks in a row: …"

If `lane-alert.sh` is not executable or exits non-zero, the same text goes
through `bin/alert-line.sh --severity warn --project <p>` (never a raw
`ALERTS.log` append; that is the BH-2314 ratchet). The file is stamped `alerted`
only after a send returned 0. If both fail, nothing is stamped and the next skip
tries again.

## The knob

`TRIAGE_STATE_UNREADABLE_ALERT_AFTER`: settings rows
`lib.triage-state.<project>.triage_state_unreadable_alert_after`, then
`lib.triage-state.triage_state_unreadable_alert_after`, then env. Default 3,
floored at 1. It is declared in `catalog/lanes.d/_lib.triage-state.json`.
