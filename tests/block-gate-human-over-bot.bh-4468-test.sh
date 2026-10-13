#!/bin/bash
# tests/block-gate-human-over-bot.bh-4468-test.sh — BH-4468: a lead/human MERGE
# (or MERGE-WITH-NOTES) verdict ROW standing on the live head lifts a MACHINE's
# comment BLOCK, and never a person's.
#
# The incident (2026-10-04, PR #4175): `cromford[bot]` BLOCKed at 12:27Z,
# newer than the head. the operator's MERGE row #576 then stood on that same head and
# `lead-verdict` went green, but bg_scan's walk still held the bot's BLOCK and
# every lane logged `MERGE_REFUSED block-gate`. The autopilot never re-reviews
# a head it already answered, so only an empty re-head commit could free it.
#
# THE NEGATIVES ARE THE POINT. Widening what clears a block is the dangerous
# direction, so beside the case that now clears sit the ones that must STILL
# block: the row on an older head, a person's BLOCK, no row at all, and a row
# whose source is not lead/human.
#
# The verdicts table is stubbed by overriding vd_standing after the lib is
# sourced: vd_block_line, vd_clears and the new lift all route through it, so
# a MERGE row here also proves step 1 (a standing BLOCK row) does not refuse.
#
# Every fixture time is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/block-gate-human-over-bot.bh-4468-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$T/h/state" "$T/h/logs" "$T/h/bin" "$T/fakebin"
SLUG=o/r; PR=41
PRURL="https://github.com/$SLUG/pull/$PR"
H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa    # the live head
H0=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb   # an older head
T_HEAD=2026-10-04T12:00:00Z
T_OLD=2026-10-04T11:00:00Z
T_BLOCK=2026-10-04T12:27:00Z
T_BLOCK2=2026-10-04T12:30:00Z
LOG="$T/h/logs/block-gate.log"
ROW_MERGE=$'MERGE\thuman\t576\t2026-10-04T19:50:00Z\t-\toperator'

# GRAPHQL IS A HARD FAILURE: any `--json`/`pr view` read exits 1. The reviews
# STATE read (`-X GET …/reviews`, bg_cr_standing) falls through to the empty
# answer — no CHANGES_REQUESTED — and the text read answers the reviews file.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"--json"*|"pr view"*|*" pr view "*|*" issue view "*) exit 1 ;;
  *"pr comment"*) exit 0 ;;
  *".[].body"*) exit 0 ;;
  *"api repos/$SLUG/issues/$PR/comments"*) cat "$T/prcomments" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/$PR/reviews"*)   cat "$T/reviews" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/$PR/commits"*)   cat "$T/commits" 2>/dev/null; exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$DIR/bin/lib/block-gate.sh" || { echo "cannot source bin/lib/block-gate.sh"; exit 1; }

# The verdicts table: a row stands on <head> iff $T/verdict-<head> exists.
# $T/verdict-fail-later makes every read AFTER the first (step 1's) fail rc 2.
vd_standing() {
  printf '%s\n' "$*" >> "$T/vd-calls.txt"
  [ -f "$T/verdict-fail-later" ] && [ "$(grep -c . "$T/vd-calls.txt")" -gt 1 ] && return 2
  [ -f "$T/verdict-${3:-}" ] || return 1
  cat "$T/verdict-${3:-}"
}

# A deliberately NOISY alerter: bg_scan's stdout is the parsed answer.
cat > "$T/h/bin/lane-alert.sh" <<'ALERT'
#!/bin/bash
echo "lane-alert stdout noise"
exit 0
ALERT
chmod +x "$T/h/bin/lane-alert.sh"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
cmt() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(b64 "$5")"; }
fresh() { # fresh [head-time]
  : > "$T/prcomments"; : > "$T/reviews"; : > "$T/gh-calls.txt"; : > "$T/vd-calls.txt"
  rm -f "$T"/verdict-* "$LOG"
  rm -rf "$T/h/state/block-gate"
  printf '%s\n' "${1:-$T_HEAD}" > "$T/commits"
}
scan() { BGOUT=$(bg_scan "$SLUG" "$PR" "$PRURL" "$H"); BGRC=$?; }
field4() { awk -F'\t' '{print $4}' <<<"$BGOUT"; }
lifted() { grep -qF "block-gate: bot BLOCK $1 lifted by human verdict #$2" "$LOG" 2>/dev/null; }
anylift() { grep -q 'lifted by human verdict' "$LOG" 2>/dev/null; }
BOT_BLOCK="VERDICT: BLOCK

