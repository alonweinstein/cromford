#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/ladder.sh — BH-1176: the resolver's CLASSIFIER, the pure half of the
# lane: a reason word in, a ladder class / rung / action word out. Sourced by
# bin/blocked-resolver.sh, never run. Nothing here reads a file, writes one, or
# calls out; sourcing it defines seven functions and does nothing else.
#
# This slice landed DARK (see tests/br-split-layout-test.sh case 4): the block
# below is a BYTE-IDENTICAL copy of the one still inline in
# bin/blocked-resolver.sh, which is sourced FIRST and therefore loses to the
# inline definition. The cut that deletes the inline copy is a separate change,
# and this file is what makes that diff a pure deletion.
# ---------------------------------------------------------------------------
# The classifier. PURE: a reason word in, an action word out, nothing read and
# nothing written. It is the one place that decides what the ladder does with a
# park, which is what makes it the thing the fixture test drives directly.
#
# An UNKNOWN reason answers `none` on purpose. A future gate that invents a new
# park must be added here deliberately; silently rebuilding on a reason nobody
# has thought about is how an agent ladder turns into a loop. Until it is added,
# that park still pages through the conductor exactly as it does today.
# ---------------------------------------------------------------------------
# br_ladder_class <reason> -> rebase-conflict|ci-red|review-blocked|orphaned-parent|prequeue-red|""
#   The three park classes that are about a BRANCH somebody can still fix. They
#   are what the rung ladder applies to; everything else (a dead pool machine, a
#   malformed plan, a BUILD_DEAD record) has no branch to fix and keeps going
#   straight to REBUILD FRESH.
#
#   `ci-red` is NON-FLAKY by construction and not by a test here: the conductor
#   forgives a red whose every failing test is a known flake (mc_flake_rerun)
#   and re-runs any other red once (mc_red_rerun) BEFORE it parks the head as
#   RED_TWICE, so a red that reaches this lane has already survived both.
#
#   `orphaned-parent` (2026-09-16) is the fourth: the PR this branch was cut
#   from CLOSED without merging, and bin/merge-conductor.sh could not simply
#   retarget the child because it still carries the dead parent's commits or it
#   conflicts with main. There IS a branch to fix — the fix is to take the dead
#   parent's commits out of it — so it belongs to the ladder rather than going
#   straight to a rebuild.
#
#   `provenance-ci-red` (BH-3630) is a provenance park the conductor saw APPROVE + CI red on; same ladder as red-ci-twice.
#
#   `stale-replan` (BH-3935) is the PR-owner age ladder's park: nobody moved the
#   PR for pr_stale.replan_days. Its only rung is bin/lib/br/opt/stale.sh's
#   re-plan; br_one stops it before the ladder when that module is off.
#   `prequeue-red` (BH-4549) is NOT ci-red: the pre-queue gate parks a head
#   whose suites fail merged onto current main, and that head is GREEN on its
#   own PR CI, so the ci-red supersede guard would decline it green-at-head.
br_ladder_class() {
  case "${1:-}" in
    conflict-unresolvable|rebase-gate-red)      echo rebase-conflict ;;
    red-ci-twice|red-twice|queue-ejected-twice|provenance-ci-red|queue-dequeued) echo ci-red ;;
    head-not-reapproved)                        echo review-blocked ;;
    orphaned-child)                             echo orphaned-parent ;;
    stale-replan)                               echo stale-replan ;;
    prequeue-red)                               echo prequeue-red ;;
    *)                                          echo "" ;;
  esac
}

# br_skips_mechanical <class> — rc 0 for the classes whose rung 1 answers
#   nothing. Rung 1 is "merge origin/main into the branch and re-run CI", which
#   is a real answer to a conflict or a stale red, and no answer at all to a
#   review finding (review-blocked: the findings are already posted) or to a
#   branch carrying an abandoned parent's commits (orphaned-parent: merging main
#   does not take them out). Both start at the fix round. So does prequeue-red:
#   the gate already ran this exact head merged onto main, so a main merge plus
#   a CI re-run answers nothing.
br_skips_mechanical() {
  case "${1:-}" in review-blocked|orphaned-parent|prequeue-red) return 0 ;; esac
  return 1
}

# br_ladder_rung <class> <mechanicals> <fixrounds> [<fixcap>]
#                                       -> mechanical|fix-round|rebuild-fresh
#   PURE, so the order is a thing the fixture drives rather than a thing the
#   reader believes. A review-blocked park skips rung 1: merging main into the
#   branch answers nothing a reviewer asked for, and the findings are already
#   posted, so its ladder is fix round then rebuild. An orphaned-parent park
#   skips it for the same shape of reason (br_skips_mechanical).
#
#   THE FIX CAP IS AN ARGUMENT (BH-579) because it is no longer one number: a
#   small conflict buys two rounds and a contested winner buys a bonus one
#   (br_fix_cap). It is passed in rather than read here so the rung CHOSEN and
#   the rung that RUNS read the same cap. Absent, it is today's single round.
br_ladder_rung() {
  local class="${1:-}" mech="${2:-0}" fix="${3:-0}" cap="${4:-${BR_MAX_FIXROUNDS:-1}}"
  case "$mech" in ''|*[!0-9]*) mech=0 ;; esac
  case "$fix"  in ''|*[!0-9]*) fix=0 ;; esac
  case "$cap"  in ''|*[!0-9]*) cap="${BR_MAX_FIXROUNDS:-1}" ;; esac
  case "$cap"  in ''|*[!0-9]*) cap=1 ;; esac
  if ! br_skips_mechanical "$class" && [ "$mech" -lt "${BR_MAX_MECHANICAL:-1}" ]; then echo mechanical; return 0; fi
  if [ "$fix" -lt "$cap" ]; then echo fix-round; return 0; fi
  echo rebuild-fresh
}

