# PILOT TICKET (draft — NOT filed)

Drafted body for the first guardrail-pack adoption. Target: **project-2**
(repo `example-org/project-2` — the slug's "project-2" typo is real), chosen
as the pilot because it is the most active build and it already has test infra.

File it with:

```bash
gh issue create -R example-org/project-2 \
  --title "adopt guardrail pack: hardcoded-model-ids, native-dialogs, rls-on-create-table" \
  --label ai-build --body-file guardrails/PILOT-TICKET.md
```

Everything below the line is the issue body.

---

## Scope

Adopt three checks from the harness guardrail catalog into this repo's CI, so
three rules we currently enforce only by asking a reviewer to notice start
failing mechanically instead.

Copy each check into `.guardrails/<check>/` (rule/script + its README, verbatim
from `cromford/guardrails/`), then wire each as its own CI step:

1. **`hardcoded-model-ids`** (semgrep) — a `claude-*` / `gpt-*` / `gemini-*` /
   `grok-*` literal outside the resolver.
2. **`native-dialogs`** (semgrep) — `window.confirm/alert/prompt` in app code.
3. **`rls-on-create-table`** (shell) — a `.sql` migration that CREATEs a table
   and never enables RLS.

Files to touch:

- `.guardrails/**` (new)
- `.github/workflows/*.yml` — one new job, `guardrails`, with one step per check
- whatever existing violations the sweep turns up (see below)

**Deliberately excluded from the pilot, with reasons:**

- **`metered-vendor-choke`** — its applicability note requires a metered-client
  wrapper to point the calls at. Confirm whether this repo has one; if not, that
  wrapper is its own ticket and this check rides with it.
- **`verification-map-freshness`** — no `docs/verification-map/` exists here yet,
  so the check is a deliberate no-op. It adopts in the same wave as the Wave B
  map backfill.

## Preconditions to confirm FIRST (report findings before writing the CI job)

1. Does this repo have a model resolver (the project-4
   `src/lib/agents/model-selector.ts` shape)? **If not, port it in this PR** —
   `hardcoded-model-ids` with nowhere to move the literal to is a red CI and a
   dead end.
2. How many existing violations does each check find on `main` today? Run each
   check locally and report the counts in a comment before proceeding. A check
   that lands red gets disabled within a week, so the count decides the shape of
   the fix: small → fix in this PR; large → fix in this PR anyway, or narrow the
   check's `paths.exclude` with a written reason per exclusion (never a blanket
   one).

## Acceptance tests

Concrete, in this repo's framework (`npm run test:unit`, vitest):

- `tests/guardrails/hardcoded-model-ids.test.ts`
  - asserts running the check against a temp file containing
    `model: "claude-opus-4-8"` exits **nonzero**
  - asserts running it against a file using `resolveModel(...)` exits **zero**
- `tests/guardrails/native-dialogs.test.ts`
  - asserts a temp `.tsx` containing `window.confirm("x")` exits **nonzero**
  - asserts the in-app `<ConfirmDialog>` equivalent exits **zero**
- `tests/guardrails/rls-on-create-table.test.ts`
  - asserts a temp `.sql` with `CREATE TABLE` and no RLS line exits **nonzero**
  - asserts the same file plus `ENABLE ROW LEVEL SECURITY` exits **zero**
  - asserts `PR_LABELS=skip-guardrail` **alone** still exits nonzero (the label
    is not the gate); that a whitespace-only justification exits nonzero; that a
    long blob with no `Guardrail-Justification:` marker exits nonzero; and that
    label + `Guardrail-Justification: <20+ chars>` exits zero
- `tests/guardrails/clean-tree.test.ts`
  - asserts all three checks exit **zero** against the repo as it stands after
    this PR — i.e. the existing-violation sweep actually finished

Red before green: write these first, run them, and record the failing output in
`red.txt` before any check file is copied in. A check-invocation test that
passes immediately is vacuous — it is testing a script that does not exist yet.

## QA screens

None — this is CI-only, no user-facing surface. The equivalent proof is the
**CI demonstration** below, which is not optional.

## CI demonstration (the "prove the feature, not the scaffolding" step)

A green CI on a clean tree proves the job ran, not that it can fail. So, in this
PR's record:

1. push a commit that seeds one violation per check (e.g. a `claude-*` literal
   in an agent file, a `window.confirm` in a component, a `CREATE TABLE` with no
   RLS),
2. link the **failing** CI run for each check in the PR body,
3. revert the seed commit, link the passing run.

Also demonstrate the escape hatch once: add the `skip-guardrail` label plus a
`Guardrail-Justification:` line on the seeded-violation commit and show the job
skipping and printing the reason — then show that removing the marker line (label
still applied) makes it run again.

## Out of scope

- `metered-vendor-choke` and `verification-map-freshness` (see above)
- Any refactor beyond fixing the violations the three checks find
- Changing the checks themselves — if one is wrong for this repo, say so in a
  comment and it gets fixed in the catalog, not forked here

## Notes

- Source of truth for the checks: `cromford/guardrails/`. If this repo's
  copy drifts, the catalog wins.
- These checks are additive to review, never a replacement: they cover the
  mechanizable half of the iron laws. The judgment half stays in
  `prompts/build-discipline.md` and in the adversarial review lens.
