# Closed-issue hygiene (a shipped ticket stops offering itself; split children inherit their parent's labels)

**What it is:** `ai-build` is the handoff. Every selector in this fleet reads
it — the triage sweep, `bin/preplan-candidates.sh`, `bin/unblocked-children.sh`,
the READY-QUEUE tick, `bin/fly-pool.sh` — and until BH-637 nothing took the
label off when a merge closed the issue. So the label outlived the work and kept
offering it, and each re-offer was a full build on a pool machine spent
rebuilding something already shipped.

BH-637 fixes it from both ends, because either alone still lies:

1. **The skip at the funnel.** `bin/run-build.sh` reads the issue's LIVE state
   before it enqueues anything and refuses a closed one. This half is what
   covers an issue a HUMAN closed by hand — no merge path ran, so no strip ran.
2. **The strip on close.** All four harness paths that close an issue after a
   merge go through one helper, which takes `ai-build` off as it closes.
3. **Children inherit.** `bin/run-decompose.sh` files split children with the
   parent's labels from the harness's own vocabulary, not the literal
   `--label ai-build` it used before. A parent carrying `ai-build,hotfix` used
   to produce ordinary children that every hotfix-selecting lane skipped in
   silence.

**How an operator reaches it:** there is no UI and no command to run by hand.

| behaviour | where it lives | when it acts |
|---|---|---|
| refuse a closed issue | `bin/run-build.sh` `# >>> closed issue skip` block, calling `issue_is_closed` in `bin/lib/issue-state-lib.sh` | every entry into `bin/run-build.sh` — the triage launch line, `bin/up10-lane.sh`, `bin/unblocked-children.sh`, the READY-QUEUE tick, `bin/blocked-resolver.sh` rebuilds, and `fly/builder-runner.sh` on a pool machine (`BUILDER_EXEC=1`) |
| strip on a tier-1 merge | `bin/run-build.sh` `CLOSE_ISSUE_AFTER_MERGE` | inside the gated tier-1 merge step |
| strip on a conductor merge | `mc_settle_merged` in `bin/lib/mc/settle.sh` | `bin/merge-conductor.sh` (`cron/hub.cron`) |
| strip on a tier-2 sweep merge | `bin/merge-sweep.sh` `# >>> issue close after merge` | `bin/merge-sweep.sh` (`cron/hub.cron`) |
| strip on a batch train landing | `reconcile_creating` in `bin/batch-resolve.sh` | the batch train settle |
| children inherit labels | `bin/run-decompose.sh`, the block above `CHILDREN_DIR=` | every size-gate split |
| a closed-issue refusal must not halt the pool | `bin/pipeline-health.sh` `# >>> pool refusal halt` | `cron/hub.cron`, \*/10 |

**How to drive it (the fixture suites, no network):**

```
HARNESS_TEST_SANDBOX=1 bash tests/issue-state-lib.bh-637-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/run-build-skip-closed.bh-637-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/issue-state-lib.bh-1424-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/run-decompose-labels.bh-637-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/hotfix-seen-standalone.bh-637-test.sh
HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-skip-closed.bh-637-test.sh
```

The first two and the last extract the real marker blocks from the real scripts
and execute them; the decomposer suite drives `bin/run-decompose.sh` in its
dry-run mode; the selector suite drives `bin/hotfix-seen.sh`.

**What to look for on a live box:**

- `logs/<project>.log` and the build record's `pipeline.log`:
  `SKIP_CLOSED #<n> — issue is CLOSED on <repo>`, and the record's `RESULT`
  starting `BUILD_REFUSED SKIP_CLOSED #<n>`.
- `logs/merge-conductor.log`, `logs/merge-sweep.log`, `logs/batch-resolve.log`
  and a tier-1 build's `pipeline.log`: `closed issue #<n> … (ai-build: <word>)`.
  The word is one of `stripped`, `strip-noop` (the issue did not carry it),
  `kept-split-child`, `strip-off` (the kill switch), `strip-skipped-unreadable`
  (the read-back failed; the close stands), `strip-failed` (the edit was
  refused; the close stands), `strip-unavailable` (an old tree with no lib). A
  failed comment appends `,comment-failed`.
- a decomposition's `pipeline.log`:
  `child <n> labels: ai-build,hotfix (inherited from parent #<n>: hotfix)`.
- `gh issue view <a freshly merged issue> -R <repo> --json labels` shows no
  `ai-build` after the next conductor settle.

**Selectors:** not applicable — no rendered screen. The observable surfaces are
the log lines above, the `RESULT` file, and the three rcs of `issue_is_closed`:
`0` = CLOSED (refuse), `1` = OPEN or switched off, `2` = UNKNOWN (build as
today). `issue_state` has only `0` and `2` — it either knows or it does not.

