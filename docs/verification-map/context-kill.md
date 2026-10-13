# Context kill (the harness's own cumulative-context bound)

**What it is:** the `# >>> context_kill` block in `bin/agent-call.sh` — a ceiling
on how much CONTEXT one claude session may accumulate, enforced by this repo
rather than by a vendor flag. While the CLI runs, a sidecar (`context_meter`)
polls the session's own transcript through `bin/transcript-cost.sh` and sums
`input_tokens + cache_read` over the session's de-duplicated API responses. When
that crosses the lane's `context_kill_tokens`, the child is terminated, `$OUT`
gets a truncation marker as its LAST line, the rc is forced nonzero, and one
lane alert names the lane, the ceiling and the API call count.

It exists because the two bounds it stands beside were measured not to fire:
`--max-budget-usd` (a $4.67 turn against a $2.00 cap) and `grok --max-turns`
(32/38/56 tool calls against a cap of 25), both recorded INERT with their
evidence in `catalog/context-budgets.json`. BH-653 measured the bill those
inert bounds allowed: alert-triage 1,087 calls at a 676K median / 5.19M max,
responder 39 calls at a 4.27M median / 8.49M max, over 68h.

**How an operator reaches it.** Twenty-one lanes arm it, because twenty-one
lanes carry the key. Only claude calls are metered on any of them (see the last
section):

| lane | stage | where it runs | ceiling |
|---|---|---|---|
| `project-triage` | `triage` (any project without its own lane) | `bin/triage-shard.sh` (one ticket per shard), `bin/lib/rt/launch.sh` (single-session fallback), `bin/runner-bench.sh` (project `bench`) | 2,700,000 |
| `alert-triage` | `triage` | `bin/alert-triage.sh:234,236` (hub cron */10) | 400,000 |
| `responder` | `triage` | `bin/watchdog-responder.sh:118` (hub cron */20) | 6,000,000 |
| `rule-miner` | `mine` | `bin/rule-miner.sh:485` | 1,500,000 |
| `decompose` | `decompose` | `bin/run-decompose.sh` | 4,600,000 |
| `qa` | `qa` | `bin/lib/rb/pr.sh` `CC qa` (preview QA in run-build) | 8,300,000 |
| `build-plan` | `plan` | `bin/lib/rb/plan.sh` `CC()` (run-build) | 7,500,000 |
| `build-execute` | `execute` | `bin/lib/rb/execute.sh`, `bin/blocked-resolver.sh` | 53,600,000 |
| `build-review` | `review` | `bin/lib/rb/review.sh`, `bin/review-autopilot.sh`, `bin/review-prs.sh`, `bin/review-rescue.sh` | 8,000,000 |
| `build-fix` | `fix` | `bin/lib/rb/result.sh`, `bin/lander.sh` | 59,100,000 |
| `preplan` | `preplan` | `bin/run-preplan.sh` | 11,400,000 |
| `preplan-files` | `preplan-files` | `bin/planned-files-cheap.sh` | 100,000 |
| `preplan-map` | `map` | `bin/run-product.sh` | 2,700,000 |
| `lead-review` | `lead-review` | `bin/lead-review.sh` | 8,000,000 |
| `postmerge-prodqa` | `prodqa` | `bin/postmerge-qa.sh` | 35,000,000 |
| `product-prd` | `prd` | `bin/draft-proposal.sh` | 3,300,000 |
| `product-mockup` | `mockup` | `bin/draft-proposal.sh` | 4,700,000 |
| `product-revise` | `revise` | `bin/product-cmd.sh` | 3,300,000 |
| `product-signals` | `signals` | `bin/run-product.sh` | 5,800,000 |
| `product-synth` | `synth` | `bin/run-product.sh` | 4,700,000 |
| `product-ideation` | `ideate` | `bin/run-product.sh` | 5,200,000 |

