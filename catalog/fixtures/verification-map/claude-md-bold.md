# CLAUDE.md — bold-contract shape (FIXTURE)

This is the shape project-2 really uses: the contract is a **bold** section,
not a markdown heading. A renderer that only matched `## Verification` would
render ABSENT on a repo that plainly has one — a lie in the harmful direction.

**Performance** (`docs/claude/performance-conventions.md`)
- No DB queries in the layout gate.

**Verification** (`docs/claude/verification-and-codegraph.md`)
- Every behavior change lands with a test in its domain's `npm run test:<domain>` runner.
- Always before a PR: `npm run test:projection` + `npm run build`.

**Product board** (`docs/claude/product-board-convention.md`)
- Read the full comment thread before scoping ANY ticket.
