#!/bin/bash
# tests/cost-rows-db-test.sh — cost rows and per-PR account attribution reach
# the harness-jobs DB, and the file side stays exactly what it was.
#
# DRIVEN, NOT GREPPED. Everything here is a claim about behaviour under
# failure or under an old file shape, and a grep passes on a version that
# gets each of them wrong:
#
#   1. cost-rollup's per-PR attribution names the DOMINANT account, "unknown"
#      for rows with no label (pre-#173 13/14-column files AND short rows read
#      under an upgraded header), and a "label:usd;..." breakdown — extracted
#      from the real python block and run on fixture build dirs.
#   2. _metric_pr_costs_json carries the two new keys when the CSV has them
#      and still posts the old eight when it does not.
#   3. metric_cost_rows: a cursor that resumes, no row sent twice across two
#      runs, short rows mapped with NULL trailing fields, ≤2000 per request,
#      and a failed request that does NOT advance the cursor. curl is stubbed.
#   4. bin/cost-rows-push.sh: silent when nothing is new, one log line when
#      something moved, an ALERT on the third consecutive failure and not
#      before, the CSV byte-identical throughout.
#   5. cron enrollment: every box cron carries exactly one pusher line with
#      its own box id (or declares the absence), same shape everywhere.
# Run from anywhere: tests/cost-rows-db-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: this suite asserts the POST to its own stub; the sandbox flag would refuse it.
unset HARNESS_TEST_SANDBOX
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
# TEST-CHANGE (BH-5651): the crontabs render from this repo's registry, as a
# cache under $T/rh read in db mode (render-cron.sh takes .lane_boxes and the
# project rows from it), not from $DIR/fleet.conf. The render runs once, in a
# subshell that holds HARNESS and db mode; rendered_cron_dir reuses its files.
. "$DIR/tests/lib/registry-cache.bh-5651.sh" || exit 1
( rcache_install "$T/rh" "$DIR" && export HARNESS="$T/rh" && rendered_cron_dir >/dev/null ) \
  || { echo "FAIL: could not build this repo's registry cache or render the fleet from it"; exit 1; }
mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/bin" "$T/env" "$T/fakebin" "$T/locks" "$T/state/cost" "$T/builds"
cp "$DIR/bin/jobs-client.sh"     "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/cost-rows-push.sh"  "$T/bin/cost-rows-push.sh"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# Stub curl: records method, url and the body (which arrives as @file for the
# cost-rows route), answers per CURL_MODE. Nothing here talks to a network.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down)   exit 7 ;;
  err500) printf 'boom\n500\n'; exit 0 ;;
  # fail on the Nth request of this run (1-based), succeed otherwise
  failnth) N=$(( $(wc -l < "${REQ_SINK:-/dev/null}" 2>/dev/null || echo 0) ))
           [ "$N" = "${FAIL_AT:-2}" ] && { printf 'boom\n500\n'; exit 0; } ;;
esac
printf '{"accepted":1,"inserted":1}\n200\n'
CURL
chmod +x "$T/fakebin/curl"

HDR16="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account"

# ===========================================================================
# 1. cost-rollup: dominant account + breakdown, from the REAL python block
# ===========================================================================
python3 - "$DIR/bin/cost-rollup.sh" "$T/rollup.py" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
# Everything from the imports through the cost-per-pr.csv writer; stop before
# the PR-comment stamping (which shells out to gh).
end = body.index("# ── Final bill on the PR itself")
open(sys.argv[2], "w").write(body[:end])
EXTRACT
[ -s "$T/rollup.py" ] && grep -q 'cost-per-pr.csv' "$T/rollup.py" \
  && ok || bad "could not extract the per-PR block from cost-rollup.sh — is the marker text still right?"

