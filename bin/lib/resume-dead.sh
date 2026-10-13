#!/bin/bash
# bin/lib/resume-dead.sh — SOURCED by bin/jobs-watchdog.sh, never executed.
# Relaunch builds that died mid-flight, through run-build.sh's checkpoint-resume
# (RESUME_BUILD). Entry point: resume_dead_pass [--dry-run].
#
# WHY IT LIVES HERE NOW (BH-1031, state→DB slice 6). This was bin/resume-dead-builds.sh,
# a SECOND death detector on its own */30 cron, and the fleet had two answers to
# "did this build die": the watchdog's (the job row stopped beating) and this
# one's — a free flock plus twenty quiet minutes. The quiet window was the wrong
# half of that pair and it is gone: twenty quiet minutes is true of a perfectly
# healthy build whose agent is thinking.
#
# So death is the ROW now: a claim that is running and beating is ALIVE, and
# anything else with a build dir and no RESULT is dead.
#
# THE KEY LOCK STAYED, as the local pre-check in front of the ledger test
# (round 1 on #1150). It is not a second detector, it answers a different
# question: `flock` is released by the KERNEL when its holder dies, so a held
# lock is a live process on THIS box and nothing else — which is exactly the
# case the row cannot see. The hub watchdog orphans a claim after ten minutes
# without a beat (one worker blip does that to a build that is still running)
# and the heartbeat route never puts the row back to `running`, so from the row
# alone that live pipeline reads dead. Relaunching it makes run-build take its
# own key lock, fail, and write `BUILD_DEFERRED ... already building` into the
# LIVE build's dir — a false verdict the sweep then reports to the client's
# board, every thirty minutes, until the sixth launch writes BUILD_DEAD there.
# It is the LAST of the three vetoes because it is the only one that costs a
# process (a python3 fcntl probe); the row test and the age test are free, and a
# dir they reject never pays for this one.
#
# AND IT FAILS CLOSED, which is the opposite of everything else in this harness.
# Fail-open here would mean "the ledger did not answer, so every build looks
# dead" — a fleet-wide relaunch storm on the exact event (a worker outage) that
# makes it most expensive. No answer from the ledger = this pass does nothing
# and says so in the log.
#
# WHAT THE ROW GIVES BACK BESIDES DEATH: the attempt bound. A resume asks the
# worker to requeue the row under its lane's retry_policies FIRST; `parked`
# means the policy is out of attempts and the honest outcome is the terminal
# RESULT the sweep reports, `already` means somebody else got there, and `held`
# means another live row owns this ticket — which is what makes "requeued once,
# never twice" a fact about a row rather than a race between two crons. Only
# `queued_for_retry` (and no row at all) reaches a launch. The per-dir counters
# stay as the local backstop for a box whose worker is older than the requeue
# route.
#
# AND THE ROW IS FOUND BY THE TICKET KEY (round 2 on #1150). The claim's
# ticket_id column is what job_open was handed, and run-build.sh hands it "$KEY"
# — never the board id its own job.json records under the same NAME. The two
# are different strings on every product board, so the map below is indexed and
# read by $PROJECT/$KEY on both sides.
#
# AND THE ROW IS LOOKED UP ACROSS STATUSES (round 1 on #1150), because a row
# this pass meets has almost never still `running`: run-build beats its claim
# the instant job_open returns, so a build that died has already been moved to
# `orphaned` (or `queued_for_retry`/`parked`) by the watchdog whose sweep this
# pass runs at the end of. Reading only `running` rows meant the requeue — and
# therefore the lane's retry policy — was never consulted at all, and a ticket
# the hub had PARKED was relaunched anyway.
#
# Seams (tests only; cron sets none): RUN_BUILD, FREE_SLOTS,
# RESUME_ROWS_CMD, RESUME_REQUEUE_CMD, RESUME_LOCK_CMD, RESUME_CAP,
# RESUME_TOTAL_CAP, RESUME_MIN_AGE_MIN. Kill switch: the settings row
# switch.resume-disabled[.<box>] (no row: flags/resume-disabled).
[ -n "${_RESUME_DEAD_LIB:-}" ] && return 0
_RESUME_DEAD_LIB=1

# The REST read the shipped-work guard goes through. Guarded inside the lib, so
# sourcing it twice (the watchdog also arms it) costs nothing.
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/gh-rest.sh"

