# Post-merge QA deploy age-out (a merge the gate never saw served stops being re-offered)

**What it is:** the end of `bin/postmerge-qa.sh`'s "come back next tick". The
stage's deploy gate refuses to drive production until prod is serving the merge
sha, and before BH-1022 that refusal had no other answer: a merge the gate never
saw served was re-offered on every wake forever — 30,698 `prod not yet serving sha
— requeued` lines for one project in three days. No model spend (the agent lane
sits behind the gate), but the feed never drained and nobody was ever told that a
merge had not reached production.

Now, `POSTMERGE_QA_DEPLOY_MAX_HOURS` after the PR's `mergedAt` (default 12, `0` =
off), a build the gate can READ and says is not served is written to
`state/postmerge-qa-done.txt` with the terminal outcome
`NOT_COVERED_DEPLOY_TIMEOUT`, alerted once, and never offered again. The word is
`NOT_COVERED_…` on purpose: nothing was driven, so the stage has observed nothing
about the app and is not making a defect claim — same shape as the existing
`NOT_COVERED_NO_QA_ENV`.

**How an operator reaches it:** no UI. `bin/postmerge-qa.sh <project>` runs from
the four per-project cron lines (`cron/{project-4,project-1,project-3,project-2}.cron`) and
from `bin/wake-loop.sh`'s `deploy` wakes. One knob, in a project's
`env/<project>.env` (documented in `env-templates/project.env.example` next to
the other `POSTMERGE_QA_*` settings):

- `POSTMERGE_QA_DEPLOY_MAX_HOURS` — hours after merge before an undeployed build
  is written `NOT_COVERED_DEPLOY_TIMEOUT` plus one alert. Default 12. `0` = never
  age out, which is byte-for-byte the pre-BH-1022 behaviour. A value that is not
  a whole number is said out loud in `logs/postmerge-qa.log` and the default is
  used, never "no limit".

The clock anchor is the PR's own `mergedAt`, read in the same `gh pr view` call
that reads the merge sha. Prod cannot serve a sha before it is merged, so "N
hours since merge and still not serving" is the audit's "N hours of not yet
serving" with no new state file to keep.

**How to drive it:**

| what | how |
|---|---|
| past the limit: one `NOT_COVERED_DEPLOY_TIMEOUT` row, one ALERTS line, one `fleet_alert` beat, nothing driven, no agent spend (BH-1022) | `HARNESS_TEST_SANDBOX=1 bash tests/postmerge-qa.bh-1022-test.sh`, case A |
| the second tick is silent — the done row is the dedup | same suite, case B |
| under the limit: the requeue line unchanged, no done row, no alert | same suite, case C |
| old but actually served: driven exactly as before, verdict is its QA verdict | same suite, case D |
| the knob: `0` = off, a non-number says so and uses 12 | same suite, cases E and F |
| absent or unparseable `mergedAt` never ages anything out | same suite, case G |
| the "cannot determine" arm (rc 2) requeues whatever the age — never terminal, never an alert | same suite, case H |
| a timed-out build does not consume the `POSTMERGE_QA_MAX` slot | same suite, case I |
| the prescribed recovery (drop the done row, re-run for that build) really drives it | same suite, case J |
| serving = the merge sha OR any DESCENDANT of it; the exact sha and a non-JSON body still pass | same suite, case L (against a real 3-commit clone) |
| an unrelated live sha (a pinned or rolled-back domain) still ages out | same suite, case M |
| a live sha the local clone has never seen is "cannot tell", never terminal | same suite, case N |
| the version probe carries `VERSION_AUTH` | same suite, case O |
| a null `mergeCommit.oid` is skipped, never read as a sha | same suite, case P |
| the rest of the stage (deploy gate first, BLOCKED ≠ FAIL, fail-open, one build per tick) | `HARNESS_TEST_SANDBOX=1 bash tests/postmerge-qa-test.sh`, `…/postmerge-qa-personas-test.sh` |

**Files it writes on a live box:**

- `state/postmerge-qa-done.txt` — one appended row,
  `<stamp> <build-key> <sha8> NOT_COVERED_DEPLOY_TIMEOUT`. This row is what stops
  the build being offered again: `already_done` skips it before the gate on every
  later tick.
- `logs/ALERTS.log` — one line per timed-out build, naming the sha, the PR, how
  long after the merge, and the two things needed to settle it (a deploy of that
  sha, or `VERSION_URL` for a project whose prod has no version endpoint) plus
  the exact re-run command.
- `logs/postmerge-qa.log` — the run's own line, `… — NOT_COVERED_DEPLOY_TIMEOUT,
  not re-offered`.
- one `fleet_alert` beat, akey `prodqa-deploy:<project>:<sha>`.

**What must never regress:**

- **Absent is not old.** No `mergedAt`, or one `date -d` cannot parse, means the
  age is UNKNOWN: the build requeues exactly as before. Nothing may reach a
  terminal state on data we could not read.
- **The alert is written BEFORE the done row.** A crash between the two can
  duplicate an alert, which is noise; the other order could leave a build
  silently terminal, which is the failure this ticket exists to remove.
- **The deployed path is untouched.** The age check lives inside the gate's
  non-pass branch only, so a build that IS being served is driven whatever its
  age.
- **The two under-limit `say` strings stay byte-identical** (`prod not yet
  serving … — requeued`, `cannot determine whether prod serves … — requeued`);
  `tests/postmerge-qa-test.sh` greps them.
- **It adds no spend.** The age-out `continue`s before the drive, before the
  `prodqa` agent lane, and before `RAN` increments — so a timed-out build also
  does not eat the `POSTMERGE_QA_MAX` slot a deployed build needs.
- **The outcome word stays `NOT_COVERED_…`.** It says only what was observed —
  not served N hours after merge — and never "never deployed" as a fact.
- **A superseded merge is a served merge.** A `VERSION_URL` reports the one sha
  production is serving NOW — the newest merge — so the gate asks whether that
  sha IS this merge or DESCENDS from it (`git merge-base --is-ancestor` against
  the local clone, the rule `bin/deploy-train.sh:135-141` already uses). Strict
  equality here is what made the audited feed: the most-requeued project-5 shas
  are all ancestors of the sha prod serves, so an age-out on top of it would
  have declared live merges not covered and fired `fleet_alert` beats that
  `bin/alert-triage.sh` pays an `agent-call` per family to triage.
- **Unknown is not "no".** If the clone has never seen the merge sha or the live
  sha (one best-effort `git fetch` per run, then give up), the answer is rc 2 —
  cannot tell — which requeues and never ages out.
- **Only rc 1 ages out.** rc 2 is an unreadable SIGNAL: `curl` or `gh api`
  failed on this box. Ageing it out would turn one box-wide outage into a
  terminal row for every merged build of every project in a single tick.
- **The `-q` null default stays `"-"`, not `""`.** `read` collapses runs of
  separators, so an empty middle column shifts `mergedAt` into the sha variable
  and production gets probed for a date.

**Manual-only / not automatable:** the real settle. When the alert fires, the
answer is a deploy (or a fix to the project's deploy lane), then removing that
build's row from `state/postmerge-qa-done.txt` and re-running
`bin/postmerge-qa.sh <project> <build-dir>` by hand — the stage will not re-offer
a build it has already called terminal, and nothing here re-deploys anything.
