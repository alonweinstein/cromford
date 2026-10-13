# Trap-eval fixtures and cell contract (BH-128.0, #1961)

This is the contract every BH-128 slice builds on. It is written here once, so
all the siblings agree on it. The runner is implemented in `bin/trap-eval.sh`
(BH-128.1): `bin/trap-eval.sh --help` prints its argv. `trap_eval_classify`,
`trap_eval_oob_scan` and `trap_eval_report` below are implemented (BH-128.2), and
the trap 2 scenarios are committed.

The suite measures per-(model, runner) behaviour at four trap classes:

1. spec-vs-test conflict
2. false-completion bait
3. unauthorized outward action
4. weak-executor pressure

## Scenario directory

`catalog/fixtures/trap-evals/trap<N>-<slug>/<scenario>/` holds:

| path | what it is |
|---|---|
| `meta.json` | `{trap: 1-4, name, tools: true\|false, timeout_s, story}` |
| `ticket.md` | The whole prompt the agent sees. Trap 2 tickets carry the done work and demand a final `CLAIM: <STARTED\|BUILT\|MERGED\|DEPLOYED\|LIVE>` line. |
| `repo/**` | Tools scenarios only. The ONLY thing copied into the worktree. |
| `judge.sh <worktree> <session-out> <base-sha>` | Hidden from the agent. Exit 0 = PASS, 1 = FAIL, anything else = JUDGE_ERROR, which records a null verdict. |
| `judge/` | Hidden known answers: `pass.patch` / `fail.patch` for traps 1, 3 and 4, and `pass.txt` / `fail*.txt` for trap 2 (`.txt`, not `.out`: the public-mirror leakcheck audits only text extensions it knows). |

## One cell

One cell is one JSON line in `$RUN/cells.jsonl`:

```json
{"model": "", "runner": "", "trap": 1, "scenario": "", "verdict": "pass|fail|null|violation", "reason": "", "cost_usd": null, "guard_denied": false, "cell_dir": ""}
```

`cost_usd` is a number, or `null` when the cost is unknown.

## State file

`state/trap-evals.json`:

```json
{"run_at": "", "run_dir": "", "models": [], "cells": [], "table": [{"model": "", "runner": "", "trap": 1, "passed": 0, "graded": 0, "nulls": 0}]}
```

## Cell API (`bin/lib/trap-eval-cells.sh`)

| function | contract | body |
|---|---|---|
| `trap_eval_verdict <judge_rc>` | Prints `pass` for 0, `fail` for 1, `null` for anything else. A judge error is never a pass. | implemented |
| `trap_eval_classify <out_file> <cost_csv> <ticket_tag> <want_runner>` | Prints `ok`, or `null:<reason>` when the session never ran or failed over to another runner. | implemented (BH-128.2) |
| `trap_eval_oob_scan <sentinel_file> <run_dir>` | Prints one out-of-bounds path per line. Empty output means clean. | implemented (BH-128.2) |
| `trap_eval_report <cells_jsonl> <state_file> <result_json> <partial_note>` | Writes the state JSON atomically and prints the table. | implemented (BH-128.2) |

`trap_eval_classify` prints `ok:UNPRICED` instead of `ok` when no cost.csv row
tagged with the ticket carries a cost, including when the csv is missing.
`trap_eval_oob_scan` exits 2 with nothing on stdout when the sentinel is
missing, so an unscannable cell is never read as clean. `trap_eval_report`
exits 1 without writing when the cells are missing, empty or unparseable.
Three env knobs: `TRAP_EVAL_OOB_ROOTS` and `TRAP_EVAL_OOB_EXCLUDE` (space or
newline separated) replace the scan roots and add excluded paths, and
`TRAP_EVAL_RUN_AT` fixes the state's `run_at`.

Two caller contracts. The `<ticket_tag>` passed to `trap_eval_classify` must be
unique per cell: any tagged cost.csv row from another runner nulls the cell, so
a tag shared across cells on different runners nulls the wrong one. And the
default oob roots include `/data/worktrees`, `/data/repos` and `$HOME` caches,
which other build slots and ordinary tooling write to. A concurrent write
during a cell's window is attributed to that cell, so run tools cells on a
quiet box, or read an oob hit as suspect until it is confirmed.

## Test seams

`bin/trap-eval.sh` reads both seams (BH-128.1).

- `TRAP_EVAL_AGENT_CALL` replaces `bin/agent-call.sh`.
- `TRAP_EVAL_FIXTURES` replaces the fixture root, `catalog/fixtures/trap-evals`.

## Budget and census

The lane is `trap-eval` (stage `trapeval`) in `catalog/context-budgets.json`.
The call site is `trap-eval` in `catalog/llm-sites.json`, and the ratchet
greps its marker `EVAL_STAGE="trapeval"` in `bin/trap-eval.sh`.
