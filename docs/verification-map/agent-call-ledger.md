# The agent-call choke point (the prompt ledger)

**What it is:** the `# >>> choke_guard` block in `bin/agent-call.sh`. Every
agent call in the fleet comes through this one script, and until BH-1037 the
only thing it did before spending money was assemble the prompt. Now, after the
prompt (and therefore its sha) is final and *before* the runner promotion, the
account pick, the phase row and any `run_attempt`, the script looks up a
persisted row keyed `(project, stage, promptsha)`. Inside the TTL a recorded
`ok` or `empty` answer is **replayed** — the body, the `.runner`/`.model`
markers, one log line — and no vendor is called.

The conductor's head-bound re-review is why it exists, and — since the round-2
fix — it is also the only thing that turns it on. It re-spawns on the same
unchanged head whenever a tick finds its job gone, and every re-spawn used to buy
the read again.

**The other half of BH-1037 already shipped as BH-1019 (#1074):**
`AGENT_CALL_RUNNERS` names the runners the failover ladder may call, and
`mc_rereview` passes `AGENT_CALL_RUNNERS=claude` because
`mc_review_lane_failure` **rejects** a non-Claude read — a descent on its behalf
bought an answer that was thrown away by construction. This build does not
reimplement it; it sits beside it.

## The knobs (all env-resolved, all documented in `env-templates/global.env.example`)

| knob | default | what it does |
|---|---|---|
| `AGENT_CALL_LEDGER` | `0` | **Opt-in, per caller.** `1` = read and write. `mc_rereview` exports it on its own call; nothing else does. `flags/agent-call-ledger-off` disables it even where it is set. |
| `AGENT_CALL_LEDGER_TTL_S` | `1800` | replay window, seconds. Non-numeric falls back to 1800. |
| `AGENT_CALL_LEDGER_STAGES` | `review` | stages the ledger reads AND writes; space or comma separated, `*` = all. |
| `AGENT_CALL_RUNNERS` | unset | BH-1019's, not this build's: runners the ladder may call. Unset = today's ladder, untouched. |

**Why it is opt-in, and not "every `review` call on the box".** `agent-call.sh`
runs AGENTIC sessions, so most stages are unreplayable on their face: replaying
an `execute` would hand back the transcript while performing none of the edits,
and replaying a `triage` would skip the comments and launches the first run
made. `review` looked like the exception — "a review's deliverable IS its text"
— but that is true of exactly one caller:

| stage `review` caller | head in the prompt? | deliverable | replay-safe |
|---|---|---|---|
| `mc_rereview` (`bin/lib/mc/rebase.sh`, via the shim; reached by `bin/merge-conductor.sh` and `bin/blocked-resolver.sh`) | yes — `$head` in the lede and that head's diff inlined from a deterministic path | the text read back out of `$OUT` | **yes** — it opts in |
| `bin/run-build.sh` review lenses (`bin/lib/rb/review.sh`) | no — `$BRANCH`/`$BASE`/`$KEY`/`$BUILD`, and the reviewer runs `git diff` itself | the FILE `$BUILD/review.md` the session writes | no |
| `bin/review-rescue.sh` | no — `$CAND`/`$KEY`/`$BRANCH` | the FILE `$CAND/review.md` | no |

A build whose box is rolled mid-fix-round and resumed inside the TTL would hash
to the same key on the FIXED head, replay the pre-fix `BLOCK` transcript, never
rewrite `review.md`, and buy a fix round against findings the fix had already
answered. So the caller says so, in one token beside `AGENT_CALL_RUNNERS`, and
`AGENT_CALL_LEDGER_STAGES` only narrows what an opted-in caller may replay.
Widening either is a config change, not a code change.

## Where the state lives

```
$HARNESS/state/agent-call-ledger/<project>/<stage>/<promptsha>.json   the row
$HARNESS/state/agent-call-ledger/<project>/<stage>/<promptsha>.out    the body
$HARNESS/state/agent-call-ledger/.pruned                              sweep stamp
$HARNESS/logs/agent-call-ledger.log                                   one line per replay
```

The path IS the key — there is no index to append to and no query to cap. Row
fields: `ts project stage promptsha outcome rc runner model bytes host`. Writes
are tmp + `mv -f`, **body first and row last**, so a row pointing at a body that
is not there cannot happen by construction. The sweep is mtime-based, once an
hour, bounded to the ledger directory, at 2× the TTL.

**Three outcomes, and only two of them replay:**

| outcome | when | replayed? |
|---|---|---|
| `ok` | rc 0, no error envelope, and `$OUT` has a non-whitespace byte | yes |
| `empty` | rc 0 and `$OUT` is blank (a `"result":""` completion) | yes, **labelled `empty`, never `ok`** |
| `failed` | a non-zero rc (including our own 2/75/76/78/79), **or an rc-0 claude error envelope** | never; the next call buys again |

**The rc-0 error envelope.** The claude CLI wraps a vendor error as
`{"is_error":true,"api_error_status":429,"result":"<the vendor's words>"}` and
can exit 0, so `.result` — the error TEXT — lands in `$OUT` and an rc-only
reading calls it a successful review. `choke_error_envelope` reads `$OUT.json`
(gated on the runner marker still saying `claude`, because `$OUT.json` belongs
to that branch alone and a stale one must not condemn a later rung's answer) and
classifies it `failed`. Without that, one 429 became a TTL-long stream of "a real
review with no verdict": the replay deletes `$OUT.json`, which is the only
evidence `mc_review_lane_failure` reads to tell a dead lane from a real review,
so each re-spawn took a strike and `bin/blocked-resolver.sh` closed a finished PR
(project-5 #1621, with a cache in front of it).

Everything else is a MISS, and a miss costs one extra purchase while a wrong hit
hands a caller an answer to a question it did not ask. So: a row whose `ts` is
non-numeric, a row past the TTL, a row whose `.out` is gone or blank-under-`ok`,
a row whose `runner` is not in the caller's `AGENT_CALL_RUNNERS`, a different
project, a different stage, a stage outside the list, `jq` missing.

**Rows that are never written at all.** The refusals that `exit` before the end
of the script — the restricted-primary refusal, the two cliff refusals and the
no-tools refusal — leave no row. Harmless (a `failed` row would not replay
either), but the store is not a complete log of refusals.

## How an operator reaches it

No UI — this repo has no user-facing app. The operator's screen is a live box:

| what | where |
|---|---|
| a replay happened | `tail $HARNESS/logs/agent-call-ledger.log` → `[<project>] review: LEDGER HIT ok promptsha=<12 chars> age=<n>s served-by=claude/claude-fable-5-1 — replayed, no vendor call` |
| the rows themselves | `ls $HARNESS/state/agent-call-ledger/<project>/review/` |
| a refused lane (BH-1019) | `head -1 <outfile>` = `AGENT_CALL_REFUSED runners-restricted …`, and `grep 'refused: the caller restricted the lanes' $HARNESS/logs/failovers.log` |
| the saving | `logs/cost.csv` simply has fewer rows. A replay writes no cost row, no `prompt-provenance.csv` row, opens no phase row and stamps no cooldown, because none of those things happened. |

The one consumer wired today is `mc_rereview` (`bin/lib/mc/rebase.sh`, behind
the `bin/lib/merge-conductor-lib.sh` shim) — the caller that re-asks the same
question of the same unchanged head. It passes `AGENT_CALL_LEDGER=1` beside the
`AGENT_CALL_RUNNERS=claude` it already passed (BH-1019), and it treats a replay
as what it is: `mc_lane_up` is skipped when `$OUT.replay` is present, because a
cached body proves nothing about whether this box's account is serving now.

## How to drive it

| what | how |
|---|---|
| the whole mechanism — hit, TTL, the three outcomes, both kill switches, the key's three parts, and the conductor consumer | `HARNESS_TEST_SANDBOX=1 bash tests/agent-call-choke-guard.bh-1037-test.sh` |
| the ladder is unchanged with the knobs off | `HARNESS_TEST_SANDBOX=1 bash tests/agent-call-provider-order-test.sh`, `HARNESS_TEST_SANDBOX=1 bash tests/agent-call-large-prompt-test.sh` (both pin `AGENT_CALL_LEDGER=0` explicitly: that is the default now, but they call the SAME prompt several times on purpose, so a box env that turned the ledger on fleet-wide would erase the ladder-order assertions they exist for) |
| the runner intent the replayed markers must survive | `HARNESS_TEST_SANDBOX=1 bash tests/review-provenance-test.sh` |

`tests/agent-call-choke-guard.bh-1037-test.sh` drives `bin/agent-call.sh` itself
against a scratch `$HARNESS` with fake `claude`/`grok`/`codex` CLIs that append
their own name to an order sink, and asserts on artifacts only — the order sink,
`$OUT`, `$OUT.replay`, the row JSON, `logs/agent-call-ledger.log`,
`logs/ALERTS.log`, `logs/cost.csv`. Case 10 drives `mc_rereview` for real.

## Where it does NOT apply

- The hub-no-build refusal (exit 77) and the unreadable-`@file` exit happen
  *before* the block: no lookup, no row, unchanged.
- The runner intent (`AGENT_CALL_RUNNERS`) is BH-1019's and is documented with
  that build. This block reads it in one place only: a row whose `runner` the
  caller has excluded is a MISS, because serving it would hand back a read the
  caller's own provenance gate rejects, on every re-spawn, until the TTL lapsed.
- In-flight dedup is deliberately absent: two concurrent misses on the same key
  both spend. the operator, 2026-09-13 — "we never lock and serialize".
