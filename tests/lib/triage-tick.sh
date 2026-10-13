# shellcheck shell=bash
# tests/lib/triage-tick.sh — one alert-triage tick in a scratch harness, the
# way the cron line and the per-project runner make it (BH-5942), but in this
# shell and in order, so a suite reads the outcome without waiting.
#
#   triage_tick_setup <harness>
#     Install the lane's per-project libs into <harness> (bin/lib/
#     triage-inbox.sh, llm-lane-project.sh, project-lanes.sh, through
#     scratch_install_closure), and a setsid stub that starts nothing. Of what
#     the closure copies, only those three stay: the rest (lane-gate.sh, the
#     App-token libs) is optional to the runner, which uses it only when it is
#     present, and adding it would change what every older fixture's lanes do
#     (a lane gate that posts liveness rows, reads switches). A file the suite
#     installed itself is never touched. Needs tests/lib/scratch.sh first ($T).
#   triage_tick <alert-triage.sh>
#     1. the script with --dispatch: collect and route to the inboxes. The
#        detached runs pl_dispatch would start go to the setsid stub.
#     2. the script with each project that has queued work
#        (state/alert-triage/<p>/ inbox.tsv, deferred.tsv or work.tsv), in
#        name order, one after the other.
#     rc: the last project run's, or the dispatch's when no project ran.
#     Env set on the call (VAR=x triage_tick ...) reaches both steps.
#   triage_tick_reset <harness>
#     Forget every project's triage state (inboxes, spools, brake files).
#
# A suite that seeds or reads a per-project file uses
# <harness>/state/alert-triage/<project>/ (cromford is the home project
# for a line whose project is not in fleet.conf).

_TT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

triage_tick_setup() {
  local h="${1:?triage_tick_setup <harness>}"
  local copied f
  copied=$(cd "$_TT_REPO" && scratch_install_closure bin/lib/triage-inbox.sh "$h") || return 1
  while IFS= read -r f; do
    case "$f" in
      ''|bin/lib/triage-inbox.sh|bin/lib/llm-lane-project.sh|bin/lib/project-lanes.sh) ;;
      *) rm -f "${h:?}/$f" ;;
    esac
  done <<< "$copied"
  mkdir -p "$T/triage-tick-bin" || return 1
  printf '#!/bin/sh\nexit 0\n' > "$T/triage-tick-bin/setsid" && chmod +x "$T/triage-tick-bin/setsid"
}

triage_tick() {
  local s="${1:?triage_tick <alert-triage.sh>}" h d p rc
  h=$(cd "$(dirname "$s")/.." && pwd)
  PATH="$T/triage-tick-bin:$PATH" bash "$s" --dispatch; rc=$?
  for d in "$h"/state/alert-triage/*/; do
    p=$(basename "$d")
    [ -s "$d/inbox.tsv" ] || [ -s "$d/deferred.tsv" ] || [ -s "$d/work.tsv" ] || continue
    bash "$s" "$p"; rc=$?
  done
  return "$rc"
}

triage_tick_reset() {
  scratch_rm "${1:?triage_tick_reset <harness>}/state/alert-triage"
}
