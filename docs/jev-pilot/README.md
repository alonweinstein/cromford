# Jev replay pilot (BH-5024)

Two scripts, Python 3 stdlib only.

- `replay.py` asks Jev and a Haiku baseline the same question about every PR the
  lead judged MERGE or BLOCK since a date, and writes one row per PR to
  `<out>/replay.jsonl`.
- `score.py` reads that file and applies the decision rule. The 2% threshold is a
  constant at the top of the file, fixed before any data was read. It is not a
  settings row on purpose.

## Dry run (spends nothing)

This builds an empty fixture dir and runs both scripts against it. `--dry-run`
never runs gh, curl, `bin/jev-risk.sh` or `bin/agent-call.sh`.

```bash
mkdir -p /tmp/jev-fx && echo '[]' > /tmp/jev-fx/prs.json
python3 -I docs/jev-pilot/replay.py --repo example-org/cromford --since 2026-09-01 --out /tmp/jev-dry --dry-run --fixtures /tmp/jev-fx
python3 -I docs/jev-pilot/score.py /tmp/jev-dry/replay.jsonl
```

With no rows, score prints `VERDICT: INCONCLUSIVE` and exits 2. That is the
right answer: no evidence is never a pass.

The fixture layout is in the header of `replay.py` (`prs.json`,
`verdicts/<pr>.json`, `cmp/<pr>.json`, `rule/<pr>.txt`, `jev/<pr>.json`,
`haiku/<pr>.json`, optional `model.txt` and `question.txt`).
`tests/jev-pilot-score.bh-5024-test.sh` builds a full one.

## Real run (the hub only, spends money)

Run from the hub checkout (`/root/repos/cromford`; `/root/harness` carries no `docs/`). This needs the `jev_risk.api_url` row and `TYPESAFE_API_KEY` set, and a
`jev-pilot.baseline` model route. If Jev is not configured, or there is no
baseline route, the run stops with rc 3 and asks nothing.

**Step 1 is required: probe five PRs first.** The TypeSafe request and
response shape in `bin/jev-risk.sh` (`jev_call`, `jev_parse`) is a guess, and
`empty` is terminal. If the guess is wrong, every billed answer settles `empty`
and that head can never be asked again under question version v1. A full run on
a wrong guess pays for every PR since 09-01 and seals all of them.

```bash
python3 -I /root/repos/cromford/docs/jev-pilot/replay.py --repo example-org/cromford --since 2026-09-01 --out /root/harness/state/jev-pilot --harness /root/harness --limit 5
python3 -I -c 'import json, collections, sys
c = collections.Counter(json.loads(l).get("jev_status") for l in open(sys.argv[1]) if l.strip())
print(dict(c)); sys.exit(0 if c.get("ok") and not c.get("empty") else 1)' /root/harness/state/jev-pilot/replay.jsonl
```

Go on only when that check exits 0: at least one Jev row came back `ok` and none
came back `empty`. On rc 1, stop. Read the `raw` column of the rows
(`GET /api/jev-risk?repo=example-org/cromford`) and fix `jev_parse` (and
bump `JEV_QV`) before asking anything else. Each Haiku row should also be `ok`
in `<out>/haiku.jsonl`; if they are all `failed`, check the baseline route.

**Step 2, the full set**, only after step 1 passed:

```bash
python3 -I /root/repos/cromford/docs/jev-pilot/replay.py --repo example-org/cromford --since 2026-09-01 --out /root/harness/state/jev-pilot --harness /root/harness
python3 -I /root/repos/cromford/docs/jev-pilot/score.py /root/harness/state/jev-pilot/replay.jsonl
```

The Haiku baseline runs through `bin/agent-call.sh` with `AGENT_CALL_NO_TOOLS=1`
and `AGENT_CALL_RUNNERS=claude`. It answers from the question text alone, just
as Jev does, and it cannot read the repo or run anything. If agent-call refuses
that call (rc 78), the run stops with rc 3.

The run is safe to repeat. Compares are cached in `<out>/cmp/`, Haiku answers in
`<out>/haiku.jsonl`, and Jev answers live in the shared ledger, so a head asked
once is never paid for again. A settled row is never redone. A row with a
`skip_reason` (unreadable verdicts or compare, Jev in flight, and so on) is
counted in the summary and retried next run.

## Reading the result

score.py exits 0 for PASS, 1 for FAIL, 2 for INCONCLUSIVE. PASS needs all three:

1. Jev called a lead-BLOCK PR low less than 2% of the time (2.0% fails).
2. Jev's BLOCK-called-low rate is at or below Haiku's.
3. Jev called more lead-MERGE PRs low than Haiku did (more reviews saved).

Both models are scored only on rows where both answered. The rest are counted as
excluded, by reason. The `would-lower` line counts the only move Jev could ever
make, rule tier medium to low, and how many of those the lead BLOCKed.

Post the table and the VERDICT line on #5024. Flip `jev_risk.mode` only on a PASS.
