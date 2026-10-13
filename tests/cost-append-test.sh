#!/bin/bash
# tests/cost-append-test.sh — cost_append(), extracted verbatim from
# bin/lib/cost-row.sh (it lived in agent-call.sh until 2026-09-14, when
# bin/claude-cost.sh needed the SAME writer rather than a second copy of it).
#
# THE PROPERTY: a cost row is never lost. Not on lock timeout, not when flock is
# absent, not while the header is being upgraded underneath it.
#
# This test exists because the FIRST version of the lock did lose rows. It ran
# `flock -w 10 9 || exit 0`, so a timeout produced a subshell that exited
# SUCCESSFULLY having appended nothing, `&& return 0` fired, and the unlocked
# fall-through never ran. The row vanished and cost_append reported success — a
# guard written to prevent losing a cost record introducing a new way to lose
# one, silently, in the ledger whose entire job is not losing them.
#
# So every case here asks the same question: did the row actually land?
# Run from anywhere: tests/cost-append-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/locks" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> cost_append/{f=1;next} /^# <<< cost_append/{exit} f' \
  "$DIR/bin/lib/cost-row.sh" > "$T/fn.sh"
[ -s "$T/fn.sh" ] && ok || bad "could not extract cost_append — markers missing?"
grep -q 'cost_append()' "$T/fn.sh" && ok || bad "extraction did not capture the function"

HDR13="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd"
HDR14="$HDR13,billing_mode"
HDR16="$HDR14,auth_fp,auth_account"
# The 2026-09-14 generation: row provenance (which transcript priced this row)
# and the attribution tags, appended at the END so every positional reader of
# the first sixteen keeps reading the same field.
HDR23="$HDR16,session_id,row_source,result_usd,ticket,job_id,pr,run_id"
# The 2026-09-18 generation (BH-656): `note`, one trailing free-text column,
# carrying the cliff-route decision on the row the serving rung wrote.
HDR24="$HDR23,note"
# The 2026-09-25 generation (BH-2303): `lane_id`, the lane the call was spent by.
# TEST-CHANGE (BH-2303): every upgrade below now lands on HDR25 instead of HDR24.
HDR25="$HDR24,lane_id"
# The 2026-09-26 generation (BH-2537): `guard_fp`, the pre-call guard's input fingerprint.
# TEST-CHANGE BH-2537: 25 -> 26. Every upgrade below now lands on HDR26 instead of HDR25.
HDR26="$HDR25,guard_fp"

