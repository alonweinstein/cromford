# Runner price cliff (warn at it, route below it, price it)

**What it is:** the `# >>> cliff_route` block in `bin/agent-call.sh` plus
`cost_model_cliff` in `bin/lib/cost-row.sh` — a per-runner PRICE CLIFF declared
beside the rate in `catalog/model-prices.json` (`cliff_tokens`), and the three
things this repo now does about it.

xAI bills the WHOLE request at 2x once it exceeds 200,000 tokens. BH-653
measured the hub's `alert-triage` lane at a 676K median context over 1,087 calls
in 68h, so the majority of that lane's grok calls have been billed double —
while every cost view here priced them flat and nothing anywhere said the cliff
had been crossed. Three holes, one mechanism:

| | what happens | where it lands |
|---|---|---|
| **warn** | after a grok call, the session's per-call series is read from the grok ledger and the FIRST call whose context crossed the cliff is named | one line in `logs/<project>.log` |
| **route** | before a grok call, the lane's projected context is compared to the cliff; past it the call is NOT ISSUED and the ladder descends a rung | one line in `logs/failovers.log`, rc 79, `note` on the serving row |
| **price** | a grok row whose `input_toks + cache_read` exceeds the cliff is priced at 2x | `cost_usd` on the row, and `row_cost()` in the hub rollup |

**Where the number lives:** `catalog/model-prices.json`, `cliff_tokens` on
`grok-4.6` and `x-ai/grok-4.6` — 200000, and no other model has the key. A
runner with no cliff is never warned about, never routed and never doubled, so
adding or removing one is an edit to that file with no code change.
`bin/update-model-prices.sh` CARRIES the key from the committed catalog into
`state/model-prices.json` on its 04:30 refresh, because every reader prefers the
live table (see [model-prices.md](model-prices.md)) — without the carry the hub
would lose the cliff every morning.

**How an operator reaches it.** Routing is on for one lane today, because one
lane carries the key:

| lane | where it runs | routing |
|---|---|---|
| `alert-triage` | `bin/alert-triage.sh` (hub cron \*/10) | `cliff_route: true` in `catalog/context-budgets.json` |

Every other lane resolves to off. The lane lookup uses the same specificity
ladder as `_budget_for` and `_ctx_kill_ceiling` (project outweighs runner, most
specific wins), so a lane is never budgeted against one row and routed by
another.

**Knobs:**

| knob | effect |
|---|---|
| `RUNNER_CLIFF_ROUTE=1` | route, whatever the manifest says |
| `RUNNER_CLIFF_ROUTE=0` (or any other non-empty value) | do not route. Garbage is OFF, never on |
| `flags/cliff-route-off` | kill switch, beats the env in every form |
| `CLIFF_ROUTE_SCAN` (4000) | how many `logs/cost.csv` lines the projection reads |
| `CLIFF_ROUTE_SAMPLE` (10) | how many matching rows the median is taken over |
| `CLIFF_ROUTE_MIN_SAMPLES` (3) | below this many rows there is NO projection, so nothing routes |

**What "projected context" means.** The median of the last `CLIFF_ROUTE_SAMPLE`
successful (`rc=0`) `logs/cost.csv` rows for the same stage+project, in
`input_toks + cache_read` — the unit `catalog/context-budgets.json` states every
ceiling in. It is the lane's own recent history, not the prompt about to be
sent: the assembled prompt is ~20KB and never crosses anything, and what puts a
grok session past 200K is the agent's own reads during the tool loop. Any
runner's rows count, because the context is a property of the job (the runner pin
was removed from this lane on 2026-08-25 for that reason). A box with no history
— every fly builder — projects nothing and routes nothing.

**A cliff-routed descent is a WORKING FAILOVER, not a page.** No vendor failed;
a cheaper rung was chosen on purpose. So the tier-3/tier-3b gates write one
`failovers.log` line instead of beating `fleet_alert` and writing to
`ALERTS.log` (otherwise alert-triage would triage its own routing every tick),
and a survival lane that then FAILS alerts exactly as it does today. Routed with
nothing below it at all is the one loud case: one `STUCK` line naming
`RUNNER_<STAGE>_FALLBACK` and the kill switch, never `DEAD` — nothing ran, so
"every available lane failed" would be false.

