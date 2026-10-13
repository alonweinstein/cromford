# Pre-build repro gate: the drive stage

`pr_drive <project> <key> <build> <thread-json>` in `bin/lib/prebuild-repro/drive.sh` (BH-2041, order 3 of #2004).
`bin/prebuild-repro.sh` calls it at step 5. It prints one line, `<VERDICT>\t<reason>`, and always returns rc 0.
The runner records the verdict. This stage never writes `prebuild-repro.txt`. The contract is in
[../repro-gate.md](../repro-gate.md).

The runner calls it only after `pr_fetch_thread` answers rc 0 and classify says `run` (BH-2040,
[skip.md](skip.md)). A project with no board row stops earlier, at `cannot-drive fetch-not-wired`.

## Order

1. Preconditions. Each one prints `CANNOT_DRIVE` with the reason below. None of them spends money, writes a
   ledger row or writes anything to `$BUILD`.
   - `bin/prod-url.sh <project>` fails, is empty, or prints `-`: `no-prod-url`.
   - `QA_CLERK_SECRET_KEY` or `QA_TEST_USER_ID` is empty: `no-qa-role`. The stage checks the process env first,
     then `env/global.env` and `env/<project>.env` (via `harness_env_dir`). Those files are sourced only inside a
     subshell, so the runner's env stays clean.
   - `lane_knob prebuild-repro LLM_LANE_ENABLED <project>` is `0`: `llm-lane-disabled`.
2. The ledger read, before any spend. The D1 kind is `repro_gate` and the key is `pr_ledger_key <project> <KEY> <thread>`.
   - A thread with no key (bad JSON), a `jobs-client.sh` that cannot load, or `job_ledger_get` rc 1 (outage):
     `ledger-unreadable`. No call is made.
   - rc 0 means the verdict is reused. `reproduced` maps to REPRODUCED, `cannot_drive` to CANNOT_DRIVE,
     `not_reproduced[_uncommented]` to NOT_REPRODUCED and `already_fixed[_uncommented]` to ALREADY_FIXED. The reason
     is `ledger-reuse`. The stage rewrites `$BUILD/prebuild-repro.md` from the row's `detail` (read through
     `GET /api/ledger`), or from a "detail unreadable" line when that read fails. Any other status gives
     `CANNOT_DRIVE ledger-unknown-status`. Nothing is called in either case.
   - rc 2 (a real miss) goes on to the call.
3. The model is `lane_role_model postmerge.qa <project>`, which reads the `model_routes` row the post-merge prod QA
   already uses. No `repro` role exists. When no model resolves: `no-model`, with no call and no row.
4. The call, inside a subshell holding the project env so the QA creds reach the child only:
   `AGENT_CALL_LANE=prebuild-repro AGENT_CALL_BUDGET_USD_REPRO=<lane_knob REPRO_GATE_MAX_USD> bin/agent-call.sh repro <project> <model> 900 $BUILD/repro-run.txt <prompt>`.
   The prompt quotes the ticket title (`$BUILD/ticket-meta.json`), the body and every comment, oldest first. Each
   comment carries its `principal` flag, and the thread's `truncated` flag is quoted too. The prompt names
   `skills/qa-prod-drive/SKILL.md`, `bin/qa-drive.mjs` (1280 and 375 widths) and
   `/root/repos/<project>/docs/verification-map/`. The rules are read-only:
   - Sign in only as `QA_TEST_USER_ID`. The prompt carries the variable's name, never its value.
   - Never run `bin/qa-unbanned.sh`.
   - Any send, pay, delete, submit, or step off the prod origin means answer CANNOT_DRIVE.

   Because the drive may not unban it, a Clerk-banned QA account ends in an agent CANNOT_DRIVE. That call was billed,
   so the row is reused until the thread changes.

## After the call

