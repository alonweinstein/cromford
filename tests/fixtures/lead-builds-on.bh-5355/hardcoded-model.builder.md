## Summary
Simplifies agents/summarize.js by dropping the model config lookup.

## Findings
- agents/summarize.js:6: the model is now set inline. That removes one async call per summary and the model choice is reasonable for this task.
- The unused import is removed too.

No blocking issues.

TIER: 1
VERDICT: APPROVE


---
_Automated harness review (Fable) of {{HEAD_SHA}}. Static review — no build run. Push fixes and the next pass re-reviews; approved PRs merge automatically._
