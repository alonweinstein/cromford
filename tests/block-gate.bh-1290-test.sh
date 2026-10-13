#!/bin/bash
# tests/block-gate.bh-1290-test.sh — BH-1290: the gate's marker predicates read
# a comment body through a LIVE PIPE that ends in `grep -q`, and `grep -q` exits
# at its first match. The writer on the left (`printf … | tr -d '\r' | …`) then
# writes into a closed pipe and dies of SIGPIPE, or — with SIGPIPE ignored —
# takes EPIPE and exits 1. Every production caller runs `set -o pipefail`, so
# the pipeline's exit code becomes that writer's, and the predicate answers
# "no marker".
#
# WHICH DIRECTION THAT IS WRONG IN. For bg_marker_block it is FAIL-OPEN: a real
# BLOCK, on line 1 of a long comment, reads as ABSENT and the merge proceeds.
# That is the one way this file must never be wrong (bin/lib/block-gate.sh:8-12
# is the incident it was written for). For bg_headbound it is the deadlock
# direction instead — a bot's own head-bound APPROVE stops clearing its own
# BLOCK, which is the BH-1131 / PR #728 7h40m hold coming back through a race.
#
# WHY THE BODIES ARE 1 MB. The race needs the body to be longer than one pipe
# write, and how much longer decides how often it loses. Measured on this box
# (bash 5.2.21, pipefail + `trap '' PIPE`, marker on line 1): 4.7 KB 0/200,
# 64 KB 9/50, 256 KB 20/20, 1 MB 20/20. The ticket's own 64 KB reproduces ~20%
# of the time, which is a suite that goes green by luck on a faster host. 1 MB
# is deterministic here and the loops of 20 keep it deterministic on a host
# where the window is narrower. CI shard log 106428451073 caught the live form:
# `tr: write error: Broken pipe` followed by
# `FAIL: D: without the APPROVE the real BLOCK must still gate (rc=0 out=)`.
#
# `trap '' PIPE` IS THE POINT, not a convenience. Under the default disposition
# the writer dies of the signal and the pipeline answers 141; with the signal
# ignored it answers 1. Both are the same wrong answer, and the ignored form is
# the deterministic one to pin, so the suite fixes the disposition rather than
# hoping for a particular one.
#
# The fix removes the WRITER, not the signal: grep is fed from a here-string, so
# there is no process left to break. That is why the negatives below matter as
# much as the positives — the transport changed, the vocabulary must not have.
#
# Every fixture time is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/block-gate.bh-1290-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# SIGPIPE ignored, so a broken pipe surfaces as EPIPE + rc 1 rather than 141.
trap '' PIPE

export HARNESS="$T/h"
mkdir -p "$T/h/state" "$T/h/logs" "$T/h/bin" "$T/fakebin"

# shellcheck source=/dev/null
. "$DIR/bin/lib/block-gate.sh" || { echo "cannot source bin/lib/block-gate.sh"; exit 1; }

# One megabyte of a single character: no marker vocabulary anywhere in it, so
# any match these cases see is the marker LINE and never the padding.
BIG=$(head -c 1048576 /dev/zero | tr '\0' x)
N=20

# ══ A. the three marker predicates, on a body longer than one pipe write ═════

# A1 — the fail-open one. A BLOCK on line 1 of a long comment IS a block.
A1=0
for _ in $(seq 1 "$N"); do bg_marker_block "VERDICT: BLOCK"$'\n'"$BIG" || A1=$((A1+1)); done
[ "$A1" = 0 ] && ok || bad "A1: bg_marker_block missed a line-1 BLOCK on a 1MB body $A1/$N times (FAIL-OPEN)"

# A2 — the clear vocabulary, same shape.
A2=0
for _ in $(seq 1 "$N"); do bg_marker_clear "UNBLOCK"$'\n'"$BIG" || A2=$((A2+1)); done
[ "$A2" = 0 ] && ok || bad "A2: bg_marker_clear missed a line-1 UNBLOCK on a 1MB body $A2/$N times"

