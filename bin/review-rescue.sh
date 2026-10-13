#!/bin/bash
# bin/review-rescue.sh — hub cron (7,37): re-enter builds whose review lane
# stopped without a PR instead of letting them orphan (the operator go 2026-08-13;
# TK-49's review died overnight and the PR sat 20h with only a DRAFT review —
# nothing owned the retry).
#
# THREE ORPHAN SHAPES, one lane:
#
#   A. DIED MID-REVIEW — RESULT says REVIEW_BLOCKED but review.md never reached
#      a VERDICT line: the review session died (timeout, OOM, session kill)
#      between claiming the stage and finishing it. Re-run the review.
#
#   B. FALSELY BLOCKED BY THE TEST-TAMPER GATE (2026-09-13) — RESULT's first
#      line is `REVIEW_BLOCKED test-tamper: …`. On 2026-09-13 thirty-nine pool
#      builds fleet-wide (23 on project-5) held this terminal because the
#      scanner counted a RETITLED or SPLIT test case as a deletion. Their branch
#      was pushed and no PR was ever opened. Four of them even carried a real
#      `VERDICT: APPROVE` from the original round — they were not waiting for a
#      review, they were waiting for a PR. So a test-tamper block is a candidate
#      EVEN WITH a verdict, the gate is RE-RUN here (the scanner has since been
#      fixed), and a standing APPROVE is reused rather than re-bought.
#
# The pipeline treats REVIEW_BLOCKED as terminal, the tier-2 sweep only moves
# completed APPROVEs, and triage's results sweep just alerts — so without this
# lane the PR rots.
#
# Per tick: take the OLDEST unrescued candidates (up to RESCUE_PER_TICK, default
# 3 — the bound on cost), find each one's open PR or pushed branch, and in a
# throwaway worktree with a HARD deadline: re-scan a test-tamper block, merge
# fresh main into the branch, OPEN THE PR if only a branch exists, and either
# reuse a standing APPROVE or re-run the adversarial review.
#
# NOTHING QUEUES BEHIND ANOTHER RESCUE (the operator, 2026-09-13: "change the rule so we
# never lock and serialize"). This lane used to hold ONE global
# locks/review-rescue.lock for the whole tick, so every rescue in the fleet
# waited behind one 40-minute Fable review and 39 stranded builds needed a
# fortnight of ticks. Candidates now run in parallel, RESCUE_PARALLEL (default 8)
# at a time, and the only lock is the per-KEY one bin/run-build.sh already uses —
# taken with `flock -n` purely so a rescue can never race a LIVE build of the
# same key. A held key is skipped, never waited on. On APPROVE -> RESULT becomes `PR_CREATED <url>` with a REAL
# url so the normal merge lanes (tier-1 gate / tier-2 sweep / the operator) take over;
# BLOCK -> leave REVIEW_BLOCKED (now with a genuine verdict) and log it for
# bin/blocked-resolver.sh's fix round; a re-scan that still finds a real deletion
# -> hand the build to that resolver's ADJUDICATE rung, which buys one Fable
# ruling on the deletion instead of waiting for anybody.
# Two attempts max, then the build is retired FROM THIS LANE (not from the
# fleet: the resolver picks it up as a fresh-rebuild candidate) — a rescue that
# hangs (like the 2h zero-output wedge on 2026-08-13) is killed by the deadline
# and counted as an attempt. The RESCUE PATH never touches the ledger: it rewrites
# RESULT, which is what the merge lanes read.
#
# C. NO DIR ON THE HUB (BH-4437) — `ledger_materialize` below. A REVIEW_BLOCKED
#    build with no verdict whose pool box was reaped before its result was
#    relayed exists only in the jobs ledger and on origin. The pass rebuilds its
#    record as builds/pool-<build_dir>/ from the ledger row, and the walk then
#    rescues it like any relayed dir. With no PR and no pushed branch it gets one
#    RESCUE_OUTCOME: no-branch line and one ALERTS line, never a silent retire.
#
# A FOURTH SHAPE, LEDGER-ONLY (BH-858) — `verdict_backfill` below, which runs
# before the candidate walk and shares nothing with it. A record whose terminal
# is PR_CREATE_FAILED and whose review.md ends in VERDICT: APPROVE holds a real
# judgement that was never written down (until BH-858 the verdict row needed a PR
# to exist first). That pass writes ONE settled tier-2 verdict row per such
# record, bound to the sha the review ran on, and pages once when a PR owes a
# verdict nothing here can produce. It opens no PR, buys no review, takes no
# worktree and calls no gh. Cap: VERDICT_BACKFILL_MAX (25).
# Kill switch: the settings row switch.review-rescue-disabled[.<box>], read
# through lane_switch (bin/lib/lane-switch.sh); with no row, flag_active
# review-rescue-disabled when the jobs client is loaded (lane_switch's settings
# fetch loads it; a pause_flags row reconciled into the file, then the file),
# else the bare file, which is what a still-warm settings cache leaves.
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=review-rescue
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# THE ENV LOAD IS ABOVE THE LIB SOURCES ON PURPOSE (#469). bin/lib/gh-app-auth.sh
# and bin/lib/gh-repo-token.sh snapshot "the token this shell started with" AT
# SOURCE TIME, and cron/hub.cron runs this lane with no GH_TOKEN in the crontab
# env. While this load sat at the BOTTOM of the file both snapshots were empty,
# so once bin/ensure-box-gh-app-default.sh logs the hub's keyring out, a
# candidate on a repo the App cannot mint for has no PAT rung left and is left
# un-rescued. bin/run-triage.sh and bin/reconcile-prs.sh load the env here too.
# The knobs below now resolve from global.env as well as from the process env,
# which is what an operator who sets one there already expects.
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-review-rescue
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off review-rescue.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
# The ONE verdict reader (bin/lib/verdict-parse.sh, BH-1625). Missing, every
# verdict reads unknown — never APPROVE.
. "${HARNESS:-/root/harness}/bin/lib/verdict-parse.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/verdict-parse.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit review-rescue
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    review-rescue
command -v verdict_prime >/dev/null 2>&1 && verdict_prime || true
REPOS="${REPOS_ROOT:-/root/repos}"
# The hub clones carry a tokenless https origin and no credential store; the
# merge conductor already solved git auth there (GIT_ASKPASS + token probe).
# BH-4080: the merge identity's defaults (also sourced by merge-conductor-lib).
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/lib/deployment.sh}" || exit 1
. "$H/bin/lib/merge-conductor-lib.sh" 2>/dev/null || { mc_git_auth() { return 1; }; mc_git_auth_clear() { :; }; }
# The hub's default token cannot see every repo (project-5 was invisible to it
# for ten hours on 2026-09-12); gh_repo_use_token picks the token that can, for
# gh AND for mc_git_auth, which reads GH_TOKEN. Absent in the test scratch tree.
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"   # App token per repo (#425); unarmed box untouched
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$H/bin/lib/gh-limit-logger.sh" ] && . "$H/bin/lib/gh-limit-logger.sh"
# shellcheck source=bin/lib/self-heal.sh
[ -r "$H/bin/lib/self-heal.sh" ] && . "$H/bin/lib/self-heal.sh"   # BH-4724: the rescued-APPROVE notice is info
# BH-5125: a BLOCK this lane hands to bin/blocked-resolver.sh is CLAIMED there,
# so the resolver's sweep can say why it has not acted yet and page when it
# never does. Absent on a box whose sync has not landed it: the line is still
# written, nothing is claimed.
# shellcheck source=bin/lib/handoff-watch.sh
[ -r "$H/bin/lib/handoff-watch.sh" ] && . "$H/bin/lib/handoff-watch.sh"
# BH-1651: the ticket-state read is REST. gh-rest.sh sources gh-rest-var.sh.
for _P in "$(dirname "$0")/lib/gh-rest.sh" "$H/bin/lib/gh-rest.sh"; do
  # shellcheck source=bin/lib/gh-rest.sh
  [ -r "$_P" ] && { . "$_P"; break; }
