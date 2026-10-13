#!/bin/bash
# bin/lib/main-red-queue-thaw.sh — sourced by bin/main-red-detector.sh (BH-3889, part 2 of BH-3886); never executed
#
# WHEN A MERGE-QUEUE FREEZE IS OVER. The detector calls two hooks from here:
#   mrqt_clear_ok <slug> <flagfile>  rc 0 = a reason=queue flag thaws this tick
#   mrqt_stand_down <slug>           rc 0 = the queue arm's red verdict is dropped
# Both set MRQT_WHY to the sentence the detector logs. Neither reads GitHub nor
# writes anything: they judge this tick's $RUNS (main's page) and the Q* globals
# mr_queue_verdict set, so the BH-1927 confirming re-read gets the same answer.
#
# THE RULE. A flag that carries qred_t=/qred_done= (the newest counted red
# batch's created_at/updated_at) thaws when the queue was read and a green batch
# was CREATED after that red or FINISHED after it, or when a green push or
# workflow_dispatch run of a required workflow on main (SKIP_RE off, never
# schedule) was created after the red finished. The same main-run proof stands
# the arm down before a raise. A flag with no qred_t= keeps the detector's old
# comparison against detected=, byte for byte.
#
# WHY (2026-10-02). The arm froze main at 06:01:34Z on three red batches while
# the greens 36971026756/36971039150, created 05:54Z, were still running; once
# they finished, the clear compared their created_at with detected= and held,
# and with merges frozen no newer batch could ever be created.
#
# INTENT CONFLICT (declared). The detector's header and its clear-branch comment
# say main's own push runs "are fast checks and prove nothing about the corpus".
# This lib follows the newer BH-3886 ticket, which counts a green push on main as
# proof, but only one created after the newest counted red batch FINISHED.

