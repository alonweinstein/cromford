#!/bin/bash
# tests/triage-state-pr-record.bh-3417-test.sh — BH-3420 (BH-3417.2): a
# dispatched PR shard records its verdict against its pre-dispatch hash, and
# the shadow scorecard can call a PR `would-have-missed`.
#
# Driven through the production path a shard takes (bin/lib/rt/shards.sh ->
# bin/triage-shard.sh): ts_shard_hash <key> at dispatch, then
# ts_after_session <h> <p> 0 <out> <key> <hash.nonce>, with the real
# bin/lib/triage-state.sh and bin/triage-state.py. The pre-check body that will
# write pr-decisions.tsv is not built yet, so the file is a fixture in the
# contract shape (docs/notes/2026-09-29-BH-3417-pr-triage-state.md): key,
# label=key, decision, reason, hash, seed, 1, -.
#
#   (W0) no pr-decisions.tsv: no hash, no snapshot, nothing recorded
#   (W1) the shard stamps the pre-dispatch hash after a later rewrite
#   (S1) a `comment` on a skipped PR is a miss; a `skip` is a noop
#   (S2) #N and N map to pr-N; N+1 does not (no miss, no DECISION row)
#   (D1a/D1b) the same S1 run against a copy of triage-state.py with the PR
#       mapping removed, and with dec0 forced back to "llm": no miss
#   (T1) a ticket shard's record path is unchanged (dec0 "llm": no miss)
#
# Run from anywhere: tests/triage-state-pr-record.bh-3417-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }

# ── the scratch harness ──────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin" "$H/state/triage-state/p" "$H/logs"
ln -s "$DIR/bin/lib" "$H/bin/lib"
cp "$DIR/bin/triage-state.py" "$DIR/bin/triage-signal.py" "$H/bin/"
export HARNESS="$H" PROJECT=p LOG="$T/lane.log" TRIAGE_STATE_MODE=shadow
triage_state_list() { :; }
lane_switch() { return 1; }
triage_state_put() { cp "$1" "$T/put.json"; }
# shellcheck source=bin/lib/triage-state.sh
. "$DIR/bin/lib/triage-state.sh" || exit 1

D="$H/state/triage-state/p"
echo '{"issues":[]}' > "$D/world.json"
HA=$(printf 'a%.0s' $(seq 64))
HB=$(printf 'b%.0s' $(seq 64))
HT=$(printf 'c%.0s' $(seq 64))
prline() { printf 'pr-3381\tpr-3381\tskip\tunchanged:triaged\t%s\t{}\t1\t-\n' "$1"; }

# run_shard <key> <decision line> — dispatch (ts_shard_hash) then record
# (ts_after_session), fresh log and PUT capture each time. Sets SH.
run_shard() {
  rm -f "$T/put.json"; : > "$LOG"
  SH=$(ts_shard_hash "$1")
  printf 'tickets=1\nDECISION: %s\n' "$2" > "$T/out.txt"
  ts_after_session "$H" p 0 "$T/out.txt" "$1" "$SH" >/dev/null 2>&1
}
put_key() { jq -r '.rows[]?.ticket_key' "$T/put.json" 2>/dev/null | tr '\n' ' '; }

# ═══ W0 — no pr-decisions.tsv: nothing hashed, snapshotted or recorded ══════
[ -z "$(ts_hash_of pr-3381)" ] && ok || bad "(W0) ts_hash_of pr-3381 with no pr-decisions.tsv must be empty"
[ -z "$(ts_shard_hash pr-3381)" ] && ok || bad "(W0) ts_shard_hash pr-3381 with no pr-decisions.tsv must be empty"
[ -z "$(find "$D" -path '*/snap/pr-3381.*' 2>/dev/null)" ] && ok || bad "(W0) no snapshot dir for pr-3381"
run_shard pr-3381 "pr-3381 :: comment :: asked the author a question"
[ ! -e "$T/put.json" ] && ! grep -q 'would-have-missed' "$LOG" && ok || bad "(W0) nothing recorded: $(cat "$T/put.json" 2>/dev/null) $(cat "$LOG")"

