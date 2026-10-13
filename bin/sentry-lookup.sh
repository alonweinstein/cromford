#!/bin/bash
# bin/sentry-lookup.sh "<search terms>" [project-slug] — deterministic Sentry
# issue lookup for the alert-triage/medic lanes (the operator 2026-08-21).
#
# Why: the project-4 board 500s generated fleet alerts for DAYS while 227 Sentry
# events held the exact root cause (and 2,583 more sat unconnected on
# /accounting/bank). Any alert about a 500/timeout/error on an owned app should
# check Sentry FIRST — a curl, not a theory.
#
# Auth: SENTRY_API_TOKEN in env (a read-only user auth token with issue:read /
# event:read / org:read on org operator — env/global.env on each box).
# No token or any API failure prints a one-line notice and exits 0 — callers
# treat Sentry as advisory evidence, never a hard dependency.
#
# Output: up to 8 matching unresolved issues, one line each:
#   <shortId>  events=<count>  last=<lastSeen>  <title>  <permalink>
set -uo pipefail
Q="${1:?usage: sentry-lookup.sh \"<search terms>\" [project-slug]}"
PROJ="${2:-}"
ORG="${SENTRY_ORG:-operator}"

if [ -z "${SENTRY_API_TOKEN:-}" ]; then
  echo "(sentry lookup unavailable — SENTRY_API_TOKEN unset)"
  exit 0
fi

URL="https://sentry.io/api/0/organizations/$ORG/issues/?query=$(python3 - "$Q" <<'PYEOF'
import sys, urllib.parse
print(urllib.parse.quote(f"is:unresolved {sys.argv[1]}"))
PYEOF
)&limit=8&sort=freq&statsPeriod=14d"
[ -n "$PROJ" ] && URL="$URL&project=$PROJ"

T=$(mktemp)
trap 'rm -f "$T"' EXIT
curl -sS -m 25 -H "Authorization: Bearer $SENTRY_API_TOKEN" -o "$T" "$URL" || {
  echo "(sentry lookup failed: curl error)"; exit 0; }

python3 - "$T" <<'PYEOF' || echo "(sentry lookup: parse error)"
import json, sys
try:
    issues = json.load(open(sys.argv[1]))
except Exception:
    print("(sentry lookup: unparseable response)"); raise SystemExit
if not isinstance(issues, list):
    print(f"(sentry lookup: {str(issues)[:120]})"); raise SystemExit
if not issues:
    print("(sentry: no unresolved issues match)")
for i in issues[:8]:
    sid = i.get("shortId", "?")
    cnt = i.get("count", "?")
    seen = i.get("lastSeen", "?")
    title = (i.get("title") or "")[:100]
    link = i.get("permalink", "")
    print(f"{sid}  events={cnt}  last={seen}  {title}  {link}")
PYEOF
