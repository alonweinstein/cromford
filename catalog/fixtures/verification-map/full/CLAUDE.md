# CLAUDE.md — demo-os (FIXTURE, not a real project)

## Stack

Next.js, Prisma.

## Verification Contract

- Every behavior change lands with a test: `npm run test:projection`.
- Always before a PR: `npm run test:roles` + `npm run build`.
- Never weaken or delete an existing test to go green.

## Key Docs

- `docs/verification-map/` — the verification map.