# ═══ W1 — the snapshot holds the pr line; the pre-dispatch hash is stamped ═══
prline "$HA" > "$D/pr-decisions.tsv"
[ "$(ts_hash_of pr-3381)" = "$HA" ] && ok || bad "(W1) ts_hash_of pr-3381 reads pr-decisions.tsv: [$(ts_hash_of pr-3381)]"
[ -z "$(ts_hash_of 3381)" ] && ok || bad "(W1) the bare number is not the PR's key"
rm -f "$T/put.json"; : > "$LOG"
SH=$(ts_shard_hash pr-3381)
[[ "$SH" =~ ^[0-9a-f]{64}\.[A-Za-z0-9]{6}$ ]] && [ "${SH%%.*}" = "$HA" ] && ok || bad "(W1) ts_shard_hash pr-3381 is <hash>.<nonce>: [$SH]"
SNAP="$D/snap/pr-3381.$SH"
[ "$(cat "$SNAP/decisions.tsv" 2>/dev/null)" = "$(prline "$HA")" ] && ok || bad "(W1) the snapshot's decisions.tsv holds exactly the pr line: [$(cat "$SNAP/decisions.tsv" 2>/dev/null)]"
prline "$HB" > "$D/pr-decisions.tsv"   # a later tick rewrites it while the shard runs
printf 'tickets=1\nDECISION: pr-3381 :: comment :: x\n' > "$T/out.txt"
ts_after_session "$H" p 0 "$T/out.txt" pr-3381 "$SH" >/dev/null 2>&1
[ "$(jq -r '.rows[] | select(.ticket_key=="pr-3381") | .verdict_hash' "$T/put.json" 2>/dev/null)" = "$HA" ] && ok \
  || bad "(W1) the row pr-3381 carries the PRE-dispatch hash: $(cat "$T/put.json" 2>/dev/null)"
[ ! -d "$SNAP" ] && ok || bad "(W1) the snapshot is removed once the shard recorded"
prline "$HA" > "$D/pr-decisions.tsv"

# ═══ S1 — the shadow scorecard for a PR shard ═══════════════════════════════
run_shard pr-3381 "pr-3381 :: comment :: asked the author a question"
grep -q 'triage-state shadow: would-have-missed 1: pr-3381 (comment)' "$LOG" && ok || bad "(S1) comment on a skipped PR is a miss: [$(cat "$LOG")]"
run_shard pr-3381 "pr-3381 :: skip :: x"
grep -q 'model-noop-on-skip 1: pr-3381 (skip)' "$LOG" && ! grep -q 'would-have-missed' "$LOG" && ok \
  || bad "(S1) skip on a skipped PR is a noop, not a miss: [$(cat "$LOG")]"
run_shard pr-3381 "PR-3381 :: comment :: asked the author a question"
grep -q 'would-have-missed 1: pr-3381 (comment)' "$LOG" && ok || bad "(S1) PR-3381 (upper case) maps too: [$(cat "$LOG")]"

# ═══ S2 — #N and N map to the PR; N+1 does not ═════════════════════════════
for raw in '#3381' '3381'; do
  run_shard pr-3381 "$raw :: comment :: asked the author a question"
  [ "$(put_key)" = "pr-3381 " ] && grep -q 'would-have-missed 1: pr-3381 (comment)' "$LOG" && ok \
    || bad "(S2) DECISION $raw maps to pr-3381: [$(put_key)] [$(cat "$LOG")]"
done
# 3382 is another number: no DECISION for this shard, so no miss, and the only
# row is the existing rc-0 blanket stamp of a shard key with no line (triaged),
# never one carrying the 3382 DECISION.
run_shard pr-3381 "3382 :: comment :: asked the author a question"
! grep -q 'would-have-missed' "$LOG" && ! grep -q 'DECISION comment' "$T/put.json" 2>/dev/null \
  && [ "$(jq -r '[.rows[]? | select(.ticket_key != "pr-3381" or .verdict != "triaged")] | length' "$T/put.json" 2>/dev/null || echo 0)" = 0 ] && ok \
  || bad "(S2) DECISION 3382 does not map to pr-3381: [$(cat "$T/put.json" 2>/dev/null)] [$(cat "$LOG")]"

# ═══ D1a / D1b — S1 goes red under each mutation of cmd_record ══════════════
cp "$H/bin/triage-state.py" "$T/orig.py"
sed 's/said\[a\.key\] = /_ = /' "$T/orig.py" > "$T/m1.py"
sed -E 's/^( *dec0 = ).*"llm"$/\1"llm"/' "$T/orig.py" > "$T/m2.py"
for m in m1 m2; do
  if cmp -s "$T/orig.py" "$T/$m.py"; then bad "($m) the mutation changed nothing: the guarded line is gone or renamed"; continue; fi
  cp "$T/$m.py" "$H/bin/triage-state.py"
  run_shard pr-3381 "pr-3381 :: comment :: asked the author a question"
  ! grep -q 'would-have-missed' "$LOG" && ok || bad "($m) S1's miss must not survive the mutation: [$(cat "$LOG")]"
done
cp "$T/orig.py" "$H/bin/triage-state.py"

# ═══ T1 — a ticket shard is unchanged: dec0 stays "llm", no miss ═══════════
printf '25\t25\tskip\tunchanged:triaged\t%s\t{}\t1\t-\n' "$HT" > "$D/decisions.tsv"
[ "$(ts_hash_of 25)" = "$HT" ] && ok || bad "(T1) ts_hash_of 25 reads decisions.tsv"
run_shard 25 "25 :: comment :: asked the author a question"
[ "$(put_key)" = "25 " ] && ! grep -q 'would-have-missed' "$LOG" && ok \
  || bad "(T1) a ticket shard's row is keyed 25 and logs no miss: [$(put_key)] [$(cat "$LOG")]"

echo "triage-state-pr-record: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
