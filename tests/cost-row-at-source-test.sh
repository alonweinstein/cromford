#!/bin/bash
# tests/cost-row-at-source-test.sh — a cost row reaches the cost_rows table at
# the moment the call is made, not up to ten minutes later when a cron tails the
# file (BH-1032, State→DB slice 7).
#
# DRIVEN, NOT GREPPED. Every claim below is about behaviour, and a grep would
# pass on a version that gets each of them wrong:
#
#   1. cost_row_emit writes the CSV FIRST and only then offers the row — the
#      write-ahead contract. The line in logs/cost.csv is byte-identical to the
#      one cost_append alone would have written, note column and all.
#   2. The offered row is PRICED and complete: cost_usd as the caller computed
#      it, the 24th column (note) carried, and `raw` the verbatim line.
#   3. ONE ROW, TWO WRITERS. The (box, row_hash) it posts is the same pair
#      bin/jobs-client.sh's _metric_cost_rows_chunk computes for that same line
#      under the same box — computed by running BOTH, never by reading either.
#      If these ever drift, one agent call becomes two rows in the ledger and
#      every fleet total is silently inflated.
#   4. The box id resolver is shared with bin/cost-rows-push.sh: state/box-id
#      wins, a bare hostname never does — with no declared identity the
#      resolver answers NOTHING and the row stays in the file (BH-1043).
#   5. FAIL OPEN. A worker that is down, a jobs-client that is missing, a body
#      that cannot be built — none of them may lose the row or fail the caller.
#   6. The kill switches (COST_ROW_AT_SOURCE=0, flags/cost-row-at-source-off)
#      turn off the POST and nothing else.
#   7. bin/agent-call.sh actually routes its row through cost_row_emit, and
#      carries the stale-library fallback every other cost helper has.
#   8. bin/cost-rows-push.sh --verify counts a modern 24-column row. Its width
#      ceiling was still `> 16`, so on today's rows it reported data_rows=0 and
#      every reconcile read as "nothing to push".
# Run from anywhere: tests/cost-row-at-source-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: this suite asserts the POST to its own stub; the sandbox flag would refuse it.
unset HARNESS_TEST_SANDBOX
# BH-3982: cost_row_emit POSTs only fleet.conf projects; ROW's project is project-2-os.
printf 'project-2-os\n' > "$T/fleet.conf"; export FLEET_CONF="$T/fleet.conf"
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/bin/lib"
export HARNESS="$T/h"
COST="$T/h/logs/cost.csv"
HDR24="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note"
echo "$HDR24" > "$COST"
echo "box-project-2" > "$T/h/state/box-id"

# The real library, sourced the way agent-call.sh sources it.
# shellcheck source=/dev/null
. "$DIR/bin/lib/cost-row.sh" || { echo "could not source bin/lib/cost-row.sh"; exit 1; }
command -v cost_row_emit >/dev/null 2>&1 \
  && ok || bad "bin/lib/cost-row.sh does not define cost_row_emit"
command -v cost_row_box_id >/dev/null 2>&1 \
  && ok || bad "bin/lib/cost-row.sh does not define cost_row_box_id"

# Stub the side channel: record method, path and the BODY FILE'S CONTENT, the
# shape _jobs_req_file really receives. Nothing here talks to a network.
SINK="$T/posts.log"
_jobs_req_file() { # <method> <path> <body-file>
  [ "${JOBS_FAIL:-0}" = 1 ] && return 1
  printf '%s %s %s\n' "$1" "$2" "$(tr -d '\n' < "$3")" >> "$SINK"
  printf '{"accepted":1,"inserted":1}\n'
  return 0
}

# A real, priced row: 24 columns, a note on the end, dollars in column 13.
ROW='2026-09-20T10:00:00Z,box1,project-2-os,execute,claude,claude-opus-5,0,61,1000,200,5000,10,4.00,subscription,fp1,client-project-2-max,sess-1,transcript,4.10,BH-1032,job-9,https://github.com/x/pull/7,build-1,cliff-routed:grok:210000>200000'

# ===========================================================================
# 1 + 2. The file is written first; the offered row is priced and complete
# ===========================================================================
: > "$SINK"
cost_row_emit "$ROW"; EMIT_RC=$?
[ "$EMIT_RC" = 0 ] && ok || bad "cost_row_emit returned $EMIT_RC — it must never fail its caller"
[ "$(tail -1 "$COST")" = "$ROW" ] \
  && ok || bad "the CSV line is not byte-identical to the row: $(tail -1 "$COST")"