# _mrqt_main_green <floor-iso> — the newest green push/dispatch run of a required
# workflow on main created after <floor>, as "<t>\t<sha>\t<event>\t<name>".
# Nothing (rc 1 on an empty floor) when there is none. ISO-8601 Z times compare
# as strings.
_mrqt_main_green() {
  [ -n "${1:-}" ] || return 1
  jq -r --arg re "${SKIP_RE:-}" --arg floor "$1" '[.[]?
      | select(.e == "push" or .e == "workflow_dispatch")
      | select(.s == "completed" and .c == "success")
      | select((((.n // "") | test($re; "i")) or ((.p // "") | test($re; "i"))) | not)
      | select((.t // "") > $floor)] | sort_by(.t) | last // empty
      | [.t, (.sha // ""), .e, (.n // .p // "?")] | @tsv' <<<"${RUNS:-[]}" 2>/dev/null
}

# _mrqt_main_why <tsv> <after> — the sentence for one _mrqt_main_green answer;
# <after> names the floor it beat.
_mrqt_main_why() {
  local t sha e n
  IFS=$'\t' read -r t sha e n <<<"$1"
  MRQT_WHY="a $e run of $n passed on main at $t on ${sha:0:8}, after $2"
}

# _mrqt_legacy <flagfile> — the detector's pre-BH-3889 chain (mr_queue_holds),
# verbatim, inverted: it answered rc 0 for "holds", this answers rc 0 for
# "thawed". A flag or a $RUNS the chain cannot read fails the chain, which was
# "not held", so it thaws here too.
_mrqt_legacy() {
  local QSINCE QDISP det
  det=$(sed -n 's/^detected=//p' "$1" 2>/dev/null | head -1)
  if QSINCE="$(sed -n 's/^detected=//p' "$1" | head -1 | sed 's/ /T/; s/Z$//')Z" \
  && QDISP=$(jq -r --arg re "$SKIP_RE" '[.[]? | select(.e == "workflow_dispatch" and .s == "completed" and .c == "success")
               | select((((.n // "") | test($re; "i")) or ((.p // "") | test($re; "i"))) | not) | .t // empty] | max // empty' <<<"${RUNS:-}" 2>/dev/null) \
  && { [ -z "$QDISP" ] || [[ "$QDISP" < "$QSINCE" ]]; } \
  && { [ "${QREAD:-}" != ok ] || [ -z "${QGREEN_T:-}" ] || [[ "$QGREEN_T" < "$QSINCE" ]]; }; then
    MRQT_WHY="a legacy flag (no qred_t=): nothing green newer than the freeze at ${det:-?}"
    return 1
  fi
  if [ -n "${QDISP:-}" ] && ! [[ "$QDISP" < "${QSINCE:-}" ]]; then
    MRQT_WHY="a legacy flag (no qred_t=) and a workflow_dispatch run that passed on main at $QDISP, after the freeze at ${det:-?}"
  elif [ "${QREAD:-}" = ok ] && [ -n "${QGREEN_T:-}" ] && ! [[ "$QGREEN_T" < "${QSINCE:-}" ]]; then
    MRQT_WHY="a legacy flag (no qred_t=) and a green batch created $QGREEN_T after the freeze at ${det:-?}"
  else
    MRQT_WHY="a legacy flag (no qred_t=) whose detected= or main runs could not be read, which the old rule never held on"
  fi
  return 0
}

mrqt_clear_ok() {
  local flag="${2:-}" qt qd det floor after g
  MRQT_WHY=""
  qt=$(sed -n 's/^qred_t=//p' "$flag" 2>/dev/null | head -1)
  qd=$(sed -n 's/^qred_done=//p' "$flag" 2>/dev/null | head -1)
  det=$(sed -n 's/^detected=//p' "$flag" 2>/dev/null | head -1)
  if [ -z "$qt" ]; then
    _mrqt_legacy "$flag"; return
  fi
  # The batch arm needs a queue that was read: "could not look" is never "fixed",
  # and with no green in the page QGREEN_* are empty and prove nothing.
  if [ "${QREAD:-}" = ok ]; then
    if [ -n "${QGREEN_T:-}" ] && [[ "$QGREEN_T" > "$qt" ]]; then
      MRQT_WHY="merge-queue batch created at $QGREEN_T went green, after the newest red batch (created $qt)"
      return 0
    fi
    [ -n "${QGREEN_DONE:-}" ] && [ -n "$qd" ] && [[ "$QGREEN_DONE" > "$qd" ]] && { MRQT_WHY="a merge-queue batch finished green at $QGREEN_DONE, after the newest red batch finished at $qd"; return 0; }
  fi
  # The main-run arm: after the red's finish, or after detected= (later) when the
  # flag has no finish to compare against.
  floor="$qd"; after="the newest red batch finished at $qd"
  [ -n "$floor" ] || { [ -n "$det" ] && floor="$(sed 's/ /T/; s/Z$//' <<<"$det")Z" && after="the freeze at $det"; }
  g=$(_mrqt_main_green "$floor")
  if [ -n "$g" ]; then
    _mrqt_main_why "$g" "$after"
    return 0
  fi
  MRQT_WHY="no green batch created after $qt or finished after ${qd:-?}, and no green push or dispatch run on main after ${floor:-?} (queue read: ${QREAD:-?})"
  return 1
}

mrqt_stand_down() {
  local rfloor rafter ep g
  MRQT_WHY=""
  rfloor="${QRED_DONE:-}"; rafter="the newest red batch finished at ${QRED_DONE:-}"
  if [ -z "$rfloor" ]; then
    # GitHub gave no finish: the newest counted red's created_at (QVERDICT col 10).
    ep=$(cut -f10 <<<"${QVERDICT:-}")
    case "$ep" in ''|*[!0-9]*) return 1 ;; esac
    rfloor=$(date -u -d "@$ep" +%FT%TZ 2>/dev/null) || return 1
    rafter="the newest red batch was created at $rfloor (its finish unknown)"
  fi
  g=$(_mrqt_main_green "$rfloor")
  [ -n "$g" ] || return 1
  _mrqt_main_why "$g" "$rafter"
  return 0
}