done
# One reset for both halves (#469): the identity tag and the App token, plus the
# PAT probe's own restore for the boxes that have no App configured.
rescue_reset() {
  command -v gh_default_auth_reset >/dev/null 2>&1 && gh_default_auth_reset
  type gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  return 0
}
LOG="$H/logs/review-rescue.log"
# RESCUE_PER_TICK and RESCUE_PARALLEL are registry knobs since BH-1940
# (lane_env_apply above sets them). The 3 below and the 0 at the parallel
# sanitizer only answer when lane-gate.sh or the registry could not run.
RESCUE_PER_TICK="${RESCUE_PER_TICK:-}"
case "$RESCUE_PER_TICK" in ''|*[!0-9]*) RESCUE_PER_TICK=3 ;; esac
# How many candidates may be in flight at once. A rescue is mostly waiting — on
# gh, on a git fetch, on a Fable review — so the cap is about the account and the
# box, not about ordering: they do not touch each other's keys (the per-key flock
# below is what guarantees that) and there is nothing to take turns over.
RESCUE_PARALLEL="${RESCUE_PARALLEL:-}"   # 0 = unlimited (default since 2026-09-14)
# BH-4437: how far back the ledger pass looks for a REVIEW_BLOCKED build with no
# dir on the hub. A registry knob (lane_env_apply above); 168 only answers when
# the registry could not run. It is a read window, so the first tick does not
# materialize every historic REVIEW_BLOCKED row the ledger holds.
RESCUE_LEDGER_LOOKBACK_H="${RESCUE_LEDGER_LOOKBACK_H:-}"
case "$RESCUE_LEDGER_LOOKBACK_H" in ''|*[!0-9]*|0) RESCUE_LEDGER_LOOKBACK_H=168 ;; esac
# RESCUE_ONLY=<project>: restrict a (manual) run to one project's build dirs.
# Oldest-first is right for the cron, wrong for an operator who needs one
# project's stranded builds back before the rest of the fleet's.
RESCUE_ONLY="${RESCUE_ONLY:-}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$(STAMP) $*" >> "$LOG"; }
alert() { HARNESS="$H" "$H/bin/alert-line.sh" "[review-rescue] $*"; }
# Refuse on an empty registry before anything else: an unresolved project below
# writes .review-rescued and gives up on that build permanently, so a registry
# blip would quietly retire every stuck review this lane touched.
# The list is kept: the ledger pass below (BH-4437) walks it.
PROJECTS=$("$H/bin/fleet-projects-or-alert.sh" review-rescue) || exit 1
# shellcheck source=lib/lane-switch.sh
. "$(dirname "$0")/lib/lane-switch.sh" || exit 1
lane_switch review-rescue-disabled && exit 0
# cron's PATH lacks /usr/local/bin, and this lane needs what lives there (claude
# via bin/agent-call.sh, codegraph, rtk). APPENDED, never prepended (BH-1250):
# prepending overrode whatever PATH the caller chose, so on a box that has a gh
# in /usr/local/bin the lane ran THAT gh — on the Fly test host that was the
# host's authenticated gh, talking to example-org/project-5, in place of the
# suite's fake. Appending keeps the cron need and drops the shadowing.
export PATH="$PATH:/usr/local/bin"

slug_for() { awk -v p="$1" '$1==p {print $2}' "$H/fleet.conf"; }
is_tamper_block() { case "$1" in "REVIEW_BLOCKED test-tamper"*) return 0 ;; *) return 1 ;; esac; }

