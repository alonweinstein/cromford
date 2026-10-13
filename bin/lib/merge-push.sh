# shellcheck shell=bash
# bin/lib/merge-push.sh — is a PR push only a merge of its base branch, and if
# so what did it change? (BH-5357, Part E). Sourced, never run. Pure git.
#
# bin/ci-merge-reuse.sh asks this on every pull_request push, to decide which
# lint steps can reuse the previous head's green run. It builds on
# bin/lib/patch-same.sh (sourced, never edited) and answers more shapes than it
# does: patch_same only proves a CLEAN main merge, and a merge with a conflict
# resolution is still a merge whose only new content is main's plus the hunks
# someone resolved.
#
#   mp_classify <git-dir> <base-ref> <before> <head>
#     prints ONE line, always rc 0:
#       clean          patch_same answers main-merge: every new commit is a
#                      merge of the base with no conflict and no hand edit.
#       resolved       <before> is an ancestor of <head>, and every commit in
#                      `rev-list head ^before ^base` is a two-parent merge whose
#                      2nd parent is on <base-ref> and whose 1st parent is not.
#                      At least one of them records a tree that differs from
#                      `git merge-tree --write-tree p1 p2` (a conflict hunk, or a
#                      hand edit made inside the merge: an evil merge is
#                      resolved, never clean).
#       full <reason>  anything else: no or all-zero <before>, an unknown sha,
#                      <before> not an ancestor (force-push, rebase), a non-merge
#                      commit, an octopus, a merge of a branch that is not the
#                      base, an empty commit list, any git failure.
#   mp_resolved <git-dir> <base-ref> <before> <head>
#     the union of the resolution paths (one per line, maybe none); rc 1 when
#     the push is not a merge-only push.
#   mp_main_files <git-dir> <base-ref> <before> <head>
#     main's incoming change: the files between merge-base(base, before) and
#     merge-base(base, head). rc 1 on any git failure.
#   mp_pr_files <git-dir> <base-ref> <head>
#     the PR's own patch: the files between merge-base(base, head) and head.
#     rc 1 on any git failure.
#   mp_knob
#     PR_CI_MERGE_REUSE as `on` or `off`: settings row > cached row > env
#     through lane-gate.sh's lib_env_apply in a subshell (lead-delta.sh's
#     ld_knob is the precedent), then the default in
#     catalog/lanes.d/_lib.ci-merge-reuse.json. Accepts on|off|1|0. Anything
#     else is off, with one note on stderr.
#
# CONSERVATIVE BY CONSTRUCTION, like patch-same.sh: every answer other than
# `full` needs positive evidence, and an answer this file cannot establish is
# `full`, which runs every step exactly as before.

_MP_LIB="${BASH_SOURCE[0]%/*}"
# shellcheck source=patch-same.sh
. "$_MP_LIB/patch-same.sh"

# _mp_merges <git-dir> <base-sha> <before-sha> <head-sha> — the new commits, one
# per line, when every one is a merge of the base into the PR; rc 1 otherwise.
_mp_merges() {
  local g="$1" base="$2" before="$3" head="$4" list c parents p1 p2 extra n=0
  git -C "$g" merge-base --is-ancestor "$before" "$head" 2>/dev/null || return 1
  list=$(git -C "$g" rev-list "$head" "^$before" "^$base" 2>/dev/null) || return 1
  for c in $list; do
    [[ "$c" =~ ^[0-9a-f]{40}$ ]] || return 1
    parents=$(git -C "$g" rev-list --parents -n 1 "$c" 2>/dev/null) || return 1
    read -r _ p1 p2 extra <<<"$parents"
    [[ "${p1:-}" =~ ^[0-9a-f]{40}$ ]] && [[ "${p2:-}" =~ ^[0-9a-f]{40}$ ]] && [ -z "${extra:-}" ] || return 1
    git -C "$g" merge-base --is-ancestor "$p2" "$base" 2>/dev/null || return 1
    git -C "$g" merge-base --is-ancestor "$p1" "$base" 2>/dev/null && return 1
    printf '%s\n' "$c"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

# _mp_merge_paths <git-dir> <merge> — the paths where the recorded tree differs
# from what git merges its parents to. merge-tree exits 1 on a conflict and
# still prints the tree (with the markers) on line 1; any other rc is a failure.
_mp_merge_paths() {
  local g="$1" c="$2" p1 p2 out rc want
  read -r _ p1 p2 <<<"$(git -C "$g" rev-list --parents -n 1 "$c" 2>/dev/null)"
  out=$(git -C "$g" merge-tree --write-tree "$p1" "$p2" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 1 ] || return 1
  want=$(head -1 <<<"$out")
  [[ "$want" =~ ^[0-9a-f]{40}$ ]] || return 1
  git -C "$g" -c core.quotepath=off diff --no-renames --name-only "$want" "$c" 2>/dev/null
}

# _mp_shas <git-dir> <base-ref> <before> <head> — "base before head" as full
# shas, rc 1 unless all three are commits.
_mp_shas() {
  local b s h
  case "${3:-}" in ''|*[!0]*) ;; *) return 1 ;; esac
  b=$(_ps_sha "$1" "${2:-}") && s=$(_ps_sha "$1" "${3:-}") && h=$(_ps_sha "$1" "${4:-}") || return 1
  printf '%s %s %s' "$b" "$s" "$h"
}

