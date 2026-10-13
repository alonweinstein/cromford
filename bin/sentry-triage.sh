#!/bin/bash
# bin/sentry-triage.sh — BH-5620 (BH-5611.4): the sentry-triage hub lane. Every
# 30 minutes it reads the new and regressed issues of Sentry project
# SENTRY_TRIAGE_PROJECT (default cromford-harness) with SENTRY_API_TOKEN, the
# auth bin/sentry-lookup.sh uses, and turns each one into exactly one outcome:
# an ai-build ticket, a comment on a matching open ticket, or noise.
#
# THE RUN, in this order:
#   1. env load, lane_gate_or_exit sentry-triage (flags/all-off,
#      flags/lane-off-sentry-triage, the D1 pause row of the same name), then
#      lane_env_apply. Nothing leaves this box before the gate;
#   2. flock -n locks/sentry-triage.lock: a held lock skips the tick;
#   3. no SENTRY_API_TOKEN: one log line, exit 0;
#   4. st_list_issues. Non-2xx or not an array: ONE warn `sentry-triage-list`
#      with the HTTP code and Sentry's first 200 bytes, exit 0;
#   5. st_issue for each issue, most events first (bin/lib/sentry-triage.sh
#      holds the dedup, cap, call and act rules). A ledger outage, an open-issue
#      list or day cap that cannot be read: no more calls this tick, and the
#      ledger outage is ONE warn `sentry-triage-ledger`;
#   6. one summary line in logs/sentry-triage.log:
#      <ISO> sentry-triage issues=<n> below_min=<n> terminal=<n> called=<n> filed=<n> commented=<n> noise=<n> failed=<n> capped=<n> healed=<n>
#
# One regression pass per issue in total (ledger key <id>:regressed).
# Registry: catalog/lanes.d/sentry-triage.json. Map: docs/verification-map/entries/BH-5620.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
# Bounded (D21): the whole tick inside 25 minutes, under the 30-minute cadence.
if [ "${ST_TIMED:-}" != 1 ] && command -v timeout >/dev/null 2>&1; then
  ST_TIMED=1 exec timeout 1500 bash "$0" "$@"
fi
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/lane-model.sh" 2>/dev/null || true
  . "$SELF/lib/untrusted-input.sh" 2>/dev/null || true
  . "$SELF/lib/sentry-triage.sh" 2>/dev/null || true
}
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${SENTRY_TRIAGE_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$SENTRY_TRIAGE_FIXTURE"
fi

command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit sentry-triage
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply sentry-triage
export AGENT_CALL_LANE=sentry-triage
for fn in st_issue st_list_issues job_ledger_row job_ledger_put lane_role_model ui_wrap gh_rest_issue_list; do
  command -v "$fn" >/dev/null 2>&1 || { echo "sentry-triage: $fn missing (bin/lib/sentry-triage.sh and its libs)" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "sentry-triage: jq is required" >&2; exit 1; }

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
exec 9>"$H/locks/sentry-triage.lock"
flock -n 9 || exit 0

ST_NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${SENTRY_TRIAGE_NOW:-} =~ ^[0-9]+$ ]]; then ST_NOW=$SENTRY_TRIAGE_NOW; fi
[ -n "$ST_NOW" ] || ST_NOW=$(date -u +%s)
ST_DAY=$(date -u -d "@$ST_NOW" +%F)
ST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sentry-triage.XXXXXX") || exit 1
trap 'rm -rf "$ST_TMP"' EXIT
ST_CALLED=0; ST_STOP=""; ST_OPEN=""; ST_MODEL=""; ST_RUNNER=""

alert() { "$H/bin/lane-alert.sh" --severity warn --id "$1" sentry-triage "$2" >/dev/null 2>&1 || true; }

if [ -z "${SENTRY_API_TOKEN:-}" ]; then
  _st_log "sentry token unset; nothing read"; exit 0
fi
st_knobs

code=$(st_list_issues "$ST_TMP/issues.json"); lrc=$?
if [ "$lrc" != 0 ]; then
  peek=$(head -c 200 "$ST_TMP/issues.json" 2>/dev/null | tr '\n' ' ')
  _st_log "issue list failed (HTTP $code): $peek"
  alert sentry-triage-list "sentry-triage: Sentry issue list for $ST_ORG/$ST_PROJECT answered HTTP $code: $peek"
  exit 0
fi
N=$(jq 'length' "$ST_TMP/issues.json")
[ "$N" -ge 100 ] && _st_log "page cap 100 reached; the rest waits for a later tick"

declare -A C=([below_min]=0 [terminal]=0 [filed]=0 [commented]=0 [noise]=0 [failed]=0 [capped]=0 [healed]=0)
while IFS= read -r issue; do
  [ -n "$issue" ] || continue
  rc=0; st_issue "$issue" || rc=$?
  if [ "$rc" = 75 ]; then
    if [ "${ST_STOP:-}" = ledger ]; then
      _st_log "ledger unreadable; no calls this tick"
      alert sentry-triage-ledger "sentry-triage: the jobs ledger is unreadable; no Sentry issue was triaged this tick"
    fi
    break
  fi
  [ -n "${C[$ST_OUT]+x}" ] && C[$ST_OUT]=$((C[$ST_OUT] + 1))
done < <(jq -c 'sort_by(-((.count // "0") | tonumber? // 0))[]' "$ST_TMP/issues.json")

_st_log "issues=$N below_min=${C[below_min]} terminal=${C[terminal]} called=$ST_CALLED filed=${C[filed]} commented=${C[commented]} noise=${C[noise]} failed=${C[failed]} capped=${C[capped]} healed=${C[healed]}"
exit 0