# --- one candidate, start to finish -------------------------------------------
# Returns 0 always: a candidate that cannot be rescued must not stop the tick.
rescue_one() {
  local CAND="$1"
  local BN CORE PROJECT KEY REST SLUG ATT FIRST TAMPER WT MB RC V T RMODEL
  local PRNUM BRANCH PRURL RESCAN RESCAN_NOTE TITLE BODY REUSED PRE PRBF TJOB
  BN=$(basename "$CAND")
  FIRST=$(head -1 "$CAND/RESULT" 2>/dev/null)
  TAMPER=0; is_tamper_block "$FIRST" && TAMPER=1

# >>> build dir project
  # The registry decides which project a build dir belongs to. Under the
  # four-name loop this replaces, a stuck review on any newer project parsed as
  # "cannot parse project/key", got marked rescued, and was dropped — a rescue
  # lane that quietly declined to rescue.
  #
  # `pool-` is the hub's copy marker on a build relayed back from a Fly pool
  # machine (pool-project-5-TK-551-202609131444). Stripped here as well as in
  # project-of.sh --prefix because the KEY is cut from the same string: with the
  # marker left on, every relayed build — which is most of the fleet's builds —
  # parsed as unparseable and was retired without ever being looked at.
  CORE="${BN#pool-}"
  PROJECT=$("${H:-/root/harness}/bin/project-of.sh" --prefix "$CORE" 2>/dev/null || echo "")
  KEY=""
  if [ -n "$PROJECT" ]; then REST="${CORE#"$PROJECT"-}"; KEY="${REST%-*}"; fi
# <<< build dir project
  [ -n "$PROJECT" ] && [ -n "$KEY" ] || { say "$BN: cannot parse project/key — marking rescued"; touch "$CAND/.review-rescued"; return 0; }
  # THE ONLY LOCK IN THIS LANE, AND IT IS DEDUPE. Same file bin/run-build.sh
  # flocks (locks/build-key-<project>-<KEY>.lock), so a rescue can never re-review
  # or re-PR a key a build is working on right now — and `-n`, so a busy key is
  # SKIPPED and re-offered next tick rather than queued behind that build. Runs in
  # this candidate's own subshell, so fd 9 is private to it.
  mkdir -p "$H/locks" 2>/dev/null
  exec 9>"$H/locks/build-key-$PROJECT-$KEY.lock"
  if ! flock -n 9; then
    say "[$PROJECT/$KEY] $BN: key is building right now (build-key lock held) — skipped this tick, nothing waits"
    return 0
  fi
  # INTERLEAVED OUTPUT HAS TO STAY READABLE. With candidates running in parallel
  # the log is no longer one rescue's story told in order, so every line this
  # candidate writes gets its key. Redefined INSIDE rescue_one on purpose: the
  # body runs in this candidate's own subshell, so the override cannot leak into a
  # sibling's, and the `say "$BN: ..."` calls below need no rewriting.
  say()   { echo "$(STAMP) [$PROJECT/$KEY] $*" >> "$LOG"; }
  alert() { HARNESS="$H" "$H/bin/alert-line.sh" "[review-rescue] [$PROJECT/$KEY] $*"; }
  # ...and the raw output of the tools this candidate drives goes to its OWN file
  # rather than into the shared log, where two reviews' stdout would interleave
  # line by line and neither would be readable.
  local CLOG="$CAND/rescue-lane.log"
  SLUG=$(slug_for "$PROJECT")
  # #469: the App token for this repo first, with the PAT probe as its fallback
  # (both inside the helper); rc 1 still means NO token can see this repo, which
  # is still the alert.
  if type gh_default_auth_for_slug >/dev/null 2>&1; then
    if ! gh_default_auth_for_slug "$SLUG"; then
      gh_repo_invisible_alert review-rescue "$SLUG" "cannot rescue $BN — no token can see the repo"
      say "$BN: no gh token can see $SLUG — left un-rescued"
      return 0
    fi
  elif type gh_repo_use_token >/dev/null 2>&1 && ! gh_repo_use_token "$SLUG"; then
    gh_repo_invisible_alert review-rescue "$SLUG" "cannot rescue $BN — no token can see the repo"
    say "$BN: no gh token can see $SLUG — left un-rescued"
    return 0
  else
    command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
  fi
  # A closed ticket is nothing to rescue: the work landed some other way (or was
  # dropped), and a PR opened now for it would only confuse the merge lanes.
  # Costs one API read; retires the dir without spending an attempt or a review.
  # Only for projects whose tickets ARE GitHub issues (board-api-prefix "-" in
  # fleet.conf); a board project's key number is a board id, and `gh issue view`
  # on it would read some unrelated issue or PR.
  local ISSUE ST BPFX
  BPFX=$(awk -v p="$PROJECT" '$1==p {print $4}' "$H/fleet.conf" 2>/dev/null | head -1)
  ISSUE="${KEY##*-}"
  [ "$BPFX" = "-" ] || ISSUE=""
  case "$ISSUE" in ''|*[!0-9]*) ;; *)
    ST=
    command -v gh_rest_issue_state_var >/dev/null 2>&1 && { gh_rest_issue_state_var ST "$SLUG" "$ISSUE" || ST=; }
    if [ "$ST" = closed ]; then
      say "$BN: ticket #$ISSUE is closed — nothing to rescue, retiring"
      touch "$CAND/.review-rescued"; return 0
    fi ;;
  esac
  # THE REVIEWER'S MODEL IS A ROUTE (BH-1510.1): REVIEW_MODEL in env, else this
  # project's rescue.review row. Asked BEFORE an attempt is spent: with no route
  # nothing is bought, the resolver has written the ALERTS line naming the role,
  # and the candidate is offered again next tick with its attempts intact.
  RMODEL="${REVIEW_MODEL:-}"
  if [ -z "$RMODEL" ]; then
    command -v model_for >/dev/null 2>&1 && RMODEL=$(model_for rescue.review "$PROJECT")
    if [ -z "$RMODEL" ]; then
      say "$BN: no model route for rescue.review — not rescued this tick, no attempt spent"
      return 0
    fi
  fi
  ATT=$(( $(cat "$CAND/.rescue-attempts" 2>/dev/null || echo 0) + 1 ))
  echo "$ATT" > "$CAND/.rescue-attempts"
  say "$BN: rescue attempt $ATT (project=$PROJECT key=$KEY)"

  # --- find the PR / branch ---------------------------------------------------
  read -r PRNUM BRANCH PRURL <<<"$(gh pr list -R "$SLUG" --state open --search "$KEY" --json number,headRefName,url \
    --jq 'map(select((.headRefName|ascii_downcase|contains("'"${KEY,,}"'")) or true)) | .[0] | (.number|tostring) + " " + .headRefName + " " + .url' 2>/dev/null)"
  # 2026-09-13: without credentials every ls-remote here came back empty and 23
  # rescuable project-5 builds were retired as "no open PR or branch found".
  # A local (path) origin, as in the tests, needs nothing.
  case "$(git -C "$REPOS/$PROJECT" remote get-url origin 2>/dev/null)" in
    https://*) mc_git_auth "$SLUG" >/dev/null 2>&1 || say "$BN: no git credential could read $SLUG — branch lookup may come back empty" ;;
  esac
  if [ -z "${BRANCH:-}" ]; then
    # captured first: head on a git pipe is a SIGPIPE race under pipefail (BH-1248)
    BRANCH=$(git -C "$REPOS/$PROJECT" ls-remote --heads origin "*${KEY,,}*" 2>/dev/null)
    BRANCH=${BRANCH%%$'\n'*}; BRANCH=${BRANCH##*refs/heads/}
    PRURL=""; PRNUM=""
  fi
  if [ -z "${BRANCH:-}" ]; then
    say "$BN: no open PR or branch found for $KEY — nothing to re-review here; bin/blocked-resolver.sh rebuilds the ticket fresh against current main."
    # BH-4437: a record this lane MATERIALIZED from the ledger (its box was
    # reaped) gets a terminal line and one page, never a silent retire. Record,
    # then alert, then the marker below: a crash before the marker re-enters next
    # tick, and the RESCUE_OUTCOME guard stops a second record and a second page.
    if [ -f "$CAND/.rescue-materialized" ] && ! grep -q '^RESCUE_OUTCOME:' "$CAND/RESULT" 2>/dev/null; then
      local MJOB
      MJOB=$(sed -n 's/^JOB_ID: //p' "$CAND/RESULT" 2>/dev/null | head -1)
      echo "RESCUE_OUTCOME: no-branch $(STAMP) — no open PR and no pushed branch for $KEY; handed to bin/blocked-resolver.sh" >> "$CAND/RESULT"
      alert "$BN: materialized from the ledger (box reaped) but no open PR or pushed branch exists — nothing to re-review; retired to bin/blocked-resolver.sh for a fresh rebuild (job ${MJOB:-unknown})"
    fi
    mc_git_auth_clear
    rescue_reset
    touch "$CAND/.review-rescued"; return 0
  fi

  # --- a throwaway worktree on the pushed head --------------------------------
  git -C "$REPOS/$PROJECT" fetch -q origin 2>/dev/null
  WT=$(mktemp -d /tmp/rescue-XXXX)
  rmdir "$WT"
  if ! git -C "$REPOS/$PROJECT" worktree add -q --detach "$WT" "origin/$BRANCH" 2>>"$CLOG"; then
    say "$BN: worktree add failed for origin/$BRANCH"; return 0
  fi
  # The head this rescue starts from: the main-merge push below leases on it.
  RESCUE_LEASE=$(git -C "$WT" rev-parse HEAD 2>/dev/null)

  # --- re-run the gate that blocked it ----------------------------------------
  # The scanner that wrote this terminal counted retitles as deletions. Re-run
  # it on the pushed head before spending anything else: rc 1 is a REAL deletion
  # with no justification and goes to the resolver's adjudication rung; rc 0/2 clears the block
  # and the report is pasted into the review prompt; any other rc could not
  # verify and must NOT block — the same degrade run-build.sh applies (F27).
  RESCAN_NOTE=""
  if [ "$TAMPER" -eq 1 ]; then
    MB=$(git -C "$WT" merge-base origin/main HEAD 2>/dev/null)
    if [ -z "$MB" ]; then
      say "$BN: no merge base against origin/main — test-tamper re-scan skipped, NOT blocking"
      RESCAN_NOTE=$'\n''TEST-TAMPER RE-SCAN: could not run (no merge base against origin/main) — integrity was NOT re-checked mechanically here; read the test diff yourself.'
    else
      RESCAN=$( cd "$WT" && BUILD_DIR="$CAND" "$H/bin/test-tamper-scan.sh" "$MB" . 2>&1 ); RC=$?
      printf '%s\n' "$RESCAN" > "$CAND/test-tamper-rescan.txt"
      case "$RC" in
        0|2)
          say "$BN: test-tamper re-scan rc=$RC — the block does not stand, continuing"
          RESCAN_NOTE=$'\n'"TEST-TAMPER RE-SCAN (rc=$RC): this build was blocked by an earlier version of the scanner; the re-scan below is the current one. Adjudicate it, it is not a free pass:"$'\n'"$RESCAN" ;;
        1)
          alert "$BN: still blocked after re-scan — a test was really deleted. Retired from THIS lane and handed to bin/blocked-resolver.sh, which buys one adversarial ruling on the deletion (ACCEPT writes the TEST-CHANGE justification and the build resumes, REJECT rebuilds the ticket with the tests intact). Nobody is waiting on a person; report in $CAND/test-tamper-rescan.txt"
          say "$BN: test-tamper re-scan rc=1 — real deletion, retiring to the blocked-resolver"
          touch "$CAND/.review-rescued"
          git -C "$REPOS/$PROJECT" worktree remove --force "$WT" 2>/dev/null
          mc_git_auth_clear
          rescue_reset
          return 0 ;;
        *)
          say "$BN: test-tamper re-scan did not run (rc=$RC, not blocking): $(head -1 <<<"$RESCAN")"
          RESCAN_NOTE=$'\n'"TEST-TAMPER RE-SCAN: scan_failed (rc=$RC) — integrity was NOT re-checked mechanically on this build; read the test diff yourself:"$'\n'"$RESCAN" ;;
      esac
    fi
  fi

  # --- a verdict needs somewhere to land: open the PR if only a branch exists --
  # This lane used to write `PR_CREATED ` with an EMPTY url whenever it had found
  # a branch rather than a PR — a terminal every close-out handler in the fleet
  # reads and none of them can act on. A branch with no PR gets a PR first.
  if [ -z "${PRURL:-}" ]; then
    # FRESH MAIN FIRST (2026-09-13). These branches were pushed hours or days ago
    # and nothing has moved them since. A PR opened on a stale head is reviewed
    # against a diff nobody will merge — the merge lanes then have to rebase it,
    # and the reviewed sha stops matching the head, which parks the PR. So main is
    # merged INTO the branch here, in this candidate's own worktree, and the merge
    # is pushed before the PR exists. `--no-edit` because a rescue has nothing to
    # say in a merge message.
    #
    # A CONFLICT IS NOT THIS LANE'S JOB. It opens no PR at all and leaves the
    # candidate where the resolver lane finds it — opening a conflicted PR would
    # only park it one step further downstream, with a review bought for a diff
    # that cannot land.
    # Identity is passed -c, same as lander.sh: CI runners and some boxes have
    # no user.email, and `merge --no-edit` writes a commit. Without -c the merge
    # fails "Please tell me who you are" and the next lines used to stamp
    # .conflicts-with-main for that too — every clean rescue looked conflicted
    # (Harness CI on this PR, 2026-09-13, 14 false fails).
    if ! git -C "$WT" -c user.name="$HARNESS_MERGE_GIT_NAME" -c user.email="$HARNESS_GIT_EMAIL" merge --no-edit origin/main >>"$CLOG" 2>&1; then
      CONFLICTED=$(git -C "$WT" status --porcelain 2>/dev/null | grep -cE '^(UU|AA|DD|AU|UA)')
      git -C "$WT" merge --abort 2>/dev/null
      if [ "${CONFLICTED:-0}" -gt 0 ]; then
        : > "$CAND/.conflicts-with-main"
        say "$BN: conflicts with main on $BRANCH — no PR opened, left for the resolver"
      else
        say "$BN: merge origin/main failed without conflicts (see $CLOG) — left un-rescued this tick"
      fi
      git -C "$REPOS/$PROJECT" worktree remove --force "$WT" 2>/dev/null
      mc_git_auth_clear
      rescue_reset
      return 0
    fi
    rm -f "$CAND/.conflicts-with-main"
    # The ticket's hold is re-read at the push and the branch must still be at
    # the head this rescue found (BH-2504, bin/lib/hold-push.sh).
    if ! { command -v hold_push >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/hold-push.sh" 2>/dev/null || . "$H/bin/lib/hold-push.sh" 2>/dev/null; } \
       || ! HOLD_PUSH_LOG="$CLOG" hold_push "$PROJECT" - "$WT" origin HEAD "$BRANCH" "${RESCUE_LEASE:-x}" >>"$CLOG" 2>&1; then
      # The merge is local-only, so the PR would show the stale diff. Worth
      # opening anyway — a PR that exists can be rebased by the merge lanes, a
      # branch with no PR is invisible to all of them — but it says so.
      say "$BN: could not push the main merge to $BRANCH (see $CLOG) — opening the PR on the pushed head as it stands"
    fi
    TITLE=$(git -C "$REPOS/$PROJECT" log -1 --format=%s "origin/$BRANCH" 2>/dev/null)
    TITLE=${TITLE:0:80}
    [ -n "$TITLE" ] || TITLE=$(grep -m1 '^#' "$CAND/plan.md" 2>/dev/null | sed 's/^#\{1,\}[[:space:]]*//' | head -c 80)
    [ -n "$TITLE" ] || TITLE="rescued build $BN"
    BODY=$(printf 'Rescued by `bin/review-rescue.sh` on %s: this build %s, so its branch was pushed and no pull request was ever opened.\n\nPlan: `%s`\n\n%s\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\n' \
      "$(STAMP)" \
      "$([ "$TAMPER" -eq 1 ] && echo 'was blocked by a test-tamper false positive (retitled test cases counted as deletions)' || echo 'died mid-review')" \
      "$CAND/plan.md" \
      "${RESCAN_NOTE:-No test-tamper re-scan was needed for this build.}")
    # >>> pr trailers (BH-3987)
    # THE PR SAYS WHO BUILT IT: the build's own job (its pr-body.md trailer, else
    # its job.json), never this lane's exported JOB_ID. The body goes through a
    # file so the block can be applied. With no file to write, the same create
    # reads the untrailered body from stdin and one line says so.
    PRBF=$(mktemp "${TMPDIR:-/tmp}/rescue-body-XXXX" 2>/dev/null) \
      && { printf '%s\n' "$BODY" > "$PRBF"; } 2>/dev/null || { rm -f "$PRBF"; PRBF=""; }
    [ -r "${H:-}/bin/lib/pr-trailers.sh" ] && . "$H/bin/lib/pr-trailers.sh"
    if [ -n "$PRBF" ] && command -v pr_trailers_apply >/dev/null 2>&1; then
      TJOB=$(pr_trailers_read "$CAND/pr-body.md" 2>/dev/null | cut -f1)
      case "$TJOB" in ""|none) TJOB=$(JOB_ID='' pr_trailers_job_for "$CAND") ;; esac
      pr_trailers_apply "$PRBF" "$TJOB" "$KEY" || say "$BN: pr trailers: could not write $PRBF — PR opened without trailers"
    elif [ -z "$PRBF" ]; then
      say "$BN: pr trailers: no body file could be written in ${TMPDIR:-/tmp} — PR opened without trailers"
    fi
    PRURL=$(gh pr create -R "$SLUG" --head "$BRANCH" --base main --title "$KEY: $TITLE" --body-file "${PRBF:--}" <<<"$BODY" 2>>"$CLOG" | grep -oE 'https://[^[:space:]]+' | tail -1)
    [ -z "$PRBF" ] || rm -f "$PRBF"
    # <<< pr trailers
    # gh refuses when the head already has an open PR. The PR existing IS
    # success — adopt its url rather than shipping an empty one.
    [ -n "$PRURL" ] || PRURL=$(gh pr list -R "$SLUG" --head "$BRANCH" --state open --json url -q '.[0].url' 2>/dev/null)
    if [ -z "$PRURL" ]; then
      alert "$BN: could not open a PR for branch $BRANCH (attempt $ATT of 2) — left un-rescued, retried next tick; gh stderr in $CLOG."
      say "$BN: gh pr create failed for $BRANCH — leaving un-rescued"
      git -C "$REPOS/$PROJECT" worktree remove --force "$WT" 2>/dev/null
      mc_git_auth_clear
      rescue_reset
      return 0
    fi
    say "$BN: opened $PRURL for branch $BRANCH (a pushed branch with no PR)"
  fi

  # --- reuse a standing verdict, or re-run the review --------------------------
  # The one shared reader (bin/lib/verdict-parse.sh, BH-1625), kept in the
  # "VERDICT: <word>" shape the case below matches; unknown is empty.
  V=$(verdict_parse -L "$CAND/review.md" 2>/dev/null) && V="VERDICT: $V" || V=""
  T=$(grep -oE "TIER: [12]" "$CAND/review.md" 2>/dev/null | tail -1)
  REUSED=0
  if [ "$TAMPER" -eq 1 ] && [ "$V" = "VERDICT: APPROVE" ]; then
    # The review already happened and APPROVEd; the gate refused AFTER it. Buying
    # the same review a second time would cost a full Fable run to learn what is
    # already written down.
    REUSED=1
    say "$BN: reusing the standing $V ($T) from the original round — the gate blocked after the review, not before it"
  else
    PROMPT="Adversarially review the diff of origin/main...HEAD in this repo for ticket $KEY (branch $BRANCH${PRNUM:+, PR #$PRNUM}), against the plan at $CAND/plan.md if present and the iron laws in ~/.claude/CLAUDE.md. Rules: /root/harness/prompts/build-discipline.md — cite rule ids (D1-D27) in findings. A prior review round DIED MID-RUN leaving a draft in $CAND/review.md — supersede it: REWRITE $CAND/review.md as the complete review. Judge correctness, edge cases, test honesty (do new tests fail if the feature breaks?), the touched-file UI iron laws, and security basics (authz on changed routes, injection, secrets).${RESCAN_NOTE} Second-to-last line exactly 'TIER: 1' or 'TIER: 2'. Last line exactly VERDICT: APPROVE or VERDICT: BLOCK."
    PRE=$(cksum < "$CAND/review.md" 2>/dev/null)
    ( cd "$WT" && AGENT_CALL_ROLE=rescue.review timeout -k 60 2400 "$H/bin/agent-call.sh" review "$PROJECT" "$RMODEL" 2100 "$CAND/rescue-review-run.txt" "$PROMPT" ) >>"$CLOG" 2>&1
    # BH-118: the draft this rewrites was usually harvested already, and
    # bin/findings-log.sh skips a lens whose marker exists. A changed review.md
    # is new content, so its marker goes and the next harvest reads it once. An
    # agent that wrote nothing leaves the marker, so nothing is logged twice.
    [ "$PRE" != "$(cksum < "$CAND/review.md" 2>/dev/null)" ] && rm -f "$CAND/.findings-general"
    V=$(verdict_parse -L "$CAND/review.md" 2>/dev/null) && V="VERDICT: $V" || V=""
    T=$(grep -oE "TIER: [12]" "$CAND/review.md" 2>/dev/null | tail -1)
  fi
  git -C "$REPOS/$PROJECT" worktree remove --force "$WT" 2>/dev/null
  mc_git_auth_clear
  rescue_reset

  # --- act on the verdict -----------------------------------------------------
  case "$V" in
    "VERDICT: APPROVE")
      # ADDITIVE, NOT WHOLESALE (BH-1301). This used to be three echo lines into
      # `> "$CAND/RESULT"`, which threw away everything else the file held —
      # `TICKET_ID:`, `SOURCE:`, `JOB_ID:`, `BUILT_AS:`, `BUILD_DIR:`. The
      # candidate walk is `find $H/builds -maxdepth 2 -name RESULT`, so relayed
      # and ledger-staged dirs are candidates too, and those lines are how
      # bin/lib/rt/staging.sh tells one build of a ticket from another: a
      # marker-less dir made its dedup blind and the next result for that ticket
      # was consumed instead of staged — a close-out nothing retries.
      #
      # So: the new header, then every old line except the one it replaces
      # (line 1) and the keys it rewrites. Written to .tmp and moved into place,
      # because reading and truncating one file in a single pipeline empties it.
      { echo "PR_CREATED ${PRURL}"; [ -n "$T" ] && echo "$T"
        if [ "$REUSED" -eq 1 ]; then echo "RESCUED: test-tamper block re-scanned clean $(STAMP); the original APPROVE stands and the PR was opened"
        else echo "RESCUED: review re-run $(STAMP) after died-mid-review orphan"; fi
        # An old TIER: line is dropped only when this rescue HAS a tier of its
        # own; with no verdict tier to write, the original's is the record. An
        # unreadable old RESULT degrades to the three-line file written above.
        if [ -n "$T" ]; then sed -e 1d -e '/^RESCUED: /d' -e '/^TIER: /d' "$CAND/RESULT" 2>/dev/null
        else                sed -e 1d -e '/^RESCUED: /d' "$CAND/RESULT" 2>/dev/null; fi
      } > "$CAND/RESULT.tmp" && mv -f "$CAND/RESULT.tmp" "$CAND/RESULT"
      touch "$CAND/.review-rescued"
      # A self-heal, not a page (BH-4724): info plus a self_heal ledger row, the
      # text the alert wrapper would build. No lib on this box -> the raw info line.
      local SH_MSG="[review-rescue] [$PROJECT/$KEY] $BN: rescued review = APPROVE ($T) — ${PRURL:-branch $BRANCH} now flows through the normal merge lanes."
      { command -v self_heal_note >/dev/null 2>&1 && self_heal_note review-rescue "$PROJECT/$KEY:$(basename "$CAND")" "$SH_MSG"; } \
        || HARNESS="$H" "$H/bin/alert-line.sh" --severity info "$SH_MSG"
      say "$BN: APPROVE ($T) — RESULT upgraded to PR_CREATED" ;;
    "VERDICT: BLOCK")
      touch "$CAND/.review-rescued"
      # SAY WHAT HAPPENS NEXT, NOT WHAT WE WISH HAPPENED (BH-5125). This line
      # used to promise "an agent fix round". br_from_builds offers a plain
      # REVIEW_BLOCKED record as rescue-giving-up, which br_action sends to a
      # fresh REBUILD, and only once the RESULT is 90 minutes old. An open PR's
      # own review verdict reaches the fix round on a separate source.
      # The floor is the lib's mirror of br_from_builds' `-mmin +90`; 5400 is
      # that same floor for a box that has not landed the lib yet.
      local nb=0 at="(its RESULT's age unknown)" floor=5400
      [ -n "${BHW_BUILD_FLOOR_S-}" ] && floor=$BHW_BUILD_FLOOR_S
      nb=$(stat -c %Y "$CAND/RESULT" 2>/dev/null) && nb=$(( nb + floor )) \
        && at=$(date -u -d "@$nb" +%H:%MZ 2>/dev/null) || { nb=0; at="(its RESULT's age unknown)"; }
      say "$BN: rescued review = BLOCK — the record stays REVIEW_BLOCKED; bin/blocked-resolver.sh offers it as rescue-giving-up (a fresh rebuild) from $at (its RESULT's 90-minute floor). An open PR's own review verdict reaches the resolver's fix round separately (br_from_reviews); ${PRURL:-branch $BRANCH}; findings in $CAND/review.md."
      command -v bhw_claim >/dev/null 2>&1 \
        && bhw_claim "$PROJECT" "$KEY" "${PRURL:--}" review-rescue "$nb" "rescued review = BLOCK; rescue-giving-up from $at"
      say "$BN: BLOCK — fix round needed" ;;
    *)
      say "$BN: attempt $ATT produced no VERDICT (killed at deadline or died again)" ;;
  esac
  return 0
}

