Render the tile.

Files: src/app/dashboard/ScanTile.tsx

## Observable outcome
The slice acceptance test passes end to end.

---
Part of #552
Order: 4 of 5
Blocked-by: #553 (hard), #555 (hard)
DEPENDS: #553 hard — this slice imports the contract (src/lib/scan/types.ts: ScanRow, ScanStore; src/lib/scan/store.ts: readScan(), writeScan())
DEPENDS: #554 soft — a separate slice of the same parent, no shared code
DEPENDS: #555 hard — readScan()
You do not wait for the contract to merge: this builds on the contract branch as soon as its pull request is open, and GitHub retargets this one when it lands.
Size budget: at most 300 lines of product code across 12 files.
Split child (depth 1): if the plan for this slice still sizes over the budget, it is built whole and says so. It is never split again.
