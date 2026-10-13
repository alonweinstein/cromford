#!/bin/bash
# gh-identity: raw-by-design — the third gate of that shape, and the strictest case: its ONE read (the head and labels of a PR a freeze would hold) runs inside an already-armed lane, and it fails CLOSED on an unreadable answer — so a token minted here that cannot see the repo is a FROZEN repo, not a missing log line.
# bin/lib/main-red-gate.sh — BH-945: ONE main-red freeze, read by EVERY merge
# lane. Sourced by bin/lib/merge-conductor-lib.sh, which every automatic merge
# path already sources; never executed. Modelled on bin/lib/block-gate.sh and
# bin/lib/pr-dep-gate.sh, which is the shape this repo already uses twice for
# "one gate, every lane".
#
# THE INCIDENT (2026-09-18). flags/main-red-example-org-cromford went up on
# the hub at 20:41Z and bin/merge-conductor.sh logged "MAIN_RED_FREEZE in force"
# every tick — while #931 (21:10Z) and #942 (22:42Z) merged into that same red
# main. Two halves were broken and both are fixed in this build:
#   * the functions below were PRIVATE to bin/merge-conductor.sh, so the five
#     other lanes that run `gh pr merge` and the two that feed them had no read
#     of the freeze at all. They live here now, under the same names, so the
#     conductor's own call sites did not change;
#   * bin/main-red-detector.sh wrote a local file and never published the
#     pause_flags row, so a box could not see the flag even if it asked. The
#     detector publishes through flag_set now, and mrg_flag_on below reads
#     through flag_active, which materialises the file from the row.
#
# THE RC CONTRACT the lanes are written against: main_red_hold answers 0 = HOLD,
# 1 = proceed. The flag name that is in force is left in MRG_FLAG for the log
# line — set in the CALLING shell rather than printed, which is _PDG_ANS's
# reason: a memo written inside $(...) dies with the subshell that wrote it, and
# the memo here is what keeps a six-entry queue pass to ONE flag read.
#
# THE ASYMMETRY, kept exactly as the conductor had it: FAIL CLOSED on the
# exemption read (a diff nobody can read is not test-only), FAIL OPEN on the
# flag read (a worker outage with no local file is "no flag", which is
# automerge-disabled's own rule — an unreachable worker cannot change a single
# decision). A fleet that stops merging during every worker blip is a stall the
# ticket did not ask for.
#
# THE IDENTITY IS THE LANE'S. The one `gh pr view` below runs on whatever token
# the calling lane armed; minting a second one here would override the tier-2
# sweep's admin-PAT fallback.
#
# THE LABEL IS ONE KNOB (BH-1770). MC_MAIN_RED_LABEL is resolved by
# bin/lib/main-red-label.sh — the settings row lib.main-red-label.mc_main_red_label,
# then this name, then the deprecated alias MAIN_RED_LABEL, env before
# env/global.env — which is the same answer main_red_label gives a build's
# priority rank. Primed once here, so every later resolve in this lane reuses
# the one row read. A box whose sync has not landed the lib keeps both names
# from the env, canonical first.
if [ -r "$(dirname "${BASH_SOURCE[0]}")/main-red-label.sh" ]; then
  # shellcheck source=bin/lib/main-red-label.sh
  . "$(dirname "${BASH_SOURCE[0]}")/main-red-label.sh"
  main_red_label_prime
  MC_MAIN_RED_LABEL=$(main_red_label_resolve)
else
  MC_MAIN_RED_LABEL="${MC_MAIN_RED_LABEL:-${MAIN_RED_LABEL:-fix-main-red}}"