# --- BH-858: the strandee whose verdict was never recorded ---------------------
# A record whose terminal is `PR_CREATE_FAILED` but whose review.md ends in
# `VERDICT: APPROVE` is not a build waiting for a review — a reviewer read the
# diff and answered, and the only thing that died was `gh pr create` (the App
# installation's GraphQL budget, fifteen builds fleet-wide on 2026-09-18). Until
# BH-858 the verdict row was written only after a PR existed, so those judgements
# are in no ledger at all, and this lane walked straight past them because it
# keys on REVIEW_BLOCKED.
#
# TWO LINE-1 SHAPES WEAR THE SAME FACTS. bin/pr-url-reconcile.sh relinks a
# strandee to the PR somebody opened by hand and rewrites line 1 to `PR_CREATED
# … | RECONCILED …`, keeping the create failure as `RECONCILED_FROM:`. It ticks
# three times as often as this lane, so it gets to every one of those records
# first — a backfill that only knew `PR_CREATE_FAILED` would find none of them.
#
# One bounded pass, BEFORE the candidate selection below, which it does not
# touch: neither shape a backfill walks can contain REVIEW_BLOCKED, which is what
# a rescue candidate's line 1 must say, so the two can never fight over a dir.
#
# TIER 2, ALWAYS. The build never finished its pipeline — QA, E2E, scope, kind
# and the head-bound gate never ran on it, and tier 1 means auto-merge. Tier 2
# sends it through the hub's reviewed tier-2 sweep instead.
# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/model-route.sh
[ -r "$H/bin/lib/model-route.sh" ] && . "$H/bin/lib/model-route.sh"
# The knob. env/global.env is loaded at the TOP of this file (see the note
# there), so VERDICT_BACKFILL_MAX is already exported when it is set; the file
# read below is the fallback for a tree where it is not.
VB_MAX="${VERDICT_BACKFILL_MAX:-}"
[ -n "$VB_MAX" ] || VB_MAX=$(sed -n 's/^[[:space:]]*VERDICT_BACKFILL_MAX=//p' "$HENV/global.env" 2>/dev/null | head -1 | tr -d "\"' ")
case "$VB_MAX" in ''|*[!0-9]*) VB_MAX=25 ;; esac

