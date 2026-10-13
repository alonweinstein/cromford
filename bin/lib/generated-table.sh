#!/bin/bash
# shellcheck shell=bash
# bin/lib/generated-table.sh — BH-1680: the target repo's `## Generated files`
# table, read for PATHS, and the builder-side strip that keeps those paths out
# of a build's commits. Sourced, never run; sourcing defines functions only.
#
# WHY. A path the table declares is regenerated on merge by the conductor
# (bin/lib/rebase-job.sh step 6b through mc_regen_generated, and the
# bin/batch-resolve.sh union). A build that commits one as well only buys a
# conflict on a hunk no ticket is about. So bin/run-build.sh's
# `# >>> generated no-commit` block resets them to the merge-base right after
# the spec artifact commit, before the gates, the review and the first push —
# the approval is bound to the stripped head, never rewritten after it.
#
# THE TABLE is read the way mc_regen_table (bin/lib/mc/rebase.sh) and
# regen_table (bin/batch-resolve.sh) read it: the union of AGENT_ARCHITECTURE.md,
# docs/verification-map/README.md and docs/verification-map/index/tail.md at a
# ref, backticks off, separator rows and path cells with no slash or dot
# skipped, deduped. Those two readers are deliberately not moved onto this one.
#
# THE OPT-OUT: a row with a cell after the second that reads `committed`
# (case-insensitive, backticks allowed) is a render the repo keeps in git
# because its own CI checks it — cromford's rules/CLAUDE.md (BH-1336). It
# is still a declared path; it is never stripped. The existing readers ignore
# cells past the second, so the column changes nothing for them.

