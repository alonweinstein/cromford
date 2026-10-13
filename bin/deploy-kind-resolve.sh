#!/bin/bash
# bin/deploy-kind-resolve.sh <project> — close the open `deployfail:<project>:*`
# console alerts once the settings row deploy.<project>.kind says `none` (BH-3387).
#
# WHY. cromford has no GitHub production deployment, so bin/deploy-verify.sh
# paged "no successful production deployment within 20 min" on every merge until
# the row existed. Those pages are about a deploy that was never going to happen:
# the row is the evidence, and they close with the reason "not a deploying project".
#
# WHAT IT CLOSES, and nothing else: rows whose akey starts with the literal
# `deployfail:<project>:` (the trailing colon keeps `deployfail:<project>-x:` out).
# Nothing at all unless deploy_kind answers rc 0 AND `none`: a smoke-only
# project's deployfail is a dead-prod page, and no row or an outage proves nothing.
#
# Launched by bin/deploy-verify.sh and bin/deploy-request.sh on every `none`
# merge; runnable by hand: bin/deploy-kind-resolve.sh cromford
# Deterministic, no LLM. Fails soft: no console, no answer -> exit 0, nothing.
set -uo pipefail
PROJECT="${1:-}"
[ -n "$PROJECT" ] || exit 0
HARNESS="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=bin/lib/deploy-kind.sh
. "$BIN/lib/deploy-kind.sh" 2>/dev/null || exit 0
KIND=$(deploy_kind "$PROJECT" 2>/dev/null) || exit 0
[ "$KIND" = none ] || exit 0
# shellcheck source=bin/lib/alert-state.sh
. "$BIN/lib/alert-state.sh" 2>/dev/null || true
LOG="$HARNESS/logs/alerts-groom.log"
mkdir -p "$HARNESS/logs" 2>/dev/null
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

RESP=$(curl -s --max-time 20 -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL/api/alerts/open") || exit 0
jq -e '.alerts' >/dev/null 2>&1 <<<"$RESP" || exit 0

PREFIX="deployfail:$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]'):"
IDS=(); ROW_IDS=()
while IFS=$'\t' read -r ID AKEY LINE; do
  [ -n "$ID" ] || continue
  [ "${AKEY:0:${#PREFIX}}" = "$PREFIX" ] || continue
  IDS+=("$ID")
  if command -v alert_state_key >/dev/null 2>&1; then
    RK=$(alert_state_key "$LINE" 2>/dev/null); [ -n "$RK" ] && ROW_IDS+=("$RK")
  fi
done < <(jq -r '.alerts[] | [(.id|tostring), ((.akey // "") | if . == "" then "-" else . end), ((.line // "") | gsub("[\t\n\r]"; " "))] | @tsv' <<<"$RESP")

[ "${#IDS[@]}" -gt 0 ] || exit 0
curl -s --max-time 20 -X POST -H "Authorization: Bearer $HARNESS_SECRET" -H 'Content-Type: application/json' \
  -d "$(printf '%s\n' "${IDS[@]}" | jq -Rn --arg r 'not a deploying project' '{ids:[inputs|tonumber], reason:$r}')" \
  "$CONSOLE_URL/api/alerts/resolve" >/dev/null || exit 0
echo "$(STAMP) deploy-kind-resolve: resolved ${#IDS[@]} deployfail alert(s) for $PROJECT (deploy.kind=none)" >> "$LOG"
# The alerts table row, best-effort, exactly as the groomer does it (BH-1071).
if [ "${#ROW_IDS[@]}" -gt 0 ] && command -v alerts_db_on >/dev/null 2>&1 && alerts_db_on; then
  alert_resolve "${ROW_IDS[@]}" >/dev/null 2>&1 || echo "$(STAMP) deploy-kind-resolve: alerts table resolve failed (console done)" >> "$LOG"
fi
exit 0
