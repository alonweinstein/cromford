We split this one into 5 parts and we are building them separately.

The plan for it came in at files=18 lines=1900 (lines=1900>300; files=18>12), against a budget of 300 lines of product code across 12 files. A pull request that size is the one nobody reviews properly, and it takes one long session instead of a few short ones. So:

TK-552.0 (#553): scan result types + empty store (the contract, it lands first)
TK-552.1 (#554): scan ingest
TK-552.2 (#555): scan read API
TK-552.3 (#556): scan dashboard tile
TK-552.4 (#557): weekly scan digest

The first part is the contract: the types, signatures and schema the other parts use. It is deliberately tiny, it goes in first, and the rest are built on top of it at the same time rather than one after another.

Each part is its own issue, its own branch and its own PR, with its own tests.

This issue stays open as the master. We took the `ai-build` label off it so no builder picks the whole thing up again, and we will comment here as each part lands.
