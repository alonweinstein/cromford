#!/bin/bash
# bin/lib/deploy-kind.sh — deploy_kind <project>: how a project's merges reach
# prod, read from the settings row deploy.<project>.kind (BH-3387).
#   github-deployment  a GitHub "Production" deployment exists; poll it (today's path)
#   none               nothing deploys on a merge; deploy-verify skips, never alerts
#   smoke-only         no deployment to poll; the prod smoke curl is the verification
# rc 0 -> one of the three, on stdout
# rc 2 -> no row, or a value that is not one of the three (named once on stderr)
# rc 1 -> outage
# The caller keeps today's behaviour on rc 1 and rc 2: an outage is never a skip.
#
# The client is sourced in a SUBSHELL: bin/jobs-client.sh `exit 1`s the shell
# that sources it when a module is missing (BH-1194), and deploy-verify and
# deploy-request must survive a half-synced box.
deploy_kind() {
  local key v rc=0
  key="deploy.$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]').kind"
  # The root is HARNESS, then H (BH-2613); the entry points own the default.
  # No root is no answer (rc 2): the caller keeps today's deployments poll.
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 2
  v=$(
    [ -r "$h/bin/jobs-client.sh" ] || exit 2
    # shellcheck source=/dev/null
    . "$h/bin/jobs-client.sh" 2>/dev/null || exit 2
    declare -F setting_get >/dev/null 2>&1 || exit 2
    setting_get "$key" 2>/dev/null
  ) || rc=$?
  [ "$rc" = 0 ] || return "$rc"
  case "$v" in
    github-deployment|none|smoke-only) printf '%s\n' "$v"; return 0 ;;
  esac
  echo "deploy_kind: $key has unknown value '$v' (want github-deployment|none|smoke-only); keeping the deployments poll" >&2
  return 2
}
