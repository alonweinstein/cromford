#!/bin/bash
# bin/lib/failover-drill-common.sh — the shared seams of the failover drill
# (BH-2746, parent #402). Sourced by bin/failover-drill.sh (a BH-402 sibling),
# never run. Defines functions and one constant; sourcing prints nothing.
#
# FD_RENEW_PAUSE_FLAG, relative to $HARNESS. Its content is an integer
#   epoch-seconds deadline: lease renew is paused while now < deadline; an
#   expired, empty or non-integer file is removed and renew proceeds.
#   bin/hub-lease.sh cmd_renew honors it (BH-2750).
# fd_now                  epoch seconds; $FAILOVER_DRILL_NOW when set (test
#                         seam). A non-integer seam value is rc 1, no output.
# fd_iso <epoch>          UTC YYYY-MM-DDTHH:MM:SSZ; rc 1 on empty/non-integer.
# fd_ssh <ip> <cmd...>    $FAILOVER_DRILL_SSH (word-split) root@<ip> <cmd>;
#                         empty ip is rc 2 with no ssh call, else ssh's rc.
# fd_api_get <path>       GET $JOBS_URL<path> through bin/jobs-client.sh's
#                         _jobs_req (loaded in a subshell when the caller has
#                         not). Body on stdout, rc 0 only on a 2xx with a
#                         non-empty body; otherwise _jobs_req's rc (1 outage or
#                         non-2xx, 2 on 404, 9 on 409) or 1 for an empty body.
# fd_alert <msg>          one line to $HARNESS/logs/ALERTS.log.
# fd_proof_set <n> <OK|FAIL|UNPROVEN> <detail>
#                         sets PROOF_<n>_VERDICT / PROOF_<n>_DETAIL; any other
#                         verdict is stored as FAIL. Non-integer n is rc 2.
# fd_proof_line <n> <name>  prints `PROOF <n> <name>: <verdict> — <detail>`;
#                         a proof never set prints `UNPROVEN — not run`.

FD_RENEW_PAUSE_FLAG=flags/hub-lease-renew-paused

fd_now() {
  if [ -n "${FAILOVER_DRILL_NOW:-}" ]; then
    [[ "$FAILOVER_DRILL_NOW" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$FAILOVER_DRILL_NOW"; return 0
  fi
  date -u +%s
}

fd_iso() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 1
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

fd_ssh() {
  local ip="${1:-}"; [ -n "$ip" ] || return 2; shift
  # shellcheck disable=SC2086  # the seam is a command line, split on purpose
  ${FAILOVER_DRILL_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=10} "root@$ip" "$@"
}

fd_api_get() {
  local body rc
  body=$(declare -F _jobs_req >/dev/null \
      || . "${HARNESS:-/root/harness}/bin/jobs-client.sh" >/dev/null 2>&1 || exit 1
    _jobs_req GET "$1"); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  [ -n "$body" ] || return 1
  printf '%s' "$body"
}

fd_alert() {
  printf '%s failover-drill: %s\n' "$(date -u +%FT%TZ)" "$*" >> "${HARNESS:-/root/harness}/logs/ALERTS.log"
}

fd_proof_set() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 2
  local v
  case "${2:-}" in OK|FAIL|UNPROVEN) v="$2" ;; *) v=FAIL ;; esac
  printf -v "PROOF_${1}_VERDICT" '%s' "$v"
  printf -v "PROOF_${1}_DETAIL" '%s' "${3:-}"
}

fd_proof_line() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] || return 2
  local v="PROOF_${1}_VERDICT" d="PROOF_${1}_DETAIL"
  printf 'PROOF %s %s: %s — %s\n' "$1" "${2:-}" "${!v:-UNPROVEN}" "${!d-not run}"
}
