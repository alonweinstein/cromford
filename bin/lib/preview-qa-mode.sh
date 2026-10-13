#!/bin/bash
# bin/lib/preview-qa-mode.sh — BH-3438: which preview QA a project gets.
# Sourced, never executed; defines one function and nothing else.
#
#   preview_qa_mode <project> [conf]
#       prints `signed-out` or `auth` from catalog/preview-qa.conf (or [conf]).
#       An absent file, no row, a malformed row or an unknown mode all print
#       `auth`, which is the behaviour before the registry existed. With no conf
#       argument and no harness root (${HARNESS:-${H:-}} empty) it prints `auth`
#       and returns 1.
# shellcheck shell=bash

preview_qa_mode() {
  local p="${1:-}" conf="${2:-}" root mode
  if [ -z "$conf" ]; then
    root="${HARNESS:-${H:-}}"
    [ -n "$root" ] || { echo auth; return 1; }
    conf="$root/catalog/preview-qa.conf"
  fi
  mode=$(awk -v p="$p" '$1 !~ /^#/ && $1 == p && NF >= 2 { m = $2 } END { print m }' "$conf" 2>/dev/null)
  case "$mode" in
    signed-out) echo signed-out ;;
    *)          echo auth ;;
  esac
}
