#!/bin/bash
# bin/pr-state-reconcile.sh tick — BH-4954 (BH-4950.1): the sweep that keeps the
# PR gate facts (`state='gate'` rows in pr_state_events, worker/jobs/src/lib/
# pr-gate.js) true when a webhook, an artifact hook or a verdict hook was lost.
# Every 15 minutes (cron/lanes/716-pr-state-reconcile.cron), for each repo in
# LEAD_REVIEW_AUTO_REPOS (lead-review-land's knob, read through its
# lane_env_apply; empty = not configured, nothing is written):
#   budget   gh_budget_low rc 0 = the repo is skipped this pass, no read at all.
#   db       pr_gate_facts <slug>: the folded facts. Unreadable = no corrections.
#   list     harness_pr_list open. Unreadable = next repo.
#   per open PR, the live head (prs_pr_get .head.sha) first; unreadable skips the
#   PR, because every other fact is judged against it. Then, in this order, one
#   correcting event per field whose db value differs from the live one:
#     head                  the live head
#     draft                 isDraft as 0/1 (db null reads as 0)
#     closed=0              only when the db says closed=1 (it is open again)
#     builder_approved_sha  job_verdict APPROVE with reviewed_sha == head, or
#                           job_verdict_headbound == reapproved@<head>; rc 1 = skipped
#     lead_verdict_*        vd_standing on the head; rc 2 = skipped
#     held                  hold_check_thread rc 1 = 1, rc 0 = 0; rc 2 = skipped
#     ci_green_sha=<head>   frp_ci state green; unreadable = skipped. Last, and
#                           only when the db is not already green on the head:
#                           it costs two GitHub reads.
#   closed   when the open list is complete (< 100 rows), every db PR that is not
#            closed and not in the list is read (gh_rest pulls/<n>); state closed
#            = closed=1. Unreadable = skipped. A full list skips this step.
# A sha fact is never corrected backwards (NULL is "no news"): it is always
# compared with `head`, so a new head already invalidates it.
# Each event: pr_gate_event_put <slug> <n> reconcile@<head12>@<field>@<sweep
# epoch> reconcile <field=value>... The epoch keeps a second correction of the
# same field on the same head from colliding with the first on the dedupe key.
# PR_STATE_RECONCILE_MAX_PER_SWEEP caps the corrections a sweep writes; the
# rest are deferred, and the next sweep sees the same difference.
# Unreadable is never written as a fact. A failed write is failed, not corrected.
# Hub only. Kill switch: flags/lane-off-pr-state-reconcile.
# Log: logs/pr-state-reconcile.log, one line per correction and one
# `checked= corrected= skipped= deferred= failed= repos=` summary a sweep.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

case "${1:-tick}" in tick) ;; *) echo "usage: bin/pr-state-reconcile.sh tick" >&2; exit 2 ;; esac

# >>> lane gate (BH-1165). Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off pr-state-reconcile.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit pr-state-reconcile
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    pr-state-reconcile
# LEAD_REVIEW_AUTO_REPOS is lead-review-land's knob (BH-3479.0 contract).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lead-review-land

LOG="$H/logs/pr-state-reconcile.log"
STATE="$H/state/pr-state-reconcile"
log() { mkdir -p "$H/logs" 2>/dev/null; echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG"; }

# shellcheck source=bin/lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" 2>/dev/null || { log "missing bin/lib/hub-box.sh; pr-state-reconcile tick skipped"; exit 0; }
BOX=$(local_box_name)
if ! is_hub_box "$BOX"; then log "not the hub (${BOX:-unnamed}); pr-state-reconcile runs on the hub only"; exit 0; fi

# jobs-client.sh exits its caller on a missing module, so every piece is checked first.
for f in bin/jobs-client.sh bin/lib/jobs/req.sh bin/lib/verdicts.sh bin/lib/hold.sh bin/lib/gh-rest.sh \
         bin/lib/gh-pr-list.sh bin/lib/gh-budget.sh bin/lib/pr-snapshot.sh bin/lib/fixround-preflight.sh; do
  [ -r "$H/$f" ] || { log "missing $f; pr-state-reconcile tick skipped"; exit 0; }
done
# shellcheck source=/dev/null
{ . "$H/bin/jobs-client.sh"; . "$H/bin/lib/verdicts.sh"; . "$H/bin/lib/hold.sh"
  . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/gh-pr-list.sh"; . "$H/bin/lib/gh-budget.sh"
  . "$H/bin/lib/pr-snapshot.sh"; . "$H/bin/lib/fixround-preflight.sh"; }

# A required registry knob: no literal here. Empty or not a positive integer
# means the registry was not read, and that is never "go".
MAX="${PR_STATE_RECONCILE_MAX_PER_SWEEP:-}"
case "$MAX" in ''|*[!0-9]*|0*) log "PR_STATE_RECONCILE_MAX_PER_SWEEP='$MAX' is not a positive integer; nothing written"; exit 0 ;; esac
# Owned by lead-review-land and exported by its lane_env_apply above. Empty =
# not configured, never "all repos".
AUTO_REPOS=""; [ -n "${LEAD_REVIEW_AUTO_REPOS+x}" ] && AUTO_REPOS=$LEAD_REVIEW_AUTO_REPOS
[ -n "${AUTO_REPOS// /}" ] || { log "LEAD_REVIEW_AUTO_REPOS is empty; nothing written"; exit 0; }

