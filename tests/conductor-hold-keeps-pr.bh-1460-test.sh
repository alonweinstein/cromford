#!/bin/bash
# tests/conductor-hold-keeps-pr.bh-1460-test.sh — the merge conductor's two PR
# closers ask the TICKET first, and a HOLD keeps the PR.
#
# 2026-09-22: the lead put ticket #1386 on HOLD to stop the resolver pushing to
# `ticket/bh-1386` while the iron-law park on its PR #1453 was adjudicated by
# hand. Twenty minutes later that green, approved PR was CLOSED and a person had
# to reopen it. `bin/blocked-resolver.sh` had a hold gate; the merge family had
# none — `grep -n hold_check bin/merge-conductor.sh bin/merge-sweep.sh` answers
# nothing — and two functions in bin/lib/mc/rebase.sh close a PR without ever
# reading the ticket:
#
#   mc_kick_ci            closes and REOPENS to fire CI. When the reopen is
#                         refused (a base branch deleted a minute earlier
#                         refuses it) the PR is LEFT CLOSED and only a person
#                         can put it back — #1453's damage exactly.
#   mc_close_for_rebuild  closes a stranded stacked child so the ticket rebuilds.
#
# So the guard goes INSIDE those two, at the choke point, not at their eleven
# call sites. Everything else must behave exactly as it did: an ABANDON, a clear
# ticket, an unreadable read, a board ticket with no issue number and a box with
# no hold library all still close.
#
# Driven, never grepped: every assertion is about the argv the stub `gh`
# RECORDED, so a version that calls the guard and ignores its answer is red.
# Run from anywhere: tests/conductor-hold-keeps-pr.bh-1460-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -r $((NOW - ${1:-0})) '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$T/fakebin"
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/"
export HARNESS="$H" PATH="$T/fakebin:$PATH" GHT="$T"
export MC_KICK_REOPEN_TRIES=1 MC_KICK_REOPEN_SLEEP=0

