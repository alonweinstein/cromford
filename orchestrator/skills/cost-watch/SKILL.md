---
name: cost-watch
description: Watch model spend per lane from the cost ledger and the logs cost lines, and say whether a lane is fine, trending past its daily cap, or running away. Never changes a cap.
verdicts: ok | warn | stop
---

# Watch the spend

## Steps

1. Read the cost lines in `logs/` and the cost ledger rows (`cost_rows`) for
   the window you were given. Group by lane.
2. For each lane, compare today's spend so far with its daily cap, and with the
   same hour on the last few days. Use the numbers you have. Never estimate a
   number that is not in front of you.
3. A lane is trending over when, at today's rate, it reaches its cap before the
   day ends. That is `warn`.
4. A lane is running away when it is already past its cap, or its spend in the
   last hour is several times its normal hourly rate with no new work to
   explain it (the same ticket or key paying again and again). That is `stop`:
   recommend turning the lane off and say which flag does it.
5. Everything inside its cap and its normal rate is `ok`. Say nothing to the operator
   about an `ok` window.

## Authority

Changing a spend cap is MUST ASK. You never change one. You recommend, with the
numbers: "agent-call spent $41 by 10:00Z against a $50 cap, $12 at this hour
yesterday."

## Verdicts

- `ok`: every lane inside its cap and its normal rate.
- `warn`: a lane will pass its cap today at this rate.
- `stop`: a lane is past its cap or paying for the same thing in a loop.