_rd_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# _rd_rows — the running claims, in bin/jobs-client.sh job_rows' column order.
# rc 1 means THE LEDGER COULD NOT ANSWER (an outage), which is not the same as
# "no rows are running" (rc 0, no output) — and the difference decides whether
# this pass runs at all.
_rd_rows() { # _rd_rows [status]
  if [ -n "${RESUME_ROWS_CMD:-}" ]; then eval "$RESUME_ROWS_CMD \"\${1:-running}\""; return $?; fi
  command -v job_rows >/dev/null 2>&1 || return 1
  job_rows "${1:-running}" 500
}

# _rd_lock_free <lock-file> — rc 0 when NOBODY holds it, 1 when a live process
# does, 2 when we cannot tell (no python3 on the box). Acquire-and-release,
# non-blocking, via python fcntl — flock(1) semantics, portable across the boxes
# and Mac test runs. 2 is treated as 1 by the caller: this pass fails closed, and
# "cannot tell" is never a licence to relaunch a build that may be running.
_rd_lock_free() {
  if [ -n "${RESUME_LOCK_CMD:-}" ]; then eval "$RESUME_LOCK_CMD \"\$1\""; return $?; fi
  command -v python3 >/dev/null 2>&1 || return 2
  python3 - "$1" <<'PY' 2>/dev/null
import fcntl, sys
f = open(sys.argv[1], "a")
try:
    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
sys.exit(0)
PY
}

# _rd_requeue <job-id> <detail> <cap> — prints the worker's decision, or nothing.
_rd_requeue() {
  if [ -n "${RESUME_REQUEUE_CMD:-}" ]; then eval "$RESUME_REQUEUE_CMD \"\$1\" \"\$2\" \"\$3\""; return $?; fi
  command -v job_requeue >/dev/null 2>&1 || return 1
  job_requeue "$1" "$2" "$3"
}

