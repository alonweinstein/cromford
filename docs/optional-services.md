# Optional services

Cromford runs with none of these. Each one makes it faster, cheaper to run, or
easier to watch. Add them when you need them, in any order.

## Mergify

Programs change; check the vendor's page.

**Programs.** Mergify runs a [startup program](https://mergify.com/startup).

**What it is.** A merge queue, run as a GitHub App.

**What it adds.** Approved PRs are tested together against the latest `main`
before they land, so two PRs that pass alone can't break `main` together.

**When you want it.** When several PRs a day land on the same repo. Without it,
Cromford merges each approved PR straight through its own gates.

**How to sign up.** Install the [Mergify GitHub App](https://github.com/apps/mergify)
and grant it only the repos you list in `SELFHOST_PROJECTS`. In the Mergify
dashboard, turn on both Merge Queue and Workflow Automation. They're separate
switches, and the label rule needs the second one.

**How to switch it on.** Commit a `.mergify.yml` with `queue_rules:` to each
repo's default branch. `bin/mergify-template.sh` prints one. Create the
`merge-queue` label on the repo: Cromford adds it to a PR to queue it, and
never creates labels itself. [MERGIFY](MERGIFY.md) has the full setup.

**Free tier.** See the vendor's pricing page at [mergify.com](https://mergify.com).

## MonkCI

Programs change; check the vendor's page.

**What it is.** Hosted runners for GitHub Actions, outside GitHub's own
runner pool.

**What it adds.** CI capacity you pick and pay for directly. The internal CI
runs on one 4 vCPU MonkCI machine per job.

**When you want it.** When CI wait time is what holds your PRs up.

**How to sign up.** On the vendor's site, [monkci.com](https://monkci.com).

**How to switch it on.** In your own repos, point a workflow's `runs-on` at the
runner label MonkCI gives you. The internal CI picks its runner from the
`CI_RUNNER` repo variable, for example `"monkci-ubuntu-24.04-4"`, and
[CI runners](CI-RUNNERS.md) lists the values it accepts. The public copy's CI
runs on GitHub's hosted runners and doesn't read `CI_RUNNER`.

**Free tier.** See the vendor's pricing page at [monkci.com](https://monkci.com).

## Fly build pool

Programs change; check the vendor's page.

**What it is.** One Fly app and volume per project that runs builds, separate
from the hub.

**What it adds.** Builds stop competing with the hub for CPU and disk, and
each project builds on its own machine.

**When you want it.** When builds on the hub slow down triage, or you watch
more than a couple of projects. One lesson first: model account capacity, not
machines, is the usual ceiling. Expect about 3 to 4 heavy builds at once per
model account. More machines on one account just hit its limits sooner.
[Build concurrency](BUILD-CONCURRENCY.md) has the detail.

**How to sign up.** Create an account at [fly.io](https://fly.io), then set
`FLY_ORG` to your org.

**How to switch it on.** Set `SELFHOST_POOL=fly`. `SELFHOST_POOL=local` builds
on the hub instead. To cap how many builds a box runs at once, set
`BUILD_SLOTS` in the box's `global.env`. `0` means no cap.

**Free tier.** See the vendor's pricing page at [fly.io](https://fly.io).

## Orgo, or any VM

Programs change; check the vendor's page.

**What it is.** A Linux machine you already run, used as the hub instead of a
Fly app. Orgo is one provider of always-on cloud machines, and any VM you can
reach over ssh works.

**What it adds.** The hub runs on hardware you choose and may already pay for.

**When you want it.** When you'd rather not run the hub on Fly, or you want
to sign in to the machine and watch it.

**How to sign up.** With your VM provider, for example [orgo.ai](https://www.orgo.ai).

**How to switch it on.** Set `SELFHOST_HUB=vm` and `SELFHOST_HUB_HOST` to the
machine's hostname or address.

**Free tier.** See the vendor's pricing page at [orgo.ai](https://www.orgo.ai).

## Model runners other than Claude

Programs change; check the vendor's page.

**Programs.** OpenRouter has [OpenRouter for Startups](https://openrouter.ai/startup-program), and Fireworks has [Fireworks for Startups](https://fireworks.ai/startups).

**What it is.** Codex, Grok, OpenRouter and Fireworks as runners for any
stage, next to Claude or instead of it.

**What it adds.** A second vendor to fall back to when one is down or out of
quota, and cheaper models for the stages that don't need the strongest one.

**When you want it.** When one model account can't keep up, or you want a
fallback that doesn't share its limits.

**How to sign up.** With each vendor. For example, [OpenRouter](https://openrouter.ai/sign-up)
or [Fireworks](https://fireworks.ai).

**How to switch it on.** Put the runner's key on the box, then point a stage
at it with a `stage.<stage>` route. [Choosing models](choosing-models.md) has
the key names and a worked example.

**Free tier.** OpenRouter's [pricing page](https://openrouter.ai/pricing) lists
a Free plan with "25+ free models". For the others, see each vendor's pricing
page.

## Telegram or Slack

Programs change; check the vendor's page.

**What it is.** A chat channel for alerts.

**What it adds.** Alerts reach you where you already are, instead of waiting
in a log on the hub.

**When you want it.** As soon as you rely on the harness running unattended.

**How to sign up.** For Telegram, create a bot with
[BotFather](https://core.telegram.org/bots). For Slack, create an app at
[api.slack.com/apps](https://api.slack.com/apps).

**How to switch it on.** Set `SELFHOST_CHAT=telegram` or `SELFHOST_CHAT=slack`.
The dry-run then names the secrets to put on the box: `TELEGRAM_BOT_TOKEN` and
`TELEGRAM_CHAT_ID`, or `SLACK_BOT_TOKEN`. See the
[deployment guide](SELF-HOST.md#2-what-you-need).

**Free tier.** See each vendor's pricing page.

## CodeRabbit

Programs change; check the vendor's page.

**Programs.** CodeRabbit is free for public repositories and has a startup offer. Both are on its [pricing page](https://www.coderabbit.ai/pricing).

**What it is.** An AI code reviewer that comments on pull requests.

**What it adds.** A second set of review comments on each PR, from outside
Cromford.

**When you want it.** When you want another reviewer's notes on a PR. It
doesn't decide merges: Cromford's own review gate is what blocks a merge.

**How to sign up.** Install its GitHub App from [coderabbit.ai](https://www.coderabbit.ai)
on the repos you want reviewed.

**How to switch it on.** Nothing to set in Cromford. It works on the PRs
Cromford opens like on any other PR.

**Free tier.** See the vendor's pricing page at [coderabbit.ai](https://www.coderabbit.ai).

## At a glance

| Service | What it's for | Required? | Setting |
|---|---|---|---|
| Mergify | Merge queue | No | `.mergify.yml` and the `merge-queue` label |
| MonkCI | Faster CI runners | No | `runs-on`, or `CI_RUNNER` for the internal CI |
| Fly build pool | Builds off the hub | No | `SELFHOST_POOL=fly` |
| Orgo, or any VM | Hub on your own machine | No | `SELFHOST_HUB=vm`, `SELFHOST_HUB_HOST` |
| Model runners other than Claude | Fallbacks and cheaper stages | No | `stage.<stage>` routes |
| Telegram or Slack | Alerts in chat | No | `SELFHOST_CHAT` |
| CodeRabbit | Extra PR review | No | None |
