#!/bin/bash
# tests/mc/classify-test.sh — the classifier half of tests/merge-conductor-test.sh,
# split out of it verbatim by BH-684 when bin/lib/merge-conductor-lib.sh became a
# shim over bin/lib/mc/. Every case here exercises bin/lib/mc/classify.sh:
# mc_classify itself, mc_ci_state, mc_job_running, mc_transition's log line, the
# spend-budget alert, the red ladder and the stuck-state detector.
#
# WHY DRIVEN AND NOT GREPPED. The claims under test are about control flow:
# which state each shape of PR lands in, that a moved head is HEAD_MOVED and
# not READY, that a transition logs exactly once. `grep -q HEAD_MOVED bin/...`
# passes just as happily on a classifier that never reaches the branch.
#
# THE SIX THAT MUST NEVER ANSWER READY. mc_classify is what puts a PR in READY
# and READY is what gets merged, so each of these is a merge that must NOT
# happen, and each is asserted by name in section 1 below:
#   * OPEN/DIRTY/CONFLICTING with APPROVE and green CI answers NEEDS_REBASE.
#   * head != the reviewed sha answers HEAD_MOVED, with APPROVE + CLEAN + green.
#   * a provenance word rp_prov_is_claude cannot resolve is HELD, never READY.
#   * ABANDONED is pinned, so a tick cannot walk a retired PR back in.
#   * mc_job_running true means not reviewed and not merged.
#   * RED_TWICE and BLOCKED_HUMAN are parked for bin/blocked-resolver.sh.
#
# gh and the jobs client are stubbed under $T/fakebin; nothing here spawns the
# conductor script itself — that is tests/merge-conductor-test.sh's half.
# Run from anywhere: tests/mc/classify-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# fixture: tests/lib/fixture-harness.sh (BH-1196) — what is copied into the
# scratch harness, and why each file is there, is documented in the lib.
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/mc" ] || exit 1   # impact: this suite runs when bin/lib/mc/ changes (bin/test-impact.sh reads rooted tokens)
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
H1=aaaaaaaa1111; H2=bbbbbbbb2222
c() { mc_classify "$@" | cut -f1; }
H3=cccccccc3333   # carried from section 1 of the parent suite: the sections below use it

# ============================================================================
# 1. The classifier, pure: every state reachable from words alone
# ============================================================================
H1=aaaaaaaa1111; H2=bbbbbbbb2222
c() { mc_classify "$@" | cut -f1; }
#          pstate mstate   mergeable  head reviewed verdict  prov   ci      reds tight scan prearm prev headbound
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = READY ]         && ok || bad "approved+clean+green must be READY"
[ "$(c OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - -)" = HEAD_MOVED ]    && ok || bad "head != reviewed sha must be HEAD_MOVED, never READY"
# NO VERDICT BOUND TO THE HEAD (2026-09-14, project-5 #586/#611). This used to
# assert WAIT_REVIEW, and WAIT_REVIEW is where those two PRs sat forever: nothing
# in the harness reviews a WAIT_REVIEW row, and the HEAD_MOVED re-review path
# only fires when a reviewed sha EXISTS and differs from the head. So a head
# nobody has adjudicated — no reviewed sha at all, or a reviewed sha equal to the
# head whose verdict was cleared — now buys the same detached head-bound review.
# A DIRTY PR is the one exception: reviewing a head that cannot merge is wasted.
[ "$(c OPEN CLEAN MERGEABLE $H1 - - - green 0 0 0 0 - -)" = HEAD_MOVED ]                 && ok || bad "no verdict and no reviewed sha must buy a fresh detached review (HEAD_MOVED), not sit in WAIT_REVIEW"
[ "$(mc_classify OPEN CLEAN MERGEABLE $H1 - - - green 0 0 0 0 - - | cut -f2)" = "no verdict bound to head ${H1:0:8} — fresh detached review" ] && ok || bad "the reason must name the head and say the review is fresh (got $(mc_classify OPEN CLEAN MERGEABLE $H1 - - - green 0 0 0 0 - - | cut -f2))"
# A DIRTY head with no verdict used to answer WAIT_REVIEW, and that was the same
# dead end one line up: nothing reviews a WAIT_REVIEW row and nothing rebases
# one either. It rebases FIRST (2026-09-14) — the fresh head-bound review is then
# bought on the head the rebase pushes, which is the head that can merge.
[ "$(c OPEN DIRTY CONFLICTING $H1 - - - green 0 0 0 0 - -)" = NEEDS_REBASE ]             && ok || bad "a DIRTY PR with no verdict must rebase first, not sit in WAIT_REVIEW where nothing reviews it"
[ "$(c OPEN CLEAN CONFLICTING $H1 - - - green 0 0 0 0 - -)" = NEEDS_REBASE ]             && ok || bad "mergeable CONFLICTING counts as DIRTY for the no-verdict rule"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 - - green 0 0 0 0 - -)" = HEAD_MOVED ]               && ok || bad "a reviewed sha EQUAL to the head with an empty verdict (an old BLOCK cleared, a resolver hand-off) must also buy the fresh review"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 BLOCK claude green 0 0 0 0 - -)" = BLOCKED_HUMAN ]   && ok || bad "a live BLOCK must still park, never buy another review"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude pending 0 0 0 0 - -)" = WAIT_CI ]     && ok || bad "pending checks must be WAIT_CI"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude none 0 0 0 0 - -)" = WAIT_CI ]        && ok || bad "no runs yet must be WAIT_CI"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 1 0 0 0 - -)" = WAIT_CI ]         && ok || bad "red once must be WAIT_CI"
# TEST-CHANGE (BH-1671): red is counted per head, never across heads. `reds` =
# strikes on DIFFERENT heads used to park BLOCKED_HUMAN red-ci-twice at 2, before
# this head had its rerun; the ticket forbids that count. Two strikes across
# heads on a head at rung 0 is a head that went red ONCE: WAIT_CI, its rerun
# next. Only the same head red again (rung 2) parks, as RED_TWICE.
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 2 0 0 0 - -)" = WAIT_CI ]         && ok || bad "red on two heads, red once on this one, must be WAIT_CI (its own rerun first), not a red-ci-twice park"
[ "$(MC_RED_RUNG=1 c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 5 0 0 0 - -)" = WAIT_CI ] && ok || bad "any number of reds on OTHER heads must not park a head whose rerun is in flight"
[ "$(MC_RED_RUNG=2 c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 2 0 0 0 - -)" = RED_TWICE ] && ok || bad "red twice on the SAME head must be RED_TWICE"
[ "$(c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = NEEDS_REBASE ] && ok || bad "DIRTY must be NEEDS_REBASE"
# A DIRTY PR REBASES WHATEVER CI SAYS (2026-09-14, project-5 #799/#826/#838/#863).
# This is the one that stranded four PRs for hours: the CI case sat ABOVE the
# DIRTY line, and GitHub runs no pull_request workflow on a PR it cannot merge —
# so `checks none` is the NORMAL state of a conflicted PR, every one of them
# answered WAIT_CI, and not one ever reached mc_rebase. #799 was still in it four
# hours later with no rebase and no resolver line ever written.
[ "$(c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude none 0 0 0 0 - -)" = NEEDS_REBASE ]  && ok || bad "the #799 shape: DIRTY + no CI runs must be NEEDS_REBASE, never WAIT_CI (got $(c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude none 0 0 0 0 - -))"
[ "$(mc_classify OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude none 0 0 0 0 - - | cut -f2)" = "mergeState DIRTY" ] && ok || bad "the reason must be the merge state, not the checks"
[ "$(c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude pending 0 0 0 0 - -)" = NEEDS_REBASE ] && ok || bad "DIRTY + pending checks must be NEEDS_REBASE: the rebase makes the head CI will actually build"
[ "$(c OPEN CLEAN CONFLICTING $H1 $H1 APPROVE claude none 0 0 0 0 - -)" = NEEDS_REBASE ]  && ok || bad "mergeable CONFLICTING must rebase whatever CI says, like DIRTY"
[ "$(c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude red 2 0 0 0 - -)" = NEEDS_REBASE ]   && ok || bad "a red on a head nobody can merge is a red about nothing — DIRTY still rebases"
# BH-491 — DIRTY/CONFLICTING evaluated BEFORE provenance, so a DIRTY PR on a
# non-primary provenance answers NEEDS_REBASE (not BLOCKED_HUMAN provenance).
[ "$(c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE codex none 0 0 0 0 - -)" = NEEDS_REBASE ]     && ok || bad "DIRTY+prov=codex must be NEEDS_REBASE, not BLOCKED_HUMAN provenance (got $(c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE codex none 0 0 0 0 - -))"
[ "$(mc_classify OPEN DIRTY CONFLICTING $H1 $H1 APPROVE codex none 0 0 0 0 - - | cut -f2)" = "dirty-under-provenance" ] && ok || bad "DIRTY+prov=codex reason must be dirty-under-provenance (got $(mc_classify OPEN DIRTY CONFLICTING $H1 $H1 APPROVE codex none 0 0 0 0 - - | cut -f2))"
# Regression guard: non-DIRTY + prov=codex unchanged — BLOCKED_HUMAN provenance
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE codex green 0 0 0 0 - -)" = BLOCKED_HUMAN ]    && ok || bad "CLEAN+prov=codex must still be BLOCKED_HUMAN (provenance) — regression (got $(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE codex green 0 0 0 0 - -))"
# …AND THE GUARD IS ON THE PROVENANCE ARM, not a DIRTY test hoisted above the
# whole classifier. BH-491 hoisted it (2026-09-16) and took two branches with it:
# a conflicted PR whose head had MOVED answered NEEDS_REBASE instead of
# HEAD_MOVED — so it stopped buying the head-bound re-review that binds an
# approval to the sha it read — and a conflicted PR already in the merge queue
# stopped answering QUEUED. tests/conductor-sticky-handoff-test.sh caught the
# first as `BLOCKED_HUMAN -> REBASING`; these pin both shapes here, where the
# classifier is tested from words alone.
[ "$(c OPEN DIRTY CONFLICTING $H2 $H1 APPROVE claude green 0 0 0 0 - -)" = HEAD_MOVED ]    && ok || bad "a DIRTY head that MOVED off the reviewed sha must be HEAD_MOVED — the drift branch outranks the rebase (got $(c OPEN DIRTY CONFLICTING $H2 $H1 APPROVE claude green 0 0 0 0 - -))"
[ "$(c OPEN DIRTY CONFLICTING $H2 $H1 APPROVE codex green 0 0 0 0 - -)" = HEAD_MOVED ]     && ok || bad "drift outranks the rebase under a non-primary provenance too (got $(c OPEN DIRTY CONFLICTING $H2 $H1 APPROVE codex green 0 0 0 0 - -))"
# A REFUSED head that is also DIRTY parks on sight whatever MC_REREVIEW_ON_MOVE
# says (2026-09-16): GitHub runs no workflow on a head that cannot merge, so the
# CI-green debounce in headbound_review would defer the read for ever (BH-491),
# and a PR that can be neither read nor parked is the silent strand.
[ "$(c OPEN DIRTY CONFLICTING $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2)" = BLOCKED_HUMAN ] && ok || bad "a refused head that is also DIRTY must still park head-not-reapproved, not rebase (got $(c OPEN DIRTY CONFLICTING $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2))"
[ "$(c OPEN CLEAN CONFLICTING $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2)" = BLOCKED_HUMAN ] && ok || bad "CONFLICTING is the same fact as DIRTY here — a head no CI will build cannot buy a read (got $(c OPEN CLEAN CONFLICTING $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2))"
[ "$( MC_INQUEUE=1; c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude green 0 0 0 0 - - )" = QUEUED ] && ok || bad "a DIRTY PR already in the merge queue must still be QUEUED — re-enqueueing it is the forever-loop (got $( MC_INQUEUE=1; c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude green 0 0 0 0 - - ))"

