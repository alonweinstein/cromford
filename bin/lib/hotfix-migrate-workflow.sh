#!/bin/bash
# bin/lib/hotfix-migrate-workflow.sh: the WORKFLOW shape of the hotfix go-live
# stage (BH-370.3). Sourced by bin/hotfix-migrate.sh, never executed; it defines
# hm_workflow, which that stage calls when the mode resolves to `workflow`.
#
# WHY IT EXISTS. Four projects expose /api/internal/migrations and the endpoint
# shape applies their SQL through the app itself. The rest do not: their schema
# moves through a dispatchable GitHub Actions workflow that holds the database
# credential, and this box holds none. So here the stage's job is to DISPATCH
# that workflow, watch the run it started, and post the same proof comment the
# endpoint shape posts. A dispatch is a production write we cannot take back,
# which is why every refusal below happens BEFORE `gh workflow run`:
#
#   * checks not green            -> hold, nothing dispatched
#   * a needs-quiet answer that is neither `yes` nor `no` (or a nonzero exit)
#                                -> hold. An unreadable answer is never a `no`.
#   * a file needs a quiet window and no probe is configured -> hold
#   * the probe never printed exactly `0` inside the window  -> hold
#     (`00`, `0 scans`, ` 0`, an empty line and a nonzero exit are NOT zero)
#   * this fingerprint already has a run     -> watch that run, do not dispatch
#     a second one. An `applied` ledger returns straight away.
#
# And after the dispatch, honesty about what the run did: `applied` is written
# only when `gh run watch --exit-status` returned 0. Our own watch deadline
# (rc 124) records the run's real in-flight word plus its id, so a re-run
# RE-ATTACHES instead of dispatching again; any other nonzero records the
# conclusion GitHub reported. No blanket catch ever says applied.
#
# KNOBS (env/<project>.env, sourced by hm_main; every default documented here):
#   HOTFIX_MIGRATE_WORKFLOW     migrate-manual.yml   the workflow file to run
#   HOTFIX_WORKFLOW_FILES_INPUT files                the -f input carrying the
#                               file list (set it EMPTY to pass no -f at all;
#                               unset means `files`)
#   HOTFIX_WORKFLOW_FILES_SEP   ,                    what joins that list. The
#                               workflow's own parser owns this: project-5's
#                               migrate-manual.yml declares `file`, not `files`.
#   HOTFIX_WORKFLOW_MAX_FILES   (unset = no cap)     how many files that input
#                               can carry. More than this HOLDS before the
#                               dispatch rather than handing the run a token it
#                               cannot parse.
#   HOTFIX_NEEDS_QUIET_CMD      node scripts/migration-sql.mjs --needs-quiet
#                               run in $WT with the migration file appended as
#                               its last argument; must print `yes` or `no`
#   HOTFIX_QUIET_PROBE_CMD      (unset)              run in $WT, must print the
#                               number of active writers; `0` opens the window
# Both of those knobs are a COMMAND AND ITS ARGUMENTS, word-split once and then
# run as argv — never a shell line. The migration path is appended as a separate
# argument, so no filename is ever shell source (a pipeline or a redirect in one
# of these knobs belongs in a wrapper script the knob names).
#   HOTFIX_QUIET_MAX_WAIT       900   seconds to wait for that `0`
#   HOTFIX_QUIET_POLL           30    seconds between probes
#   HOTFIX_RUN_WAIT             1800  seconds to watch the run
#   HOTFIX_RUN_LOCATE_WAIT      60    seconds to find the run we dispatched
# A non-integer value falls back to the default (same shape as HOTFIX_CI_WAIT).
#
# FROM THE STAGE it uses: hm_wait_checks, hm_body_head, hm_revert_lines,
# hm_hold, hm_finish (-> hm_write_ledger + hm_post_proof); and the globals
# PROJECT BUILD SLUG PR_URL BRANCH WT FP FILES LEDGER MODE.
#
# FILES IT WRITES under $BUILD: hotfix-dispatch.txt (the dispatch output),
# hotfix-quiet.err (needs-quiet and probe read errors), hotfix-run-watch.txt,
# hotfix-run-log.txt (the last 60 lines of the run log, capped at 8000 bytes so
# 60 long lines cannot push the proof past GitHub's 65536-char comment limit and
# turn a real apply into `applied` with no comment id).
#
# THE IDENTITY IT RUNS ON. One fleet PAT is one 5000/h REST bucket for every lane
# on every box and one credential whose leak is fleet-wide (#425), so this lane
# arms a short-lived, repo-scoped App token for $SLUG before its first gh call
# and puts the caller's own token back when it returns. A box that mints none
# gets rc 1 from gh_auth_for, with no fork and no new failure mode, and the lane
# runs on exactly the identity it was handed.
#
# EXIT CODES (hm_workflow's return, which hm_main passes through): 0 applied,
# 3 hold — including a green run whose proof comment would not post.

