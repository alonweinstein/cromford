#!/bin/bash
# BH-479: the launch stage of bin/run-triage.sh, moved here verbatim by
# BH-479.0; defines functions only, nothing runs on source.
rt_launch() {
# The schedule rides at the END of the prompt: it is the last thing decided
# before the session runs and the most perishable thing in it. It goes on here
# and NOT between the env-prefix lines below — those are one command spliced
# across four lines, and a statement inserted into the splice detaches
# GROK_EFFORT, AGENT_SYSTEM_APPEND and AGENT_CALL_ROW_NOTE (the tick's
# paid-unchanged note, bin/lib/triage-state-waste.sh) from the call they belong to.
PROMPT_TEXT="$PROMPT_TEXT${OVERLAP_SEC:+$'\n\n'$OVERLAP_SEC}"
# BH-4491: the session reads tickets and threads itself, so the prompt opens
# with the standing untrusted-input rule. No lib on this box: today's prompt.
# shellcheck source=bin/lib/untrusted-input.sh
command -v ui_notice >/dev/null 2>&1 || { [ -r "$HARNESS/bin/lib/untrusted-input.sh" ] && . "$HARNESS/bin/lib/untrusted-input.sh"; }
RT_UI_NOTICE=""
command -v ui_notice >/dev/null 2>&1 && RT_UI_NOTICE="$(ui_notice)"$'\n\n'
# P2 (#2294 review I3): the throttle ledger counts PAID launches, so the row is
# written here, before the agent call, and never at the gate.
command -v triage_throttle_record >/dev/null 2>&1 && triage_throttle_record "$HARNESS" "$PROJECT"
# lock_run_unheld, not a bare call: this session is told by the SOP to launch
# builds with `setsid run-build.sh ... &`, and those outlive it. Through the
# wrapper they inherit neither lock fd, and RC below still reads agent-call.sh's
# own exit code (the subshell execs it). This is the site BH-651 was.
GROK_EFFORT="$EFFECTIVE_GROK_EFFORT" \
AGENT_SYSTEM_APPEND="$TRIAGE_APPEND" \
AGENT_CALL_ROW_NOTE="${TS_ROW_NOTE:-}" \
  lock_run_unheld "$HARNESS/bin/agent-call.sh" triage "$PROJECT" "$TRIAGE_MODEL" 10800 "$OUT" "$RT_UI_NOTICE$PROMPT_TEXT"
RC=$?
# A call-guard REPEAT (BH-4120) is rc 74 with this mark: the guard refused a
# third identical paid prompt, which means no new input, not a broken lane. The
# lane and the job read it as a skip; every RC branch below still runs, so the
# failed-attempt counter keeps counting. Same match as bin/triage-shard.sh.
RT_CG_SKIP=""
if [ "$RC" -eq 74 ]; then
  case "$(head -1 "$OUT" 2>/dev/null)" in "AGENT_CALL_REFUSED call-guard repeat "*) RT_CG_SKIP=1 ;; esac
fi
if [ -n "$RT_CG_SKIP" ]; then LANE_TICK skip
else LANE_TICK "$([ "$RC" -eq 0 ] && echo run || echo failed)"; fi
# Coordination DB: close the tick's claim with its real rc. Fail-open; JOB_ID is
# empty whenever the claim did not happen, and job_update is a no-op then.
if [ -n "${JOB_ID:-}" ] && command -v job_update >/dev/null 2>&1; then
  [ -n "${JOB_BEAT:-}" ] && job_beat_stop "$JOB_BEAT"
  job_update "$JOB_ID" stage=done "status=$([ "$RC" -eq 0 ] || [ -n "$RT_CG_SKIP" ] && echo "done" || echo failed)"
fi

# Decision observability (2026-08-23): harvest the session's DECISION lines into
# logs/decisions.log so post-mortems read why a ticket routed the way it did
# instead of excavating transcripts. Fail-open, never affects the tick.
"$HARNESS/bin/decision-log.sh" "$PROJECT" "${GATE_DECISION#RUN }" "$SCOPE_N" "$OUT" 2>>"$ALERTS" || true
# TRIAGE-STATE: the verdicts this session reached, onto the triage_state rows,
# each stamped with the input hash the pre-check computed BEFORE the session
# (bin/lib/triage-state.sh). rc != 0 records nothing. Fail-open, like the line above.
command -v ts_after_session >/dev/null 2>&1 && ts_after_session "$HARNESS" "$PROJECT" "$RC" "$OUT"

# Successful run consumes the gate fingerprint, and stamps the full-sweep clock
# only on a full-scope tick (see rt_gate_consume).
# A FAILING run is counted instead (BH-1021): at TRIAGE_FAIL_CONSUME_AFTER
# consecutive rc!=0 exits on the same fingerprint, rt_gate_fail_consume absorbs
# it anyway and alerts once, so a session that fails every time is not re-bought
# on every cron tick forever. See bin/lib/rt/gate.sh.
if [ "$RC" -eq 0 ]; then
  rt_gate_consume
  rm -f "$HARNESS/state/$PROJECT.gate.fail"
  _rt_tgl && tgl_clear_fail "$HARNESS" "$PROJECT"   # BH-2318: the streak's row ends with it
else
  rt_gate_fail_consume
fi
}

# rt_cg_skip_log — sets BEAT_RC for the console run beat, and on a call-guard
# repeat (RT_CG_SKIP, set by rt_launch above) writes the tick's log line and
# returns 0. That is a skip, not a failure (BH-4120): its own `rc=skip` line, no
# ALERTS line (the driver skips it on RT_CG_SKIP), and an rc 0 beat so Mission
# Control's LAST RESULT does not read FAILED for a guard that did its job.
# Returns 1 on every other rc, and the driver writes its `rc=$RC` line.
rt_cg_skip_log() {
BEAT_RC="$RC"
[ -n "$RT_CG_SKIP" ] || return 1
SUMMARY="call-guard repeat (no new input) — $(head -1 "$OUT" 2>/dev/null | cut -c1-160) [gate=${GATE_DECISION#RUN } scope=$SCOPE_N model=$TRIAGE_MODEL]"
echo "$STAMP [$PROJECT] rc=skip :: $SUMMARY" >> "$LOG"
BEAT_RC=0
}
