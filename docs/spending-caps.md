# Spending caps

The bill is yours, so the caps are on by default. This page covers the three
settings in `selfhost.conf`, what happens when a cap is hit, and the other
limits you can tune once the harness is running. The
[deployment guide](SELF-HOST.md#8-spend-caps) has the same settings in brief.

## The three settings

| Setting | Template default | What it does |
|---|---|---|
| `SELFHOST_CAP_USD_PER_CALL` | `5` | Dollars one agent call may spend. Becomes `AGENT_CALL_BUDGET_USD` |
| `SELFHOST_CAP_USD_DAY` | `20` | Dollars one lane may spend in a UTC day. Becomes `LLM_USD_CAP_DAY` |
| `SELFHOST_CAPS_OFF` | blank (`0` is the same) | Set to `1` to turn both caps off |

Both caps must be positive numbers. `0` does not mean unlimited, and the
installer refuses it. `SELFHOST_CAPS_OFF=1` is the only way to turn them off.
The dry-run prints the caps it will set on its `CAP` lines.

There is no call-count or token cap yet. Dollars are the cap.

## What happens when a cap is hit

**The daily cap stops a call before it starts.** When a lane has spent its
`LLM_USD_CAP_DAY` for the day, `bin/agent-call.sh` refuses the next call. It
writes `AGENT_CALL_REFUSED llm-gate` to the call's output, exits 74, and logs
that nothing was called and nothing was billed. The lane picks up again the
next UTC day, or as soon as you raise the cap.

**The per-call cap is a soft limit.** It's handed to the Claude CLI as that
call's budget, and the CLI has been seen to finish a turn past it. Cromford's
own context limit is what ends a runaway session, so lean on the daily cap for
a hard stop.

## Changing a cap on a running harness

```bash
bin/harness-ctl.sh set <lane> LLM_USD_CAP_DAY <n>
```

The hub's triage lanes also have an older daily cap in
`catalog/lane-caps.conf`. You get the lower of the two, so raising
`LLM_USD_CAP_DAY` alone may change nothing for those lanes.

To stop every lane at once:

```bash
bin/harness-ctl.sh all-off <reason>
```

`bin/harness-ctl.sh all-on "<reason>"` turns them back on.

## Per-PR budgets

`catalog/cost-caps.conf` sets what a merged PR is allowed to cost, per
project, plus a fleet-wide daily ceiling. The hub's cost breaker reads it and
pauses a project whose spend per merged PR runs over its budget. The file's
header explains the format. Replace the shipped rows with your own projects before you rely on it.
