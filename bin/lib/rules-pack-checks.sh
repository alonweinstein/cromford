#!/bin/bash
# bin/lib/rules-pack-checks.sh — the rules pack's built-in checks (BH-3510).
# Sourced, never executed. Functions only. No root default (BH-2613 rule 4):
# the tree and the base are arguments. bin/rules-pack.sh runs each one for a
# catalog row of kind `builtin`: rc 0 clean, 1 findings (one per stdout line,
# `<path>: <why>`), 125 could not run.
#
# rp_grep_q <tree>
#   tests/*.sh lines that pipe a file-grep into `grep -q`, the shape that
#   flakes under pipefail (the regex is rollup-crash-loud-test.sh section 5).
#
# rp_model_id_delta <tree> <base>
#   `+` lines of `git diff <base>` over bin/ catalog/ worker/ (the price and
#   slug maps excluded, as alert-triage-runners R6 and triage-route-off-grok S7
#   exclude them) that carry a model id literal. Diffs the working tree, as
#   R6/S7 do. A worker whose schema is composed (BH-4987: worker/<w>/schema.d/
#   in the tree or at the base) is judged as ONE logical file per side instead:
#   its schema.d/ fragments in name order when it has them, else its schema.sql.
#   The model-id lines of the two sides are compared as a multiset, so a seed
#   row moved from schema.sql into a fragment, or between fragments, cancels
#   out, and a line that is new on the logical file is a finding on the
#   fragment that holds it, with or without a re-rendered schema.sql.

rp_grep_q() {
  local hits p n=0
  hits=$(grep -ln 'grep [^|]*"\$[A-Z_]*" *| *grep -q' "$1"/tests/*.sh 2>/dev/null)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "${p#"$1"/}: pipes a file-grep into grep -q (flakes under pipefail; rollup-crash-loud section 5)"
    n=$((n+1))
  done <<< "$hits"
  [ "$n" -eq 0 ]
}

rp_model_id_delta() {
  local d l path="" n=0 w f t=""
  local -a ws=() ex=()
  # Bracketed so this file never matches its own pattern.
  local re='claude-[a-z]+-[0-9]|grok-[0-9]|gpt[-]|accounts/fireworks/model[s]'
  [ -n "${2:-}" ] || return 125
  # The composed workers: a schema.d/ in the tree or at the base.
  for f in "$1"/worker/*/schema.d; do
    [ -d "$f" ] || continue
    w=${f%/schema.d}; ws+=("${w##*/}")
  done
  while IFS= read -r w; do
    w=${w#worker/}
    git -C "$1" cat-file -e "$2:worker/$w/schema.d" 2>/dev/null || continue
    case " ${ws[*]} " in *" $w "*) ;; *) ws+=("$w") ;; esac
  done < <(git -C "$1" ls-tree -d --name-only "$2" worker/ 2>/dev/null)
  for w in "${ws[@]}"; do ex+=(":(exclude)worker/$w/schema.sql" ":(exclude)worker/$w/schema.d"); done
  d=$(git -C "$1" diff "$2" -- bin catalog worker \
        ':(exclude)catalog/model-prices.json' ':(exclude)catalog/model-slugs.json' "${ex[@]}") || return 125
  while IFS= read -r l; do
    case "$l" in
      '+++ b/'*) path=${l#+++ b/}; continue ;;
      '+++'*) continue ;;
      +*) [[ $l =~ $re ]] || continue
          echo "$path: adds a model id literal (R6/S7): ${l#+}"; n=$((n+1)) ;;
    esac
  done <<< "$d"
  [ "${#ws[@]}" -eq 0 ] || t=$(mktemp -d "${TMPDIR:-/tmp}/rules-pack.mid.XXXXXX") || return 125
  for w in "${ws[@]}"; do
    # The base side: the logical file's model-id lines.
    if git -C "$1" cat-file -e "$2:worker/$w/schema.d" 2>/dev/null; then
      while IFS= read -r f; do
        git -C "$1" show "$2:worker/$w/schema.d/$f" 2>/dev/null
      done < <(git -C "$1" ls-tree --name-only "$2:worker/$w/schema.d" 2>/dev/null | LC_ALL=C sort)
    else
      git -C "$1" show "$2:worker/$w/schema.sql" 2>/dev/null
    fi | { grep -E "$re" || true; } > "$t/base"
    # The tree side, `<path>\t<line>` in composition order.
    if [ -d "$1/worker/$w/schema.d" ]; then
      while IFS= read -r f; do
        awk -v p="worker/$w/schema.d/$f" -v re="$re" '$0 ~ re { print p "\t" $0 }' "$1/worker/$w/schema.d/$f"
      done < <(for f in "$1/worker/$w/schema.d"/*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done | LC_ALL=C sort)
    elif [ -f "$1/worker/$w/schema.sql" ]; then
      awk -v p="worker/$w/schema.sql" -v re="$re" '$0 ~ re { print p "\t" $0 }' "$1/worker/$w/schema.sql"
    fi > "$t/tree"
    # Multiset: each base line cancels one equal tree line; what is left is new.
    while IFS= read -r l; do
      echo "$l"; n=$((n+1))
    done < <(awk -F'\t' -v b="$t/base" '
      FILENAME == b { have[$0]++; next }
      { l = substr($0, length($1) + 2)
        if (have[l] > 0) { have[l]--; next }
        print $1 ": adds a model id literal (R6/S7): " l }' "$t/base" "$t/tree")
  done
  [ -z "$t" ] || { rm -f "$t/base" "$t/tree"; rmdir "$t"; }
  [ "$n" -eq 0 ]
}
