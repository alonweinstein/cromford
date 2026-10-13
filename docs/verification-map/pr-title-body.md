# The PR title and the `## What` list a build opens

**What it is:** the two strings `bin/run-build.sh` composes at PR-open time — the
title GitHub shows in every list, and the `## What` section at the top of the
body. Both are derived, no model call: the title from the ticket, the What list
from this branch's own commits.

**How an operator reaches it:** it runs inside a build, between the pre-PR push
and `gh_pr_create_ladder`. Three marker blocks hold it, and they are what a
change to this behaviour edits:

- `# >>> pr what list` — the `## What` list (`WHAT_BASE`, `WHAT_MB`, `WHAT_LIST`)
- `# >>> pr title subject` — `PR_SUBJECT`, inside `# >>> pr create ladder`
- `# >>> evidence block` — `PR_BODY_FOR`'s `EB_SUBJECT`, the body's first line

**The rules, in the order they are applied:**

1. **Title** = `<KEY>: <subject>`, where the subject is the first non-empty of:
   the `.title` in `$BUILD/ticket-meta.json`; the newest commit subject that is
   not `spec(<KEY>): the plan this build was executed from`; HEAD's own subject.
   A leading `<KEY>: ` is stripped from the winner so the created title carries
   the key exactly once, and the whole subject is cut at 80 characters.
   The `<KEY>: ` PREFIX is load-bearing for `br_key_from_title`
   (`bin/blocked-resolver.sh`), `bin/dep-verify.sh` and `pr_for()` in
   `bin/decompose-parent-close.sh`: all three read the key at the FRONT of the
   title and ignore the rest, so only the subject after it ever moves.
2. **`## What`** = `git log -12 --format='- %s' "$(git merge-base origin/$BASE HEAD)..HEAD"`,
   minus the spec commit. `origin/$BASE` is resolved the way `SCOPE_BASE` is —
   the LOCAL `$BASE` ref is stale after the pre-PR rebase — and an unresolvable
   merge base falls back to the ref itself rather than to an empty section.
3. **Body line 1** = `Ticket <KEY> — <the same subject the title used>`, falling
   back to HEAD's subject when `PR_SUBJECT` is unset (the path the three suites
   that source the evidence block verbatim depend on).

**Why it is written down:** until BH-1415 the title was `git log -1 --format=%s`,
and the spec artifact stage commits `spec(<KEY>): the plan this build was
executed from` AFTER execute — so HEAD *was* that commit. The 2026-09-22 pool
wave opened 33 PRs (#1376-#1414) all called
`BH-<n>: spec(BH-<n>): the plan this build was executed from`, and their `## What`
lists carried `merge train: …`, `train: #…` and other tickets' commits, because
the list diffed against the stale local `main`.

**Verify it works:**

- `bash tests/run-build-pr-title.bh-1415-test.sh` — drives all three blocks in a
  scratch repo shaped like the incident (a branch rebased onto a moved
  `origin/main`, local `main` left behind), including the real pr-create ladder
  block with a stubbed `gh_pr_create_ladder` whose argv is asserted.
- On a live build: `$BUILD/pr-body.md` on the build box, and the PR itself. The
  title must name the ticket; the What list must hold only this branch's
  subjects. A `still carries a main-train subject` line in `$BUILD/pipeline.log`
  means the base resolution went wrong on that build — the list is not filtered
  by text, so a branch that genuinely made a `train:` commit keeps it and logs.

**The backfill:** `bin/pr-title-backfill.sh` retitles PRs opened BEFORE this
landed. Dry run is the default and prints one `WOULD RETITLE #n: <old> -> <new>`
per PR:

```
bin/pr-title-backfill.sh --all-open example-org/cromford          # reads only
bin/pr-title-backfill.sh --apply --all-open example-org/cromford  # writes
bin/pr-title-backfill.sh --apply example-org/cromford 1516 1513   # named PRs
```

It touches OPEN PRs only, and only titles where the same key appears on both
sides of `: spec(…): `; it reads the issue title BEFORE it writes, and reports
`RETITLED` only when the PATCH's own response body reads the new title back.
rc 1 = at least one PATCH failed; rc 3 = unusable arguments, no `gh`, or an
unreadable PR list (never an empty run). It has no cron lane, no lock and no
state: its own matcher is the idempotency key, because a PR it retitled no
longer matches. `bash tests/pr-title-backfill.bh-1415-test.sh` drives it over a
stubbed `gh`, including every negative.

**Manual-only / not automatable:** the `--apply` half writes to real PRs an
operator may be reading. Run the dry run first and read its lines against
`gh pr list --state open`; nothing in the harness invokes this script.
