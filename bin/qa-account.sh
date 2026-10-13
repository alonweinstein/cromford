#!/bin/bash
# bin/qa-account.sh <project> <role> [user_id|email] — resolve one QA account
# field from state/qa-accounts.json. Default field is user_id.
#
# ONE LOOKUP, ONE SPELLING. This was inline python inside bin/qa-session.sh, and
# the moment a second caller needed it (bin/qa-unbanned.sh, 2026-08-29) the
# choice was a copy or a file. Two implementations of one rule is this repo's
# named failure shape — a role that resolves in one script and not the other
# would make "which account did we drive as" answerable two ways.
#
# A raw `user_...` id passed where a role is expected resolves to itself, so a
# caller holding an id (an alert, a console command) does not need the map.
#
# Exit 1 with a message on stderr when the project or role is unknown: an
# unresolved account must stop the caller, never fall through to a default.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
P="${1:?project}"; ROLE="${2:?role}"; FIELD="${3:-user_id}"
case "$FIELD" in user_id|email) ;; *) echo "unknown field: $FIELD" >&2; exit 1 ;; esac
# An id is its own answer — but only for user_id; nothing here can invent the
# email that goes with it, and printing an empty string would read as "no email
# on file" rather than "you asked the wrong question".
case "$ROLE" in
  user_*) [ "$FIELD" = user_id ] && { echo "$ROLE"; exit 0; }
          echo "cannot resolve $FIELD from a bare user id" >&2; exit 1 ;;
esac
ACCOUNTS="${QA_ACCOUNTS:-$HARNESS/state/qa-accounts.json}"
[ -r "$ACCOUNTS" ] || { echo "no QA account map at $ACCOUNTS" >&2; exit 1; }
VAL=$(python3 - "$ACCOUNTS" "$P" "$ROLE" "$FIELD" <<'PY' 2>/dev/null
import json, sys
path, project, role, field = sys.argv[1:5]
try:
    rows = json.load(open(path))
except Exception:
    sys.exit(1)
entry = (rows.get(project) or {}).get(role) or {}
value = entry.get(field) or ""
if not value:
    sys.exit(1)
print(value)
PY
) || { echo "no QA account for $P/$ROLE in $ACCOUNTS" >&2; exit 1; }
[ -n "$VAL" ] || { echo "no $FIELD for $P/$ROLE in $ACCOUNTS" >&2; exit 1; }
echo "$VAL"