fi
#
# BH-1939: MC_MAIN_RED_TEST_PATHS has no literal here. It resolves through
# lib_env_apply main-red-gate (catalog/lanes.d/_lib.main-red-gate.json), in a
# subshell, the way and for the reasons bin/lib/gh-budget.sh gives. An empty
# answer takes the branch that does less: an empty path list exempts nothing.
# The label above is BH-1770's knob, not this lib's, so it is not re-resolved here.
_MRG_KV=$(
  exec 3>&1
  _MRG_R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || exit 0
  command -v lib_env_apply >/dev/null 2>&1 || . "$_MRG_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
  if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_MRG_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
    LANE_REGISTRY=$(lanes_json_path "$_MRG_R" 2>/dev/null) && export LANE_REGISTRY
  fi
  trap 'for _MRG_K in MC_MAIN_RED_TEST_PATHS; do printf "%s\t%s\n" "$_MRG_K" "${!_MRG_K:-}" >&3; done' EXIT
  lib_env_apply main-red-gate >/dev/null 2>&1)
while IFS=$'\t' read -r _MRG_K _MRG_V; do
  if [ -n "$_MRG_V" ]; then printf -v "$_MRG_K" '%s' "$_MRG_V"; fi
done <<<"$_MRG_KV"
unset _MRG_KV _MRG_K _MRG_V

# mrg_home — the harness root, read at CALL time (pdg_home's reason: a lane that
# sets HARNESS after sourcing the lib, which every fixture does, must read its
# own tree).
mrg_home() { printf '%s' "${HARNESS:-${MC_H:-/root/harness}}"; }

# mrg_flag_on <name> — the conductor's flag_on, spelled once. flag_active
# reconciles the file from the pause_flags row first, so a BOX with no local
# file materialises the freeze the hub published; with no client it is the bare
# file test this repo has always done.
mrg_flag_on() {
  local n="${1:-}"
  [ -n "$n" ] || return 1
  if command -v flag_active >/dev/null 2>&1; then flag_active "$n"; else [ -f "$(mrg_home)/flags/$n" ]; fi
}

# ONE FLAG READ PER (project, slug) UNTIL THE CALLER FORGETS IT. The conductor
# already reads once per project per tick; a queue pass over six entries would
# otherwise make twelve worker GETs for an answer that cannot usefully change
# inside one pass, each up to JOBS_TIMEOUT on an outage.
#
# The memo is dropped at a PASS BOUNDARY, not never (BH-987): a queue assembles
# a batch minutes before it lands, and a flag raised in that window is exactly
# the one that must stop the merge. bin/merge-queue.sh calls main_red_forget
# ONCE before each landing pass re-asks, so the pass costs one read per flag
# spelling and still sees a freeze raised since assembly. A flag raised DURING a
# landing pass is seen by the next pass. Callers that read once per process (the
# conductor tick, the tier-1 gate in bin/run-build.sh, the sweeps, review-prs,
# batch-resolve) neither need nor make that call.
MRG_MEMO_KEY=""
MRG_MEMO_VAL=""
MRG_FLAG=""

# main_red_forget — drop the memo so the next _mrg_flag_for reads the flag store
# again. Called at a landing-pass boundary; see the memo note above.
main_red_forget() {
  MRG_MEMO_KEY=""
  MRG_MEMO_VAL=""
  MRG_FLAG=""
}

# _mrg_flag_for <project> <slug> — sets MRG_FLAG; rc 0 when a flag is in force.
# Both spellings a detector or a hand might use are tested — the PROJECT name
# and the owner-repo slug — because a flag name cannot contain a slash. An EMPTY
# project or slug is SKIPPED: "main-red-" is not a flag anyone meant to raise,
# and testing it would freeze a lane on a stray file.
_mrg_flag_for() {
  local project="${1:-}" slug="${2:-}" key n
  key="$project|$slug"
  MRG_FLAG=""
  if [ "$key" = "${MRG_MEMO_KEY:-}" ]; then
    MRG_FLAG="${MRG_MEMO_VAL:-}"
    [ -n "$MRG_FLAG" ] && return 0
    return 1
  fi
  MRG_MEMO_KEY="$key"; MRG_MEMO_VAL=""
  for n in "${project:+main-red-$project}" "${slug:+main-red-${slug//\//-}}"; do
    [ -n "$n" ] || continue
    if mrg_flag_on "$n"; then MRG_MEMO_VAL="$n"; MRG_FLAG="$n"; return 0; fi
  done
  return 1
}