mk_build() { # mk_build <dir> <pr-no> <header> <rows...>
  local d="$T/builds/$1" pr="$2" hdr="$3"; shift 3
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/x-os/pull/$pr" > "$d/RESULT"
  { echo "$hdr"; printf '%s\n' "$@"; } > "$d/cost.csv"
}
R13="2026-09-01T10:00:00Z,box,x-os,execute,claude,claude-opus-5,0,60,10,20,0,0"
# PR 1: labeled, two accounts — project-2-max carries 7.00 of 9.00, ops-hub 2.00
mk_build b1 1 "$HDR16" \
  "$R13,4.00,subscription,fp1,client-project-2-max" \
  "$R13,3.00,subscription,fp1,client-project-2-max" \
  "$R13,2.00,subscription,fp2,ops-hub"
# PR 2: a 13-column file from before billing_mode — every row "unknown"
mk_build b2 2 "${HDR16%,billing_mode,auth_fp,auth_account}" "$R13,5.00"
# PR 3: mixed widths under an upgraded header — a legacy 14-field row (no
# label) beside a labeled 16-field row; the label wins because 6.00 > 1.00,
# and the short row is counted under "unknown", not dropped.
mk_build b3 3 "$HDR16" \
  "$R13,1.00,subscription" \
  "$R13,6.00,subscription,fp2,ops-hub"
# PR 4: a tie — breaks on the label name so the file is stable run to run
mk_build b4 4 "$HDR16" \
  "$R13,2.00,subscription,fp9,zeta" \
  "$R13,2.00,subscription,fp8,alpha"
mkdir -p "$T/state/cost/remote-builds"
( cd "$T" && python3 "$T/rollup.py" "$T" "$T/state/cost" 2>"$T/rollup.err" ) \
  || bad "the extracted rollup block crashed: $(head -5 "$T/rollup.err")"
CSV="$T/state/cost/cost-per-pr.csv"
[ "$(head -1 "$CSV" | tr -d '\r')" = 'pr_url,cost_usd,input_toks,output_toks,cache_read,cache_write,stage_breakdown,build_dirs,auth_account,account_breakdown,fly_usd' ] \
  && ok || bad "cost-per-pr.csv header did not keep the two account columns after the eight originals, then fly_usd (BH-4021): $(head -1 "$CSV")"
col() { python3 -c 'import csv,sys; print(next(r[sys.argv[2]] for r in csv.DictReader(open(sys.argv[1])) if r["pr_url"].endswith("/pull/"+sys.argv[3])))' "$CSV" "$1" "$2"; }
[ "$(col auth_account 1)" = client-project-2-max ] && ok || bad "PR 1: dominant account should be client-project-2-max, got $(col auth_account 1)"
[ "$(col account_breakdown 1)" = "client-project-2-max:7.00;ops-hub:2.00" ] \
  && ok || bad "PR 1: breakdown wrong: $(col account_breakdown 1)"
[ "$(col auth_account 2)" = unknown ] && ok || bad "PR 2 (13-col file): expected unknown, got $(col auth_account 2)"
[ "$(col account_breakdown 2)" = "unknown:5.00" ] && ok || bad "PR 2: breakdown should be unknown:5.00, got $(col account_breakdown 2)"
[ "$(col auth_account 3)" = ops-hub ] && ok || bad "PR 3 (mixed widths): expected ops-hub, got $(col auth_account 3)"
[ "$(col account_breakdown 3)" = "ops-hub:6.00;unknown:1.00" ] \
  && ok || bad "PR 3: the short row must count as unknown, not vanish: $(col account_breakdown 3)"
[ "$(col auth_account 4)" = alpha ] && ok || bad "PR 4 (tie): must break on the label name, got $(col auth_account 4)"
grep -q 'mixed' "$CSV" && bad "\"mixed\" is not a value auth_account may take" || ok
# Untouched: the eight original columns still say what they said.
[ "$(col cost_usd 1)" = 9.00 ] && [ "$(col stage_breakdown 1)" = "execute:9.00" ] \
  && ok || bad "the original columns moved: cost=$(col cost_usd 1) stages=$(col stage_breakdown 1)"

