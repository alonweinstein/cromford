# Adversarial review — TK-208 (general lens)

## Blocking findings

- **BLOCKING (D14):** the PATCH handler in `src/app/api/clients/[id]/route.ts` resolves the caller's role but never re-validates the target row against the resolved org, so a member of org 4471 can PATCH a client in org 9902 by guessing the id.
- **BLOCKING (D1):** `tests/plan-builder.test.ts` never goes red — deleting the whole `computeSavings` body leaves all 6 cases green, because every assertion only checks that the function returned an object.
- **BLOCKING:** validate.txt records `npm run test:unit` with no exit code at all, while harness-suite.txt reports HARNESS_EXIT: 1 — a green claim contradicted by the harness's own run.

## Non-blocking notes

- D25: this diff adds an unused `parseCurrency` import to `src/lib/format.ts`; drop it in the dead-code pass.

TIER: 2
VERDICT: BLOCK
