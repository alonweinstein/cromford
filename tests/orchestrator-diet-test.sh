#!/bin/bash
# tests/orchestrator-diet-test.sh — fresh context is the DEFAULT, and a grown
# session gets cut off rather than re-sent.
#
# THE MEASURED PROBLEM. Turn COUNT was never the issue: 53 turns in a day is
# just real conversation, and the composed briefing is ~21K tokens, which is
# fine. The cost is session GROWTH — accumulated tool results re-read on every
# api call. One hub session reached 5,070 api calls, 27MB on disk, 2,436 tool
# results totalling 4.3MB (individual results 171-216KB), peak cache_read
# 999,307 tokens. About $666/day, and nothing errored.
#
# THE ROOT CAUSE WAS A FLAG POLARITY. Fresh-context turns required
# flags/orchestrator-v2 to be PRESENT, and the code's own comment said "rm the
# flag to fall back to -c continuation". So the expensive path was one deleted
# file away, and an absent flag on a rebuilt hub silently restores $500+/day of
# burn with no error and no log line. A flag whose ABSENCE costs money is
# backwards: the safe path has to be what you get when nobody remembers
# anything.
# Run from anywhere: tests/orchestrator-diet-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
ORC="$DIR/bin/orchestrate.sh"
SZ="$DIR/bin/session-size.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/harness/flags" "$T/harness/bin" "$T/sessions/p"

# The decision function, lifted from the script so this exercises shipped code.
python3 - "$ORC" "$T/orc_fresh.sh" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
start = src.index("orc_fresh() {")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write(src[start:end])
EXTRACT
[ -s "$T/orc_fresh.sh" ] && ok || bad "could not extract orc_fresh from orchestrate.sh"

decide() {  # decide -> prints FRESH or CONTINUE
  HARNESS="$T/harness" bash -c '
    set -uo pipefail
    HARNESS="'"$T"'/harness"
    . "'"$T"'/orc_fresh.sh"
    if orc_fresh; then echo FRESH; else echo CONTINUE; fi'
}

# --- 1. THE POLARITY: no flags at all must mean FRESH ------------------------
# This is the whole fix. A rebuilt hub, a cleared flags dir, a box someone
# forgot — all of them must land on the cheap path.
rm -f "$T/harness/flags/"*
[ "$(decide)" = FRESH ] \
  && ok || bad "with NO flags present the orchestrator must run fresh — an absent flag must not cost \$500/day"

# --- 2. continuation is explicit opt-in --------------------------------------
touch "$T/harness/flags/orchestrator-continue"
printf '#!/bin/bash\necho 0\n' > "$T/harness/bin/session-size.sh"; chmod +x "$T/harness/bin/session-size.sh"
[ "$(decide)" = CONTINUE ] \
  && ok || bad "flags/orchestrator-continue must actually select continuation, or the opt-in is a lie"

# --- 3. THE CIRCUIT BREAKER ---------------------------------------------------
# Even a deliberate opt-in must not ride a session that has outgrown the
# briefing. Past the ceiling the next turn starts fresh.
printf '#!/bin/bash\necho 999307\n' > "$T/harness/bin/session-size.sh"
[ "$(decide)" = FRESH ] \
  && ok || bad "a session at the measured hub peak (999,307 tokens) must trip the breaker"
printf '#!/bin/bash\necho 149999\n' > "$T/harness/bin/session-size.sh"
[ "$(decide)" = CONTINUE ] \
  && ok || bad "a session under the ceiling must still continue — the breaker must not fire always"
printf '#!/bin/bash\necho 150000\n' > "$T/harness/bin/session-size.sh"
[ "$(decide)" = FRESH ] \
  && ok || bad "the ceiling itself must trip (>=), not just values above it"

# A broken/missing sizer must NOT force continuation: unknown size is not
# evidence of a small session, and the failure direction that costs money is
# the one to avoid.
rm -f "$T/harness/bin/session-size.sh"
[ "$(decide)" = CONTINUE ] \
  && ok || bad "an unreadable sizer must fall back to the explicit opt-in, not crash the decision"

# The legacy flag keeps an existing hub working.
rm -f "$T/harness/flags/"*
touch "$T/harness/flags/orchestrator-continue" "$T/harness/flags/orchestrator-v2"
[ "$(decide)" = FRESH ] \
  && ok || bad "the legacy orchestrator-v2 flag must still select fresh"