# br_regen_offered <state-json> <head> — rc 0 when this TICKET has already been
#   offered the regenerate rung on THIS head. Pure jq over the record, no file
#   I/O, so the dedup is a thing the fixture drives.
#
#   Keyed on head8 and not on the ticket alone: a regenerate that pushes moves
#   the head, CI runs, and the park that comes back is a genuinely new fact. An
#   EMPTY head is rc 1 — absent is not "already offered" (D11), and the rung
#   body refuses a park with no head of its own anyway.
br_regen_offered() {
  local st="${1:-}" head="${2:-}"
  [ -n "$head" ] || return 1
  printf '%s' "$st" | jq -e --arg h "${head:0:8}" \
    '[.attempts[]? | select((.action == "regen") or (.action == "regen-noop"))
                   | select((.detail // "") | contains("head8=" + $h))] | length > 0' \
    >/dev/null 2>&1
}

# br_regen_ladder <class> <ladder-action> -> the action to DISPATCH.
#   RUNG 1b, THE REGENERATE RUNG (BH-950.2). A ci-red park whose mechanical rung
#   is spent went straight to an agent fix round, and 12 of the parks in the #950
#   census were red on a GENERATED file that was stale — a drift one more merge
#   of main answers for free. So between rung 1 and rung 2 the ci-red class gets
#   one more tokenless merge (mc_rebase, which regenerates the generated-files
#   table on the way through), and only the class that merge can help:
#   review-blocked has posted findings a merge answers nothing about,
#   orphaned-parent needs its parent's commits taken OUT, and a rebase-conflict
#   park has already had exactly this merge refused at rung 1.
#
#   BR_REGEN_RUNG=0 prints the ladder's own answer, so the dispatch is the
#   pre-BH-950 one to the letter.
br_regen_ladder() {
  local class="${1:-}" action="${2:-}"
  if [ "${BR_REGEN_RUNG:-1}" != 0 ] && [ "$class" = ci-red ]; then
    case "$action" in fix-round|rebuild-fresh) printf 'regen'; return 0 ;; esac
  fi
  printf '%s' "$action"
}

br_action() { # br_action <reason> -> ladder|rebuild-fresh|adjudicate|re-review|none
  # The ladder owns the branch classes unless it is switched off, in which case
  # every reason answers exactly what it answered before it shipped.
  if [ "${BR_LADDER:-1}" != 0 ] && [ -n "$(br_ladder_class "${1:-}")" ]; then echo ladder; return 0; fi
  case "${1:-}" in
    head-not-reapproved|orphaned-child)     echo fix-round ;;
    # THE REVIEW LANE'S OWN VERDICT (BH-872). Deliberately NOT a ladder class:
    # rung 1 (merge main / re-run CI) answers nothing a reviewer asked for, and
    # rung 3 (close the PR and rebuild the ticket) is not the answer to a review
    # finding on a PR that may have no ticket at all. Fix round, then ABANDONED.
    review-changes-requested)               echo fix-round ;;
    iron-law|test-tamper|rescue-real-deletion) echo adjudicate ;;
    no-verdict)                             echo re-review ;;
    # The rebuild this lane started has ENDED. A dead machine is worth another
    # rebuild; a planner that could not decompose the ticket, a plan that
    # stopped on an open question and a review that refused the diff are all
    # TICKET-level stops, and a second rebuild ends exactly the same way.
    rebuild-build-dead)                     echo rebuild-fresh ;;
    rebuild-decompose-failed|rebuild-plan-blocked|rebuild-review-blocked) echo abandon-rebuild ;;
    # THE ENQUEUE ITSELF DID NOT LAND (BH-488). Not a ticket-level stop and not
    # a new rung: the PR is already closed and the record already marked, so the
    # only thing owed is the enqueue, tried again.
    rebuild-enqueue-failed)                 echo rebuild-retry ;;
    conflict-unresolvable|rebase-gate-red|queue-ejected-twice|merge-failed-twice|\
    queue-enqueue-failed-twice|red-ci-twice|red-twice|provenance-ci-red|reproduction-gate|intent-gate|\
    pool-died-twice|pool-deferred-max|rescue-giving-up|plan-malformed|plan-blocked|\
    build-dead|pr-create-failed)            echo rebuild-fresh ;;
    # BH-1770 (the operator, 2026-09-24): bin/lane-reaper.sh killed this run past its
    # per-lane deadline, and THIS lane owns the relaunch, never the sweep. There
    # is no branch to fix — the run never finished — so it is a fresh build on
    # the capped ladder, and ABANDONED with one alert when that is spent.
    abandoned-timeout)                      echo rebuild-fresh ;;
    *)                                      echo none ;;
  esac
}