# main_red_flag <project> <slug> — prints the flag name in force. The
# conductor's signature, unchanged: bin/merge-conductor.sh's project tick and
# bin/batch-resolve.sh both read it this way.
main_red_flag() {
  _mrg_flag_for "${1:-}" "${2:-}" || return 1
  printf '%s' "$MRG_FLAG"
}

# main_red_test_path <path> — rc 0 when this path is a test file by the
# configured globs. `case` patterns, so tests/foo/bar.sh matches tests/* and
# src/tests/x does not.
main_red_test_path() {
  # NO PATHNAME EXPANSION ON THE PATTERN LIST (BH-987). $MC_MAIN_RED_TEST_PATHS
  # is word-split on purpose, but with globbing ON, `tests/*` expanded against
  # the CWD: from a repo checkout (the tier-1 gate runs after `cd "$WT"`) the
  # patterns became the list of EXISTING test files, so a PR adding a NEW test
  # file matched nothing and was never exempt. `local -` restores the shell
  # options on return, so no caller's `set` state changes (bash >= 4.4).
  local -
  set -f
  local f="$1" pat
  for pat in ${MC_MAIN_RED_TEST_PATHS:-}; do
    # shellcheck disable=SC2254
    case "$f" in $pat) return 0 ;; esac
  done
  return 1
}

# main_red_exempt <slug> <num> <url> <head> <labels-csv> — rc 0 when this PR may
# merge THROUGH a freeze. The label is matched csv-EXACT, so `fix-main-red-later`
# is not the label. FAIL CLOSED: a diff we cannot read is not exempt, and a tree
# with no mc_pr_files cannot read one at all.
main_red_exempt() {
  local slug="$1" num="$2" url="$3" head="$4" lbl="$5" files f
  # An empty label is no label: `,,` in an empty or `a,,b` csv must not exempt.
  if [ -n "${MC_MAIN_RED_LABEL:-}" ]; then
    case ",${lbl:-}," in *",$MC_MAIN_RED_LABEL,"*) return 0 ;; esac
  fi
  command -v mc_pr_files >/dev/null 2>&1 || return 1
  files=$(mc_pr_files "$slug" "$num" "$url" "$head") || return 1
  [ -n "$files" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    main_red_test_path "$f" || return 1
  done <<<"$files"
  return 0
}

# main_red_hold <project> <slug> <num> <url> [head] [labels-csv]
#   rc 0 = HOLD (main is red and this PR is not one of the two ways out)
#   rc 1 = proceed (nothing red, or exempt)
#   MRG_FLAG = the flag in force, for the lane's one log line.
#
# ZERO GitHub calls when no flag is on: the flag read comes first and the common
# case is a green main. When the freeze IS on and the caller did not already
# have the head and the labels, ONE `gh pr view --json headRefOid,labels` buys
# both (token discipline: a minimal field list, never a full PR object). An
# answer nobody can read HOLDS.
main_red_hold() {
  local project="${1:-}" slug="${2:-}" num="${3:-}" url="${4:-}" head="${5:-}" lbl="${6:-}" ans
  _mrg_flag_for "$project" "$slug" || return 1
  if [ -z "$head" ] || [ -z "$lbl" ]; then
    ans=$(gh pr view "$url" --json headRefOid,labels \
            -q '.headRefOid + "\t" + ([.labels[].name] | join(","))' 2>/dev/null) || return 0
    [ -n "$ans" ] || return 0
    [ -n "$head" ] || head="${ans%%$'\t'*}"
    [ -n "$lbl" ]  || lbl="${ans#*$'\t'}"
  fi
  main_red_exempt "$slug" "$num" "$url" "$head" "$lbl" && return 1
  return 0
}

# main_red_queue_hold <num> — pdg_queue_hold's shape for bin/merge-queue.sh:
# the project and the slug come from the queue's own environment.
main_red_queue_hold() {
  main_red_hold "${PROJECT:-}" "${SLUG:-}" "${1:-}" "https://github.com/${SLUG:-}/pull/${1:-}"
}
