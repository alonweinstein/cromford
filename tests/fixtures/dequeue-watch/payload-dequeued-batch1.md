<!---
DO NOT EDIT
-*- Mergify Payload -*-
{"version": 1, "state": "dequeued", "queue_rule_name": "default", "queued_at": "2026-09-29T02:03:01.765266+00:00", "estimated_time_of_merge": null, "speculative_check_pr": null, "required_conditions": []}
-*- Mergify Payload End -*-
-->

# Merge Queue Status

- ✅ **Entered queue** — `2026-09-29 02:03 UTC` · Rule: `default` · triggered by @operator with the [`@mergifyio queue` command](https://github.com/example-org/cromford/pull/3396#issuecomment-5882236683)
- ❌ **Checks failed** · on draft #201
- 🚫 **Left the queue** — `2026-09-29 02:17 UTC` · at `b49a1b832b0d294ee7a46325ac2ace79dc50d235`

This pull request spent **14 minutes 34 seconds** in the queue, including **11 minutes 21 seconds** running CI.

## Reason

The merge conditions cannot be satisfied due to failing checks

- `Pure-logic gate fixtures`

Failing checks:
- ❌ [`Pure-logic gate fixtures`](https://github.com/example-org/cromford/actions/runs/5001/job/109225593793) ([job log](https://github.com/example-org/cromford/actions/runs/5001/job/109225593793))

## Hint

You may have to fix your CI before adding the pull request to the queue again.
If you update this pull request, to fix the CI, it will automatically be requeued once the queue conditions match again.
If you think this was a flaky issue instead, you can requeue the pull request, without updating it, by posting a `@mergifyio queue` comment.

<details>
<summary><strong>Waiting for</strong></summary>

- [ ] `check-success = "Pure-logic gate fixtures"`
- [ ] `check-success = "Tests cannot touch a real harness"`

</details>
<details>
<summary>All conditions</summary>

- [ ] `check-success = "Pure-logic gate fixtures"`
- [ ] `check-success = "Tests cannot touch a real harness"`
- `#changes-requested-reviews-by=0`
  - [X] #3396
- [X] `check-success = "Jobs worker — routes + schema"`
- [X] `check-success = "Mission Control SPA — unit tests + build"`
- [X] `check-success = "Prompt replay evals (prompts/** only)"`
- [X] `check-success = "Syntax + shellcheck + config integrity"`
- [X] `check-success = "Test determinism lint"`

</details>

Requeued — the merge queue status continues in [this comment ↓](https://github.com/example-org/cromford/pull/3396#issuecomment-5883232765).
