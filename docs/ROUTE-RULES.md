# Route rules — plan-driven model routing (P4, SHADOW MODE)

Today every build stage (plan, execute, fix, review, QA) runs on the
`build.*` rows of `model_routes` (Opus 5.5 since 2026-09-23,
`docs/BUILDER-ROUTING.md`). Ticket size and risk never pick the model, and a
quality failure retries on the same model. The approved target (the operator,
2026-09-25): **the plan's structure picks the model per unit, the reviewer never
downshifts, and escalation happens on measured failure.** No per-ticket budgets:
cost tripwires, not caps.

P4 is the measuring half of that target. It writes the routing rules down as
rows and records, for every build, what they **would** have picked beside what
the build actually ran on. **Nothing reads a rule to choose a model.** Turning a
rule live is a later ticket, decided on the `route_shadow` evidence.

## The tables (Cloudflare D1, `worker/jobs/schema.sql`, the P4 block)

| table | what it holds |
|---|---|
| `route_rules` | one row per rule: `name`, `priority`, `effect` (`route` or `bump`), `mode` (`shadow` or `off`, **no `live`**), `match_json`, `execute_role` (a `model_routes` role), `review_tier` (a floor), `test_scope`, `tier_bump`, `version` |
| `route_rule_changes` | append-only audit, one row per decision: `before_json` (NULL on create), `after_json`, `actor`, `reason`, `at` |
| `route_shadow` | one row per build dir: the matched rule, the bumps, the would-be execute role and model, the actual model, the would-be review tier, the classifier's tier over the planned files, the review model, the test scope, `differs`, the features |

Same D1 / bearer boundary as `model_routes`: no RLS step (see
`docs/MODEL-ROUTES.md`).

## The seeded rules (all `mode: shadow`)

| priority | rule | match | would-be execute | review floor | tests |
|---|---|---|---|---|---|
| 10 | `risk-surface` | any of `u0`, `invariant_bearing`, `risk_surface` | `build.execute` (the live role) | T2 | full |
| 20 | `docs-tests-copy` | `docs_only`, none of the three above | `build.execute.lite` | T0 | minimal |
| 30 | `specified-small` | `fully_specified`, none of the three above, `max_lines` 150 | `build.execute.lite` | T1 | impact |
| 100 | `bounce-escalate` (bump) | first-review BLOCK share > 0.30 on >= 5 reviews in 30 days, for the project OR for the unit class (the rule it matched) | `build.execute` | +1 tier | — |

`build.execute.lite` is a new `model_routes` role (seeded to Sonnet 5, the value
`triage.light` carries). **A rule names a role, never a model id**: the would-be
model is that role's rung 0 through `bin/lib/model-route.sh`, the path every
live lane uses, so moving it is a Models-screen edit, not a deploy.

Evaluation (`route_rules_decide`): only `shadow` rows; the first matching
`route` rule by `(priority, name)` sets the execute role, the review floor and
the test scope; then every matching `bump` rule applies in order (its
`execute_role`, `tier_bump` review tiers up, capped at T2). No match = the live
role, the classifier's tier, the full suite: exactly what the build runs today.

**The reviewer never downshifts.** There is no review-model column. The review
model recorded is always `build.review`'s, and the would-be review tier is
`max(rule floor, classifier tier over the planned files)`: a rule can raise the
depth of review, never lower it.

## The features (`route_features <build>`)

All from artifacts the pipeline already wrote before EXECUTE; no model call,
no clock. Same artifacts + same rules = the same answer, byte for byte.

| feature | source |
|---|---|
| `planned_tier` | `bin/lib/review-tier.sh review_tier_files` over `planned-files.txt` — the SAME classifier the review stage runs on the real diff — FLOORED by the same classifier over every path token in `plan.md` (a word ending in a code/data/doc extension, or a path through `migrations/`; URLs dropped). The max of the two wins. The floor exists because `bin/planned-files.sh` keeps only some prefixes and extensions (`bin/`, `worker/`, `supabase/migrations/`, `server/`, `packages/`, `.py`, `.go` are dropped). An empty list is `T2 reason=planned-files-unavailable`. |
| `risk_surface` | `planned_tier` is T2 (schema, migrations, `.sql`, auth, permission, role, billing, payment, token, webhook, middleware), or `KIND: migration` |
| `docs_only` | `planned_tier` is T0 (docs/tests/CI config only). The plan's own `KIND` label never makes a plan docs-only: a copy change in product files is judged on its files. |
| `u0` | the ticket title is a split's unit 0 (`<KEY>.0: ...`, `bin/run-decompose.sh`), or the plan declares a colon-anchored `CONTRACT:` line |
| `invariant_bearing` | the plan carries a `## System invariants` section whose FIRST content line does not start with an empty-section phrase: `none` (the plan prompt has a SIZE S plan write "None beyond the iron laws" plus one sentence of why), `n/a`, `not applicable`, `no [new/additional/system] invariants`, `nothing beyond` (any case, any trailing text). A later `(a)`-`(d)` clause line counts even after such a leading line. Only a heading of the same or a higher level closes the section: a deeper one (`### (a) Cross-run state`) is content, empty only if its own text starts with one of those phrases. A fenced heading is not a section. |
| `fully_specified` | `PLAN_TRACE: ok` (`bin/plan-gate.sh`), a declared line count (`bin/size-gate.sh`), an `## Acceptance tests` section, and for `KIND: bug` a complete reproduction |
| `lines`, `files` | `SIZE_DECLARED` from `size-gate.txt` |
| `bounce_*` | `GET /api/route-shadow/bounce`: first verdict per build job in `verdict_history` (joined to `jobs` for the project), and with `?rule=` only the jobs whose shadow row named that rule. No reviews is `rate: null`, never 0. |

