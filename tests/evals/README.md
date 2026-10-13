# Replay evals — the triage prompts, graded against what the fleet actually did

`prompts/<project>.md` carries the decision policy of a system that opens PRs on
four clients' repos: ready-to-build vs waiting-on-client, launch vs queue, the
duplicate-work guard, HOLD. Until 2026-08-29 an edit to one of those files
shipped with **nothing** checking that it still makes the same calls. A dropped
guard produces no error, no failed build and no alert; the first symptom is a
twin PR, or a ticket built off an unanswered thread, on a client's board, days
later.

This directory is the per-change gate. `tests/evals/run-evals.sh` replays 20
real historical triage decisions through the **current** prompt template and
fails when the answers move.

```
tests/evals/run-evals.sh --check          # free: fixture integrity, no model
tests/evals/run-evals.sh --list           # what is committed
tests/evals/run-evals.sh --dry-run        # compose every prompt, call nothing
tests/evals/run-evals.sh --limit 3        # smoke: the first 3 fixtures
tests/evals/run-evals.sh                  # the whole suite (metered)
```

Environment: `TRIAGE_MODEL` (**required** — the runner replays through the model
the stage is configured with and refuses to invent one), `EVALS_MAX_USD`
(default `5.00`), `EVALS_CALL_USD` (default `0.50`), `EVALS_MAX_REGRESSIONS`
(default `0` — any disagreement fails), `EVALS_FIXTURES`.

Exit codes: `0` graded and within threshold · `1` regression · `2` the suite
could not run, or did not grade everything it was asked to.

## How it relates to `bin/prompt-eval.sh`

`bin/prompt-eval.sh` is the **weekly, per-project baseline** gate over
`catalog/fixtures/golden/` — invented scenarios, real infrastructure, graded
against a recorded pass rate.

This runner is the **per-change** gate CI runs when `prompts/**` moves: real
captured decisions, graded against a fixed expected verdict with a regression
threshold. It **delegates** prompt composition, the no-tools contract, the
credential scrub and the grader to `prompt-eval.sh` rather than forking any of
them, so a change to the TICK SCOPE preamble or to what an action means moves
both gates together. What it adds is the per-fixture expected-vs-got table, the
threshold, and a hard spend cap.

Both callers ride the one `eval` lane in `catalog/context-budgets.json`. A
second `stage: eval` row with no project would collide with the first on the
`(runner, stage, project)` join key, so the lane declares both callers instead.

## What a fixture is

One real historical triage decision, captured off the live boards by
`tests/evals/capture-fixture.py`:

| file | what it is |
|---|---|
| `meta.json` | `project` (the only prompt this is graded against), `gate`, `board_shape`, `verdict_class`, `note`, and a `source` block recording exactly how it was reconstructed |
| `inputs.md` | the board state as the triage prompt saw it: the boards call, the ticket's list row, the ticket record with its thread, and the harness-side state |
| `expected.txt` | `KEY :: action[\|action]` — the verdict CLASS the fleet actually issued |
| `scope.txt` | the TICK SCOPE line for the `board-changed` gate |

**The content is real, and that is deliberate.** The golden scenarios under
`catalog/fixtures/golden/` are invented on purpose; these are not. A replay eval
is only worth its provenance: an invented thread grades the prompt against a
situation nobody was ever in. So these carry real client ticket text that
already flows through this fleet's prompts and repos, kept minimal (first +
last 6 comments, bodies capped), with emails, avatars, attachments, activity
feeds and internal ids stripped at capture and a credential scan that refuses
the capture on a hit. `run-evals.sh --check` re-runs that scan on every
invocation, including in CI.

### Provenance, and what is reconstructed rather than recorded

* **The verdict** is what the fleet did, not what someone thinks it should have
  done. `launch` fixtures are tickets with a build directory under
  `/root/harness/builds/<project>-<KEY>-<ts>/` — the harness launched them.
  `skip` fixtures are tickets sitting at `triageVerdict=needs_clarification`
  with the turn on the client and our own question as the newest comment, which
  every tick since has correctly left alone.
