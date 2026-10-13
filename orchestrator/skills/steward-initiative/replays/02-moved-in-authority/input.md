Initiative I1 `tracer-first-slicing`
- goal: decomposed rework rate under 10%
- metric_query: csv:logs/outcome-rework-rollup.csv#rework_pct@slice=decomposed
- cadence_hours: 168
- escalation_rule: change
- status: active
- last_value: 12.5
- last_decision: approve (note: "keep slicing, tell me when it moves")
- links: https://github.com/example-org/cromford/issues/3966
- check slot check:1:2026-10-12T07:00:00Z: no event yet

This check measured rework_pct = 9.1. The next step Archie would take is to
comment the number on #3966. No merge, deploy or cap is involved.