mp_classify() {
  local g="${1:-}" ref="${2:-}" shas base before head how merges c paths any=""
  [ -n "$g" ] && [ -n "$ref" ] || { echo "full bad-args"; return 0; }
  case "${3:-}" in '') echo "full no-before"; return 0 ;; *[!0]*) ;; *) echo "full no-before"; return 0 ;; esac
  shas=$(_mp_shas "$g" "$ref" "${3:-}" "${4:-}") || { echo "full unknown-sha"; return 0; }
  read -r base before head <<<"$shas"
  [ "$before" != "$head" ] || { echo "full same-head"; return 0; }
  git -C "$g" merge-base --is-ancestor "$before" "$head" 2>/dev/null \
    || { echo "full not-a-descendant"; return 0; }
  how=$(patch_same "$g" "$base" "$before" "$head") || how=""
  [ "$how" = main-merge ] && { echo clean; return 0; }
  merges=$(_mp_merges "$g" "$base" "$before" "$head") || { echo "full not-merge-only"; return 0; }
  for c in $merges; do
    paths=$(_mp_merge_paths "$g" "$c") || { echo "full merge-tree-failed"; return 0; }
    [ -n "$paths" ] && any=1
  done
  # Every merge reproduced exactly, yet patch_same did not say so: two readers
  # of one history disagree, and that is not evidence of anything.
  [ -n "$any" ] || { echo "full undecided"; return 0; }
  echo resolved
}

mp_resolved() {
  local g="${1:-}" shas base before head merges c p out=""
  shas=$(_mp_shas "$g" "${2:-}" "${3:-}" "${4:-}") || return 1
  read -r base before head <<<"$shas"
  merges=$(_mp_merges "$g" "$base" "$before" "$head") || return 1
  for c in $merges; do
    p=$(_mp_merge_paths "$g" "$c") || return 1
    out+="$p"$'\n'
  done
  printf '%s' "$out" | awk 'NF && !seen[$0]++'
}

_mp_fork() { # <git-dir> <base-sha> <sha> -> merge-base
  local m
  m=$(git -C "$1" merge-base "$2" "$3" 2>/dev/null) && [[ "$m" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$m"
}

mp_main_files() {
  local g="${1:-}" shas base before head f0 f1
  shas=$(_mp_shas "$g" "${2:-}" "${3:-}" "${4:-}") || return 1
  read -r base before head <<<"$shas"
  f0=$(_mp_fork "$g" "$base" "$before") && f1=$(_mp_fork "$g" "$base" "$head") || return 1
  git -C "$g" -c core.quotepath=off diff --no-renames --name-only "$f0" "$f1" 2>/dev/null
}

mp_pr_files() {
  local g="${1:-}" base head f
  base=$(_ps_sha "$g" "${2:-}") && head=$(_ps_sha "$g" "${3:-}") || return 1
  f=$(_mp_fork "$g" "$base" "$head") || return 1
  git -C "$g" -c core.quotepath=off diff --no-renames --name-only "$f" "$head" 2>/dev/null
}

mp_knob() {
  local v
  v=$(
    # The lib root contract (BH-2613): no literal fallback; an empty root
    # reads this checkout's own lane-gate.sh beside the lib.
    root="${HARNESS:-${H:-}}"; lg=""
    [ -n "$root" ] && lg="$root/bin/lib/lane-gate.sh"
    { [ -n "$lg" ] && [ -r "$lg" ]; } || lg="$_MP_LIB/lane-gate.sh"
    command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lg" ] && . "$lg" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply ci-merge-reuse >/dev/null 2>&1
    printf '%s' "${PR_CI_MERGE_REUSE:-}"
  ) || v=""
  if [ -z "$v" ]; then
    v=$(jq -r '.libs[]? | select(.id == "ci-merge-reuse") | .knobs[]?
               | select(.env == "PR_CI_MERGE_REUSE") | .default // empty' \
          "$_MP_LIB/../../catalog/lanes.d/_lib.ci-merge-reuse.json" 2>/dev/null)
  fi
  case "$v" in
    on|1) echo on ;;
    off|0) echo off ;;
    *) echo "merge-push: PR_CI_MERGE_REUSE='$v' is not on|off; reading it as off" >&2; echo off ;;
  esac
}
