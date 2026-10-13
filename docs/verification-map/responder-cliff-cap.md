# Cliff-derived session ceiling, and the responder's two ceiling knobs

**What it is:** a second input to the context kill's ceiling. The
`# >>> context_kill` block in `bin/agent-call.sh` already bounds ONE claude
session at the lane's `context_kill_tokens` (see
[context-kill.md](context-kill.md)). BH-1384 lets that ceiling be derived from
the RUNNER's own price cliff instead: with `CONTEXT_KILL_CLIFF=1` and a model
that carries `cliff_tokens` in `catalog/model-prices.json`, the ceiling becomes
`min(lane cap, cliff - CONTEXT_KILL_CLIFF_MARGIN)`, and the stop is labelled
`CLIFF-AVOIDED:` rather than `CONTEXT KILL:` — the session was stopped to avoid
the vendor's 2x band, not because the lane was too big for its ceiling.

**It cannot invent a ceiling, only lower one.** A lane with no
`context_kill_tokens` key is unbounded, exactly as before, and the cliff is
never consulted for it.

**What is dormant, and say so.** Only `grok-4.6` / `x-ai/grok-4.6` carry
`cliff_tokens` today, and the context kill meters the CLAUDE rung only (it reads
the session transcript). So on today's fleet `CONTEXT_KILL_CLIFF=1` derives
nothing and every path is byte-for-byte the old one. The live lever for the
responder is `RESPONDER_CONTEXT_CAP_TOKENS`.

## How an operator reaches it

| knob | where | what it does |
|---|---|---|
| `RESPONDER_CONTEXT_CAP_TOKENS` | settings row `lane.watchdog-responder.responder_context_cap_tokens`, or env | `> 0` is the session ceiling verbatim (passed per command as `CONTEXT_KILL_TOKENS` on the tooled calls only). `0`, the default, asks for the cliff derivation instead. |
| `RESPONDER_CLIFF_MARGIN_TOKENS` | settings row `lane.watchdog-responder.responder_cliff_margin_tokens`, or env | how far under the cliff the derived ceiling sits. Default 10000. |
| `CONTEXT_KILL_CLIFF` / `CONTEXT_KILL_CLIFF_MARGIN` | the env `bin/agent-call.sh` reads | the mechanism itself, for any caller. Unset = off. |

Both lane knobs are registered in `catalog/lanes.d/watchdog-responder.json`, so
`bin/harness-ctl.sh show watchdog-responder` prints them with their defaults and
bounds, and the Mission Control settings page can write them.

## What to look for, per artifact

- `<outfile>.cliffcap` — `cliff=200000 ceiling=190000 model=<m> margin=10000`,
  written before the child starts and ONLY when the cliff is what lowered the
  ceiling. Removed before every attempt, beside `<outfile>.ctxkill`, so a
  marker can never outlive the attempt that wrote it.
- `logs/ALERTS.log` — `CLIFF-AVOIDED: <stage>/<project> on <model> stopped at N
  context tokens against ceiling M, derived from the <cliff>-token price cliff
  for <model>, after K API calls (session <sid>) …`. Exactly one line, and no
  `CONTEXT KILL:` line for the same event. A lane-cap stop is the reverse.
- `logs/failovers.log` — the ladder's own record with the same label, plus (when
  the margin was at or past the cliff) one line naming the cliff, the margin and
  the 1000-token floor.
- `logs/responder.log` — after a stopped act session, one line:
  `responder act session CLIFF-AVOIDED: stopped at 260000 against ceiling 190000
  (cliff 200000 for <model>) — no 2x bill; the keys this pass covered are
  stamped handled and come back after the 12h cooldown.` and
  `responder decision call (no tools, claude) rc=…` on every pass.
- `state/responder/handled.json` — the offered keys ARE stamped after a stop
  (rc 143 is outside the 74..79 before-billing family), which is what that log
  line says. The line and the state are asserted together. With
  `flags/alerts-db` present the same keys are also written through to the
  `brake:responder-handled` ledger rows after the file stamp (BH-2346), and the
  12h cooldown reads the file merged with those rows.
- `logs/cost.csv` — a stopped session still writes its row, priced from its own
  transcript (`row_source=transcript`).
- the child's environment — `CONTEXT_KILL_TOKENS`, `CONTEXT_KILL_CLIFF` and
  `CONTEXT_KILL_CLIFF_MARGIN` are all `env -u`'d off the claude invocation. A
  ceiling belongs to the call that set it, not to the builds that call may
  launch.

## How it is driven

`tests/responder-cliff.bh-1384-test.sh`, against a scratch `$HARNESS`:

- **A** — the real `bin/agent-call.sh` with a fake `claude` that grows a real
  session transcript under `$HOME/.claude/projects` and a `MODEL_PRICES` fixture
  carrying a cliff, no cliff, a null cliff and a string cliff. Ten adversarial
  negatives each run a session that WOULD be stopped if the cliff applied, and
  assert it survives; a positive control runs first so a fixture that cannot
  kill anything cannot make them pass.
- **B** — the real `bin/watchdog-responder.sh` (only its harness root rewritten)
  with a recording agent-call stub: what the call RECEIVES in its environment is
  the assertion, and a stub that writes the markers and exits 143 pins the log
  line against `handled.json`.
- **C** — the real `bin/agent-call.sh` behind the responder with
  `RUNNER_TRIAGE=grok` in the environment: the decision call answers on the
  claude stub instead of rc 78, the grok stub is never executed, and the
  fall-open path still runs the tooled pass when the decision answer is unusable.

There is no screen and no route: this repo's surfaces are cron lanes and shell
libraries. The operator-facing QA pass is `bin/harness-ctl.sh show
watchdog-responder` (both knobs with their bounds) and
`RESPONDER_DRY=1 bin/watchdog-responder.sh` (a dry pass, no call, no cooldown).
