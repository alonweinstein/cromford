#!/bin/bash
# bin/lib/scratch-closure-grace.sh — BH-4632. The grace the BH-4552
# scratch-closure lint (tests/lib/scratch-closure-lint.sh lint()) gives a suite
# raised by a branch cut BEFORE the lint landed. Such a branch passed its own PR
# checks (the corpus does not run on an ordinary PR) and could not have known
# about the lint; without this it turns its Mergify batch draft red and ejects
# every other member. Sourced, never executed; it reads git and prints, and
# never writes state.
#
# A raised suite is graced (WARN, not red) only when ALL of these hold:
#   1. L, the OLDEST commit on the upstream (RATCHET_BASE / TI_BASE, origin/main
#      or main, the newest that resolves) that ADDED the lint's path, is found
#      from git and is an ancestor of that upstream. Never a hardcoded sha.
#   2. every PR head that touches the suite forked from the upstream at a commit
#      that does NOT contain L. A rebase onto, or a merge of, post-lint main ends
#      the grace; so does any post-lint head touching the same suite.
#   3. fewer than scratch_closure_grace_days days (lib.scratch-closure-grace,
#      default 14 in the registry, 0 = off) have passed since L's committer time.
#   4. the suite has no uncommitted or untracked change: the working tree
#      belongs to no head, so a builder's own new hand-copy is never graced.
#
# THE HEADS. On an ordinary run it is HEAD. On a Mergify batch draft
# (GITHUB_HEAD_REF = mergify/merge-queue/*) it is the member PR heads: the second
# parents of the merges on the draft's first-parent chain down to the base,
# starting from HEAD^2 when HEAD is GitHub's test merge (first parent = the
# base). No member found falls back to HEAD, which is post-lint: red (fail closed).
#
#   scg_upstream <repo>                     the upstream tip, rc 1 when none resolves
#   scg_lint_commit <repo> <ref> <lint-rel> L, rc 1 (and nothing printed) when absent
#   scg_heads <repo> <base>                 the head list, one sha per line
#   scg_grace_days                          the knob (lane_knob, libs scope)
#   scg_grace <repo> <base> <suite-rel> <lint-rel> [<n>]
#                                           rc 0 = graced, printing the one grace
#                                           line; rc 1 = judged as today, silent

scg_upstream() {
  local repo="$1" c up=""
  for c in "${RATCHET_BASE:-}" "${TI_BASE:-}" origin/main main; do
    [ -n "$c" ] || continue
    git -C "$repo" cat-file -e "$c^{commit}" 2>/dev/null || continue
    c=$(git -C "$repo" rev-parse "$c^{commit}") || continue
    if [ -z "$up" ] || git -C "$repo" merge-base --is-ancestor "$up" "$c"; then up="$c"; fi
  done
  [ -n "$up" ] || return 1
  printf '%s\n' "$up"
}

scg_lint_commit() {
  local repo="$1" ref="$2" rel="$3" adds=() l
  mapfile -t adds < <(git -C "$repo" log --diff-filter=A --format=%H "$ref" -- "$rel" 2>/dev/null)
  [ "${#adds[@]}" -gt 0 ] || return 1
  l="${adds[${#adds[@]}-1]}"
  git -C "$repo" merge-base --is-ancestor "$l" "$ref" 2>/dev/null || return 1
  printf '%s\n' "$l"
}

scg_heads() {
  local repo="$1" base="$2" start=HEAD p1 line parts=() n=0
  case "${GITHUB_HEAD_REF:-}" in
    mergify/merge-queue/*)
      p1=$(git -C "$repo" rev-parse -q --verify "HEAD^1" 2>/dev/null) || p1=""
      if [ "$p1" = "$base" ] && git -C "$repo" rev-parse -q --verify "HEAD^2" >/dev/null 2>&1; then start="HEAD^2"; fi
      while read -r line; do
        read -r -a parts <<< "$line"
        [ "${#parts[@]}" -ge 3 ] || continue
        printf '%s\n' "${parts[2]}"; n=$((n+1))
      done < <(git -C "$repo" rev-list --first-parent --parents "$start" "^$base" 2>/dev/null)
      [ "$n" -gt 0 ] && return 0 ;;
  esac
  git -C "$repo" rev-parse HEAD
}

scg_grace_days() {
  local _LG_KIND=libs v
  command -v lane_knob >/dev/null 2>&1 || return 1
  v=$(lane_knob scratch-closure-grace SCRATCH_CLOSURE_GRACE_DAYS)
  case "$v" in ''|*[!0-9]*) v=$(SCRATCH_CLOSURE_GRACE_DAYS='' lane_knob scratch-closure-grace SCRATCH_CLOSURE_GRACE_DAYS) ;; esac
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$v"
}

scg_grace() {
  local repo="$1" base="$2" rel="$3" lint_rel="$4" n="${5:-}" up l h fork days lct end untracked first="" touched=0
  # 4. the working tree is nobody's head.
  git -C "$repo" diff --quiet HEAD -- "$rel" 2>/dev/null || return 1
  untracked=$(git -C "$repo" ls-files --others --exclude-standard -- "$rel" 2>/dev/null)
  [ -z "$untracked" ] || return 1
  # 1. L, from git.
  up=$(scg_upstream "$repo") || return 1
  l=$(scg_lint_commit "$repo" "$up" "$lint_rel") || return 1
  # 3. the window, from L's committer time.
  days=$(scg_grace_days) || return 1
  [ "$days" -gt 0 ] || return 1
  lct=$(git -C "$repo" log -1 --format=%ct "$l") || return 1
  end=$(( lct + days * 86400 ))
  [ "$(date -u +%s)" -lt "$end" ] || return 1
  # 2. every head that touches the suite forked before L.
  while read -r h; do
    [ -n "$h" ] || continue
    fork=$(git -C "$repo" merge-base "$h" "$up" 2>/dev/null) || return 1
    git -C "$repo" diff --quiet "$fork" "$h" -- "$rel" 2>/dev/null && continue
    touched=1
    git -C "$repo" merge-base --is-ancestor "$l" "$fork" && return 1
    [ -n "$first" ] || first="$h"
  done < <(scg_heads "$repo" "$base")
  [ "$touched" = 1 ] || return 1
  printf 'WARN scratch-closure grace: %s +%s hand-copies (head %s cut before lint %s; grace ends %s)\n' \
    "$rel" "${n:-?}" "${first:0:12}" "${l:0:12}" "$(date -u -d "@$end" +%Y-%m-%dT%H:%MZ)"
}
