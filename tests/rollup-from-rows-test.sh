#!/bin/bash
# tests/rollup-from-rows-test.sh — the cost lanes read the cost_rows TABLE and
# get byte-for-byte what the ssh/scp scrape of every box's logs/cost.csv gave
# them (BH-1032, State→DB slice 7).
#
# WHY BYTE-FOR-BYTE AND NOT "about the same". bin/cost-rollup.sh writes
# state/cost/fleet-cost.csv and everything downstream — cost-per-pr.csv,
# summary.json, the dashboard, the budget breaker — is a sum over that file. A
# reader that returns the right ROWS but re-renders `4.00` as `4` produces the
# same dollars and a different file, and the next lane that diffs the two (there
# is one: bin/cost-reconcile.sh) reports drift forever. So the contract is the
# file, not the total, and the total is asserted on top of it.
#
# DRIVEN, NOT GREPPED. A fake worker answers the real GET route out of a fixture
# table; bin/lib/cost-rows-read.sh is the real library:
#
#   1. fleet-cost.csv built from the table == fleet-cost.csv built from the
#      files, byte for byte, on the same fixture.
#   2. The 24h window's dollar sum over the table equals the sum over the files.
#   3. Paging: a window wider than one page walks backwards on `until` and
#      returns every row exactly once (the inclusive bound may not double-count
#      rows sharing a second, and may not drop them either).
#   4. FAIL OPEN: an unreachable worker answers rc 1, writes NO half file, and
#      leaves one line in logs/agent-rules.log — never an empty window that
#      reads as a fleet that spent nothing.
#   5. A row pushed before `raw` existed is RECONSTRUCTED, not dropped.
#   6. bin/cost-rollup.sh actually uses the reader, has NO ssh collection behind
#      it (BH-2527), and names an unreadable table instead.
#   7. COST_ROWS_READ_LIMIT above the route's 2000 ceiling is CLAMPED — asking
#      for more and calling the clamped page "short" reports a fraction of the
#      window as the whole of it.
#   8. The skip set: a row the caller already holds verbatim from a file is not
#      re-emitted, and <out>.boxes still counts it.
#   9. `raw` is re-emitted only when it hashes to its own row_hash (the column
#      is capped at 4096 bytes and a truncated line still parses).
#  10. bin/cost-rollup.sh's union block is EXTRACTED AND RUN — table rows and
#      file rows merged, each call landing exactly once, and with the table
#      down (BH-2527) nothing rewritten, one ALERT a day, no box reached.
#      Grepping a script for the strings it contains is what let the double
#      count ship green.
#  11. The rollup names the boxes cost_rows is NOT hearing from: a log line for
#      a box quiet today, one alert a day for a box absent from the whole window.
# Run from anywhere: tests/rollup-from-rows-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/bin/lib"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/h/bin/"
export HARNESS="$T/h"
HDR24="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note"

# ── The fixture: what the boxes' files hold ─────────────────────────────────
# Deliberately includes `4.00` and `0.50` — trailing-zero dollars are exactly
# what a float round-trip destroys — a duplicate line (two boxes carrying the
# same row, which `sort -u` collapses), and one row with an empty note.
mk() { printf '%s,box%s,%s,%s,claude,claude-opus-5,0,61,1000,200,5000,10,%s,subscription,fp1,acct-a,s%s,transcript,%s,BH-1,job-1,,build-1,%s\n' "$1" "$2" "$3" "$4" "$5" "$2" "$5" "${6:-}"; }
FILE_ROWS="$T/file-rows.csv"
{
  mk 2026-09-20T10:00:00Z 1 project-2-os execute 4.00 ''
  mk 2026-09-20T10:05:00Z 1 project-2-os review  0.50 'cliff-routed:grok:210000>200000'
  mk 2026-09-20T11:00:00Z 2 project-3 execute 12.25 ''
  mk 2026-09-20T11:00:00Z 2 project-3 execute 12.25 ''
  mk 2026-09-19T23:59:00Z 3 project-4 plan 1.00 ''
} > "$FILE_ROWS"