mkdir -p "$STATE" 2>/dev/null
# A sweep dedupe, never a queue: a second tick while one runs skips.
exec 9>"$STATE/tick.lock"; flock -n 9 || { log "another sweep holds $STATE/tick.lock; skipped"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pr-state-reconcile.XXXXXX") || { log "mktemp failed; sweep skipped"; exit 0; }
trap 'rm -rf "$WORK"' EXIT
command -v prs_gc >/dev/null 2>&1 && prs_gc

STAMP=$(date -u +%s)
REPOS=0; CHECKED=0; CORRECTED=0; SKIPPED=0; DEFERRED=0; FAILED=0
s12() { case "$1" in ????????????*) printf '%s' "${1:0:12}" ;; '') printf 'null' ;; *) printf '%s' "$1" ;; esac; }

# fix <field> <db> <live> <field=value>... — one correcting event, under the cap.
# Uses SLUG, N and HEAD from the loop.
fix() {
  local field="$1" db="$2" live="$3"; shift 3
  if [ "$CORRECTED" -ge "$MAX" ]; then DEFERRED=$((DEFERRED + 1)); return 0; fi
  if pr_gate_event_put "$SLUG" "$N" "reconcile@${HEAD:0:12}@$field@$STAMP" reconcile "$@" 2>/dev/null; then
    CORRECTED=$((CORRECTED + 1))
    log "$SLUG $N $field db=$(s12 "$db") live=$(s12 "$live")"
  else
    FAILED=$((FAILED + 1))
    log "$SLUG $N $field db=$(s12 "$db") live=$(s12 "$live"): the correcting event was not written; next sweep retries"
  fi
}

