#!/bin/bash
# bin/lib/dup-main.sh — BH-5802: work that is already on main is seen before a
# plan is built and before a PR is reviewed. Sourced; defines functions only.
#
# WHY. Three lead BLOCKs found a PR duplicating main: #4701 would have deleted
# the cromford guardrails c139f7b87 had shipped, #4342 re-added BH-4329's check
# in a looser form that would win, and #4332 carried worker files #4883 had
# already shipped. A re-added file with the same content merges CLEAN, so the
# conflict checks never saw any of them.
#
#   dup_main_ticket <repo> <base-ref> <key> <since-iso>
#     "<sha12> <subject>" for each commit on <base-ref> since the ticket was
#     filed whose message names <key> as a word (BH-77 never matches BH-770).
#     Nothing when <since-iso> is empty: no filing time, no guess.
#   dup_main_plan_note <repo> <base-ref> <key> <since-iso>
#     The PLAN prompt sentence: search main since the filing time by key, files
#     and symbols; if the work is done, the plan's first line is the parked
#     marker `BLOCKED: already done on main by <sha>`, which PLAN_IS_BLOCKED
#     (bin/run-build.sh) stops on. Names the key's commits when there are any.
#   dup_main_pr <repo> <base-ref> <head>
#     "<sha12> <path>" for the first duplicate in a PR head: a file the PR adds
#     that the base also added after the merge base and still has, or
#     DUP_MAIN_MIN_LINES (5) identical non-trivial added lines in a file both
#     changed (the sha is the commit that added them). rc 0 found,
#     1 none, 2 cannot run (a head or base the clone does not have).
#
# Reads git objects already in <repo>; never fetches.

DUP_MAIN_MIN_LINES="${DUP_MAIN_MIN_LINES:-5}"

dup_main_ticket() {
  local repo="$1" base="$2" key="$3" since="${4:-}" re
  [ -n "$since" ] && [ -n "$key" ] || return 0
  [[ "$key" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || return 0
  re="(^|[^A-Za-z0-9-])${key}([^0-9]|$)"
  git -C "$repo" log "$base" --since="$since" -E --grep="$re" --format='%H%x09%s' 2>/dev/null \
    | awk -F'\t' '{print substr($1, 1, 12) " " $2}'
}

dup_main_plan_note() {
  local repo="$1" base="$2" key="$3" since="${4:-}" hits
  [ -n "$since" ] || return 0
  hits=$(dup_main_ticket "$repo" "$base" "$key" "$since" | head -n 5 | paste -sd ';' -)
  printf 'ALREADY ON MAIN? (BH-5802) Before you plan, check that %s does not already have this change: search it since the ticket was filed, by the files you would touch and their key symbols (git log %s --since=%s -- <file>; git log %s -S<symbol>).' \
    "$base" "$base" "$since" "$base"
  [ -n "$hits" ] && printf ' These commits there already name %s: %s.' "$key" "$hits"
  printf " If the work is already done, plan.md's FIRST line is 'BLOCKED: already done on main by <sha> (<what it did>)' and nothing is built. If part of it is done, plan only what is left and name the commits that did the rest. "
}

# A line worth comparing: 4+ characters once trimmed, not only punctuation, not
# a bare shell keyword. Two files ending in `fi` and `}` are not duplicates.
_dup_main_added() { # _dup_main_added <repo> <from> <to> <path> -> the added lines, trimmed, sorted unique
  git -C "$1" diff --no-renames -U0 "$2" "$3" -- "$4" 2>/dev/null \
    | awk '/^\+\+\+ /{next} /^\+/{l=substr($0,2); gsub(/^[ \t]+|[ \t]+$/, "", l)
             if (length(l) < 4) next
             if (l ~ /^[][{}();,:.|&<>"'"'"'`=+*-]*$/) next
             if (l ~ /^(fi|done|esac|then|else|do|return|exit)( [0-9]+)?;?$/) next
             print l}' | LC_ALL=C sort -u
}

dup_main_pr() {
  local repo="$1" base="$2" head="$3" mb st path sha n shared
  git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null || return 2
  git -C "$repo" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || return 2
  mb=$(git -C "$repo" merge-base "$base" "$head" 2>/dev/null) || return 2
  # 1. a file the PR adds that the base also added after the merge base
  while IFS=$'\t' read -r st path; do
    [ "$st" = A ] || continue
    # main must still have it: a file main added and then deleted is not one
    git -C "$repo" cat-file -e "$base:$path" 2>/dev/null || continue
    sha=$(git -C "$repo" log -1 --format=%H --diff-filter=A "$mb..$base" -- "$path" 2>/dev/null)
    [ -n "$sha" ] && { printf '%s %s\n' "${sha:0:12}" "$path"; return 0; }
  done < <(git -C "$repo" diff --no-renames --name-status "$mb" "$head" 2>/dev/null)
  # 2. the same hunk: enough identical non-trivial added lines in a file both changed
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    shared=$(LC_ALL=C comm -12 <(_dup_main_added "$repo" "$mb" "$head" "$path") <(_dup_main_added "$repo" "$mb" "$base" "$path"))
    n=$(grep -c . <<<"$shared")
    if [ "${n:-0}" -ge "$DUP_MAIN_MIN_LINES" ]; then
      # The commit that added the shared lines (the oldest that changed the
      # first one's count), not the newest commit that touched the file.
      sha=$(git -C "$repo" log --reverse --format=%H -S"${shared%%$'\n'*}" "$mb..$base" -- "$path" 2>/dev/null | awk 'NR == 1')
      [ -n "$sha" ] || sha=$(git -C "$repo" log -1 --format=%H "$mb..$base" -- "$path" 2>/dev/null)
      printf '%s %s\n' "${sha:0:12}" "$path"; return 0
    fi
  done < <(LC_ALL=C comm -12 <(git -C "$repo" diff --no-renames --name-only "$mb" "$head" 2>/dev/null | LC_ALL=C sort) \
                              <(git -C "$repo" diff --no-renames --name-only "$mb" "$base" 2>/dev/null | LC_ALL=C sort))
  return 1
}
