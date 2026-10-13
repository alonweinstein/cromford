# Adversarial review — TK-211 (general lens)

## Blocking findings

- **BLOCKING (D14):** the PATCH handler in `src/app/api/clients/[id]/route.ts` resolves the caller's role but never re-validates the target row against the resolved org, so a member of org 4471 can PATCH a client in org 9902 by guessing the id.

TIER: 2
VERDICT: BLOCK

## Re-review after fixes

The fix round addressed the authorization gap. Restating what was blocking so the record is complete:

- **BLOCKING (D14):** the PATCH handler in `src/app/api/clients/[id]/route.ts` resolves the caller's role but never re-validates the target row against the resolved org, so a member of org 4471 can PATCH a client in org 9902 by guessing the id.

Now fixed: the handler re-reads the row and compares `row.orgId` to the resolved session org before any write.

TIER: 2
VERDICT: APPROVE