- the PR body says \`Closes #4060\` but the change only covers part of it"

# 1 — the #4175 shape: bot BLOCK newer than the head, human MERGE row on it.
fresh
cmt 9001 "$T_BLOCK" 'cromford[bot]' "https://x/c9001" "$BOT_BLOCK" > "$T/prcomments"
printf '%s\n' "$ROW_MERGE" > "$T/verdict-$H"
scan
[ "$BGRC" = 0 ] && [ -z "$BGOUT" ] && ok \
  || bad "1: a human MERGE row on the live head must lift the bot's BLOCK (rc=$BGRC out=$BGOUT)"
lifted 9001 576 && ok || bad "1: the lift must be logged as 'block-gate: bot BLOCK 9001 lifted by human verdict #576' (log: $(cat "$LOG" 2>/dev/null))"

# 2 — the same, but the row stands on an OLDER head: still blocked.
fresh
cmt 9001 "$T_BLOCK" 'cromford[bot]' "https://x/c9001" "$BOT_BLOCK" > "$T/prcomments"
printf '%s\n' "$ROW_MERGE" > "$T/verdict-$H0"
scan
[ "$BGRC" = 1 ] && [ "$(field4)" = 9001 ] && ok \
  || bad "2: a MERGE row on an older head must not lift the BLOCK (rc=$BGRC out=$BGOUT)"
anylift && bad "2: nothing may be logged as lifted" || ok

# 3 — a PERSON's BLOCK plus a human MERGE row from another login: still blocked.
fresh
cmt 9002 "$T_BLOCK" someone "https://x/c9002" "BLOCK — this needs a migration" > "$T/prcomments"
printf '%s\n' "$ROW_MERGE" > "$T/verdict-$H"
scan
[ "$BGRC" = 1 ] && [ "$(field4)" = 9002 ] && [ "$(awk -F'\t' '{print $2}' <<<"$BGOUT")" = someone ] && ok \
  || bad "3: a person's BLOCK must not be lifted by a verdict row (rc=$BGRC out=$BGOUT)"
anylift && bad "3: nothing may be logged as lifted" || ok

# 4 — a bot BLOCK with no verdict row: still blocked (no regression).
fresh
cmt 9001 "$T_BLOCK" 'cromford[bot]' "https://x/c9001" "$BOT_BLOCK" > "$T/prcomments"
scan
[ "$BGRC" = 1 ] && [ "$(field4)" = 9001 ] && ok \
  || bad "4: a bot BLOCK with no row must still block (rc=$BGRC out=$BGOUT)"
anylift && bad "4: nothing may be logged as lifted" || ok

# 5 — bot and person both pending, MERGE row on the head: the person still blocks.
fresh
{ cmt 9001 "$T_BLOCK"  'cromford[bot]' "https://x/c9001" "$BOT_BLOCK"
  cmt 9002 "$T_BLOCK2" someone              "https://x/c9002" "BLOCK — not yet"; } > "$T/prcomments"
printf '%s\n' "$ROW_MERGE" > "$T/verdict-$H"
scan
[ "$BGRC" = 1 ] && [ "$(field4)" = 9002 ] && ok \
  || bad "5: the person's BLOCK must still block when the bot's is lifted (rc=$BGRC out=$BGOUT)"
lifted 9001 576 && ok || bad "5: the bot's lift must be logged (log: $(cat "$LOG" 2>/dev/null))"
# …and the person's block is the newer one here, so pin the other order too:
# a person blocking BEFORE the bot must not be hidden behind the bot's lift.
fresh
{ cmt 9002 "$T_BLOCK"  someone              "https://x/c9002" "BLOCK — not yet"
  cmt 9001 "$T_BLOCK2" 'cromford[bot]' "https://x/c9001" "$BOT_BLOCK"; } > "$T/prcomments"
printf '%s\n' "$ROW_MERGE" > "$T/verdict-$H"
scan
[ "$BGRC" = 1 ] && [ "$(field4)" = 9002 ] && ok \
  || bad "5b: with the bot newest, the answer must name the person once the bot's is lifted (rc=$BGRC out=$BGOUT)"

# 6 — the `app/<name>` spelling is a machine login too.
fresh
cmt 9001 "$T_BLOCK" 'app/cromford' "https://x/c9001" "$BOT_BLOCK" > "$T/prcomments"
printf '%s\n' "$ROW_MERGE" > "$T/verdict-$H"
scan
[ "$BGRC" = 0 ] && ok || bad "6: an app/<name> BLOCK must be lifted by a MERGE row (rc=$BGRC out=$BGOUT)"

# 7 — MERGE-WITH-NOTES from the lead lifts too.
fresh
cmt 9001 "$T_BLOCK" 'cromford[bot]' "https://x/c9001" "$BOT_BLOCK" > "$T/prcomments"
printf 'MERGE-WITH-NOTES\tlead\t577\t2026-10-04T19:50:00Z\t-\tlead\n' > "$T/verdict-$H"
scan
[ "$BGRC" = 0 ] && ok || bad "7: a lead MERGE-WITH-NOTES row must lift the bot's BLOCK (rc=$BGRC out=$BGOUT)"
lifted 9001 577 && ok || bad "7: the lift must name row #577 (log: $(cat "$LOG" 2>/dev/null))"

# 8 — a MERGE row whose source is `box` lifts nothing (only lead/human stand).
fresh
cmt 9001 "$T_BLOCK" 'cromford[bot]' "https://x/c9001" "$BOT_BLOCK" > "$T/prcomments"
printf 'MERGE\tbox\t578\t2026-10-04T19:50:00Z\t-\t-\n' > "$T/verdict-$H"
scan
[ "$BGRC" = 1 ] && [ "$(field4)" = 9001 ] && ok \
  || bad "8: a box-source MERGE row must not lift the BLOCK (rc=$BGRC out=$BGOUT)"
anylift && bad "8: nothing may be logged as lifted" || ok

# 8b — a table that becomes unreadable between step 1 and the lift lifts nothing.
fresh
cmt 9001 "$T_BLOCK" 'cromford[bot]' "https://x/c9001" "$BOT_BLOCK" > "$T/prcomments"
printf '%s\n' "$ROW_MERGE" > "$T/verdict-$H"
touch "$T/verdict-fail-later"   # step 1 reads the row; the lift's read then fails
scan
[ "$BGRC" = 1 ] && [ "$(field4)" = 9001 ] && ok \
  || bad "8b: an unreadable table at the lift must leave the BLOCK standing (rc=$BGRC out=$BGOUT)"

# 9 — a bot BLOCK OLDER than the head is never pending, so the lift spends no
# GET: the only verdicts read is step 1's.
fresh
cmt 9001 "$T_OLD" 'cromford[bot]' "https://x/c9001" "$BOT_BLOCK" > "$T/prcomments"
printf '%s\n' "$ROW_MERGE" > "$T/verdict-$H"
scan
calls=$(grep -c . "$T/vd-calls.txt")
[ "$BGRC" = 0 ] && [ "$calls" = 1 ] && ok \
  || bad "9: no pending block must mean no extra verdicts read (rc=$BGRC calls=$calls)"
# …and a pending bot block costs exactly ONE more read, however many bots.
fresh
{ cmt 9001 "$T_BLOCK"  'cromford[bot]' "https://x/c9001" "$BOT_BLOCK"
  cmt 9003 "$T_BLOCK2" 'other[bot]'         "https://x/c9003" "VERDICT: BLOCK"; } > "$T/prcomments"
printf '%s\n' "$ROW_MERGE" > "$T/verdict-$H"
scan
calls=$(grep -c . "$T/vd-calls.txt")
[ "$BGRC" = 0 ] && [ "$calls" = 2 ] && lifted 9001 576 && lifted 9003 576 && ok \
  || bad "9b: two bot blocks must both lift on one extra read (rc=$BGRC calls=$calls)"

# 10 — case 1 seven times with a noisy alerter: stdout stays empty and the
# streak file never exists (a lifted scan is rc 0, which resets it).
fresh
cmt 9001 "$T_BLOCK" 'cromford[bot]' "https://x/c9001" "$BOT_BLOCK" > "$T/prcomments"
printf '%s\n' "$ROW_MERGE" > "$T/verdict-$H"
noisy=0
for _ in 1 2 3 4 5 6 7; do
  scan
  { [ "$BGRC" = 0 ] && [ -z "$BGOUT" ]; } || noisy=1
done
[ "$noisy" = 0 ] && [ ! -e "$T/h/state/block-gate/streak/o-r-41" ] && ok \
  || bad "10: seven lifted scans must answer rc 0, empty stdout, no streak file (rc=$BGRC out=$BGOUT)"

echo "block-gate-human-over-bot.bh-4468: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