[ "$(wc -l < "$COST" | tr -d ' ')" = 2 ] \
  && ok || bad "cost_row_emit wrote $(wc -l < "$COST") lines, expected header + 1"
[ "$(wc -l < "$SINK" | tr -d ' ')" = 1 ] \
  && ok || bad "expected exactly one POST, got $(wc -l < "$SINK")"
read -r M P BODY < <(head -1 "$SINK")
[ "$M" = POST ] && [ "$P" = /api/metrics/cost-rows ] \
  && ok || bad "wrong request: $M $P"
jget() { printf '%s' "$BODY" | python3 -c 'import json,sys; b=json.load(sys.stdin); r=b["rows"][0]; print(r.get(sys.argv[1], b.get(sys.argv[1], "")))' "$1"; }
[ "$(jget box)" = box-project-2 ] \
  && ok || bad "box should come from state/box-id, got '$(jget box)'"
[ "$(jget cost_usd)" = 4.00 ] \
  && ok || bad "the row must reach the DB PRICED: cost_usd='$(jget cost_usd)'"
[ "$(jget note)" = 'cliff-routed:grok:210000>200000' ] \
  && ok || bad "the 24th column (note) was dropped: '$(jget note)'"
[ "$(jget raw)" = "$ROW" ] \
  && ok || bad "raw must be the verbatim line so a reader can re-emit it unchanged: '$(jget raw)'"
[ "$(jget ticket)" = BH-1032 ] && [ "$(jget row_source)" = transcript ] \
  && ok || bad "attribution/provenance columns did not land: ticket=$(jget ticket) row_source=$(jget row_source)"
[ "$(jget line_no)" = 2 ] \
  && ok || bad "line_no should be the row's position in the file (2), got '$(jget line_no)'"

# ===========================================================================
# 3. ONE ROW, TWO WRITERS — the at-source hash IS the mirror's hash
# ===========================================================================
# Both computed by RUNNING the two producers over the same line, so a change to
# either one that breaks the pairing fails here rather than in the ledger.
( set +u
  # shellcheck source=/dev/null
  . "$DIR/bin/jobs-client.sh" >/dev/null 2>&1
  CHUNK=$(mktemp "$T/chunk.XXXXXX")
  _metric_cost_rows_chunk "$COST" 1 10 box-project-2 "$CHUNK" >/dev/null 2>&1
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rows"][0]["row_hash"])' "$CHUNK"
) > "$T/mirror.hash" 2>/dev/null
MIRROR_HASH=$(tr -d '\n ' < "$T/mirror.hash")
[ -n "$MIRROR_HASH" ] \
  && ok || bad "could not compute the mirror's row_hash — did _metric_cost_rows_chunk move?"
[ "$(jget row_hash)" = "$MIRROR_HASH" ] \
  && ok || bad "at-source hash '$(jget row_hash)' != mirror hash '$MIRROR_HASH' — one call would become two ledger rows"

# ===========================================================================
# 4. The box id resolver is SHARED with bin/cost-rows-push.sh
# ===========================================================================
[ "$(cost_row_box_id)" = box-project-2 ] \
  && ok || bad "cost_row_box_id ignored state/box-id: $(cost_row_box_id)"
grep -q 'cost_row_box_id' "$DIR/bin/cost-rows-push.sh" \
  && ok || bad "bin/cost-rows-push.sh still resolves its own box id — two resolvers double-home a row"
# WITH NO DECLARED IDENTITY THE ANSWER IS NOTHING (BH-1043, asserted here on
# the rebase onto it). This assertion used to read "cost_row_box_id must still
# answer something when state/box-id is absent" — and the something was
# `hostname -s`, which every Orgo box answers as the image default
# "orgo-desktop". `box` is half the PK of this row, so that fallback filed
# however many un-provisioned machines under one phantom box and reported
# success doing it; bin/lib/box-id.sh deleted it from the mirror lane and it
# must not survive in the at-source one. The row is HELD, not lost:
# cost_row_emit keeps the CSV line and posts nothing (§5 drives that), and the
# */10 mirror sends it the first tick after state/box-id lands.
( rm -f "$T/h/state/box-id"; unset BOX_ID COST_ROWS_BOX; B=$(cost_row_box_id); [ -z "$B" ]; ) \
  && ok || bad "cost_row_box_id guessed an identity with no \$COST_ROWS_BOX/\$BOX_ID/state/box-id — that is the orgo-desktop phantom (BH-1043)"
( rm -f "$T/h/state/box-id"; unset BOX_ID COST_ROWS_BOX; BOX_ID=pool-project-4-m42; [ "$(cost_row_box_id)" = pool-project-4-m42 ]; ) \
  && ok || bad "cost_row_box_id ignored a DECLARED \$BOX_ID — the pool path has no state/box-id and never will"