# The stub: every argv line is recorded, the PR read answers from $T/pr.json and
# the issue/comments reads from $T/issue.json / $T/comments.json. A missing
# fixture file is a 404, the way a real `gh api` answers for an issue that is
# not there.
#
# AND IT ANSWERS PER ISSUE NUMBER (review round 1, BH-1460). `$T/comments-<n>.json`
# wins over the generic thread when it exists. A stub that answered the same
# thread for every number could not tell "the guard read #9" from "the guard
# read #2", so a guard deriving the ticket from the WRONG part of the head ref
# passed every row in this file. Section 9 is only able to go red because of it.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/argv.log"
N=\$(printf '%s' "\$*" | sed -nE 's#.*repos/o/r/(issues|pulls)/([0-9]+).*#\2#p')
case "\$*" in
  *"-X PATCH"*"state=closed"*) printf '%s\n' "\$*" >> "$T/closed.log"; echo '{}'; exit 0 ;;
  *"-X PATCH"*"state=open"*)   printf '%s\n' "\$*" >> "$T/reopened.log"; echo '{}'; exit 0 ;;
  *"issues/"*"/comments"*)
    case "\$*" in
      *"-F body=@"*|*"-f body="*) printf '%s\n' "\$*" >> "$T/posted.log"; echo '{"id":1}'; exit 0 ;;
    esac
    [ -s "$T/comments-\$N.json" ] && { cat "$T/comments-\$N.json"; exit 0; }
    cat "$T/comments.json" 2>/dev/null || echo '[]'; exit 0 ;;
  *"repos/o/r/issues/"*) [ -s "$T/issue.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
                         cat "$T/issue.json"; exit 0 ;;
  *"repos/o/r/pulls/"*)  [ -s "$T/pr.json" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
                         cat "$T/pr.json"; exit 0 ;;
esac
echo '{}'
exit 0
GH
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"; chmod +x "$T/fakebin/sleep"

# THE LIB IS **NOT** SOURCED HERE, and that is the point of section 8 below.
# bin/merge-conductor.sh and bin/lib/merge-conductor-lib.sh source the mc/
# modules and nothing else, so a guard that merely asked `command -v hold_check`
# would be a permanent no-op in production while passing green in a suite that
# had helpfully sourced the library itself. This file loads the modules the way
# the real lane does, and nothing more.
#
# mc_log / mc_alert are recorded rather than stubbed silent: "the refusal was
# said out loud" is only provable against a recorder.
# bin/lib/mc/log.sh sets MC_H (the module split's own $HARNESS); rebase.sh reads
# it at source time, so it loads first — the order bin/lib/merge-conductor-lib.sh
# uses. Nothing else in log.sh is needed here.
# shellcheck source=/dev/null
. "$H/bin/lib/mc/log.sh" || { echo "cannot source mc/log.sh"; exit 1; }
# shellcheck source=/dev/null
. "$H/bin/lib/mc/rebase.sh" || { echo "cannot source mc/rebase.sh"; exit 1; }
mc_log()   { printf '%s\n' "$*" >> "$T/mc.log"; }
mc_alert() { printf '%s\n' "$*" >> "$T/mc-alert.log"; }

# pr_open <head-ref> — the PR the closers read.
pr_open() {
  jq -nc --arg r "${1:-ticket/bh-9}" \
    '{number:9,state:"open",head:{ref:$r,sha:"aaaaaaaaaaaa"},base:{ref:"main"}}' > "$T/pr.json"
}
issue_open() { jq -nc '{number:9,state:"open",labels:[{name:"ai-build"}],title:"TK-9",body:"## Scope"}' > "$T/issue.json"; }
thread() { if [ -z "${1:-}" ]; then echo '[]' > "$T/comments.json"; else
             jq -nc --arg b "$1" --arg c "$(ISO 600)" '[{body:$b,created_at:$c,user:{type:"User"}}]' > "$T/comments.json"; fi; }
# thread_n <issue-number> <body> — the thread on ONE issue, which the generic
# thread above does not answer for. Used by section 9 to hold #9 while #2 is
# clear (and the other way round), the only way to prove WHICH ticket was read.
thread_n() { jq -nc --arg b "$2" --arg c "$(ISO 600)" \
               '[{body:$b,created_at:$c,user:{type:"User"}}]' > "$T/comments-$1.json"; }
reset() { : > "$T/argv.log"; : > "$T/closed.log"; : > "$T/reopened.log"; : > "$T/posted.log"
          : > "$T/mc.log"; : > "$T/mc-alert.log"; rm -f "$T"/comments-[0-9]*.json
          MC_HOLD_MEMO=''; pr_open; issue_open; thread ""; }
closed_n() { grep -c . "$T/closed.log" 2>/dev/null | tr -dc '0-9'; }
pr_reads() { grep -c 'repos/o/r/pulls/9$' "$T/argv.log" 2>/dev/null | tr -dc '0-9'; }

# ── 1. mc_kick_ci: a HOLD keeps the PR ──────────────────────────────────────
reset; thread 'HOLD — adjudicating the park by hand'
mc_kick_ci o/r 9; RC=$?
[ "$(closed_n)" = 0 ] && ok || bad "1: a held ticket's PR must not be closed by the CI kick (closed $(closed_n) time(s))"
[ "$RC" != 0 ] && ok || bad "1: the kick must report that it did not happen (rc $RC)"
grep -q 'held, PR kept' "$T/mc.log" && ok \
  || bad "1: the refusal must be said out loud as 'held, PR kept': $(cat "$T/mc.log")"
[ ! -s "$T/mc-alert.log" ] && ok || bad "1: an obeyed hold is not an alert: $(cat "$T/mc-alert.log")"

# ── 2. mc_close_for_rebuild: the same ───────────────────────────────────────
reset; thread 'HOLD — adjudicating the park by hand'
mc_close_for_rebuild o/r 9 "closing for a rebuild"; RC=$?
[ "$(closed_n)" = 0 ] && ok || bad "2: a held ticket's PR must not be closed for a rebuild"
[ "$RC" != 0 ] && ok || bad "2: the close must report that it did not happen (rc $RC)"
grep -q 'held, PR kept' "$T/mc.log" && ok || bad "2: the refusal must be said out loud"

# ── 3. no hold: both close exactly as they always did ───────────────────────
reset
mc_kick_ci o/r 9; RC=$?
[ "$(closed_n)" = 1 ] && ok || bad "3: an unheld PR must still be closed by the kick"
[ -s "$T/reopened.log" ] && ok || bad "3: ...and reopened"
[ "$RC" = 0 ] && ok || bad "3: the kick must report success (rc $RC)"
reset
mc_close_for_rebuild o/r 9 "closing for a rebuild"; RC=$?
[ "$(closed_n)" = 1 ] && ok || bad "3: an unheld PR must still be closed for a rebuild"
[ -s "$T/posted.log" ] && ok || bad "3: ...with its reason commented first"

# ── 4. ABANDON is not a pause: the close proceeds ───────────────────────────
reset; thread 'ABANDON — wrong approach, close it'
mc_kick_ci o/r 9 >/dev/null 2>&1
[ "$(closed_n)" = 1 ] && ok || bad "4: an ABANDON must not keep the PR open"
grep -q 'held, PR kept' "$T/mc.log" && bad "4: an ABANDON is not a pause" || ok

# ── 5. a RESUME newer than the HOLD closes again ────────────────────────────
reset
jq -nc --arg h "$(ISO 1200)" --arg r "$(ISO 60)" \
  '[{body:"HOLD — wait",created_at:$h,user:{type:"User"}},{body:"RESUME",created_at:$r,user:{type:"User"}}]' \
  > "$T/comments.json"
mc_kick_ci o/r 9 >/dev/null 2>&1
[ "$(closed_n)" = 1 ] && ok || bad "5: a lifted hold must not keep the PR"

# ── 6. the answers that are NOT a hold behave as they always did ────────────
# An issue the credential cannot read says NOTHING about the ticket, and a lane
# that stops on every unreadable read is a lane an outage freezes. A board
# ticket (no issue number in the head ref) has no GitHub issue to read at all.
reset; rm -f "$T/issue.json"
mc_kick_ci o/r 9 >/dev/null 2>&1
[ "$(closed_n)" = 1 ] && ok || bad "6: an unreadable issue must not block the kick"
reset; pr_open "feature/no-ticket-here"
mc_kick_ci o/r 9 >/dev/null 2>&1
[ "$(closed_n)" = 1 ] && ok || bad "6: a head ref with no ticket number must not block the kick"
# A PR that is already CLOSED is not a PR a hold is protecting.
reset; thread 'HOLD — wait'
jq -nc '{number:9,state:"closed",head:{ref:"ticket/bh-9",sha:"aaaaaaaaaaaa"},base:{ref:"main"}}' > "$T/pr.json"
mc_kick_ci o/r 9 >/dev/null 2>&1
[ "$(closed_n)" = 1 ] && ok || bad "6: a closed PR is not kept open by a hold"

# ── 7. no hold library on the box: today's behaviour, never a freeze ────────
# A box mid-sync has bin/lib/mc/ and not bin/lib/hold.sh. It must close exactly
# as it always did rather than die on an unset function.
reset; thread 'HOLD — wait'
mv "$H/bin/lib/hold.sh" "$T/hold.sh.away"
( unset -f hold_check hold_classify hold_is_pause hold_is_abandon 2>/dev/null
  mc_kick_ci o/r 9 >/dev/null 2>&1 )
[ "$(closed_n)" = 1 ] && ok || bad "7: a box with no hold library must behave exactly as it did"
mv "$T/hold.sh.away" "$H/bin/lib/hold.sh"

# ── 8. THE GUARD LOADS ITS OWN LIBRARY ──────────────────────────────────────
# Nothing in the merge lane sources bin/lib/hold.sh: bin/merge-conductor.sh and
# bin/lib/merge-conductor-lib.sh load the mc/ modules and stop. A guard that
# only asked `command -v hold_check` would therefore be a no-op on every real
# tick — permanently, silently, and green in any suite that had sourced the
# library for it. This runs the closer in a shell where the hold functions do
# NOT exist and the file DOES, which is production's shape exactly.
reset; thread 'HOLD — adjudicating the park by hand'
( unset -f hold_check hold_classify hold_is_pause hold_is_abandon 2>/dev/null
  command -v hold_check >/dev/null 2>&1 && exit 9      # the premise itself
  mc_kick_ci o/r 9 >/dev/null 2>&1 ); RC=$?
[ "$RC" != 9 ] && ok || bad "8: the premise is wrong — hold_check was still defined"
[ "$(closed_n)" = 0 ] && ok \
  || bad "8: the guard must source bin/lib/hold.sh itself — nothing in the merge lane does"

# ── 9. THE TICKET IS THE ONE THE BRANCH NAMES, ON EVERY BRANCH SHAPE ────────
# The first cut of this guard read the ticket off the head ref's TRAILING
# digits. `git ls-remote origin 'refs/heads/ticket/*'` on this repo the day it
# was written: 360 plain `ticket/bh-N`, 73 `-r2`, 17 `-r3`, 3 `-r4`, 2 `-r5`,
# 1 `-step0`, 10 `-local` — so for ~20% of live build branches it asked about
# the RETRY NUMBER instead of the ticket: `ticket/bh-1000-r2` read issue #2,
# `-step0` read #0, `-local` read nothing at all. A held #1000 did not protect
# its own round-2 PR, and a held #2 would have frozen the CI kick on every
# round-2 PR in the fleet. A ticket in round 2+ is exactly the one a lead pauses
# to adjudicate by hand, so the wrong 20% was the 20% that mattered.
#
# mc_ticket_of_branch (same file) has parsed this shape correctly since the
# rebase lane was written; this asks the guard to use it.
for REF in ticket/bh-9-r2 ticket/bh-9-r3 ticket/bh-9-step0 ticket/bh-9-local; do
  reset; pr_open "$REF"; thread ""; thread_n 9 'HOLD — adjudicating the park by hand'
  mc_kick_ci o/r 9 >/dev/null 2>&1
  [ "$(closed_n)" = 0 ] && ok \
    || bad "9: $REF belongs to ticket #9 — a HOLD on #9 must keep its PR (closed $(closed_n) time(s))"
done
# ...and the retry number is NOT a ticket: a hold on #2 says nothing about
# ticket/bh-9-r2, which must close exactly as it always did.
reset; pr_open ticket/bh-9-r2; thread ""; thread_n 2 'HOLD — a different ticket entirely'
mc_kick_ci o/r 9 >/dev/null 2>&1
[ "$(closed_n)" = 1 ] && ok \
  || bad "9: a hold on #2 must not keep ticket/bh-9-r2's PR — #2 is the retry number, not the ticket"
grep -q 'held, PR kept' "$T/mc.log" && bad "9: the guard read the retry number as a ticket" || ok

# ── 10. ONE TICKET READ PER TICK, NOT ONE PER KICK ATTEMPT ──────────────────
# mc_kick_ci runs from seven call sites in bin/merge-conductor.sh and the
# refusal writes no attempt marker, so a held PR was re-asked — PR, issue,
# comments: three REST reads — on every kick attempt in the tick, for as long
# as the hold stood. The conductor runs one process per tick, so a memo keyed
# on `slug#num` in the process is a per-tick memo: the answer is read once and
# the refusal is still said out loud every time, because each call site's log
# line is what tells the reader why THAT close did not happen.
#
# ONLY THE HELD ANSWER IS MEMOISED, deliberately. A "not held" cached for the
# rest of a tick would let a close land minutes after a person typed HOLD,
# which is the bug this whole PR exists to kill; re-reading a clear ticket
# costs the reads it always cost.
reset; thread 'HOLD — adjudicating the park by hand'
mc_kick_ci o/r 9 >/dev/null 2>&1; FIRST=$(pr_reads)
[ "$FIRST" -ge 1 ] && ok || bad "10: the first call must actually read the PR (got $FIRST)"
: > "$T/mc.log"
mc_kick_ci o/r 9 >/dev/null 2>&1; RC=$?
[ "$(pr_reads)" = "$FIRST" ] && ok \
  || bad "10: a second kick attempt in the same tick must cost no REST read (reads $FIRST -> $(pr_reads))"
[ "$(closed_n)" = 0 ] && ok || bad "10: and it must still refuse to close"
[ "$RC" != 0 ] && ok || bad "10: ...reporting that the kick did not happen (rc $RC)"
grep -q 'held, PR kept' "$T/mc.log" && ok \
  || bad "10: the refusal is still said out loud on a memo hit — every call site's line is why THAT close did not happen"
# The memo is per PR, not per lane: a different PR is still read.
reset; thread 'HOLD — adjudicating the park by hand'
mc_kick_ci o/r 9 >/dev/null 2>&1
BEFORE=$(grep -c 'repos/o/r/pulls/' "$T/argv.log" 2>/dev/null | tr -dc '0-9')
mc_kick_ci o/r 11 >/dev/null 2>&1
AFTER=$(grep -c 'repos/o/r/pulls/' "$T/argv.log" 2>/dev/null | tr -dc '0-9')
[ "$AFTER" -gt "$BEFORE" ] && ok || bad "10: the memo is keyed on slug#num — another PR must still be read"

echo "conductor-hold-keeps-pr: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
