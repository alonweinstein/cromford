#!/bin/bash
# bin/lib/responder-fix.sh — scripted remedies for the conditions the watchdog
# responder already knows the answer to (BH-2548). Sourced by
# bin/watchdog-responder.sh on the prefetch path; defines functions only.
#
# THE GAP. The responder pays about $2.5 a call, and two of the conditions it
# pays for have a fixed answer bash can read off the evidence it already fetched
# into $RCACHE/hdr-<i>:
#   evidence_missing  a line that STARTS `EVIDENCE MISSING for <P>:<K> — ` for
#                     the item's own P:K. The decide prompt forces "act" on it and
#                     the tooled pass then escalates it as "evidence unavailable",
#                     so a MISSING item bought two calls for one beat.
#   not_owed          the FETCHED `FIELDS:` line says waitingOn=client (one
#                     token, case-folded) AND the PR line is exactly
#                     `PRs: none open matching <K>`. The ticket left the
#                     stale-owed set since the snapshot; the model can only
#                     answer "healthy / none".
#
# THE TABLE IS DATA, THE DETECTORS ARE CODE. Each condition is mapped by a
# settings row (registered in catalog/lanes.d/watchdog-responder.json, exported
# by lane_env_apply) to:
#   model   today's path: the item goes to the model
#   none    journal and stamp the cooldown, no side effect
#   <name>  run bin/responder-fix/<name>.sh (^[a-z0-9-]{1,40}$)
# A row can only re-route a condition, never invent one: a match pattern in a
# row, over client-authored text, gating an action is an injection surface.
#
# FAIL OPEN. A junk row, a name with no file, a remedy that exits non-zero or
# runs past 60s: the item stays in the pass and goes to the model, exactly as
# before this file existed. Only a remedy that SUCCEEDED is journalled
# `scripted:` and stamped handled (send THEN stamp, D9).
#
# Reads from the caller: H, LOG, NOW, HANDLED, BRAKE_DB, KEYIDS[], STAMP.

# rfix_resolve <condition> — prints `model`, `none` or `script:<path>`.
rfix_resolve() {
  local c="$1" v
  case "$c" in
    evidence_missing) v="${RESPONDER_FIX_EVIDENCE_MISSING:-escalate-missing}" ;;
    not_owed)         v="${RESPONDER_FIX_NOT_OWED:-none}" ;;
    *) printf 'model\n'; return 0 ;;
  esac
  case "$v" in model|none) printf '%s\n' "$v"; return 0 ;; esac
  if [[ "$v" =~ ^[a-z0-9-]{1,40}$ ]] && [ -f "$H/bin/responder-fix/$v.sh" ]; then
    printf 'script:%s\n' "$H/bin/responder-fix/$v.sh"; return 0
  fi
  echo "$(STAMP) responder: bad remedy row $c=$v — routed to the model" >> "$LOG"
  printf 'model\n'
}

# rfix_classify <hdr-file> <project> <key> — prints the condition, or nothing.
rfix_classify() {
  local f="$1" p="$2" k="$3" line wo fields=""
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "EVIDENCE MISSING for $p:$k — "*) printf 'evidence_missing\n'; return 0 ;;
      FIELDS:*) [ -z "$fields" ] && fields="$line" ;;
    esac
  done < "$f"
  [[ "$fields" =~ ^FIELDS:\ status=[^\ ]*\ waitingOn=([^\ ]+)\ triageVerdict= ]] || return 0
  wo="${BASH_REMATCH[1],,}"
  [ "$wo" = client ] || return 0
  grep -qxF -- "PRs: none open matching $k" "$f" && printf 'not_owed\n'
  return 0
}

