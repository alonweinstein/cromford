#!/bin/bash
# bin/lib/triage-hotfix-lib.sh — THE EMERGENCY LINE IS READ FIRST (BH-645,
# #643 slice 2). Moved out of bin/run-triage.sh at rebase time so the driver
# carries no stage body (tests/rt-split-layout-test.sh A6; a line ceiling
# until BH-5228) — the
# functions are unchanged from BH-645's original inline block, and the stage
# files (bin/lib/rt/scope.sh, bin/lib/rt/shards.sh) that call them are the same
# ones the ticket shipped.
#
# This tick hands the session a READY-QUEUE slice capped at 40 lines and a
# board slice of whatever is launchable, both in discovery order. A hotfix
# filed this morning sits wherever the file happens to put it — line 43 on a
# busy box, which is to say nowhere, because the cap cuts it off before the
# session ever reads it.
#
# So the project's open `ai-build` + `hotfix` issue numbers are read ONCE per
# tick, the matching lines are marked `[HOTFIX] ` and each slice is
# stable-sorted hotfix-first BEFORE the cap. The vocabulary — the label name,
# the kill switch, the sort — is bin/lib/hotfix-lib.sh's and nothing is
# redefined here.
#
# GITHUB-ISSUES LANES ONLY, because the label lives on a GitHub issue; an in-app
# product board has no such field in v1 (#368), so those projects never make the
# call and render exactly what they render today.
#
# EVERY UNCERTAIN ANSWER IS "NO HOTFIXES", which is today's behaviour: the lane
# off, no gh, no jq, no repo slug, the shared API budget low, a call that fails.
# A 403 is deliberately indistinguishable from an empty list here — the cost of
# a wrong negative is one tick of FIFO on a queue that is re-offered every tick,
# and the cost of paging on it is an alert nobody can act on.
#
# Sourced by bin/run-triage.sh, BEFORE bin/lib/rt/scope.sh's queue-pending and
# board_section arms call triage_hot_load/triage_hot_mark. A caller that lifts
# just the QLINES line (tests/ready-queue-rows-test.sh) or the u2 line without
# sourcing this file still degrades correctly: both call sites guard with
# `command -v triage_hot_mark` and fall back to a plain passthrough.
#
#   triage_hot_load          -> memoised per-tick read of the open hotfix issue
#                                numbers; always rc 0
#   triage_hot_mark <class>  -> stdin lines, stdout the same lines marked
#                                `[HOTFIX] ` and sorted hotfix-first; a `cat`
#                                passthrough whenever the answer is uncertain
#   hot_sop <text>           -> the one SOP sentence, only when something in
#                                <text> was actually marked
# The root is HARNESS, then H. With neither set nothing is sourced, and the
# triage_hot_* functions take their "uncertain" path (BH-2650).
_THL_R="${HARNESS:-${H:-}}"
# shellcheck source=bin/lib/hotfix-lib.sh
[ -n "$_THL_R" ] && [ -r "$_THL_R/bin/lib/hotfix-lib.sh" ] && . "$_THL_R/bin/lib/hotfix-lib.sh"
# shellcheck source=bin/lib/gh-budget.sh
[ -n "$_THL_R" ] && [ -r "$_THL_R/bin/lib/gh-budget.sh" ] && . "$_THL_R/bin/lib/gh-budget.sh"
# gh-rest: no-graphql — the repo's own read, over REST (BH-425), not gh issue
# list.
# shellcheck source=bin/lib/gh-rest.sh
[ -n "$_THL_R" ] && [ -r "$_THL_R/bin/lib/gh-rest.sh" ] && . "$_THL_R/bin/lib/gh-rest.sh"
unset _THL_R
TRIAGE_HOT=""        # " <key> <key> " — canonical keys, space-delimited
TRIAGE_HOT_READY=0
# triage_hot_load — the one read, memoised for the tick. Call it from the PARENT
# shell before the marking pipelines: both marked slices are built inside a
# `$( ... )`, and a memo set in a subshell is a memo the next subshell does not
# have — which would be one gh call per slice instead of one per tick.
triage_hot_load() {
  [ "$TRIAGE_HOT_READY" = 1 ] && return 0
  TRIAGE_HOT_READY=1
  command -v hotfix_lane_on >/dev/null 2>&1 || return 0
  [ "$(hotfix_lane_on "$HARNESS")" = 1 ] || return 0
  command -v triage_shard_gh >/dev/null 2>&1 || return 0
  [ "$(triage_shard_gh "$HARNESS" "$PROJECT")" = 1 ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v gh_rest_var >/dev/null 2>&1 || return 0   # BH-1485: the name this lane calls
  [ -n "${TRIAGE_GH_SLUG:-}" ] || return 0
  # The SAME bucket every other lane reads (#645: "reuse it, do not add a second
  # budget"). Low means skip this tick, not fail.
  if command -v gh_budget_low >/dev/null 2>&1 && gh_budget_low run-triage >/dev/null 2>&1; then
    return 0
  fi
  # REST, not `gh issue list` (BH-425: the repo's decision reads are REST-only
  # since #768 — a rate-limited GraphQL call answered empty and that read as
  # "no such object" rather than "unknown", which is exactly the shape this
  # function's own "every uncertain answer is no hotfixes" contract forbids
  # from silently becoming the wrong kind of certain). `labels=a,b` is AND on
  # REST, the same as two `--label` flags on the CLI. `/issues` also returns
  # PRs, so `.pull_request == null` is load-bearing, not decoration.
  # THE LABEL IS A URL COMPONENT, NOT A STRING TO GLUE ON (BH-1349). Raw, a
  # label with a SPACE hands gh a URL it cannot build: nothing comes back, not
  # even a status line, gh_rest answers 75 and the whole tick degrades to FIFO.
  # A label with an `&` is worse than silent — it ENDS the labels parameter, so
  # GitHub filters on `ai-build,<prefix>` alone and the tick marks a superset
  # while looking like it worked. So it is `@uri`-encoded before it goes in;
  # jq is already a precondition of this function, so that costs no new
  # dependency, and the default `hotfix` encodes to itself, which leaves the
  # fleet's own query (and the ETag key computed over it) exactly where it was.
  # An empty encode — only reachable if jq itself failed — is this file's usual
  # "uncertain = no hotfixes" rather than `labels=ai-build,`, which would mark
  # every open ai-build issue.
  local body="" nums lbl
  lbl=$(hotfix_label "$HARNESS" | tr -d '\n' | jq -sRr @uri 2>/dev/null) || lbl=""
  [ -n "$lbl" ] || return 0
  # BH-1485: `gh_rest_var`. "uncertain = no hotfixes" is still the answer on a
  # failed read; what the capture threw away was the reason it failed.
  gh_rest_var body GET "repos/$TRIAGE_GH_SLUG/issues?labels=ai-build,$lbl&state=open&per_page=100" 2>/dev/null || return 0
  nums=$(printf '%s' "$body" | jq -r '.[] | select(.pull_request == null) | .number' 2>/dev/null) || return 0
  [ -n "$nums" ] || return 0
  # Delimited on BOTH sides, and that is the whole lookup: the membership test
  # below matches " <key> ", so a set that ends without its trailing space can
  # never match its own last number.
  TRIAGE_HOT=" $(printf '%s' "$nums" | tr '\n' ' ') "
  return 0
}
# triage_hot_mark <class> — stdin lines, stdout the same lines marked and sorted
# hotfix-first. An empty set is `cat`: byte-identical passthrough, no sort, no
# marker, so a tick with no hotfix renders today's prompt exactly.
triage_hot_mark() {
  local cls="${1:-}" line k
  triage_hot_load
  if [ -z "$TRIAGE_HOT" ] || ! command -v triage_shard_key >/dev/null 2>&1 \
     || ! command -v priority_sort_tsv >/dev/null 2>&1; then
    cat; return 0
  fi
  # `|| [ -n "$line" ]` is load-bearing: a producer whose last line carries no
  # trailing newline (bin/unblocked-children.sh is one) would otherwise have its
  # final ticket read and thrown away by the loop that was supposed to order it.
  while IFS= read -r line || [ -n "$line" ]; do
    # The marker is ours, so a line that already carries it is normalised rather
    # than marked twice: `[HOTFIX] [HOTFIX] BH-9043` is a key nothing downstream
    # can read.
    line=${line#'[HOTFIX] '}
    k=$(triage_shard_key "$cls" "$PROJECT" 1 "$line" 2>/dev/null) || k=""
    # A key this function cannot place keeps rank 1 and its original position.
    # It is never dropped: a queue line nobody reads is a client waiting.
    if [ -n "$k" ] && [ "${TRIAGE_HOT#*" $k "}" != "$TRIAGE_HOT" ]; then
      printf '0\t[HOTFIX] %s\n' "$line"
    else
      printf '1\t%s\n' "$line"
    fi
  done | priority_sort_tsv 1 | cut -f2-
  return 0
}
# hot_sop <text> — the one SOP sentence, and only when something was marked. The
# prompt has to be byte-identical on a tick with no hotfix, which is only true
# if the sentence is conditional on the marker actually being in the text.
hot_sop() {
  case "${1:-}" in
    *'[HOTFIX] '*) printf 'Lines marked [HOTFIX] are launched before any other line.' ;;
  esac
}
