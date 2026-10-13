<!---
DO NOT EDIT
-*- Mergify Payload -*-
{"version": 1, "state": "waiting", "queue_rule_name": null, "queued_at": null, "estimated_time_of_merge": null, "speculative_check_pr": null, "required_conditions": []}
-*- Mergify Payload End -*-
-->

# Merge Queue Status

- 🟠 **Waiting for queue conditions**
- ⏳ Enter queue
- ⏳ Run checks
- ⏳ Merge

<details>
<summary>Required conditions to enter a queue</summary>

- [X] `-closed` [📌 queue requirement]
- [X] `-conflict` [📌 queue requirement]
- [X] `-draft` [📌 queue requirement]
- [X] any of [📌 queue -> configuration change requirements]:
  - [X] `-mergify-configuration-changed`
  - [ ] `check-success = @mergify/Configuration changed`
  - [ ] `check-success = @mergify/Configuration has been deleted`
- [X] any of [🔀 queue conditions]:
  - [X] all of [📌 queue conditions of queue rule `default`]:
    - [X] `#changes-requested-reviews-by=0`
    - [X] `base = main`
    - [X] `check-success = "Prompt replay evals (prompts/** only)"`
    - [X] `check-success = "Syntax + shellcheck + config integrity"`
    - [X] `check-success = "Test determinism lint"`
  - [ ] all of [📌 queue conditions of queue rule `hotfix`]:
    - [ ] `label = fix-main-red`
    - [X] `#changes-requested-reviews-by=0`
    - [X] `base = main`
    - [X] `check-success = "Prompt replay evals (prompts/** only)"`
    - [X] `check-success = "Syntax + shellcheck + config integrity"`
    - [X] `check-success = "Test determinism lint"`

</details>
