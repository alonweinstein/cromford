# About this repository

This is the source of the Cromford runtime. The hosted product at
[cromford.dev](https://cromford.dev) runs the same code. Start at
[the README](../README.md). This page covers how the repository is released,
what is in it, and what is not here yet.

## How this repository relates to Cromford

Cromford is built in an internal codebase. Each release lands here as one new
commit on top of the last one, with a message like:

```
Cromford 2026.10.06 (upstream 0123456789ab)
```

The date is the release day. The sha names the internal build the release was
cut from. History here is the list of releases, so forks and clones keep
working across updates.

## What's in it

- The lanes: the scripts under `bin/` that triage, plan, build, review, merge
  and verify, and the cron schedule that runs them.
- The shared libraries under `bin/lib/`.
- `console-ui/`, the Mission Control front end.
- The test suite under `tests/`, and the CI in `.github/workflows/ci.yml`.
- The rules the builds run under: `rules/CLAUDE.md` and
  `prompts/build-discipline.md`.

## Example names

Names of projects, people, machines and accounts in this repository are
examples. They are consistent with each other and mean nothing outside it:

- `project-1` … `project-20` are projects the fleet works on.
- `box-project-4-1` is a machine: the first watcher box for `project-4`.
  `box-hub` is the orchestrator and `box-small` is the box several small
  projects share. The shape matters: the harness derives a box's id, and the
  name of its crontab, by stripping the prefix and any trailing instance number.
- `example-org` is the GitHub organisation, `operator` the account that runs it.
- `TK-142` is a board ticket.
- Addresses in `10.0.0.x`, all-zero uuids, and `team_EXAMPLE…` ids stand in
  for infrastructure ids.

Keep using them in issues and PRs.

## Current gaps, plainly

- **`docs/OPERATOR-SETUP.md` is behind the code.** Read it for the shape, not as
  a checklist. It describes a single watcher box talking to a console. It does
  not cover the job-queue worker that now coordinates the fleet, the Fly
  builder pool, or the multi-vendor runner lanes. What it does describe still
  works.
- **The Mission Control backend is not in this repository yet.** That is the
  console worker: its API, D1 schema and Slack and Telegram bindings. It will
  be published as its own repository. The MCP server is here, in `mcp/` (see
  `docs/MCP.md`), and it talks to a console you run. Until then
  `console-ui/` is the front end alone, and Path B in `docs/OPERATOR-SETUP.md`
  runs everything except the remote control surface.
- **Eval fixtures are not included.** `tests/evals/` is the replay harness that
  grades a prompt change against real past decisions. Capture your own with
  `tests/evals/capture-fixture.py`.
- **Per-project prompts are not included.** `prompts/TEMPLATE.md` and
  `prompts/TEMPLATE-GH.md` ship, and you write your own from them.
- **Anything machine-local** (credentials, logs, run state) was never in git.

To run it on your own accounts, start at [SELF-HOST.md](SELF-HOST.md).

## Licence

Apache License 2.0. See [LICENSE](../LICENSE) and [NOTICE](../NOTICE).
Contributions come in under the same licence; see
[CONTRIBUTING.md](../CONTRIBUTING.md).
