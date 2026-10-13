Types and a store that compiles and returns nothing yet.

Files: src/lib/scan/types.ts, src/lib/scan/store.ts

## Observable outcome
The slice acceptance test passes end to end.

---
Part of #552
Order: 1 of 5
CONTRACT: src/lib/scan/types.ts: ScanRow, ScanStore; src/lib/scan/store.ts: readScan(), writeScan()
This is the tracer every other part of this split builds on: the thinnest end-to-end path, from a real trigger to a persisted result to an outcome you can observe. It lands first and stays small: aim for 60 lines of product code, well inside the budget below. The names on the CONTRACT: line are working code the siblings import, not stubs. Each sibling adds one capability on top of it.
Size budget: at most 300 lines of product code across 12 files.
Split child (depth 1): if the plan for this slice still sizes over the budget, it is built whole and says so. It is never split again.