**Fail-open is the rule, in both directions.** A REST call that failed — even one
that printed a payload and then exited nonzero, which is what a rate limit looks
like — is UNKNOWN, and UNKNOWN builds. Failing closed on a dead token would
refuse every build in the fleet silently. On the strip side the order is the
design: the label comes off only after `gh issue close` returned 0, so
"unlabelled but still open" — an issue no watcher can see and no merge has
shipped — cannot be produced here.

**The split-child exemption.** `bin/decompose-parent-close.sh` finds a split's
children with `--label ai-build --state all` and treats a child it cannot see as
"an unknown, and an unknown is not a closure". Stripping children would leave
every split master open for ever, so an issue whose body has a line matching
`^Part of #<n>` — written by `bin/run-decompose.sh` and by nothing else — keeps
the label on close and logs `kept-split-child`. Prose about being "part of the
onboarding plan" is not the exemption.

**Accepted degrade.** `bin/preplan-candidates.sh:261,295` reads blockers off the
labelled issue list and treats one missing from it as not-closed unless it is
`claimed`/`midbuild`. After a strip, a child of a stripped non-split blocker
loses its `child` pre-plan class and is planned by its own build instead.
Pre-planning is an optimisation and the launch path is
`bin/unblocked-children.sh`, which fetches a missing blocker by number — so this
costs a pre-plan, never a launch. `bin/wake-loop.sh:343` and
`bin/triage-gate.sh:92` read `--state all` lists; an issue LEAVING such a list is
itself a change that runs the tick.

**Knobs** (`env/global.env`, read by file rather than sourced, each with a
`flags/` kill file — see [settings-knobs.md](settings-knobs.md)):

| knob | default | off-state |
|---|---|---|
| `SKIP_CLOSED` / `flags/skip-closed-off` | on | every build enqueues as it did before BH-637 |
| `CLOSE_STRIP_AI_BUILD` / `flags/close-strip-ai-build-off` | on | issues close as before, label left on |
| `DECOMPOSE_INHERIT_LABELS` | empty | only `ai-build` and the hotfix label are inherited |

**Preconditions / seed needs:** none. No new env var is required in any
environment — all three knobs have a documented default and the off-state is
this repo's pre-BH-637 behaviour. `gh` must be on PATH for the state read; with
no `gh` the answer is UNKNOWN and the build proceeds.

**Manual-only / not automatable:** the live-box confirmation. The suites prove
the logic against a stubbed `gh`; that a real GitHub issue loses its label after
a real merge is a one-line check on a box after the deploy
(`gh api repos/<owner>/<repo>/issues/<n>` and inspect the `labels` array), and it is not something a fixture can claim.

**Metered-call cost:** +1 `gh api repos/<owner>/<repo>/issues/<n>` GET per build entry on a
GitHub-Issues project; +1 `gh api repos/<owner>/<repo>/issues/<n>` GET and at most +1
`gh api repos/<owner>/<repo>/issues/<n>/labels/ai-build` DELETE per merge close; 0-1
`gh api repos/<owner>/<repo>/issues/<n>` GET per decomposition (0 in the common path,
where `ticket-meta.json` already has them). Every call is idempotent and bounded per
event, so no dedup ledger is needed.

## A merge that only sliced the issue stays open (BH-2477)

Every merge close-out that has the PR url in hand asks
`issue_close_guard` (`bin/lib/issue-state-lib.sh`) first. It answers one word:
`close`, `slice:plan` (the build's `plan.md` has a line starting
`SLICE: C<k> of #<n>` for this issue, which the planner writes on a one-slice
plan since BH-2508, or the older `The build for THIS ticket is C<k>`),
`slice:no-keyword` (the PR body has no
`Closes`/`Fixes`/`Resolves` for this issue), `slice:open-children:#a,#b` (open
issues cross-referencing it whose body has a `Part of #n` or
`Child **C<k>** of #n` line), or `unknown:<what>`.

- A slice with an open child gets one comment starting `Slice delivered: #<pr>; children own the
  rest.` and stays open (BH-4662: see the next bullet for a slice with none). THEN `ai-build` comes off it (BH-2508), through
  `issue_strip_ai_build`, the same rule the close path uses: the `Part of #`
  split-child exemption and the `CLOSE_STRIP_AI_BUILD` switch apply. The
  helpers print `kept-slice:<why>+<strip word>` (`+stripped`, `+strip-noop`,
  `+kept-split-child`, `+strip-off`, `+strip-skipped-unreadable`,
  `+strip-failed`), rc 0, and the caller logs
  `left issue #<n> open, slice delivered (…)`. The conductor and sweep
  (`mc_close_shipped`) strip only after the comment posted; a refused comment
  is `comment-deferred` rc 1 with the label untouched, so a master never loses
  its label without the note that says why.