**Unknown fails toward the frontier.** No plan, no planned files or an unreadable
artifact is T2, which is risk surface, which is the live execute role.

## Where it runs

`bin/run-build.sh`, between `rb_gate_overlap` and `rb_execute` (the
`# >>> route shadow` block): the last point before EXECUTE and the first point a
plan exists. (`EXECUTE_MODEL` itself is resolved in the prelude, before there is
a plan to read, so that is not where a plan-driven decision can happen.) The hook
runs `bin/lib/route-rules.sh shadow` as **its own process**: argv in, stdout and
stderr discarded, fds 6-9 (the repo, dedupe and slot locks) closed by the hook
and every other inherited fd above 2 closed by the script on entry (a box with
more slots has slot locks past 9), a 30 s ceiling, `|| true`. It cannot change
a variable, hold a build lock or alter the exit path of the build. It does add
wall time: up to 30 s, the ceiling. `tests/route-rules.p4-test.sh` section D extracts the block verbatim and
proves the runner argv byte-identical with the hook, without it, with a hostile
`route-rules.sh`, and with none at all.

What it writes: `$BUILD/route-shadow.json`, one
`ROUTE_SHADOW (log only) rule=... would=<model>(<role>)/<tier>/<scope> actual=<model>`
line in `$BUILD/pipeline.log`, and one `POST /api/route-shadow` row (idempotent
on the build dir, so a resumed build records once). Rules come from the worker,
cached at `state/route-rules.json` for an outage; no rules at all reads as "no
rule matched".

Kill switch: `ROUTE_SHADOW=0` (settings row `lib.route-rules.route_shadow`) or
`flags/route-shadow-off`.

## The routes

- `GET /api/route-rules` — every rule, priority order, `match` parsed.
- `PUT /api/route-rules` — the WHOLE row, the `model_routes` write pattern: an
  optional `expected_version` (the row's `version`; 0 = create) checked at read
  time and again as the first statement of the batch (409 on either), one
  `route_rule_changes` row per decision, an identical re-PUT writes nothing
  (`confirm: true` re-stamps it). Refused (400): `mode: live`, an unknown
  effect/tier/scope/feature/match key, and an `execute_role` that is not a
  routed hub role (a model id is exactly that). The seed skips any rule with an
  audit row, so an operator's decision is never undone by a deploy.
- `GET /api/route-rule-changes?name=&limit=` — the audit, newest first.
- `POST /api/route-shadow`, `GET /api/route-shadow?since=&project=&limit=`.
- `GET /api/route-shadow/bounce?project=&rule=&days=`.

Client verbs (`bin/lib/jobs/routing.sh`, `bin/jobs-client.sh`): `route-rules`,
`route-rule-put <json-file>`, `route-shadow [since] [project] [limit]`,
`route-shadow-bounce <project> [rule] [days]`.

## The nightly report

`bin/route-shadow-report.sh` (hub, 06:15Z, lane `route-shadow-report`): the last
24 h of `route_shadow` rows — builds, how many would have left the live execute
model and to which role, how many would have run a different model, how many a
bump rule escalated, per project and per rule — to `state/route-shadow/latest.txt`
and `<date>.json`, and one fleet-topic message. An unreadable worker is `n/a`,
never "0 builds", and posts nothing.

## Not in P4

- A live mode. The worker refuses `mode: live`; flipping a rule to live is its
  own ticket with its own argv test.
- Per-unit routing inside a decomposed ticket: the unit is the build (each split
  child is its own build, and `u0` catches the contract chunk).
- Bounce data for the lite role itself: every shadow row today ran on the live
  model, so the class bounce rate measures the plans a rule would pick, on the
  frontier model. It becomes a lite-model measurement only once a rule is live.