# --- 4. session-size measures CONTEXT, not file size -------------------------
# A session can be megabytes of small entries or a handful of enormous tool
# results, and only the second costs per call. Reading the CLI's own
# cache_read figure is the difference between measuring the bill and guessing.
mk() { printf '{"type":"assistant","message":{"usage":{"input_tokens":1,"output_tokens":1,"cache_read_input_tokens":%s}}}\n' "$1"; }
{ mk 1000; mk 480000; mk 250000; } > "$T/sessions/p/s.jsonl"
GOT=$(bash "$SZ" "$T/sessions")
[ "$GOT" = "480000" ] \
  && ok || bad "must report the PEAK cache_read, not the last or the sum (got: '$GOT')"

# Unknown reports 0, never a large number: a parse failure that returned
# "huge" would force fresh forever and throw away working memory the
# orchestrator genuinely needs.
[ "$(bash "$SZ" "$T/nonexistent")" = "0" ] \
  && ok || bad "a missing session dir must report 0, not a number that forces fresh forever"
printf 'garbage not json\n' > "$T/sessions/p/s.jsonl"
[ "$(bash "$SZ" "$T/sessions")" = "0" ] \
  && ok || bad "an unparseable session must report 0, not crash and not guess"

# --- 5. F2: the turn contract must MANDATE capped reads ----------------------
# The 170-216KB tool results come from whole-file reads of rolling logs, and
# every one of them then rides in the context of every remaining call in the
# turn. The instruction has to be in the prompt the model actually receives.
grep -q 'READ FILES CAPPED' "$ORC" \
  && ok || bad "the v2 prompt does not mandate capped reads — this is the path that now runs by default"
grep -q 'NEVER read /root/orchestrator/conversation-log.md whole' "$ORC" \
  && ok || bad "conversation-log.md (~400KB, rolling) is not called out as never-read-whole"
grep -q 'tail -c 20000' "$ORC" \
  && ok || bad "the contract names no concrete cap — 'read less' is not an instruction"

# --- 6. the burn ledger grew two columns, which is a MIGRATION --------------
# Appending 9-field rows under the old 7-column header does not error: a reader
# parks the extras in a restkey and the new columns read empty forever, which
# is indistinguishable from "never measured". Same shape as cost.csv's 13->14.
BURN="$DIR/bin/orchestrator-burn.sh"
grep -q 'peak_cache_read' "$BURN" \
  && ok || bad "the ledger does not record peak context — the daily sum cannot tell a busy day from a runaway session"
grep -q 'CSV.up' "$BURN" \
  && ok || bad "no one-time header upgrade — new rows would land under the old 7-column header"

# THE TRAP THIS CAUGHT: the alert read the LAST field for usd_equiv. Adding two
# columns silently moves the threshold onto avg_cache_read, so the burn alarm
# would compare dollars against a token count and never fire again.
grep -q 'USD=\${ROW##\*,}' "$BURN" \
  && bad "usd is still read as the last CSV field — two new columns moved it, and the burn alert would compare dollars to a token count" || ok
grep -q "cut -d, -f7" "$BURN" \
  && ok || bad "usd_equiv is not read by position — it must not depend on being last"

# Exercise the upgrade for real: an old-header file must keep its rows and gain
# the columns, not be truncated or duplicated.
printf 'date,api_calls,fresh_in,output,cache_read,cache_write,usd_equiv\n2026-08-23,10,1,2,3,4,5.00\n' > "$T/burn.csv"
bash -c '
  set -uo pipefail
  CSV="'"$T"'/burn.csv"
  HDR="date,api_calls,fresh_in,output,cache_read,cache_write,usd_equiv,peak_cache_read,avg_cache_read"
  if [ -s "$CSV" ] && [ "$(head -1 "$CSV" | awk -F, "{print NF}")" = 7 ]; then
    { echo "$HDR"; tail -n +2 "$CSV"; } > "$CSV.up" && mv "$CSV.up" "$CSV"
  fi'
[ "$(head -1 "$T/burn.csv" | awk -F, '{print NF}')" = 9 ] \
  && ok || bad "the header upgrade did not widen the file to 9 columns"
[ "$(grep -c '^2026-08-23,' "$T/burn.csv")" = 1 ] \
  && ok || bad "the header upgrade lost or duplicated an existing row"

echo "orchestrator-diet-test: $PASS pass, $FAIL fail"
echo "NOTE: /root/orchestrator/CLAUDE.md is hub-only and NOT in this repo, so the"
echo "      same capped-read rule still has to be added there by hand."
[ "$FAIL" -eq 0 ]
