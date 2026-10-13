#!/bin/bash
# tests/merge-conductor-state-notes.bh-979-test.sh — a per-PR conductor state
# note is a progress report, not an alert; and what still pages is ONE family
# per (repo, state) instead of one per PR.
#
# WHAT IS AT STAKE. On 2026-09-19, 1033 of the 2019 lines in the alert-triage
# deferral spool were mc_alert output — HEAD_MOVED / WAIT_CI / STACKED_WAIT /
# "Nm in state" notes, one per PR. Each one was its own root-cause family, so the
# 6h family brake never grouped any of them and every single one bought the
# STRONG investigator.
#
# WHAT SURVIVES family(), MEASURED (round 1 review, re-measured here on the
# hub's 434 conductor spool lines with the real bin/alert_family.py): NOT the
# branch slug — folding branches alone moved families per state 59->59
# (HEAD_MOVED), 29->29 (BLOCKED_HUMAN), 12->12 (RED_TWICE). It is the status
# parenthetical `(verdict=APPROVE ci=red mergeState=BLOCKED mode=merge)`, which
# differs on every PR. Folding both moves them 59->14, 29->13, 12->8, 30->5.
#
# WHERE THE FOLD LIVES. In alert_family.fold_volatile() — the FAMILY INPUT,
# shared by every lane — and NOT in the text mc_alert sends. A grouping key may
# erase the branch a person would act on; ALERTS.log and a --critical DM may not.
# Block 3 asserts the text is intact, block 4 asserts the grouping happens, and
# block 4's LEGACY CONTROL computes the pre-BH-979 signature so "one family"
# cannot pass on inputs that were never two.
#
# Drives the REAL bin/lib/merge-conductor-lib.sh and the REAL bin/alert_family.py.
#   bash tests/merge-conductor-state-notes.bh-979-test.sh     exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$HARNESS/bin" "$HARNESS/logs" "$HARNESS/state"

# lane-alert.sh IS the alert boundary: what it receives is the assertion.
cat > "$HARNESS/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/lane-alert.calls"
STUB
chmod +x "$HARNESS/bin/lane-alert.sh"
: > "$T/lane-alert.calls"

# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"

nalerts() { wc -l < "$T/lane-alert.calls" | tr -d ' '; }
reset()   { : > "$T/lane-alert.calls"; : > "$MC_LOG"; }

# ---------- 1. a transient per-PR state note never reaches fleet_alert -------
reset
mc_alert "project-5#1058" HEAD_MOVED "30m in HEAD_MOVED: drift on ticket/bh-900-widget — https://github.com/example-org/project-5/pull/1058" "" 1
[ "$(nalerts)" = 0 ] && ok || bad "1: a state note must not raise an alert (got: $(cat "$T/lane-alert.calls"))"
# silence is not the fix — the drop this ticket is about is a SILENT one
grep -q 'project-5#1058 state note (not an alert): HEAD_MOVED' "$MC_LOG" \
  && ok || bad "1: the note must still be recorded in the conductor log (got: $(cat "$MC_LOG"))"

# ---------- 2. parks, terminals and the stuck detector are untouched ---------
reset
mc_alert "project-5#1058" BLOCKED_HUMAN "0m in BLOCKED_HUMAN: verdict-contradiction — https://github.com/example-org/project-5/pull/1058" 1
[ "$(nalerts)" = 1 ] && ok || bad "2: BLOCKED_HUMAN must still page (got $(nalerts))"
grep -q -- '--critical' "$T/lane-alert.calls" && ok || bad "2: a critical park must still be critical"
reset
mc_alert "project-5#1058" ABANDONED "the resolver ladder was exhausted — https://github.com/example-org/project-5/pull/1058"
[ "$(nalerts)" = 1 ] && ok || bad "3: ABANDONED must still page (got $(nalerts))"
reset
mc_alert "project-5" READY "mergify queue not answering for project-5 — merged directly"
[ "$(nalerts)" = 1 ] && ok || bad "4: a caller that passes no statenote is unchanged (got $(nalerts))"

# ---------- 3. the off switch restores the old behaviour verbatim ------------
reset
MC_STATE_NOTES_ALERT=1 mc_alert "project-5#1058" HEAD_MOVED "30m in HEAD_MOVED — https://github.com/example-org/project-5/pull/1058" "" 1
[ "$(nalerts)" = 1 ] && ok || bad "5: MC_STATE_NOTES_ALERT=1 must restore the old paging (got $(nalerts))"