# _rfix_stamp <keys-file> — the 12h cooldown, same store and shape as the lane's
# own stamp at the bottom of bin/watchdog-responder.sh, and under the same lock:
# project runs overlap (BH-5942), so an unlocked rewrite here could erase the
# keys another run stamps in the middle (lead BLOCK at 897dab888). The temp
# name is this writer's own. A lock not free in 5 s stamps nothing: the keys
# come back next pass, never a false "handled".
_rfix_stamp() {
  local kf="$1" bk tmp="$HANDLED.${LLP_PROJECT:-rfix}.$$.tmp"
  if ! (
    flock -w 5 8 || exit 1
    jq -c --argjson now "$NOW" --rawfile ks "$kf" \
      'reduce ($ks | split("\n")[] | select(length > 0)) as $k (.; .[$k] = $now)' \
      "$HANDLED" > "$tmp" && mv "$tmp" "$HANDLED"
  ) 8>"${HANDLED_LOCK:-$HANDLED.lock}"; then
    rm -f "$tmp"
    echo "$(STAMP) responder: scripted-fix stamp skipped (handled.json lock not free in 5 s, or the rewrite failed) — the keys come back next pass" >> "$LOG"
    return 0
  fi
  if [ "${BRAKE_DB:-0}" = 1 ] && declare -F brake_mark >/dev/null 2>&1; then
    while IFS= read -r bk; do
      [ -n "$bk" ] || continue
      brake_mark responder-handled "$bk" "$NOW" \
        || echo "$(STAMP) responder: brake ledger mark failed for $bk — local handled.json stamp stands" >> "$LOG"
    done < "$kf"
  fi
}

# rfix_pass <rcache> <dry> — classify every prefetched item, run each matched
# (condition, project) group's remedy once, and append the keys it settled to
# <rcache>/fixed-keys. With dry=1 it journals `would run` and does nothing else.
rfix_pass() {
  local rc="$1" dry="${2:-0}" i pk p k cond detail line res v r grp gf kf
  : > "$rc/fixed-keys"
  : > "$rc/rfix-items"
  for i in "${!KEYIDS[@]}"; do
    pk="${KEYIDS[$i]}"; p="${pk%%:*}"; k="${pk#*:}"
    cond=$(rfix_classify "$rc/hdr-$i" "$p" "$k")
    [ -n "$cond" ] || continue
    detail=""
    if [ "$cond" = evidence_missing ]; then
      while IFS= read -r line; do
        case "$line" in "EVIDENCE MISSING for $p:$k — "*) detail="${line#"EVIDENCE MISSING for $p:$k — "}"; break ;; esac
      done < "$rc/hdr-$i"
    fi
    printf '%s\t%s\t%s\t%s\n' "$cond" "$p" "$k" "${detail//$'\t'/ }" >> "$rc/rfix-items"
  done
  [ -s "$rc/rfix-items" ] || return 0
  while IFS=$'\t' read -r cond p; do
    res=$(rfix_resolve "$cond")
    [ "$res" = model ] && continue
    v=none; [ "$res" != none ] && { v="${res#script:}"; v="${v##*/}"; v="${v%.sh}"; }
    gf="$rc/rfix-group"; kf="$rc/rfix-keys"
    awk -F'\t' -v c="$cond" -v p="$p" '$1 == c && $2 == p { print $2 "\t" $3 "\t" $4 }' "$rc/rfix-items" > "$gf"
    awk -F'\t' '{ print $1 ":" $2 }' "$gf" > "$kf"
    if [ "$dry" = 1 ]; then
      while IFS= read -r grp; do
        echo "$(STAMP) $grp $cond -> would run scripted:$v (dry run: nothing run, nothing stamped)" >> "$LOG"
      done < "$kf"
      continue
    fi
    if [ "$res" != none ]; then
      timeout 60 "${res#script:}" "$cond" "$p" < "$gf" >/dev/null 2>&1; r=$?
      if [ "$r" -ne 0 ]; then
        echo "$(STAMP) responder: remedy $v rc=$r for $cond/$p — routed to the model" >> "$LOG"
        continue
      fi
    fi
    while IFS= read -r grp; do
      echo "$(STAMP) $grp $cond -> scripted:$v" >> "$LOG"
    done < "$kf"
    _rfix_stamp "$kf"
    cat "$kf" >> "$rc/fixed-keys"
  done < <(cut -f1,2 "$rc/rfix-items" | sort -u)
}
