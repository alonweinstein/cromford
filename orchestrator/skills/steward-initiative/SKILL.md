---
name: steward-initiative
description: Look after one initiative the operator asked Archie to keep an eye on. Read its metric and last check, then stay silent, send one beat, or escalate when the rule says the operator decides.
verdicts: silent | beat | escalate
---

# Steward an initiative

An initiative is a goal the operator asked you to watch. It lives in the jobs DB table
`initiatives` (routes in `worker/jobs/src/routes/initiatives.js`), numbered
I<id>. The fields you read:

- `goal`: what the operator wants to be true.
- `metric_query`: how it is measured, `none` or
  `csv:logs/<file>.csv#<column>[@<column>=<value>]`.
- `cadence_hours`: how often it is checked.
- `escalation_rule`: `always`, `change`, or `> < >= <=` and a number.
- `status`: `active` or `dropped`. A dropped initiative gets nothing.
- `next_check_at`, `last_check_at`, `last_value`, `last_check_status`.
- `last_decision`, `last_decision_note`: the operator's last answer (approve, change,
  drop) and what he said.

Every check is recorded in `initiative_events` under the slot key
`check:<id>:<due_at>`. Read that slot before you spend anything. If it already
says `composed` or `sent`, the work is done; never pay for it twice.

## Steps

1. Read the row and the latest check event. Read the metric value for this
   check.
2. Apply `escalation_rule` to the value and `last_value`. If it does not fire,
   the answer is `silent`. A metric you cannot read is `silent` too, recorded as
   unreadable; absent is not zero.
3. If it fires and the next step is inside your authority (a comment, a HOLD, a
   ticket, an idea), the answer is `beat`: one message, recommendation first,
   the number from what to what, the links, and how to reply
   (`Archie approve I<id>`, `Archie change I<id> <what>`, `Archie drop I<id>`).
4. If it fires and the next step is MUST ASK (a merge, a deploy, a client-board
   write, a spend cap, a harness rule) or the operator's `last_decision` says he wants
   to decide, the answer is `escalate`: the same message, and the
   recommendation says plainly that he has to decide.
5. Never ask again what `last_decision` already answered.

New initiatives come from the operator's chat command, answered without a model turn:
`Archie, track <goal> | metric: … | every: 7d | escalate: change | links: <url>`.

## Verdicts

- `silent`: the rule did not fire, or the metric could not be read.
- `beat`: the rule fired and you can act on it yourself.
- `escalate`: the rule fired and the operator has to decide.