# br_reason_of <raw-reason-string> -> the normalized word br_action understands.
# The raw strings are whatever the parking lane wrote, and they carry detail
# ("conflict-unresolvable: CONFLICT (content): Merge conflict in x.ts"). Matched
# on the PREFIX, so the detail rides along in the log without confusing this.
br_reason_of() {
  case "${1:-}" in
    conflict-unresolvable*)      echo conflict-unresolvable ;;
    rebase-gate-red*)            echo rebase-gate-red ;;
    queue-ejected-twice*)        echo queue-ejected-twice ;;
    merge-failed-twice*)         echo merge-failed-twice ;;
    queue-enqueue-failed-twice*) echo queue-enqueue-failed-twice ;;
    no-verdict*)                 echo no-verdict ;;
    head-not-reapproved*)        echo head-not-reapproved ;;
    red-ci-twice*)               echo red-ci-twice ;;
    # RED_TWICE (2026-09-15): the conductor re-ran this head's failed jobs once
    # and CI came back red on the SAME head. Same answer as its cross-head
    # sibling above — a branch whose own CI will not go green is rebuilt fresh
    # against current main; the fix round needs posted review findings and a red
    # CI run has none, so br_fix_round would only fall through to this anyway.
    red-twice*)                  echo red-twice ;;
    # 2026-09-16: the raw reason carries the dead base branch and the parent's
    # PR url, and the fix round reads both out of it — so it is matched on the
    # prefix like every other reason here and the detail rides along.
    orphaned-child*)             echo orphaned-child ;;
    # BH-3935: bin/lib/pr-owner/stale.sh's rung 2 writes it, with the age in
    # the detail ("stale-replan: no head or verdict change for 5d").
    stale-replan*)               echo stale-replan ;;
    # BH-872: the raw reason carries the PR and the head it was read at, so it
    # is matched on the prefix like every other reason and the detail rides
    # along into the log.
    review-changes-requested*)   echo review-changes-requested ;;
    # BH-614: the build was approved and its branch pushed, and the create
    # opened nothing (bin/run-build.sh's ratchet refused the url-less claim, or
    # bin/fly-pool.sh's reap rewrote a legacy line RESULT_MALFORMED). There is no
    # PR to read and no finding to fix, so no rung of the ladder applies — only a
    # fresh build against current main answers it.
    pr-create-failed*)           echo pr-create-failed ;;
    # BH-1770: a run bin/lane-reaper.sh killed past its deadline (REAPED on the
    # record). br_from_builds writes it; the relaunch is this lane's.
    abandoned-timeout*)          echo abandoned-timeout ;;
    iron-law*)                   echo iron-law ;;
    # A REBUILD'S OWN OUTCOME (2026-09-16, project-5 #1645). These four are
    # written by br_from_rebuilds and by nothing else: they mean the fresh build
    # THIS lane enqueued has finished, and they are deliberately distinct from
    # their bare siblings. `build-dead` is a record nobody has acted on yet;
    # `rebuild-build-dead` is our own rebuild dying, which spends the next
    # counter without re-closing a PR that rung 3 already closed.
    rebuild-build-dead*)         echo rebuild-build-dead ;;
    rebuild-decompose-failed*)   echo rebuild-decompose-failed ;;
    rebuild-plan-blocked*)       echo rebuild-plan-blocked ;;
    rebuild-review-blocked*)     echo rebuild-review-blocked ;;
    rebuild-enqueue-failed*)     echo rebuild-enqueue-failed ;;
    # BH-3630: a `provenance` park the conductor saw verdict=APPROVE + ci=red
    # on. The conductor's row only ever says `provenance`; br_from_conductor
    # writes this word after reading the conductor's own detail for the head
    # (br_prov_promote), so a bare `provenance` still answers "" below.
    provenance-ci-red*)          echo provenance-ci-red ;;
    # BH-4549: the pre-queue gate's park, `prequeue-red: <suites> on main <m12>
    # — …` (tracer) or `prequeue-red: <suites> (reproduced alone on <base12>,
    # batch #n)` (batch-solo). The fix round re-reads the suites and the sha.
    prequeue-red*)               echo prequeue-red ;;
    # A LOSER OF A CONTESTED PATH IS NOT THE LADDER'S (BH-579). Another ticket
    # won the path this PR conflicts on and holds it; this lane answers the hold
    # itself (br_one's loser skip) and the conductor gets the row back when the
    # hold is released. An empty answer is what keeps the row out of
    # br_from_conductor entirely, so no rung is ever offered to a loser.
    contested*)                  echo "" ;;
    *)                           echo "" ;;
  esac
}