* **State at a past instant is replayed, not guessed.** For a fixture with
  `as_of`, `status` and `waitingOn` come from the ticket's own activity feed
  (the last `status_change` / `turn` at or before that instant; where the feed
  holds no transition yet, the create-time defaults, and `meta.json` says which
  of the two applied).
* **`triageVerdict` has no activity row carrying its value**, so the current
  value is used and the capture *refuses* unless the ticket was demonstrably
  triaged before `as_of` (a `triagedAt`, a triage activity, or the triage
  agent's comment in the thread).
* **Harness-side state is normalised** to "idle, slots free". It was never
  recorded per tick and reconstructing it would be invention. Every fixture here
  is a THREAD-driven decision, so an idle harness is the setting in which the
  recorded verdict is the only correct one — and that is stated inside every
  `inputs.md` rather than left as an assumption.
* **A fixture whose correct answer depends on state the frozen input does not
  carry is not a valid fixture.** Four project-2 `launch` candidates (TK-145,
  TK-159, TK-166, TK-186) were captured, replayed and then dropped for exactly
  this. That board slices work into ordered children, so each thread says "slice
  2 of 4, after TK-120.2" and a session with no tools cannot check whether the
  prerequisite merged. It answered `defer`, with reasoning that is correct for
  the input it was given: *"the slice is explicitly ordered after TK-120.2
  (shared schema.ts/engine.ts/builder files) and this tick shows no evidence
  TK-120.2 has built or merged"*. Grading that as a launch would have measured
  guessing rather than the prompt. See the coverage note below.
* `launch` fixtures accept `launch|queue`. The eval session has no tools and
  cannot see a free slot for itself, so queue is the same intent one tick later.
  The distinction these fixtures pin is build vs don't-build; every not-build
  action still fails.

### Coverage, honestly

20 fixtures across the four board-API projects: 8 `launch`, 8
skip-because-the-client-owes-us-an-answer, 4 skip-because-it-shipped-and-they-
are-validating.

| project | launch | skip |
|---|---|---|
| project-1 | 5 | 3 |
| project-3 | 2 | 3 |
| project-4 | 1 | 3 |
| project-2 | **0** | 3 |

**project-2 has no `launch` fixture, and that is a stated gap rather than an
oversight.** Every launch that board made in the capture window is a slice of an
ordered parent, and a no-tools session cannot verify the prerequisite (see the
bullet above). Its skip fixtures, the class the #25 incident came from, are
covered. Closing the gap means recording the PR/build graph in `inputs.md`,
which this capture deliberately does not invent. That is the follow-up.

**Only the triage stage is covered.** The review stage's verdicts are recorded
(`/root/harness/logs/findings.log`, ~12K lines of `verdict=APPROVE|BLOCK` per
ticket per lens) but its *input* is the diff of a build that has since been
merged, rebased or abandoned — there is no honest way to freeze what the review
prompt saw. A review fixture would be a reconstruction wearing a recording's
clothes, so none is committed. Queue, results-sweep and GitHub-Issues board
shapes are covered by the golden scenarios, not here.

## Adding a fixture

On the hub, with the project's env sourced:

```bash
set -a; . /root/harness/env/global.env; . /root/harness/env/<project>.env; set +a
python3 tests/evals/capture-fixture.py \
  --project project-2 --key TK-190 --id project-2-pb190-needs-clarification-skip \
  --expect skip --note "why this is the right call" [--as-of 2026-08-26T11:50:00Z]
```

Then `tests/evals/run-evals.sh --check`, and `--fixture <id>` to replay just it.

**Changing an `expected.txt` is a deliberate act.** If a replay disagrees with
the record, the first question is whether the prompt regressed — not whether the
fixture is inconvenient. Re-pinning a fixture to make CI green is how a gate
stops being one, so it belongs in the PR body with the reason.
