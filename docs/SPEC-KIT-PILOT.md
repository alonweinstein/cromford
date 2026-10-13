# Spec Kit in the harness SDLC: adoption design + A/B measurement

Asked by the operator 2026-09-08 ("let's add this process to our SDLC; what's the best way to
measure if it's better than our current process"), pointing at https://github.com/github/spec-kit.
Status: DESIGN. The execute PRs launch after the operator confirms the pilot design below.

## 1. What Spec Kit is, mapped onto what we already run

Spec Kit (v1.0, GitHub, MIT) is Spec-Driven Development as a set of agent slash commands and
markdown templates scaffolded into a repo (`.specify/`). Stages, and our nearest equivalent:

| Spec Kit stage | What it produces | We already have | Gap |
|---|---|---|---|
| constitution | project principles the plan must check against | rules/CLAUDE.md + each repo's CLAUDE.md (iron laws, UI standards) | none; skip |
| specify | `spec.md`: prioritised user stories, functional requirements TK-nnn, measurable tech-agnostic success criteria SC-nnn, edge cases, `[NEEDS CLARIFICATION]` markers | the ticket thread + triage; plan.md mixes "what" and "how" | REAL: no separate what-artifact with testable success criteria |
| clarify | up to 5 targeted questions before planning | triage doctrine (`needs_clarification`, waitingOn=client) | none; keep ours, feed it the specify markers |
| plan | `plan.md` + research/data-model/contracts, with a constitution-check gate | Fable plan (prompts/plan-contract.md), plan gate refuses ambiguity, scope gate | none structurally; add "constitution check" = explicit iron-law checklist line per plan |
| tasks | `tasks.md`: dependency-ordered, story-sliced, `[P]` parallelisable | none; Opus executes from plan.md prose | REAL for medium/large tickets; noise for 1-file changes |
| analyze | cross-artifact consistency: every FR covered by a task, no task outside spec, constitution violations | scope gate (files) only | REAL: requirements coverage, not just file scope |
| implement | execute tasks in order, tick boxes | Opus execute stage | none |
| converge | assess codebase vs spec/plan/tasks, append remaining work | Fable review + repair rounds (repair forces tier 2) | PARTIAL: reviewer has no SC-nnn list to check against |
| checklist | "unit tests for English": requirement quality checks | none | small; folds into specify |
| bug extension (assess/fix/test) | validate diagnosis, reproduce, confirm symptom gone | kind-bug flow (#205) + repro-gate | none; ours is already stricter (real repro) |
| assess extension | go / clarify / kill for ideas | product-stages (ideate/synth) | none |

## 2. How to adopt (recommendation)

Do NOT install the `specify` CLI into the product repos. It scaffolds interactive slash commands
and `.specify/` directories per repo; our builds are headless prompt stages in run-build.sh, and
per-repo scaffolding would drift and leak into client repos. Vendor the templates instead (MIT,
pin the tag in `prompts/speckit/VERSION`) and add the three missing stages as harness stages:

1. **SPECIFY** (new, after triage, before plan; Fable): ticket thread -> `spec.md` using the
   spec-kit spec template (user stories P1/P2/P3, TK-nnn, SC-nnn measurable and tech-agnostic,
   edge cases). Any `[NEEDS CLARIFICATION]` marker = the existing needs_clarification verdict:
   post the questions on the ticket, waitingOn=client, stop. Constitution = rules/CLAUDE.md +
   repo CLAUDE.md, injected as-is.
2. **TASKS** (new, after plan; same model as plan): `tasks.md` from spec + plan, story-sliced,
   dependency-ordered. Skipped when the plan touches <= 2 files (flag `SPECKIT_TASKS_MIN_FILES`).
3. **ANALYZE** (new gate, before execute; Fable, cheap): every FR has a task, every task traces to
   an FR or the plan, no iron-law conflict. FAIL -> back to plan (one round), then PLAN_BLOCKED
   with an owner (item 6 stop-owner flow), never a silent proceed.
4. **EXECUTE** gets `tasks.md` as its work list (unchanged prompt otherwise).
5. **REVIEW** gets `spec.md` success criteria as a required checklist: each SC-nnn marked
   met / not met / not verifiable, with evidence. This is the converge loop; repair rounds
   already exist.
6. Build record: `spec.md`, `tasks.md`, `analyze.md` alongside plan.md/review.md in
   /root/harness/builds/<dir>/ ; the what-shipped comment quotes the SC list.

Cost estimate: +2 Fable calls and +1 plan-model call per build, roughly +$1.5-3 per ticket at
today's prices. This is the number the pilot has to justify.

## 3. Measuring "is it better" (the pilot)

Before/after is the wrong design: we changed 8 SDLC gates on 09-07 and the project-3 Codex canary
runs until 09-21, so any before/after delta is confounded. Run a concurrent, randomised A/B at
the ticket level.

**Assignment.** `SPECKIT_PILOT=1` on a box turns the stages on for tickets whose id hashes even
(`cksum` of the ticket key mod 2), off for odd. Same box, same board, same period, same reviewer.
Recorded in the build record (`arm=speckit|control`) and in cost-per-pr.csv (new column).

**Scope.** project-1, project-2, project-4. project-3 excluded until the Codex canary closes (two
experiments on one board can't be separated). Only tickets that reach "buildable" enter; pure copy
tickets (kind=copy) excluded from both arms. Bug tickets included (both arms keep the #205 flow).

**Size.** Target 20 tickets per arm (~3 weeks at the current build rate), interim read at 10/arm.
With rates this small, a difference is only worth acting on if it is large; the decision rule
below is deliberately coarse.

**Metrics** (all already logged or one column away):
1. First-pass approval: Fable review = APPROVE with zero repair rounds. (primary, quality)
2. Post-merge defects within 14 days: bug tickets, client "back to todo" / re-open, reverts,
   or hotfix PRs linked to the merged PR. (primary, quality; the one that matters to clients)
3. Repair rounds per ticket; red gates per ticket (scope/plan/analyze refusals).
4. Clarification rate AND conversion: tickets sent back to the client, and how many came back
   answered within 3 days. Specify should raise the first; if the second collapses (clients stop
   answering), that is a kill signal.
5. Wall time ticket-buildable -> PR open; cost per merged PR (cost-per-pr.csv).
6. Scope fidelity: files changed / files the plan named (>1.3 = drift).
7. Blind judged fidelity: an independent Fable judge scores each merged PR 0-10 against the
   ticket thread only (completeness, correctness, minimality), with spec/tasks artifacts stripped
   so it cannot tell the arm. Cheap (~$0.3/PR) and the only metric that is directly comparable
   across arms regardless of ticket size.

**Decision rule** (at 20/arm, or at 10/arm if the signal is already extreme):
- ADOPT if first-pass approval up >= 15 points OR post-merge defects down >= 40% relative,
  AND cost per merged PR is not up more than the repair-round savings.
- KILL if clarification conversion falls below 50% or cost per merged PR rises > 30% with no
  quality gain.
- Otherwise extend to 30/arm once, then decide.

**Reporting.** `bin/speckit-pilot-report.sh` (generalises the codex-canary compare) prints the
table per arm; the 5-min monitor gets one line "SPECKIT a/b: n=.. approve=../.. defects=../..".

**Freeze.** No other plan/execute/review prompt changes during the pilot window unless they apply
to both arms; every such change is logged in the pilot state file.

## 4. Execute PRs (after the operator's go)
1. prompts/speckit/ vendored templates + VERSION; SPECIFY stage + clarification wiring.
2. TASKS stage + ANALYZE gate + execute/review wiring; build-record artifacts.
3. Pilot switch (SPECKIT_PILOT, hash assignment), cost-per-pr arm column, report script,
   monitor line, blind-judge script.
4. docs + fleet sync; arm on for project-1/project-2/project-4.