# What today's ssh/scp path produces: the canonical header, then every box's
# data rows, sort -u'd. This literal IS bin/cost-rollup.sh section 1.
FLEET_FILES="$T/fleet-from-files.csv"
# The header bin/cost-rollup.sh writes on fleet-cost.csv — 26 names since
# BH-2537 (guard_fp). TEST-CHANGE BH-2537: 25 -> 26 (was "$HDR24,lane_id").
{ echo "$HDR24,lane_id,guard_fp"; sort -u "$FILE_ROWS"; } > "$FLEET_FILES"

# ── The fake worker: the real GET route's contract, out of the same rows ────
# limit / since / until / box are honoured exactly as worker/jobs/src/index.js
# does: newest first, `until` INCLUSIVE, `since` inclusive.
cat > "$T/fakedb.py" <<'PYEOF'
import csv, hashlib, json, os, sys, urllib.parse
COLS = ["ts", "host", "project", "stage", "runner", "model", "rc", "duration_s",
        "input_toks", "output_toks", "cache_read", "cache_write", "cost_usd",
        "billing_mode", "auth_fp", "auth_account", "session_id", "row_source",
        "result_usd", "ticket", "job_id", "pr", "run_id", "note"]
rows_file, q = sys.argv[1], sys.argv[2]
want_raw = os.environ.get("FAKEDB_NO_RAW") != "1"
# FAKEDB_BAD_RAW: the 4096-byte `raw` cap firing — the column comes back SHORT
# and still parses, which is why the reader has to verify it against row_hash
# instead of trusting it.
bad_raw = os.environ.get("FAKEDB_BAD_RAW") == "1"
# FAKEDB_BOX_IS_HOST: the fixture names the box in its own host column, so a
# test can put two named boxes in one table.
box_is_host = os.environ.get("FAKEDB_BOX_IS_HOST") == "1"
qs = urllib.parse.parse_qs(urllib.parse.urlparse(q).query)
one = lambda k: (qs.get(k) or [""])[0]
# THE ROUTE'S OWN CLAMP, not the caller's number: worker/jobs/src/index.js does
# Math.min(Math.max(limit, 1), 2000). A fake that honours a larger limit hides
# the exact bug this clamp exists for — a reader that asks for 5000, gets 2000,
# and calls a full page "short", i.e. reports a fraction of the window as whole.
limit = min(max(int(one("limit") or 200), 1), 2000)
out = []
seen = set()
with open(rows_file, newline="") as fh:
    for line in fh:
        raw = line.rstrip("\r\n")
        if not raw.strip():
            continue
        f = next(csv.reader([raw]))
        f = (f + [None] * len(COLS))[:len(COLS)]
        r = dict(zip(COLS, f))
        # The table's own PK: byte-identical lines are ONE row, exactly as the
        # worker's ON CONFLICT(box, row_hash) makes them.
        h = hashlib.sha256(raw.encode()).hexdigest()
        box = (r["host"] or "") if box_is_host else "box" + (r["host"] or "")[3:]
        if (box, h) in seen:
            continue
        seen.add((box, h))
        # Numbers come back as NUMBERS, the way D1 stores and JSON renders them
        # — which is precisely why `raw` has to exist.
        for k in ("rc", "input_toks", "output_toks", "cache_read", "cache_write"):
            r[k] = int(r[k]) if r[k] not in (None, "") else None
        for k in ("duration_s", "cost_usd", "result_usd"):
            r[k] = float(r[k]) if r[k] not in (None, "") else None
        r["box"], r["row_hash"] = box, h
        if want_raw:
            r["raw"] = raw[:20] if bad_raw else raw
        out.append(r)
if one("box"):
    out = [r for r in out if r["box"] == one("box")]
if one("since"):
    out = [r for r in out if (r["ts"] or "") >= one("since")]
if one("until"):
    out = [r for r in out if (r["ts"] or "") <= one("until")]
out.sort(key=lambda r: r["ts"] or "", reverse=True)
print(json.dumps({"cost_rows": out[:limit], "as_of": "t"}))
PYEOF

_jobs_req() { # <method> <path>
  [ "${DB_DOWN:-0}" = 1 ] && return 1
  python3 "$T/fakedb.py" "$FILE_ROWS" "$2"
}
export -f _jobs_req 2>/dev/null || true

# shellcheck source=/dev/null
. "$DIR/bin/lib/cost-rows-read.sh" || { echo "could not source bin/lib/cost-rows-read.sh"; exit 1; }
command -v cost_rows_fetch >/dev/null 2>&1 \
  && ok || bad "bin/lib/cost-rows-read.sh does not define cost_rows_fetch"
