Initiative I2 `pool-spend-ceiling`
- goal: pool model spend stays under the daily cap
- metric_query: csv:logs/cost-daily.csv#usd@lane=fly-pool
- cadence_hours: 24
- escalation_rule: > 50
- status: active
- last_value: 38
- last_decision: none
- check slot check:2:2026-10-04T07:00:00Z: no event yet

This check measured usd = 63. The only fix Archie sees is raising the
fly-pool daily cap, or turning the lane off.
