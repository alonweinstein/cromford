#!/bin/bash
# bin/lib/fleet-paths.sh — the one list that answers "does this commit matter to
# the fleet" (BH-5247). Sourced, never executed; defines FLEET_PATHS and nothing
# else, so it is safe to source twice and under set -u. Readers:
#   bin/fleet-propagate.sh  — a range touching none of these is skipped, and the
#                             boxes stay where they are
#   bin/pipeline-health.sh  — fleet checkout freshness: a box behind main only
#                             outside these paths is current, not drift
#
# --- WHERE EACH PATH LANDS ---------------------------------------------------
# Derived from what bin/harness-sync.sh rsyncs, what bin/update-runners.sh
# renders, and what bin/fly-image-build.sh bakes — if you add a plane there,
# add it here:
#   bin/         -> /root/harness/bin on every box (harness-sync), AND baked into
#                   the pool image (fly-image-build bakes the LIVE hub install,
#                   so run-build.sh on a pool machine IS this directory)
#   prompts/     -> /root/harness/prompts (harness-sync)
#   fly/         -> the Dockerfile + entrypoint the pool image is built FROM
#   rules/       -> /root/.claude/{CLAUDE.md,RTK.md,settings.json} (update-runners)
#   skills/      -> ~/.claude/skills (bin/sync-skills.sh, called by harness-sync)
#   cron/        -> the crontab base every box renders from (update-runners)
#   catalog/     -> /root/harness/catalog + pushed to harness-jobs (harness-sync);
#                   pools read it from the spawn tarball, so it never rebakes
#                   an image (POOL_EXEMPT_PATHS in fleet-propagate.sh, BH-3463)
#   checks/      -> /root/harness/checks; the gates EXECUTE these (harness-sync)
#   guardrails/  -> /root/harness/guardrails (harness-sync)
#   config/      -> /root/harness/config (harness-sync); run-time configuration
#                   the lanes read, e.g. config/generated-paths.conf
#   worker/      -> hub only: harness-sync runs `wrangler deploy` for a changed worker
#   fleet.conf   -> /root/harness/fleet.conf, the registry every lane reads
#   vercel.conf  -> /root/harness/vercel.conf
#   orchestrator/ -> hub only: /root/orchestrator/.claude/skills (sync-skills.sh,
#                   called by harness-sync, BH-4064); pools never read it
# Entries ending in / are directories, the rest are files at the repo root; the
# same words are git pathspecs, which is how pipeline-health uses them.
# shellcheck disable=SC2034  # read by the scripts that source this file
FLEET_PATHS="bin/ prompts/ fly/ rules/ skills/ cron/ catalog/ checks/ guardrails/ config/ worker/ fleet.conf vercel.conf orchestrator/"
