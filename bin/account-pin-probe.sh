#!/bin/bash
# bin/account-pin-probe.sh [--alert] <project>... — can THIS box resolve the
# Claude account each project is pinned to (BH-3559)?
#
# One line per project, never a token:
#   <project> unpinned                 no account.<project> pin, or `shared`
#   <project> <label> ok file          <env dir>/accounts.d/<label>.env has a token
#   <project> <label> ok live          the live claude token's fp label is the pin
#                                      or an alias of it (catalog/account-aliases.json)
#   <project> <label> UNRESOLVABLE     neither: agent-call refuses this project's
#                                      claude rung on this box with rc 76
# Exit 1 when any project is UNRESOLVABLE, else 0. Each line is appended with a
# timestamp to logs/account-pin-probe.log.
#
# The env is loaded per project the way run-build.sh loads it (global.env, then
# <project>.env), so the live token is the one that project's lanes run on. No
# model is called: the answer is a file check and an fp comparison.
#
# --alert: UNRESOLVABLE raises the same deduped warn lane-alert agent-call raises
# on a refusal (project_account_alert_unavailable), and ok resolves it.
# bin/claude-auth-check.sh runs this hourly on the hub and, over ssh, on each
# pinned project's owning box.
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
ALERT=0
[ "${1:-}" = --alert ] && { ALERT=1; shift; }
[ "$#" -gt 0 ] || { echo "usage: account-pin-probe.sh [--alert] <project>..." >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/project-account.sh"
[ -r "$LIB" ] || LIB="$H/bin/lib/project-account.sh"
[ -r "$LIB" ] || { echo "account-pin-probe: no project-account lib" >&2; exit 2; }
. "$HERE/lib/env-path.sh" 2>/dev/null || . "$H/bin/lib/env-path.sh" || exit 2
HENV=$(harness_env_dir "$H")
mkdir -p "$H/logs" 2>/dev/null

RC=0
for P in "$@"; do
  case "$P" in ''|*[!A-Za-z0-9._-]*) echo "account-pin-probe: bad project name" >&2; RC=2; continue ;; esac
  LINE=$(
    set -a
    { . "$HENV/global.env"; [ -f "$HENV/$P.env" ] && . "$HENV/$P.env"; } >/dev/null 2>&1
    set +a
    . "$LIB" >/dev/null 2>&1 || { echo "$P ? UNRESOLVABLE"; exit 1; }
    { command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply project-account; } >/dev/null 2>&1
    L=$(account_label_for_project "$P" 2>/dev/null)
    if [ -z "$L" ]; then echo "$P unpinned"; exit 0; fi
    if project_account_exports "$P" >/dev/null 2>&1; then S="ok file"
    elif project_account_live_matches "$L"; then S="ok live"
    else S=UNRESOLVABLE; fi
    echo "$P $L $S"
    if [ "$ALERT" = 1 ]; then
      if [ "$S" = UNRESOLVABLE ]; then project_account_alert_unavailable "$P" "$L" probe
      else project_account_alert_resolve "$P"; fi
    fi
    [ "$S" != UNRESOLVABLE ]
  ) || RC=1
  printf '%s\n' "$LINE"
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$LINE" >> "$H/logs/account-pin-probe.log" 2>/dev/null
done
exit "$RC"
