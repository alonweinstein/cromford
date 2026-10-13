#!/bin/bash
# shellcheck shell=bash
# bin/lib/split-watchdog.sh — BH-1805 (BH-1793.0) contract, BH-1807 (BH-1793.2)
# decider: the pure decision lib for the split-watchdog lane (BH-1793). No
# network, no model, no writes, no external binary.
#
# sw_next_step <now_epoch> <n_min> <m_min> <retry_reasons_regex>
#   stdin: one family's children in land order, one TSV line each, 14 columns:
#     key ticket_id board_status waiting_on_client(0|1)
#     pr_state(none|open|merged|closed|unknown) pr_url merged_at_epoch
#     mergeable(clean|dirty|unknown) head_sha lock_held(0|1|unknown)
#     queue_status(none|queued|ready|claimed|done|failed|unknown) queue_reason
#     queue_finished_epoch deploy_serves_merge(0|1|unknown)
#   stdout: at most one `<step>\t<child>\t<reason>` line, or nothing, where step
#     is one of enqueue | reenqueue | owed-completion | handoff-rebase | close-parent.
#   Fail closed: any `unknown` a rule needs means that rule does not fire.
#
# All of stdin is read before anything is decided (a piping caller never takes
# SIGPIPE). Rules in priority order, each scanning children in land order; the
# first rule that matches prints its line and nothing else is printed:
#   enqueue         the earliest pr_state=none child, when it has at least one
#                   earlier child, every earlier child is pr_state=merged, the
#                   latest of their merged_at_epoch <= now - n_min*60, and the
#                   child has waiting_on_client=0, lock_held=0, queue_status
#                   none|done. Board status is never read as merged.
#   reenqueue       the earliest pr_state=none child with queue_status=failed, a
#                   queue_reason matching the (non-empty) retry regex and not
#                   matching ^BUILD_DEFERRED|REFUSED, queue_finished_epoch <=
#                   now - m_min*60, waiting_on_client=0, lock_held=0.
#   owed-completion the earliest pr_state=merged child with board_status
#                   in_progress and deploy_serves_merge=1.
#   handoff-rebase  the earliest pr_state=open child with mergeable=dirty and a
#                   non-empty head_sha; the reason carries @<head_sha>.
#   close-parent    at least one child and every child pr_state=merged; the child
#                   column is `-` and the reason lists every child key.
#   A reason never carries now_epoch, so unchanged state gives the same reason
#   on every tick. waiting_on_client does not gate the last three rules.
#   rc 0 = decided (a line or nothing); rc 2 = now/n_min/m_min not a whole
#   number; rc 3 = a row without exactly 14 columns. rc 2/3 print nothing on
#   stdout and one line on stderr.
sw_next_step() {
  local now=${1-} n_min=${2-} m_min=${3-} retry_re=${4-}
  local -a lines=() K=() BOARD=() WOC=() PR=() URL=() MAT=() MG=() SHA=() LOCK=() QS=() QR=() QF=() DEP=()
  local line rest a t i j c n num='^[0-9]{1,18}$' excl='^BUILD_DEFERRED|REFUSED'
  local -a f
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [ -n "$line" ] && lines+=("$line")
  done
  for a in "$now" "$n_min" "$m_min"; do
    [[ $a =~ $num ]] || { echo "sw_next_step: now/n_min/m_min must be whole numbers, got [$now] [$n_min] [$m_min]" >&2; return 2; }
  done
  now=$((10#$now)); n_min=$((10#$n_min)); m_min=$((10#$m_min))
  for line in "${lines[@]}"; do
    t=${line//[!$'\t']/}
    [ "${#t}" = 13 ] || { echo "sw_next_step: row with $(( ${#t} + 1 )) columns, want 14: ${line%%$'\t'*}" >&2; return 3; }
    f=(); rest=$line
    for ((c = 0; c < 13; c++)); do f+=("${rest%%$'\t'*}"); rest=${rest#*$'\t'}; done
    f+=("$rest")
    K+=("${f[0]}"); BOARD+=("${f[2]}"); WOC+=("${f[3]}"); PR+=("${f[4]}"); URL+=("${f[5]}")
    MAT+=("${f[6]}"); MG+=("${f[7]}"); SHA+=("${f[8]}"); LOCK+=("${f[9]}"); QS+=("${f[10]}")
    QR+=("${f[11]}"); QF+=("${f[12]}"); DEP+=("${f[13]}")
  done
  n=${#K[@]}

  # enqueue: only the earliest pr_state=none child can have every earlier child merged.
  local max ok
  for ((i = 0; i < n; i++)); do [ "${PR[i]}" = none ] && break; done
  if ((i > 0 && i < n)); then
    ok=1; max=0
    for ((j = 0; j < i; j++)); do
      if [ "${PR[j]}" = merged ] && [[ ${MAT[j]} =~ $num ]]; then
        ((10#${MAT[j]} > max)) && max=$((10#${MAT[j]}))
      else ok=0; break; fi
    done
    if ((ok)) && ((max <= now - n_min * 60)) && [ "${WOC[i]}" = 0 ] && [ "${LOCK[i]}" = 0 ] \
       && { [ "${QS[i]}" = none ] || [ "${QS[i]}" = "done" ]; }; then
      printf 'enqueue\t%s\tpredecessors merged: %s @%s\n' "${K[i]}" "${K[i-1]}" "$max"
      return 0
    fi
  fi

  # reenqueue: an empty regex would match everything, so it never fires.
  if [ -n "$retry_re" ]; then
    for ((i = 0; i < n; i++)); do
      [ "${PR[i]}" = none ] && [ "${QS[i]}" = failed ] && [ -n "${QR[i]}" ] || continue
      [ "${WOC[i]}" = 0 ] && [ "${LOCK[i]}" = 0 ] && [[ ${QF[i]} =~ $num ]] || continue
      ((10#${QF[i]} <= now - m_min * 60)) || continue
      [[ ${QR[i]} =~ $retry_re ]] || continue
      [[ ${QR[i]} =~ $excl ]] && continue
      printf 'reenqueue\t%s\tretry failed: %s\n' "${K[i]}" "${QR[i]}"
      return 0
    done
  fi

  for ((i = 0; i < n; i++)); do
    if [ "${PR[i]}" = merged ] && [ "${BOARD[i]}" = in_progress ] && [ "${DEP[i]}" = 1 ]; then
      printf 'owed-completion\t%s\tmerged %s, deploy serves merge, board in_progress\n' "${K[i]}" "${URL[i]}"
      return 0
    fi
  done

  for ((i = 0; i < n; i++)); do
    if [ "${PR[i]}" = open ] && [ "${MG[i]}" = dirty ] && [ -n "${SHA[i]}" ]; then
      printf 'handoff-rebase\t%s\tPR %s dirty @%s\n' "${K[i]}" "${URL[i]}" "${SHA[i]}"
      return 0
    fi
  done

  ((n > 0)) || return 0
  local keys=""
  for ((i = 0; i < n; i++)); do
    [ "${PR[i]}" = merged ] || return 0
    keys+="${keys:+,}${K[i]}"
  done
  printf 'close-parent\t-\tfamily merged: %s\n' "$keys"
  return 0
}
