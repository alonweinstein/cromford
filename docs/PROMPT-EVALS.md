# Prompt / SOP regression evals

`bin/prompt-eval.sh` replays recorded board states against a project's real
triage prompt and grades the DECISION lines the session emits. It exists because
the fleet's prompts carry the decision policy — ready-to-build vs
waiting-on-client, launch vs queue, the duplicate-work guard, HOLD — and until
Wave E they changed with no regression testing at all. A prompt edit that drops a
guard raises no error and fails no build. The first symptom is a twin PR, or a
ticket built off a thread the client never answered, days later, on their board.

## The rule

**Run it before landing any change to `prompts/*`.** A prompt diff without an
eval run is the same claim as a code diff without tests: it compiles, so it must
be right.

```bash
bin/prompt-eval.sh project-2                    # score against the baseline
bin/prompt-eval.sh project-2 --scenario hold-comment-defer
bin/prompt-eval.sh project-2 --dry-run          # compose only, no LLM calls, free
bin/prompt-eval.sh --list project-2             # which scenarios apply
```

Exit 0 = graded and within the band (or no baseline recorded yet). Exit 1 = the
pass rate dropped more than `PROMPT_EVAL_MAX_DROP` (default 2) percentage points
below the recorded baseline. Exit 2 = the eval could not run, or graded **less**
than it used to. **Exit 2 is not a pass.**

## Side-effect freedom is mechanical

The session under test is the very thing that might be broken, so "the prompt
says do not act" is not a control — a prompt regression is exactly what would
break it. An eval session runs against fixtures that name real repo slugs, real
production domains and real `/root/harness` paths, on a box holding live board
tokens. Three layers, in order of how much they are worth:

1. **`AGENT_CALL_NO_TOOLS=1`** (new in `bin/agent-call.sh`). The claude lane runs
   with `--tools ""` — the CLI's documented "disable all tools" — and **without**
   `--dangerously-skip-permissions`, so if the ban were ever inert the failure is
   a call that stalls on a permission prompt rather than one that silently acts.
   Every other runner **refuses** (no verified equivalent flag), and the whole
   tier-3/3b/4 survival ladder is disabled for such a call, because a failover
   would hand the prompt to precisely those unguarded runners.
2. **The scrubbed environment.** Every eval call is invoked through `env -u` for
   each variable matching token / secret / password / credential / webhook /
   `DATABASE_URL` / `_PAT` / `_API_KEY` / `GH_*` / `GITHUB_*` /
   `*_SERVICE_ROLE_KEY` / `*_DB_URL` (and bare `DB_URL`) / `POSTGRES_URL*` /
   `POSTGRES_PRISMA_URL`, with runner auth
   (`ANTHROPIC_*`, `CLAUDE_*`) kept. A session that somehow got a shell has
   nothing to authenticate with.
3. **The prompt envelope.** Defense in depth only. It is never counted as the
   guard, and the tests deliberately do not credit it.

**Enforcement status, honestly:** layer 2 is VERIFIED (a driven test reads the
child environment back). Layer 1 is verified to *pass the flag* and to parse on
the installed CLI; that the session actually has no tools is a claim about the
CLI which only the first live run can settle. The lane's `bounds` in
`catalog/context-budgets.json` say exactly that.

## The one deliberate composition divergence

The live TICK SCOPE preambles end by telling the session that if the scope looks
inconsistent it should *"discard the scope and run the full SOP instead"* — go
enumerate the whole board. A fixture is inconsistent **by construction** (three
tickets exist on the board, one is in scope), so inherited verbatim that sentence
is an instruction to go fetch a real client's board.

So the eval **replaces** that sentence — it does not merely contradict it later
in the envelope — with a tail that says the BOARD STATE is the entire world for
the tick and the session has no tools. Everything else in every preamble stays
byte-identical to `run-triage.sh`, and `tests/prompt-eval-grade-test.sh` section
12 pins both halves: the live sentence must still exist in `run-triage.sh` (or
this divergence is stale) and must never appear in a composed eval prompt.