verdict_backfill() {
  local n=0 D BN FIRST V PROJECT CORE REST KEY JOB RC STATE RSHA PROV WHY
  command -v job_for_record >/dev/null 2>&1 || return 0
  for D in "$H"/builds/*/; do
    [ "$n" -lt "$VB_MAX" ] || break
    D="${D%/}"
    [ -f "$D/RESULT" ] || continue
    # Write-then-mark, and the marker is the whole idempotency story: it is only
    # reached after a row landed, or after an alert was written.
    [ -f "$D/.verdict-backfilled" ] && continue
    # bin/blocked-resolver.sh ran its ladder and closed this one out.
    [ -f "$D/.blocked-resolver-abandoned" ] && continue
    FIRST=$(head -1 "$D/RESULT" 2>/dev/null)
    # BOTH SHAPES A STRANDEE WEARS. bin/pr-url-reconcile.sh rewrites line 1 to
    # `PR_CREATED <url> | RECONCILED …` as soon as it finds the PR somebody
    # opened by hand, and keeps the create failure one line down as
    # `RECONCILED_FROM:`. That lane ticks every 10 minutes and this one every
    # 30, so for the population this ticket was filed about — builds whose PR
    # already exists on the branch — the reconciler always wins the race, and
    # RECONCILED is the only shape the backfill ever meets. Keying on
    # PR_CREATE_FAILED alone walks past every one of them.
    case "$FIRST" in
      PR_CREATE_FAILED*) ;;
      "PR_CREATED "*" | RECONCILED "*)
        # The rewritten line 1 says nothing about how the build ENDED; only the
        # preserved original does. A record the builder linked itself carries no
        # RECONCILED_FROM line at all and is not a strandee.
        grep -q '^RECONCILED_FROM: PR_CREATE_FAILED' "$D/RESULT" || continue ;;
      *) continue ;;
    esac
    BN=$(basename "$D")
    CORE="${BN#pool-}"; CORE="${CORE#fly-}"
    PROJECT=$("$H/bin/project-of.sh" --prefix "$CORE" 2>/dev/null || echo "")
    KEY=""
    if [ -n "$PROJECT" ]; then REST="${CORE#"$PROJECT"-}"; KEY="${REST%-*}"; fi
    [ -n "$PROJECT" ] && [ -n "$KEY" ] || { say "$BN: cannot parse project/key — no verdict backfilled, and nothing marked"; continue; }
    n=$((n+1))
    # THE VERDICT LINE IN THE FINAL BLOCK, and only a line that starts with it
    # (bin/lib/verdict-parse.sh, BH-1625): a review that quotes
    # `VERDICT: APPROVE` in its findings and ends in BLOCK is a BLOCK, and a
    # review whose own last line was lost in relay must not have a quotation
    # promoted into a judgement.
    V=$(verdict_parse -L "$D/review.md" 2>/dev/null) || V=""
    if [ "$V" = BLOCK ]; then
      say "[$PROJECT/$KEY] $BN: the create failed on a BLOCKed build — no verdict is owed"
      touch "$D/.verdict-backfilled"; continue
    fi
    JOB=$(job_for_record "$PROJECT" "$BN"); RC=$?
    if [ "$RC" = 1 ]; then
      say "[$PROJECT/$KEY] $BN: the ledger did not answer which job wrote this record — nothing written, nothing marked, the next tick retries"
      continue
    fi
    if [ "$V" != APPROVE ] || [ -z "$JOB" ]; then
      WHY="no VERDICT line in review.md"
      [ "$V" = APPROVE ] && WHY="no job row names this build dir"
      alert "[$PROJECT/$KEY] $BN died at PR create and owes a verdict this lane cannot backfill ($WHY); the merge conductor's head-bound re-review is the only path left — if it is not armed, review the PR by hand"
      touch "$D/.verdict-backfilled"; continue
    fi
    STATE=$(job_verdict_state "$JOB"); RC=$?
    if [ "$RC" = 1 ]; then
      say "[$PROJECT/$KEY] $BN: the ledger would not say whether job $JOB owns a verdict — nothing written, nothing marked, the next tick retries"
      continue
    fi
    if [ "${STATE%%	*}" = settled ]; then
      say "[$PROJECT/$KEY] $BN: job $JOB already carries a settled verdict — nothing owed"
      touch "$D/.verdict-backfilled"; continue
    fi
    # The sha the review ran on, in order of how close it is to the review:
    # `reviewed-sha` is what bin/fly-results-ingest.sh relays with the record,
    # `review-head` is the builder's own copy, and the provisional row's own
    # reviewed_sha is what the build recorded before it died. Empty is OMITTED —
    # a blank sha reads as a claim about the head.
    RSHA=$(head -1 "$D/reviewed-sha" 2>/dev/null || true)
    [ -n "$RSHA" ] || RSHA=$(head -1 "$D/review-head" 2>/dev/null || true)
    if [ -z "$RSHA" ] && [ "$RC" = 0 ]; then
      RSHA="${STATE#*	}"; [ "$RSHA" = "-" ] && RSHA=""
    fi
    [ -n "$RSHA" ] || say "[$PROJECT/$KEY] $BN: no record of the sha this review ran on — the row is written without one rather than claiming a head"
    # Provenance from pipeline.log, the same read bin/merge-sweep.sh and
    # mc_verdict make on a record: the `.runner` sidecars are not relayed to the
    # hub, so a demoted review announces itself here or nowhere.
    PROV=claude
    grep -q 'judge provenance' "$D/pipeline.log" 2>/dev/null && PROV=fallback
    if job_artifact_put verdict APPROVE \
        "$(jq -nc --arg p "$PROV" --arg r "$BN" --arg s "$RSHA" \
            '{tier:"2",provenance:$p,record:$r,settled:true,source:"review-rescue-backfill"}
             + (if $s == "" then {} else {reviewed_sha:$s} end)' 2>/dev/null)" "$JOB" >/dev/null 2>&1; then
      say "[$PROJECT/$KEY] $BN: backfilled the ledger verdict APPROVE (tier 2, job $JOB, provenance $PROV, reviewed sha ${RSHA:-none}) from the review this build did buy"
      touch "$D/.verdict-backfilled"
    else
      say "[$PROJECT/$KEY] $BN: the verdict row would not write (job $JOB) — nothing marked, the next tick retries"
    fi
  done
}
verdict_backfill

# --- BH-4437: the REVIEW_BLOCKED build whose pool box was reaped ---------------
# The candidate walk below reads only the hub's builds/. A pool build whose
# review died, on a machine reaped before its result was relayed, never gets a
# dir there — but the ledger still holds its `result` row (build_dir, key, box,
# job) and its branch is still on origin. This pass rebuilds the hub-side record
# as builds/pool-<build_dir>/, the name a relayed copy of that build would have
# had, so bor_local_dir, bin/blocked-resolver.sh and bin/stale-owed-tickets.sh
# all map the ledger row to it with no change of their own. The walk then finds
# it the same tick (its RESULT carries the ledger's age) and rescue_one re-runs
# the review on the pushed head, exactly as for a relayed dir.
#
# A row qualifies only when ALL hold — the same orphan test stale-owed pages on:
# line 1 REVIEW_BLOCKED; a plain build_dir and a job id; no dir for it on the
# hub (exact, pool-, fly-); its job not already staged (no RESULT names its
# JOB_ID); 90 min <= age <= RESCUE_LEDGER_LOOKBACK_H; and the job has NO verdict
# artifact (rc 2). An outage on either read writes nothing and the next tick
# retries. At most RESCUE_PER_TICK per tick, oldest first; the rest come back.
#
# AND the build was not already dealt with. bin/blocked-resolver.sh acts on
# exactly these ledger-only rows from hour 6, and with no dir to mark it records
# that only in the ticket's state file; once this pass makes a dir, the resolver
# reads the dir, not that file. So a row is skipped when (a) the ticket's
# resolver state has the build in rebuild_seen (plain, pool-, fly-) or a non-hold
# ladder attempt at or after the row — the resolver's own NOT RE-OFFERED test,
# and an unreadable file fails closed — or (b) the ledger holds a NEWER result
# row for the same ticket under another build_dir: the ticket was built again,
# and the KEY search in rescue_one would find THAT build's PR and review it twice.
# shellcheck source=bin/lib/builds-of-record.sh
[ -r "$H/bin/lib/builds-of-record.sh" ] && . "$H/bin/lib/builds-of-record.sh"
NOW=$(date -u +%s)
# ledger_tkey <project> <build_dir> <ledger key> — the ticket a ledger row is
# for, derived from build_dir exactly as bin/blocked-resolver.sh derives it (so
# the state file named below is the one the resolver wrote), the ledger's key
# only when build_dir does not carry the project prefix.
ledger_tkey() {
  local rest
  case "$2" in "$1"-*) rest="${2#"$1"-}"; printf '%s' "${rest%-*}" ;; *) printf '%s' "$3" ;; esac
}
# resolver_acted <project> <ticket key> <build_dir> <row epoch> — rc 0 when the
# resolver's state for the ticket says it already acted on this build, or the
# state cannot be read (fail closed); rc 1 when it has not.
resolver_acted() {
  local rk st sx at ate
  rk="$1-$2"; st="$H/state/blocked-resolver/$1/${rk//[^A-Za-z0-9._-]/-}.json"
  [ -f "$st" ] || return 1
  sx=$(jq -r --arg b "$3" '[
      ((.rebuild_seen // []) | any(. == $b or . == ("pool-" + $b) or . == ("fly-" + $b))),
      ([.attempts[]? | select((.action // "") | . != "held" and . != "stalled" and . != "stall-cleared" and (startswith("hold-") | not))] | last | (.at // ""))
    ] | @tsv' "$st" 2>/dev/null) || return 0
  [ "${sx%%$'\t'*}" = false ] || return 0
  at="${sx#*$'\t'}"
  [ -n "$at" ] || return 1
  ate=$(date -u -d "$at" +%s 2>/dev/null) || return 0
  [ "$ate" -ge "$4" ]
}
ledger_materialize() {
  local n=0 P ROWS RC STAGED KEY BDIR BOX UPD RLINE _PR JOB TS AGE TMP DEST TK
  local -A NEWEST=()
  command -v bor_list >/dev/null 2>&1 && command -v bor_local_dir >/dev/null 2>&1 \
    && command -v job_verdict_state >/dev/null 2>&1 || return 0
  # A tmp record left by a run that died between mkdir and mv: the walk skips
  # it, and this sweeps it once it is plainly not a live run's (an hour old).
  find "$H/builds" -mindepth 1 -maxdepth 1 -type d -name '.pool-*.tmp.*' -mmin +60 \
    -exec rm -rf {} + 2>/dev/null
  STAGED=$'\n'"$(sed -n 's/^JOB_ID: //p' "$H"/builds/*/RESULT 2>/dev/null)"$'\n'
  for P in $PROJECTS; do
    [ -z "$RESCUE_ONLY" ] || [ "$P" = "$RESCUE_ONLY" ] || continue
    ROWS=$(bor_list "$P" 2>/dev/null); RC=$?
    if [ "$RC" = 1 ]; then say "$P: ledger read failed — no record materialized this tick"; continue; fi
    [ "$RC" = 0 ] || continue
    # The newest result row per ticket, whatever its line 1 (updated_at is ISO,
    # so it orders as text). An older row of a ticket built since is superseded.
    NEWEST=()
    while IFS=$'\t' read -r KEY BDIR BOX UPD RLINE _PR JOB; do
      [ -n "$BDIR" ] && [ -n "$UPD" ] && [ "$UPD" != - ] || continue
      TK=$(ledger_tkey "$P" "$BDIR" "$KEY"); [ -n "$TK" ] && [ "$TK" != - ] || continue
      [[ "$UPD" > "${NEWEST[$TK]:-}" ]] && NEWEST[$TK]="$UPD"
    done <<<"$ROWS"
    # Oldest first, the same order the candidate walk takes (updated_at is ISO).
    while IFS=$'\t' read -r KEY BDIR BOX UPD RLINE _PR JOB; do
      case "$RLINE" in REVIEW_BLOCKED*) ;; *) continue ;; esac
      [ -n "$JOB" ] && [ "$JOB" != - ] || continue
      # Ledger text that becomes a path: a plain name, or nothing.
      if ! [[ "$BDIR" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        say "$P: refused ledger build_dir '$BDIR' (job $JOB) — not a plain name, never used as a path"
        continue
      fi
      bor_local_dir "$BDIR" >/dev/null && continue
      case "$STAGED" in *$'\n'"$JOB"$'\n'*) continue ;; esac
      [ -n "$UPD" ] && [ "$UPD" != - ] || continue
      TS=$(date -u -d "$UPD" +%s 2>/dev/null) || continue
      AGE=$(( NOW - TS ))
      [ "$AGE" -ge 5400 ] && [ "$AGE" -le $(( RESCUE_LEDGER_LOOKBACK_H * 3600 )) ] || continue
      TK=$(ledger_tkey "$P" "$BDIR" "$KEY")
      if [ -z "$TK" ] || [ "$TK" = - ]; then
        say "[$P] $BDIR: no ticket key on the ledger row (job $JOB) — not materialized"
        continue
      fi
      if [[ "${NEWEST[$TK]:-}" > "$UPD" ]]; then
        say "[$P/$TK] $BDIR: superseded — the ledger holds a newer build of $TK; not materialized"
        continue
      fi
      if resolver_acted "$P" "$TK" "$BDIR" "$TS"; then
        say "[$P/$TK] $BDIR: bin/blocked-resolver.sh already acted on this build (or its state is unreadable) — not materialized"
        continue
      fi
      job_verdict_state "$JOB" >/dev/null 2>&1; RC=$?
      if [ "$RC" = 1 ]; then
        say "[$P/$KEY] $BDIR: the ledger would not say whether job $JOB has a verdict — not materialized, the next tick retries"
        continue
      fi
      [ "$RC" = 2 ] || continue
      if [ "$n" -ge "$RESCUE_PER_TICK" ]; then
        say "ledger pass capped at RESCUE_PER_TICK=$RESCUE_PER_TICK materializations — the rest come back next tick"
        return 0
      fi
      # Built aside and moved into place whole: no half record is ever visible.
      TMP="$H/builds/.pool-$BDIR.tmp.$$"; DEST="$H/builds/pool-$BDIR"
      if mkdir "$TMP" 2>/dev/null \
         && printf '%s\nSOURCE: remote (ledger, built on %s; materialized by review-rescue — no build dir on the hub)\nJOB_ID: %s\nBUILT_AS: %s\nMATERIALIZED: %s\n' \
              "$RLINE" "$BOX" "$JOB" "$BDIR" "$(STAMP)" > "$TMP/RESULT" \
         && : > "$TMP/.rescue-materialized" && : > "$TMP/.stale-flagged"; then
        if job_transcript_get_source "$JOB" plan_md > "$TMP/plan.md" 2>/dev/null && [ -s "$TMP/plan.md" ]; then :
        else rm -f "$TMP/plan.md"; say "[$P/$KEY] $BDIR: no plan_md in the ledger for job $JOB — the review runs without a plan"; fi
        # The record keeps the ledger's age, so the walk's -mmin +90 and its
        # oldest-first order treat it as the build it is.
        touch -d "$UPD" "$TMP/RESULT" 2>/dev/null
        if mv -T "$TMP" "$DEST" 2>/dev/null; then
          n=$((n+1)); STAGED="$STAGED$JOB"$'\n'
          say "[$P/$KEY] materialized pool-$BDIR from the ledger (job $JOB, box $BOX)"
          continue
        fi
      fi
      case "$TMP" in "$H"/builds/.pool-*) rm -rf "$TMP" ;; esac
      say "[$P/$KEY] $BDIR: could not write the hub record for job $JOB — nothing materialized, the next tick retries"
    done < <(printf '%s\n' "$ROWS" | sort -t$'\t' -k4,4)
  done
}
ledger_materialize

