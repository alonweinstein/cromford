# Changelog notes

This is the README as it stood before it became an entry point, moved here
verbatim on 2026-09-11. It is a running set of dated notes about what landed
and why — the kind of thing that is useful to search and wrong to greet a
newcomer with.

Nothing below has been edited. Where it contradicts [docs/OPERATOR-SETUP.md](OPERATOR-SETUP.md),
the setup guide is newer and wins.

---

# cromford

Autonomous watcher/build fleet for product-board-driven apps. One box per project
("machine-per-OS"): each box clones this repo to /root/harness, provisions ONLY its
project's secrets under env/ (never in git), and runs bin/bootstrap-machine.sh <project>.
Hub box additionally runs the orchestrator and cross-repo guards. See MULTI-MACHINE-PLAN.md.

- **New operator? Start at [docs/OPERATOR-SETUP.md](docs/OPERATOR-SETUP.md)** — join the
  existing fleet or stand up your own (own console + Telegram bot + your projects), on
  Orgo or any Debian VM.
- Project registry: [fleet.conf](fleet.conf) — repo slug, prod URL, board API prefix,
  cron offset per project (read by bin/fleet-conf.sh; add a row to add a project).
- Secrets are never in git: [env-templates/](env-templates/) documents every variable.
- Repeated procedures are **repo-managed skills**, not prompt blobs: [skills/](skills/)
  holds one `SKILL.md` per competency (`migration-judged-apply`, `qa-prod-drive`,
  `console-deploy`, plus the local-planning `harness` skill). `bin/sync-skills.sh`
  deploys them to `~/.claude/skills/` on every box as part of `bin/harness-sync.sh`,
  so a session loads a tested procedure ON DEMAND instead of carrying it in every
  prompt. Shape is asserted by `tests/skills-sync-test.sh`; no skill file may
  contain a secret value.
- Per-project triage behavior: `prompts/<project>.md` ([template](prompts/TEMPLATE.md)).
- Console source: private repo `example-org/cromford-console`.
- **Small projects** (2026-08-18): any repo can join the fleet in one command —
  `bin/load-project.sh <owner/repo>` registers it (GitHub-Issues board, `ai-build`
  label = the handoff), renders its watcher prompt from `prompts/TEMPLATE-GH.md`,
  and bootstraps it onto the shared box `box-small`. Ownership routing
  is fleet.conf's box column via `bin/box-for.sh` ("local" = the hub). Plan
  locally, execute remotely: the `/harness` skill (skills/harness/SKILL.md) files
  an approved local plan as sequenced ai-build issues the pipeline builds.