# TEST-CHANGE (BH-1671): the red park a NOT-dirty PR keeps is the per-head one
# (RED_TWICE); the cross-head red-ci-twice park no longer exists.
[ "$(MC_RED_RUNG=2 c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 2 0 0 0 - -)" = RED_TWICE ] && ok || bad "the red-twice park must be untouched for a PR that is NOT dirty"
# WAIT_REVIEW is no longer an answer this classifier gives: both shapes that
# produced it (a DIRTY head with no verdict, a CLEAN one) now move. It remains a
# STATE — bin/merge-conductor.sh parks a freshly re-approved head there for one
# tick — so the word, the budget and the row stay exactly as they are.
for MS in DIRTY CLEAN UNSTABLE BLOCKED UNKNOWN; do
  for MG in CONFLICTING MERGEABLE UNKNOWN; do
    for V in APPROVE - ""; do
      for CIW in green pending none red; do
        [ "$(c OPEN $MS $MG $H1 $H1 "$V" claude $CIW 0 0 0 0 - -)" = WAIT_REVIEW ] \
          && { bad "mc_classify still answers the WAIT_REVIEW dead end (ms=$MS mg=$MG v=$V ci=$CIW)"; break 4; }
      done; done; done; done
ok
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 1 0 0 - -)" = BLOCKED_HUMAN ] && ok || bad "a tightened review gate must be BLOCKED_HUMAN"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 CONTRADICTION claude green 0 0 0 0 - -)" = BLOCKED_HUMAN ] && ok || bad "ledger/record contradiction must be BLOCKED_HUMAN"
# BH-4585 (#4620): a contradiction about an OLDER head is head-moved, so the
# head-bound re-review is bought; only one on THIS head (or an unknown one)
# parks, quoting both verdicts when the caller hands them in.
[ "$(c OPEN CLEAN MERGEABLE $H2 $H1 CONTRADICTION claude green 0 0 0 0 - -)" = HEAD_MOVED ] && ok || bad "a contradiction on an older head must be HEAD_MOVED"
[ "$(c OPEN CLEAN MERGEABLE $H1 - CONTRADICTION claude green 0 0 0 0 - -)" = BLOCKED_HUMAN ] && ok || bad "a contradiction on an unknown sha must still park"
[ "$( MC_CONTRA="ledger APPROVE vs record BLOCK"; mc_classify OPEN CLEAN MERGEABLE $H1 $H1 CONTRADICTION claude green 0 0 0 0 - - | cut -f2 )" = "verdict-contradiction: ledger APPROVE vs record BLOCK on ${H1:0:8}" ] && ok || bad "a current-head contradiction must quote both verdicts"
[ "$( MC_CONTRA=; mc_classify OPEN CLEAN MERGEABLE $H1 $H1 CONTRADICTION claude green 0 0 0 0 - - | cut -f2 )" = verdict-contradiction ] && ok || bad "no MC_CONTRA: the reason is the bare word"
# ...and mc_verdict lets a finished head-bound re-review of the contradicted sha stand.
CU=https://github.com/acme/fixt/pull/77; CS=dddddddddddddddddddddddddddddddddddddddd
mkdir -p "$T/crec"; printf 'Findings\n\nVERDICT: BLOCK\n' > "$T/crec/review.md"
cv() ( job_verdict() { printf 'APPROVE\t-\tclaude\t-\tjob1\t%s' "$CS"; }; mc_verdict "$CU" "$T/crec" | cut -f1,3 )
[ "$(cv)" = "CONTRADICTION	$CS" ] && ok || bad "ledger APPROVE vs record BLOCK must be CONTRADICTION on the ledger's sha (got '$(cv)')"
mc_rr_write "$(mc_rr_file acme/fixt 77 "$CS")" done 0 0 0 APPROVE "$CS" - - >/dev/null 2>&1
[ "$(cv)" = "APPROVE	$CS" ] && ok || bad "a head-bound re-review APPROVE of that sha must stand over the contradiction (got '$(cv)')"
mc_rr_write "$(mc_rr_file acme/fixt 77 "$CS")" done 0 0 0 BLOCK "$CS" - - >/dev/null 2>&1
[ "$(cv)" = "BLOCK	$CS" ] && ok || bad "a head-bound re-review BLOCK of that sha must stand too (got '$(cv)')"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE codex green 0 0 0 0 - -)" = BLOCKED_HUMAN ]  && ok || bad "a fallback-lane APPROVE must be BLOCKED_HUMAN (provenance)"
# …UNTIL A CLAUDE HEAD-BOUND REVIEW HAS READ THAT HEAD (2026-09-14, project-5
# #864/#865/#866/#867). The hold is about WHO read the code, and the conductor
# can buy that read; MC_PROV_CLEARED is how the tick hands the answer in. It is
# bound to a head, and it never outranks a BLOCK or a contradiction.
[ "$( MC_PROV_CLEARED=1; c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE codex green 0 0 0 0 - - )" = READY ] && ok || bad "a head a claude re-review APPROVED must stop being parked for the BUILD's provenance"
[ "$( MC_PROV_CLEARED=1; c OPEN CLEAN MERGEABLE $H1 $H1 BLOCK codex green 0 0 0 0 - - )" = BLOCKED_HUMAN ] && ok || bad "a cleared provenance must not unpark a BLOCK"
[ "$( MC_PROV_CLEARED=1; c OPEN CLEAN MERGEABLE $H1 $H1 CONTRADICTION codex green 0 0 0 0 - - )" = BLOCKED_HUMAN ] && ok || bad "a cleared provenance must not unpark a verdict contradiction"
[ "$( MC_PROV_CLEARED=1; c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE codex none 0 0 0 0 - - )" = NEEDS_REBASE ] && ok || bad "a cleared provenance on a DIRTY head still rebases first"
[ "$( MC_PROV_CLEARED=0; c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE codex green 0 0 0 0 - - )" = BLOCKED_HUMAN ] && ok || bad "MC_PROV_CLEARED=0 must be exactly today's provenance park"
mc_prov_held codex     && ok || bad "mc_prov_held must hold a non-primary runner"
mc_prov_held claude    && bad "mc_prov_held must not hold the primary lane" || ok
mc_prov_held -         && bad "mc_prov_held must read '-' as no claim, never as a hold" || ok
mc_prov_held ""        && bad "mc_prov_held must read an empty word as no claim" || ok
mc_prov_cleared example-org/x#9 "$H1" && bad "mc_prov_cleared must be false before anything clears it" || ok
mc_prov_clear example-org/x#9 "$H1"
mc_prov_cleared example-org/x#9 "$H1" && ok || bad "mc_prov_clear must record the clearance"
mc_prov_cleared example-org/x#9 "$H2" && bad "a clearance is bound to ONE head — a new push is unread code again" || ok
mc_prov_clear example-org/x#9 "$H1"
[ "$(grep -c "^provcleared example-org/x#9 $H1$" "$MC_ATTEMPTS")" = 1 ] && ok || bad "mc_prov_clear must be idempotent (got $(grep -c "^provcleared example-org/x#9 $H1$" "$MC_ATTEMPTS") lines)"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 2 0 - -)" = BLOCKED_HUMAN ] && ok || bad "iron-law hits must be BLOCKED_HUMAN"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 1 - -)" = BLOCKED_HUMAN ] && ok || bad "static guards red must be BLOCKED_HUMAN"
[ "$(c OPEN BLOCKED MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = WAIT_CI ]     && ok || bad "BLOCKED (required context) must be WAIT_CI"
[ "$(c OPEN UNKNOWN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 NEEDS_REBASE -)" = NEEDS_REBASE ] && ok || bad "UNKNOWN must keep the prior state"
[ "$(c MERGED CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = MERGED ]     && ok || bad "MERGED is terminal"
[ "$(c CLOSED CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = CLOSED ]     && ok || bad "CLOSED is terminal"
# the head-bound outcome, read only where it means anything: a head that MOVED,
# and only about the head it actually names.
#
# `blocked@<this head>` is a reviewer who read THIS code and said no — buying
# another re-review spends a second Fable call to be told the same word, so it is
# a human's problem now. Every other shape keeps today's HEAD_MOVED, because the
# conductor's own re-review is exactly what they call for:
#   blocked@<an OLDER head>  somebody pushed a fix on top of the refused head.
#                            Nobody has read THAT. Parking it would be the same
#                            never-ending park, one commit further along.
#   bare `blocked` (legacy)  a record from before the sha suffix shipped. It
#                            cannot say WHICH head it judged, and the safe
#                            reading of "we do not know" is buy the re-review.
#   no-verdict@…             nobody answered (dead session, model outage).
#   `-`                      every row written before any of this shipped.
H3=cccccccc3333
# ...AND THE BUILD GATE'S REFUSAL BUYS OUR OWN READ FIRST (2026-09-16, lever 2).
# `blocked@<this head>` used to park on sight, which cost bin/blocked-resolver.sh
# a full agent fix round for a word authored by whatever runner that build's
# survival ladder reached (61 of them on project-5 on 2026-09-16). It is
# HEAD_MOVED now — the conductor buys its own head-bound Claude read — and only
# OUR read coming back BLOCK (MC_HB_REFUSED=1, from mc_hb_refuse) parks it.
[ "$(c OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2)" = HEAD_MOVED ] && ok || bad "the build gate's blocked@<head> must buy the conductor's own read first, not park on sight (got $(c OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2))"
[ "$( MC_HB_REFUSED=1; c OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2 )" = BLOCKED_HUMAN ] && ok || bad "once OUR OWN re-review has BLOCKED this head, it parks (got $( MC_HB_REFUSED=1; c OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2 ))"
[ "$( MC_HB_REFUSED=1; mc_classify OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2 | cut -f2 )" = "head-not-reapproved" ] && ok || bad "the block reason must name the head-bound outcome"
# the kill flag restores the immediate park byte-for-byte
[ "$( MC_REREVIEW_ON_MOVE=0; c OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2 )" = BLOCKED_HUMAN ] && ok || bad "MC_REREVIEW_ON_MOVE=0 must restore today's immediate park (got $( MC_REREVIEW_ON_MOVE=0; c OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2 ))"
[ "$( MC_REREVIEW_ON_MOVE=0; mc_classify OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2 | cut -f2 )" = "head-not-reapproved" ] && ok || bad "with the knob off the reason is unchanged too"
[ "$(c OPEN CLEAN MERGEABLE $H3 $H1 APPROVE claude green 0 0 0 0 - blocked@$H2)" = HEAD_MOVED ] && ok || bad "a BLOCK about an OLDER head must not park the NEW head — the conductor must buy the re-review"
[ "$(c OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - blocked)" = HEAD_MOVED ] && ok || bad "a legacy bare 'blocked' names no head and must never park a PR"
[ "$(c OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - no-verdict@$H2)" = HEAD_MOVED ] && ok || bad "a re-review that produced no verdict must stay HEAD_MOVED (the conductor buys it)"
[ "$(c OPEN CLEAN MERGEABLE $H2 $H1 APPROVE claude green 0 0 0 0 - reapproved@$H2)" = HEAD_MOVED ] && ok || bad "a record whose outcome is stale against a NEWER head must still be HEAD_MOVED"
[ "$(c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - blocked@$H1)" = READY ] && ok || bad "the head-bound outcome must not fire on a head that never moved"
# the sha test itself: prefixes agree in both directions (an 8-char ledger row
# against a 40-char head), and nothing shorter than 7 chars is allowed to match.
FULL=1234567890abcdef1234567890abcdef12345678
mc_hb_blocks "blocked@$FULL" "$FULL"        && ok || bad "mc_hb_blocks must match a full sha against itself"
mc_hb_blocks "blocked@12345678" "$FULL"     && ok || bad "mc_hb_blocks must match an 8-char row against a full head"
mc_hb_blocks "blocked@$FULL" "12345678"     && ok || bad "mc_hb_blocks must match a full row against an 8-char head"
mc_hb_blocks "blocked@123456" "$FULL"       && bad "mc_hb_blocks matched a 6-char prefix — too short to mean anything" || ok
mc_hb_blocks "blocked@deadbeefdeadbeef" "$FULL" && bad "mc_hb_blocks matched a DIFFERENT sha" || ok
mc_hb_blocks "blocked" "$FULL"              && bad "mc_hb_blocks matched a bare legacy word with no sha" || ok
mc_hb_blocks "no-verdict@$FULL" "$FULL"     && bad "mc_hb_blocks matched a word that is not blocked" || ok
mc_hb_blocks "blocked@$FULL" ""             && bad "mc_hb_blocks matched against an empty head" || ok
# the sweep's green-run discount, project-4 excluded
[ "$(mc_discount example-org/project-3 UNSTABLE green)" = CLEAN ] && ok || bad "UNSTABLE + every run green must discount to CLEAN off project-4"
[ "$(mc_discount example-org/project-4 UNSTABLE green)" = UNSTABLE ] && ok || bad "project-4 must NOT take the generic discount"
# Every documented state has a budget of its OWN. This used to assert only that
# mc_budget printed SOMETHING, which it always does — its `*)` arm prints -1 —
# so a state added without a budget case passed silently and then never aged or
# paged. A non-terminal state must answer >= 0; MERGED and CLOSED must answer
# -1, because a terminal state that aged would page forever. ABANDONED joined
# them on 2026-09-13: it is bin/blocked-resolver.sh's terminal, and it has
# already alerted once with its whole attempt list, so ageing it would page
# forever about work nothing is doing any more.
for S in $MC_STATES; do
  case "$S" in
    MERGED|CLOSED|ABANDONED) [ "$(mc_budget "$S")" = "-1" ] && ok || bad "$S is terminal and must not age (got $(mc_budget "$S"))" ;;
    *) [ "$(mc_budget "$S")" -ge 0 ] 2>/dev/null && ok || bad "no age budget of its own for $S — mc_budget fell through to the default" ;;
  esac
done


# ============================================================================
# 2. Transitions: one log line per change, none on a quiet tick; budgets alert once
# ============================================================================
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$HARNESS/logs/beats.txt"\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
S1=$(mc_transition example-org/x#1 WAIT_CI "checks pending" $H1 $H1 https://github.com/example-org/x/pull/1 APPROVE CLEAN -)
[ "$(grep -c 'example-org/x#1 - -> WAIT_CI' "$MC_LOG")" = 1 ] && ok || bad "first sighting must log one transition"
S2=$(mc_transition example-org/x#1 WAIT_CI "checks pending" $H1 $H1 https://github.com/example-org/x/pull/1 APPROVE CLEAN -)
[ "$S1" = "$S2" ] && [ "$(grep -c 'example-org/x#1' "$MC_LOG")" = 1 ] && ok || bad "a quiet tick must neither log nor reset since"
mc_transition example-org/x#1 READY "clean" $H1 $H1 https://github.com/example-org/x/pull/1 APPROVE CLEAN - >/dev/null
grep -q 'example-org/x#1 WAIT_CI -> READY' "$MC_LOG" && ok || bad "a change must log FROM -> TO"
OLD=$(( $(date -u +%s) - 4000 ))
# WAIT_CI, not READY: READY's budget age is a state note since BH-4717, and this
# pins the once-per-entry page, which needs a state that still pages.
mc_row_put example-org/x#1 WAIT_CI "$OLD" $H1 $H1 - pending https://github.com/example-org/x/pull/1
mc_budget_check example-org/x#1 WAIT_CI "$OLD" https://github.com/example-org/x/pull/1 "checks pending"
mc_budget_check example-org/x#1 WAIT_CI "$OLD" https://github.com/example-org/x/pull/1 "checks pending"
[ "$(grep -c 'example-org/x#1 WAIT_CI' "$T/h/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "an over-budget state must alert exactly once per entry (got $(grep -c 'example-org/x#1 WAIT_CI' "$T/h/logs/ALERTS.log" 2>/dev/null))"
grep -q 'pull/1' "$T/h/logs/ALERTS.log" && ok || bad "the alert must name the PR URL"
FRESH=$(date -u +%s)
mc_row_put example-org/x#2 WAIT_CI "$FRESH" $H1 $H1 - pending https://github.com/example-org/x/pull/2
mc_budget_check example-org/x#2 WAIT_CI "$FRESH" https://github.com/example-org/x/pull/2 "pending"
grep -q 'example-org/x#2' "$T/h/logs/ALERTS.log" && bad "a state inside its budget must not alert" || ok
# A PROVENANCE HOLD THE CONDUCTOR IS FIXING ITSELF DOES NOT PAGE (2026-09-15,
# project-5 #1058/#1071, project-4 #1478: paged "0m in BLOCKED_HUMAN: provenance",
# merged on its own minutes later). Actions on = the tick buys the claude read.
touch "$T/h/flags/merge-conductor-actions"
NOW=$(date -u +%s)
mc_row_put example-org/pn#3 BLOCKED_HUMAN "$NOW" $H1 $H1 - provenance https://github.com/example-org/pn/pull/3
mc_budget_check example-org/pn#3 BLOCKED_HUMAN "$NOW" https://github.com/example-org/pn/pull/3 "provenance (verdict=APPROVE)"
grep -q 'example-org/pn#3' "$T/h/logs/ALERTS.log" && bad "a provenance hold with actions armed must NOT page at minute zero" || ok
grep -q 'example-org/pn#3 0m in BLOCKED_HUMAN (provenance) — auto-resolving' "$MC_LOG" && ok || bad "the auto-resolving hold must say so in the conductor log"
grep -q 'pn#3.*buys a claude read' "$MC_LOG" && ok || bad "with no re-review job the log must say the read is still to be bought"
mc_budget_check example-org/pn#3 BLOCKED_HUMAN "$NOW" https://github.com/example-org/pn/pull/3 "provenance (verdict=APPROVE)"
[ "$(grep -c 'pn#3.*auto-resolving' "$MC_LOG")" = 1 ] && ok || bad "the auto-resolving line must log once per hold, not every tick (got $(grep -c 'pn#3.*auto-resolving' "$MC_LOG"))"
# a running read is named as such
mc_rr_write "$(mc_rr_file example-org/pn 4 $H1)" running $$ "$NOW" 0 - $H1 $H1 "$T/out4"
mc_row_put example-org/pn#4 BLOCKED_HUMAN "$NOW" $H1 $H1 - provenance https://github.com/example-org/pn/pull/4
mc_budget_check example-org/pn#4 BLOCKED_HUMAN "$NOW" https://github.com/example-org/pn/pull/4 "provenance"
grep -q 'pn#4.*read of aaaaaaaa is running' "$MC_LOG" && ok || bad "a running re-review must be named in the auto-resolving line"
grep -q 'example-org/pn#4' "$T/h/logs/ALERTS.log" && bad "a provenance hold with a running read must not page" || ok
rm -f "$(mc_rr_file example-org/pn 4 $H1)"   # a later section asserts the re-review dir is empty
# past the window it pages exactly as before, once per day
STALE=$(( NOW - 3700 ))
mc_row_put example-org/pn#5 BLOCKED_HUMAN "$STALE" $H1 $H1 - provenance https://github.com/example-org/pn/pull/5
mc_budget_check example-org/pn#5 BLOCKED_HUMAN "$STALE" https://github.com/example-org/pn/pull/5 "provenance"
grep -q 'example-org/pn#5 BLOCKED_HUMAN' "$T/h/logs/ALERTS.log" && ok || bad "a provenance hold older than MC_PROV_AUTO_SECS must page (the read never came back)"
# a hold that was auto-resolving and then aged out pages too: the auto mark is not the day mark
mc_row_put example-org/pn#6 BLOCKED_HUMAN "$STALE" $H1 $H1 "BLOCKED_HUMAN@$STALE@auto" provenance https://github.com/example-org/pn/pull/6
mc_budget_check example-org/pn#6 BLOCKED_HUMAN "$STALE" https://github.com/example-org/pn/pull/6 "provenance"
grep -q 'example-org/pn#6 BLOCKED_HUMAN' "$T/h/logs/ALERTS.log" && ok || bad "an auto-resolving hold that ages past the window must page once"
# observe-only (flag off) pages at once: nobody is buying the read
rm -f "$T/h/flags/merge-conductor-actions"
mc_row_put example-org/pn#7 BLOCKED_HUMAN "$NOW" $H1 $H1 - provenance https://github.com/example-org/pn/pull/7
mc_budget_check example-org/pn#7 BLOCKED_HUMAN "$NOW" https://github.com/example-org/pn/pull/7 "provenance"
grep -q 'example-org/pn#7 BLOCKED_HUMAN' "$T/h/logs/ALERTS.log" && ok || bad "with the actions flag off a provenance hold must page at once"
# any other unowned reason still pages at minute zero
touch "$T/h/flags/merge-conductor-actions"
mc_row_put example-org/pn#8 BLOCKED_HUMAN "$NOW" $H1 $H1 - tightened https://github.com/example-org/pn/pull/8
mc_budget_check example-org/pn#8 BLOCKED_HUMAN "$NOW" https://github.com/example-org/pn/pull/8 "tightened"
grep -q 'example-org/pn#8 BLOCKED_HUMAN' "$T/h/logs/ALERTS.log" && ok || bad "an unowned non-provenance park must still page at minute zero"
rm -f "$T/h/flags/merge-conductor-actions"
# the issue number a PR was built for: the build KEY's digits (the #262 rule
# run-build and the sweep use), the branch's only when there is no record
[ "$(mc_issue_of "$T/h/builds/pool-issuer-IS-42-202609120003" ticket/is-7)" = 42 ] && ok || bad "mc_issue_of must prefer the record KEY's number"
[ "$(mc_issue_of "$T/h/builds/issuer-IS-43-202609120004" ticket/is-7)" = 43 ] && ok || bad "mc_issue_of must read a non-pool record too"
[ "$(mc_issue_of "" ticket/is-7)" = 7 ] && ok || bad "mc_issue_of must fall back to the branch digits"
[ -z "$(mc_issue_of "" fix/by-hand)" ] && ok || bad "mc_issue_of must print nothing when neither carries a number"
# the iron-law scan block, lifted from the sweep: a hit counts, a test file does not
printf '+++ b/src/a.ts\n+window.confirm("x")\n+++ b/src/a.test.ts\n+window.alert("y")\n' > "$T/d.diff"
[ "$(mc_iron_law_scan "$T/d.diff")" = 1 ] && ok || bad "iron-law scan must count the src hit and skip the test file"
# evidence artifacts are not product code (project-5 #499/#492, 2026-09-13: 49 hits, all in
# tasks/**/TK-*-RED-OUTPUT.txt and the committed plan/build-log prose): tasks/, docs/, *.md, *.txt skip
printf '+++ b/src/b.ts\n+window.confirm("x")\n+++ b/tasks/platform/waves/TK-1-RED-OUTPUT.txt\n+model claude-sonnet-5 window.alert("y")\n+++ b/docs/build-log/waves/TK-1.md\n+VERCEL_URL must not be used\n+++ b/README.txt\n+claude-opus-5\n+++ b/.harness/specs/TK-1/plan.md\n+window.prompt("z")\n' > "$T/d2.diff"
[ "$(mc_iron_law_scan "$T/d2.diff")" = 1 ] && ok || bad "iron-law scan must skip tasks/, docs/, *.md and *.txt evidence files (got $(mc_iron_law_scan "$T/d2.diff"))"


# ============================================================================
# 2b. mc_ci_state: a CANCELLED run is not a red one (project-5 #586, 2026-09-14)
#     A push cancels the run it supersedes, so a sha with entirely green CI
#     carries a cancelled entry — and this read answered `red`, which parked the
#     PR at "re-review deferred — CI red" against a workflow that never failed.
#     Driven through the real gh JSON so the jq that picks the latest run per
#     workflow is under test, not a hand-rolled restatement of it.
# ============================================================================
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
# gh api -i -X GET repos/<slug>/actions/runs?head_sha=<sha>&per_page=50 — the
# gh_rest read (BH-1586): a whole HTTP response with the raw payload, and the
# jq that picks the latest run per workflow runs in mc_ci_state itself.
# The rate-limit read answers real JSON even here: an empty answer leaves
# bin/lib/gh-budget.sh a 0-byte cache file in this same scratch tree, and the
# next tick then dies silently in the middle of tick_project.
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
esac
S=\$(sed -E 's/.*head_sha=([^&]*).*/\1/' <<<"\$5")
[ -f "$T/runs-\$S.json" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; exit 0; }
printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$T/runs-\$S.json"
EOF
chmod +x "$T/fakebin/gh"
CI() { ( PATH="$T/fakebin:$PATH"; mc_ci_state o/r "$1" ); }
RUNS() { # RUNS <sha> <name|started|attempt|status|conclusion>...
  local sha="$1" first=1 out='{"workflow_runs":[' n t a st c
  shift
  for r in "$@"; do
    IFS='|' read -r n t a st c <<<"$r"
    [ "$first" = 1 ] || out="$out,"; first=0
    out="$out$(jq -nc --arg n "$n" --arg t "$t" --argjson a "$a" --arg s "$st" --arg c "$c" \
      '{name:$n,run_started_at:$t,run_attempt:$a,status:$s,conclusion:(if $c=="" then null else $c end)}')"
  done
  printf '%s]}' "$out" > "$T/runs-$sha.json"
}
D=2026-09-14T03
RUNS green1 "CI|$D:00:00Z|1|completed|success" "E2E|$D:02:00Z|1|completed|cancelled"
[ "$(CI green1)" = green ] && ok || bad "a cancelled run beside a green one must be green, never red (got $(CI green1))"
RUNS skipped1 "CI|$D:00:00Z|1|completed|success" "Lint|$D:01:00Z|1|completed|skipped"
[ "$(CI skipped1)" = green ] && ok || bad "a skipped workflow is not evidence and must not turn the sha red (got $(CI skipped1))"
RUNS red1 "CI|$D:00:00Z|1|completed|success" "E2E|$D:02:00Z|1|completed|failure"
[ "$(CI red1)" = red ] && ok || bad "a real failure must still be red (got $(CI red1))"
RUNS red2 "E2E|$D:00:00Z|1|completed|cancelled" "E2E|$D:02:00Z|2|completed|failure"
[ "$(CI red2)" = red ] && ok || bad "the LATEST attempt of a workflow decides: cancelled then failed is red (got $(CI red2))"
RUNS fixed1 "E2E|$D:00:00Z|1|completed|failure" "E2E|$D:02:00Z|2|completed|success"
[ "$(CI fixed1)" = green ] && ok || bad "a failure re-run green must not keep the sha red for ever (got $(CI fixed1))"
RUNS pend1 "CI|$D:00:00Z|1|completed|success" "E2E|$D:02:00Z|1|in_progress|"
[ "$(CI pend1)" = pending ] && ok || bad "a run still going must be pending (got $(CI pend1))"
RUNS allcut "E2E|$D:00:00Z|1|completed|cancelled" "CI|$D:01:00Z|1|completed|cancelled"
[ "$(CI allcut)" = none ] && ok || bad "every run cancelled is no evidence at all — none, never green (got $(CI allcut))"
RUNS empty1
[ "$(CI empty1)" = none ] && ok || bad "no runs on the sha must be none (got $(CI empty1))"
[ "$(CI nosuchsha)" = unavailable ] && ok || bad "an API that refuses must be unavailable, never green (got $(CI nosuchsha))"
rm -f "$T/fakebin/gh"


# ============================================================================
# 2c. mc_job_running: the PR's OWN build owns it until it records a verdict
#     (2026-09-14). A pool build reviews its PR at the END of its pipeline, and
#     the */5 tick sees the PR minutes earlier — buying a Fable review there is
#     a second review of one head, and the verdict that lands afterwards is what
#     parked project-5 #864 on a `provenance` the build had not finished
#     writing. Bounded: a builder that died must not hold a PR for ever.
#     Driven through the real /api/verdict body so the jq under test is the one
#     that runs in prod, not a restatement of it.
# ============================================================================
JR() { # JR <status> <verdict-json> <age-seconds> — rc 0 = the tick must wait
  local st="$1" v="$2" age="$3" at
  at=$(date -u -d "@$(( $(date -u +%s) - age ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  jq -nc --arg s "$st" --argjson v "$v" --arg t "$at" \
    '{job_id:"build-demo-os-TK-12-1", verdict:$v, job:{status:$s,stage:"review",updated_at:$t}}' > "$T/jobrow.json"
  ( _jobs_req() { cat "$T/jobrow.json"; }
    mc_job_running https://github.com/example-org/demo-os/pull/12 )
}
OUT=$(JR running null 60) && ok || bad "a RUNNING job with no verdict yet must make the conductor wait"
grep -q 'build-demo-os-TK-12-1' <<<"$OUT" && ok || bad "the wait must name the job in its line (got '$OUT')"
JR running '"APPROVE"' 60 >/dev/null && bad "a job that already recorded its verdict has nothing left to wait for" || ok
JR done null 60          >/dev/null && bad "a job that is not running must never hold a PR" || ok
JR failed null 60        >/dev/null && bad "a FAILED job must never hold a PR" || ok
JR running null 7200     >/dev/null && bad "past MC_JOB_WAIT_SECS a running row is a dead builder, not a wait" || ok
( MC_JOB_WAIT_SECS=10800; JR running null 7200 >/dev/null ) && ok || bad "MC_JOB_WAIT_SECS must be the knob that decides how long"
mc_job_running https://github.com/example-org/demo-os/pull/12 >/dev/null 2>&1 \
  && bad "with no jobs client sourced at all mc_job_running must fail OPEN (no wait)" || ok
( _jobs_req() { return 1; }; mc_job_running https://github.com/example-org/demo-os/pull/12 >/dev/null ) \
  && bad "a worker outage must fail OPEN — an unreachable ledger cannot hold a PR" || ok
rm -f "$T/jobrow.json"


fx_conductor_tick "$DIR" "$T" || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\nissuer example-org/issuer - - 3 box-issuer\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
: # flock is NOT stubbed: the per-PR lock shard is the thing under test
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
# A build record for PR 11 (APPROVE bound to head H1) and PR 12 (APPROVE bound to
# H1 while its head is H2 = moved). PR 13 has no record but a ticket/ branch.
mkdir -p "$T/h/builds/demo-os-TK-11-202609120001" "$T/h/builds/pool-demo-os-TK-12-202609120002"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/11" > "$T/h/builds/demo-os-TK-11-202609120001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/demo-os-TK-11-202609120001/review.md"
echo "$H1" > "$T/h/builds/demo-os-TK-11-202609120001/reviewed-sha"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/12" > "$T/h/builds/pool-demo-os-TK-12-202609120002/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/pool-demo-os-TK-12-202609120002/review.md"
echo "$H1" > "$T/h/builds/pool-demo-os-TK-12-202609120002/reviewed-sha"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
# Both list branches answer --json arrays: since #329 the conductor asks
# bin/lib/gh-pr-list.sh for the list (once per HARNESS_PR_AUTHORS login) and
# does its own jq, so a stub that pre-extracted TSV would be answering a
# question the conductor no longer asks.
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    echo "WRITE VERB IN OBSERVE MODE: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$H1","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"$H2","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":13,"url":"https://github.com/example-org/demo-os/pull/13","headRefOid":"$H1","headRefName":"ticket/TK-13","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"},
 {"number":14,"url":"https://github.com/example-org/demo-os/pull/14","headRefOid":"$H1","headRefName":"fix/by-hand","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  # TEST-CHANGE (BH-782): the CLOSED list is all-mappable, so it is a REST read
  # (bin/lib/gh-rest.sh) and a REST failure is no longer retried over
  # a GraphQL pr list. The shim answers the REST path with a status line and a
  # REST-shaped body; the open list still carries GraphQL-only fields
  # (mergeStateStatus/mergeable/isInMergeQueue) and is unchanged.
  *"repos/example-org/demo-os/pulls?state=closed"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    cat <<'JR'
[{"number":15,"html_url":"https://github.com/example-org/demo-os/pull/15","title":"TK-15","body":"","state":"closed","merged_at":null,"closed_at":"2026-09-12T01:00:00Z","created_at":"2026-09-11T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","draft":false,"labels":[],"user":{"login":"operator","type":"User"},"head":{"ref":"ticket/TK-15","sha":"deadbee"},"base":{"ref":"main"}}]
JR
    ;;
  *"pr list -R example-org/issuer --state open"*) echo "[]" ;;
  # TEST-CHANGE (BH-782): the CLOSED list is all-mappable, so it is a REST read
  # (bin/lib/gh-rest.sh) and a REST failure is no longer retried over
  # a GraphQL pr list. The shim answers the REST path with a status line and a
  # REST-shaped body; the open list still carries GraphQL-only fields
  # (mergeStateStatus/mergeable/isInMergeQueue) and is unchanged.
  *"repos/example-org/issuer/pulls?state=closed"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    cat <<'JR'
[{"number":7,"html_url":"https://github.com/example-org/issuer/pull/7","title":"IS-7","body":"","state":"closed","merged_at":null,"closed_at":"2026-09-12T01:00:00Z","created_at":"2026-09-11T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","draft":false,"labels":[],"user":{"login":"operator","type":"User"},"head":{"ref":"ticket/is-7","sha":"deadbe7"},"base":{"ref":"main"}}]
JR
    ;;
  *"issue view 7"*) echo "OPEN" ;;
  *"actions/runs?head_sha=$H1"*) restpr --runs 'completed|success' 'completed|success' ;;
  *"actions/runs?head_sha=$H2"*) restpr --runs 'in_progress|' ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  # The jobs ledger's answer for one PR. A 404 (no job recorded this PR) is the
  # default and is what every case below 4j runs on; 4j drops a row in the file
  # to drive mc_job_running through the real client.
  "GET "*/api/verdict*) if [ -s "${JOBROW:-/nonexistent}" ]; then printf '%s\n200\n' "$(cat "$JOBROW")"
                        else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x REQ_SINK="$T/req.txt" JOBROW="$T/ledger-job.json" "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
: > "$T/gh-calls.txt"; : > "$T/req.txt"
run_tick
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }

# The flag state section 7e runs in, reproduced: in the parent suite sections 3b
# and 3e leave `merge-conductor-actions` and `merge-conductor-merge` on, and 7e
# needs them because `gh run rerun` is a write verb. Fixture only — 7e ends by
# removing them again to prove observe mode buys no rerun.
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# ============================================================================
# 7. THE RED LADDER AND THE STUCK-STATE DETECTOR (2026-09-15)
#
# project-5 #1045 (TK-989) went red at 02:04Z, the conductor logged it once, and
# then never touched the PR again: `WAIT_CI checks red once` had no next
# transition, because the red-twice park counts reds on DIFFERENT heads and
# nobody ever pushed to that one. It was closed by hand at 12:52Z, ten hours
# later. #1124/#1136 were the other half — parked with no owner for hours and
# nothing saying so.
#
# So two claims are pinned here. RED: red -> one rerun of the failed jobs ->
# still red on the SAME head -> RED_TWICE, handed to the resolver; a NEW head
# starts the ladder over. STUCK: every state has a TTL, a PR past it alerts
# exactly once per (PR, state, head), and where a deterministic re-kick exists
# the same tick does it.

# ============================================================================
# 7a. the classifier, pure
[ "$(MC_RED_RUNG=0 c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 1 0 0 0 - -)" = WAIT_CI ] \
  && ok || bad "rung 0 (nothing tried yet) must still be WAIT_CI — the tick dispatches the rerun"
[ "$(MC_RED_RUNG=1 c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 1 0 0 0 - -)" = WAIT_CI ] \
  && ok || bad "rung 1 (the rerun is in flight) must be WAIT_CI, never a park"
[ "$(MC_RED_RUNG=1 mc_classify OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 1 0 0 0 - - | cut -f2)" = "checks red once — failed jobs re-run, waiting on the rerun" ] \
  && ok || bad "rung 1's reason must say the rerun was bought (got '$(MC_RED_RUNG=1 mc_classify OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 1 0 0 0 - - | cut -f2)')"
[ "$(MC_RED_RUNG=2 c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 1 0 0 0 - -)" = RED_TWICE ] \
  && ok || bad "red AGAIN on the same head after its rerun must be RED_TWICE — the #1045 dead end"
[ "$(MC_RED_RUNG=2 mc_classify OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 1 0 0 0 - - | cut -f2)" = "red-twice: still red on ${H1:0:8} after its failed jobs were re-run once" ] \
  && ok || bad "the RED_TWICE reason must start with the word the resolver maps (got '$(MC_RED_RUNG=2 mc_classify OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude red 1 0 0 0 - - | cut -f2)')"
[ "$(MC_RED_RUNG=2 c OPEN DIRTY CONFLICTING $H1 $H1 APPROVE claude red 1 0 0 0 - -)" = NEEDS_REBASE ] \
  && ok || bad "a DIRTY head still rebases first — a red about a tree nobody can merge is a red about nothing"
[ "$(MC_RED_RUNG=0 c OPEN CLEAN MERGEABLE $H1 $H1 APPROVE claude green 0 0 0 0 - -)" = READY ] \
  && ok || bad "the ladder must say nothing at all about a green head"
grep -q 'RED_TWICE' <<<"$MC_STATES" && ok || bad "RED_TWICE must be in MC_STATES"
mc_resolver_owns red-twice && ok || bad "red-twice must be a reason the resolver owns, or it pages daily for ever"
mc_resolver_owns "red-twice: still red on abc" && ok || bad "mc_resolver_owns must match red-twice on the prefix, detail and all"
mc_park_state RED_TWICE && ok || bad "RED_TWICE must age and display as a park, like BLOCKED_HUMAN"
mc_park_state WAIT_CI && bad "WAIT_CI is not a park" || ok
# red-twice must NOT be sticky: it is re-derived from CI every tick, and a rerun
# that goes green underneath us has to move the row (the red-ci-twice rule).
mc_handoff_owns red-twice && bad "a red-twice park must not freeze the row — CI can legitimately go green under it" || ok

# 7b. the ladder's bookkeeping: one rerun per head, and a push starts over
mc_red_rung example-org/x#41 "$H1" | grep -qx 0 && ok || bad "a head nothing has re-run is rung 0"
mc_rerun_record example-org/x#41 "$H1"
mc_red_rung example-org/x#41 "$H1" | grep -qx 1 && ok || bad "a rerun just dispatched is rung 1 — the tick that bought it must not read the OLD red as a second one"
mc_red_rung example-org/x#41 "$H2" | grep -qx 0 && ok || bad "the ladder is keyed on the head: a push resets it to rung 0"
[ "$(MC_RED_RERUN_SETTLE_SECS=0 mc_red_rung example-org/x#41 "$H1")" = 2 ] \
  && ok || bad "past MC_RED_RERUN_SETTLE_SECS a red on the same head is the SECOND red"
[ "$(grep -c "^cirerun example-org/x#41 $H1 " "$MC_ATTEMPTS")" = 1 ] \
  && ok || bad "the rerun mark is one line per (PR, head) in the attempts ledger"
# A READ THAT NAMES NO FAILED RUN MUST NOT SPEND THE RUNG. mc_ci_state has just
# said `red` off the same endpoint, so an empty answer here is the API refusing
# us — and spending the rung on it would put the PR one tick from a fresh
# rebuild of the whole ticket on the strength of one flaky GET.
( flaky_failed_runs() { :; }
  mc_red_rerun o/r example-org/x#45 "$H1" ) \
  && bad "an unreadable red must not report a dispatched rerun" || ok
[ "$(mc_red_rung example-org/x#45 "$H1")" = 0 ] \
  && ok || bad "an unreadable red must leave the rung at 0 so the next tick asks again (got $(mc_red_rung example-org/x#45 "$H1"))"
grep -q 'x#45 red on .* could not be read — no rerun this tick and no rung spent' "$MC_LOG" \
  && ok || bad "and it must say so in the log, not fail silently"

# 7c. the TTL table
[ "$(mc_ttl WAIT_CI)" = 5400 ] && ok || bad "WAIT_CI TTL must default to 90m (got $(mc_ttl WAIT_CI))"
[ "$(mc_ttl NEEDS_REBASE)" = 1800 ] && ok || bad "NEEDS_REBASE TTL must default to 30m"
[ "$(mc_ttl REBASING)" = 1800 ] && ok || bad "REBASING TTL must default to 30m"
[ "$(mc_ttl QUEUED)" = 3600 ] && ok || bad "QUEUED TTL must default to 60m"
[ "$(mc_ttl READY)" = 1200 ] && ok || bad "READY TTL must default to 20m"
[ "$(mc_ttl STACKED_WAIT)" = 21600 ] && ok || bad "STACKED_WAIT TTL must default to 6h"
[ "$(mc_ttl BLOCKED_HUMAN)" = 7200 ] && ok || bad "BLOCKED_HUMAN TTL must default to 2h"
[ "$(mc_ttl RED_TWICE)" = 7200 ] && ok || bad "RED_TWICE TTL must default to 2h"
for TERM in MERGED CLOSED ABANDONED; do
  [ "$(mc_ttl $TERM)" -lt 0 ] || { bad "$TERM is terminal and must have no TTL"; break; }
done; ok
[ "$(mc_ttl NotAState)" -lt 0 ] && ok || bad "an unknown state must have no TTL, never a default one"
[ "$(MC_TTL_READY=60 mc_ttl READY)" = 60 ] && ok || bad "MC_TTL_<STATE> must override the default from env/global.env"
[ "$(MC_TTL_READY=-1 mc_ttl READY)" = "-1" ] && ok || bad "MC_TTL_<STATE>=-1 must turn one TTL off"
[ "$(MC_TTL_READY=nonsense mc_ttl READY)" = 1200 ] && ok || bad "a junk override must fall back to the default, never break the loop"
# every state the conductor can put on a row is either in the TTL table or terminal
for ST in $MC_STATES; do
  case "$ST" in MERGED|CLOSED|ABANDONED) continue ;; esac
  [ "$(mc_ttl "$ST")" -gt 0 ] || { bad "state $ST has no TTL — a PR could sit in it for ever with nothing saying so"; break; }
done; ok

# 7d. the stuck detector: one alert per (PR, state, head), and it re-arms on a push
STUCKURL=https://github.com/example-org/x/pull/41
: > "$T/h/logs/ALERTS.log"
NOWS=$(date -u +%s)
mc_row_put example-org/x#41 WAIT_CI "$NOWS" "$H1" "$H1" - "checks pending" "$STUCKURL"
mc_stuck_check example-org/x#41 WAIT_CI "$NOWS" "$H1" "$STUCKURL" "checks pending" \
  && bad "a state inside its TTL must not be called stuck" || ok
OLDS=$(( NOWS - 6000 ))
mc_stuck_check example-org/x#41 WAIT_CI "$OLDS" "$H1" "$STUCKURL" "checks pending" \
  && ok || bad "90m in WAIT_CI must trip the TTL"
[ "$(grep -c 'example-org/x#41 WAIT_CI' "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "the stuck detector must alert once (got $(grep -c 'example-org/x#41 WAIT_CI' "$T/h/logs/ALERTS.log"))"
grep -q 'waiting on a required check to report' "$T/h/logs/ALERTS.log" \
  && ok || bad "the alert must name what the PR is waiting on, not just that it is stuck: $(cat "$T/h/logs/ALERTS.log")"
grep -q "$STUCKURL" "$T/h/logs/ALERTS.log" && ok || bad "the stuck alert must name the PR URL"
mc_stuck_check example-org/x#41 WAIT_CI "$OLDS" "$H1" "$STUCKURL" "checks pending" \
  && bad "a second tick over the same (PR, state, head) must not page again" || ok
[ "$(grep -c 'example-org/x#41 WAIT_CI' "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "the dedupe must survive across ticks (state file), not just inside one"
mc_stuck_check example-org/x#41 WAIT_CI "$OLDS" "$H2" "$STUCKURL" "checks pending" \
  && ok || bad "a NEW head is a PR somebody moved — it gets its own TTL and its own one alert"
mc_stuck_check example-org/x#41 READY "$OLDS" "$H1" "$STUCKURL" "clean" \
  && ok || bad "a different state on the same head is a different stuck fact and alerts once too"
mc_stuck_check example-org/x#42 MERGED "$OLDS" "$H1" "$STUCKURL" "merged" \
  && bad "a terminal state has no TTL and must never be called stuck" || ok
mc_stuck_check example-org/x#43 WAIT_CI "" "$H1" "$STUCKURL" "checks pending" \
  && bad "a row with no since must be skipped, never aged from epoch 0" || ok
grep -q 'example-org/x#41 STUCK .* in WAIT_CI .* past its 90m TTL' "$MC_LOG" \
  && ok || bad "the conductor log must carry the stuck line too (the ALERTS copy is not the durable record)"
# a park the resolver owns is displayed as BLOCKED_AGENT even when it is stuck
mc_stuck_check example-org/x#44 BLOCKED_HUMAN "$(( NOWS - 9000 ))" "$H1" "$STUCKURL" "conflict-unresolvable: x.ts" \
  && ok || bad "a park past 2h must be called stuck — this is the #1124/#1136 shape"
grep -q 'example-org/x#44 BLOCKED_AGENT' "$T/h/logs/ALERTS.log" \
  && ok || bad "a stuck park must page under the name of the lane that owns it (BLOCKED_AGENT)"
grep -q 'blocked-resolver.sh to drain the park' "$T/h/logs/ALERTS.log" \
  && ok || bad "the stuck park alert must say the resolver has not drained it"

# 7e. the whole script: red once buys a rerun, red twice on the SAME head is
#     RED_TWICE and is handed off, and a push starts the ladder over.
cp "$DIR/bin/lib/flaky.sh" "$T/h/bin/lib/" 2>/dev/null
for N in 61 62; do
  D7="$T/h/builds/pool-demo-os-TK-$N-20260915000$N"
  mkdir -p "$D7"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/$N" > "$D7/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$D7/review.md"
  echo "$H1" > "$D7/reviewed-sha"
done
# The head PR 61 sits on is $H1 until $T/pushed exists, then $H2 — that is how
# "somebody pushed a fix" is driven without a second stub.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
HD="$H1"; [ -f "$T/pushed" ] && HD="$H2"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"run rerun"*) printf '%s\n' "\$*" >> "$T/reruns7.txt"; exit 0 ;;
  *"api -X PATCH"*) printf '%s\n' "\$*" >> "$T/kicks7.txt"; exit 0 ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"pr review"*|*"pr edit"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<J
[{"number":61,"url":"https://github.com/example-org/demo-os/pull/61","headRefOid":"\$HD","headRefName":"ticket/TK-61","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"},
 {"number":62,"url":"https://github.com/example-org/demo-os/pull/62","headRefOid":"$H1","headRefName":"ticket/TK-62","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"select(.conclusion"*) printf '901|.github/workflows/ci.yml|CI\n' ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|failure|901|CI' ;;
  *"actions/runs/901/jobs"*) echo "unit" ;;
  *"v3.diff"*) restpr --diff ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
rm -f "$T/pushed"; : > "$T/reruns7.txt"; : > "$T/gh-writes.txt"
rm -f "$T/h/state/merge-conductor/stuck"/* 2>/dev/null
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ "$(state_of 'example-org/demo-os#61')" = WAIT_CI ] \
  && ok || bad "the FIRST red on a head must be WAIT_CI, not a park (got $(state_of 'example-org/demo-os#61'))"
[ "$(grep -c 'run rerun 901 --failed' "$T/reruns7.txt")" = 2 ] \
  && ok || bad "each red PR must buy exactly one rerun of its failed runs (got '$(cat "$T/reruns7.txt")')"
grep -q 'demo-os#61.*red ladder rung 1' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the rerun must be logged as the ladder's rung 1"
grep -qE "^cirerun example-org/demo-os#61 $H1 [0-9]+$" "$T/h/state/merge-conductor/attempts.txt" \
  && ok || bad "the rerun must be recorded per (PR, head) with the epoch the ladder ages against"
# the very next tick must NOT call the same red a second one: the rerun it just
# dispatched has not even flipped the run yet (MC_RED_RERUN_SETTLE_SECS).
: > "$T/reruns7.txt"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ "$(state_of 'example-org/demo-os#61')" = WAIT_CI ] \
  && ok || bad "inside the settle window the OLD red must not be read as a second one (got $(state_of 'example-org/demo-os#61'))"
[ -s "$T/reruns7.txt" ] && bad "one rerun per head: the second tick must not re-run it again" || ok
# past the settle window, still red on the SAME head: RED_TWICE, handed off.
: > "$T/reruns7.txt"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_RED_RERUN_SETTLE_SECS=0
[ "$(state_of 'example-org/demo-os#61')" = RED_TWICE ] \
  && ok || bad "red again on the same head after its rerun must be RED_TWICE (got $(state_of 'example-org/demo-os#61'))"
[ "$(awk -F'\t' '$1=="example-org/demo-os#61" {print $7}' "$T/h/state/merge-conductor/pr-state.tsv" | cut -d: -f1)" = red-twice ] \
  && ok || bad "the row's reason must be the word the resolver maps (red-twice)"
grep -q 'demo-os#61 RED_TWICE red-twice:.*handed to bin/blocked-resolver.sh' "$T/h/logs/merge-conductor.log" \
  && ok || bad "a RED_TWICE park must be handed to the resolver in the log line its recovery path reads"
[ -s "$T/reruns7.txt" ] && bad "a parked head must not buy a third rerun: $(cat "$T/reruns7.txt")" || ok
# and it does not page by age, because the resolver owns it
grep -q 'demo-os#61 RED_TWICE' "$T/h/logs/ALERTS.log" 2>/dev/null \
  && bad "a park the resolver owns must not page — it alerts once, on ABANDONED" || ok
N7=$(grep -c 'demo-os#61 .* -> RED_TWICE' "$T/h/logs/merge-conductor.log")
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_RED_RERUN_SETTLE_SECS=0
[ "$(grep -c 'demo-os#61 .* -> RED_TWICE' "$T/h/logs/merge-conductor.log")" = "$N7" ] \
  && ok || bad "a settled park must not re-transition every tick"
[ "$(grep -c 'demo-os#61 RED_TWICE red-twice:.*handed to' "$T/h/logs/merge-conductor.log")" = 1 ] \
  && ok || bad "the hand-off line is one per park, not one per tick"
# A PUSH RESETS THE LADDER. The new head has had no rerun, so it is rung 0 and
# the row goes back to WAIT_CI — a fix somebody pushed must never inherit the
# park of the head it replaced.
touch "$T/pushed"; : > "$T/reruns7.txt"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_RED_RERUN_SETTLE_SECS=0
# (HEAD_MOVED, not WAIT_CI: the approval is still bound to the OLD head, so the
# drift branch answers first — which is exactly the point. What must not happen
# is the new head inheriting the previous head's park.)
[ "$(state_of 'example-org/demo-os#61')" = HEAD_MOVED ] \
  && ok || bad "a new head must leave the park and be re-adjudicated, never inherit RED_TWICE (got $(state_of 'example-org/demo-os#61'))"
grep -q "run rerun 901 --failed" "$T/reruns7.txt" \
  && ok || bad "the new head gets its own rerun (got '$(cat "$T/reruns7.txt")')"
rm -f "$T/pushed"
# Observe mode buys no rerun at all: `gh run rerun` is a write verb.
rm -f "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
: > "$T/reruns7.txt"
mc_row_put 'example-org/demo-os#62' WAIT_CI "$(date -u +%s)" "$H1" "$H1" - "checks red once" https://github.com/example-org/demo-os/pull/62
grep -v "^cirerun example-org/demo-os#62 " "$T/h/state/merge-conductor/attempts.txt" > "$T/att7.tmp"
mv -f "$T/att7.tmp" "$T/h/state/merge-conductor/attempts.txt"
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0
[ -s "$T/reruns7.txt" ] && bad "observe-only must never re-run anything: $(cat "$T/reruns7.txt")" || ok
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# 7f. the stuck detector inside the tick: ONE alert, and the re-kick in the same
#     pass. MC_CI_KICK_MIN_AGE is pushed out of reach so the 10-minute kick above
#     cannot fire — what is under test here is the TTL's own re-kick.
: > "$T/h/logs/ALERTS.log"; : > "$T/kicks7.txt"
rm -f "$T/h/state/merge-conductor/stuck"/* 2>/dev/null
grep -v "example-org/demo-os#62" "$T/h/state/merge-conductor/attempts.txt" > "$T/att7.tmp"
mv -f "$T/att7.tmp" "$T/h/state/merge-conductor/attempts.txt"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH"*) printf '%s\n' "\$*" >> "$T/kicks7.txt"; exit 0 ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"pr review"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<J
[{"number":62,"url":"https://github.com/example-org/demo-os/pull/62","headRefOid":"$H1","headRefName":"ticket/TK-62","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs ;;
  *"v3.diff"*) restpr --diff ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
OLD7=$(( $(date -u +%s) - 7000 ))
mc_row_put 'example-org/demo-os#62' WAIT_CI "$OLD7" "$H1" "$H1" - "checks none" https://github.com/example-org/demo-os/pull/62
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 MC_CI_KICK_MIN_AGE=999999
[ "$(grep -c 'demo-os#62 WAIT_CI .*STUCK' "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "a PR past its state TTL must raise one stuck alert (got: $(cat "$T/h/logs/ALERTS.log"))"
grep -q 'pulls/62 -f state=closed' "$T/kicks7.txt" && grep -q 'pulls/62 -f state=open' "$T/kicks7.txt" \
  && ok || bad "the TTL must do the deterministic re-kick in the same tick (got: $(cat "$T/kicks7.txt"))"
grep -q 'demo-os#62 stuck in WAIT_CI past its TTL — CI re-kicked' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the re-kick must say it was the stuck detector's, not the 10-minute kick's"
K7=$(grep -c 'pulls/62' "$T/kicks7.txt")
run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 MC_CI_KICK_MIN_AGE=999999
[ "$(grep -c 'demo-os#62 WAIT_CI .*STUCK' "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "the stuck alert must not repeat on the next tick (got $(grep -c 'demo-os#62 WAIT_CI .*STUCK' "$T/h/logs/ALERTS.log"))"
[ "$(grep -c 'pulls/62' "$T/kicks7.txt")" = "$K7" ] \
  && ok || bad "and neither must the re-kick"

echo "mc/classify-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
