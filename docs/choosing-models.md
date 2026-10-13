# Choosing models

Cromford can run each stage on one of five runners: `claude`, `codex`,
`openrouter`, `grok` or `fireworks`. You pick a primary per stage and the
rungs it falls back to. The full reference is [Model routes](MODEL-ROUTES.md).
This page covers what you need to set one up.

## How routes work

Routes live in the `model_routes` table. Each row is one rung of a ladder:

| Column | What it is |
|---|---|
| `role` | What the ladder is for, like `stage.triage` or `grok.default` |
| `position` | `0` is the primary, `1` and up are the fallbacks, in order |
| `model` | The model id. It must have a row in the price table |
| `runner` | Which CLI runs it: `claude`, `codex`, `openrouter`, `grok` or `fireworks` |

Two kinds of role matter here:

- **`stage.<stage>`** picks the runner for a stage: `stage.triage`,
  `stage.plan`, `stage.preplan`, `stage.execute`, `stage.review`,
  `stage.fix`. Rung 0 is the primary runner and rung 1 is its fallback.
- **`<runner>.default`** picks the model a non-Claude runner uses, like
  `grok.default` or `codex.default`. A Claude stage takes its model from its
  own ladder, like `build.plan` or `build.review`.

A stage with no route runs on `claude`. If a primary that isn't `claude` has
no fallback, it falls back to `claude`. An env line on the box
(`RUNNER_TRIAGE`, `RUNNER_EXECUTE`, and so on) beats the route, and the box
writes one alert a day while the two disagree.

## Setting a route

Edit routes on the console's `/models` screen, or send the whole ladder to the
jobs worker:

```
PUT /api/model-routes
```

The body names the role and the full ladder, in order. It replaces the whole
ladder in one write. An unknown runner or a model with no price row is
refused, and nothing is written.

## Worked example: Grok first, Claude as the fallback

To run triage on Grok and fall back to Claude, set the `stage.triage` ladder:

```json
{
  "role": "stage.triage",
  "ladder": [
    {"model": "grok-4.7", "runner": "grok"},
    {"model": "claude-opus-5-5", "runner": "claude"}
  ],
  "reason": "triage on grok first"
}
```

Then give the `grok` runner its model with the `grok.default` ladder:

```json
{
  "role": "grok.default",
  "ladder": [{"model": "grok-4.7", "runner": "grok"}]
}
```

Both model ids are in the shipped price catalog, `catalog/model-prices.json`.
Use any id from that file.

## Keys for each runner

These are secrets. They go under `/etc/harness/env/` on the box, never in
`selfhost.conf`.

| Runner | What it reads |
|---|---|
| `claude` | `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` |
| `codex` | Its own login, or `CODEX_API_KEY` or `OPENAI_API_KEY` |
| `openrouter` | `OPENROUTER_API_KEY` |
| `fireworks` | `FIREWORKS_API_KEY` |
| `grok` | The grok CLI's own login. `XAI_API_KEY` is used only when `GROK_BILLING=api` |

The [runners section of the operator setup](OPERATOR-SETUP.md#runners-and-vendor-lanes)
covers the failover order between runners.

## What still needs Claude today

Most stages can run on any of the five runners. These still need Claude:

- **The installer.** `bin/selfhost-install.sh` accepts only
  `SELFHOST_MODEL_AUTH=oauth` (a Claude Code token) or `api-key` (an
  Anthropic key). There is no option for another vendor yet, so plan on a
  Claude credential being on the box.
- **The strongest safety guard.** The guard that stops a build from merging a
  PR, pushing `main`, deploying or writing to a production database is a
  Claude Code hook. Other runners get a shell-level guard instead, set up in
  `bin/agent-call.sh`.
- **Parallel sub-agents in the execute stage.** The execute prompt asks for
  sub-agents through Claude Code's Task tool, which the other runners don't
  have.
- **A few lanes pinned to Claude:** the merge queue's re-review of a moved PR
  (`bin/lib/mc/rebase.sh`, set by `MC_RR_RUNNERS`), the hub's alert responder
  (`bin/watchdog-responder.sh`), and the architecture research lane
  (`bin/archie-research.sh`).
- **The fallback.** A non-Claude stage with no fallback rung falls back to
  Claude. Give it a fallback of your own to avoid that.