# ===========================================================================
# 2. _metric_pr_costs_json: new keys when present, old eight when not
# ===========================================================================
client() { # client <verb> [args...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid REQ_SINK="$T/req.log" BOX_NAME=testbox ${EXTRA_ENV:-}
    bash "$T/bin/jobs-client.sh" "$@" >/dev/null 2>&1 )
}
rm -f "$T/req.log"
client metric-pr-costs "$CSV"
grep -q '"auth_account": "client-project-2-max"' "$T/req.log" \
  && ok || bad "the push dropped auth_account: $(head -c 300 "$T/req.log")"
grep -q '"account_breakdown": "client-project-2-max:7.00;ops-hub:2.00"' "$T/req.log" \
  && ok || bad "the push dropped account_breakdown"
cat > "$T/old.csv" <<'OLD'
pr_url,cost_usd,input_toks,output_toks,cache_read,cache_write,stage_breakdown,build_dirs
https://github.com/example-org/project-3/pull/262,136.80,232,117415,7450640,471688,execute:110.77;review:10.72,pool-project-3-TK-107
OLD
rm -f "$T/req.log"
client metric-pr-costs "$T/old.csv"
grep -q 'pull/262' "$T/req.log" && ok || bad "an old-header file no longer pushes"
grep -q 'auth_account' "$T/req.log" \
  && bad "an old-header file must not invent auth_account keys (the worker COALESCEs on absence, not on \"\")" || ok

# ===========================================================================
# 3. metric_cost_rows: cursor, idempotency, short rows, failure
# ===========================================================================
COST="$T/logs/cost.csv"; CUR="$T/state/cost-rows-push.cursor"
{ echo "$HDR16"
  echo "$R13,4.00,subscription,fp1,client-project-2-max"     # line 2, 16 cols
  echo "$R13,1.00,subscription"                        # line 3, 14 cols
  echo "$R13,0.50"                                     # line 4, 13 cols
  echo "$R13,2.00,metered,fp2,ops-hub"; } > "$COST"    # line 5
cp "$COST" "$T/cost.before"
rm -f "$T/req.log" "$CUR"
client metric-cost-rows "$COST" "$CUR" project-2
[ "$(grep -c 'POST .*/api/metrics/cost-rows' "$T/req.log" 2>/dev/null)" = 1 ] \
  && ok || bad "four rows must go in ONE request, got $(grep -c 'POST' "$T/req.log" 2>/dev/null)"
[ "$(cat "$CUR" 2>/dev/null)" = 5 ] && ok || bad "cursor should sit on the last file line (5), got '$(cat "$CUR" 2>/dev/null)'"
B=$(sed -E 's|^POST [^ ]+ ||' "$T/req.log")
[ "$(jq -r .box <<<"$B")" = project-2 ] && ok || bad "the body must carry the box: $(jq -c .box <<<"$B")"
[ "$(jq '.rows | length' <<<"$B")" = 4 ] && ok || bad "expected 4 rows in the body, got $(jq '.rows|length' <<<"$B")"
[ "$(jq -r '.rows[0].auth_account' <<<"$B")" = client-project-2-max ] \
  && ok || bad "row 1 lost its label: $(jq -c '.rows[0]' <<<"$B")"
[ "$(jq -r '.rows[0].line_no' <<<"$B")" = 2 ] && ok || bad "row 1 should be line_no 2"
# short rows: the trailing fields are JSON null, never "" and never missing
[ "$(jq -c '.rows[1] | [.billing_mode, .auth_fp, .auth_account]' <<<"$B")" = '["subscription",null,null]' ] \
  && ok || bad "14-col row must map auth_fp/auth_account to null: $(jq -c '.rows[1]' <<<"$B")"
[ "$(jq -c '.rows[2] | [.cost_usd, .billing_mode, .auth_fp, .auth_account]' <<<"$B")" = '["0.50",null,null,null]' ] \
  && ok || bad "13-col row must map the trailing three to null: $(jq -c '.rows[2]' <<<"$B")"