# --- pick the oldest candidates -----------------------------------------------
CANDS=()
while read -r R; do
  [ "${#CANDS[@]}" -lt "$RESCUE_PER_TICK" ] || break
  D=$(dirname "$R")
  # BH-4437: a ledger pass's half-built tmp record is never a candidate.
  case "$D" in */.pool-*.tmp.*) continue ;; esac
  if [ -n "$RESCUE_ONLY" ]; then
    case "$(basename "$D")" in "$RESCUE_ONLY"-*|pool-"$RESCUE_ONLY"-*) ;; *) continue ;; esac
  fi
  FIRST=$(head -1 "$R" 2>/dev/null)
  grep -q "REVIEW_BLOCKED" <<<"$FIRST" || continue
  # A verdict normally means this build was already judged and there is nothing
  # to re-enter. The ONE exception is a test-tamper block: the gate runs BEFORE
  # the review on a fresh build and AFTER it on a resumed one, so four of the
  # 2026-09-13 strandees held `VERDICT: APPROVE` and a REVIEW_BLOCKED terminal at
  # the same time. Skipping them is what left them waiting for a PR forever.
  # "Has a verdict" is the shared reader's answer (BH-1625, #1639 review), -L as
  # for every appended build artifact, so this skip agrees with
  # bin/stale-owed-tickets.sh about which REVIEW_BLOCKED builds are orphaned.
  if ! is_tamper_block "$FIRST" && verdict_parse -L "$D/review.md" >/dev/null 2>&1; then continue; fi
  [ -f "$D/.review-rescued" ] && continue
  # bin/blocked-resolver.sh stamps this when it has ruled on the record and
  # enqueued a fresh build. Since BH-1047 its fast path adjudicates a
  # contract-first tamper block from minute 90, the same floor this lane uses,
  # so both crons can hold the same record on the same minute. Rescuing one the
  # resolver has already superseded opens a second PR on the branch it just
  # closed and buys a second review for one ticket — the record is its owner's.
  [ -f "$D/.blocked-resolver-superseded" ] && continue
  A=$(cat "$D/.rescue-attempts" 2>/dev/null || echo 0)
  if [ "$A" -ge 2 ]; then
    HARNESS="$H" "$H/bin/alert-line.sh" "[review-rescue] GIVING UP on $(basename "$D") after 2 failed rescue attempts — retired from this lane and handed to bin/blocked-resolver.sh, which rebuilds the ticket fresh against current main (3 tries, then one ABANDONED outcome record). Nobody is waiting on a person."
    touch "$D/.review-rescued"; continue
  fi
  CANDS+=("$D")