command -v cost_rows_db_enabled >/dev/null 2>&1 \
  && ok || bad "bin/lib/cost-rows-read.sh does not define cost_rows_db_enabled"

# ===========================================================================
# 1. Byte-for-byte with the file path
# ===========================================================================
FLEET_DB="$T/fleet-from-db.csv"
cost_rows_fetch "$FLEET_DB" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "cost_rows_fetch returned $RC on a healthy worker"
if cmp -s "$FLEET_DB" "$FLEET_FILES"; then ok; else
  bad "fleet-cost.csv from the table differs from the file path:"; diff "$FLEET_FILES" "$FLEET_DB" | head -8
fi
# The duplicate line collapsed exactly once, as `sort -u` does.
[ "$(grep -c 'project-3' "$FLEET_DB")" = 1 ] \
  && ok || bad "the duplicate row was not collapsed to one: $(grep -c 'project-3' "$FLEET_DB")"

# ===========================================================================
# 2. The window sum over the table equals the sum over the files
# ===========================================================================
winsum() { python3 -c '
import csv, sys
since = sys.argv[2]
print("%.4f" % sum(float(r["cost_usd"] or 0) for r in csv.DictReader(open(sys.argv[1])) if (r["ts"] or "") >= since))' "$1" "$2"; }
S_FILES=$(winsum "$FLEET_FILES" 2026-09-20T00:00:00Z)
S_DB=$(winsum "$FLEET_DB" 2026-09-20T00:00:00Z)
[ "$S_FILES" = "$S_DB" ] \
  && ok || bad "24h window sum: files=$S_FILES table=$S_DB"
[ "$S_DB" = 16.7500 ] \
  && ok || bad "the window sum itself is wrong: $S_DB (expected 16.7500 — 4.00+0.50+12.25, the dup counted once)"

# ===========================================================================
# 3. Paging — a window wider than one page walks backwards on `until`
# ===========================================================================
PAGED="$T/paged.csv"
( COST_ROWS_READ_LIMIT=2 cost_rows_fetch "$PAGED" >/dev/null 2>&1 ) ; RC=$?
[ "$RC" = 0 ] && ok || bad "paged fetch returned $RC"
if cmp -s "$PAGED" "$FLEET_FILES"; then ok; else
  bad "a 2-row page size did not reproduce the whole window:"; diff "$FLEET_FILES" "$PAGED" | head -8
fi
# The two rows sharing 11:00:00Z are the inclusive-bound trap: they must not be
# dropped by an exclusive walk nor doubled by an inclusive one.
[ "$(tail -n +2 "$PAGED" | wc -l | tr -d ' ')" = 4 ] \
  && ok || bad "paged fetch returned $(tail -n +2 "$PAGED" | wc -l) data rows, expected 4"

# The page ceiling refuses rather than reports a short window.
( COST_ROWS_READ_LIMIT=1 COST_ROWS_READ_PAGES=2 cost_rows_fetch "$T/short.csv" >/dev/null 2>&1 ) ; RC=$?
[ "$RC" = 1 ] && ok || bad "hitting the page ceiling must fail open (rc $RC), never return a short window"
grep -q 'page ceiling' "$T/h/logs/agent-rules.log" \
  && ok || bad "the page ceiling did not log why it stopped"

# ===========================================================================
# 4. FAIL OPEN — an unreachable worker is never an empty window
# ===========================================================================
: > "$T/h/logs/agent-rules.log"
rm -f "$T/down.csv"
( DB_DOWN=1 cost_rows_fetch "$T/down.csv" >/dev/null 2>&1 ) ; RC=$?
[ "$RC" = 1 ] && ok || bad "an unreachable worker must return rc 1, got $RC"
[ ! -e "$T/down.csv" ] \
  && ok || bad "a failed fetch wrote a file — a half window that looks whole is the bug this exists to prevent"
grep -q 'cost-rows-read' "$T/h/logs/agent-rules.log" \
  && ok || bad "a failed fetch must leave one line in logs/agent-rules.log"
# An existing file is left ALONE, not truncated: the caller's fallback may be
# about to write it.
cp "$FLEET_FILES" "$T/keep.csv"
( DB_DOWN=1 cost_rows_fetch "$T/keep.csv" >/dev/null 2>&1 )
cmp -s "$T/keep.csv" "$FLEET_FILES" \
  && ok || bad "a failed fetch clobbered the caller's existing file"
# A body that is not the route's shape is a FAILED read, never an empty one.
_jobs_req() { printf '{"error":"boom"}\n'; }
( cost_rows_fetch "$T/bad.csv" >/dev/null 2>&1 ) ; RC=$?
[ "$RC" = 1 ] && ok || bad "an unparseable body must be a failed read (rc $RC), not an empty window"
_jobs_req() { [ "${DB_DOWN:-0}" = 1 ] && return 1; python3 "$T/fakedb.py" "$FILE_ROWS" "$2"; }

# ===========================================================================
# 5. Rows from before `raw` existed are reconstructed, not dropped
# ===========================================================================
LEGACY="$T/legacy.csv"
( FAKEDB_NO_RAW=1 cost_rows_fetch "$LEGACY" >/dev/null 2>&1 ) ; RC=$?
[ "$RC" = 0 ] && ok || bad "a table with no raw column must still answer (rc $RC)"
[ "$(tail -n +2 "$LEGACY" | wc -l | tr -d ' ')" = 4 ] \
  && ok || bad "reconstruction dropped rows: $(tail -n +2 "$LEGACY" | wc -l) of 4"
L_SUM=$(winsum "$LEGACY" 2026-09-20T00:00:00Z)
[ "$L_SUM" = "$S_FILES" ] \
  && ok || bad "reconstructed rows priced differently: $L_SUM vs $S_FILES"
grep -q 'cliff-routed' "$LEGACY" \
  && ok || bad "reconstruction lost the note column"

# ===========================================================================
# 6. The kill switch, and the lanes that read through this library
# ===========================================================================
cost_rows_db_enabled && ok || bad "cost_rows_db_enabled should be on by default"
( COST_ROWS_FROM_DB=0; cost_rows_db_enabled ) \
  && bad "COST_ROWS_FROM_DB=0 did not disarm the DB read" || ok
touch "$T/h/flags/cost-rows-from-db-off"
cost_rows_db_enabled && bad "flags/cost-rows-from-db-off did not disarm the DB read" || ok
rm -f "$T/h/flags/cost-rows-from-db-off"

grep -q 'cost-rows-read.sh' "$DIR/bin/cost-rollup.sh" \
  && ok || bad "bin/cost-rollup.sh does not source the cost_rows reader"
grep -q 'cost_rows_fetch' "$DIR/bin/cost-rollup.sh" \
  && ok || bad "bin/cost-rollup.sh does not read the table"
# BH-2527 inverted this: the ssh fallback is GONE, and an unreadable table is
# named rather than papered over (section 10 runs that path). The rollup must
# still log which path it took, so an hour where the table was unreadable is
# legible after the fact rather than looking like an hour the fleet was cheap.
grep -q 'ssh -o BatchMode=yes' "$DIR/bin/cost-rollup.sh" \
  && bad "bin/cost-rollup.sh still reaches boxes over ssh (BH-2527 removed that path)" || ok
grep -q 'cost_rows was unreadable or disarmed' "$DIR/bin/cost-rollup.sh" \
  && ok || bad "bin/cost-rollup.sh does not say when the table was unreadable"

# ===========================================================================
# 7. COST_ROWS_READ_LIMIT above the route's ceiling is CLAMPED, not trusted
# ===========================================================================
# The route answers Math.min(limit, 2000). A reader that asks for 5000, gets a
# full 2000-row page and then decides `got < lim` means "that was the last page"
# stops after one page and returns rc 0 on a fraction of the window — the half
# window that looks whole, which is the failure the paging exists to prevent.
BIG="$T/big-rows.csv"
python3 - "$BIG" <<'PYBIG'
import sys
with open(sys.argv[1], "w") as fh:
    for i in range(2001):
        # Descending minutes so every row has its own ts and the walk has to
        # page; 2001 rows means one full page plus one.
        fh.write("2026-09-01T%02d:%02d:00Z,box9,p,execute,claude,claude-opus-5,0,1,1,1,1,1,"
                 "0.010000,subscription,fp1,acct-a,s%d,transcript,,BH-9,job-9,,run-9,\n"
                 % (i // 60, i % 60, i))
PYBIG
_jobs_req() { python3 "$T/fakedb.py" "$BIG" "$2"; }
( COST_ROWS_READ_LIMIT=5000 cost_rows_fetch "$T/big.csv" >/dev/null 2>&1 ) ; RC=$?
[ "$RC" = 0 ] && ok || bad "a clamped-limit fetch returned $RC"
BIGN=$(tail -n +2 "$T/big.csv" | wc -l | tr -d ' ')
[ "$BIGN" = 2001 ] \
  && ok || bad "COST_ROWS_READ_LIMIT=5000 returned $BIGN of 2001 rows — the route clamps to 2000, so a full page read as the last one"
_jobs_req() { [ "${DB_DOWN:-0}" = 1 ] && return 1; python3 "$T/fakedb.py" "$FILE_ROWS" "$2"; }

# ===========================================================================
# 8. The skip set — a line the caller already holds from a FILE is not re-emitted
# ===========================================================================
# THE DOUBLE COUNT THIS EXISTS TO STOP. A caller that merges the table with its
# own files can only collapse the two copies with `sort -u`, i.e. on identical
# TEXT — and a row that predates `raw` comes back reconstructed, so `4.00`
# arrives as `4` and `sort -u` keeps both. The hash is the table's own PK half.
SKIPF="$T/skip-hashes"
head -1 "$FILE_ROWS" | python3 -c '
import hashlib, sys
print(hashlib.sha256(sys.stdin.readline().rstrip("\r\n").encode("utf-8", "replace")).hexdigest())' > "$SKIPF"
( COST_ROWS_SKIP_HASHES="$SKIPF" FAKEDB_NO_RAW=1 cost_rows_fetch "$T/skipped.csv" >/dev/null 2>&1 ) ; RC=$?
[ "$RC" = 0 ] && ok || bad "a fetch with a skip set returned $RC"
[ "$(tail -n +2 "$T/skipped.csv" | wc -l | tr -d ' ')" = 3 ] \
  && ok || bad "the skip set did not drop exactly one row: $(tail -n +2 "$T/skipped.csv" | wc -l) of 4 remain"
grep -q '10:00:00Z' "$T/skipped.csv" \
  && bad "the skipped row was emitted anyway — a caller merging this with its files counts that call twice" || ok
grep -q '11:00:00Z' "$T/skipped.csv" \
  && ok || bad "the skip set dropped a row the caller does NOT hold"
# An unreadable skip set skips NOTHING: a duplicate the caller can see beats a
# row silently dropped.
( COST_ROWS_SKIP_HASHES="$T/does-not-exist" cost_rows_fetch "$T/noskip.csv" >/dev/null 2>&1 )
[ "$(tail -n +2 "$T/noskip.csv" | wc -l | tr -d ' ')" = 4 ] \
  && ok || bad "an unreadable skip set changed the window"
# <out>.boxes: who the table is hearing from, SKIPPED ROWS INCLUDED — presence
# is a fact about the table, not about what this caller happened to need.
[ -s "$T/skipped.csv.boxes" ] \
  && ok || bad "cost_rows_fetch did not write <out>.boxes"
BSUM=$(awk -F'\t' '{n+=$2} END{print n+0}' "$T/skipped.csv.boxes")
[ "$BSUM" = 4 ] \
  && ok || bad "<out>.boxes tallied $BSUM rows, expected 4 (the skipped row counts: it IS in the table)"
awk -F'\t' '$1=="box1"{print $3}' "$T/skipped.csv.boxes" | grep -q '2026-09-20T10:05:00Z' \
  && ok || bad "<out>.boxes did not carry box1's latest ts"

# ===========================================================================
# 9. `raw` is trusted only where it PROVES it is whole
# ===========================================================================
# The column is capped at 4096 bytes and a truncated line still parses, so a
# blind re-emit ships a short row that every downstream reader accepts.
( FAKEDB_BAD_RAW=1 cost_rows_fetch "$T/trunc.csv" >/dev/null 2>&1 ) ; RC=$?
[ "$RC" = 0 ] && ok || bad "a table with a truncated raw must still answer (rc $RC)"
[ "$(tail -n +2 "$T/trunc.csv" | wc -l | tr -d ' ')" = 4 ] \
  && ok || bad "a truncated raw dropped rows: $(tail -n +2 "$T/trunc.csv" | wc -l) of 4"
# Reconstruction, not the 20-byte stub: every line still carries all 24 columns
# and the window still prices the same. (It is NOT byte-equal to the file — a
# reconstructed 4.00 renders 4; that is section 5's stated degradation, and it
# is strictly better than a SHORT line that parses.)
SHORTEST=$(tail -n +2 "$T/trunc.csv" | awk -F, '{print NF}' | sort -n | head -1)
[ "$SHORTEST" = 24 ] \
  && ok || bad "a raw that does not hash to its own row_hash was re-emitted anyway: narrowest row is $SHORTEST columns, not 24"
T_SUM=$(winsum "$T/trunc.csv" 2026-09-20T00:00:00Z)
[ "$T_SUM" = "$S_FILES" ] \
  && ok || bad "the reconstructed window priced differently: $T_SUM vs $S_FILES"

# ===========================================================================
# 10. bin/cost-rollup.sh's OWN union block, RUN (not grepped)
# ===========================================================================
# Section 6 above proves the script CONTAINS four strings. It does not prove the
# file it writes is right, and the double count this section pins was green
# under exactly that kind of assertion: the rollup merged hub.csv, the build
# ledgers and the DB rows under one `sort -u`, so every row the table held
# without `raw` (all of them until this slice) landed TWICE in fleet-cost.csv.
awk '/^# >>> fleet row union/{f=1;next} /^# <<< fleet row union/{exit} f' \
  "$DIR/bin/cost-rollup.sh" > "$T/union.sh"
[ -s "$T/union.sh" ] \
  && ok || bad "bin/cost-rollup.sh carries no extractable '# >>> fleet row union' block"

UH="$T/u/h"
mkdir -p "$UH/logs" "$UH/state/cost" "$UH/bin/lib" "$UH/builds/b1" "$T/u/bin"
cp "$DIR/bin/lib/cost-rows-read.sh" "$UH/bin/lib/cost-rows-read.sh"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$UH/bin/"
# A fake ssh on PATH, so the block's own collection loops run as written.
cat > "$T/u/bin/ssh" <<'SSHEOF'
#!/bin/bash
case "$*" in
  *"cat /root/harness/logs/cost.csv"*) cat "${FAKE_BOX_CSV:-/dev/null}" 2>/dev/null ;;
  *) : ;;
esac
exit 0
SSHEOF
chmod +x "$T/u/bin/ssh"

# The fixture is dated NOW, because the block's window is "31 days ago" and a
# fixture with a frozen date would quietly fall out of it and stop proving
# anything the day this test is a month old.
UNOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
umk() { printf '%s,%s,%s,execute,claude,claude-opus-5,0,61,1000,200,5000,10,%s,subscription,fp1,acct-a,s1,transcript,,BH-7,job-7,,run-7,\n' "$UNOW" "$1" "$2" "$3"; }
# Trailing-zero and sub-1e-4 dollars: exactly what a REAL/float round-trip
# re-renders (1.250000 -> 1.25, 0.000010 -> 1e-05), i.e. the lines `sort -u`
# cannot collapse.
# WITH THE HEADER, like every real one: logs/cost.csv and each build ledger
# carry it, and the union block strips it (`tail -n +2`, `grep -v "^ts,host"`).
# A headerless fixture would have its first ROW eaten and the block would look
# like it was dropping data.
{ echo "$HDR24"
  umk hub hub-os 1.250000
  umk hub hub-os 0.400000
} > "$UH/logs/cost.csv"
{ echo "$HDR24"; umk hub hub-os 12.500000; } > "$UH/builds/b1/cost.csv"
# The table holds those three (pushed by the */10 mirror, pre-`raw`) plus one
# row no file on this box carries — a pool machine reaped after it died.
{ grep -hv '^ts,host' "$UH/logs/cost.csv" "$UH/builds/b1/cost.csv"
  umk pool-x pool-os 0.000010
} > "$T/u/db-rows.csv"
FLEET="$UH/state/cost/fleet-cost.csv"

(
  export HARNESS="$UH"; H="$UH"; CD="$UH/state/cost"
  PATH="$T/u/bin:$PATH"; export PATH
  STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
  BOXPROJ="project-4:project-4"
  box_ip() { echo "10.9.9.9"; }
  FAKE_BOX_CSV=/dev/null; export FAKE_BOX_CSV
  _jobs_req() { FAKEDB_NO_RAW=1 FAKEDB_BOX_IS_HOST=1 python3 "$T/fakedb.py" "$T/u/db-rows.csv" "$2"; }
  # shellcheck source=/dev/null
  . "$T/union.sh"
) >/dev/null 2>&1
UN=$(tail -n +2 "$FLEET" | wc -l | tr -d ' ')
[ "$UN" = 4 ] \
  && ok || bad "fleet-cost.csv carries $UN data rows, expected 4 — the file rows and their table copies were counted twice"
[ "$(grep -c ',1.250000,' "$FLEET")" = 1 ] \
  && ok || bad "the 1.250000 row appears $(grep -c ',1.250000,' "$FLEET") times"
grep -q ',1.25,' "$FLEET" \
  && bad "the reconstructed copy (1.25) landed beside the file's own 1.250000 — one call, two rows, every sum over this file high" || ok
grep -q ',12.500000,' "$FLEET" \
  && ok || bad "the build ledger's row is missing from fleet-cost.csv"
grep -q 'pool-x' "$FLEET" \
  && ok || bad "the row only the TABLE carried (a dead pool machine) was dropped — the skip set must not drop rows the files do not hold"
USUM=$(python3 -c '
import csv, sys
print("%.6f" % sum(float(r["cost_usd"] or 0) for r in csv.DictReader(open(sys.argv[1]))))' "$FLEET")
[ "$USUM" = 14.150010 ] \
  && ok || bad "fleet-cost.csv sums to $USUM, expected 14.150010 (1.25+0.40+12.50+0.00001, each counted once)"
[ -s "$UH/state/cost/cost-rows-boxes.tsv" ] \
  && ok || bad "the union block did not keep the per-box presence table"
grep -q 'no ssh' "$UH/logs/agent-rules.log" \
  && ok || bad "the union block did not log that it read the table"

# The SAME block with the table down (BH-2527): no box is reached, the last
# good fleet-cost.csv and presence table are left exactly as they were, and
# one ALERT a day names the outage. A file rebuilt from the hub alone would be
# a smaller fleet that reads as a cheaper one.
: > "$UH/logs/agent-rules.log"
cp "$FLEET" "$T/u/fleet.before"
cp "$UH/state/cost/cost-rows-boxes.tsv" "$T/u/boxes.before"
cat > "$T/u/bin/ssh" <<SSHEOF
#!/bin/bash
echo "\$*" >> "$T/u/ssh.log"
exit 0
SSHEOF
chmod +x "$T/u/bin/ssh"
down_union() {
  (
    export HARNESS="$UH"; H="$UH"; CD="$UH/state/cost"
    PATH="$T/u/bin:$PATH"; export PATH
    STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
    BOXPROJ="project-4:project-4"
    _jobs_req() { return 1; }
    # shellcheck source=/dev/null
    . "$T/union.sh"
    echo "past the union" > "$T/u/past"
  ) >/dev/null 2>&1
}
down_union
grep -q 'cost_rows was unreadable or disarmed' "$UH/logs/agent-rules.log" \
  && ok || bad "the union block did not log that the table was unreadable"
[ ! -e "$T/u/past" ] \
  && ok || bad "the union block carried on past an unreadable table — every section after it would rewrite state/cost/ from the hub alone"
cmp -s "$T/u/fleet.before" "$FLEET" \
  && ok || bad "an unreadable table rewrote fleet-cost.csv ($(tail -n +2 "$FLEET" | wc -l) rows)"
cmp -s "$T/u/boxes.before" "$UH/state/cost/cost-rows-boxes.tsv" \
  && ok || bad "an unreadable table touched the presence table"
[ ! -s "$T/u/ssh.log" ] \
  && ok || bad "an unreadable table fell back to the tailnet: $(cat "$T/u/ssh.log")"
[ "$(grep -c 'cost_rows is unreadable' "$UH/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "an unreadable table must raise one ALERT: $(cat "$UH/logs/ALERTS.log" 2>/dev/null)"
down_union
[ "$(grep -c 'cost_rows is unreadable' "$UH/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "the unreadable-table ALERT fired twice in one day"

# ===========================================================================
# 11. bin/cost-rollup.sh names the boxes the TABLE is not hearing from
# ===========================================================================
# The DB read MOVED the "unreachable box reads as a quiet box" failure (a stuck
# cursor now does what an unreachable box did); it did not close it.
awk '/^# >>> cost rows box presence/{f=1;next} /^# <<< cost rows box presence/{exit} f' \
  "$DIR/bin/cost-rollup.sh" > "$T/presence.sh"
[ -s "$T/presence.sh" ] \
  && ok || bad "bin/cost-rollup.sh carries no extractable '# >>> cost rows box presence' block"
PH="$T/p/h"; mkdir -p "$PH/logs" "$PH/state/cost/overage" "$PH/flags" "$PH/bin"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$PH/bin/"
printf 'hub\nproject-4\nproject-3\n' > "$PH/state/cost/overage/EXPECTED"
PNOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
{ printf 'hub\t120\t%s\n' "$PNOW"
  printf 'project-4\t3\t2026-01-02T00:00:00Z\n'
} > "$PH/state/cost/cost-rows-boxes.tsv"
(
  H="$PH"; CD="$PH/state/cost"; OD="$CD/overage"
  STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
  # shellcheck source=/dev/null
  . "$T/presence.sh"
) >/dev/null 2>&1
grep -q 'project-4' "$PH/logs/agent-rules.log" \
  && ok || bad "a box whose last row is months old was not named in the log"
grep -q 'hub' "$PH/logs/agent-rules.log" \
  && bad "a box that pushed a minute ago was named as silent" || ok
grep -q 'project-3' "$PH/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "a box with NO row in the whole window did not raise one alert"
grep -q 'project-4' "$PH/logs/ALERTS.log" 2>/dev/null \
  && bad "a box that is merely quiet today was alerted on — that is how an alert channel gets ignored" || ok
# One alert a day, not one per run.
: > "$PH/logs/ALERTS.log"
(
  H="$PH"; CD="$PH/state/cost"; OD="$CD/overage"
  STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
  # shellcheck source=/dev/null
  . "$T/presence.sh"
) >/dev/null 2>&1
[ -s "$PH/logs/ALERTS.log" ] \
  && bad "the absent-box alert fired twice in one day" || ok

# An EMPTY boxes file is the fleet-wide case: cost_rows_fetch returns 0 on a
# window with no rows, so nothing falls back to ssh and every expected box is
# absent. It must alert, not skip — the gate is -f, not -s.
PH2="$T/p/h2"; mkdir -p "$PH2/logs" "$PH2/state/cost/overage" "$PH2/flags" "$PH2/bin"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$PH2/bin/"
printf 'hub\nproject-4\nproject-3\n' > "$PH2/state/cost/overage/EXPECTED"
: > "$PH2/state/cost/cost-rows-boxes.tsv"
(
  H="$PH2"; CD="$PH2/state/cost"; OD="$CD/overage"
  STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
  # shellcheck source=/dev/null
  . "$T/presence.sh"
) >/dev/null 2>&1
grep -q 'hub' "$PH2/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "an empty cost-rows-boxes.tsv (nobody pushed at all) raised no alert"
grep -q 'project-3' "$PH2/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "an empty cost-rows-boxes.tsv named only some of the expected boxes"

# A MISSING boxes file still skips: that is "the table was unreadable", which
# section 1b already logged, and re-alerting it here would double every outage.
PH3="$T/p/h3"; mkdir -p "$PH3/logs" "$PH3/state/cost/overage" "$PH3/flags"
printf 'hub\nproject-4\n' > "$PH3/state/cost/overage/EXPECTED"
(
  H="$PH3"; CD="$PH3/state/cost"; OD="$CD/overage"
  STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
  # shellcheck source=/dev/null
  . "$T/presence.sh"
) >/dev/null 2>&1
[ -s "$PH3/logs/ALERTS.log" ] \
  && bad "a missing cost-rows-boxes.tsv alerted — that is the unreadable-table case 1b owns" || ok

echo "rollup-from-rows: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