echo "box-project-2" > "$T/h/state/box-id"

# ===========================================================================
# 5. FAIL OPEN — the row survives every way the side channel can break
# ===========================================================================
: > "$SINK"; JOBS_FAIL=1
cost_row_emit "$ROW"; RC=$?
JOBS_FAIL=0
[ "$RC" = 0 ] && ok || bad "a failed POST must not fail cost_row_emit (rc $RC)"
[ "$(tail -1 "$COST")" = "$ROW" ] \
  && ok || bad "a failed POST lost the CSV row"
[ "$(wc -l < "$COST" | tr -d ' ')" = 3 ] \
  && ok || bad "the write-ahead append did not happen on the failure path"

# No client at all (a box mid-bootstrap): still a row, still rc 0, no POST.
( unset -f _jobs_req_file
  cost_row_emit "$ROW" ) ; RC=$?
[ "$RC" = 0 ] && ok || bad "a missing jobs-client must not fail cost_row_emit (rc $RC)"

# A malformed row (too few columns) is still appended, and nothing is posted:
# the ledger keeps the line, the DB is not offered a row it cannot key.
: > "$SINK"
cost_row_emit "2026-09-20T10:00:00Z,box1,project-2-os"; RC=$?
[ "$RC" = 0 ] && [ ! -s "$SINK" ] \
  && ok || bad "a short row must be appended and NOT posted (rc $RC, posts $(wc -l < "$SINK"))"
[ "$(tail -1 "$COST")" = "2026-09-20T10:00:00Z,box1,project-2-os" ] \
  && ok || bad "the short row did not reach the CSV"

# ===========================================================================
# 6. The kill switches turn off the POST and nothing else
# ===========================================================================
: > "$SINK"
( COST_ROW_AT_SOURCE=0 cost_row_emit "$ROW" )
[ ! -s "$SINK" ] && ok || bad "COST_ROW_AT_SOURCE=0 still posted"
[ "$(tail -1 "$COST")" = "$ROW" ] \
  && ok || bad "COST_ROW_AT_SOURCE=0 must still write the CSV row"
: > "$SINK"; touch "$T/h/flags/cost-row-at-source-off"
cost_row_emit "$ROW"
[ ! -s "$SINK" ] && ok || bad "flags/cost-row-at-source-off still posted"
rm -f "$T/h/flags/cost-row-at-source-off"
: > "$SINK"
cost_row_emit "$ROW"
[ -s "$SINK" ] && ok || bad "removing the flag did not re-arm the at-source write"

# ===========================================================================
# 7. bin/agent-call.sh routes its row through cost_row_emit
# ===========================================================================
grep -q '^  cost_row_emit "\$ROW"' "$DIR/bin/agent-call.sh" \
  && ok || bad "bin/agent-call.sh does not emit its row through cost_row_emit"
grep -q 'command -v cost_row_emit .*||' "$DIR/bin/agent-call.sh" \
  && ok || bad "bin/agent-call.sh has no stale-library fallback for cost_row_emit"
# The fallback must still APPEND. A box mid-sync that silently dropped the row
# would be worse than the lane this replaces.
sed -n 's/^command -v cost_row_emit[^|]*|| \(.*\)$/\1/p' "$DIR/bin/agent-call.sh" | grep -q 'cost_append' \
  && ok || bad "the cost_row_emit fallback must fall back to cost_append, not to nothing"

# ===========================================================================
# 8. cost-rows-push.sh --verify counts a modern 24-column row
# ===========================================================================
# The ceiling was `len(f) > 16: continue`, written when a row had 16 columns.
# Today every row has 24, so --verify counted ZERO data rows on every box and
# reported a reconciled ledger no matter what was owed.
VPY="$T/verify.py"
python3 - "$DIR/bin/cost-rows-push.sh" "$VPY" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
i = src.index("import csv, itertools, sys")
body = src[i:src.index("PYEOF", i)]
open(sys.argv[2], "w").write(body)
EXTRACT
[ -s "$VPY" ] && ok || bad "could not extract the --verify counter from bin/cost-rows-push.sh"
{ echo "$HDR24"; echo "$ROW"; echo "$ROW"; } > "$T/verify.csv"
VOUT=$(python3 "$VPY" "$T/verify.csv" 0 2>/dev/null)
[ "$VOUT" = "2 2" ] \
  && ok || bad "--verify must count both 24-column rows, got '$VOUT' (expected '2 2')"

echo "cost-row-at-source: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