# row_hash is sha256 of the raw line, so the SAME row hashes the same anywhere
H2=$(sed -n 2p "$COST" | tr -d '\n' | sha256sum | cut -d' ' -f1)
[ "$(jq -r '.rows[0].row_hash' <<<"$B")" = "$H2" ] && ok || bad "row_hash is not sha256(raw line)"
# Every row carries every one of the canonical 24 names + line_no + row_hash +
# raw, whatever width the LINE was: the worker's columns are fixed, so a short
# row sends the names it lacks as null rather than omitting them. 23 + 2 = 25
# when the session + attribution columns landed (2026-09-14); 24 + 3 = 27 since
# `note` joined the list and `raw` started riding along (BH-1032, 2026-09-20);
# 25 + 3 = 28 since `lane_id` (BH-2303, 2026-09-25); 26 + 3 = 29 since `guard_fp`
# (BH-2537, 2026-09-26). TEST-CHANGE BH-2537: 25 -> 26 (was 28 keys).
#
# THE NAMES, not just the count: a count passes on a list that swapped one name
# for another, which is exactly the failure that lost `note` for three weeks.
[ "$(jq -cr '.rows[2] | keys_unsorted | sort | join(",")' <<<"$B")" = \
  "auth_account,auth_fp,billing_mode,cache_read,cache_write,cost_usd,duration_s,guard_fp,host,input_toks,job_id,lane_id,line_no,model,note,output_toks,pr,project,raw,rc,result_usd,row_hash,row_source,run_id,runner,session_id,stage,ticket,ts" ] \
  && ok || bad "a short row must still carry all 29 keys, got $(jq -c '.rows[2]|keys' <<<"$B")"
# `raw` is the VERBATIM line even for a short row — the whole point is that a
# reader can re-emit it rather than reconstruct it from typed columns.
[ "$(jq -r '.rows[2].raw' <<<"$B")" = "$(sed -n 4p "$COST")" ] \
  && ok || bad "raw must be the verbatim source line: $(jq -r '.rows[2].raw' <<<"$B")"
[ "$(jq -c '.rows[2] | [.session_id, .row_source, .ticket, .run_id]' <<<"$B")" = '[null,null,null,null]' ] \
  && ok || bad "a pre-2026-09-14 row must map the seven new names to null: $(jq -c '.rows[2]' <<<"$B")"

# --- the CURRENT 23-column width is pushed, tags and all -------------------
# Its own fixture, because it is its own regression: the chunker refused
# anything wider than sixteen (`len(f) > 16: continue`) while the cursor marched
# past it, so on the day the boxes synced every new row would have stopped
# reaching the DB — silently, with no failed request for the streak alert to
# catch. A width ceiling that does not track the canonical width is a ceiling
# that eventually drops everything.
HDR23="$HDR16,session_id,row_source,result_usd,ticket,job_id,pr,run_id"
{ echo "$HDR23"
  echo "$R13,3.00,subscription,fp3,acct-x,sess-9,transcript,2.40,TK-109,job-7,https://github.com/o/r/pull/3,build-11"
  echo "$R13,0.50"; } > "$T/wide.csv"              # a 13-col row under a 23-col header
rm -f "$T/req.log" "$T/wide.cursor"
client metric-cost-rows "$T/wide.csv" "$T/wide.cursor" project-2
BW=$(sed -E 's|^POST [^ ]+ ||' "$T/req.log")
[ "$(jq '.rows | length' <<<"$BW")" = 2 ] \
  && ok || bad "a 23-column row must be pushed, got $(jq '.rows|length' <<<"$BW") rows"
[ "$(jq -c '.rows[0] | [.row_source, .session_id, .ticket, .job_id, .pr, .run_id]' <<<"$BW")" \
    = '["transcript","sess-9","TK-109","job-7","https://github.com/o/r/pull/3","build-11"]' ] \
  && ok || bad "the provenance and tags must survive the push: $(jq -c '.rows[0]' <<<"$BW")"
[ "$(jq -r '.rows[0].result_usd' <<<"$BW")" = 2.40 ] \
  && ok || bad "result_usd must survive the push: $(jq -c '.rows[0]' <<<"$BW")"
[ "$(jq -r '.rows[0].cost_usd' <<<"$BW")" = 3.00 ] \
  && ok || bad "the first sixteen columns must still map by position: $(jq -c '.rows[0]' <<<"$BW")"
