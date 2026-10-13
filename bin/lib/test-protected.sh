#!/bin/bash
# bin/lib/test-protected.sh — is a suite protected from flaky quarantine? (BH-3686)
#
# Sourced, pure: no network, no clock, no writes.
#
# tp_protected <suite> [root] — rc 0 and one reason line when <suite> is
#   protected, rc 1 and no output when it is not, rc 2 for an empty suite.
#   Root is [root], else ${HARNESS:-${H:-}}. The reasons, checked in order:
#     named list          an exact path in catalog/test-quarantine-protected.txt
#     named glob <g>      a glob line there (exact lines win over any glob)
#     guard tier          a catalog/test-tiers.tsv row with tier `guard`
#     test-impact always  the first field of a catalog/test-impact-always.txt line
#     nightly strict      the first field of a catalog/nightly-strict.txt line
#   The named list is ${TP_PROTECTED_LIST:-<root>/catalog/test-quarantine-protected.txt}.
#   When it cannot be read (missing, unreadable, or no root) EVERY suite is
#   protected: rc 0, reason `protected list unreadable`. A missing secondary
#   catalog is only "no row".
tp_protected() {
  local suite="${1:-}" root="${2:-${HARNESS:-${H:-}}}" list g _
  suite="${suite#./}"
  [ -n "$suite" ] || return 2
  list="${TP_PROTECTED_LIST:-}"
  [ -n "$list" ] || { [ -n "$root" ] && list="$root/catalog/test-quarantine-protected.txt"; }
  if [ -z "$list" ] || [ ! -f "$list" ] || [ ! -r "$list" ]; then
    echo "protected list unreadable"; return 0
  fi
  while read -r g _; do
    case "$g" in ''|'#'*) continue ;; esac
    [ "$g" = "$suite" ] && { echo "named list"; return 0; }
  done < "$list"
  while read -r g _; do
    case "$g" in ''|'#'*) continue ;; *[*?[]*) ;; *) continue ;; esac
    # shellcheck disable=SC2254 # the line IS a glob, on purpose (tt_hit idiom)
    case "$suite" in $g) echo "named glob $g"; return 0 ;; esac
  done < "$list"
  [ -n "$root" ] || return 1
  if [ -r "$root/catalog/test-tiers.tsv" ] && awk -F'\t' -v s="$suite" \
       '!/^#/ && $1 == s && $2 == "guard" { f = 1 } END { exit !f }' "$root/catalog/test-tiers.tsv"; then
    echo "guard tier"; return 0
  fi
  _tp_first_field "$suite" "$root/catalog/test-impact-always.txt" && { echo "test-impact always"; return 0; }
  _tp_first_field "$suite" "$root/catalog/nightly-strict.txt" && { echo "nightly strict"; return 0; }
  return 1
}

# _tp_first_field <suite> <file> — rc 0 when a non-comment line's first field is <suite>.
_tp_first_field() {
  [ -r "$2" ] || return 1
  awk -v s="$1" '!/^#/ && $1 == s { f = 1 } END { exit !f }' "$2"
}
