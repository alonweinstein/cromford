# client-id-trust

- **Family key:** `fd7bbe69fac5`
- **30-day count when promoted:** 7
- **Projects:** project-4, project-1, pool-project-4, pool-project-2
- **Ruled by the miner:** 2026-08-26 (`state/rule-mining/20260826/10-findings-fd7bbe69fac5.md`)
- **Promoted to `checks/`:** 2026-08-29

## The findings it was mined from

```
2026-08-26 [project-4]            ticket=TK-330  lens=security :: Unsafe trust of client-supplied ids
2026-08-26 [project-1]        ticket=TK-115  lens=security :: Unsafe trust of client-supplied ids
2026-08-26 [pool-project-2] ticket=TK-139  lens=security :: Unsafe trust of client-supplied ids
```

Seven reviews, four projects, one question asked seven times by a paid model.
Reviewers caught it every time — that is the system working, and paying for it
every time is the system leaking.

## The objectivity test

- **Measurable observation:** an added line containing a `where:` object whose
  only key is `id`, in a file under `/api/`, `/server/`, `/actions/`, or named
  `route.ts` / `actions.ts` / `handler.ts`.
- **Named tool:** `checks/client-id-trust/check.sh` (awk over the added-line
  stream normalized by `bin/checks-run.sh`).
- **Explicit threshold:** one or more such lines.

## Known false positives

- A genuinely global lookup — an admin-only route, a webhook resolving its own
  event id, a lookup whose scope is applied on the NEXT line rather than in the
  same `where`. The check is line-local on purpose: a multi-line read is where
  a shell check starts guessing.
- A `where` whose scope column is named something this check does not know
  (it knows `userId`, `ownerId`, `orgId`, `organizationId`, `tenantId`,
  `clerkId`, `accountId`, `workspaceId`, `companyId`, `createdById`,
  `memberships`, and any explicit `AND:` / `OR:`).

Both are read-and-move-on for the human the hit parks it for. Nothing is
auto-fixed and nothing is auto-blocked.
