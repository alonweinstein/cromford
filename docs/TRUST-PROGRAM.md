# Fully-Trusted Autonomous Development — program tracker

Approved by the operator 2026-08-19 ("I love all of these 8 ideas let's do them"), born
from the 2026-08-12..19 live-stress week. Standing process change shipped with
this file: **harness changes go through PRs on this repo** (branch → PR →
Harness CI → review → merge), no more direct pushes to main. The orchestrator's
merge authority applies to these PRs like any other.

| # | Workstream | Status | Where |
|---|-----------|--------|-------|
| 1 | Post-deploy verification: prod QA smoke + error watch + auto-revert | NOT STARTED | harness (new bin/post-deploy-verify.sh + deploy-train integration; needs per-app Sentry read) |
| 2 | Earned-autonomy dial: metrics set per-project tier scope | PARTIAL — the DEMOTION half shipped (Wave D). The first graduation step is merged with BH-1668 (live proof pending until the first unattended enqueue is observed on a real board): a tier-2 PR on a Mergify repo that the conductor classified READY, with an APPROVE on its head, the required check green and `mergeable_state` clean, enqueues itself (`@mergifyio queue` under a PAT, once per head; `MC_AUTOENQUEUE`, docs/MERGE-CONDUCTOR.md section 4). Per-project tier-scope graduation is still not built | harness (reopen-metrics.sh now iterates fleet.conf + reads GitHub-Issues reopens; run-build tier gate forces tier-2 above `REOPEN_DEMOTE_RATE`. Knobs: `REOPEN_DEMOTE_RATE`=0.15, `REOPEN_MIN_SAMPLE`=10, `REOPEN_EXTRA_LENS`=0, `REPAIR_TIER_MAX`=2, `REPAIR_TIER_ENFORCE`=0 (the repair-round demoter, SDLC item 3: counted and recorded on every build, disarmed until `REPAIR_TIER_ENFORCE=1` is set in `env/global.env`), `SCOPE_GATE_ENFORCE`=0 (the scope-gate demoter, SDLC item 4: the diff is classified against the plan's file list on every build and only the `protected` verdict is demotion-eligible, disarmed until `SCOPE_GATE_ENFORCE=1` is set in the same file). `KIND_GATE_ENFORCE`=0 (the bug-flow demoter, SDLC item 7: every build is classified `bug|feature|copy|migration|infra` and recorded, and a bug whose plan carries no complete `## Reproduction` is demotion-eligible — the same flag also arms the copy skips, so it withholds a merge AND removes verification, which is why it ships disarmed). Nothing here can WIDEN autonomy — post-merge review / tier-1 expansion stays out until the fleet-wide rate has weeks of data) |
| 3 | Ephemeral staging with synthetic seed data | NOT STARTED | app-side; investigation tickets per board |
| 4 | CI for the harness repo | SHIPPED in this PR (.github/workflows/harness-ci.yml) | this repo |
| 5 | Auto-apply allowlisted migrations post-deploy | SHIPPED (PR #8; hub cron 9,24,39,54; boot-smoked — first real apply is the live test) | harness (bin/migration-autopilot.sh: classifier-passed SQL + deploy-serving check + internal apply endpoints; flagged SQL still pages) |
| 6 | Intent ledger pattern in the apps | TICKETS FILED per board | app-side |
| 7 | Incident-to-rule mining lane | SHIPPED (PR #7; Mondays 05:30Z; dry-run inventoried 8 real incidents) | harness (weekly bin/rule-miner.sh drafting build-discipline additions as a PR) |
| 8 | Diagnostic doctrine: caller's-own-credentials first | SHIPPED in this PR (alerts-medic.sh + alert-triage.sh prompts) | this repo |
| 9 | GitHub App identity: short-lived installation tokens + webhook relay | NOT STARTED | harness-wide (replaces long-lived PATs; App webhooks -> relay -> instant sweep/train/reconcile triggers; fixes the 403-scope class and the commit-author block class). From the Riker review, 2026-08-20 |
| 10 | Structural anomaly gates on build records | NOT STARTED | harness (RESULT anomalies as structured severity entries; sweep/watchers refuse on unacknowledged warnings, explicit acknowledge step with resolution — the stale-note starvation, formalized). From the Riker review |

Sequencing: 4+8 first (this PR), then 5 and 7 (mechanical, high leverage), then
2 (needs 14d of reopen baseline, collecting since 2026-08-19), then 1 (largest
harness build), 3 and 6 ride the app boards at their own pace.

One-shot analyses (not workstreams): determinism audit of our own pipeline
(Riker's pivot-audit method — which LLM stage decisions are ~deterministic
across runs and can demote to code/cheaper models). Scheduled post-project-5-launch.

Definition of done for the program: a change can go ticket → plan → build →
review(×N by risk) → merge → deploy → OBSERVED WORKING IN PROD, with autonomy
scope set by measured outcomes, and no human in the loop except where the
measured trust says there must be one.