# _rd_switch <root> — rc 0 when switch.resume-disabled[.<box>] (no row: the
# file <root>/flags/resume-disabled) is ON, 1 when not, 2 when lane-switch.sh
# could not load. A subshell: the resolver never reaches the caller.
_rd_switch() {
  ( HARNESS="$1"; . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" >/dev/null 2>&1 || exit 2; lane_switch resume-disabled file ) >/dev/null 2>&1
}

resume_dead_pass() { # resume_dead_pass [--dry-run]
  local H="${HARNESS:-/root/harness}"
  local RUN_BUILD="${RUN_BUILD:-$H/bin/run-build.sh}"
  local FREE_SLOTS="${FREE_SLOTS:-$H/bin/free-slots.sh}"
  local CAP="${RESUME_CAP:-2}" TOTAL_CAP="${RESUME_TOTAL_CAP:-6}"
  # NOT A LIVENESS TEST — a creation race guard. run-build takes its claim
  # within seconds of mkdir, but a dir minted between the ledger read above and
  # this loop would have no row yet and read dead. Minutes, not the old
  # twenty-minute quiet window, and measured on the dir's OWN creation rather
  # than on "any file touched recently", which is what made the old number a
  # (wrong) liveness proxy.
  local MIN_AGE="${RESUME_MIN_AGE_MIN:-10}"
  local DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
  local ALERTS="$H/logs/ALERTS.log" LOG="$H/logs/resume-dead.log"
  local STAMP; STAMP=$(date -u '+%Y-%m-%d %H:%M:%SZ')

  local SW_RC=0
  if _rd_switch "$H"; then return 0; else SW_RC=$?; fi
  [ "$SW_RC" = 2 ] && [ -f "$H/flags/resume-disabled" ] && return 0
  mkdir -p "$H/logs" "$H/locks" 2>/dev/null

  # THE LEDGER FIRST, AND ITS SILENCE IS FATAL TO THIS PASS (see the header).
  local ROWS RC
  ROWS=$(_rd_rows running 2>/dev/null); RC=$?
  if [ "$RC" -ne 0 ]; then
    echo "$STAMP [resume] the ledger could not answer which builds are running — no dir was judged this tick (failing closed: the alternative is a fleet-wide relaunch storm during a worker outage)" >> "$LOG"
    return 0
  fi

  # (project, TICKET KEY) -> the live claim's id, for the rows that are BEATING.
  # A row with no beat at all is not evidence of life: it is the shape a box
  # running a bin/ older than the heartbeat produces, and the watchdog reports it
  # under its own much longer threshold rather than calling it alive here.
  #
  # THE KEY, NOT THE BOARD ID (round 2 on #1150). The row's ticket_id COLUMN is
  # whatever bin/run-build.sh handed job_open, and that call is
  # `job_open "$PROJECT" "$KEY"` — the ticket KEY (TK-42, BH-1031). The build
  # dir's job.json carries BOTH: `.ticket_id` is the BOARD id the build was
  # launched with (a uuid on a product board, an issue number on GitHub) and
  # `.key` is the key. Indexing on one and looking up by the other is a map that
  # never hits in production while every fixture that puts the same string in
  # both columns says it works.
  local -A ALIVE=() JOBID=() JSTAT=()
  local RID RPJ _RK _RS _RBOX RROWKEY RAGE _RB _RSP RBEAT _RATT S OROWS
  while IFS=$'\t' read -r RID RPJ _RK _RS _RBOX RROWKEY RAGE _RB _RSP RBEAT _RATT; do
    [ -n "${RID:-}" ] && [ -n "${RPJ:-}" ] || continue
    JOBID["$RPJ/$RROWKEY"]="$RID"; JSTAT["$RPJ/$RROWKEY"]=running
    case "${RBEAT:-}" in ''|-|null) continue ;; esac
    ALIVE["$RPJ/$RROWKEY"]=1
  done <<< "$ROWS"

  # THE STATUSES A JUDGED BUILD ACTUALLY LANDS IN. These rows are NOT liveness
  # (nothing here can be alive — the sweep above just settled them); they are
  # how the dir's row is FOUND, so the requeue below is asked at all and a
  # ticket the hub parked ends in a terminal RESULT instead of a relaunch. A
  # running row always wins. Failing to read one of these is not fatal: the
  # ledger answered once already, so the pass keeps its local bound.
  # `abandoned` (BH-2406) is asked LAST: it is an operator's final word on a
  # row, and any other row this pass can find for the key (a later attempt) wins.
  for S in orphaned queued_for_retry parked abandoned; do
    OROWS=$(_rd_rows "$S" 2>/dev/null) || continue
    [ -n "$OROWS" ] || continue
    while IFS=$'\t' read -r RID RPJ _RK _RS _RBOX RROWKEY RAGE _RB _RSP RBEAT _RATT; do
      [ -n "${RID:-}" ] && [ -n "${RPJ:-}" ] || continue
      [ -n "${JOBID[$RPJ/$RROWKEY]:-}" ] && continue
      JOBID["$RPJ/$RROWKEY"]="$RID"; JSTAT["$RPJ/$RROWKEY"]="$S"
    done <<< "$OROWS"
  done

  local CANDS; CANDS=$(mktemp "${TMPDIR:-/tmp}/resume-cands.XXXXXX") || return 0
  local D PJ TID KEY A TOT NOW; NOW=$(date +%s)
  command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }
  for D in "$H"/builds/*/; do
    D="${D%/}"; [ -d "$D" ] || continue
    case "$(basename "$D")" in pool-*) continue ;; esac
    [ -f "$D/job.json" ] || continue
    PJ=$(jq -r '.project // ""' "$D/job.json" 2>/dev/null)
    TID=$(jq -r '.ticket_id // ""' "$D/job.json" 2>/dev/null)
    KEY=$(jq -r '.key // ""' "$D/job.json" 2>/dev/null)
    [ -n "$PJ" ] && [ -n "$TID" ] && [ -n "$KEY" ] || continue
    [ -f "$H/flags/builder-fly-$PJ" ] && continue

    if [ -f "$D/RESULT" ]; then
      # A DEFERRED verdict written by a RESUME we launched is weather: clear it,
      # refund the attempt, and let the next quiet window retry. An original
      # run's BUILD_DEFERRED (no resume-attempts) belongs to the triage queue
      # machinery — leave it alone. Everything else with a RESULT is terminal.
      A=$(cat "$D/resume-attempts" 2>/dev/null || echo 0)
      if head -1 "$D/RESULT" 2>/dev/null | grep -q '^BUILD_DEFERRED' && [ "${A:-0}" -gt 0 ]; then
        echo $((A - 1)) > "$D/resume-attempts"
        # The sweep may have COMMENTED the deferral per its SOP — clear it, or
        # the eventual REAL verdict lands in a COMMENTED dir and never reaches
        # the board.
        rm -f "$D/RESULT" "$D/COMMENTED"
        echo "$STAMP [$PJ/$KEY] resume came back BUILD_DEFERRED — attempt refunded, will retry" >> "$LOG"
      fi
      continue
    fi

    # LIVENESS IS THE ROW (BH-1031): a claim that is running and beating is a
    # pipeline that is working anywhere in the fleet, which is the half a lock
    # on one box structurally cannot give. Everything else with no RESULT is a
    # corpse — as far as the ledger can see.
    # Keyed by $KEY, which is what the claim's ticket_id column holds — $TID is
    # the board id and matches a row only by accident (a board whose ids are
    # its keys).
    [ -n "${ALIVE[$PJ/$KEY]:-}" ] && continue
    [ $(( (NOW - $(_rd_mtime "$D/job.json")) / 60 )) -ge "$MIN_AGE" ] || continue

    # ...AND THE KEY LOCK STILL VETOES (round 1 on #1150), for the case the row
    # gets wrong: a build that is STILL RUNNING whose claim the hub watchdog
    # orphaned after a worker blip (the heartbeat route never restores
    # `running`). A live pipeline holds this lock for its whole run and the
    # kernel frees it the moment that process dies, so a held lock is a working
    # build on this box and nothing else. rc 2 (no python3) is "cannot tell",
    # and cannot-tell never relaunches. Asked LAST of the three because it is
    # the only one that costs a process: the two above are free, and a dir they
    # reject never pays for this one.
    _rd_lock_free "$H/locks/build-key-$PJ-$KEY.lock" || continue

    # AN OPERATOR ABANDONED THIS JOB (BH-2406), so it is over: no relaunch, no
    # resume-cap BUILD_DEAD, and nothing for the blocked-resolver to rebuild.
    # Asked before the cap so an abandoned dir never reads as dead-by-cap. The
    # RESULT's `ABANDONED ` prefix is none of br_from_builds' reasons, the
    # marker makes that explicit, and COMMENTED keeps the sweep from reporting
    # it to the board as a verdict. No ALERTS line: this is an obeyed
    # instruction, not an incident.
    if [ "${JSTAT[$PJ/$KEY]:-}" = abandoned ]; then
      if [ "$DRY" = 1 ]; then echo "ABANDONED $D"; continue; fi
      echo "ABANDONED job ${JOBID[$PJ/$KEY]} was abandoned by an operator — final, not resumed and not rebuilt (checkpoints + logs in $D)" > "$D/RESULT"
      : > "$D/.blocked-resolver-abandoned"
      touch "$D/COMMENTED"
      echo "$STAMP [$PJ/$KEY] job ${JOBID[$PJ/$KEY]} was abandoned by an operator — RESULT written, nothing launched" >> "$LOG"
      continue
    fi

    A=$(cat "$D/resume-attempts" 2>/dev/null || echo 0)
    case "$A" in ''|*[!0-9]*) A=0 ;; esac
    TOT=$(cat "$D/resume-total" 2>/dev/null || echo 0)
    case "$TOT" in ''|*[!0-9]*) TOT=0 ;; esac
    if [ "$A" -ge "$CAP" ] || [ "$TOT" -ge "$TOTAL_CAP" ]; then
      if [ "$DRY" = 1 ]; then echo "DEAD-CAP $D"; continue; fi
      echo "BUILD_DEAD resumed $A times ($TOT launches incl. refunded deferrals) without completing — handed to bin/blocked-resolver.sh for a fresh build against current main (checkpoints + logs in $D)" > "$D/RESULT"
      echo "$STAMP [$PJ/$KEY] BUILD_DEAD: resume cap exhausted (attempts=$A/$CAP total=$TOT/$TOTAL_CAP) on $(basename "$D") — RESULT written for the sweep to report" >> "$ALERTS"
      continue
    fi
    printf '%s %s %s %s %s\n' "$(_rd_mtime "$D/job.json")" "$D" "$PJ" "$TID" "$KEY" >> "$CANDS"
  done

  if [ ! -s "$CANDS" ]; then rm -f "$CANDS"; return 0; fi
  read -r _ D PJ TID KEY <<<"$(sort -n "$CANDS" | head -1)"
  rm -f "$CANDS"

  # Slot sanity: don't burn an attempt on a launch that would immediately defer.
  # Through bin/free-slots.sh since 2026-09-11, so this and the launch rules in
  # the prompts cannot answer the same question differently. The project is not
  # passed: the candidate loop has already skipped every fly-routed project, so
  # the only question left here is box-wide, and a box-wide answer is a number.
  local FREE; FREE=$("$FREE_SLOTS" 2>/dev/null | awk '{print $1}')
  case "$FREE" in ''|*[!0-9]*) FREE=0 ;; esac
  [ "$FREE" -lt 1 ] && return 0

  # Shipped-work guard (the TK-42 twin-PR class): if this build recorded its
  # branch, ask GitHub whether that branch's PR already merged or is open — the
  # pipeline died AFTER shipping, so the honest move is the terminal RESULT the
  # sweep knows how to close out, never a relaunch. gh weather -> skip this tick
  # (conservative: a duplicate client-visible PR costs more than a 30-min wait).
  local BR SLUG PRJSON MURL OURL
  if [ -s "$D/branch" ]; then
    BR=$(head -1 "$D/branch")
    local FC="$H/bin/fleet-conf.sh"
    [ -x "$FC" ] || FC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/fleet-conf.sh"
    SLUG=$("$FC" "$PJ" repo 2>/dev/null || true)
    if [ -n "$SLUG" ] && [ "$SLUG" != "-" ]; then
      if ! command -v gh_rest_pr_list_var >/dev/null 2>&1; then   # BH-1485: the name below
        echo "$STAMP [$PJ/$KEY] bin/lib/gh-rest.sh unavailable — cannot check whether this branch already shipped, so nothing is relaunched this tick" >> "$LOG"
        return 0
      fi
      # REST, never the GraphQL-backed `gh pr list` (round 1 on #1150). This
      # read moved onto the hub's */5 sweep with the fold, and #768 is what a
      # rate-limited GraphQL read costs: it answers an EMPTY STRING, which a
      # decision path reads as "no such PR". gh_rest_pr_list separates the two
      # for good — rc 0 with `[]` is a real "no PR", rc 75 is "come back later"
      # — and `head` is owner-qualified because that is what REST requires.
      # BH-1485: the `_var` variant. The capture below used to be `$( )`, so the
      # two variables the next line names were the ones THIS shell last saw —
      # 000 and empty until some other read had run uncaptured. They are real now.
      PRJSON=""
      gh_rest_pr_list_var PRJSON "$SLUG" all "${SLUG%%/*}:$BR" 10 2>/dev/null || PRJSON=""
      if [ -z "$PRJSON" ]; then
        echo "$STAMP [$PJ/$KEY] PR-state check unverifiable (HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}) — skipping resume this tick" >> "$LOG"
        return 0
      fi
      MURL=$(jq -r '[.[] | select(.state == "closed" and .merged_at != null)][0].html_url // ""' <<<"$PRJSON" 2>/dev/null)
      OURL=$(jq -r '[.[] | select(.state == "open")][0].html_url // ""' <<<"$PRJSON" 2>/dev/null)
      if [ -n "$MURL" ]; then
        [ "$DRY" = 1 ] && { echo "SHIPPED-MERGED $D"; return 0; }
        rm -f "$D/COMMENTED"
        echo "PR_MERGED $MURL (recovered by the jobs watchdog's resume pass: pipeline died after ship)" > "$D/RESULT"
        echo "$STAMP [$PJ/$KEY] dead build's branch $BR already MERGED ($MURL) — terminal RESULT written, no resume" >> "$LOG"
        return 0
      elif [ -n "$OURL" ]; then
        [ "$DRY" = 1 ] && { echo "SHIPPED-OPEN $D"; return 0; }
        rm -f "$D/COMMENTED"
        echo "PR_CREATED $OURL (recovered by the jobs watchdog's resume pass: pipeline died after PR creation)" > "$D/RESULT"
        echo "$STAMP [$PJ/$KEY] dead build's branch $BR has an OPEN PR ($OURL) — terminal RESULT written, merge lanes take over" >> "$LOG"
        return 0
      fi
    fi
  fi

  [ "$DRY" = 1 ] && { echo "RESUME $D"; return 0; }

  # THE ROW IS THE BOUND, AND IT IS ASKED BEFORE ANYTHING IS LAUNCHED.
  # `parked` is the lane's retry policy saying it has paid enough for this
  # ticket, and the honest outcome is the same terminal RESULT the local cap
  # writes. `already` is another sweep having got there first — the row is no
  # longer running, so nothing was written, and relaunching on top of it is
  # precisely the double build this pass must not cause.
  local JID="${JOBID[$PJ/$KEY]:-}" JST="${JSTAT[$PJ/$KEY]:-}" DEC="" JUDGE=""
  # A row the hub ALREADY parked needs no second opinion: the requeue route
  # answers `already` for any status but running/orphaned, and acting on that
  # would leave the dir with no verdict at all. Parked IS the policy's answer,
  # so it gets the same terminal RESULT the requeue's own parked branch writes.
  if [ "$JST" = parked ]; then
    echo "BUILD_DEAD the retry policy for this lane is out of attempts (job $JID was parked) — handed to bin/blocked-resolver.sh for a fresh build against current main (checkpoints + logs in $D)" > "$D/RESULT"
    echo "$STAMP [$PJ/$KEY] BUILD_DEAD: job $JID is parked — RESULT written for the sweep to report" >> "$ALERTS"
    return 0
  fi
  # `queued_for_retry` is not asked either (same `already`), and nothing in the
  # fleet consumes such a row today — so the local counters bound it and the
  # resume below is what actually picks the ticket back up. The id still rides
  # into the log line: the row is how a human joins this launch to that ticket.
  if [ -n "$JID" ] && [ "$JST" != queued_for_retry ]; then
    JUDGE=$(_rd_requeue "$JID" "build dir $(basename "$D") has no RESULT and its claim is not beating — resuming from its checkpoints" "$CAP" 2>/dev/null)
    DEC=$(printf '%s' "$JUDGE" | cut -f1)
    case "$DEC" in
      parked)
        echo "BUILD_DEAD the retry policy for this lane is out of attempts ($(printf '%s' "$JUDGE" | cut -f2) of $(printf '%s' "$JUDGE" | cut -f3)) — handed to bin/blocked-resolver.sh for a fresh build against current main (checkpoints + logs in $D)" > "$D/RESULT"
        echo "$STAMP [$PJ/$KEY] BUILD_DEAD: the worker parked job $JID — RESULT written for the sweep to report" >> "$ALERTS"
        return 0 ;;
      already)
        echo "$STAMP [$PJ/$KEY] job $JID is no longer running and was not requeued by us — another sweep owns it; nothing launched" >> "$LOG"
        return 0 ;;
      # `held` is the worker refusing for the strongest reason there is: another
      # LIVE row already owns this project+ticket (or the row is a ticketless
      # lane tick). Launching anyway is the double build — run-build's own
      # job_open refuses with rc 9 and writes BUILD_DEFERRED into this dir, the
      # next tick refunds the attempt but never resume-total, and the dir churns
      # to BUILD_DEAD plus an ALERTS line for a ticket that is being built right
      # now. Same treatment as `already`: log it, launch nothing.
      held)
        echo "$STAMP [$PJ/$KEY] job $JID was not requeued — $(printf '%s' "$JUDGE" | cut -f4); nothing launched" >> "$LOG"
        return 0 ;;
    esac
  fi

  A=$(cat "$D/resume-attempts" 2>/dev/null || echo 0); case "$A" in ''|*[!0-9]*) A=0 ;; esac
  TOT=$(cat "$D/resume-total" 2>/dev/null || echo 0); case "$TOT" in ''|*[!0-9]*) TOT=0 ;; esac
  A=$((A + 1)); echo "$A" > "$D/resume-attempts"
  echo $((TOT + 1)) > "$D/resume-total"
  # A COMMENTED left by a swept deferral must not survive into the relaunch —
  # the real verdict this resume produces still owes the board its close-out.
  rm -f "$D/COMMENTED"
  echo "$STAMP [$PJ/$KEY] resuming dead build $(basename "$D") (attempt $A/$CAP, launch $((TOT + 1))/$TOTAL_CAP, job ${JID:--}, decision ${DEC:--})" >> "$LOG"
  # 9>&- : do NOT let the pipeline inherit the watchdog's overlap-guard flock, or
  # one multi-hour build blocks every future tick on this box.
  RESUME_BUILD="$D" nohup "$RUN_BUILD" "$PJ" "$TID" "$KEY" > "$D/resume-$A.log" 2>&1 9>&- &
  return 0
}
