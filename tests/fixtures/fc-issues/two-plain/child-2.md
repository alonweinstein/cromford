Render the tile against the read API.

Files: src/app/dashboard/MetricTile.tsx

## Observable outcome
The slice acceptance test passes end to end.

---
Part of #552
Order: 2 of 2
Blocked-by: #553 (hard)
DEPENDS: #553 hard — this slice imports the contract (src/db/metrics.ts: MetricRow; src/api/metrics.ts: GET /api/metrics)
You do not wait for the contract to merge: this builds on the contract branch as soon as its pull request is open, and GitHub retargets this one when it lands.
Size budget: at most 300 lines of product code across 12 files.
Split child (depth 1): if the plan for this slice still sizes over the budget, it is built whole and says so. It is never split again.
