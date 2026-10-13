## 8. Config

Every threshold is a config value with a documented default — set any of them in
`env/global.env`.

| knob | default | what it does |
|---|---|---|
| `PR_OWNER_SWEEP` | `1` | `0` = the lane does nothing, silently |
| `flags/pr-owner-sweep-off` | absent | the same kill switch as a file |
| `PR_OWNER_DRY_RUN` | `0` | `1` = decide and log everything, write nothing to GitHub and clear no marker on any box |
| `PR_OWNER_STALE_DAYS` | `14` | how long a head may stay `CONFLICTING` before `stale-conflict` |
| `PR_OWNER_GRACE_MIN` | `30` | a PR that moved this recently is OWNED by the event path |
| `PR_OWNER_MAX_ACTIONS` | `5` | writes per repo per run |
| `PR_OWNER_PR_LIMIT` | `200` | `gh pr list --limit` for both the open and merged lists |
| `PR_OWNER_EXTRA_REPOS` | empty | space-separated repos that are ours before they are a project |

The hook knobs (§10) are read once per run through `ph_knob`
(`bin/lib/pr-health.sh`). **The D1 settings row wins, then the env, then the
default.** A row or env value that is not a whole number is ignored and named
in `logs/pr-owner-sweep.log`. A settings outage falls through to env/default.
`0` is a value, and it turns that rung off. The seeds are in
`worker/jobs/schema.sql`.

| settings row | env fallback | default | read by |
|---|---|---|---|
| `pr_stale.rebase_hours` | `PR_STALE_REBASE_HOURS` | `24` | `po_stale` (#3935) |
| `pr_stale.replan_days` | `PR_STALE_REPLAN_DAYS` | `5` | `po_stale` (#3935) |
| `pr_stale.close_days` | `PR_STALE_CLOSE_DAYS` | `10` | `po_stale` (#3935) |
| `pr_owner.enroll_external` | `PR_OWNER_ENROLL_EXTERNAL` | `1` | `po_enroll`, `mc_enrolled_rows` |
| `pr_owner.ownerless_alert_hours` | `PR_OWNER_OWNERLESS_ALERT_HOURS` | `24` | the sweep's ownerless clock (`ph_streak`) |
| `pr_owner.mc_max_age_s` | `PR_OWNER_MC_MAX_AGE_S` | `900` | `po_mc_read` (BH-5124); `0` = never trust the file. No seed row. |

