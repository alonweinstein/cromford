# `envelope.json` — where every number in it came from

RECONSTRUCTED, NOT CAPTURED. No box in this build had a grok binary or a
`~/.grok` tree, and BH-1494 forbids spending a metered call to manufacture one
(the xAI team 1ec95c24 is at its credit cap as of 2026-09-21 05:52Z). So this
file was assembled from figures somebody else measured, and this note says
exactly which.

## Verbatim from the ticket thread

the operator's comment on #1494, 2026-09-22 18:05Z, reporting one grok 1.0.40 session
run on the Mac at `grok-4.7`, reasoning effort high. Both the VALUES and the KEY
NAMES below are his, spelling for spelling:

| key | value |
|---|---|
| `usage.input_tokens` | 57398 |
| `usage.cache_read_input_tokens` | 1152 |
| `usage.cache_creation_input_tokens` | 0 |
| `usage.output_tokens` | 1 |
| `usage.reasoning_tokens` | 412 |
| `total_cost_usd` | 0.11785 |
| `total_cost_usd_ticks` | 1178500000 |
| `modelUsage["grok-4.7"]` | `inputTokens`, `outputTokens`, `cacheReadInputTokens`, `cacheCreationInputTokens`, `modelCalls`, `costUSD` |

The same comment records what `bin/grok-usage.sh` printed for that session
before this ticket: `58550 1 <blank> <blank> <blank>` — tokens, no cache, no
dollars. That is the gap `tests/cost-grok-usage.bh-1494-test.sh` pins.

## NOT from the thread — flagged as a guess

**`"result": "ok"` and `"type": "result"`.** The field that carries the ANSWER
TEXT in xAI's `--output-format json` envelope is not in the thread, and this
box cannot reach xAI's CLI docs (docs.x.ai 404s, x.ai/cli 403s). `.result` is
Claude Code's envelope spelling, and the key set the operator posted (`total_cost_usd`,
`total_cost_usd_ticks`, `modelUsage`, `costUSD`) matches that envelope spelling
for spelling — which is why it is the first thing tried. It is still a guess,
and `bin/agent-call.sh` codes it as one: when `.result` is not a string the RAW
envelope is passed through to `$OUT`, so a wrong guess costs a noisier answer,
never an empty one. That is also why `GROK_OUTPUT_JSON` defaults to `0`.

## Still owed

No `~/.grok/logs/unified.jsonl` fixture. 1.0.40 dropped
`sessions/**/updates.jsonl` for `logs/unified.jsonl` plus
`sessions/session_search.sqlite`, and nobody has captured a 1.0.x line of it.
`tests/cost-grok-usage.bh-1494-test.sh` §A8 prints that as a named TODO and
counts it as neither a pass nor a fail.
