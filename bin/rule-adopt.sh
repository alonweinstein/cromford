#!/bin/bash
# bin/rule-adopt.sh tick — BH-3715 (BH-3692.2): the hub lane that lands the rule
# miner's LINT-BACKED rules PR (head rules/mined-<YYYYMMDD>-lint, the contract's
# RE_LINT_HEAD_RE) through the normal lead lane: a lead review of the live head,
# a head-bound lead MERGE, then mc_enqueue. NO model call, NO SSH, never merges
# or pushes; the judgement PR rules/mined-<date> never matches and is left alone.
#
# Every 15 minutes (cron/lanes/461-rule-adopt.cron), per open non-draft -lint PR
# on the cromford repo (its fleet.conf row), in this order:
#   head     gh_rest GET pulls/<n>: .head.sha (full sha) and .mergeable_state.
#            state/rule-adopt/enqueued-<n>-<sha12> = already queued, skipped.
#   guard    gh_rest GET compare/main...<head>: every non-merge commit authored
#            by harness@box, every file prompts/build-discipline.md
#            (modified) or prompts/rule-evidence/D<n>.json (added), at least one
#            evidence file, each lint-backed with a check and its own D-number.
#            Otherwise one warn rule-adopt-foreign-<n>-<sha12>. A truncated
#            compare or a failed evidence read is unreadable, never foreign.
#   verdict  vd_standing on the head: MERGE/MERGE-WITH-NOTES = enqueue; BLOCK =
#            one warn rule-adopt-block-<n>-<sha12>; nothing = request; rc 2 =
#            unreadable.
#   request  bin/lead-verdict.sh request … --notes "rule-miner lint-backed …".
#            rc 0 or HTTP 409 = requested (marker requested-<n>-<sha12>); else
#            one warn rule-adopt-req-<n>-<sha12>. At most
#            RULE_ADOPT_MAX_REQUESTS_PER_TICK new asks a tick (a re-confirm of
#            a requested head does not count); the rest are deferred.
#   enqueue  dirty = one warn rule-adopt-dirty-<n>-<sha12>, never a rebase.
#            mc_enqueue rc 0 = marker, then warn rule-adopt-queued-<n>; rc 2
#            (merged outright) = marker only; rc 1/3 = warn
#            rule-adopt-enqueue-<n>-<sha12>, no marker, retried next tick.
# Then the merged sweep: each -lint PR merged in the last 7 days with no
# state/rule-adopt/noted-<n> gets one warn rule-adopted-<n> naming each rule, its
# check and incident ids (evidence read at ref=main); the marker is written only
# after lane-alert.sh returned 0.
# Unreadable is never "go". Hub only. Kill switch: flags/lane-off-rule-adopt.
# Log: logs/rule-adopt.log, one `tick prs=..` summary line a tick.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

case "${1:-}" in tick) ;; *) echo "usage: bin/rule-adopt.sh tick" >&2; exit 2 ;; esac

# >>> lane gate (BH-1165). Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off rule-adopt.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit rule-adopt
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    rule-adopt

LOG="$H/logs/rule-adopt.log"
STATE="$H/state/rule-adopt"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) $*" >> "$LOG"; }

# shellcheck source=bin/lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" 2>/dev/null || { log "missing bin/lib/hub-box.sh; rule-adopt tick skipped"; exit 0; }
BOX=$(local_box_name)
if ! is_hub_box "$BOX"; then log "not the hub (${BOX:-unnamed}); rule-adopt runs on the hub only"; exit 0; fi

# jobs-client.sh and merge-conductor-lib.sh exit their caller on a missing module, so every piece is checked first.
for f in bin/jobs-client.sh bin/lib/jobs/req.sh bin/lib/verdicts.sh bin/lib/gh-rest.sh bin/lib/gh-pr-list.sh \
         bin/lib/merge-conductor-lib.sh bin/lib/rule-evidence.sh bin/lead-verdict.sh bin/lane-alert.sh; do
  [ -r "$H/$f" ] || { log "missing $f; rule-adopt tick skipped"; exit 0; }
done
# shellcheck source=/dev/null
{ . "$H/bin/jobs-client.sh"; . "$H/bin/lib/verdicts.sh"; . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/gh-pr-list.sh"
  . "$H/bin/lib/merge-conductor-lib.sh"; . "$H/bin/lib/rule-evidence.sh"; }

