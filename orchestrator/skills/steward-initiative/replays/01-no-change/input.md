Initiative I1 `tracer-first-slicing`
- goal: decomposed rework rate under 10%
- metric_query: csv:logs/outcome-rework-rollup.csv#rework_pct@slice=decomposed
- cadence_hours: 168
- escalation_rule: change
- status: active
- last_value: 12.5
- last_decision: none
- check slot check:1:2026-10-05T07:00:00Z: no event yet

This check measured rework_pct = 12.5.
