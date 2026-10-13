# shellcheck shell=bash
# bin/lib/board-creds.sh — the ONE way a board caller resolves, and REFUSES, a
# project's internal token and app base variable (BH-1955). Sourced, never
# executed: defines functions only, no `set`, no output on source, so it is safe
# under a caller's `set -uo pipefail`.
#
# bin/lib/internal-token.sh (BH-1953) says WHICH variable is the token and which
# is the base. This file adds what every caller must then do the same way: on
# no match, a duplicate, or an unreadable env file, print nothing, write ONE
# ALERTS line, and return 1 — never pick the first of two tokens (`head -1`
# picks a rotated-but-not-deleted token and the 401 reads as an outage).
#
# The dedup flag is flags/alerted-token-<project>-<YYYYMMDD>, the same one
# bin/internal-token-for.sh writes, so every caller and the sweeps together say
# it at most once per project per day. Variable NAMES only, never values.
#
#   board_token_var <project> <envfile> <caller>  -> NAME, rc 0 | rc 1 after the alert
#   board_base_var  <project> <envfile> <caller>  -> NAME, rc 0 | rc 1 after the alert

# shellcheck source=bin/lib/internal-token.sh
. "$(dirname "${BASH_SOURCE[0]}")/internal-token.sh" 2>/dev/null || true

# _bc_alert <project> <reason> <caller> — flag first, then append, so a crash
# between the two drops a line rather than doubling one.
_bc_alert() {
  local h="${HARNESS:-/root/harness}" flag
  flag="$h/flags/alerted-token-$1-$(date -u +%Y%m%d)"
  [ -f "$flag" ] && return 0
  mkdir -p "$h/flags" "$h/logs" 2>/dev/null; touch "$flag" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [internal-token] $1: $2 ($3) — board calls for this project are refused until it is fixed." >> "$h/logs/ALERTS.log" 2>/dev/null
  return 0
}

# _bc_resolve <what> <ERE-var-name> <one-fn> <project> <envfile> <caller>
_bc_resolve() {
  local what="$1" re="$2" one="$3" p="$4" f="$5" c="${6:-unknown}" name rc names n
  if ! command -v "$one" >/dev/null 2>&1; then
    _bc_alert "$p" "bin/lib/internal-token.sh is missing or unreadable" "$c"; return 1
  fi
  [ -r "$f" ] || { _bc_alert "$p" "$f is missing or unreadable" "$c"; return 1; }
  name=$("$one" "$f") && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$name" ]; then printf '%s\n' "$name"; return 0; fi
  if [ "$rc" -eq 1 ]; then
    _bc_alert "$p" "$f defines no $what" "$c"; return 1
  fi
  names=$(env_vars_matching "${!re}" "$f" || true)
  n=$(printf '%s' "$names" | grep -c . || true)
  _bc_alert "$p" "$f defines $n ${what} variables ($(printf '%s' "$names" | paste -sd, -)) — refusing to guess which one is live" "$c"
  return 1
}

board_token_var() { _bc_resolve '*_INTERNAL_API_TOKEN' INTERNAL_TOKEN_RE internal_token_var "$@"; }
board_base_var()  { _bc_resolve '*_API_BASE or *_APP_BASE' APP_BASE_RE app_base_var "$@"; }

# board_env_value <NAME> <envfile> — that variable's value: the exported one
# first (a caller that sourced the env file may have overridden it), else the
# literal in the file (the LAST one, as a sourced file would leave it) with one
# layer of quotes stripped. Prints nothing when
# neither has it. Only ever called with a NAME the resolver above returned.
board_env_value() {
  local v="${!1:-}"
  if [ -z "$v" ]; then
    v=$(sed -E 's/^[[:space:]]*export[[:space:]]+//' "$2" 2>/dev/null | sed -n "s/^$1=//p" | tail -1)
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  fi
  printf '%s' "$v"
}