for SLUG in $AUTO_REPOS; do
  REPOS=$((REPOS + 1))
  case "$SLUG" in */*) ;; *) log "'$SLUG' in LEAD_REVIEW_AUTO_REPOS is not owner/repo; skipped"; continue ;; esac
  if gh_budget_low pr-state-reconcile; then log "budget low; $SLUG skipped this pass"; SKIPPED=$((SKIPPED + 1)); continue; fi
  if ! pr_gate_facts "$SLUG" > "$WORK/facts" 2>/dev/null || ! jq -e '.rows | type == "array"' "$WORK/facts" >/dev/null 2>&1; then
    log "$SLUG: the gate facts are unreadable; no corrections this pass"; SKIPPED=$((SKIPPED + 1)); continue
  fi
  harness_pr_list "$SLUG" open number,url,isDraft,baseRefName,headRefOid,updatedAt > "$WORK/list" 2>/dev/null; RC=$?
  if [ "$RC" != 0 ] || ! jq -e 'type == "array"' "$WORK/list" >/dev/null 2>&1; then
    log "$SLUG: the open PR list is unreadable (rc $RC); next sweep retries"; SKIPPED=$((SKIPPED + 1)); continue
  fi
  while IFS=$'\t' read -r N URL DRAFT BASE LHEAD LUPD; do
    case "$N" in ''|*[!0-9]*) continue ;; esac
    CHECKED=$((CHECKED + 1))
    HEAD=""
    prs_pr_get "$SLUG" "$N" "$LHEAD" "$LUPD" "$BASE" "$WORK/pr" 2>/dev/null && HEAD=$(jq -r '.head.sha // empty' "$WORK/pr" 2>/dev/null | tr 'A-F' 'a-f')
    [[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || { log "$SLUG $N: live head unreadable; PR skipped"; SKIPPED=$((SKIPPED + 1)); continue; }
    # The db's facts for this PR, '' for null (no row = every field null). A
    # null rides as '-' because read collapses adjacent tabs.
    IFS=$'\t' read -r D_HEAD D_DRAFT D_CLOSED D_CI D_APP D_LEAD D_HELD < <(jq -r --argjson n "$N" '
      ([.rows[] | select(.number == $n)] | first // {}) as $r
      | [$r.head, $r.draft, $r.closed, $r.ci_green_sha, $r.builder_approved_sha, $r.lead_verdict_sha, $r.held]
      | map(if . == null or . == "" then "-" else tostring end) | @tsv' "$WORK/facts")
    for v in D_HEAD D_DRAFT D_CLOSED D_CI D_APP D_LEAD D_HELD; do [ "${!v:--}" = - ] && printf -v "$v" '%s' ""; done
    [ "$HEAD" != "${D_HEAD:-}" ] && fix head "${D_HEAD:-}" "$HEAD" "head=$HEAD"
    LDRAFT=0; [ "$DRAFT" = true ] && LDRAFT=1
    [ "$LDRAFT" != "${D_DRAFT:-0}" ] && fix draft "${D_DRAFT:-}" "$LDRAFT" "draft=$LDRAFT"
    [ "${D_CLOSED:-0}" = 1 ] && fix closed 1 0 closed=0
    # A builder APPROVE bound to the head (lead-review-enqueue's rule).
    if [ "${D_APP:-}" != "$HEAD" ]; then
      JRC=0; JV=$(job_verdict "$URL" 2>/dev/null) || JRC=$?
      case "$JRC" in
        0)
          IFS=$'\t' read -r V _ _ _ _ RSHA <<<"$JV"
          RSHA=$(printf '%s' "$RSHA" | tr 'A-F' 'a-f')
          if [ "$V" = APPROVE ]; then
            if [ "$RSHA" = "$HEAD" ]; then fix builder_approved_sha "${D_APP:-}" "$HEAD" "builder_approved_sha=$HEAD"
            elif HB=$(job_verdict_headbound "$URL" 2>/dev/null); then
              [ "$(printf '%s' "$HB" | tr 'A-F' 'a-f')" = "reapproved@$HEAD" ] && fix builder_approved_sha "${D_APP:-}" "$HEAD" "builder_approved_sha=$HEAD"
            else
              log "$SLUG $N: the builder verdict's headbound is unreadable; builder_approved_sha not judged"; SKIPPED=$((SKIPPED + 1))
            fi
          fi ;;
        2) ;;
        *) log "$SLUG $N: the builder verdict is unreadable; builder_approved_sha not judged"; SKIPPED=$((SKIPPED + 1)) ;;
      esac
    fi
    if [ "${D_LEAD:-}" != "$HEAD" ]; then
      VRC=0; VL=$(vd_standing "$SLUG" "$N" "$HEAD" 2>/dev/null) || VRC=$?
      case "$VRC" in
        0) fix lead_verdict "${D_LEAD:-}" "$HEAD" "lead_verdict_sha=$HEAD" "lead_verdict_word=$(cut -f1 <<<"$VL")" ;;
        1) ;;
        *) log "$SLUG $N: the standing verdict is unreadable; lead_verdict not judged"; SKIPPED=$((SKIPPED + 1)) ;;
      esac
    fi
    HRC=0; hold_check_thread "$SLUG" "$N" >/dev/null 2>&1 || HRC=$?
    case "$HRC" in
      0|1) LHELD=$((HRC == 1 ? 1 : 0)); [ "$LHELD" != "${D_HELD:-0}" ] && fix held "${D_HELD:-}" "$LHELD" "held=$LHELD" ;;
      *) log "$SLUG $N: the PR thread is unreadable; held not judged"; SKIPPED=$((SKIPPED + 1)) ;;
    esac
    # CI last: two GETs, and only when the db is not already green on the head.
    if [ "${D_CI:-}" != "$HEAD" ]; then
      CI=$(frp_ci "$SLUG" "$HEAD" | jq -r '.state // "unreadable"' 2>/dev/null)
      case "$CI" in
        green) fix ci_green_sha "${D_CI:-}" "$HEAD" "ci_green_sha=$HEAD" ;;
        pending|red|none) ;;
        *) log "$SLUG $N: CI on $(s12 "$HEAD") is unreadable; ci_green_sha not judged"; SKIPPED=$((SKIPPED + 1)) ;;
      esac
    fi
  done < <(jq -r '.[] | [(.number|tostring), (.url // ""), (.isDraft|tostring), (.baseRefName // "main"),
      ((.headRefOid // "") | if . == "" then "-" else . end), ((.updatedAt // "") | if . == "" then "-" else . end)] | @tsv' "$WORK/list")

  # Closed on GitHub, open in the db. Only a complete list can say "not open".
  if [ "$(jq 'length' "$WORK/list")" -ge 100 ]; then
    log "$SLUG: list may be truncated; closed sweep skipped"
    continue
  fi
  while IFS=$'\t' read -r N HEAD; do
    case "$N" in ''|*[!0-9]*) continue ;; esac
    [ "$HEAD" = - ] && HEAD=""
    CRC=0; gh_rest GET "repos/$SLUG/pulls/$N" > "$WORK/one" 2>/dev/null || CRC=$?
    ST=$(jq -r '.state // empty' "$WORK/one" 2>/dev/null)
    if [ "$CRC" != 0 ] || [ -z "$ST" ]; then
      log "$SLUG $N: the PR is not in the open list and its state is unreadable; closed not judged"; SKIPPED=$((SKIPPED + 1)); continue
    fi
    [ "$ST" = closed ] && fix closed 0 1 closed=1
  done < <(jq -r --slurpfile open "$WORK/list" '($open[0] | map(.number)) as $o
      | .rows[] | select(.closed != 1) | select(.number as $n | $o | index($n) | not)
      | [(.number|tostring), (.head // "-")] | @tsv' "$WORK/facts")
done

log "checked=$CHECKED corrected=$CORRECTED skipped=$SKIPPED deferred=$DEFERRED failed=$FAILED repos=$REPOS"
exit 0
