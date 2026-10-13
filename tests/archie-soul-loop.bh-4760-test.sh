#!/bin/bash
# tests/archie-soul-loop.bh-4760-test.sh — BH-4766 (slice 2 of #4760): Archie's
# operating loop and owed-first turn rule in prompts/archie-soul.d/, the
# factory-watch wording in the follow-ups section, and the archie-turn replay
# skill under catalog/prompts/replays/.
#
# Every S check reads `cat prompts/archie-soul.d/*.md`, the bytes bin/archie.sh
# and bin/orchestrate.sh read. R1/R2 DRIVE bin/archie-skill-replay.sh with its
# default recorded replayer or a stub model that keeps its prompt. X1 runs the
# same checks on broken copies to prove each one can go red. Nothing here calls
# a vendor.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-soul-loop.bh-4760-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
RUNNER="$REPO/bin/archie-skill-replay.sh"
REPLAYS="$REPO/catalog/prompts/replays"
SOULD="$REPO/prompts/archie-soul.d"
TURN="$REPO/catalog/prompts/replays/archie-turn"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat "$SOULD"/*.md > "$T/soul.md"

# line_of <file> <ERE>: the first matching line number, or 0.
line_of() { local n; n=$(grep -nE "$2" "$1" | head -1 | cut -d: -f1); echo "${n:-0}"; }

# loop_checks <soulfile>: S1a-S3 on one concatenated soul. Prints one
# `FAIL: <case> ...` line per broken check and returns the number of them.
loop_checks() {
  local f="$1" n=0 rep op ini blank lp i want prev s1 tr fu w a b
  rep=$(line_of "$f" '^REPORT:'); ini=$(line_of "$f" '^Initiatives\.')
  # S1a: exactly one `Operating loop.` line, after REPORT:, before Initiatives.
  if [ "$(grep -c '^Operating loop\.' "$f")" != 1 ]; then
    echo "FAIL: S1a not exactly one Operating loop. line"; n=$((n+1)); op=0
  else
    op=$(line_of "$f" '^Operating loop\.')
    if [ "$rep" -gt 0 ] && [ "$ini" -gt 0 ] && [ "$op" -gt "$rep" ] && [ "$op" -lt "$ini" ]; then :
    else echo "FAIL: S1a Operating loop. at $op is not between REPORT: $rep and Initiatives. $ini"; n=$((n+1)); fi
  fi
  # S1b: the REPORT block ends on a blank line before the loop, and the loop
  # block ends on a blank line before Initiatives.
  blank=$(awk -v r="$rep" 'NR>r && /^$/ {print NR; exit}' "$f")
  if [ "$rep" -gt 0 ] && [ -n "$blank" ] && [ "$op" -gt 0 ] && [ "$blank" -lt "$op" ]; then :
  else echo "FAIL: S1b the REPORT block (from $rep) runs into the loop (blank=${blank:-none}, loop=$op)"; n=$((n+1)); fi
  if [ "$op" -gt 0 ]; then
    lp=$(awk -v o="$op" 'NR>o && /^$/ {print NR; exit}' "$f")
    lp=$(awk -v o="$op" -v l="${lp:-0}" 'NR>l && l>0 && /^$/ {print NR; exit}' "$f")
    if [ -n "$lp" ] && [ "$ini" -gt "$lp" ]; then :
    else echo "FAIL: S1b the loop block runs into Initiatives. (end=${lp:-none}, Initiatives.=$ini)"; n=$((n+1)); fi
  fi
  # The loop block: from Operating loop. to its first blank line.
  if [ "$op" -gt 0 ]; then sed -n "${op},\$p" "$f" | awk 'NR>1 && /^$/ {exit} {print}' > "$T/loop.blk"
  else : > "$T/loop.blk"; fi
  # S1c: steps 1..6 in order, each carrying its verb.
  prev=0; i=0
  for want in 'Sweep' 'Diagnose' 'Act inside the MAY list' 'Verify with a probe' 'Decide whether the operator hears' 'ai-build'; do
    i=$((i+1))
    s1=$(line_of "$T/loop.blk" "^$i\. ")
    if [ "$s1" -gt "$prev" ] && sed -n "${s1},\$p" "$T/loop.blk" | awk -v j=$((i+1)) 'NR>1 && $0 ~ "^"j"\\. " {exit} {print}' | grep -qF "$want"; then
      prev=$s1
    else echo "FAIL: S1c step $i missing, out of order, or without [$want]"; n=$((n+1)); fi
  done
  # S1d: step 1 sweeps owed, then stop-the-line, then stuck work, then trends.
  w=$(awk '/^1\. /{f=1} /^2\. /{exit} f' "$T/loop.blk" | tr '\n' ' ')
  prev=-1
  for want in 'owed to the operator' 'stop-the-line' 'stuck work' 'trends'; do
    a="${w%%"$want"*}"
    if [ "$a" = "$w" ]; then echo "FAIL: S1d step 1 has no [$want]"; n=$((n+1)); break; fi
    b=${#a}
    if [ "$b" -le "$prev" ]; then echo "FAIL: S1d [$want] is not after the one before it"; n=$((n+1)); break; fi
    prev=$b
  done
  # S2a: the turn rule says to lead with OWED TO OPERATOR and stop-the-line.
  tr=$(sed -n '/^Turn rule\./,/^$/p' "$f" | tr '\n' ' ')
  if [ -z "$tr" ]; then echo "FAIL: S2a no Turn rule. paragraph"; n=$((n+1))
  else
    for want in 'OWED TO OPERATOR' 'stop-the-line' 'lead' 'before you answer' 'logs/archie-fm-watch.log' 'logs/ALERTS.log'; do
      grep -qF "$want" <<<"$tr" || { echo "FAIL: S2a the turn rule has no [$want]"; n=$((n+1)); }
    done
  fi
  # S2b: no authority-gating phrase, and still exactly 3 authority headers.
  for want in 'MUST ASK' 'waits for the operator' 'asks before anything touching clients, money or production'; do
    if grep -qF "$want" "$f"; then echo "FAIL: S2b the soul carries [$want]"; n=$((n+1)); fi
  done
  [ "$(grep -c '^MAY, without asking:\|^NEVER:\|^REPORT:' "$f")" = 3 ] \
    || { echo "FAIL: S2b not exactly 3 MAY/NEVER/REPORT lines"; n=$((n+1)); }
  # S3: follow-ups name the factory-watch initiative, not the watch lane.
  fu=$(sed -n '/^Follow-ups\./,/^$/p' "$f")
  for want in '`factory-watch`' 'bin/archie-fm-watch.sh' 'not the whole-factory watch lane'; do
    grep -qF -- "$want" <<<"$fu" || { echo "FAIL: S3 the follow-ups block has no [$want]"; n=$((n+1)); }
  done
  return "$n"
}

# --- S1a..S3 on the live soul ----------------------------------------------------
if loop_checks "$T/soul.md" > "$T/live.out"; then ok
else bad "S live soul: $(cat "$T/live.out")"; fi

# --- V1 no em or en dash in the soul or the new recordings ---------------------------
RECS=("$TURN"/replays/*/recorded.txt)
if [ ! -f "${RECS[0]}" ] || [ "${#RECS[@]}" -lt 2 ]; then bad "V1 archie-turn has fewer than 2 recorded.txt"
elif grep -P '[\x{2013}\x{2014}]' "$SOULD"/*.md "${RECS[@]}"; then bad "V1 an em or en dash in the soul or a recorded.txt"
else ok; fi

# --- R1 the real runner passes both archie-turn cases ------------------------------
"$RUNNER" --root "$REPLAYS" --skill archie-turn > "$T/out" 2>"$T/err"; RC=$?
if [ "$RC" = 0 ] && grep -qx 'PASS archie-turn/01-owed-overdue-leads lead-owed' "$T/out" \
   && grep -qx 'PASS archie-turn/02-nothing-owed answer' "$T/out" \
   && tail -1 "$T/out" | grep -q ' 0 failed$'; then ok
else bad "R1 archie-turn replay: rc=$RC $(cat "$T/out" "$T/err")"; fi

# --- R2 the prompt head is the real soul plus one newline ---------------------------
mkdir -p "$T/stubs" "$T/calls"
cat > "$T/stubs/record" <<EOF
#!/bin/bash
cp "\$1" "$T/calls/\$(basename "\$2").txt"
cat "\$2/recorded.txt"
EOF
chmod +x "$T/stubs/record"
{ cat "$T/soul.md"; echo; } > "$T/head"
ARCHIE_REPLAY_MODEL_CMD="$T/stubs/record" "$RUNNER" --root "$REPLAYS" --skill archie-turn > "$T/out" 2>"$T/err"; RC=$?
[ "$RC" = 0 ] && ok || bad "R2 stubbed run rc=$RC: $(cat "$T/out" "$T/err")"
for C in 01-owed-overdue-leads 02-nothing-owed; do
  F="$T/calls/$C.txt"
  if [ -f "$F" ] && cmp -s -n "$(wc -c < "$T/head")" "$F" "$T/head" && grep -q '^Turn rule\.' "$F" \
     && grep -qx '=== CASE ===' "$F"; then ok
  else bad "R2 $C: the prompt does not start with the soul + newline, or has no Turn rule."; fi
done

# --- X1 each check can go red ----------------------------------------------------------
# a) the loop file sorted after Initiatives.
cp -r "$SOULD" "$T/x1a"
mv "$T/x1a/15-operating-loop.md" "$T/x1a/25-operating-loop.md" 2>/dev/null
cat "$T/x1a"/*.md > "$T/x1a.md"
loop_checks "$T/x1a.md" > "$T/x1a.out"
grep -q '^FAIL: S1a' "$T/x1a.out" && ok || bad "X1a a loop after Initiatives. passed S1a"
# b) the loop file lost its trailing blank line, so it runs into Initiatives.
cp -r "$SOULD" "$T/x1b"
printf '%s\n' "$(cat "$T/x1b/15-operating-loop.md")" > "$T/x1b/15-operating-loop.md"
cat "$T/x1b"/*.md > "$T/x1b.md"
loop_checks "$T/x1b.md" > "$T/x1b.out"
grep -q '^FAIL: S1b' "$T/x1b.out" && ok || bad "X1b a loop with no trailing blank line passed S1b"
# c) step 1 in the wrong order, and a step dropped.
sed -e 's/what is owed to the operator, then stop-the-line events/stop-the-line events, then what is owed to operator/' \
    -e '/^4\. /s/Verify with a probe/Check/' "$T/soul.md" > "$T/x1c.md"
loop_checks "$T/x1c.md" > "$T/x1c.out"
grep -q '^FAIL: S1d' "$T/x1c.out" && grep -q '^FAIL: S1c step 4' "$T/x1c.out" && ok \
  || bad "X1c a reordered step 1 or a dropped step passed: $(cat "$T/x1c.out")"
# d) the turn rule loses OWED TO OPERATOR, and an A6 phrase creeps in.
sed -e 's/OWED TO OPERATOR/the owed list/' -e '1a MUST ASK before anything.' "$T/soul.md" > "$T/x1d.md"
loop_checks "$T/x1d.md" > "$T/x1d.out"
grep -q '^FAIL: S2a.*OWED TO OPERATOR' "$T/x1d.out" && grep -q '^FAIL: S2b' "$T/x1d.out" && ok \
  || bad "X1d a turn rule with no OWED TO OPERATOR, or MUST ASK, passed: $(cat "$T/x1d.out")"
# e) the follow-ups block goes back to the old wording.
sed -e '/^It is not the whole-factory watch lane/d' -e 's/`factory-watch`/factory-watch/' "$T/soul.md" > "$T/x1e.md"
loop_checks "$T/x1e.md" > "$T/x1e.out"
grep -q '^FAIL: S3' "$T/x1e.out" && ok || bad "X1e the old follow-ups wording passed S3"
# f) case 01 recorded as a plain answer: the real runner FAILs it.
mkdir -p "$T/x1f-root"; cp -r "$TURN" "$T/x1f-root/" 2>/dev/null
R1F="$T/x1f-root/archie-turn/replays/01-owed-overdue-leads/recorded.txt"
if [ -f "$R1F" ]; then
  sed -i 's/^VERDICT: lead-owed$/VERDICT: answer/' "$R1F"
  "$RUNNER" --root "$T/x1f-root" --skill archie-turn > "$T/out" 2>"$T/err"; RC=$?
  [ "$RC" != 0 ] && grep -qx 'FAIL archie-turn/01-owed-overdue-leads expected=lead-owed got=answer' "$T/out" && ok \
    || bad "X1f a case 01 that answers did not FAIL: rc=$RC $(cat "$T/out")"
else bad "X1f no case 01 recorded.txt to break"; fi

echo "archie-soul-loop: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