# A3 — the terminal verdict line, same shape.
A3=0
for _ in $(seq 1 "$N"); do bg_marker_approve "VERDICT: APPROVE"$'\n'"$BIG" || A3=$((A3+1)); done
[ "$A3" = 0 ] && ok || bad "A3: bg_marker_approve missed a line-1 verdict on a 1MB body $A3/$N times"

# A4 — CR STRIPPING SURVIVED THE TRANSPORT. `tr -d '\r'` removed every CR in the
# body, mid-line ones included; whatever replaces it must do the same or a
# GitHub comment posted from a CRLF client stops matching.
bg_marker_block $'VERDICT: BLOCK\r\n'"$BIG" && ok || bad "A4a: a CRLF marker line must still block"
bg_marker_block $'VER\rDICT: BLOCK'        && ok || bad "A4b: a mid-line CR must still be stripped"
bg_marker_clear $'UNBLOCK\r\n'"$BIG"       && ok || bad "A4c: a CRLF clear line must still clear"

# A5 — the control the race never touched: a marker on the LAST line of a long
# body. grep had to read to the end for this one, so there was no short-circuit
# to race. It must still match, which is how A1-A3 are shown to be about the
# transport and not about the regexes.
bg_marker_block "$BIG"$'\n'"VERDICT: BLOCK" && ok || bad "A5: a marker on the LAST line must still block"

# ══ B. the head binding — the deadlock direction of the same defect ══════════
# bg_headbound's `printf | tr 'A-Z' 'a-z' | grep -qF` is the fourth instance of
# the shape in this file. When it loses, a machine's own head-bound APPROVE
# stops clearing its own BLOCK: PR #728's 7h40m hold, re-entered by a race.
AP_HEAD12=94e6bf9147b0
AP_HEAD=94e6bf9147b01324eb199090da846eaca46293f9
# The autopilot's real footer shape (bin/review-autopilot.sh), sha upper-cased
# so the case-folding half of the predicate is exercised too.
AP_FOOTER='<!-- harness-review-autopilot 94E6BF9147B0 -->'

B1=0
for _ in $(seq 1 "$N"); do bg_headbound "$AP_FOOTER"$'\n'"$BIG" "$AP_HEAD" || B1=$((B1+1)); done
[ "$B1" = 0 ] && ok || bad "B1: bg_headbound missed the head named on line 1 of a 1MB body $B1/$N times (deadlock)"

# B2 — and the whole clear predicate on a long body: vocabulary, machine login
# and head binding together, which is what bg_scan_read actually calls.
B2=0
for _ in $(seq 1 "$N"); do
  bg_verdict_clears "$AP_FOOTER"$'\n'"$BIG"$'\n'"VERDICT: APPROVE" 'cromford[bot]' "$AP_HEAD" \
    || B2=$((B2+1))
done
[ "$B2" = 0 ] && ok || bad "B2: bg_verdict_clears failed on a 1MB head-bound machine approve $B2/$N times"

# ══ C. the production entry point: bg_scan over a real comment row ═══════════
# The same fixture shape tests/block-gate.bh-1131-test.sh uses — a fake `gh` on
# PATH answering the REST reads out of files — so this is the gate as the six
# merge lanes call it, not the predicate in isolation. Deleting the predicate's
# call site in bg_scan_read fails this case.
SLUG=o/r; PR=41
PRURL="https://github.com/$SLUG/pull/$PR"
HEAD=aaaaaaaa1111
T_HEAD_OLD=2026-09-17T18:40:00Z
T_BLOCK=2026-09-17T18:47:00Z

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api repos/$SLUG/issues/$PR/comments"*) cat "$T/prcomments" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/$PR/reviews"*)   cat "$T/reviews" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/$PR/commits"*)   cat "$T/commits" 2>/dev/null; exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
cmt() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(b64 "$5")"; }

: > "$T/reviews"
printf '%s\n' "$T_HEAD_OLD" > "$T/commits"
rm -rf "$T/h/state/block-gate"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "BLOCK — do not merge, the RLS migration is missing
$BIG" > "$T/prcomments"
CBOUT=$(bg_scan "$SLUG" "$PR" "$PRURL" "$HEAD"); CBRC=$?
[ "$CBRC" = 1 ] && grep -q 9001 <<<"$CBOUT" && grep -q reviewer-h <<<"$CBOUT" && ok \
  || bad "C1: a 1MB comment carrying a line-1 BLOCK must gate the merge (rc=$CBRC out=$CBOUT)"

