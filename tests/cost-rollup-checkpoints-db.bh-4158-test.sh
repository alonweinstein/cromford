#!/bin/bash
# tests/cost-rollup-checkpoints-db.bh-4158-test.sh — THE COST ROLLUP'S
# CHECKPOINTS LIVE IN THE DB (BH-4158, slice C0 of #4158 / wave 6 of #4141).
#
# bin/cost-rollup.sh kept three checkpoints under state/cost/:
#   stamped.json    the dedup ledger in front of the client-visible "Final AI
#                   bill" PR comment  -> ledgers kind cost-final-bill, key = PR URL
#   last-success    the liveness stamp pipeline-health reads
#                                     -> ledgers kind cost-rollup, key last-success
#   rollup-running  the lock holder's pid + start -> locks/cost-rollup.running
# The writers of all three files are gone; the legacy stamped.json drains into
# rows and is deleted. Blocks are extracted VERBATIM by their markers.
#
#   F1-F5  the shell final-bill block: lossless prefetch, unreadable = unknown,
#          nightly only, bounded legacy import, retry rows handed over with detail
#   P1-P12 the python final-bill fragment: claim before send, retry on a failed
#          comment (at most 3 attempts, then failed + ALERTS), a read error or
#          failed claim posts nothing
#   K1-K4  last-success row, the pipeline-health liveness read, the run mark
#   E1     the REAL bin/jobs-client.sh CLI from a python child, under the block's
#          exports, against a loopback worker
#   E2     the REAL bin/cost-rollup.sh (WINDOWS_ONLY=1) against the loopback worker
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/cost-rollup-checkpoints-db.bh-4158-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v flock >/dev/null && command -v python3 >/dev/null \
  || { echo "jq/flock/python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }

# One pinned instant for every fixture (determinism lint).
NOW=1791100800   # 2026-10-04T12:00:00Z
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

blk() { # blk <file> <begin-marker> <end-marker> -> the lines between them
  awk -v b="$2" -v e="$3" 'index($0, b) == 1 {f=1; next} index($0, e) == 1 {exit} f' "$1"
}
blk "$DIR/bin/cost-rollup.sh" '# >>> final bill ledger (BH-4158)' '# <<< final bill ledger (BH-4158)' > "$T/fb.sh"
blk "$DIR/bin/cost-rollup.sh" '# >>> final bill (BH-4158)' '# <<< final bill (BH-4158)' > "$T/fb.py"
blk "$DIR/bin/cost-rollup.sh" '# >>> rollup last success' '# <<< rollup last success' > "$T/stamp.sh"
blk "$DIR/bin/cost-rollup.sh" '# >>> rollup timebox lock' '# <<< rollup timebox lock' > "$T/lock.sh"
blk "$DIR/bin/pipeline-health.sh" '# >>> cost rollup liveness' '# <<< cost rollup liveness' > "$T/live.sh"
for f in fb.sh fb.py stamp.sh lock.sh live.sh; do
  [ -s "$T/$f" ] && ok || bad "block $f could not be extracted — markers missing?"
done

# ============================================================================
# F. the shell final-bill block
# ============================================================================
H1="$T/fh"
cat > "$T/fstubs.sh" <<'SH'
# ledger_page: answers $T/pages/<n>.json (else default.json) with rc <n>.rc
ledger_page() {
  local n; n=$(( $(grep -c . "$T/page-calls") + 1 ))
  printf '%s\n' "$*" >> "$T/page-calls"
  [ -f "$T/pages/$n.rc" ] && return "$(cat "$T/pages/$n.rc")"
  if [ -f "$T/pages/$n.json" ]; then cat "$T/pages/$n.json"; else cat "$T/pages/default.json"; fi
}
# job_ledger_put: logs kind<TAB>key<TAB>status<TAB>detail; the put numbered
# $T/putfail-at fails with rc 1
job_ledger_put() {
  local n; n=$(( $(grep -c . "$T/puts") + 1 ))
  if [ -f "$T/putfail-at" ] && [ "$n" -ge "$(cat "$T/putfail-at")" ]; then
    printf 'FAILED\t%s\n' "$*" >> "$T/puts.failed"; return 1
  fi
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$T/puts"
}
SH
fb() { # fb [VAR=val...] — run the block; FB_UNKNOWN -> $T/fb.unknown, keys -> $T/fb.keys
  : > "$T/page-calls"; : > "$T/puts"; rm -f "$T/puts.failed" "$T/fb.unknown" "$T/fb.keys" "$T/fb.retry"
  mkdir -p "$H1/state/cost" "$H1/logs"
  # bounded: a walk that never ends must come out red, not hang the suite
  ( export T="$T" H1="$H1" "$@"
    timeout 120 bash -c '
      set -uo pipefail
      H="$H1"; CD="$H/state/cost"
      STAMP() { echo TS; }
      [ "${NO_CLIENT:-0}" = 1 ] || . "$T/fstubs.sh"
      . "$0"
      printf "%s\n" "$FB_UNKNOWN" > "$T/fb.unknown"
      cp "$FB_KEYS" "$T/fb.keys"; rm -f "$FB_KEYS"
      [ -n "${FB_RETRY:-}" ] && { cp "$FB_RETRY" "$T/fb.retry"; rm -f "$FB_RETRY"; }; :' "$T/fb.sh" >/dev/null 2>"$T/fb.err" )
}
# page <file> <first-n> <count> <status...> — a GET /api/ledger list body
page() {
  local f="$1" a="$2" c="$3"; shift 3
  python3 - "$f" "$a" "$c" "$@" <<'PY'
import json, sys
f, a, c, sts = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:] or ["stamped"]
rows = []
for i in range(a, a + c):
    rows.append({"kind": "cost-final-bill", "key": f"https://github.com/o/r/pull/{i}",
                 "status": sts[(i - a) % len(sts)],
                 "updated_at": "2026-10-0%dT00:00:00Z" % (1 + (i // 1000) % 3)})
json.dump({"ledgers": rows, "as_of": "2026-10-04T12:00:00Z"}, open(f, "w"))
PY
}
mkdir -p "$T/pages"

# F1. a full page then a short one: every non-retry key, and the second call
#     carries the compound cursor of row 1000
rm -f "$T/pages"/*; page "$T/pages/1.json" 1 1000 stamped pending
page "$T/pages/2.json" 1001 3 stamped pending retry
fb
[ "$(cat "$T/fb.unknown" 2>/dev/null)" = 0 ] && ok || bad "F1: two clean pages must leave FB_UNKNOWN=0, got '$(cat "$T/fb.unknown" 2>/dev/null)' err=$(head -3 "$T/fb.err")"
[ "$(grep -c . "$T/fb.keys" 2>/dev/null)" = 1002 ] && ok || bad "F1: expected 1002 done keys (1000 + stamped + pending), got $(grep -c . "$T/fb.keys" 2>/dev/null)"
grep -qx 'https://github.com/o/r/pull/1003' "$T/fb.keys" && bad "F1: a retry row must stay eligible (its key is not done)" || ok
grep -qx 'https://github.com/o/r/pull/1002' "$T/fb.keys" && grep -qx 'https://github.com/o/r/pull/2' "$T/fb.keys" \
  && ok || bad "P4b: a pending row (claimed, outcome unknown) must count as done"
R1000=$(jq -r '.ledgers[999] | "\(.updated_at) \(.key)"' "$T/pages/1.json")
[ "$(sed -n 2p "$T/page-calls")" = "cost-final-bill 1000 $R1000" ] && ok \
  || bad "F1: page 2 must carry before + before_key of row 1000 ('cost-final-bill 1000 $R1000'), got '$(sed -n 2p "$T/page-calls")'"
[ "$(grep -c . "$T/page-calls")" = 2 ] && ok || bad "F1: a short page ends the walk, got $(grep -c . "$T/page-calls") calls"

# F5. retry rows (BH-4158 review): key<TAB>detail go to FB_RETRY, so the
#     fragment can count attempts; they stay out of the done set
rm -f "$T/pages"/*
python3 - "$T/pages/1.json" <<'PY'
import json, sys
rows = [{"kind": "cost-final-bill", "key": "https://github.com/o/r/pull/41", "status": "retry",
         "detail": "attempt 2 2026-10-03T04:45:00Z", "updated_at": "2026-10-03T04:45:00Z"},
        {"kind": "cost-final-bill", "key": "https://github.com/o/r/pull/42", "status": "retry",
         "detail": "2026-10-02T04:45:00Z", "updated_at": "2026-10-02T04:45:00Z"},
        {"kind": "cost-final-bill", "key": "https://github.com/o/r/pull/43", "status": "failed",
         "detail": "attempt 3 2026-10-01T04:45:00Z", "updated_at": "2026-10-01T04:45:00Z"}]
json.dump({"ledgers": rows, "as_of": "2026-10-04T12:00:00Z"}, open(sys.argv[1], "w"))
PY
fb
printf 'https://github.com/o/r/pull/41\tattempt 2 2026-10-03T04:45:00Z\nhttps://github.com/o/r/pull/42\t2026-10-02T04:45:00Z\n' > "$T/fb.retry.want"
cmp -s "$T/fb.retry" "$T/fb.retry.want" && ok || bad "F5: FB_RETRY must hold key<TAB>detail of each retry row, got: $(cat "$T/fb.retry" 2>/dev/null)"
grep -qx 'https://github.com/o/r/pull/43' "$T/fb.keys" && ok || bad "F5: a failed (attempts spent) row must count as done"
grep -q 'pull/4[12]$' "$T/fb.keys" && bad "F5: a retry row must stay eligible" || ok

# F2. page 2 fails: the set is incomplete, so it is UNKNOWN, never short
rm -f "$T/pages"/*; page "$T/pages/1.json" 1 1000 stamped; echo 1 > "$T/pages/2.rc"
: > "$H1/logs/agent-rules.log"
fb
[ "$(cat "$T/fb.unknown" 2>/dev/null)" = 1 ] && ok || bad "F2: a failed page must set FB_UNKNOWN=1, got '$(cat "$T/fb.unknown" 2>/dev/null)'"
[ "$(grep -c 'final-bill ledger unreadable' "$H1/logs/agent-rules.log")" = 1 ] && ok \
  || bad "F2: one 'final-bill ledger unreadable' line expected: $(cat "$H1/logs/agent-rules.log")"
# F2b. a 2xx that is not a ledger list is unreadable too
rm -f "$T/pages"/*; echo '{"error":"nope"}' > "$T/pages/1.json"
fb
[ "$(cat "$T/fb.unknown" 2>/dev/null)" = 1 ] && ok || bad "F2b: a wrong-shape page must set FB_UNKNOWN=1"
# F2c. the 50-page ceiling: a walk that never ends is unknown, not complete (D12)
rm -f "$T/pages"/*; page "$T/pages/default.json" 1 1000 stamped
fb
[ "$(cat "$T/fb.unknown" 2>/dev/null)" = 1 ] && ok || bad "F2c: hitting the page ceiling must set FB_UNKNOWN=1"
[ "$(grep -c . "$T/page-calls")" = 50 ] && ok || bad "F2c: the walk must stop at 50 pages, made $(grep -c . "$T/page-calls")"
# F2d. no client at all on a nightly run: unknown
fb NO_CLIENT=1
[ "$(cat "$T/fb.unknown" 2>/dev/null)" = 1 ] && ok || bad "F2d: no ledger client on a nightly run must set FB_UNKNOWN=1"

# F3. the hourly window refresh never reads the ledger
rm -f "$T/pages"/*; page "$T/pages/1.json" 1 3 stamped
fb WINDOWS_ONLY=1
[ "$(grep -c . "$T/page-calls")" = 0 ] && ok || bad "F3: WINDOWS_ONLY=1 must make zero ledger_page calls, made $(grep -c . "$T/page-calls")"

# F4. the legacy stamped.json drains into rows, a bounded chunk per run
legacy5() {
  printf '{"https://github.com/o/r/pull/501":"2026-09-01T04:45:00Z","https://github.com/o/r/pull/502":"2026-09-02T04:45:00Z","https://github.com/o/r/pull/503":"2026-09-03T04:45:00Z","https://github.com/o/r/pull/504":"2026-09-04T04:45:00Z","https://github.com/o/r/pull/505":"2026-09-05T04:45:00Z"}' \
    > "$H1/state/cost/stamped.json"
}
scratch_rm "$H1"; mkdir -p "$H1/state/cost" "$H1/logs"; legacy5
fb WINDOWS_ONLY=1 COST_STAMP_IMPORT_CHUNK=2
printf 'cost-final-bill\thttps://github.com/o/r/pull/501\tstamped\t2026-09-01T04:45:00Z\ncost-final-bill\thttps://github.com/o/r/pull/502\tstamped\t2026-09-02T04:45:00Z\n' > "$T/want.puts"
cmp -s "$T/puts" "$T/want.puts" && ok || bad "F4: run 1 must PUT the first 2 entries verbatim: $(cat "$T/puts")"
[ "$(jq -r 'keys|join(" ")' "$H1/state/cost/stamped.json" 2>/dev/null)" = "https://github.com/o/r/pull/503 https://github.com/o/r/pull/504 https://github.com/o/r/pull/505" ] \
  && ok || bad "F4: run 1 must leave exactly the 3 unimported entries: $(cat "$H1/state/cost/stamped.json" 2>/dev/null)"
SNAPS=$(ls "$H1"/logs/cost-stamped-legacy-*.json 2>/dev/null | wc -l)
[ "$SNAPS" = 1 ] && [ "$(jq length "$H1"/logs/cost-stamped-legacy-*.json 2>/dev/null)" = 5 ] \
  && ok || bad "F4: the first import must snapshot the whole file once into logs/ ($SNAPS snapshots)"
grep -q 'cost-rollup: final-bill import: 2 imported, 3 remaining' "$H1/logs/agent-rules.log" \
  && ok || bad "F4: run 1 log line: $(grep final-bill "$H1/logs/agent-rules.log")"
fb WINDOWS_ONLY=1 COST_STAMP_IMPORT_CHUNK=2
fb WINDOWS_ONLY=1 COST_STAMP_IMPORT_CHUNK=2
[ ! -e "$H1/state/cost/stamped.json" ] && ok || bad "F4: a drained legacy file must be deleted: $(cat "$H1/state/cost/stamped.json" 2>/dev/null)"
[ "$(ls "$H1"/logs/cost-stamped-legacy-*.json 2>/dev/null | wc -l)" = 1 ] && ok || bad "F4: the snapshot is written once, not per run"
grep -q 'final-bill import: 1 imported, 0 remaining' "$H1/logs/agent-rules.log" && ok || bad "F4: run 3 must import the last entry"
fb WINDOWS_ONLY=1 COST_STAMP_IMPORT_CHUNK=2
[ ! -s "$T/puts" ] && ok || bad "F4: with no legacy file nothing is imported: $(cat "$T/puts")"
# F4b. the worker fails on the 2nd PUT: stop there, keep what did not land
scratch_rm "$H1"; mkdir -p "$H1/state/cost" "$H1/logs"; legacy5; echo 2 > "$T/putfail-at"
fb WINDOWS_ONLY=1
rm -f "$T/putfail-at"
[ "$(grep -c . "$T/puts")" = 1 ] && [ "$(jq length "$H1/state/cost/stamped.json" 2>/dev/null)" = 4 ] \
  && ! jq -e 'has("https://github.com/o/r/pull/501")' "$H1/state/cost/stamped.json" >/dev/null 2>&1 \
  && ok || bad "F4b: a failed 2nd PUT must leave 1 imported and 4 kept: puts=$(grep -c . "$T/puts") file=$(cat "$H1/state/cost/stamped.json" 2>/dev/null)"
[ "$(grep -c . "$T/puts.failed" 2>/dev/null)" = 1 ] && ok || bad "F4b: the import must stop at the first failed PUT, not keep trying"
grep -q 'final-bill import: 1 imported, 4 remaining, stopped' "$H1/logs/agent-rules.log" && ok \
  || bad "F4b: the stop must be logged: $(grep final-bill "$H1/logs/agent-rules.log")"
# F4c. no client at all: nothing imported, nothing lost
scratch_rm "$H1"; mkdir -p "$H1/state/cost" "$H1/logs"; legacy5
fb WINDOWS_ONLY=1 NO_CLIENT=1
[ "$(jq length "$H1/state/cost/stamped.json" 2>/dev/null)" = 5 ] && ok || bad "F4c: no client must keep every legacy entry"

# ============================================================================
# P. the python final-bill fragment
# ============================================================================
PH="$T/ph"; mkdir -p "$PH/bin" "$PH/logs" "$PH/state/cost" "$T/pbin"
cat > "$PH/bin/jobs-client.sh" <<'SH'
#!/bin/bash
# fake CLI: one line per call into the shared call log; rc from putrc.<status>
printf 'jobs-client %s\n' "$*" >> "$CALLS"
[ -f "$PUTRC_DIR/putrc.$4" ] && exit "$(cat "$PUTRC_DIR/putrc.$4")"
exit 0
SH
cat > "$T/pbin/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$CALLS"
case "$1 $2" in
  "pr view")    echo "${GH_STATE:-MERGED}" ;;
  "pr comment") exit "${GH_COMMENT_RC:-0}" ;;
esac
exit 0
SH
chmod +x "$PH/bin/jobs-client.sh" "$T/pbin/gh"
cat > "$T/prun.py" <<'PY'
import json, os, sys, subprocess, datetime
H, CD = sys.argv[1], sys.argv[2]
now = datetime.datetime(2026, 10, 4, 12, 0, 0)
per_pr = {e["pr"]: e for e in json.load(open(sys.argv[3]))}
exec(open(sys.argv[4]).read())
PY
cand() { # cand <pr-no> <total> — one per_pr entry
  # TEST-CHANGE: merge of BH-4155 — per_pr entries carry the BH-4021 fields (tstages, fly*) the merged bill body reads
  printf '{"pr":"https://github.com/o/r/pull/%s","total":%s,"in":12000,"out":3000,"cr":1500000,"cw":200000,"stages":{"execute":%s},"tstages":{"execute":%s},"fly":0.0,"fly_s":0,"fly_n":0,"fly_unpriced":0,"dirs":["cromford-BH-%s-x"]}' "$1" "$2" "$2" "$2" "$1"
}
prun() { # prun <candidates-json> [VAR=val...] — the fragment; calls -> $T/calls
  local c="$1"; shift
  printf '%s' "$c" > "$T/cands.json"
  : > "$T/calls"
  ( export PATH="$T/pbin:$PATH" CALLS="$T/calls" PUTRC_DIR="$T" COST_STAMPED_KEYS="$T/keys" "$@"
    python3 "$T/prun.py" "$PH" "$PH/state/cost" "$T/cands.json" "$T/fb.py" > "$T/p.out" 2> "$T/p.err" )
  echo $? > "$T/p.rc"
}
legsum() { cat "$PH/state/cost/stamped.json" 2>/dev/null | cksum; }
p8() { # P8: the fragment never writes the legacy file
  [ "$(legsum)" = "$1" ] && ok || bad "P8 ($2): state/cost/stamped.json was created or modified"
}
U1=https://github.com/o/r/pull/1; U2=https://github.com/o/r/pull/2; U3=https://github.com/o/r/pull/3

# P1. already in the prefetched set: not even a `gh pr view`
printf '%s\n' "$U1" > "$T/keys"; rm -f "$PH/state/cost/stamped.json"; S0=$(legsum)
prun "[$(cand 1 5.00)]"
[ "$(cat "$T/p.rc")" = 0 ] && ok || bad "P1: fragment exited $(cat "$T/p.rc"): $(tail -3 "$T/p.err")"
[ ! -s "$T/calls" ] && ok || bad "P1: a done PR must cost zero calls: $(cat "$T/calls")"
p8 "$S0" P1

# P2. only in the not-yet-imported legacy file: never billed twice
: > "$T/keys"; printf '{"%s":"2026-09-01T04:45:00Z"}' "$U2" > "$PH/state/cost/stamped.json"; S0=$(legsum)
prun "[$(cand 2 5.00)]"
grep -q '^gh pr comment' "$T/calls" && bad "P2: a PR only in the legacy file must not be commented: $(cat "$T/calls")" || ok
[ ! -s "$T/calls" ] && ok || bad "P2: a legacy-done PR must cost zero calls: $(cat "$T/calls")"
p8 "$S0" P2
rm -f "$PH/state/cost/stamped.json"; S0=$(legsum)

# P3. a MERGED PR: claim, then comment, then stamped — in that order
: > "$T/keys"
prun "[$(cand 3 7.50)]"
grep -v '^gh pr view' "$T/calls" | cut -d' ' -f1-6 > "$T/order"
printf 'jobs-client ledger-put cost-final-bill %s pending 2026-10-04T12:00:00Z\ngh pr comment %s --body Final\njobs-client ledger-put cost-final-bill %s stamped 2026-10-04T12:00:00Z\n' "$U3" "$U3" "$U3" \
  | cut -d' ' -f1-6 > "$T/order.want"
cmp -s "$T/order" "$T/order.want" && ok || bad "P3: expected claim -> comment -> stamped, got: $(cat "$T/calls")"
grep -q "^jobs-client ledger-put cost-final-bill $U3 pending 2026-10-04T12:00:00Z$" "$T/calls" \
  && ok || bad "P3: the claim must carry the PR URL key verbatim and the run's ISO-Z time: $(cat "$T/calls")"
grep -q 'Final bill: \*\*\$7.50\*\*' "$T/calls" && ok || bad "P3: the comment body must be the unchanged final bill"  # TEST-CHANGE: BH-4021 (merged from the base) renamed the body's lead to "Final bill:"
p8 "$S0" P3

# P4. the comment fails: the row goes to retry, never to stamped
prun "[$(cand 3 7.50)]" GH_COMMENT_RC=1
grep -q "^jobs-client ledger-put cost-final-bill $U3 retry " "$T/calls" && ok || bad "P4: a failed comment must put retry: $(cat "$T/calls")"
grep -q " stamped " "$T/calls" && bad "P4: a failed comment must never be recorded stamped" || ok
# P4b (fragment half). a pending key in the set is done
printf '%s\n' "$U3" > "$T/keys"
prun "[$(cand 3 7.50)]"
[ ! -s "$T/calls" ] && ok || bad "P4b: a pending (done) key must not be re-billed: $(cat "$T/calls")"
p8 "$S0" P4

# P5. the claim cannot be written: no comment for this PR or any later one
: > "$T/keys"; echo 1 > "$T/putrc.pending"
prun "[$(cand 1 9.00),$(cand 2 4.00)]"
rm -f "$T/putrc.pending"
grep -q '^gh pr comment' "$T/calls" && bad "P5: a failed claim must post nothing: $(cat "$T/calls")" || ok
[ "$(grep -c '^jobs-client ledger-put' "$T/calls")" = 1 ] && ok || bad "P5: the loop must stop at the failed claim: $(cat "$T/calls")"
grep -q 'final-bill claim' "$PH/logs/agent-rules.log" 2>/dev/null && ok || bad "P5: a failed claim must be logged"
p8 "$S0" P5

# P6. the shell could not read the ledger: no gh call, no put
prun "[$(cand 1 9.00)]" COST_STAMPED_UNKNOWN=1
[ ! -s "$T/calls" ] && ok || bad "P6: COST_STAMPED_UNKNOWN=1 must make zero calls: $(cat "$T/calls")"
# P6b. no key file handed over at all: same
prun "[$(cand 1 9.00)]" COST_STAMPED_KEYS=
[ ! -s "$T/calls" ] && ok || bad "P6b: a nightly run with no prefetched key file must make zero calls: $(cat "$T/calls")"
# P6c. an unparseable legacy file: unknown, not empty
echo 'not json' > "$PH/state/cost/stamped.json"
prun "[$(cand 1 9.00)]"
[ ! -s "$T/calls" ] && ok || bad "P6c: an unreadable legacy file must make zero calls: $(cat "$T/calls")"
rm -f "$PH/state/cost/stamped.json"

# P7. STAMP_DRY prints the bill and writes nothing
prun "[$(cand 1 9.00)]" STAMP_DRY=1
grep -q "^DRY-STAMP $U1: Final bill" "$T/p.out" && ok || bad "P7: STAMP_DRY must print the DRY-STAMP line: $(cat "$T/p.out")"  # TEST-CHANGE: BH-4021 body lead "Final bill"
grep -q 'ledger-put' "$T/calls" && bad "P7: STAMP_DRY must not write the ledger: $(cat "$T/calls")" || ok
p8 "$S0" P7

# P9. the hourly lane never bills
prun "[$(cand 1 9.00)]" WINDOWS_ONLY=1
[ ! -s "$T/calls" ] && ok || bad "P9: WINDOWS_ONLY=1 must make zero calls: $(cat "$T/calls")"

# P10-P12 (BH-4158 review): a failing comment is retried a bounded number of
# times. The attempt count rides in the row's detail ("attempt <n> <ts>"); a
# bare-timestamp detail is a pre-count row, read as one attempt. The third
# failure writes `failed` (done for the prefetch) and one ALERTS line.
cat > "$PH/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf 'alert-line %s\n' "$*" >> "$CALLS"
SH
chmod +x "$PH/bin/alert-line.sh"
: > "$T/keys"
# P10. first failure: retry, attempt 1
prun "[$(cand 3 7.50)]" GH_COMMENT_RC=1 COST_RETRY_ROWS="$T/retry"
grep -q "^jobs-client ledger-put cost-final-bill $U3 retry attempt 1 2026-10-04T12:00:00Z$" "$T/calls" && ok \
  || bad "P10: a first failure must put retry 'attempt 1 <ts>': $(cat "$T/calls")"
# P11. a row at attempt 1 fails again: attempt 2, still retry, no alert
printf '%s\tattempt 1 2026-10-03T04:45:00Z\n' "$U3" > "$T/retry"
prun "[$(cand 3 7.50)]" GH_COMMENT_RC=1 COST_RETRY_ROWS="$T/retry"
grep -q "^jobs-client ledger-put cost-final-bill $U3 retry attempt 2 " "$T/calls" && ok \
  || bad "P11: a second failure must put retry 'attempt 2': $(cat "$T/calls")"
grep -q '^alert-line' "$T/calls" && bad "P11: no alert before the attempts are spent" || ok
# P11b. a pre-count row (bare timestamp) counts as attempt 1
printf '%s\t2026-10-02T04:45:00Z\n' "$U3" > "$T/retry"
prun "[$(cand 3 7.50)]" GH_COMMENT_RC=1 COST_RETRY_ROWS="$T/retry"
grep -q "^jobs-client ledger-put cost-final-bill $U3 retry attempt 2 " "$T/calls" && ok \
  || bad "P11b: a bare-timestamp retry row must count as one attempt: $(cat "$T/calls")"
# P12. the third failure: failed (terminal) and one ALERTS line naming the PR
printf '%s\tattempt 2 2026-10-03T04:45:00Z\n' "$U3" > "$T/retry"
prun "[$(cand 3 7.50)]" GH_COMMENT_RC=1 COST_RETRY_ROWS="$T/retry"
grep -q "^jobs-client ledger-put cost-final-bill $U3 failed attempt 3 " "$T/calls" && ok \
  || bad "P12: the third failure must put failed 'attempt 3': $(cat "$T/calls")"
grep -q " retry " "$T/calls" && bad "P12: a spent row must not go back to retry: $(cat "$T/calls")" || ok
[ "$(grep -c "^alert-line .*$U3" "$T/calls")" = 1 ] && ok || bad "P12: exactly one ALERTS line naming the PR: $(cat "$T/calls")"
# P12b. a retry row that succeeds: stamped
prun "[$(cand 3 7.50)]" COST_RETRY_ROWS="$T/retry"
grep -q "^jobs-client ledger-put cost-final-bill $U3 stamped " "$T/calls" && ok || bad "P12b: a retry that posts must put stamped: $(cat "$T/calls")"
rm -f "$T/retry" "$PH/bin/alert-line.sh"

# ============================================================================
# K. last-success row, the liveness read, the run mark
# ============================================================================
KH="$T/kh"; mkdir -p "$KH/state/cost" "$KH/logs" "$KH/locks" "$KH/flags" "$KH/bin"
stamp() { # stamp [VAR=val...] — the last-success block, stub put -> $T/kputs
  : > "$T/kputs"
  ( export T="$T" KH="$KH" "$@"
    bash -c '
      set -uo pipefail
      H="$KH"; CD="$H/state/cost"; STAMP() { echo TS; }
      job_ledger_put() { printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "${4:-}" >> "$T/kputs"; return "${KPUT_RC:-0}"; }
      . "$0"' "$T/stamp.sh" >/dev/null 2>"$T/k.err" )
  echo $? > "$T/k.rc"
}
# K1. one row, ISO-Z, and the legacy file is removed
echo '2026-09-01T00:00:00Z' > "$KH/state/cost/last-success"
stamp
[ "$(grep -c . "$T/kputs")" = 1 ] && grep -qE '^cost-rollup\|last-success\|ok\|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$T/kputs" \
  && ok || bad "K1: expected one put cost-rollup|last-success|ok|<ISO-Z>, got: $(cat "$T/kputs")"
[ ! -e "$KH/state/cost/last-success" ] && ok || bad "K1: the legacy last-success file must be removed (writer gone)"
# K2. the put fails: one log line, rc 0, still no file
: > "$KH/logs/agent-rules.log"
stamp KPUT_RC=1
[ "$(cat "$T/k.rc")" = 0 ] && ok || bad "K2: a failed put must never fail the block (rc $(cat "$T/k.rc"))"
[ "$(grep -c 'last-success row NOT written' "$KH/logs/agent-rules.log")" = 1 ] && ok \
  || bad "K2: one 'last-success row NOT written' line expected: $(cat "$KH/logs/agent-rules.log")"
[ ! -e "$KH/state/cost/last-success" ] && ok || bad "K2: a failed put must not resurrect the file"

# K3. the liveness read
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$KH/bin/"
printf '#!/bin/bash\nexit 0\n' > "$KH/bin/beat.sh"; chmod +x "$KH/bin/beat.sh"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/cap.sh"
echo '{}' > "$KH/state/health-alerted.json"
live() { # live [VAR=val...] — ROW_RC (0/1/2), ROW_AT (epoch); pages -> $T/kalerts
  : > "$T/kalerts"; : > "$T/krows"
  ( export T="$T" KH="$KH" NOW="$NOW" "$@"
    bash -c '
      set -uo pipefail
      H="$KH"; DEDUP="$H/state/health-alerted.json"
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/kalerts"; }
      job_ledger_row() {
        echo "$*" >> "$T/krows"
        case "${ROW_RC:-0}" in
          0) printf "{\"status\":\"ok\",\"detail\":\"%s\"}" "$(date -u -d "@$ROW_AT" "+%Y-%m-%dT%H:%M:%SZ")"; return 0 ;;
          *) return "$ROW_RC" ;;
        esac
      }
      . "$T/cap.sh"; . "$0"
      echo "$ROLL_SRC" > "$T/ksrc"' "$T/live.sh" >/dev/null 2>"$T/kl.err" )
}
SUM="$KH/state/cost/summary.json"
rm -f "$KH/state/cost/last-success" "$KH/state/cost-rollup-stale"
# a: row fresh, summary old -> quiet
echo '{}' > "$SUM"; touch -d "@$((NOW - 5*3600))" "$SUM"
live ROW_AT=$((NOW - 600))
[ ! -s "$T/kalerts" ] && ok || bad "K3a: a fresh row must not page: $(cat "$T/kalerts") err=$(head -3 "$T/kl.err")"
grep -q 'ledger cost-rollup/last-success' "$T/ksrc" && ok || bad "K3a: the fresh row must be the named source: $(cat "$T/ksrc")"
# b: row and summary both old -> one page
live ROW_AT=$((NOW - 5*3600))
[ "$(grep -c '|costrollupstale:hub|' "$T/kalerts")" = 1 ] && ok || bad "K3b: a stale row and summary must page once: $(cat "$T/kalerts")"
rm -f "$KH/state/cost-rollup-stale"
# c: ledger unreadable, summary fresh -> quiet, and the source says so
touch -d "@$((NOW - 600))" "$SUM"
live ROW_RC=1
[ ! -s "$T/kalerts" ] && ok || bad "K3c: a ledger outage with a fresh summary.json must not page: $(cat "$T/kalerts")"
grep -q 'ledger unreadable' "$T/ksrc" && ok || bad "K3c: ROLL_SRC must say the ledger was unreadable: $(cat "$T/ksrc")"
# c2: ledger unreadable AND summary stale -> it still pages (an outage is not freshness)
touch -d "@$((NOW - 5*3600))" "$SUM"
live ROW_RC=1
[ "$(grep -c '|costrollupstale:hub|' "$T/kalerts")" = 1 ] && grep -q 'ledger unreadable' "$T/kalerts" \
  && ok || bad "K3c2: a ledger outage must not mask a stale summary.json: $(cat "$T/kalerts")"
rm -f "$KH/state/cost-rollup-stale"
# c3: no row yet (rc 2), summary fresh -> quiet, named
touch -d "@$((NOW - 600))" "$SUM"
live ROW_RC=2
[ ! -s "$T/kalerts" ] && grep -q 'no ledger row yet' "$T/ksrc" && ok || bad "K3c3: rc 2 with a fresh summary must be quiet and named: $(cat "$T/kalerts") src=$(cat "$T/ksrc")"
# d: row old (the put failed this run), summary fresh -> quiet: the newest wins
live ROW_AT=$((NOW - 5*3600))
[ ! -s "$T/kalerts" ] && ok || bad "K3d: an old row beside a fresh summary.json must not page: $(cat "$T/kalerts")"
grep -q 'summary.json mtime' "$T/ksrc" && ok || bad "K3d: the newest source must win: $(cat "$T/ksrc")"
# e: no summary.json and no legacy stamp: no rollup here, no query, no page
rm -f "$SUM" "$KH/state/cost/last-success"
live ROW_AT=$((NOW - 5*3600))
[ ! -s "$T/krows" ] && ok || bad "K3e: a box with no rollup must not query the ledger: $(cat "$T/krows")"
[ ! -s "$T/kalerts" ] && ok || bad "K3e: a box with no rollup must not page: $(cat "$T/kalerts")"
# f: a legacy stamp only (a box mid-upgrade) is still honored
iso $((NOW - 600)) > "$KH/state/cost/last-success"
live ROW_RC=2
[ ! -s "$T/kalerts" ] && grep -q 'state/cost/last-success' "$T/ksrc" && ok \
  || bad "K3f: a fresh legacy stamp must still count: $(cat "$T/kalerts") src=$(cat "$T/ksrc")"
iso $((NOW - 5*3600)) > "$KH/state/cost/last-success"
live ROW_RC=2
[ "$(grep -c '|costrollupstale:hub|' "$T/kalerts")" = 1 ] && ok || bad "K3f: a stale legacy stamp alone must page: $(cat "$T/kalerts")"
rm -f "$KH/state/cost/last-success" "$KH/state/cost-rollup-stale"

# K4. the run mark lives beside the lock, never under state/cost/
runlock() {
  : > "$T/lockout.txt"
  ( export HARNESS="$KH" T="$T" KH="$KH" COST_ROLLUP_TIMEBOXED=1
    bash -c '
      set -uo pipefail
      H="$KH"; CD="$KH/state/cost"
      STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
      . "$0"
      cp "$H/locks/cost-rollup.running" "$T/mark.seen" 2>/dev/null
      echo REACHED_END >> "$T/lockout.txt"' "$T/lock.sh" >/dev/null 2>"$T/lockerr.txt" )
}
printf '1 2026-09-01T00:00:00Z\n' > "$KH/state/cost/rollup-running"
rm -f "$T/mark.seen"
runlock
grep -q REACHED_END "$T/lockout.txt" && ok || bad "K4: an unheld lock must let the run through: $(cat "$T/lockerr.txt")"
grep -qE '^[0-9]+ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$T/mark.seen" 2>/dev/null \
  && ok || bad "K4: the holder must write '<pid> <ISO-Z>' to locks/cost-rollup.running: $(cat "$T/mark.seen" 2>/dev/null)"
[ ! -e "$KH/state/cost/rollup-running" ] && ok || bad "K4: the legacy state/cost/rollup-running must be removed and never rewritten"
[ ! -e "$KH/locks/cost-rollup.running" ] && ok || bad "K4: the mark must go when the holder exits"
flock -x "$KH/locks/cost-rollup.lock" -c 'sleep 20' &
HOLDER=$!; sleep 0.5   # determinism: ok waits for the background flock holder to take the lock
printf '%s %s\n' 4343 '2026-10-04T08:00:00Z' > "$KH/locks/cost-rollup.running"
touch -d '3 hours ago' "$KH/locks/cost-rollup.running"   # determinism: ok the age is relative to the file's own mtime check
: > "$KH/logs/ALERTS.log"; rm -f "$KH/flags"/alerted-cost-rollup-wedged-*
runlock
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
grep -q REACHED_END "$T/lockout.txt" && bad "K4: a held lock must stop the run" || ok
grep -q '\[cost-rollup\] a rollup run (pid 4343, started 2026-10-04T08:00:00Z)' "$KH/logs/ALERTS.log" \
  && ok || bad "K4: a wedged holder read from locks/cost-rollup.running must page with its pid: $(cat "$KH/logs/ALERTS.log")"
[ ! -e "$KH/state/cost/rollup-running" ] && ok || bad "K4: a skipped run must not write state/cost/rollup-running"

# ============================================================================
# E. the real client and the real rollup against a loopback worker
# ============================================================================
cat > "$T/worker.py" <<'PY'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
DB, LOG = sys.argv[1], sys.argv[2]
def load():
    try: return json.load(open(DB))
    except Exception: return {}
class W(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _log(self, s):
        with open(LOG, "a") as fh: fh.write(s + "\n")
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = dict(urllib.parse.parse_qsl(u.query))
        self._log(f"GET {u.path} {q.get('kind','')} {q.get('key','')}")
        if self.headers.get("authorization") != "Bearer s3cret": return self._send(401, {"error": "auth"})
        if u.path == "/api/metrics/cost-rows": return self._send(200, {"cost_rows": []})
        if u.path == "/api/ledger":
            db = load()
            if q.get("key"):
                r = db.get(q["kind"] + "|" + q["key"])
                return self._send(200, {"ledger": r}) if r else self._send(404, {"error": "not found"})
            rows = [r for r in db.values() if r["kind"] == q.get("kind")]
            return self._send(200, {"ledgers": rows, "as_of": "x"})
        return self._send(404, {"error": "no route"})
    def do_PUT(self):
        n = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        self._log(f"PUT {self.path} {body.get('kind','')} {body.get('key','')} {body.get('status','')}")
        if self.headers.get("authorization") != "Bearer s3cret": return self._send(401, {"error": "auth"})
        db = load()
        db[body["kind"] + "|" + body["key"]] = {"kind": body["kind"], "key": body["key"], "status": body["status"],
                                                "detail": body.get("detail"), "updated_at": "2026-10-04T12:00:00Z"}
        json.dump(db, open(DB, "w"))
        return self._send(200, {"ledger": db[body["kind"] + "|" + body["key"]]})
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0); self.rfile.read(n)
        self._log(f"POST {self.path}")
        return self._send(200, {})
    def log_message(self, *a): pass
s = HTTPServer(("127.0.0.1", 0), W)
print(s.server_port, flush=True)
s.serve_forever()
PY
python3 "$T/worker.py" "$T/db.json" "$T/wreqs" > "$T/port" 2>/dev/null &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null; __scratch_exit_trap' EXIT
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done   # determinism: ok polls for the loopback worker's port
STUB="http://127.0.0.1:$(cat "$T/port" 2>/dev/null)"
dbrow() { jq -r --arg k "$1|$2" '.[$k] | if . == null then "" else "\(.status) \(.detail // "")" end' "$T/db.json" 2>/dev/null; }

# E1. a python child running the real CLI sees the parent's worker: the block
#     exports JOBS_URL even though the client only shell-set it
E1H="$T/e1"; mkdir -p "$E1H/logs" "$E1H/env" "$E1H/state/cost"
( unset JOBS_URL
  export T="$T" E1H="$E1H" STUB="$STUB" DIR="$DIR" HARNESS="$E1H" HARNESS_ENV_DIR="$E1H/env" JOBS_TIMEOUT=3 JOBS_RETRIES=0
  bash -c '
    set -uo pipefail
    export HARNESS_SECRET=s3cret
    JOBS_URL="$STUB"; JOBS_BOX=e1box
    H="$E1H"; CD="$H/state/cost"; STAMP() { echo TS; }; WINDOWS_ONLY=1
    . "$0"
    rm -f "$FB_KEYS"
    python3 -c "import subprocess, sys; sys.exit(subprocess.run([sys.argv[1] + \"/bin/jobs-client.sh\", \"ledger-put\", \"cost-final-bill\", \"https://github.com/o/r/pull/77\", \"stamped\", \"2026-10-04T12:00:00Z\"]).returncode)" "$DIR"
    echo $? > "$T/e1.rc"' "$T/fb.sh" >/dev/null 2>"$T/e1.err" )
[ "$(cat "$T/e1.rc" 2>/dev/null)" = 0 ] && ok || bad "E1: the child CLI put must succeed (rc $(cat "$T/e1.rc" 2>/dev/null)): $(tail -3 "$T/e1.err")"
[ "$(dbrow cost-final-bill https://github.com/o/r/pull/77)" = "stamped 2026-10-04T12:00:00Z" ] && ok \
  || bad "E1: the row must land in the worker the parent was talking to: '$(dbrow cost-final-bill https://github.com/o/r/pull/77)'"

# E2. the real rollup, hourly lane, with a 3-entry legacy stamped.json
EH="$T/e2"; mkdir -p "$EH/bin/lib/jobs" "$EH/logs" "$EH/builds" "$EH/state/cost" "$EH/env" "$EH/flags" "$EH/locks" "$T/ebin"
# The rollup, the jobs client and the alert line, each with the bin/lib files it
# sources (BH-4552). alert_family.py is imported by python, so it is copied.
for s in bin/cost-rollup.sh bin/jobs-client.sh bin/alert-line.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$EH" ) >/dev/null || bad "E2: cannot install the closure of $s"
done
cp "$DIR/bin/alert_family.py" "$EH/bin/"
printf '# project slug\nproject-1 -\n' > "$EH/fleet.conf"
printf '#!/bin/bash\nexit 1\n' > "$T/ebin/gh"; printf '#!/bin/bash\nexit 7\n' > "$T/ebin/ssh"
chmod +x "$T/ebin/gh" "$T/ebin/ssh"
printf '{"https://github.com/o/r/pull/601":"2026-09-01T04:45:00Z","https://github.com/o/r/pull/602":"2026-09-02T04:45:00Z","https://github.com/o/r/pull/603":"2026-09-03T04:45:00Z"}' \
  > "$EH/state/cost/stamped.json"
printf '1 2026-09-01T00:00:00Z\n' > "$EH/state/cost/rollup-running"
echo '2026-09-01T00:00:00Z' > "$EH/state/cost/last-success"
(cd "$EH/state/cost" && ls -A) | grep -v -e '^stamped.json$' -e '^rollup-running$' -e '^last-success$' > "$T/e2.before" || true
ls -A "$EH/flags" > "$T/e2.flags.before"
env -u JOBS_URL PATH="$T/ebin:$PATH" HARNESS="$EH" HARNESS_ENV_DIR="$EH/env" COST_ROLLUP_TIMEBOXED=1 LANE_GATE_DISABLE=1 \
    WINDOWS_ONLY=1 STAMP_DRY=1 HARNESS_SECRET=s3cret JOBS_URL="$STUB" JOBS_BOX=e2box JOBS_TIMEOUT=3 JOBS_RETRIES=0 \
    bash "$EH/bin/cost-rollup.sh" > "$T/e2.out" 2>&1
E2RC=$?
[ "$E2RC" = 0 ] && ok || bad "E2: the rollup exited $E2RC: $(tail -5 "$T/e2.out")"
case "$(dbrow cost-rollup last-success)" in
  "ok "[0-9][0-9][0-9][0-9]-*Z) ok ;;
  *) bad "E2: the cost-rollup/last-success row must be written: '$(dbrow cost-rollup last-success)' $(grep -i 'last-success' "$EH/logs/agent-rules.log")" ;;
esac
for n in 601 602 603; do
  [ "$(dbrow cost-final-bill "https://github.com/o/r/pull/$n")" = "stamped 2026-09-0$((n - 600))T04:45:00Z" ] && ok \
    || bad "E2: legacy entry /pull/$n must be imported verbatim: '$(dbrow cost-final-bill "https://github.com/o/r/pull/$n")'"
done
for f in stamped.json last-success rollup-running; do
  [ ! -e "$EH/state/cost/$f" ] && ok || bad "E2: state/cost/$f must not exist after a run (its writer is gone)"
done
(cd "$EH/state/cost" && ls -A) > "$T/e2.after"
grep -qx -e 'stamped.json' -e 'last-success' -e 'rollup-running' "$T/e2.after" && bad "E2: a moved checkpoint reappeared under state/cost/" || ok
[ ! -e "$EH/locks/cost-rollup.running" ] && ok || bad "E2: the run mark must go with the run"
# flags/: only the rollup's pre-existing daily alert dedupe stamps, nothing new
NEWF=$(ls -A "$EH/flags" | grep -vxF -f "$T/e2.flags.before" | grep -v -e '^alerted-costperpr-empty-' -e '^alerted-unpriced-' -e '^alerted-jobs-client-' -e '^alerted-cost-rows-absent-' || true)
[ -z "$NEWF" ] && ok || bad "E2: flags/ gained new names: $NEWF"
grep -q 'final-bill import: 3 imported, 0 remaining' "$EH/logs/agent-rules.log" && ok \
  || bad "E2: the import line must say the file drained: $(grep -i 'final-bill' "$EH/logs/agent-rules.log")"

echo "cost-rollup-checkpoints-db.bh-4158-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