mkdir -p "$STATE" 2>/dev/null
# A tick dedupe, never a queue: a second tick while one runs skips.
exec 9>"$STATE/tick.lock"; flock -n 9 || { log "another tick holds $STATE/tick.lock; skipped"; exit 0; }

# A required registry knob: no literal here. Not a positive integer = the
# registry was not read, and that is never "go".
MAXR="${RULE_ADOPT_MAX_REQUESTS_PER_TICK:-}"
case "$MAXR" in ''|*[!0-9]*|0*) log "RULE_ADOPT_MAX_REQUESTS_PER_TICK='$MAXR' is not a positive integer; nothing done"; exit 0 ;; esac
SLUG=$(awk '$1 == "cromford" {print $2; exit}' "${FLEET_CONF:-$H/fleet.conf}" 2>/dev/null)
[[ "$SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { log "no owner/repo on the cromford row of fleet.conf ('$SLUG'); nothing done"; exit 0; }

# alert_once <id> <text> — one warn per id, deduped by state/rule-adopt/alerted-<id>,
#   written only after lane-alert.sh returned 0 (a failed call is retried next tick).
alert_once() {
  [ -e "$STATE/alerted-$1" ] && return 1
  "$H/bin/lane-alert.sh" --severity warn --id "$1" rule-adopt "$2" >/dev/null 2>&1 \
    || { log "lane-alert.sh failed for $1; next tick retries"; return 2; }
  : > "$STATE/alerted-$1" 2>/dev/null || log "alerted $1 but could not write its marker; this may alert again"
  return 0
}

# 14 days outlives the 7-day merged window, so a pruned noted- marker never re-notes.
find "$STATE" -maxdepth 1 \( -name 'alerted-*' -o -name 'enqueued-*' -o -name 'requested-*' -o -name 'noted-*' \) -mtime +14 -delete 2>/dev/null

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rule-adopt.XXXXXX") || { log "mktemp failed; tick skipped"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

PRS=0; LINT=0; QUEUED=0; NEEDHV=0; REQUESTED=0; DEFERRED=0; BLOCKED=0; FOREIGN=0; DIRTY=0; UNREAD=0; NOTED=0; ASKED=0

# evidence <path> <ref> — the evidence file at <ref>, decoded into $WORK/ev. rc 1 = unreadable.
evidence() {
  gh_rest GET "repos/$SLUG/contents/$1?ref=$2" > "$WORK/ct" 2>/dev/null || return 1
  jq -r '.content // empty' "$WORK/ct" 2>/dev/null | base64 -d > "$WORK/ev" 2>/dev/null || return 1
  jq -e 'type == "object"' "$WORK/ev" >/dev/null 2>&1
}

# guard <head> — sets WHY (empty = clean, "unreadable" or the failed condition) and RULES.
guard() {
  local head="$1" p d
  WHY=""; RULES=""
  gh_rest GET "repos/$SLUG/compare/main...$head" > "$WORK/cmp" 2>/dev/null || { WHY=unreadable; return; }
  WHY=$(jq -r 'if (.commits|type) != "array" or (.files|type) != "array" or (.total_commits|type) != "number"
      or .total_commits > (.commits|length) or (.files|length) >= 300 then "unreadable"
    elif ([.commits[] | select((.parents|length) < 2) | select(.commit.author.email != "harness@box")] | length) > 0
      then "a non-merge commit is not authored by harness@box"
    elif ([.files[] | select(((.filename == "prompts/build-discipline.md" and .status == "modified")
      or ((.filename | test("^prompts/rule-evidence/D[0-9]+\\.json$")) and .status == "added")) | not)] | length) > 0
      then "it changes a file other than prompts/build-discipline.md or a new prompts/rule-evidence/D<n>.json"
    elif ([.files[] | select(.filename | startswith("prompts/rule-evidence/"))] | length) == 0
      then "it adds no prompts/rule-evidence/D<n>.json"
    else "" end' "$WORK/cmp" 2>/dev/null) || WHY=unreadable
  [ -z "$WHY" ] || return
  for p in $(jq -r '.files[] | select(.filename | startswith("prompts/rule-evidence/")) | .filename' "$WORK/cmp"); do
    evidence "$p" "$head" || { WHY=unreadable; return; }
    d=${p##*/}; d=${d%.json}
    [ "$(re_field "$WORK/ev" '.class')" = lint-backed ] && [ "$(re_field "$WORK/ev" '.check')" != null ] \
      && [ "$(re_field "$WORK/ev" '.rule')" = "$d" ] \
      || { WHY="$p is not a lint-backed $d with a check"; return; }
    RULES="$RULES $d"
  done
  RULES=$(tr ' ' '\n' <<<"$RULES" | sed '/^$/d' | sort -V | paste -sd, -)
}

if harness_pr_list "$SLUG" open number,url,isDraft,headRefName > "$WORK/list" 2>/dev/null \
   && jq -e 'type == "array"' "$WORK/list" >/dev/null 2>&1; then
  while IFS=$'\t' read -r N URL DRAFT HEADREF; do
    PRS=$((PRS + 1))
    [ "$DRAFT" = true ] && continue
    case "$N" in ''|*[!0-9]*) continue ;; esac
    [[ "$HEADREF" =~ $RE_LINT_HEAD_RE ]] || continue
    LINT=$((LINT + 1))
    # The live head, never the list's.
    HEAD=""; MS=""
    gh_rest GET "repos/$SLUG/pulls/$N" > "$WORK/pr" 2>/dev/null \
      && { HEAD=$(jq -r '.head.sha // empty' "$WORK/pr" 2>/dev/null | tr 'A-F' 'a-f'); MS=$(jq -r '.mergeable_state // empty' "$WORK/pr" 2>/dev/null); }
    [[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || { log "#$N: live head unreadable; skipped"; UNREAD=$((UNREAD + 1)); continue; }
    H12=${HEAD:0:12}
    [ -e "$STATE/enqueued-$N-$H12" ] && continue
    guard "$HEAD"
    if [ "$WHY" = unreadable ]; then log "#$N @$H12: compare or evidence unreadable; skipped"; UNREAD=$((UNREAD + 1)); continue; fi
    if [ -n "$WHY" ]; then
      FOREIGN=$((FOREIGN + 1))
      alert_once "rule-adopt-foreign-$N-$H12" "$URL @$H12 is on a rules/mined-*-lint branch but $WHY, so it was not reviewed or queued." || true
      continue
    fi
    LINE=$(vd_standing "$SLUG" "$N" "$HEAD" 2>/dev/null); VRC=$?
    V=$(cut -f1 <<<"$LINE")
    if [ "$VRC" = 2 ]; then log "#$N @$H12: standing verdict unreadable; skipped"; UNREAD=$((UNREAD + 1)); continue; fi
    if [ "$VRC" = 0 ] && [ "$V" = BLOCK ]; then
      BLOCKED=$((BLOCKED + 1))
      alert_once "rule-adopt-block-$N-$H12" "$URL @$H12: the lead review BLOCKed the lint-backed rules ($(cut -f5 <<<"$LINE")). Not queued." || true
      continue
    fi
    if [ "$VRC" = 0 ] && [ "$V" != MERGE ] && [ "$V" != MERGE-WITH-NOTES ]; then log "#$N @$H12: standing verdict '$V'; skipped"; continue; fi
    if [ "$VRC" != 0 ]; then
      if [ ! -e "$STATE/requested-$N-$H12" ]; then
        [ "$ASKED" -lt "$MAXR" ] || { DEFERRED=$((DEFERRED + 1)); continue; }
        ASKED=$((ASKED + 1))
      fi
      RRC=0; "$H/bin/lead-verdict.sh" request "$SLUG" "$N" "$HEAD" \
        --notes "rule-miner lint-backed rules; each rule names the check that enforces it (prompts/rule-evidence/*.json)" \
        >/dev/null 2>"$WORK/err" || RRC=$?
      if [ "$RRC" = 0 ] || grep -q 'HTTP 409' "$WORK/err"; then
        : > "$STATE/requested-$N-$H12"; REQUESTED=$((REQUESTED + 1))
      else
        alert_once "rule-adopt-req-$N-$H12" "$URL @$H12: could not request a lead review ($(head -1 "$WORK/err")). By hand: bin/harness-ctl.sh review $SLUG $N $HEAD" || true
      fi
      continue
    fi
    if [ "$MS" = dirty ]; then
      DIRTY=$((DIRTY + 1))
      alert_once "rule-adopt-dirty-$N-$H12" "$URL @$H12 has a lead $V but conflicts with main; this lane never rebases, so the miner has to re-cut the branch." || true
      continue
    fi
    OUT=$(mc_enqueue "$URL" "$HEAD" 2>&1); RC=$?
    case "$RC" in
      0) : > "$STATE/enqueued-$N-$H12"; QUEUED=$((QUEUED + 1))
         alert_once "rule-adopt-queued-$N" "$RULES lint-backed, lead $V on $H12, queued to merge: $URL" || true ;;
      2) : > "$STATE/enqueued-$N-$H12"; QUEUED=$((QUEUED + 1)); log "#$N @$H12: merged outright by the queue" ;;
      # BH-3806: BH-3683 withholds the lead-verdict status on this head, so the
      # enqueue labelled and asked nothing. No mark: the next tick asks again,
      # and refuses again until a --source human verdict stands.
      4) NEEDHV=$((NEEDHV + 1))
         alert_once "rule-adopt-nhv-$N-$H12" "$URL @$H12 has a lead $V but $(head -1 <<<"$OUT")" || true ;;
      *) alert_once "rule-adopt-enqueue-$N-$H12" "$URL @$H12 has a lead $V but mc_enqueue rc $RC: $(head -1 <<<"$OUT")" || true ;;
    esac
  done < <(jq -r '.[] | [(.number|tostring), .url, (.isDraft|tostring), (.headRefName // "")] | @tsv' "$WORK/list")
else
  log "the open PR list for $SLUG is unreadable; open loop skipped"; UNREAD=$((UNREAD + 1))
fi

# The merged sweep: adoption time is GitHub's mergedAt, never this clock.
if harness_pr_list "$SLUG" closed number,url,headRefName,mergedAt 50 > "$WORK/closed" 2>/dev/null \
   && jq -e 'type == "array"' "$WORK/closed" >/dev/null 2>&1; then
  CUT=$(( $(date +%s) - 604800 ))
  while IFS=$'\t' read -r N URL HEADREF MA; do
    case "$N" in ''|*[!0-9]*) continue ;; esac
    [[ "$HEADREF" =~ $RE_LINT_HEAD_RE ]] || continue
    [ -n "$MA" ] && [ "$MA" != null ] || continue
    ME=$(date -d "$MA" +%s 2>/dev/null) || continue
    [ "$ME" -ge "$CUT" ] || continue
    [ -e "$STATE/noted-$N" ] && continue
    gh_rest GET "repos/$SLUG/pulls/$N/files" > "$WORK/files" 2>/dev/null \
      && jq -e 'type == "array"' "$WORK/files" >/dev/null 2>&1 || { log "#$N: merged files unreadable; next tick retries"; UNREAD=$((UNREAD + 1)); continue; }
    NOTE=""; OK=1
    for p in $(jq -r '.[] | select(.status != "removed") | .filename | select(test("^prompts/rule-evidence/D[0-9]+\\.json$"))' "$WORK/files"); do
      evidence "$p" main || { OK=0; break; }
      NOTE="$NOTE$(re_field "$WORK/ev" '.rule') enforced by $(re_field "$WORK/ev" '.check'), incidents $(re_field "$WORK/ev" '(.incidents|join(","))'); "
    done
    if [ "$OK" = 0 ] || [ -z "$NOTE" ]; then log "#$N: evidence unreadable or absent at main; next tick retries"; UNREAD=$((UNREAD + 1)); continue; fi
    if "$H/bin/lane-alert.sh" --severity warn --id "rule-adopted-$N" rule-adopt "adopted (merged $MA): $NOTE$URL" >/dev/null 2>&1; then
      : > "$STATE/noted-$N"; NOTED=$((NOTED + 1))
    else
      log "#$N: lane-alert.sh failed for rule-adopted-$N; next tick retries"
    fi
  done < <(jq -r '.[] | [(.number|tostring), .url, (.headRefName // ""), (.mergedAt // "null")] | @tsv' "$WORK/closed")
else
  log "the closed PR list for $SLUG is unreadable; merged sweep skipped"; UNREAD=$((UNREAD + 1))
fi

log "tick prs=$PRS lint=$LINT queued=$QUEUED needhv=$NEEDHV requested=$REQUESTED deferred=$DEFERRED blocked=$BLOCKED foreign=$FOREIGN dirty=$DIRTY unreadable=$UNREAD noted=$NOTED"
exit 0
