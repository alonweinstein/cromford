#!/bin/bash
# bin/ci-merge-reuse.sh — on a PR push that only merges the base branch, which
# lint steps can reuse the previous head's green run? (BH-5357, Part E)
#
# WHY. On 2026-10-07/08 about 30 conflicted PRs had main merged into them, and
# every push re-ran the lint job's tree checks from scratch although the PR's
# own patch had not changed and main's side was already green on main.
#
# THE DECISION, one per push, written to GITHUB_OUTPUT:
#   mode=full    every step runs, exactly as before. Chosen on: knob off, an
#                action other than synchronize, a mergify/merge-queue/ head,
#                a push that is not merge-only (bin/lib/merge-push.sh
#                mp_classify), an unreadable diff, a selection input touched by
#                anything in the push, or no green Harness CI run on the
#                previous head for this branch (a failed read included).
#   mode=reuse   for each row of catalog/ci-merge-reuse.tsv, run_<id>=1 when a
#                conflict resolution matches one of its globs, or when main's
#                incoming change AND the PR's own patch each match one; else 0.
# Also: reason=, prev_run= (the green run reused), and run_<id> for every
# catalog row (1 in full mode). The workflow gates each mapped step on
# `steps.reuse.outputs.run_<id> != '0'`, so an empty output (this step crashed
# or did not run) runs the step.
#
# Env: MR_ACTION MR_BEFORE MR_HEAD MR_BASE_REF MR_HEAD_REF CI_REPO GH_TOKEN
#      PR_CI_MERGE_REUSE. Seams: MR_GH (gh binary), MR_GIT_DIR, MR_CATALOG,
#      MR_WORKFLOW (the run name, default "Harness CI").
# rc 0 whenever it wrote a decision, including an empty MR_BEFORE on an
# opened/reopened event (BH-6310); rc 2 on any other bad args or an unreadable
# catalog, after writing mode=full.
# tests/ci-merge-reuse.bh-5357-test.sh drives it; the wiring suite pins the
# workflow half.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
GD="${MR_GIT_DIR:-$ROOT}"
CATALOG="${MR_CATALOG:-$ROOT/catalog/ci-merge-reuse.tsv}"
GH="${MR_GH:-gh}"
WORKFLOW="${MR_WORKFLOW:-Harness CI}"
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-}"
# The inputs of this decision itself. Any of them in the push means the old
# green was decided by other rules, so nothing is reused.
SELECTION_INPUTS="catalog/ci-merge-reuse.tsv bin/ci-merge-reuse.sh bin/lib/merge-push.sh bin/lib/patch-same.sh bin/lib/lane-gate.sh catalog/lanes.d/_lib.ci-merge-reuse.json .github/**"

IDS=(); GLOBS=()
say() {
  printf '%s\n' "$1"
  [ -n "$SUMMARY" ] && printf '%s\n' "$1" >> "$SUMMARY"
  return 0
}
decide_full() { # <reason> [rc]
  local id
  {
    echo "mode=full"
    echo "reason=$1"
    echo "prev_run="
    for id in "${IDS[@]}"; do echo "run_$id=1"; done
  } >> "$OUT"
  say "merge-reuse: mode=full reason=$1"
  echo "::notice title=merge-reuse::mode=full reason=$1"
  exit "${2:-0}"
}

# The catalog first, so even a bad-args answer names every step.
if [ -r "$CATALOG" ]; then
  while IFS=$'\t' read -r id globs _; do
    case "$id" in ''|\#*) continue ;; esac
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] && [ -n "${globs// /}" ] || { IDS=(); decide_full "catalog row '$id' is malformed" 2; }
    IDS+=("$id"); GLOBS+=("$globs")
  done < "$CATALOG"
fi
[ "${#IDS[@]}" -gt 0 ] || decide_full "catalog unreadable: $CATALOG" 2
for v in MR_BEFORE MR_HEAD MR_BASE_REF; do
  [ -n "${!v:-}" ] && continue
  rc=2
  # GitHub sends no before sha on a PR's opened/reopened event. That is full
  # mode, not a usage error, so it must not turn the step red.
  if [ "$v" = MR_BEFORE ] && [ -n "${MR_HEAD:-}" ] && [ -n "${MR_BASE_REF:-}" ]; then
    case "${MR_ACTION:-}" in opened|reopened) rc=0 ;; esac
  fi
  decide_full "bad args: $v is empty" "$rc"