# _gen_table_rows <repo-dir> <ref> -> "<path>\t<committed 0|1>" per declared row.
_gen_table_rows() {
  local dir="${1:-.}" ref="${2:-HEAD}" f
  [ -d "$dir" ] || return 0
  for f in AGENT_ARCHITECTURE.md docs/verification-map/README.md docs/verification-map/index/tail.md; do
    git -C "$dir" show "$ref:$f" 2>/dev/null | awk '
      tolower($0) ~ /^#+[ \t]*.*generated files/ { sec=1; next }
      sec && /^#+ / { exit }
      sec && /^\|/ {
        line = $0
        sub(/^\|/, "", line)
        n = split(line, c, "|")
        if (n < 2) next
        p = c[1]; cmd = c[2]
        gsub(/`/, "", p);   gsub(/^[ \t]+|[ \t]+$/, "", p)
        gsub(/`/, "", cmd); gsub(/^[ \t]+|[ \t]+$/, "", cmd)
        if (p == "" || cmd == "") next
        if (p ~ /^-+$/ || cmd ~ /^-+$/) next
        if (p !~ /[\/.]/) next
        kept = 0
        for (i = 3; i <= n; i++) {
          x = c[i]; gsub(/`/, "", x); gsub(/^[ \t]+|[ \t]+$/, "", x)
          if (tolower(x) == "committed") kept = 1
        }
        print p "\t" kept
      }'
  done
  return 0
}

# gen_table_paths <repo-dir> <ref> -> every declared path (or glob), one per line.
gen_table_paths() {
  _gen_table_rows "$@" | cut -f1 | awk 'NF && !seen[$0]++'
}

# gen_nocommit_paths <repo-dir> <ref> -> the declared paths a build must not
#   commit: every row except those flagged `committed`. A path flagged in ANY
#   home is kept, so two homes disagreeing never strips a committed render.
gen_nocommit_paths() {
  _gen_table_rows "$@" | awk -F'\t' '
    NF { if (!($1 in k)) { order[++n] = $1; k[$1] = 0 } if ($2 == 1) k[$1] = 1 }
    END { for (i = 1; i <= n; i++) if (!k[order[i]]) print order[i] }'
}

# gen_path_matches <path> <pattern> — rc 0 when the declared row covers the
#   path: equal, or a shell-case glob over the WHOLE path, the way the train's
#   regen_cmd_for matches it. Never a prefix or suffix match.
gen_path_matches() {
  [ "$1" = "$2" ] && return 0
  # shellcheck disable=SC2254
  case "$1" in $2) return 0 ;; esac
  return 1
}

# _gen_mb <base-ref> -> merge-base(<base>, HEAD) in cwd, or rc 1.
_gen_mb() { git merge-base "$1" HEAD 2>/dev/null; }

# gen_nocommit_strip <base-ref> <out-list> [<ticket>] — in the build worktree
#   (cwd): reset every changed path the base's table declares (and does not
#   flag committed) to merge-base(<base>, HEAD), as ONE commit. Prints one
#   status sentence. ALWAYS rc 0 — a strip that cannot happen leaves the build
#   exactly as it was.
#
#   <out-list> gains the stripped paths ONLY after the committed tree proves
#   them gone (`git diff --quiet mb HEAD -- <paths>`); it is never truncated, so
#   a resumed build keeps what an earlier run of the same build stripped.
gen_nocommit_strip() {
  local base="${1:-}" list="${2:-}" key="${3:-build}" mb changed decl p d rest=0
  local -a kept=()
  [ -n "$base" ] || return 0
  if ! mb=$(_gen_mb "$base"); then
    echo "no merge-base with $base — nothing stripped"
    return 0
  fi
  decl=$(gen_nocommit_paths . "$base")
  [ -n "$decl" ] || return 0
  changed=$(git diff --name-only --no-renames "$mb" HEAD 2>/dev/null)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local hit=""
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      gen_path_matches "$p" "$d" && { hit=1; break; }
    done <<<"$decl"
    if [ -n "$hit" ]; then
      kept+=("$p")
    else
      case "$p" in .harness/specs/*) ;; *) rest=$((rest + 1)) ;; esac
    fi
  done <<<"$changed"
  [ "${#kept[@]}" -gt 0 ] || return 0
  if [ "$rest" = 0 ]; then
    echo "skipped: the diff is only declared generated files (${kept[*]}) — the ticket is about them, so they stay"
    return 0
  fi
  local ok=1
  for p in "${kept[@]}"; do
    if git cat-file -e "$mb:$p" 2>/dev/null; then
      git checkout -q "$mb" -- "$p" 2>/dev/null || { ok=0; break; }
    else
      git rm -q -f -- "$p" >/dev/null 2>&1 || { ok=0; break; }
    fi
  done
  if [ "$ok" = 1 ] && git -c commit.gpgsign=false commit -q --no-verify \
       -m "chore($key): drop declared generated files (regenerated on merge)" -- "${kept[@]}" >/dev/null 2>&1; then
    if git diff --quiet "$mb" HEAD -- "${kept[@]}" 2>/dev/null; then
      { [ -s "$list" ] && cat "$list"; printf '%s\n' "${kept[@]}"; } | awk 'NF && !seen[$0]++' > "$list.tmp" \
        && mv -f "$list.tmp" "$list"
      echo "stripped ${kept[*]} — reset to ${mb:0:8} in one commit"
    else
      echo "strip commit landed but ${kept[*]} still differ from ${mb:0:8} — not claimed"
    fi
    return 0
  fi
  # The reset or the commit failed: put exactly those paths back as HEAD has
  # them, index and tree, and touch nothing else.
  git reset -q HEAD -- "${kept[@]}" >/dev/null 2>&1
  git checkout -q HEAD -- "${kept[@]}" >/dev/null 2>&1
  echo "strip FAILED for ${kept[*]} — restored to HEAD, the build commits them as before"
  return 0
}

# gen_nocommit_line <base-ref> <list> -> the PR body line, or nothing. Names only
#   listed paths the committed tree still matches merge-base on, so a path that
#   came back into the diff is never claimed as not committed.
gen_nocommit_line() {
  local mb p out=""
  [ -s "${2:-}" ] || return 0
  mb=$(_gen_mb "$1") || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    git diff --quiet "$mb" HEAD -- "$p" 2>/dev/null || continue
    out="${out:+$out, }\`$p\`"
  done < "$2"
  [ -n "$out" ] || return 0
  printf 'Generated files not committed: %s — regenerated on merge by the conductor.\n' "$out"
}
