#!/bin/bash
# bin/qa-clerk-ban.sh <project> <user-id> <status|ban|unban>
#
# The one place in the harness that talks to Clerk's ban endpoints. Prints the
# user's ban state (`banned` or `active`) on every verb, so a caller never has
# to guess whether the write landed — `unban` that answers `banned` is a failed
# unban, not a successful call.
#
# WHY THIS EXISTS (2026-08-29, SDLC item 3a). Privileged QA accounts are BANNED
# at rest in Clerk by our own design: project-3's qa-administrator has been banned
# since 2026-08-16, and project-1' qa-owner/qa-admin the same way. That rest state
# is correct and stays. What was NOT correct is what a QA drive did about it:
#
#   POST /v1/sign_in_tokens for a banned user returns 200 and mints a real
#   ticket. The bounce happens LATER, when the browser presents the ticket and
#   the instance refuses the session — so the drive lands on /sign-in, screen-
#   shots the sign-in page, and reports coverage. Every authed claim in that
#   report is about a screen nobody ever saw.
#
# So a drive that needs a banned account must lift the ban for the length of the
# drive and put it back, and it must be able to SEE the state to say so. This
# script is the seeing and the lifting; bin/qa-unbanned.sh owns the putting-back
# (an EXIT trap in the process that owns the whole drive — a re-ban issued by a
# separate short-lived process cannot survive its caller being killed).
#
# ban/unban are idempotent at Clerk: banning a banned user is a 200 no-op.
#
# Env: QA_CLERK_SECRET_KEY, read from $HENV/<project>.env (never echoed).
# CLERK_API is overridable so tests/qa-ban-guard-test.sh can drive this file
# against a fake API; production resolves to exactly the URL it always has.
#
# Exit codes: 0 = the call succeeded and the printed state is Clerk's answer.
#             1 = no secret / no user id / HTTP failure — state UNKNOWN, and
#                 nothing is printed. A caller must treat that as "do not
#                 proceed", never as "not banned".
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
# The base URL is the endpoint-clerk knob (BH-1941): CLERK_API in the env still
# wins, as it always has; else ENDPOINT_CLERK, else the registry default.
# Resolved before any call; an unresolvable endpoint exits 1.
. "${HARNESS:-/root/harness}/bin/lib/endpoints.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/endpoints.sh" 2>/dev/null
if [ -z "${CLERK_API:-}" ]; then
  CLERK_API=$(endpoint_url clerk 2>/dev/null) || { echo "no Clerk endpoint (CLERK_API / ENDPOINT_CLERK unset, no registry default)" >&2; exit 1; }
fi
P="${1:?project}"; UID_="${2:?user-id}"; VERB="${3:?status|ban|unban}"

case "$VERB" in status|ban|unban) ;; *) echo "unknown verb: $VERB" >&2; exit 1 ;; esac
case "$UID_" in user_*) ;; *) echo "not a Clerk user id: $UID_" >&2; exit 1 ;; esac

SK="${QA_CLERK_SECRET_KEY:-}"
if [ -z "$SK" ]; then
  SK=$(grep -E "^QA_CLERK_SECRET_KEY=" "$HENV/$P.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
fi
[ -n "$SK" ] || { echo "no QA_CLERK_SECRET_KEY for $P" >&2; exit 1; }

# One request, then one read-back. The read-back is the point: Clerk's ban/unban
# responses carry the updated user object, but a proxy, a 5xx retry or a
# permission-scoped key can return a shape that parses to "not banned" without
# anything having changed. GET is the only answer worth printing.
call() { # call <method> <path>
  curl -sS -m 25 -o /dev/null -w '%{http_code}' -X "$1" \
    -H "Authorization: Bearer $SK" -H "Content-Type: application/json" \
    "$CLERK_API/v1/users/$UID_$2" 2>/dev/null
}
read_state() {
  local body
  body=$(curl -sS -m 25 -H "Authorization: Bearer $SK" "$CLERK_API/v1/users/$UID_" 2>/dev/null) || return 1
  # `banned` is a real boolean on the Clerk user object. A response that has no
  # such field is NOT "active" — it is an error page, a 404 or a shape we do not
  # understand, and all three must fail rather than report a state.
  printf '%s' "$body" | python3 -c '
import json, sys
try:
    u = json.load(sys.stdin)
except Exception:
    sys.exit(1)
b = u.get("banned")
if b is None:
    sys.exit(1)
print("banned" if b else "active")
' 2>/dev/null
}

if [ "$VERB" != status ]; then
  CODE=$(call POST "/$VERB")
  case "$CODE" in
    2*) ;;
    *) echo "clerk $VERB HTTP ${CODE:-none} for ${UID_:0:12}…" >&2; exit 1 ;;
  esac
fi
STATE=$(read_state) || { echo "clerk user read failed for ${UID_:0:12}…" >&2; exit 1; }
echo "$STATE"
exit 0