# ---------- 3b. the alert TEXT a human reads is NOT degraded -----------------
# The branch and the status are what a person opens the PR with. The first cut of
# this build replaced the branch with `<branch>` in the text itself and bought no
# grouping for it (59 families before, 59 after); the fold now happens in the
# family key, so this assertion is the one that keeps it there.
reset
mc_alert "project-5#1058" BLOCKED_HUMAN "0m in BLOCKED_HUMAN: based on ticket/bh-900-widget, not the project base (verdict=APPROVE ci=green mergeState=CLEAN mode=merge) — https://github.com/example-org/project-5/pull/1058"
grep -qF 'ticket/bh-900-widget' "$T/lane-alert.calls" \
  && ok || bad "6: the branch a human would act on must survive into the alert (got: $(cat "$T/lane-alert.calls"))"
grep -qF 'verdict=APPROVE ci=green mergeState=CLEAN mode=merge' "$T/lane-alert.calls" \
  && ok || bad "6: and so must the status the operator reads the PR's shape from"
! grep -q '<branch>' "$T/lane-alert.calls" \
  && ok || bad "6: no placeholder may reach a human-facing alert"

# ---------- 4. ONE family per (repo, state, reason), across different PRs -----
# PROD_A and PROD_B are verbatim shapes from the hub's spool on 2026-09-19 (two
# different PRs, two different branches, two different statuses, one repo, one
# state, one reason kind).
fam() { python3 "$DIR/bin/alert_family.py" family "$1"; }
rk()  { python3 "$DIR/bin/alert_family.py" row_key "$1"; }
fold(){ python3 "$DIR/bin/alert_family.py" fold "$1"; }

PROD_A='[orchestrator/merge-conductor] conductor: example-org/cromford#731 HEAD_MOVED — 1109m in HEAD_MOVED: based on ticket/bh-587, not the project base (verdict=APPROVE ci=unavailable mergeState=DIRTY mode=merge) — https://github.com/example-org/cromford/pull/731'
PROD_B='[orchestrator/merge-conductor] conductor: example-org/cromford#704 HEAD_MOVED — 156m in HEAD_MOVED: based on ticket/bh-545, not the project base (verdict=APPROVE ci=pending mergeState=BLOCKED mode=merge) — https://github.com/example-org/cromford/pull/704'