# hm_wf_int <value> <default>: an env knob is an integer or it is the default.
hm_wf_int() {
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

# hm_wf_rtrim <string>: drop trailing whitespace only. Leading whitespace is
# deliberately KEPT: " 0" is not the answer `0`, and trimming it would turn a
# malformed probe answer into an open quiet window.
hm_wf_rtrim() {
  local s="$1"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# hm_wf_files_json <status> [run_id]: the ledger's files[] array, decorated with
# the run id when we have one (hm_write_ledger passes a decorated array through).
hm_wf_files_json() {
  printf '%s\n' "${FILES[@]}" \
    | jq -R -s --arg s "$1" --arg r "${2:-}" \
      'split("\n") | map(select(length > 0))
       | map({path:., status:$s} + (if $r == "" then {} else {run_id:$r} end))'
}

# hm_wf_body <headline> <note> [attach-file]: the proof body, in the shape
# BH-370.2's merge gate and the endpoint shape both read — headline, the files,
# the run (when there is one), the quiet-window decision PER FILE, the run log
# tail, then the revert lines.
hm_wf_body() {
  local headline="$1" note="$2" attach="${3:-}" i
  printf '%s\n\n' "$headline"
  hm_body_head
  [ -n "$note" ] && printf '%s\n\n' "$note"
  [ -n "$RUN_URL" ] && printf 'Workflow run: %s (%s)\n\n' "$RUN_URL" "$WORD"
  i=0
  while [ "$i" -lt "${#FILES[@]}" ]; do
    printf -- '- %s: quiet window: %s\n' "${FILES[$i]}" "${QL[$i]}"
    i=$((i+1))
  done
  printf '\n'
  if [ -n "$RUN_ID" ]; then
    i=0
    while [ "$i" -lt "${#FILES[@]}" ]; do
      printf -- '- %s: %s (run %s)\n' "${FILES[$i]}" "$FSTAT" "$RUN_ID"
      i=$((i+1))
    done
    printf '\n'
    if [ -s "$BUILD/hotfix-run-log.txt" ]; then
      printf 'Run log (last 60 lines), capped at 8 KB:\n\n```\n%s\n```\n\n' "$(cat "$BUILD/hotfix-run-log.txt")"
    else
      printf 'Run log (last 60 lines): we could not read it. That says nothing about the run itself, so it did not change the decision above.\n\n'
    fi
  fi
  if [ -n "$attach" ] && [ -s "$attach" ]; then
    printf 'What we read:\n\n```\n%s\n```\n\n' "$(tail -n 20 "$attach" | head -c 1500)"
  fi
  hm_revert_lines "${FILES[@]}"
}

# hm_wf_stop <decision> <headline> <note> <file-status> <code> [attach-file]:
# ledger, then proof, then the ledger again with the comment id — hm_finish owns
# that order, and owns rc 3 when the comment would not post.
hm_wf_stop() {
  local decision="$1" headline="$2" note="$3" fstat="$4" code="$5" attach="${6:-}"
  local body rc
  body=$(mktemp)
  hm_wf_body "$headline" "$note" "$attach" > "$body"
  hm_finish "$decision" "$body" "$(hm_wf_files_json "$fstat" "$RUN_ID")" "$code"
  rc=$?; rm -f "$body"; return "$rc"
}

# hm_workflow: arm this repo's App token, run the body, put the caller's token
# back. Split in two so the reset happens on ALL of the body's return paths
# rather than being repeated at each of them.
hm_workflow() {
  local hmwrc r="${HARNESS:-${H:-}}"
  # No root = gh-app-auth is not loaded from one (BH-2650): the body runs on
  # the caller's token, as it does on a box without the lib.
  if ! command -v gh_auth_for >/dev/null 2>&1 \
     && [ -n "$r" ] && [ -r "$r/bin/lib/gh-app-auth.sh" ]; then
    # shellcheck source=bin/lib/gh-app-auth.sh
    . "$r/bin/lib/gh-app-auth.sh"
  fi
  if command -v gh_auth_for >/dev/null 2>&1; then gh_auth_for "$SLUG" || true; fi
  hm_workflow_body
  hmwrc=$?
  if command -v gh_auth_reset >/dev/null 2>&1; then gh_auth_reset; fi
  return "$hmwrc"
}

hm_workflow_body() {
  local WF INPUT SEP MAXF NQ PROBE QMAX QPOLL RWAIT LWAIT
  local -a NQA=() PRA=()
  local RUN_ID="" RUN_URL="" WORD="" FSTAT="" HEAD_HOLD HEAD_OK
  local -a QL=() NEEDY=() NEEDYI=()
  local i f out rc

  WF="${HOTFIX_MIGRATE_WORKFLOW:-migrate-manual.yml}"
  # Dash, not colon-dash: set-but-empty means "pass no -f", unset means `files`.
  INPUT="${HOTFIX_WORKFLOW_FILES_INPUT-files}"
  SEP="${HOTFIX_WORKFLOW_FILES_SEP-,}"
  MAXF="${HOTFIX_WORKFLOW_MAX_FILES:-}"
  NQ="${HOTFIX_NEEDS_QUIET_CMD:-node scripts/migration-sql.mjs --needs-quiet}"
  PROBE="${HOTFIX_QUIET_PROBE_CMD:-}"
  # Word-split once, here, so the path below is argv and never shell source.
  eval "NQA=($NQ)" 2>/dev/null || NQA=()
  [ -n "$PROBE" ] && { eval "PRA=($PROBE)" 2>/dev/null || PRA=(); }
  QMAX=$(hm_wf_int "${HOTFIX_QUIET_MAX_WAIT:-900}" 900)
  QPOLL=$(hm_wf_int "${HOTFIX_QUIET_POLL:-30}" 30)
  RWAIT=$(hm_wf_int "${HOTFIX_RUN_WAIT:-1800}" 1800)
  LWAIT=$(hm_wf_int "${HOTFIX_RUN_LOCATE_WAIT:-60}" 60)
  # `timeout 0` is "no limit" in coreutils, the opposite of what a 0 caller means.
  [ "$RWAIT" -ge 1 ] || RWAIT=1
  # And a 0 poll is `sleep 0`: the probe is a live DB query, so an unfloored 0
  # would run it as fast as the box can fork for the whole window.
  [ "$QPOLL" -ge 1 ] || QPOLL=1

  HEAD_HOLD="We held this hotfix and dispatched nothing."
  HEAD_OK="We dispatched this hotfix's migration workflow and it finished green."

  i=0
  while [ "$i" -lt "${#FILES[@]}" ]; do QL+=("not checked"); i=$((i+1)); done

  # ── 1. dedupe BEFORE spend ────────────────────────────────────────────────
  # A dispatch is a production write, so the question "did we already pay for a
  # run of exactly this SQL" is asked first. hm_main's own idempotence block
  # normally catches an `applied` ledger before we are called; the rule lives
  # here too, so it holds wherever this function is called from.
  if [ -s "$LEDGER" ] && [ "$(jq -r --arg fp "$FP" '.fp == $fp' "$LEDGER" 2>/dev/null)" = true ]; then
    local ldec lrun lst
    ldec=$(jq -r '.decision // ""' "$LEDGER" 2>/dev/null)
    lrun=$(jq -r '[.files[]?.run_id // empty] | map(select(. != "")) | .[0] // ""' "$LEDGER" 2>/dev/null)
    lst=$(jq -r '[.files[]?.status // empty] | .[0] // ""' "$LEDGER" 2>/dev/null)
    if [ -n "$lrun" ] && [ "$ldec" = applied ]; then
      cat "$LEDGER"
      return 0
    fi
    # A run id in the ledger means a dispatch we already paid for, so the list
    # below is the SHORT one: only a word GitHub itself finished badly falls
    # through to a fresh dispatch. Everything else re-attaches — including the
    # words step 7 writes when the WATCH misfired rather than the run (a
    # transient `gh run watch` error after a green run records `success`, a
    # watch and a view that both failed record `exit <rc>`). Re-attaching a run
    # that already finished is free: `run watch --exit-status` returns at once
    # and the ledger becomes `applied`. Re-dispatching it applies the SQL twice.
    if [ -n "$lrun" ]; then
      case "$lst" in
        failure|cancelled|timed_out|startup_failure|action_required|dispatch-failed) ;;
        *) RUN_ID="$lrun" ;;
      esac
    fi
  fi

  if [ -z "$RUN_ID" ]; then
    # ── 2. the PR's checks ──────────────────────────────────────────────────
    hm_wait_checks || { hm_hold "checks not green, so we stopped before the dispatch." "$BUILD/hotfix-checks.txt"; return $?; }

    # ── 3. does each file need a quiet window ───────────────────────────────
    i=0
    while [ "$i" -lt "${#FILES[@]}" ]; do
      f="${FILES[$i]}"
      out=$(cd "$WT" && "${NQA[@]}" "$f" 2>>"$BUILD/hotfix-quiet.err"); rc=$?
      out=$(hm_wf_rtrim "$out")
      if [ "$rc" = 0 ] && [ "$out" = yes ]; then
        NEEDY+=("$f"); NEEDYI+=("$i"); QL[i]="waiting"
      elif [ "$rc" = 0 ] && [ "$out" = no ]; then
        QL[i]="not needed"
      else
        QL[i]="HOLD: needs-quiet read error (exit $rc, output '$out')"
        printf 'needs-quiet %s: exit %s, output %s\n' "$f" "$rc" "$out" >> "$BUILD/hotfix-quiet.err"
        hm_wf_stop hold "$HEAD_HOLD" \
          "needs-quiet read error for $f: exit $rc, output '$out'. We do not read that as a no, so nothing was dispatched." \
          hold 3
        return $?
      fi
      i=$((i+1))
    done

    # ── 4. the quiet window ─────────────────────────────────────────────────
    if [ "${#NEEDY[@]}" -gt 0 ]; then
      if [ -z "$PROBE" ]; then
        for i in "${NEEDYI[@]}"; do QL[i]="HOLD: probe not configured"; done
        hm_wf_stop hold "$HEAD_HOLD" \
          "probe not configured: HOTFIX_QUIET_PROBE_CMD is unset and these files need a quiet window: $(printf '%s, ' "${NEEDY[@]}" | sed 's/, $//')." \
          hold 3
        return $?
      fi
      local start deadline now rem last prc waited
      start=$(date +%s); deadline=$(( start + QMAX )); last="never read"
      while :; do
        # No rtrim here: the shell already dropped the trailing newline, and a
        # probe that answered " 0" or "0 scans" has not answered 0.
        out=$(cd "$WT" && "${PRA[@]}" 2>>"$BUILD/hotfix-quiet.err"); prc=$?
        if [ "$prc" = 0 ] && [ -n "$out" ] && [ -z "${out//[0-9]/}" ]; then
          if [ "$out" = 0 ]; then
            waited=$(( $(date +%s) - start ))
            for i in "${NEEDYI[@]}"; do QL[i]="waited ${waited}s, active=0"; done
            break
          fi
          last="active=$out"
        else
          last="read error (exit $prc, output '$out')"
          printf 'quiet probe: %s\n' "$last" >> "$BUILD/hotfix-quiet.err"
        fi
        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
          for i in "${NEEDYI[@]}"; do QL[i]="HOLD: $last"; done
          hm_wf_stop hold "$HEAD_HOLD" \
            "quiet window not reached in ${QMAX}s; last probe: $last" hold 3
          return $?
        fi
        rem=$(( deadline - now )); [ "$rem" -gt "$QPOLL" ] && rem="$QPOLL"
        sleep "$rem"
      done
    fi

    # ── 5. the dispatch ─────────────────────────────────────────────────────
    local stamp joined drc
    local -a args=(workflow run "$WF" -R "$SLUG" --ref "$BRANCH")
    if [ -n "$INPUT" ]; then
      # A cap that the PR does not fit under is a refusal, not a best effort:
      # project-5's migrate-manual.yml takes ONE `file`, and handing it `a,b`
      # fails inside a run we already paid to start.
      if [ -n "$MAXF" ] && [ "${#FILES[@]}" -gt "$MAXF" ]; then
        hm_wf_stop hold "$HEAD_HOLD" \
          "this PR adds ${#FILES[@]} migration files and $WF takes at most $MAXF on its \`$INPUT\` input (HOTFIX_WORKFLOW_MAX_FILES), so more migration files than the workflow can carry would have ridden on one dispatch. Apply them in separate hotfix PRs, or by hand." \
          hold 3
        return $?
      fi
      joined=$(IFS="$SEP"; printf '%s' "${FILES[*]}")
      args+=(-f "$INPUT=$joined")
    fi
    stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    gh "${args[@]}" > "$BUILD/hotfix-dispatch.txt" 2>&1
    drc=$?
    if [ "$drc" != 0 ]; then
      hm_wf_stop hold "$HEAD_HOLD" \
        "workflow dispatch failed (gh exit $drc). Nothing is running, so a re-run is safe." \
        dispatch-failed 3 "$BUILD/hotfix-dispatch.txt"
      return $?
    fi

    # ── 6. which run did we just start ──────────────────────────────────────
    # The newest run created at or after the dispatch stamp. ISO-8601 Z strings
    # compare lexicographically, so this is a string compare on purpose.
    local ldl
    ldl=$(( $(date +%s) + LWAIT ))
    while :; do
      RUN_ID=$(gh run list -R "$SLUG" --workflow "$WF" --branch "$BRANCH" --limit 5 \
                 --json databaseId,createdAt,status 2>/dev/null \
               | jq -r --arg t "$stamp" \
                 '[.[] | select(.createdAt >= $t)] | sort_by(.createdAt) | last | .databaseId // empty' 2>/dev/null)
      [ -n "$RUN_ID" ] && break
      now=$(date +%s)
      [ "$now" -ge "$ldl" ] && break
      rem=$(( ldl - now )); [ "$rem" -gt 5 ] && rem=5
      sleep "$rem"
    done
    if [ -z "$RUN_ID" ]; then
      hm_wf_stop hold "We dispatched this hotfix's migration workflow and then lost sight of it." \
        "dispatched at $stamp but could not locate the run within ${LWAIT}s; check the Actions tab for $WF on $BRANCH before re-running, because a re-run dispatches again." \
        dispatched-unlocated 3 "$BUILD/hotfix-dispatch.txt"
      return $?
    fi
  fi

  # ── 7. watch it ───────────────────────────────────────────────────────────
  local wrc word note
  RUN_URL="https://github.com/$SLUG/actions/runs/$RUN_ID"
  timeout "$RWAIT" gh run watch "$RUN_ID" -R "$SLUG" --exit-status > "$BUILD/hotfix-run-watch.txt" 2>&1
  wrc=$?
  word=$(gh run view "$RUN_ID" -R "$SLUG" --json status,conclusion \
           -q 'if (.conclusion // "") != "" then .conclusion else .status end' 2>/dev/null)
  word=$(hm_wf_rtrim "${word:-}")
  case "$word" in null) word="" ;; esac

  # ── 8. the log tail, best effort ──────────────────────────────────────────
  # Lines AND bytes: 60 lines of a verbose runner can be hundreds of KB, and a
  # body over GitHub's 65536-char comment limit fails to post, which turns a real
  # apply into `applied` with posted_comment_id null (hm_finish's rc 3).
  gh run view "$RUN_ID" -R "$SLUG" --log 2>&1 | tail -n 60 | tail -c 8000 \
    > "$BUILD/hotfix-run-log.txt"

  # ── 9. ledger, then proof ─────────────────────────────────────────────────
  if [ "$wrc" = 0 ]; then
    FSTAT=applied; WORD="${word:-success}"
    hm_wf_stop applied "$HEAD_OK" "" applied 0
    return $?
  fi
  if [ "$wrc" = 124 ]; then
    # OUR deadline, not GitHub's: the run is still going. Recording its real
    # in-flight word plus the id is what lets a re-run re-attach to it instead
    # of dispatching a second one.
    FSTAT="${word:-in_progress}"; WORD="$FSTAT"
    note="watch timed out after ${RWAIT}s. The run is still going; a re-run of this stage re-attaches to it and does not dispatch again."
  else
    FSTAT="${word:-exit $wrc}"; WORD="$FSTAT"
    note="the run did not finish green (gh run watch exit $wrc, GitHub says $FSTAT)."
  fi
  hm_wf_stop hold "We held this hotfix: the migration workflow did not finish green." \
    "$note" "$FSTAT" 3 "$BUILD/hotfix-run-watch.txt"
  return $?
}
