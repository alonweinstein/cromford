# Onboarding a repo

Adding a repo is one setting and one command. Getting good builds out of it
takes a little more: Cromford needs to know how your repo installs, tests and
builds.

## Add it to your settings

List the repo in `SELFHOST_PROJECTS` in your `selfhost.conf`, as
`name=owner/repo`. The name is lowercase letters, digits and hyphens. Separate
several with spaces. Run the dry-run again: with `SELFHOST_POOL=fly`, each
project gets its own build app and volume in the plan.

## Enroll it on the hub

```bash
bin/load-project.sh <owner/repo> --project <name> --box <box>
```

This needs a running hub. It adds the project to `fleet.conf`, renders its
prompt, commits and pushes to your fork, creates the `ai-build` label on the
repo, and sets up the box. Always pass `--box`. The script's header explains
its other flags.

To add a machine to the fleet, see [Adding a box](ADDING-A-BOX.md).

Enrolling builds nothing by itself. Cromford only acts on issues labeled
`ai-build`.

Per-project secrets and settings go in the project's own env file under
`/etc/harness/env/`. `env-templates/project.env.example` lists them, with a
line on what each is for.

## What the repo needs

- **A `CLAUDE.md` at the root with a Verification Contract.** Add a
  `## Verification Contract` heading. The first fenced block under it is the
  command Cromford runs to check a build, for example
  `npm ci && npm run lint && npm test && npm run build`. Keep deploys out of it.
  This repo's own [CLAUDE.md](../CLAUDE.md#verification-contract) is a worked
  example. An `AGENTS.md` is read as context, but the verify command only comes
  from `CLAUDE.md`.
- **CI on pull requests.** Cromford's merge gate reads your checks, so a repo
  with no CI has nothing to gate on.
- **The `ai-build` label.** The enroll step creates it.
- **Optional: a CodeGraph index.** A repo with a `.codegraph/` directory gets a
  code graph pass before each plan. Without one, that pass is skipped.

## Study it first

```bash
bin/onboard-study.sh <repo-dir>
```

This reads a checkout and reports the install, test, build, lint and deploy
commands it found, a draft Verification Contract, a readiness grade, and any
deploy config. It calls no model and runs none of your repo's code. Its one
write is the `.codegraph/` index inside the checkout. Add `--json` for a
machine-readable report.

## Your first ticket

Start small: a copy change or a small fix you can check in a minute. Open it
with the `ai-build` label and say how you'll know it's right. If triage asks a
question, answer it in the thread. When the PR opens, read the plan and the
review before the code.