[ "$(jq -c '.rows[1] | [.billing_mode, .session_id, .run_id]' <<<"$BW")" = '[null,null,null]' ] \
  && ok || bad "a short row under a wide header maps its missing names to null: $(jq -c '.rows[1]' <<<"$BW")"
[ "$(cat "$T/wide.cursor")" = 3 ] && ok || bad "the wide-row cursor should be 3, got $(cat "$T/wide.cursor")"

# --- a second run with nothing new sends NOTHING ---------------------------
rm -f "$T/req.log"
client metric-cost-rows "$COST" "$CUR" project-2
[ ! -s "$T/req.log" ] && ok || bad "a caught-up run must not send a request (no duplicate rows): $(cat "$T/req.log")"
[ "$(cat "$CUR")" = 5 ] && ok || bad "a caught-up run moved the cursor to $(cat "$CUR")"

# --- append two rows: only the two go, cursor resumes ----------------------
echo "$R13,3.00,subscription,fp1,client-project-2-max" >> "$COST"
echo "$R13,3.50,subscription,fp1,client-project-2-max" >> "$COST"
rm -f "$T/req.log"
client metric-cost-rows "$COST" "$CUR" project-2
B=$(sed -E 's|^POST [^ ]+ ||' "$T/req.log")
[ "$(jq '.rows | length' <<<"$B")" = 2 ] && ok || bad "only the 2 appended rows should go, got $(jq '.rows|length' <<<"$B")"
[ "$(jq -r '.rows[0].line_no' <<<"$B")" = 6 ] && ok || bad "resumed push should start at line 6, got $(jq -r '.rows[0].line_no' <<<"$B")"
[ "$(cat "$CUR")" = 7 ] && ok || bad "cursor should be 7, got $(cat "$CUR")"

# --- a failed request does NOT advance the cursor --------------------------
echo "$R13,9.00,subscription,fp1,client-project-2-max" >> "$COST"
rm -f "$T/req.log"
EXTRA_ENV="CURL_MODE=err500" client metric-cost-rows "$COST" "$CUR" project-2
[ "$(cat "$CUR")" = 7 ] && ok || bad "a 500 must leave the cursor at 7, got $(cat "$CUR")"
rm -f "$T/req.log"
EXTRA_ENV="CURL_MODE=down" client metric-cost-rows "$COST" "$CUR" project-2
[ "$(cat "$CUR")" = 7 ] && ok || bad "a transport failure must leave the cursor at 7, got $(cat "$CUR")"
# ...and the next good run sends exactly that row again (idempotent by PK)
rm -f "$T/req.log"
client metric-cost-rows "$COST" "$CUR" project-2
B=$(sed -E 's|^POST [^ ]+ ||' "$T/req.log")
[ "$(jq '.rows | length' <<<"$B")" = 1 ] && [ "$(jq -r '.rows[0].cost_usd' <<<"$B")" = 9.00 ] \
  && ok || bad "the row the failed run did not land must go on the next run: $(jq -c '.rows' <<<"$B")"
[ "$(cat "$CUR")" = 8 ] && ok || bad "cursor should be 8 after the retry, got $(cat "$CUR")"

# --- chunking: 2500 rows = two requests, cursor advances between them, a
#     failure on the SECOND leaves the cursor after the first --------------
{ echo "$HDR16"; for i in $(seq 1 2500); do echo "2026-09-01T10:00:${i}Z,box,x-os,execute,claude,m,0,1,1,1,0,0,0.01,subscription,fp,acct"; done; } > "$T/big.csv"
rm -f "$T/req.log" "$T/big.cursor"
client metric-cost-rows "$T/big.csv" "$T/big.cursor" hub
[ "$(grep -c 'POST' "$T/req.log")" = 2 ] && ok || bad "2500 rows must be 2 requests, got $(grep -c POST "$T/req.log")"
[ "$(sed -n 1p "$T/req.log" | sed -E 's|^POST [^ ]+ ||' | jq '.rows|length')" = 2000 ] \
  && ok || bad "the first chunk must be exactly 2000 rows"
