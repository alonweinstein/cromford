#!/bin/bash
# shellcheck shell=bash
# bin/lib/deployment.sh — BH-4080: the ONE home of every value specific to the
# deployment this harness was built on (our GitHub repo and org, the operator's
# login and commit identity, the bot identities, the workers.dev subdomain, the
# box naming convention and the hub's fleet name). Sourced, never executed.
#
# Each knob is `: "${X:=default}"`, so a value already in the environment (an
# export, or env/global.env, which every lane loads `set -a`) always wins and
# this file only fills what nobody set. Nothing else happens here: no reads, no
# subshells, no functions, so sourcing it twice, or from anywhere, is free.
# Consumers source "${HARNESS_DEPLOYMENT_FILE-<beside itself>/deployment.sh}"
# and fail when it is missing. HARNESS_DEPLOYMENT_FILE is unset on a box; the
# test library (tests/lib/scratch.sh) points it at the checkout's own copy,
# because a scratch tree often carries one copied lib and nothing beside it.
# Source it AFTER env/global.env is loaded where you can: HARNESS_GH_OWNER is
# derived from HARNESS_REPO at source time, so a HARNESS_REPO set later does
# not move it (set HARNESS_GH_OWNER too, or load the env first).
#
# Registered in catalog/lanes.d/_lib.deployment.json, every knob `settable:
# false`: a repo slug, a push identity or a host that a console page could write
# is a hijack path (tests/lanes-registry-test.sh section 17). Another operator
# sets these in env/global.env on the box. The defaults are this fleet's values,
# so on our boxes nothing changes.
#
# bin/deployment-lint.sh (catalog/deployment-literals.tsv) fails on a literal of
# any of these outside this file and the allowlisted homes; the report of where
# each one lives is docs/config-inventory/deployment.md.

# The harness's own GitHub repo: issues, PRs, CI runs, the box clone.
: "${HARNESS_REPO:=example-org/cromford}"
# The GitHub owner the App mints tokens for by default. Follows the repo.
: "${HARNESS_GH_OWNER:=${HARNESS_REPO%%/*}}"
# The operator's GitHub login: PR author filters, the triage gate's self actor.
: "${HARNESS_OPERATOR_LOGIN:=operator}"
# The commit identity a box falls back to when it has no global git identity.
: "${HARNESS_GIT_NAME:=operator}"
: "${HARNESS_GIT_EMAIL:=operator@example.com}"
# The committer name on the merge conductor's own merges (MC_GIT_NAME beats it).
: "${HARNESS_MERGE_GIT_NAME:=box}"
# The harness bot's commit identity (verification-map retrofits, rebase fixups).
: "${HARNESS_BOT_GIT_NAME:=cromford}"
: "${HARNESS_BOT_GIT_EMAIL:=harness@example.com}"
# https://harness-jobs.<sub>.workers.dev and https://harness-locks.<sub>.workers.dev.
: "${HARNESS_WORKERS_SUBDOMAIN:=operator}"
# A fleet.conf row with no box column is owned by <prefix><project minus -os>.
: "${HARNESS_BOX_PREFIX:=box-}"
# The hub's fleet name when HUB_BOX_NAME is not set (HUB_BOX_NAME always wins).
: "${HARNESS_HUB_BOX:=box-hub}"