done < <(find "$H/builds" -maxdepth 2 -name RESULT -mmin +90 2>/dev/null | xargs -r ls -tr 2>/dev/null)
[ "${#CANDS[@]}" -gt 0 ] || exit 0

# Oldest first, RESCUE_PER_TICK of them, all IN PARALLEL. One per tick was the
# original bound on cost; with 39 stranded builds on one day that is a fortnight
# of ticks, so the bound is a knob (env) rather than a constant — and since
# 2026-09-13 the candidates no longer take turns either. Each runs in its own
# subshell (its own worktree, its own fds, its own per-key flock), at most
# RESCUE_PARALLEL at a time, and the tick waits for all of them before it exits so
# cron never overlaps a rescue with its own successor.
case "$RESCUE_PARALLEL" in ''|*[!0-9]*) RESCUE_PARALLEL=0 ;; esac   # 0 = no cap: every candidate starts now
RUNNING=0
for C in "${CANDS[@]}"; do
  ( rescue_one "$C" ) &
  RUNNING=$((RUNNING+1))
  # `wait -n` returns on the FIRST child to finish, which is what keeps the cap a
  # cap without making the slowest candidate the pace-setter for the rest.
  if [ "$RESCUE_PARALLEL" -gt 0 ] && [ "$RUNNING" -ge "$RESCUE_PARALLEL" ]; then
    wait -n 2>/dev/null || wait
    RUNNING=$((RUNNING-1))
  fi
done
wait
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