Pipeline (2026-07-27, E2E stage added 2026-08-29): PLAN (acceptance tests + QA screens)
-> EXECUTE (red->green TDD per the repo's CLAUDE.md Verification Contract) -> semgrep ->
E2E SMOKE (bin/e2e-smoke.sh: chromium loads the branch's own Vercel PREVIEW, read-only,
asserting no 5xx and no console errors; verdict rides into the review prompt, fail-open
to a recorded SKIP when no preview exists) -> adversarial REVIEW (test honesty + security
triage) -> PR -> preview QA (playwright on the Vercel preview, fail-open) -> tier-1
auto-merge -> deploy-verify (prod deployment status + smoke) -> post-merge prod QA. A recorded E2E: FAIL blocks
both merge paths: it demotes tier-1 out of auto-merge, and bin/merge-sweep.sh refuses it.
Every build PR carries its own spec (2026-08-29): after EXECUTE, run-build.sh commits the plan
it built from to `.harness/specs/<ticket>/plan.md` (plus `requirements.md` when the plan stage
wrote one) in the same commit stream, so the PR diff shows the spec beside the code and the
spec outlives the build box. One fixed path per ticket, rewritten in place — fix rounds and
resumes update it, never duplicate it. Spec text is not code: the review prompt, the tier size
heuristic and merge-sweep's added-line iron-law scan all skip `.harness/specs/**`.
Boxes self-sync bin/+prompts/+catalog/ daily via update-runners.sh from this repo;
healthcheck.sh beats twice daily per box.

Runner CLIs are updated daily too (2026-09-06, the operator: "make sure codex and Claude get
updated daily in general"). `update-runners.sh` calls `bin/cli-update.sh` right after
the harness sync: it finds every install of claude and codex on the box — a native
launcher (`~/.local/bin/claude` → `claude install latest`) and/or an npm global package
(`npm install -g <pkg>@latest`, retried once with `--force` on EEXIST/ENOTEMPTY) —
then repoints stale symlinks in `/usr/local/bin` and `/usr/bin` at the newest install
(old link backed up beside it) so cron's PATH and a login PATH resolve the same binary.
Before/after versions land in `logs/cli-versions.csv` and in the harness-jobs DB
(`cli_versions` history + `box_status` current state, via `jobs-client.sh
metric-cli-version`). It exits non-zero only when a CLI ended up WORSE or MISSING,
which update-runners turns into an ALERTS line. The hub's `bin/cli-version-check.sh`
(05:40Z, `cron/hub.cron`) then ssh-probes every fleet.conf box, reads both PATH views,
and compares them to the hub and to the per-model floors in
`catalog/cli-min-versions.json` (claude-fable-5-1 → claude-code ≥ 2.1.251; the model
bump that stranded project-9 on 2.1.250): ONE ALERTS line per box that is behind,
below a floor for a model its env names, missing a CLI, split between its PATHs, or
unreachable; the fleet table goes to `state/cli-versions-fleet.tsv` and the DB.
Detection only — the alert names `cli-update.sh` on that box as the fix. Tests:
`tests/cli-update-test.sh`, `tests/cli-version-check-test.sh`.

Post-merge production QA (2026-08-29, SDLC item 3b): everything before the merge
observes a PREVIEW, and `deploy-verify.sh` only asks whether prod answers a status
code — so the last thing anyone had actually SEEN of a feature was a branch build.
`bin/postmerge-qa.sh <project>` (cron, one build per tick) closes that: it waits for
production to serve the merge sha (the deploy gate — `VERSION_URL` where a project
has one, else a successful GitHub production deployment; "not yet" requeues and
drives nothing), then drives the shipped screens as a real signed-in QA user at
1280px and 375px via `bin/qa-drive.mjs`, then spends the `prodqa` agent lane on the
flows and judgement calls — and only if the browser really landed a session. The
observation lands in the build's `qa-prod.md`, in `logs/findings.log` as
`lens=prodqa`, and as a comment on the merged PR; a FAIL also writes `ALERTS.log`
and pages Telegram. It runs entirely after the merge, so it can never block one;
`flags/postmerge-qa-disabled` is the kill switch.

Privileged QA accounts are BANNED at rest in Clerk on purpose, and Clerk mints a
sign-in ticket for a banned user anyway — the bounce to `/sign-in` happens later, in
the browser. Drives were screenshotting the sign-in page and reporting coverage.
`bin/qa-unbanned.sh <project> <role> -- <cmd…>` is now the only sanctioned way
through: it lifts the ban, runs the drive, and restores the ban from an EXIT trap
(three retries, then an ALERTS line, a Telegram beat, and exit 90 whatever the drive
returned). A landing on `/sign-in` is a hard FAIL everywhere — `qa-signin-check.mjs`
exits non-zero on it now, where it used to print `FAIL:` and exit 0.

Outcomes close the loop (2026-08-29, SDLC item 7): everything else in the pipeline
measures OUTPUT — builds counted, dollars priced, review findings logged before a
merge. `bin/outcome-metrics.sh` (hub, Mondays 05:20Z) measures whether the merge
HELD. It takes the merged-PR list and each PR's project/ticket/merge-sha from the
harness-jobs ledger (`kind=merge` rows + `job_artifacts` via `GET /api/verdict`),
never by re-scraping GitHub, and asks three checkable questions: was it **reverted**
on main, was its ticket **reopened** on the board (`logs/reopens.csv`), did its merge
commit turn main **red**. Each finding lands as a `lens=outcome` row in
`logs/findings.log` — the same format `bin/findings-log.sh` writes, so
`bin/rule-miner.sh` counts outcome families against PROMOTE_MIN alongside every
other finding — plus a flat row in `logs/outcome-metrics.csv`
(`date,repo,pr,outcome,evidence,repairs`; `repairs` since SDLC item 3, the count
the build itself recorded of how many times it was sent back, carried from the
verdict row so a revert can be read against how much repairing it took). The miner invokes it before reading the log, so
the feed cannot fill after its consumer ran. It is DETECTION ONLY: nothing in the
lane reverts, reopens, closes or merges anything, and `tests/outcome-metrics-test.sh`
asserts that against a recording `gh` stub.

Metrics live in the DB, not just on the hub's disk (2026-08-29, the operator: "move things
to the database instead of files"). Four series now write their CSV **and** push a
row to harness-jobs: `burn_days` (`bin/orchestrator-burn.sh`, the orchestrator's
daily API-equivalent burn), `pr_costs` (`bin/cost-rollup.sh`'s per-PR sweep),
`extra_usage_snapshots` (`bin/extra-usage-track.sh`'s hourly credits-vs-cash poll)
and `outcome_metrics` (the rows above). Every push is fail-open through
`bin/jobs-client.sh` and happens AFTER the file write, so a worker outage costs a
row and never a measurement; the CSVs stay exactly what today's readers read. Each
table is upserted on the measurement's natural key (the UTC day, the PR url, the
`(box, ts)` poll, the `(repo, pr, outcome)` triple), so the producers' re-runs are
no-ops instead of duplicates. `POST /api/metrics/{burn,pr-costs,extra-usage,outcomes}`,
same bearer as everything else; console screens for them are a follow-up. Pure logs
(`ALERTS.log`, per-project logs) and file-is-the-flag flags stay files.

Outcomes now STEER, not just report (2026-08-29, SDLC item 2). Everything else
in the pipeline steers on ACTIVITY — the sweep merges what was approved, the
miner counts what reviewers said, the rollup prices what ran. `bin/review-
tighten.sh` (hub, daily 05:45Z) turns the outcome findings into ONE mechanical
decision: a repo whose **trailing-window revert/reopen rate** crosses its
threshold stops auto-merging and parks its harness PRs for the operator's judged merge
until the rate comes back down. The denominator is the PRs the fleet actually
MERGED in the window (`ledgers` kind=merge), the numerator is how many of THOSE
carry a `reverted`/`reopened` finding — DISTINCT PRs, so a PR that was both is
one merge that did not hold. `merged_then_red` is counted and reported but is
not in the rate: a red main is often the next commit's fault. Thresholds are DB
rows (`review_gate_thresholds`, scope `*` or a repo slug) with a documented code
fallback of 14 days / 5 merges / tighten at 20% / clear at 10% — two different
numbers, so a gate does not flap as one revert ages out of the window, and a
`min_merges` floor so one revert on a quiet repo cannot park its whole backlog.

**It only ever tightens.** Nothing in the lane merges, loosens a gate, widens a
budget or grants autonomy; a repo at a 0% rate gets today's behaviour and
nothing better. It writes exactly two things — the switch (a `pause_flags` row
`review-tighten-<repo>`, which write-throughs to a file so a repo stays parked
through a worker outage, read by `bin/merge-sweep.sh` AND `bin/merge-queue.sh`)
and its own measurement row (`review_gate`, written every run including the runs
that change nothing) — plus ONE ALERTS line per transition naming the repo, the
evidence and how to release it by hand. It never acts blind: no merge ledger
means no denominator, so the run logs why and leaves every existing flag exactly
as it was. A flag is cleared on evidence the rate came down, never on the
absence of evidence. `tests/review-tighten-test.sh` drives all of that against a
stubbed worker, including the assertion that the sweep skips a parked repo's PR
without ledgering it and still merges the same PR when the flag is gone.

Mission Control shows the loop on `/outcomes` (console-ui): cost-per-PR and
revert/reopen rate per repo, the weekly burn trend, every finding joined to what
its PR cost and to the job that built it, and the gate's own numbers beside each
repo. One Pages Function (`functions/api/outcomes/`) fans out to the five tables
in a single call on the same delegated dash-cookie session as coord/ideas, and
it is GET-only: a dashboard that could flip its own gate would be a second,
unreviewed merge path. It never recomputes the park decision — that rule lives
in one script.

Mined rules become ENFORCEMENT (2026-08-29, SDLC item 6): the weekly rule miner
had two lanes and neither one ran on the harness side — prose rules into
`prompts/build-discipline.md` (a model can forget every one) and drafted
guardrails PR'd onto project repos (which bite only after a whole adoption
build). Between 2026-08-19 and 08-29 that second lane promoted zero checks, so a
review-finding family could recur seven times across four projects and still be
re-litigated by a paid model on the eighth. [`checks/`](checks/) is the third
lane: deterministic scripts the harness runs itself. `bin/checks-run.sh`
normalizes a diff to its added lines once (dropping test files,
`scripts/migrations/`, `.harness/specs/` and comment-only lines, exactly as
`bin/merge-sweep.sh` does) and pipes that stream to every `checks/*/check.sh`.
The first three were promoted from families the 2026-08-26 run ruled on:
`client-id-trust` (`fd7bbe69fac5`, 7 recurrences), `sql-command-injection`
(`53e19b60469c`, 5) and `secret-literals` (`4d8b31f48fbd`, 5). Two gates execute
them: `bin/run-build.sh` puts the hits in the review prompt beside the other
mechanical gates, and `bin/merge-sweep.sh` counts them into its added-line
iron-law scan, which **parks** the PR and writes one ALERTS line. It is
DETECTION ONLY — no check has a git write, a `gh` call or an edit path, a hit
costs a human read and never a disabled check, and both wiring points fail OPEN
so a missing runner behaves exactly as before the catalog existed.
`tests/checks-suite-test.sh` proves every check fires on its seeded violation
and stays silent on its clean fixture. The same PR fixed the miner's own PR step
(`tests/rule-miner-pr-step-test.sh`): the 2026-08-26 run drafted rule D33 from 58
incidents and logged only "PR creation FAILED", because it had assembled a
77,148-character body and GitHub refuses anything over 65,536 — with every
step's stderr sent to `/dev/null`, so nothing recorded which step died or why.
The body is now budgeted (rules always ride in full; omitted evidence is named
and counted), each step names itself into one loud ALERTS line carrying what git
or gh actually said, and a re-run adopts an already-open PR instead of
duplicating it.

Machine config is repo-managed too, on the same 05:17Z tick: `rules/CLAUDE.md` renders
to `/root/.claude/CLAUDE.md` on every box (plus `rules/RTK.md` and `rules/settings.json`
beside it, and `cron/<box-id>.cron` to the crontab). Edit the repo file, never the box
copy — the render reverts local edits. Box-specific text goes in
`/root/.claude/CLAUDE.local.md`, which the render appends and never overwrites (the
same escape hatch for settings is `settings.local.json`, which Claude Code merges
natively and the render never touches). `bin/rules-drift-check.sh` (hub, hourly)
ssh-reads every box and writes an ALERTS line if a live file stops matching the repo —
it distinguishes RENDER drift (update-runners never ran, or someone hand-edited the
box) from CHECKOUT drift (harness-sync is behind, so the box renders faithfully from
stale rules). It is read-only: it never heals, deploys, or writes to a box.

AI product team (2026-07-28, v2 org-walking chain): weekly generative stage per box
(run-product.sh, cron Mondays 09:0X UTC staggered). Phases: MAP (cached the operator-editable
company map: departments -> roles -> accountabilities -> processes -> OS coverage;
prompts/product-stages/map.md; cockpit edit round-trips via update_company_map) ->
SIGNALS (evidence harvest tagged dept/role/process) -> IDEATE fan-out (one session
per department, AAA-ladder walk, IDEATE_CONCURRENCY=3) -> SYNTH (cross-dept dedup +
DERISK/UNCLOG/SCALE classification honesty) -> SELECT (bucket-first derisk->unclog->
scale, then impact*confidence/effort) -> draft-proposal.sh (PRD + themed mockup +
playwright shots) -> GATE: beat kind=proposal; the operator approves/revises/kills from the
Product Cockpit (/product) or Telegram. Stage prompts are shared; per-project
prompts/product-<project>.md files are context blocks only.
Approve -> post-proposal.sh creates the [Proposal] ticket (mockup attached + viewer
link + inline previews), flips turn to client; the client's approving comment makes it
BUILDABLE via the normal pipeline (see the [Proposal] section in each triage prompt).
Idea ledger: state/product-<project>.ledger.json (candidate|gate_pending|vetoed|posted|
client_approved|client_rejected|expired|building|shipped). Kill switch:
flags/product-paused-<project>; earned autonomy (skip gate): flags/product-autonomy-
<project>, OFF by default. Commands post_proposal/kill_proposal/revise_proposal flow
console -> poll-commands.sh -> product-cmd.sh on the owning box.
