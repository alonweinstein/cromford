# shellcheck shell=bash
# bin/lib/internal-token.sh — the ONE definition of which env-file variable is a
# project's internal board API token and which is its app base URL (BH-1953).
# Sourced, never executed. Defines only: no `set`, no output, no reads, no ALERTS
# on source, and safe under the caller's `set -euo pipefail`. Functions print
# variable NAMES, never values.
#
# The trailing `=` is part of both patterns: without it a neighbouring
# FOO_INTERNAL_API_TOKEN_OLD=… would count as a second token.
INTERNAL_TOKEN_RE='^[A-Z0-9_]*INTERNAL_API_TOKEN='
APP_BASE_RE='^[A-Z0-9_]+_(API|APP)_BASE='

# env_vars_matching <ERE> <envfile> — every matching NAME (leading `export`
# stripped), in file order, one per line, duplicates kept.
env_vars_matching() {
  sed -E 's/^[[:space:]]*export[[:space:]]+//' "$2" 2>/dev/null | grep -oE "$1" | sed 's/=$//'
}

# _env_one_var <ERE> <envfile> — rc 0 + the single NAME; rc 1 none; rc 2 two or
# more (prints nothing: a caller never guesses which one is live).
_env_one_var() {
  local names n
  names=$(env_vars_matching "$1" "$2" || true)
  n=$(printf '%s' "$names" | grep -c . || true)
  [ "${n:-0}" -eq 0 ] && return 1
  [ "$n" -gt 1 ] && return 2
  printf '%s\n' "$names"
}

internal_token_vars() { env_vars_matching "$INTERNAL_TOKEN_RE" "$1"; }
internal_token_var()  { _env_one_var "$INTERNAL_TOKEN_RE" "$1"; }
app_base_var()        { _env_one_var "$APP_BASE_RE" "$1"; }
