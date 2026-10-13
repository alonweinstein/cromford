#!/bin/bash
# bin/alerts-resolve-closed-prs.sh <owner/repo#N>... — close the console alerts
# whose whole subject is "this PR is open and stuck", for PRs a webhook just
# reported CLOSED (merged or abandoned). V1 alert hygiene, 2026-09-25.
#
# WHY. `mq-hb-lander:<project>:<PR>` and its siblings stayed open after the PR
# merged: bin/alerts-groom.sh settles them, but on a 2h cron (or a wake-driven
# run of the whole groom, which asks GitHub once per alert). The closure is
# already a FACT when bin/wake-loop.sh sees a `pull_request.closed` row — the
# webhook is the evidence — so the rows it makes stale close in the same drain,
# with no GitHub call at all.
#
# WHAT IT CLOSES, and nothing else:
#   * akey `mq-<kind>:<project>:<N>` (except mq-headbound / mq-tc) where <project>'s fleet.conf repo is
#     <owner/repo> (case-insensitive) — the merge-queue namespaces the groomer
#     had to find by URL
#   * a row whose line names github.com/<owner/repo>/pull/<N> AND whose text is
#     a PR-open subject: ALERTS_PR_SUBJECT_RE (knob: env or flags/alerts.conf only;
#     never a settings row, which must not widen what a close settles), default
#     `Merge queue: #|\[rebase-train\]|\[blocked-resolver\] ESCALATED`
#   * a pipeline-health row (akey `alert:ph-*`, or a `[pipeline-health]` line)
#     whose `prs=<owner/repo>#<N>,…` token lists ONLY closed PRs (BH-4055):
#     leadunqueued names its one PR, stalepr every aging PR of the project, so a
#     stalepr row with one PR still open stays open
# A row that merely MENTIONS the PR — a migration that still has to be applied
# after the merge, a post-deploy apply that failed — is not about the PR being
# open, and a closed PR does not settle it. Those stay for the groomer's own
# checks.
#
# Launched detached by bin/lib/wake-class-pr-closed.sh; runnable by hand.
# Deterministic, no LLM. Fails soft: no console, no answer -> exit 0, nothing.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$BIN/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
HENV=$(harness_env_dir "$HARNESS")
set -a; . "$HENV/global.env" 2>/dev/null; set +a
[ "$#" -gt 0 ] || exit 0
[ -n "${CONSOLE_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=bin/lib/alert-state.sh
. "$BIN/lib/alert-state.sh" 2>/dev/null || true
LOG="$HARNESS/logs/alerts-groom.log"
mkdir -p "$HARNESS/logs" 2>/dev/null
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

SUBJECT_RE='Merge queue: #|\[rebase-train\]|\[blocked-resolver\] ESCALATED'
command -v alert_cfg >/dev/null 2>&1 && SUBJECT_RE=$(alert_cfg ALERTS_PR_SUBJECT_RE "$SUBJECT_RE")

# The closed set, as "<owner/repo lowercased>#<N>" plus the fleet project that
# owns each repo (the mq-* akeys name the project, not the repo).
declare -A CLOSED=() PROJ_OF_REPO=()
while read -r P; do
  [ -n "$P" ] || continue
  R=$("$BIN/fleet-conf.sh" "$P" repo 2>/dev/null) || continue
  [ -n "$R" ] && [ "$R" != "-" ] && PROJ_OF_REPO[$(printf %s "$R" | tr 'A-Z' 'a-z')]="$P"
done < <("$BIN/fleet-conf.sh" --projects 2>/dev/null)
for A in "$@"; do
  case "$A" in */*'#'*) ;; *) continue ;; esac
  R=$(printf %s "${A%#*}" | tr 'A-Z' 'a-z'); N="${A##*#}"
  case "$N" in ''|*[!0-9]*) continue ;; esac
  CLOSED["$R#$N"]=1
  [ -n "${PROJ_OF_REPO[$R]:-}" ] && CLOSED["mq:${PROJ_OF_REPO[$R]}:$N"]=1
done
[ "${#CLOSED[@]}" -gt 0 ] || exit 0

RESP=$(curl -s --max-time 20 -H "Authorization: Bearer $HARNESS_SECRET" "$CONSOLE_URL/api/alerts/open") || exit 0
jq -e '.alerts' >/dev/null 2>&1 <<<"$RESP" || exit 0

IDS=(); ROW_IDS=()
while IFS=$'\t' read -r ID AKEY LINE; do
  [ -n "$ID" ] || continue
  HIT=""
  # NEVER a head-bound or failed-typecheck row: the webhook does not say merged
  # or closed, and a MERGE there means unreviewed or failing code reached main.
  # bin/alerts-groom.sh asks GitHub and settles those on a close without merge.
  case "$AKEY" in mq-headbound:*|mq-tc:*) continue ;; esac
  if [[ "$AKEY" =~ ^mq-[a-z-]+:([a-z0-9-]+):([0-9]+)$ ]] && [ -n "${CLOSED["mq:${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"]:-}" ]; then
    HIT=akey
  elif { [[ "$AKEY" == alert:ph-* ]] || [[ "$LINE" == "[pipeline-health]"* ]]; } \
       && PRS=$(grep -oE 'prs=[A-Za-z0-9_./#,-]+' <<<"$LINE" | head -1) && [ -n "$PRS" ]; then
    # BH-4055: every listed ref closed, matched on the whole lowercased ref.
    ALL=1; NREF=0
    while IFS= read -r REF; do
      [ -n "$REF" ] || continue
      NREF=$((NREF+1))
      [ -n "${CLOSED[$REF]:-}" ] || { ALL=0; break; }
    done < <(printf '%s\n' "${PRS#prs=}" | tr ',' '\n' | tr 'A-Z' 'a-z')
    [ "$ALL" = 1 ] && [ "$NREF" -gt 0 ] && HIT=ph
  else
    while read -r U; do
      [ -n "$U" ] || continue
      K=$(printf %s "$U" | sed -E 's#^github\.com/##I; s#/pull/#\##I' | tr 'A-Z' 'a-z')
      if [ -n "${CLOSED[$K]:-}" ] && grep -qE "$SUBJECT_RE" <<<"$LINE"; then HIT=line; break; fi
    done < <(grep -oiE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' <<<"$LINE")
  fi
  [ -n "$HIT" ] || continue
  IDS+=("$ID")
  if [[ "$AKEY" == alert:ph-* ]]; then
    ROW_IDS+=("${AKEY#alert:}")
  elif command -v alert_state_key >/dev/null 2>&1; then
    RK=$(alert_state_key "$LINE" 2>/dev/null); [ -n "$RK" ] && ROW_IDS+=("$RK")
  fi
  echo "$(STAMP) resolve $ID (pr-closed-wake/$HIT): $(head -c 100 <<<"$LINE")" >> "$LOG"
done < <(jq -r '.alerts[] | [(.id|tostring), ((.akey // "") | if . == "" then "-" else . end), ((.line // "") | gsub("[\t\n\r]"; " "))] | @tsv' <<<"$RESP")

[ "${#IDS[@]}" -gt 0 ] || exit 0
curl -s --max-time 20 -X POST -H "Authorization: Bearer $HARNESS_SECRET" -H 'Content-Type: application/json' \
  -d "$(printf '%s\n' "${IDS[@]}" | jq -Rn --arg r pr-closed-wake '{ids:[inputs|tonumber], reason:$r}')" \
  "$CONSOLE_URL/api/alerts/resolve" >/dev/null
echo "$(STAMP) pr-closed wake: resolved ${#IDS[@]} for $*" >> "$LOG"
# The alerts table row, best-effort, exactly as the groomer does it (BH-1071).
if [ "${#ROW_IDS[@]}" -gt 0 ] && command -v alerts_db_on >/dev/null 2>&1 && alerts_db_on; then
  alert_resolve "${ROW_IDS[@]}" >/dev/null 2>&1 || echo "$(STAMP) pr-closed wake: alerts table resolve failed (console done)" >> "$LOG"
fi
exit 0