[ "$(cat "$T/big.cursor")" = 2501 ] && ok || bad "cursor should be 2501, got $(cat "$T/big.cursor")"
rm -f "$T/req.log" "$T/big.cursor"
EXTRA_ENV="CURL_MODE=failnth FAIL_AT=2" client metric-cost-rows "$T/big.csv" "$T/big.cursor" hub
[ "$(cat "$T/big.cursor")" = 2001 ] \
  && ok || bad "a failure on chunk 2 must leave the cursor after chunk 1 (2001), got $(cat "$T/big.cursor")"

# --- a rotated (shorter) file resets the cursor instead of waiting forever --
printf '%s\n%s,0.10,subscription,fp,acct\n' "$HDR16" "$R13" > "$T/rot.csv"
echo 999 > "$T/rot.cursor"; rm -f "$T/req.log"
client metric-cost-rows "$T/rot.csv" "$T/rot.cursor" hub
[ "$(cat "$T/rot.cursor")" = 2 ] && grep -q 'POST' "$T/req.log" \
  && ok || bad "a cursor past EOF must reset and re-offer the file (PK absorbs it), cursor=$(cat "$T/rot.cursor")"

# --- header/blank/odd lines are skipped and still advance the cursor -------
{ echo "$HDR16"; echo ""; echo "$HDR16"; echo "garbage,row"; } > "$T/odd.csv"
rm -f "$T/req.log" "$T/odd.cursor"
client metric-cost-rows "$T/odd.csv" "$T/odd.cursor" hub
[ ! -s "$T/req.log" ] && [ "$(cat "$T/odd.cursor")" = 4 ] \
  && ok || bad "skipped lines must advance the cursor (4) without a request: cursor=$(cat "$T/odd.cursor" 2>/dev/null) req=$(cat "$T/req.log" 2>/dev/null)"

# --- the CSV is byte-identical throughout ---------------------------------
head -5 "$COST" | cmp -s - "$T/cost.before" && ok || bad "the pusher modified cost.csv"

# ===========================================================================
# 4. bin/cost-rows-push.sh — the cron wrapper
# ===========================================================================
push() { # push <curl-mode> [box]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid \
           REQ_SINK="$T/req.log" CURL_MODE="$1"
    bash "$T/bin/cost-rows-push.sh" "${2:-project-2}" >/dev/null 2>&1 ); echo $?
}
rm -f "$CUR" "$T/req.log" "$T/logs/cost-rows-push.log" "$T/logs/ALERTS.log" "$T/state/cost-rows-push.fails"
RC=$(push ok)
[ "$RC" = 0 ] && ok || bad "cost-rows-push.sh exited $RC"
[ "$(grep -c '' "$T/logs/cost-rows-push.log")" = 1 ] && grep -q 'pushed 7 rows (cursor 0 -> 8' "$T/logs/cost-rows-push.log" \
  && ok || bad "one log line naming what moved, got: $(cat "$T/logs/cost-rows-push.log" 2>/dev/null)"
grep -q '^\[project-2\]\|\[project-2\]' "$T/logs/cost-rows-push.log" && ok || bad "the log line must name the box"
grep -q '"box": "project-2"' "$T/req.log" && ok || bad "the wrapper must pass its box id through: $(head -c 200 "$T/req.log")"
# HARNESS_SECRET came from global.env (cron has no env): the request was authed
grep -q 'POST' "$T/req.log" && ok || bad "the wrapper never pushed — global.env not sourced?"
# quiet tick: nothing new -> no log line, no request
rm -f "$T/req.log"; push ok >/dev/null
[ "$(grep -c '' "$T/logs/cost-rows-push.log")" = 1 ] && [ ! -s "$T/req.log" ] \
  && ok || bad "a quiet tick must be silent: $(tail -1 "$T/logs/cost-rows-push.log") / $(cat "$T/req.log" 2>/dev/null)"