# THE LEGACY CONTROL: the pre-BH-979 rule, hex runs then digit runs, written out
# here and nowhere in bin/. If these were already one signature, the assertion
# below would prove nothing.
legacy() { python3 -c '
import hashlib, re, sys
s = re.sub(r"[0-9a-f]{8,}", "H", sys.argv[1])
s = re.sub(r"\d+", "N", s)
print(hashlib.sha1(s.encode()).hexdigest()[:12])' "$1"; }
[ "$(legacy "$PROD_A")" != "$(legacy "$PROD_B")" ] \
  && ok || bad "7: CONTROL — before the fold these production lines must be TWO families"
[ "$(fam "$PROD_A")" = "$(fam "$PROD_B")" ] \
  && ok || bad "7: two PRs in one state on one repo must be ONE family (got $(fam "$PROD_A") vs $(fam "$PROD_B"))"

# surgical, or it is grouping unrelated incidents to look tidy
PROD_REPO=${PROD_A//cromford/project-4}
PROD_STATE=${PROD_A/HEAD_MOVED — 1109m in HEAD_MOVED/RED_TWICE — 1109m in RED_TWICE}
PROD_REASON=${PROD_A/based on ticket\/bh-587, not the project base/no verdict bound to head bc457f51 — fresh detached review}
[ "$(fam "$PROD_A")" != "$(fam "$PROD_REPO")" ]   && ok || bad "7: a different REPO must stay a different family"
[ "$(fam "$PROD_A")" != "$(fam "$PROD_STATE")" ]  && ok || bad "7: a different STATE must stay a different family"
[ "$(fam "$PROD_A")" != "$(fam "$PROD_REASON")" ] && ok || bad "7: a different REASON must stay a different family"

# AND THE NAMES THE FOLD ERASED ARE STILL IN row_key. family() decides whether a
# line buys a SESSION; row_key decides whether it gets its own ROW. Folding two
# PRs together may never cost the second incident its row.
[ "$(rk "$PROD_A")" != "$(rk "$PROD_B")" ] \
  && ok || bad "8: two PRs must keep two rows (got $(rk "$PROD_A") vs $(rk "$PROD_B"))"
BR_X='build failed on ticket/bh-900-widget after 3 attempts'
BR_Y='build failed on ticket/bh-944-gizmo after 3 attempts'
[ "$(fam "$BR_X")" = "$(fam "$BR_Y")" ] \
  && ok || bad "8: two branches, one condition — one family"
[ "$(rk "$BR_X")" != "$(rk "$BR_Y")" ] \
  && ok || bad "8: but a branch with no PR number must still keep its own row"

# the fold itself: what it takes, and what it must leave alone
[ "$(fold 'based on ticket/bh-587, not the project base')" = 'based on <branch>, not the project base' ] \
  && ok || bad "9: a branch slug folds (got: $(fold 'based on ticket/bh-587, not the project base'))"
[ "$(fold '(verdict=APPROVE ci=red mergeState=BLOCKED mode=merge)')" = '<status>' ] \
  && ok || bad "9: the status parenthetical folds (got: $(fold '(verdict=APPROVE ci=red mergeState=BLOCKED mode=merge)'))"
[ "$(fold 'see https://github.com/example-org/project-5/pull/7 and and/or')" = 'see https://github.com/example-org/project-5/pull/7 and and/or' ] \
  && ok || bad "9: urls and ordinary words are left alone (got: $(fold 'see https://github.com/example-org/project-5/pull/7 and and/or'))"

# AND THE IDENTITY STOPS AT THE SENTENCE (round 4). identifiers()' class ended
# on `[A-Za-z0-9._/-]+`, so a branch named at the end of a sentence was captured
# WITH the full stop: one incident, two identities, two console rows through
# bin/lib/alert-state.sh. The fold above keeps its greedy class on purpose —
# eating the trailing dot is what makes the two sentences ONE family — so the
# two regexes are deliberately not the same, and this is the pin for it.
ids() { python3 "$DIR/bin/alert_family.py" identifiers "$1"; }
[ "$(ids 'drift on ticket/bh-900-widget.')" = 'ticket/bh-900-widget' ] \
  && ok || bad "9: a sentence-final branch must not carry the full stop into its identity (got: $(ids 'drift on ticket/bh-900-widget.'))"
[ "$(rk 'drift on ticket/bh-900-widget.')" = "$(rk 'drift on ticket/bh-900-widget')" ] \
  && ok || bad "9: so one branch is one row_key wherever it sits in the sentence (got $(rk 'drift on ticket/bh-900-widget.') vs $(rk 'drift on ticket/bh-900-widget'))"
# CONTROL: a dot INSIDE a branch name is part of it (ticket/bh-478.1 is real)
[ "$(ids 'reviewed ticket/bh-478.1 at head')" = 'ticket/bh-478.1' ] \
  && ok || bad "9: a dot inside the slug is part of the branch name (got: $(ids 'reviewed ticket/bh-478.1 at head'))"

# ---------- 5. mc_budget_check: a machinery-wait is a note, the rest page -----
# The SET is deliberately narrow (MC_STATE_NOTE_STATES): the four states that
# mean "waiting on this lane's own machinery", plus READY and QUEUED since
# BH-4717, whose aged row the STUCK detector already pages on its own TTL.
# WAIT_CI stays an alert on its own merits — an aged WAIT_CI means CI is not
# reporting, which a person acts on, and nothing else pages before its 90m TTL.
# (Round 1 corrected the claim that existing suites already pin the BUDGET path
# for it: tests/merge-conductor-test.sh pins the STUCK detector's WAIT_CI line,
# which is a different call site. THE WAIT_CI assertion below is the pin.) What
# WAIT_CI gets from BH-979 is the FOLD, asserted in block 4.
mkdir -p "$(dirname "$MC_ROWS")"
: > "$MC_ROWS"
reset
printf 'project-5#2001\tHEAD_MOVED\t1\tdeadbeef\tdeadbeef\t-\tdrift\thttps://github.com/example-org/project-5/pull/2001\n' > "$MC_ROWS"
mc_budget_check "project-5#2001" HEAD_MOVED 1 "https://github.com/example-org/project-5/pull/2001" "drift on ticket/bh-900-widget"
[ "$(nalerts)" = 0 ] && ok || bad "10: a HEAD_MOVED budget note must not page (got: $(cat "$T/lane-alert.calls"))"
grep -q 'state note (not an alert): HEAD_MOVED' "$MC_LOG" \
  && ok || bad "10: the HEAD_MOVED budget note must be in the conductor log"

# THE COUNTER-ASSERTION, and it is the one that keeps this change from being a
# blanket mute: a state OUTSIDE the set still pages exactly as it did.
reset
printf 'project-5#2003\tWAIT_CI\t1\tdeadbeef\tdeadbeef\t-\tchecks\thttps://github.com/example-org/project-5/pull/2003\n' > "$MC_ROWS"
mc_budget_check "project-5#2003" WAIT_CI 1 "https://github.com/example-org/project-5/pull/2003" "checks pending"
[ "$(nalerts)" = 1 ] && ok || bad "10: WAIT_CI is NOT in the state-note set and must still page (got $(nalerts))"
reset
printf 'project-5#2004\tREADY\t1\tdeadbeef\tdeadbeef\t-\tclean\thttps://github.com/example-org/project-5/pull/2004\n' > "$MC_ROWS"
mc_budget_check "project-5#2004" READY 1 "https://github.com/example-org/project-5/pull/2004" "merge flag off"
[ "$(nalerts)" = 0 ] && ok || bad "10: READY is in the state-note set since BH-4717 and must not page (got: $(cat "$T/lane-alert.calls"))"
grep -q 'state note (not an alert): READY' "$MC_LOG" \
  && ok || bad "10: the READY budget note must be in the conductor log (got: $(cat "$MC_LOG"))"

# `tightened` deliberately: it is a park the blocked-resolver does NOT own, so
# the pre-existing "handed to the resolver, not paged" branch cannot be what
# makes this pass. This is the arm that would go silent if the statenote
# predicate were wrong.
reset
printf 'project-5#2002\tBLOCKED_HUMAN\t1\tdeadbeef\tdeadbeef\t-\ttightened\thttps://github.com/example-org/project-5/pull/2002\n' > "$MC_ROWS"
mc_budget_check "project-5#2002" BLOCKED_HUMAN 1 "https://github.com/example-org/project-5/pull/2002" "tightened"
[ "$(nalerts)" = 1 ] && ok || bad "11: a PARK budget alert must still page (got $(nalerts): $(cat "$T/lane-alert.calls"))"
grep -q -- '--critical' "$T/lane-alert.calls" \
  && ok || bad "11: and it must still be critical"

# ---------- 6. a suppressed note does not burn the alerted mark --------------
# mc_budget_check writes `<STATE>@<since>` into the row's `alerted` field and
# returns early the next time it matches. A SUPPRESSED note wrote that same mark,
# so an operator who later sets MC_STATE_NOTES_ALERT=1 — the documented way to
# get the old paging back — got silence for every entry already noted: the mark
# was already spent by an alert nobody ever received. The mark now records WHICH
# it was, so flipping the knob re-pages, and so a note still dedupes inside its
# own mode.
reset
: > "$MC_ROWS"
NOTEURL=https://github.com/example-org/project-5/pull/2005
printf 'project-5#2005\tHEAD_MOVED\t1\tdeadbeef\tdeadbeef\t-\tdrift\t%s\n' "$NOTEURL" > "$MC_ROWS"
mc_budget_check "project-5#2005" HEAD_MOVED 1 "$NOTEURL" "drift on ticket/bh-900-widget"
[ "$(nalerts)" = 0 ] && ok || bad "12: the note itself must not page (got: $(cat "$T/lane-alert.calls"))"
[ "$(grep -c 'state note (not an alert): HEAD_MOVED' "$MC_LOG")" = 1 ] \
  && ok || bad "12: and it is recorded once (got: $(cat "$MC_LOG"))"
# CONTROL: inside the same mode the mark still dedupes — the note is logged once,
# not every tick, or this fix trades silence for spam.
mc_budget_check "project-5#2005" HEAD_MOVED 1 "$NOTEURL" "drift on ticket/bh-900-widget"
[ "$(grep -c 'state note (not an alert): HEAD_MOVED' "$MC_LOG")" = 1 ] \
  && ok || bad "12: a second tick in the same mode must dedupe on the mark (got: $(grep -c 'state note' "$MC_LOG"))"
# THE ASSERTION: the knob that restores paging actually restores it.
reset
MC_STATE_NOTES_ALERT=1 mc_budget_check "project-5#2005" HEAD_MOVED 1 "$NOTEURL" "drift on ticket/bh-900-widget"
[ "$(nalerts)" = 1 ] \
  && ok || bad "12: MC_STATE_NOTES_ALERT=1 must page an entry that was noted while it was off (got: $(nalerts))"
grep -qF 'ticket/bh-900-widget' "$T/lane-alert.calls" \
  && ok || bad "12: and the page a human then reads is the whole note (got: $(cat "$T/lane-alert.calls"))"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