**A kill is a runaway backstop, not a budget** (BH-2538). Ten of those
numbers follow one rule over the fleet's claude cost rows in the 7 days
`2026-09-18T21:31:27Z..2026-09-25T21:31:27Z` (`input_toks + cache_read`, rows above 0): kill = max(1.25 x p99 rounded
up to 100K, 2 x `ceiling_tokens`), with p99 = `sorted[min(n-1, int(n*0.99))]`,
so at 100 rows or fewer it is the sample max; the six larger lanes' p99
comes from a second 7-day pull recorded as `p99_source` in their basis. A session that reaches it is well past
anything the lane normally runs; the lane's p95 sessions finish. `product-revise`
and `lead-review` have no rows of their own and carry their analog's number
(`product-prd`, `build-review`). **A small sample never tightens a lane:**
under 100 rows a lane keeps main's number when the rule comes out lower
(`main-floor`: product-prd, product-mockup, product-signals, product-synth,
preplan-map, product-ideation), and under 30 rows a lane main left unarmed stays
unarmed (`small-sample-unarmed`: prompt-eval, 10 rows). Every basis records
`main_kill`. An unpinned lane on a stage with pinned
siblings (project-triage) is measured without the siblings' rows. Each lane's
`context_kill_basis` records the query, window, rows, p95, p99, max and rule;
`tests/context-kill-lanes.bh-2538-test.sh` and
`tests/context-kill-lanes.bh-2309-test.sh` recompute every one. The other three
(`alert-triage`, `responder`, `rule-miner`) were set by their own tickets.

**Lanes with no measured rows are UNARMED** until a 7-day window has claude rows
for them: `alerts-medic`, `orchestrator-turn`, `box-chat`, `prebuild-repro`, `trap-eval`, `feature-map-draft`. Each carries a
`context_kill_basis` with rule `unmeasured` and a note that says so; a kill
sized off no data (the old 2 x ceiling) would stop nearly every session, since
measured lanes run at 6.7-52x their declared ceiling. The resolver lets the most
specific matching lane decide first, so the unarmed `alerts-medic` (stage
`triage`, project `medic`) stays unbounded rather than falling through to
project-triage's number.

**Every kill is also a settings knob** (BH-2538). Each manifest lane that
carries a kill or a kill basis is registered in
`catalog/lanes.d/_lib.context-kill.json`, so the console can set it: the row
`lib.context-kill.context_kill_tokens_<lane>` (e.g.
`lib.context-kill.context_kill_tokens_project_triage`) overrides that lane's
`context_kill_tokens`. `bin/agent-call.sh` applies the rows with
`lib_env_apply context-kill` and `_ctx_kill_row` reads them. A row of 0 unarms
the lane; a positive row arms an unarmed one. When the worker cannot answer,
the box's cached row applies, and with no cached row the manifest number does,
so a settings outage never means "no kill". A caller's `CONTEXT_KILL_TOKENS`
still binds first.

**The same work killed twice goes to a person.** Every killed row's note names
its work: `context-kill:ceiling=<n>:total=<m>:tk=<ticket>:fp=<16 hex of the
caller's K3 fingerprint>`. When that work (same project and stage, the same ticket AND
fingerprint when both are declared, so a ticket whose thread moved is new work) reaches `CONTEXT_KILL_REPEAT_MAX` kills (default 2) inside
`CONTEXT_KILL_REPEAT_WINDOW_S` (default 86400), `bin/agent-call.sh` raises ONE
`CONTEXT KILL REPEATED` alert through `bin/lane-alert.sh --critical` (one alert
id per piece of work), and every later call for it is refused rc 74 before
anything is bought, with a `refused:context-kill-repeat` cost row. A triage
shard handles that refusal like a call-guard repeat: stamp kept, no per-tick
ALERTS line. The count is read from `logs/cost.csv`; there is no state file.
Both knobs are `lib.agent-call.*` settings rows (`catalog/lanes.d/_lib.json`);
`CONTEXT_KILL_REPEAT_MAX=0` turns the stop off.

The numbers live in `catalog/context-budgets.json` (`context_kill_tokens` on the
lane) and nowhere else — changing one is an edit to that file, no code change and
no deploy. Every other lane has no key and is unbounded exactly as before.
`CONTEXT_KILL_TOKENS` overrides the manifest for one call; `CONTEXT_KILL_POLL_S`
(default 15) is the poll interval. **Kill switch:** `flags/context-kill-off` or
`CONTEXT_KILL=0`, either of which restores the previous foreground invocation
verbatim.

**The unit is the SESSION, not the attempt.** A `--resume`d attempt inherits the
whole prior session's reads, because it is one context — so a kill total can read
higher than the tokens that attempt bought on its own. That is the unit the
ceiling is stated in, not an accounting error.

**One more knob that turns it off without saying so** — `COST_TRANSCRIPT_ROWS=0`
(and `flags/transcript-cost-off`) mint no session id, and the meter reads the
session's transcript by id, so a lane declaring a ceiling on such a box runs
UNBOUNDED. It is not silent: the first such call of the day writes one
`CONTEXT KILL UNENFORCEABLE` line to `logs/ALERTS.log` naming the lane, the
ceiling it cannot enforce and the reason, then runs the old foreground path.
Same line, different reason, when `bin/transcript-cost.sh` is missing or not
executable. The flag that dedups it is
`flags/alerted-ctxkill-unenforceable-<stage>-<YYYYMMDD>`.

