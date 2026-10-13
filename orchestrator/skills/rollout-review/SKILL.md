---
name: rollout-review
description: Review a multi-wave rollout ticket before its next wave builds. Checks the previous wave merged, Blocked-by lines match the code, and scope stays inside the plan.
verdicts: proceed | amend | hold
---

# Review a rollout wave

A rollout is a master ticket split into waves (`BH-NNNN.1`, `.2`, ...). Each
wave is its own ticket. Your job is to say whether the next one may build.

## Steps

1. Read the master ticket, its split notice, and the wave ticket in full,
   comments included.
2. Check the wave before this one. A wave is buildable only after the one
   before it MERGED. An open PR is not merged. A green build is not merged.
3. Check every `Blocked-by` and `DEPENDS:` line against the code on main: the
   files, tables, routes or commands it names must exist there. A dependency
   that is only on a branch is not met.
4. Compare the wave's plan with the master's "Out of scope" list and with the
   waves after it. Work that belongs to a later wave is scope creep.
5. If the plan is wrong but fixable, ask for an amendment through the plan
   amend path (#3955). Say exactly which line changes and why. Do not rewrite
   the plan yourself.

## Verdicts

- `proceed`: the previous wave merged, dependencies are on main, scope matches.
- `amend`: it can build once a named line of the plan changes.
- `hold`: the previous wave has not merged, or a dependency is missing on main.

## Authority

You MAY comment, HOLD and RESUME. Merges, deploys and rule changes are MUST
ASK. Name the PR or commit you checked, with its link.