done
# shellcheck source=lib/merge-push.sh
. "$DIR/lib/merge-push.sh" || decide_full "bin/lib/merge-push.sh did not load" 2

knob=$(mp_knob)
[ "$knob" = on ] || decide_full "knob PR_CI_MERGE_REUSE is off"
[ "${MR_ACTION:-}" = synchronize ] || decide_full "action ${MR_ACTION:-<none>}"
case "${MR_HEAD_REF:-}" in mergify/merge-queue/*) decide_full "merge-queue batch" ;; esac

BASE="origin/$MR_BASE_REF"
read -r cls why <<<"$(mp_classify "$GD" "$BASE" "$MR_BEFORE" "$MR_HEAD")"
case "$cls" in
  clean|resolved) ;;
  *) decide_full "push is not merge-only (${why:-$cls})" ;;
esac
RES=""
if [ "$cls" = resolved ]; then
  RES=$(mp_resolved "$GD" "$BASE" "$MR_BEFORE" "$MR_HEAD") || decide_full "resolution paths unreadable"
fi
MAIN=$(mp_main_files "$GD" "$BASE" "$MR_BEFORE" "$MR_HEAD") || decide_full "main's incoming diff unreadable"
PRF=$(mp_pr_files "$GD" "$BASE" "$MR_HEAD") || decide_full "the PR's own diff unreadable"

# matches <globs> <paths> — rc 0 when any path matches any glob. In a [[ ]]
# pattern `*` already crosses `/`, so `**` needs no special case.
matches() {
  local -a gl; local g p
  read -ra gl <<<"$1"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for g in "${gl[@]}"; do
      # shellcheck disable=SC2053
      [[ "$p" == $g ]] && return 0
    done
  done <<<"$2"
  return 1
}
hit=$( { matches "$SELECTION_INPUTS" "$MAIN" && echo main; } || { matches "$SELECTION_INPUTS" "$PRF" && echo pr; } \
       || { matches "$SELECTION_INPUTS" "$RES" && echo resolution; } )
[ -z "$hit" ] || decide_full "a selection input is in the $hit change"

# The previous head's green run on this branch, read with the job's own token.
command -v "$GH" >/dev/null 2>&1 || { echo "::warning title=merge-reuse::gh not found; running everything"; decide_full "gh unavailable"; }
[ -n "${CI_REPO:-}" ] || decide_full "CI_REPO is empty"
runs=$("$GH" api "repos/$CI_REPO/actions/runs?head_sha=$MR_BEFORE&event=pull_request" 2>/dev/null); grc=$?
if [ "$grc" != 0 ]; then
  echo "::warning title=merge-reuse::reading the previous head's runs failed (rc $grc); running everything"
  decide_full "previous run unreadable (gh rc $grc)"
fi
prev=$(jq -r --arg n "$WORKFLOW" --arg b "${MR_HEAD_REF:-}" \
  '[.workflow_runs[]? | select(.name == $n and .head_branch == $b and .conclusion == "success") | .id] | first // empty' \
  <<<"$runs" 2>/dev/null) || prev=""
[[ "$prev" =~ ^[0-9]+$ ]] || decide_full "no green $WORKFLOW run on ${MR_BEFORE:0:8}"

reason="$cls main merge"
[ "$cls" = resolved ] && reason="$reason ($(grep -c . <<<"$RES") resolved paths)"
{
  echo "mode=reuse"
  echo "reason=$reason"
  echo "prev_run=$prev"
} >> "$OUT"
say "merge-reuse: mode=reuse reason=$reason prev_run=$prev"
for i in "${!IDS[@]}"; do
  id="${IDS[$i]}"; gl="${GLOBS[$i]}"
  if matches "$gl" "$RES"; then
    echo "run_$id=1" >> "$OUT"; say "merge-reuse: run $id (a conflict resolution reaches it)"
  elif matches "$gl" "$MAIN" && matches "$gl" "$PRF"; then
    echo "run_$id=1" >> "$OUT"; say "merge-reuse: run $id (main's change and the PR both reach it)"
  else
    echo "run_$id=0" >> "$OUT"; say "merge-reuse: reused $id green on run $prev (${MR_BEFORE:0:8})"
  fi
done
echo "::notice title=merge-reuse::mode=reuse reason=$reason prev_run=$prev"
exit 0
