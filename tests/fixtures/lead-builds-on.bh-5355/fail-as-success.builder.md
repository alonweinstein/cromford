## Summary
The PR changes how bin/sync.sh handles an empty answer from the vendor API.

## Findings
- [Critical] bin/sync.sh:10: `curl -sS` drops `-f`, so a 5xx answer with an empty body is no longer a failure. The new branch then calls `mark_done` and exits 0. An outage is recorded as a finished run with no items.
- [Important] No test drives the empty-answer branch.

TIER: 2
VERDICT: REQUEST_CHANGES


---
_Automated harness review (Fable) of {{HEAD_SHA}}. Static review — no build run. Push fixes and the next pass re-reviews; approved PRs merge automatically._