# flock_stub <exit-code> — 0 acquires, non-zero simulates a timeout
flock_stub() { printf '#!/bin/bash\nexit %s\n' "$1" > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"; }
no_flock()   { rm -f "$T/fakebin/flock"; }

# run <row> — returns rc; leaves the file at $T/cost.csv
run() {
  ( HARNESS="$T" COST="$T/cost.csv" PATH="$T/fakebin:$PATH" \
    bash -c '. "$0"; cost_append "$1"' "$T/fn.sh" "$1" >/dev/null 2>&1 )
}
rows() { local n; n=$(grep -c . "$T/cost.csv" 2>/dev/null || echo 1); echo $((n - 1)); }
fresh() { printf '%s\n' "$HDR16" > "$T/cost.csv"; }

# ---------- 1. THE BUG: a lock timeout must NOT lose the row ----------
fresh; flock_stub 1
run "ROW-A"; RC=$?
[ "$(rows)" = 1 ] && ok || bad "a lock TIMEOUT must still write the row (wrote $(rows))"
grep -q 'ROW-A' "$T/cost.csv" && ok || bad "the row content must be the one we passed"
[ "$RC" = 0 ] && ok || bad "cost_append should still report success once the row landed (rc=$RC)"

# ---------- 2. the happy path writes exactly once ----------
# The fall-through must not double-append when the locked path already wrote —
# a duplicated row inflates the ledger, which is its own wrong number.
fresh; flock_stub 0
run "ROW-B"
[ "$(rows)" = 1 ] && ok || bad "the locked path must write exactly one row (wrote $(rows))"

# NOT PROVEN HERE, stated rather than implied: cost_append distinguishes exit 75
# ("lock not acquired", fall through and write) from any other failure ("the
# locked path already ran its append, do not write twice"). Mutation-checked —
# removing that discrimination leaves this suite at 17 pass, 0 fail, because the
# only nonzero exit these fixtures can produce IS the lock timeout. Simulating a
# locked append that fails after partially writing would need a filesystem
# fault, not a stub. So the discrimination is defensive, unproven by test, and
# labelled as such instead of sitting behind a green tick that does not cover it.

# ---------- 3. no flock binary at all ----------
# The boxes have it; a host without it must still record spend.
fresh; no_flock
run "ROW-C"
[ "$(rows)" = 1 ] && ok || bad "with no flock the row must still be written (wrote $(rows))"
grep -q 'ROW-C' "$T/cost.csv" && ok || bad "the unlocked path must write the right row"

# ---------- 4. the header upgrade, under the lock ----------
fresh; flock_stub 0
printf '%s\n' "$HDR13" > "$T/cost.csv"
printf '%s\n' "old,legacy,row,x,claude,m,0,1,1,1,0,0,1.00" >> "$T/cost.csv"
run "new,row,x,y,grok,m,0,1,1,1,0,0,2.00,metered"
[ "$(head -1 "$T/cost.csv")" = "$HDR26" ] \
  && ok || bad "a 13-col header must be upgraded in place, straight to 26 (got: $(head -1 "$T/cost.csv"))"
[ "$(rows)" = 2 ] && ok || bad "the legacy row must survive the upgrade (rows=$(rows))"
grep -q 'old,legacy,row' "$T/cost.csv" && ok || bad "the pre-existing row must not be dropped"
grep -q 'metered' "$T/cost.csv" && ok || bad "the new row must be appended after the upgrade"

# Idempotent: a second call must not append the columns twice.
run "another,row,x,y,grok,m,0,1,1,1,0,0,3.00,metered"
[ "$(head -1 "$T/cost.csv")" = "$HDR26" ] \
  && ok || bad "the upgrade must be idempotent (got: $(head -1 "$T/cost.csv"))"
[ "$(rows)" = 3 ] && ok || bad "the third row must land (rows=$(rows))"

# A 14-col file (has billing_mode, predates auth_fp/auth_account) upgrades too.
printf '%s\n' "$HDR14" > "$T/cost.csv"
printf '%s\n' "old,14col,row,x,claude,m,0,1,1,1,0,0,1.00,subscription" >> "$T/cost.csv"
run "new16,row,x,y,claude,m,0,1,1,1,0,0,2.00,subscription,abc123def456,acct-x"
[ "$(head -1 "$T/cost.csv")" = "$HDR26" ] \
  && ok || bad "a 14-col header must be upgraded to 26 (got: $(head -1 "$T/cost.csv"))"
grep -q 'old,14col,row' "$T/cost.csv" && ok || bad "the 14-field legacy row must survive the upgrade"

# A 16-col file — every box in the fleet on the day this shipped — gains exactly
# the seven new names and keeps its rows. This is the generation that matters:
# if the upgrade missed it, session_id/row_source/the tags would be written into
# a file whose header does not name them, and csv.DictReader would park all
# seven in the restkey where no reader looks (the auth_account bug, again).
printf '%s\n' "$HDR16" > "$T/cost.csv"
printf '%s\n' "old,16col,row,x,claude,m,0,1,1,1,0,0,1.00,subscription,fp1,acct-x" >> "$T/cost.csv"
run "new23,row,x,y,claude,m,0,1,1,1,0,0,2.00,subscription,fp1,acct-x,sess-1,transcript,1.90,TK-9,job7,https://pr/1,build-2"
[ "$(head -1 "$T/cost.csv")" = "$HDR26" ] \
  && ok || bad "a 16-col header must be upgraded to 26 (got: $(head -1 "$T/cost.csv"))"
grep -q 'old,16col,row' "$T/cost.csv" && ok || bad "the 16-field legacy row must survive the upgrade"
grep -q 'sess-1,transcript' "$T/cost.csv" && ok || bad "the 23-field row must land after the upgrade (note reads empty)"

# A 23-col file — every box in the fleet on the day BH-656 shipped — gains
# exactly `note` and keeps its rows.
printf '%s\n' "$HDR23" > "$T/cost.csv"
printf '%s\n' "old,23col,row,x,claude,m,0,1,1,1,0,0,1.00,subscription,fp1,acct-x,sess-0,result,,,,," >> "$T/cost.csv"
run "new24,row,x,y,claude,m,0,1,1,1,0,0,2.00,subscription,fp1,acct-x,sess-1,transcript,1.90,TK-9,job7,https://pr/1,build-2,cliff-routed:grok:676000>200000"
[ "$(head -1 "$T/cost.csv")" = "$HDR26" ] \
  && ok || bad "a 23-col header must be upgraded to 26 (got: $(head -1 "$T/cost.csv"))"
grep -q 'old,23col,row' "$T/cost.csv" && ok || bad "the 23-field legacy row must survive the upgrade"
grep -q 'cliff-routed:grok:676000>200000' "$T/cost.csv" && ok || bad "the 24-field row must land after the upgrade"

# A 24-col file — every box on the day BH-2303 shipped — gains exactly
# `lane_id` and keeps its rows.
printf '%s\n' "$HDR24" > "$T/cost.csv"
printf '%s\n' "old,24col,row,x,claude,m,0,1,1,1,0,0,1.00,subscription,fp1,acct-x,sess-0,result,,,,,," >> "$T/cost.csv"
run "new25,row,x,y,claude,m,0,1,1,1,0,0,2.00,subscription,fp1,acct-x,sess-1,transcript,1.90,TK-9,job7,https://pr/1,build-2,,review-prs"
[ "$(head -1 "$T/cost.csv")" = "$HDR26" ] \
  && ok || bad "a 24-col header must be upgraded to 26 (got: $(head -1 "$T/cost.csv"))"
grep -q 'old,24col,row' "$T/cost.csv" && ok || bad "the 24-field legacy row must survive the upgrade"

# A 26-col file is left alone: the upgrade is keyed on the width it FINDS, so
# there is no seventh generation to append twice. (TEST-CHANGE BH-2537: 25 -> 26.)
run "again,row,x,y,claude,m,0,1,1,1,0,0,3.00,subscription,fp1,acct-x,sess-2,result,,,,,,,"
[ "$(head -1 "$T/cost.csv")" = "$HDR26" ] \
  && ok || bad "a 26-col header must be left untouched (got: $(head -1 "$T/cost.csv"))"

# ---------- 5. a lock timeout must not skip the row even mid-upgrade ----------
# The upgrade is skipped when the lock is unavailable — that is the accepted
# precision-not-correctness trade — but the ROW is not.
printf '%s\n' "$HDR13" > "$T/cost.csv"
flock_stub 1
run "timeout,during,upgrade,x,claude,m,0,1,1,1,0,0,9.00,metered"
[ "$(rows)" = 1 ] && ok || bad "a timeout during the upgrade window must still write (rows=$(rows))"
grep -q 'timeout,during,upgrade' "$T/cost.csv" && ok || bad "that row must be the one we passed"
# Header stays 13-col: the upgrade was skipped rather than risked. The rollup's
# restkey recovery is what keeps that row classified.
[ "$(head -1 "$T/cost.csv")" = "$HDR13" ] \
  && ok || bad "the upgrade must be SKIPPED when the lock is unavailable, not forced"

echo "cost-append-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
