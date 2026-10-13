<!--
PROVENANCE: the findings below are REAL harness review output, copied verbatim
from the merge-review follow-ups the harness posted on example-org/project-5#47
(https://github.com/example-org/project-5/issues/47), covering the #46/#45 merge.
Only the trailing TIER:/VERDICT: lines are added here — the lens contract
requires them and a ticket comment does not carry them.

Why a ticket comment and not a build dir: builds/ exists only on the fleet boxes
(/root/harness/builds); no checkout on a laptop has one. This is the closest
real reviewer text reachable without the hub.
-->
# Merge review follow-ups — TK-12.2 (#46) / TK-12.1 (#45)

Fold in these small follow-ups from the #46/#45 merge review (non-blocking, same PR):

1. Add `correspondentkey` to `LINK_COLUMNS` in `tests/level2-unit/account-erasure.test.ts` so future tables linked only through it cannot escape the inventory.
2. `notifyOperator` on the erasure's 42703 skip path.
3. `CORRESPONDENT_SALT` must be set in Vercel prod, Railway `project-5-worker`, and `.env.local` before this ships. Name all three in the PR body. The key module already throws if it is missing; the skip-warning path is the loud fallback.

TIER: 2
VERDICT: APPROVE