| agent-call rc | Outcome | Ledger row | `.md` |
|---|---|---|---|
| 74..79 | `CANNOT_DRIVE not-billed-rc<rc>` (nothing was called or billed) | none | none |
| any other nonzero (budget stop, context kill, timeout) | `CANNOT_DRIVE cap-or-error` | `cannot_drive` | empty fields |
| 0, block unparseable | `CANNOT_DRIVE unparseable` | `cannot_drive` | empty fields |
| 0, NOT_REPRODUCED/ALREADY_FIXED without ROLE or with a URL off the prod origin | `CANNOT_DRIVE unverifiable-url` | `cannot_drive` | the parsed fields |
| 0, agent said CANNOT_DRIVE | `CANNOT_DRIVE agent: <observed>` | `cannot_drive` | the parsed fields |
| 0, REPRODUCED | `REPRODUCED <observed>` | `reproduced` | the parsed fields |
| 0, NOT_REPRODUCED | `NOT_REPRODUCED <observed>` | `not_reproduced_uncommented` | the parsed fields |
| 0, ALREADY_FIXED | `ALREADY_FIXED <observed>` | `already_fixed_uncommented` | the parsed fields |

The stop stage upgrades the two `*_uncommented` statuses to `not_reproduced`/`already_fixed` once it has delivered
its board comment. This stage never writes those two statuses.

The reason is flattened to one line and cut to 160 chars (`-` when OBSERVED is empty). The row's `detail` is
`{role,url,steps,observed,cost_usd,build}`, with each field cut well under the worker's 4000-char column.
`cost_usd` is `.total_cost_usd` from `repro-run.txt.json` when present, and `null` otherwise, never 0. `build` is
the build dir name. A failed `job_ledger_put` is logged to `$BUILD/pipeline.log`, and the verdict still returns. The
next build of the same thread may then spend again, and the per-call cap bounds that.

## The final block and the parse

The agent must end with five single lines: `REPRO_VERDICT: REPRODUCED|NOT_REPRODUCED|ALREADY_FIXED|CANNOT_DRIVE`,
`REPRO_ROLE:`, `REPRO_URL:`, `REPRO_STEPS:` (`;`-separated) and `REPRO_OBSERVED:`. Only the last 8 non-empty lines of
`repro-run.txt` are read. It is `unparseable` when any of these holds:
- no verdict appears in the window;
- two different verdicts appear;
- the verdict value is anything other than the four words exactly (for example `NOT_REPRODUCED probably`);
- a `REPRO_VERDICT:` line is inside a code fence, counted over the WHOLE file, so a fence opened above the window
  still counts;
- a `REPRO_VERDICT:` line starts with `>`.

Origin means the lowercased `scheme://host[:port]`. A URL with userinfo has no origin. NOT_REPRODUCED and ALREADY_FIXED
need `origin(REPRO_URL) == origin(prod)`. So `*.vercel.app`, `localhost`, another subdomain, and `http://` against an
`https://` prod are all refused.

## `$BUILD/prebuild-repro.md`

```
REPRO_ROLE: <role>
REPRO_URL: <url>
REPRO_STEPS: <steps>
REPRO_OBSERVED: <observed>
```

At most 2000 bytes, written tmp+mv. The render and stop stages read it.

## Knobs and budget

- `REPRO_GATE_MAX_USD` (lane `prebuild-repro`, 0.5..10, default 3) binds `AGENT_CALL_BUDGET_USD_REPRO` verbatim.
- `LLM_LANE_ENABLED` on lane `prebuild-repro` is checked here as a precondition. It and `LLM_USD_CAP_DAY` are also
  checked by agent-call's own gate (`AGENT_CALL_LANE=prebuild-repro`), where a refusal is rc 74 and writes no row.
- `catalog/context-budgets.json` lane `prebuild-repro` (stage `repro`): target 80K, ceiling 200K, grok 200K.
  It is `_unmeasured` because the stage is new.

Tests: `HARNESS_TEST_SANDBOX=1 bash tests/prebuild-repro-drive.bh-2041-test.sh`.
