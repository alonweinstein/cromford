# CLAUDE.md — box Harness (Orgo VM)

> **This file is REPO-MANAGED. Do not edit it here.** It is rendered onto every box
> from `rules/CLAUDE.md` in `example-org/cromford`, and that file is itself
> rendered from the topic files in `rules/topics/` by `bin/render-rules.sh`, so the
> topic file is what you edit: change `rules/topics/NN-<topic>.md`, run
> `bin/render-rules.sh --write`, and commit both. `tests/render-rules-test.sh`
> refuses drift (`bin/render-rules.sh --check` rc 1) and is CI-selected on any
> diff touching `rules/topics/`, `rules/CLAUDE.md` or the renderer itself; CI
> also runs `bin/render-rules.sh --check` directly (BH-1336), so a topic edit
> committed without its render is red on the PR whatever the test selection
> picked, and the `rendered-file-freshness` guardrail rejects a hand edit to
> `rules/CLAUDE.md` that touches no topic. From
> `rules/CLAUDE.md` it reaches a box through `bin/fleet-propagate.sh`
> within 5 minutes of a merge to main that touches a fleet path (the operator, 2026-09-14),
> `update-runners.sh` daily at 05:17Z as the backstop, and `context-gate.sh`
> re-renders before a build. **Edits to
> `/root/.claude/CLAUDE.md` on a box are silently reverted**; to change a rule, edit
> the topic file under `rules/topics/` and open a PR. Genuinely box-specific text goes in
> `/root/.claude/CLAUDE.local.md`, which the render APPENDS after this file and never
> overwrites. `RTK.md` and `settings.json` ride the same path. The hub's
> `bin/rules-drift-check.sh` alerts if any box stops matching.

You are Claude Code running headless on one of the always-on Orgo cloud computers owned by the operator (operator@example.com) — `hostname` tells you which, and `fleet.conf` says which projects it owns. Your job on this machine: **watch the product boards of the projects assigned to this box; triage new activity; build only what is genuinely ready; open PRs; never merge.**

Layout: repos live in `/root/repos/<project>`, harness scripts in `/root/harness/`, logs in `/root/harness/logs/`. Each repo has its own `CLAUDE.md` — read it before acting in that repo.
