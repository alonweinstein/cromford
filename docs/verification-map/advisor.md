# The advisor on execute and fix sessions (BH-3491)

**What it is:** the claude rung of `bin/agent-call.sh` adds `--advisor <model>`
to a session when `bin/lib/advisor.sh` says so. There is no UI. The console's
Costs screen shows the advisor's spend as its own stage (`execute-advisor`,
`fix-advisor`) beside the executor's, with no screen change.

## What turns it on

| input | where | default |
|---|---|---|
| `advisor.<project>`, then `advisor.default` | settings rows (`POST /api/settings`, console Settings) | none = off |
| values | `fable`, `opus`, `sonnet`, a full `claude-*` id, or `off` | |
| `AGENT_ADVISOR_MODEL` | env, read only when the box has no settings answer at all | unset |
| `AGENT_ADVISOR_STAGES` | `lib.advisor.agent_advisor_stages` row (`catalog/lanes.d/_lib.advisor.json`) | `execute fix` |

A stale cached settings row still beats env. `execute` is run-build's execute
and the resolver's fix round; `fix` is the in-build review fix, the QA fix and
the lander conflict fix. No other stage ever gets the flag, and neither does a
`AGENT_CALL_NO_TOOLS=1` call or a non-claude runner.

A Fable main takes only a Fable advisor. A Fable main with any other advisor
value runs without the flag.

## What the session is told

Only on an attempt that carries the flag, the one `--append-system-prompt` gains:
`Consult the advisor before committing to an approach that deviates from
plan.md, when the same error repeats twice, and before you write the final
summary.` The prompt itself (and its `PROMPT_SHA`, the call-guard fingerprint)
is unchanged.

## Fail-open

A launch that exits non-zero with zero tokens and the word `advisor` in stderr
or the error envelope (an old CLI's `unknown option '--advisor'`, a pairing,
allowlist or consent refusal) is retried once, on the same model, without the
flag. That writes one `logs/failovers.log` line, one warn alert through
`bin/alert-line.sh` (id `advisor-refused-<account>`, severity `warn`: the
digest, not a page) and
`flags/advisor-refused-<account>-<value>-<UTCday>`, which keeps the advisor off
for that account on that box until 00:00Z. A session that ran turns and failed
is never read as a refusal.

## Cost

`bin/transcript-cost.sh <session> --advisor` sums `usage.iterations[]` entries
of type `advisor_message`, at each entry's own model. Top-level usage is
executor-only, so the executor row is unchanged. `agent-call` writes the sum as
a second `logs/cost.csv` row, stage `<stage>-advisor`, same session id, note
`advisor`. When there is no transcript, it uses the envelope's iterations (one
turn only, `row_source=result`). It writes no row when the advisor was never
consulted. The advisor dollars join the phase and job spend. `bin/cost-rollup.sh`
counts both advisor stages in the `build` bucket.

On the envelope path (no transcript), the executor row is the envelope's
`total_cost_usd`, which may already hold the advisor's dollars (BH-3602). The
envelope's `modelUsage` decides it: it is session-wide and sums to the total,
so an advisor-family key means the total includes the advisor. Then the
executor row is the total minus that key's `costUSD`
(`row_source=result-net-advisor`, `result_usd` still the gross total) and the
advisor row carries the key (`row_source=result-modelusage`), so the two add up
to the total once. No advisor key: both rows stay `result`. An envelope that
cannot be split (no `modelUsage`, keys that do not add up to the total, two
advisor keys) keeps the total on the executor row as `result-adv-unverified`
and logs `advisor split unreadable` to `logs/cost-source-delta.log`. A Fable
main with a fable advisor shares one key; that case follows
`_ADV_ENV_SAME_FAMILY` in `bin/agent-call.sh` (`unverified` today, because the
probe's CLI never consulted the advisor; `includes` would write
`result-incl-advisor` and no advisor row).

## How to verify

- Suites: `tests/agent-call-advisor.bh-3491-test.sh` (drives `bin/agent-call.sh`
  with fake CLIs: flag, stages, pairing, env fallback, the refusal retry and the
  advisor row), `tests/transcript-cost-advisor.bh-3491-test.sh` (the pricer mode),
  `tests/agent-call-advisor-envelope.bh-3602-test.sh` (the envelope split).
- Live, envelope path: `awk -F, '$18 ~ /^result-(net-advisor|incl-advisor|modelusage|adv-unverified)$/' logs/cost.csv`.
- Live, after the pilot rows exist: `grep ',execute-advisor,' logs/cost.csv` on
  the box that ran the build, and `grep 'refused --advisor' logs/failovers.log`
  (empty, or one line per account per day).