# C2 — the same thread with the BLOCK line removed answers rc 0, so C1 is not
# passing because the gate refuses everything.
rm -rf "$T/h/state/block-gate"
cmt 9001 "$T_BLOCK" reviewer-h "https://x/c9001" "Looks fine to me, no findings.
$BIG" > "$T/prcomments"
CBOUT=$(bg_scan "$SLUG" "$PR" "$PRURL" "$HEAD"); CBRC=$?
[ "$CBRC" = 0 ] && ok || bad "C2: a 1MB comment with no marker must not gate (rc=$CBRC out=$CBOUT)"

# ══ N. the vocabulary did NOT change — only the transport ════════════════════

# N1 — a body with no marker still does not block, and a QUOTED block is still
# somebody repeating a block rather than posting one.
bg_marker_block "$BIG"            && bad "N1a: a body with no marker must not block" || ok
bg_marker_block "$BIG"$'\n'"> BLOCK" && bad "N1b: a quoted '> BLOCK' must not block" || ok
bg_marker_block "$BIG"$'\n'"blocked on the migration" && bad "N1c: prose must not block" || ok
bg_marker_block ""                && bad "N1d: an empty body must not block" || ok
bg_marker_block                   && bad "N1e: an absent body must not block" || ok

# N2 — a bare approve still clears nothing (BG_CLEAR_RE is untouched).
bg_marker_clear "VERDICT: APPROVE"    && bad "N2a: a terminal verdict is not a CLEAR marker" || ok
bg_marker_clear "LGTM"$'\n'"$BIG"     && bad "N2b: LGTM must not clear" || ok
bg_marker_approve "APPROVED"          && bad "N2c: a bare APPROVED is not a verdict line" || ok
bg_marker_approve "VERDICT: BLOCK"    && bad "N2d: VERDICT: BLOCK is not an approve" || ok
bg_marker_clear ""                    && bad "N2e: an empty body must not clear" || ok

# N3 — the head binding's fail-closed guards are intact: a body that does not
# name the head, an unreadable head, and a head that is not hex.
bg_headbound "$BIG" "$AP_HEAD"          && bad "N3a: a body naming no head must not bind" || ok
bg_headbound "$BIG $AP_HEAD12" ""       && bad "N3b: an empty head must fail closed" || ok
bg_headbound "$BIG $AP_HEAD12" abc      && bad "N3c: a too-short head must fail closed" || ok
bg_headbound "$BIG $AP_HEAD12" zzzzzzzzzzzz && bad "N3d: a non-hex head must fail closed" || ok

# ══ S. the shape is gone from the file ═══════════════════════════════════════
# Guarded per D3: the symbol count is asserted FIRST, so a renamed or deleted
# predicate fails here rather than making the absence check vacuously true.
S_SYM=$(grep -cE '^bg_(marker_(block|clear|approve)|headbound)\(\)' "$DIR/bin/lib/block-gate.sh")
[ "$S_SYM" = 4 ] && ok || bad "S1a: expected 4 predicate definitions, found $S_SYM"
# Comment lines are skipped: the fix's own comment QUOTES the shape it removed,
# and a check that cannot tell prose from code would force that explanation out
# of the file. `[|]` rather than `\|` — a backslash escape of an ordinary
# character is undefined in POSIX awk regex.
S_PIPE=$(awk '{ l=$0; sub(/^[ \t]+/,"",l)
                if (l ~ /^#/) next
                if ($0 ~ /printf .*[|] *tr .*[|] *grep -q/) printf "%d:%s\n", NR, $0 }' \
              "$DIR/bin/lib/block-gate.sh")
[ -z "$S_PIPE" ] && ok || bad "S1b: a live writer still feeds a short-circuiting grep -q: $S_PIPE"

echo "block-gate.bh-1290: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