## What it actually measures

The **decision policy**, not the tick's tool use. It catches a dropped guard, a
flipped decision-table row, a lost precedence rule. It does not catch a broken
`curl`, a wrong API path, or an expired token — those belong to the live tick and
to `bin/lane-probe.sh`.

**Model fidelity:** `results-sweep` scenarios run on `TRIAGE_MODEL_LIGHT`
(default `claude-sonnet-5`) and everything else on `TRIAGE_MODEL`, mirroring
`run-triage.sh`'s own routing — the sweep lane is precisely where a cheaper model
is most likely to drop a rule, and grading it on the strong model would measure a
pair the fleet never runs.

**Runner divergence, stated plainly:** production triage on some boxes runs
`RUNNER_TRIAGE=grok`. The eval refuses non-claude runners, because only the
claude lane can enforce the no-tools contract. So on those projects the eval
measures the prompt **on claude**, and cannot see a regression that is specific
to how grok reads the SOP. That is a real gap, accepted deliberately: an eval
that ran with working tools and live credentials to keep runner parity would be
trading a client incident for a measurement.

Grading is **code-based** — per ticket key, is every emitted action in the
allowed set. No model judges another model, because a judge that drifts turns a
regression suite into a mood ring.

Four grading policies, each deliberate:

- **A missing decision is a FAIL.** A session that says nothing about a ticket has
  not handled it. Reading silence as a pass makes the eval greener the quieter the
  model gets.
- **Every emitted action must be allowed.** Not "any". A session that launches a
  duplicate build and then comments about it has still launched the duplicate.
- **An extra decision is a WARN.** A tick may legitimately decide on a ticket the
  fixture does not pin (one a scoped thread depends on).
- **A malformed line is counted and never credited.** The key it was meant for
  then reports MISSING, which is the honest result.

An empty `expected.txt`, an unparseable line, or a duplicate key **refuses** the
scenario. 0 of 0 is not a green run, and a fixture that grades something other
than what it appears to say is worse than no fixture.

## Coverage is checked separately from the rate

A rate is a fraction and nobody reads the denominator. Six of eight scenarios
erroring leaves two that pass and a headline of 100% — an *improvement* — while
three quarters of the policy went ungraded. So each run also compares its scored
expected-count against the baseline's: fewer is `COVERAGE-SHRANK`, exit 2, and it
cannot be recorded as a new baseline without `--force-baseline`.

## Scenarios are scoped to their project

A fixture's board text names a real repo slug, a real production domain and that
project's ticket-key prefix. Grading a project-1 SOP against project-2-flavoured
board JSON measures the mismatch, not the prompt — the session would spend the
tick correctly noticing the board is not its own. So a scenario runs **only**
against the project in its `meta.json`, and its `board_shape` is checked as a
consistency assertion (a mismatch is a broken fixture and is refused, not
skipped).

**Current coverage, which is also the current debt:**

| project | scenarios | note |
|---|---|---|
| `project-2` | 8 (9 pinned decisions) | the in-app board shape |
| `project-5` | 2 (3 pinned decisions) | GitHub Issues |
| `project-1` | 4 (4 pinned decisions) | in-app board: ready launch, waiting on client, duplicate PR, REVIEW_BLOCKED sweep |
| `project-3` | 4 (4 pinned decisions) | same four guards, `requester` turn side |
| `project-4` | 4 (4 pinned decisions) | same four guards, `requester` turn side |
| `project-8` | 4 (4 pinned decisions) | same four guards (board-api per fleet.conf) |
| `project-6` | 2 (2 pinned decisions) | GitHub Issues: ready launch, open `Blocked-by` |
| every other fleet project | **0** | reported as `NO SCENARIOS`, exit 2, rolled into the cron's one coverage-debt alert |

