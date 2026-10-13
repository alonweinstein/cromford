#!/bin/bash
# bin/lib/endpoints.sh — BH-1937 (BH-1511.0): ONE resolver for the URLs the
# harness calls. Sourced, never executed; defines a function, runs nothing.
#
#   url=$(endpoint_url <service>) || …   # stdout the URL, rc 0
#                                        # or empty stdout, one stderr line, rc 1
#
# <service> is [a-z0-9-] (no leading -). Its knob is ENDPOINT_<SERVICE> (upper
# case, - becomes _) in the registry lib `endpoint-<service>` (a
# catalog/lanes.d/_lib.endpoint-<service>.json), keyed
# lib.endpoint-<service>.endpoint_<service>. The value comes from
# bin/lib/lane-gate.sh's lib_env_apply and nothing else: operator row > cached
# row (logged) > env > registry default. There is NO literal fallback: a URL
# nobody configured is rc 1, never a guess.
#
# Two properties of lib_env_apply decide which of those rungs a real endpoint
# knob can reach:
#   - endpoint knobs register `settable: false` (BH-1165: a URL a root lane
#     sends `Bearer $SECRET` to is not editable from the console), and rows are
#     never read for those, so only the env and the registry default answer;
#   - the registry default is applied only to `required: true` knobs, so an
#     endpoint knob registers required. With nothing answering, lib_env_apply
#     writes its daily FAIL CLOSED ALERTS line and `exit 75`s. That runs in a
#     subshell here, so the caller gets rc 1 and keeps running.
[ -n "${_EP_LOADED:-}" ] && return 0
_EP_LOADED=1
_EP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

endpoint_url() {
  local svc="${1:-}" var v lg="" root="${HARNESS:-${H:-}}"
  case "$svc" in
    ''|-*|*[!a-z0-9-]*) echo "endpoint_url: bad service name '$svc' (want [a-z0-9-])" >&2; return 1 ;;
  esac
  var=ENDPOINT_$(printf '%s' "$svc" | tr 'a-z-' 'A-Z_')
  [ -z "$root" ] || lg="$root/bin/lib/lane-gate.sh"
  [ -n "$lg" ] && [ -r "$lg" ] || lg="$_EP_DIR/lane-gate.sh"
  v=$(
    command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lg" ] && . "$lg" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply "endpoint-$svc" >/dev/null 2>&1
    printf '%s' "${!var:-}"
  ) || v=""
  if [ -z "$v" ]; then
    echo "endpoint_url: no URL for '$svc' ($var: no settings row, no cached row, no env, no registry default); refusing to guess" >&2
    return 1
  fi
  printf '%s\n' "$v"
}