- `slice:plan` and `slice:no-keyword` have not seen a child, so both
  close-outs read the open children first (BH-4662, `_issue_open_children`,
  the same read and filter the guard uses for `slice:open-children`). Three
  outcomes. A child: the bullet above, word unchanged. None: the comment's
  first line is `Slice delivered: #<pr>. No child issue carries the rest yet,
  so this issue stays open and keeps ai-build.`, the label is never stripped
  (the rest is re-offered), one warn alert goes through `bin/lane-alert.sh
  --severity warn --id slice-no-children:<slug>#<n>:<pr>`, and the word is
  `kept-slice:no-children+label-kept`, rc 0. The comment and the alert are
  both paid once per record through the marker below. A refused comment is
  `,comment-failed` with the alert still raised in `issue_slice_settle`
  (nothing retries an rc 0 there), and `comment-deferred` rc 1 with no alert
  yet in `mc_close_shipped` (it retries next tick). Unreadable (a failed or
  unparseable page, or still full at the cap): nothing written,
  `close-deferred:children-read`, rc 1, the caller's usual deferral;
  `bin/hotfix-after-deploy.sh` drops that rc, so it writes one
  `HOTFIX CLOSE-OUT OWED` line naming it.
- A plan's `SLICE: C<k> of #N` line also makes the PR body say `Part of #N`
  instead of `Closes #N` (BH-4662, `_prepr_parents` in
  `bin/lib/prepr-gate.sh`), so GitHub's keyword close cannot shut the master
  at merge. Matched at line start only, in the guard's shape. Known gap: the
  older sentence form names no issue, so its PR body keeps `Closes`; the guard
  still answers `slice:plan` for it at merge.
- The slice comment is paid once per build record. A slice stays open, so
  the merge-time close-out and then `bin/hotfix-after-deploy.sh` both act on
  it; `issue_slice_settle` and `mc_close_shipped` skip the comment when
  `<record>/issue-commented` exists and write it after one posts. The strip
  still runs on the later lane and answers `+strip-noop`.
- An unknown writes nothing. The helper prints `close-deferred:<what>`, rc 1,
  and the caller takes its usual could-not-close branch.
- Knob: `ISSUE_CLOSE_GUARD_PAGES` (env or `env/global.env`, default 5) caps the
  timeline read at 100 events per page. A timeline still full at the cap is
  `unknown:timeline-capped`, never "no children".
- Wired at `bin/lib/mc/settle.sh` (conductor), both `bin/merge-sweep.sh` close
  sites, `bin/batch-resolve.sh` and `bin/lib/rb/pr.sh` (tier-1). A tree
  without this lib (`MC_ICS_SHIM=1`) closes as before.
- `bin/hotfix-after-deploy.sh` asks the guard before its "Deployed … live"
  close (BH-2508). A slice gets the slice comment and the strip instead, and a
  `+strip-failed` or `,comment-failed` word is one `HOTFIX CLOSE-OUT OWED` line
  on ALERTS. An `unknown:*`, or no lib loaded (`unknown:no-guard`), closes
  nothing and writes one `HOTFIX CLOSE-OUT OWED … close guard could not
  decide` line, because that script's caller drops its rc.
- GitHub's own keyword close at merge is untouched. A `Closes #n` PR still
  closes #n when it merges, whatever the guard says. The comment says what the
  close-out did, not what state the issue ended in.
- Cost: +1 pull GET and 1 to 5 timeline GETs per close-out, plus on a slice
  1 issue GET and at most 1 label DELETE; `slice:plan` and `slice:no-keyword`
  add their own 1 to 5 timeline GETs (BH-4662).

Live check: after a `Refs`-only PR merges on a master with an open child,
`grep 'left issue #' /root/harness/logs/merge-conductor.log` shows the slice
line ending `+stripped)` and the issue thread has one `Slice delivered`
comment; `gh api repos/<owner>/<repo>/issues/<master>` shows no `ai-build`.
With no open child the line ends `no-children+label-kept)`, the label stays,
and ALERTS has one `slice-closeout` warn line.
Suites: `tests/issue-close-guard.bh-2477-test.sh`,
`tests/merge-settle-slice.bh-2477-test.sh`,
`tests/issue-close-slice-strip.bh-2508-test.sh`,
`tests/hotfix-close-guard.bh-2508-test.sh`,
`tests/slice-closeout.bh-4662-test.sh`.