A project with no fixtures is a coverage gap, not a pass — the run says so and
the weekly cron alerts on it. Recording scenarios for the remaining projects is
the next fixture work. A project scoring against two to four pinned decisions
moves 25 to 50 points on one wrong decision, so read those regressions with the
denominator in mind. The project-6 scenarios key decisions `TK-<issue>`; its SOP
names no key prefix, so a live run that shows MISSING plus a WARN extra there
means the prompt needs one, not that the fixture is wrong.

## Adding a scenario

1. `mkdir catalog/fixtures/golden/<name>/` — name it after the guard or gate it
   exercises (`hold-comment-defer`, `dup-launch-guard-open-pr`).
2. `meta.json`: `gate` (`board-changed` | `queue-pending` | `results-sweep` |
   `daily-sweep`), `project` (**the project it will be graded against**),
   `board_shape` (`board-api` | `gh-issues` | `any`), `note` (what failure it
   catches).
3. `inputs.md`: the board state, threads, queue and build dirs the tick would
   have seen. **Sanitize the people and the content** — invented clients,
   invented names, invented ticket ids and bodies. Repo slugs, production
   domains and harness paths are real, because the SOP names them and a fixture
   that hid them would not exercise the SOP.
4. `scope.txt` (and `scope-2.txt` for a queue tick's `build-queue` entries): the
   TICK SCOPE list the gate would have produced.
5. `expected.txt`: `KEY :: action[|action]`. Use a set only where the SOP
   genuinely permits either answer. A set that admits everything grades nothing.
6. `tests/prompt-eval-grade-test.sh` checks the whole fixture set parses and that
   the gate reasons are still covered; `tests/prompt-eval-compose-test.sh` checks
   the scoping and the composed output. Both are free.
7. Re-baseline deliberately (below), because the denominator changed.

`catalog/fixtures/golden/README.md` carries the same layout table.

## Re-baselining is a deliberate act

The baseline lives in `state/prompt-eval-baseline.json` (machine-local — `state/`
is gitignored, so each hub records its own).

```bash
bin/prompt-eval.sh project-2 --baseline         # record the current rate
bin/prompt-eval.sh project-2 --force-baseline   # record over a regression
```

`--baseline` **refuses** when the run is a regression or graded less than the
last one, and says why. `--force-baseline` is the explicit override. Every
overwrite — forced or not — appends `pass_rate old -> new, expected old -> new`
to `ALERTS.log`, because a baseline is the only record that the prompt used to do
better and a silent change to it is indistinguishable from one made to shut a
gate up. `--baseline` with `--cron` is rejected outright: re-baselining the whole
fleet unattended is how a regression becomes the new normal.

If a regression is genuinely the new intended behaviour, change the fixture's
`expected.txt` with the reasoning beside it, then re-baseline.

## Cost, and why this is never in CI

Every scenario is one real metered LLM call. It rides `bin/agent-call.sh` on
stage `eval`, which has its own lane in `catalog/context-budgets.json`, so the
spend lands in `logs/cost.csv` under `eval` instead of hiding inside triage.

Composed prompts measure 22-23KB, about 5.8K input tokens each:

| | |
|---|---|
| `project-2` (8 scenarios) | ~46K input tokens |
| computed floor at fable-5 rates ($15/M in, $75/M out) | **~$0.90 per project run** |
| whole fleet as it stands (project-2 + project-5) | **~$1.10 floor** |

That floor is arithmetic, not a measurement. The real figure will be higher —
and with tools disabled the sessions can no longer grow their own context, which
is the one thing that would have made it much higher. **Nothing has been measured
yet: the first live run is what prices this lane**, and the lane's manifest row
says so rather than carrying an invented number.

Wired per-PR, this would bill on every push and gate merges on a model's mood.
It runs manually before a prompt change, and weekly:

```
50 6 * * 1 /root/harness/bin/prompt-eval.sh --cron >> /root/harness/logs/prompt-eval.log 2>&1
```

`--cron` walks `fleet.conf` and skips projects with no prompt file. On a
regression it writes an ALERTS.log line plus a `fleet_alert` beat naming the
project, the rate and the artifact directory. It alerts the same way — not
silently — when a project has no scenarios, produced no scored result, or graded
less than last time; when the project list itself is empty; and when not one
project in the set produced a graded result.

## Environment

| var | default | what it does |
|---|---|---|
| `PROMPT_EVAL_MAX_DROP` | `2` | regression threshold, percentage points |
| `PROMPT_EVAL_MODEL` | `$TRIAGE_MODEL`, else `claude-fable-5-1` | judgment-tick model |
| `PROMPT_EVAL_MODEL_LIGHT` | `$TRIAGE_MODEL_LIGHT`, else `claude-sonnet-5` | sweep-tick model |
| `PROMPT_EVAL_PROJECTS` | all of `fleet.conf` | pin the `--cron` set |
| `PROMPT_EVAL_FIXTURES` | discovered | point at another golden directory |
| `PROMPT_EVAL_BASELINE` | `state/prompt-eval-baseline.json` | baseline file |
| `PROMPT_EVAL_AGENT_CALL` | `bin/agent-call.sh` | test seam (the compose suite points it at a recorder) |
| `PROMPT_EVAL_TIMEOUT` | `1800` | per-scenario seconds |

Artifacts per run land in `state/prompt-eval/<project>/<ts>-<pid>/`: the exact
composed prompt, the session output, the harvested decisions, the grade for every
scenario, and the list of environment variables that were scrubbed. When a
regression fires, that directory is the evidence.

## Review-stage fixtures: none, by design (BH-527)

Parent #527 asked for a `tests/evals/` fixture that replays a review and asserts
the verdict `REVISE`. There is no honest way to add one today, and adding it
anyway would fail CI rather than guard anything:

- `tests/evals/README.md` says it out loud — "Only the triage stage is covered."
  A review's *input* is the diff of a build that has since been merged, rebased
  or abandoned, so a review fixture would be a reconstruction wearing a
  recording's clothes.
- `tests/evals/run-evals.sh --check` runs on every PR and grades triage actions
  only: its integrity pass validates each fixture's expected action against
  `launch|queue|comment|status|skip|defer|close|escalate`.
- `REVISE` is not in this repo's review vocabulary at all. A lens answers
  `APPROVE|BLOCK` (plus `TIER: 1|2` from the general lens), and a fixture
  expecting `REVISE` would be graded against a word nothing writes.

So the guarantee is delivered two other ways: deterministically, by the scorer —
the model only PROPOSES in `evidence-proposed.txt` and `bin/lib/evidence.sh`
decides the verdict from the artifact on disk, so a CONFIRMED whose artifact is
missing cannot render (that decision rule arrives with #527's scorer slice;
today the lib is the interface and scores zero claims, which is why nothing is
demoted yet) — and by the review prompt, which now carries the
EVIDENCE VERDICTS paragraph telling the reviewer to open each CONFIRMED row's
artifact and treat a mismatch as a verification-integrity finding
(`tests/evidence-gate-test.sh` §B drives the real review-lens block and asserts
on the prompt the reviewer was handed).

What a review-stage replay lane would need, if someone builds it later: a frozen
diff plus the captured review prompt as the fixture input (not a rebuilt one), a
`review` stage in `run-evals.sh` beside the triage stage, and an
`APPROVE|BLOCK` grader with its own action list. Until those three exist, this
note is the record of why the directory has no review fixture.

## Known coupling

The TICK SCOPE preambles in `prompt-eval.sh` are replicated from
`bin/run-triage.sh` rather than shared, because Wave B was editing that file in
the same round. They must stay identical apart from the documented tail
divergence. The next change to `run-triage.sh` should factor them into one file
both callers source, parameterised on that tail; whoever does it should also note
that the live queue/sweep preambles append `$BOARD_SEC` when the board moved
during a queue tick, and the eval composes only the empty-`BOARD_SEC` variant —
a scenario for the board-moved-under-a-queue-tick case would need that branch.
There is a `TODO(dedup)` at the replication site saying the same thing.