**How to drive it:**

| what | how |
|---|---|
| the whole mechanism — kill, marker, alert, cost row, both switch forms, the no-key lane, and a failed meter read | `bash tests/context-kill.bh-653-test.sh` |
| the manifest side (the two ceilings, the bounds' truth values, lane shape) | `bash tests/context-budget-manifest-test.sh` |
| the fifteen BH-2309 lanes: every shipped number resolves, follows its rule, and a real `preplan-files` call is killed with a cost row that says why | `bash tests/context-kill-lanes.bh-2309-test.sh` |
| BH-2538: every armed number resolves and follows max(1.25 x p99, 2 x ceiling) over a 7-day window, the six unmeasured lanes are unarmed, a real `bin/triage-shard.sh` at project-triage's old p95 kill runs clean while a runaway one is stopped with a refused cost row (`rc` 143/137, `context-kill:ceiling=<n>:total=<m>:tk=..:fp=..`), and the same ticket killed twice raises one critical alert and is refused rc 74 the third time | `bash tests/context-kill-lanes.bh-2538-test.sh` |
| the unmetered lanes are untouched | `bash tests/agent-call-notools-test.sh`, `bash tests/agent-call-provider-order-test.sh` |
| the ceiling resolver alone | `CONTEXT_BUDGETS=catalog/context-budgets.json bash -c '. <(sed -n "/^_ctx_kill_ceiling()/,/^}/p" bin/agent-call.sh); HARNESS=/tmp/none _ctx_kill_ceiling triage alert-triage claude'` → `400000` |

`tests/context-kill.bh-653-test.sh` drives `bin/agent-call.sh` itself against a scratch
`$HARNESS` with a fake `claude` on PATH that writes a real, growing session
transcript — the same file the meter reads in production — and asserts on
artifacts only: the child pid, `$OUT`, `$OUT.ctxkill`, `logs/ALERTS.log`,
`logs/failovers.log`, `logs/cost.csv`.

**What it looks like on a live box (the rung-5 evidence, not yet observed as of
2026-09-18):**

- `logs/ALERTS.log` — one line per kill:
  `[orchestrator/agent-call] CONTEXT KILL: triage/alert-triage on claude-fable-5-1 killed at 4xx,xxx context tokens against ceiling 400000 after N API calls (session <sid>) — output truncated, stage fails by policy, no vendor failover`
- `logs/alert-triage.log` — that lane logs `tail -1` of its outfile, so a cut
  session's line ENDS with `CONTEXT KILL: triage/alert-triage session stopped by
  the harness at its context ceiling (...) — output above is TRUNCATED`. A clean
  session's line never carries it; that difference is the feature.
- `logs/responder.log` — `responder session rc=143`.
- `logs/failovers.log` — the policy-stop line, and NO `retrying as
  claude-opus-5`, no `one retry on the SAME lane`, no `tier-2`.
- `logs/cost.csv` — the killed session still bills what it spent: `rc` 143 (or
  137 if the CLI ignored the TERM), `row_source` `killed` (BH-3990: the call had
  started, so the row keeps the transcript's real token counts, blank when the
  transcript could not be read, never zeros).
  Its `note` column says why (BH-2309): `context-kill:ceiling=<cap>:total=<n>`,
  or `cliff-avoided:ceiling=<cap>:total=<n>` when the price cliff lowered the
  ceiling. The token comes from `$OUT.ctxkill` only, so a timeout or an external
  TERM (rc 143 with no marker) is never labelled a kill.
- `logs/claude-cost.log` — if the meter could not READ the transcript, one line
  saying the session ran unmetered. That is not a kill: fail-open toward the
  running work is deliberate.
- `logs/ALERTS.log` again — `CONTEXT KILL UNENFORCEABLE: triage/alert-triage
  declares context_kill_tokens 400000 but …` when the box cannot meter at all.
  A declared bound that cannot fire is the thing this ticket was written about,
  so it is never allowed to be quiet.

**Where it does NOT apply:** the codex, gemini, grok, openrouter and fireworks
lanes. The meter's unit is the claude transcript; the other vendors' usage is
only readable post-hoc from their own ledgers. The grok lane keeps its (inert)
`--max-turns` untouched.