# three failures -> ONE alert, on the third, not the first
echo "$R13,1.00,subscription,fp1,client-project-2-max" >> "$COST"
push err500 >/dev/null; push err500 >/dev/null
[ ! -f "$T/logs/ALERTS.log" ] && ok || bad "two failures must not alert yet: $(cat "$T/logs/ALERTS.log")"
[ "$(cat "$T/state/cost-rows-push.fails")" = 2 ] && ok || bad "the failure counter should read 2"
push err500 >/dev/null
[ "$(grep -c 'cost-rows-push: 3 consecutive failed pushes' "$T/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "the third consecutive failure must write exactly one ALERT: $(cat "$T/logs/ALERTS.log" 2>/dev/null)"
push err500 >/dev/null
[ "$(grep -c 'cost-rows-push' "$T/logs/ALERTS.log")" = 1 ] && ok || bad "a fourth failure must not alert again"
[ "$(cat "$CUR")" = 8 ] && ok || bad "failed ticks moved the cursor to $(cat "$CUR")"
# recovery clears the streak and lands the row
push ok >/dev/null
[ ! -f "$T/state/cost-rows-push.fails" ] && [ "$(cat "$CUR")" = 9 ] \
  && ok || bad "a good tick must clear the failure streak and land the row (cursor=$(cat "$CUR"))"
grep -q test-secret "$T/logs/cost-rows-push.log" "$T/logs/ALERTS.log" 2>/dev/null \
  && bad "HARNESS_SECRET leaked into a log" || ok
# no cost.csv at all: a clean, silent exit
mkdir -p "$T/empty/logs" "$T/empty/state" "$T/empty/env" "$T/empty/bin"; cp "$T/bin/"*.sh "$T/empty/bin/"
RC=$( export PATH="$T/fakebin:$PATH" HARNESS="$T/empty"; bash "$T/empty/bin/cost-rows-push.sh" hub >/dev/null 2>&1; echo $? )
[ "$RC" = 0 ] && [ ! -f "$T/empty/logs/cost-rows-push.log" ] && ok || bad "a box with no cost.csv must exit 0 silently (rc=$RC)"

# ===========================================================================
# 5. cron enrollment — one line per box, its own id, one shape
# ===========================================================================
for F in "$(rendered_cron_dir)"/*.cron; do
  N=$(grep -c 'cost-rows-push\.sh' "$F" 2>/dev/null || true)
  case "${N:-0}" in
    1) ;;
    0) grep -qi 'NO cost-rows-push line, deliberately' "$F" \
         || bad "$(basename "$F") has no cost-rows-push line and no stated reason — absence must be declared" ;;
    *) bad "$(basename "$F") has $N cost-rows-push lines, expected exactly 1" ;;
  esac
  GOT=$(grep -o 'cost-rows-push\.sh [A-Za-z0-9._-]*' "$F" | awk '{print $2}')
  [ -z "$GOT" ] || [ "$GOT" = "$(basename "$F" .cron)" ] \
    || bad "$(basename "$F") pushes as box '$GOT', expected '$(basename "$F" .cron)'"
done
ok
# every box that tracks its meter mirrors its rows too — the two per-box lanes
# name the same set, so a new box cannot get one without the other
TRACK=$(grep -l 'extra-usage-track\.sh' "$(rendered_cron_dir)"/*.cron | sort)
MIRROR=$(grep -l 'cost-rows-push\.sh' "$(rendered_cron_dir)"/*.cron | sort)
[ "$TRACK" = "$MIRROR" ] && ok || bad "boxes with a tracker line and boxes with a pusher line differ:
$(diff <(echo "$TRACK") <(echo "$MIRROR"))"
ODD=$(grep -h 'cost-rows-push\.sh' "$(rendered_cron_dir)"/*.cron \
  | grep -vE '^1,11,21,31,41,51 \* \* \* \* /root/harness/bin/cost-rows-push\.sh [A-Za-z0-9._-]+ >/dev/null 2>&1 #' || true)
[ -z "$ODD" ] && ok || bad "pusher cron line does not match the fleet-standard 10-minute shape:
$ODD"

echo "cost-rows-db-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