**rc 79 has two meanings and they are told apart by a marker.** `agent_argv_refuse`
(the prompt does not fit in argv) and a cliff route both answer 79. The first
line of `$OUT` is `AGENT_CALL_CLIFF_ROUTED …` for the route and
`PROMPT_TOO_LARGE …` for the refusal; `cliff_routed_rc` reads it, and
`ladder_classify` maps the route to class `routed/cliff` (no retry, no cooldown,
descend) rather than `real-failure/prompt_too_large`.

**The `note` column.** `logs/cost.csv` gained a 24th trailing column. It is empty
on almost every row; after a route the row the SERVING rung writes carries
`cliff-routed:grok:<projected>><cliff>`. No cost row is written for the routed
attempt itself — nothing was called and nothing was billed.

**How to drive it:**

| what | how |
|---|---|
| the whole mechanism — warn, route, both kill-switch forms, the manifest default, the negatives, the tier-2 rung, pricing, the refresh carry | `bash tests/runner-cliff.bh-656-test.sh` |
| the ladder and the unmetered lanes are untouched | `bash tests/agent-call-provider-order-test.sh`, `bash tests/ladder-recovery-test.sh`, `bash tests/kill-not-failover-test.sh`, `bash tests/context-kill.bh-653-test.sh` |
| the row width | `bash tests/cost-append-test.sh`, `bash tests/cost-account-attrib-test.sh` |
| the cliff lookup alone | `MODEL_PRICES=catalog/model-prices.json bash -c '. <(awk "/^# >>> cost_price_tokens/{f=1;next} /^# <<< cost_price_tokens/{exit} f" bin/lib/cost-row.sh); cost_model_cliff grok-4.6'` → `200000` |
| the price alone | same source, then `cost_price_tokens grok-4.6 300000 10000 0 0` → `1.320000` (and `200000 0 0 0` → `0.400000`, because exactly at the cliff is not past it) |

`tests/runner-cliff.bh-656-test.sh` drives `bin/agent-call.sh` itself against a
scratch `$HARNESS` with fake `grok`/`claude`/`codex` CLIs on PATH and a seeded
`logs/cost.csv`, and asserts on artifacts only: the order the CLIs were called
in, the cost row's fields, `logs/failovers.log`, `logs/ALERTS.log`, the lane log
and the recorded `beat.sh` calls.

**What it looks like on a live box (rung-5 evidence, not yet observed as of
2026-09-18):**

- `logs/alert-triage.log` — the warn, after a grok-served triage whose session
  crosses:
  `[agent-call] CLIFF: triage/alert-triage grok call 4 context 245500 crossed the grok-4.6 cliff 200000 — every request from here is billed 2x by xAI`
- `logs/failovers.log` — the route:
  `triage grok: CLIFF ROUTE — projected context 676000 (median of the last 10 successful triage/alert-triage rows) is past the grok-4.6 cliff 200000; nothing called, descending to the next rung`
  and, if it reaches the survival lane,
  `tier-3: cliff-routed onto the OpenRouter survival lane after routed — no vendor failed on this rung, routine failover, not a page`
- `logs/cost.csv` — `tail -1 … | awk -F, '{print $5","$24}'` on a routed stage
  reads the SERVING runner and `cliff-routed:grok:676000>200000`. There is no
  `grok` row for that attempt at all.
- `state/model-prices.json` — `jq '.per_token["grok-4.6"].cliff_tokens'` is
  `200000` after the next 04:30 refresh.

**Known limits, stated rather than solved:**

- **Row pricing is per ROW, the cliff is per REQUEST.** A row's `input_toks` is a
  session figure, so a row over 200K may hold no single request over it. This is
  what acceptance test 6 asks for and it errs in the direction the manifest
  already documents (`runner_ceilings_note`: a cumulative cap against a
  per-request cliff). Per-request precision would need the per-call series in the
  rollup, which it does not have.
- **Attribution under concurrency.** The warn reads `bin/grok-usage.sh`, which
  picks the newest ledger touched since the call started — correct for one call
  at a time, and capable of naming a sibling session's crossing when two grok
  calls run on one box. Same documented limit as every other consumer of that
  reader.
- **The D1 mirror does not carry `note`.** `bin/jobs-client.sh` pushes a fixed
  list of 23 column names and truncates; the column is additive and the mirror
  is unaffected, but a cliff route is not queryable fleet-wide from the
  coordination DB yet.

**Where it does NOT apply:** every runner with no `cliff_tokens` — claude, codex,
gemini, openrouter, fireworks. This is a price-cliff router, not a context bound;
the harness's own cumulative-context ENFORCEMENT is a different mechanism with a
different unit and a different lane ([context-kill.md](context-kill.md)), and
neither one is extended here.
