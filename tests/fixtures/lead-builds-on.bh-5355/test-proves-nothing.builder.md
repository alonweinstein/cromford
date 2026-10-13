## Summary
Adds `--retry 3` to the vendor read in bin/sync.sh and a test for it.

## Findings
- bin/sync.sh:10: the retry flag is correct for curl and keeps `-f`, so a final failure still reaches `mark_failed`.
- tests/sync-retry-test.sh: new test covers the retry behavior.

No blocking issues.

TIER: 1
VERDICT: APPROVE


---
_Automated harness review (Fable) of {{HEAD_SHA}}. Static review — no build run. Push fixes and the next pass re-reviews; approved PRs merge automatically._
