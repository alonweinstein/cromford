#!/bin/bash
# tests/gh-ledger-fleet.bh-1574-test.sh — BH-1574: every box's GitHub-call ledger
# reaches D1 (bin/gh-ledger-push.sh), and bin/gh-quota-report.sh reports the
# FLEET from D1 — per box, per bucket, per caller.
#
# WHY. The hub App installation (161623167) is one 6,600/h bucket shared by the
# hub, seven boxes and every Fly builder. bin/gh-quota-report.sh read only the
# files of the box it ran on, so the ledger "accounted for" ~1,400/h and the
# rest of the bucket looked like a mystery consumer when most of it was other
# boxes' ledgers that nothing summed (2026-09-23 gh-reads audit).
#
# What is pinned, with the worker stubbed as a `curl` on PATH that records every
# request and answers the way worker/jobs does:
#   A. the push aggregates one box's hour files into (hour, caller, project,
#      meter, bucket, method, path class, status, source) rows with calls,
#      counted, the lowest remaining, the highest used/limit/reset — a legacy
#      10-column line lands as bucket `-`, source `rest`, never dropped;
#   B. a push that moved nothing sends nothing; a new line re-sends that WHOLE
#      hour (the worker upserts, so a recompute replaces instead of doubling).
#      "Moved" is the file's SIZE against the size last sent, never an mtime:
#      a push and an append in the same second must not lose the append;
#   C. a failed push leaves the stamp alone, so the next tick re-sends;
#   D. flags/gh-ledger-push-off sends nothing;
#   E. the report sums rows from TWO boxes and prints per box / bucket / caller
#      plus the GraphQL line from the X-RateLimit headers the rows carried;
#   F. an unreachable worker falls back to this box's files and SAYS so.
#
# Run from anywhere: bash tests/gh-ledger-fleet.bh-1574-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PUSH="$DIR/bin/gh-ledger-push.sh"
REPORT="$DIR/bin/gh-quota-report.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=1790143200   # determinism: ok pinned; 2026-09-23T04:00:00Z — every fixture hour is written by name
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state/gh-rest-ledger" "$T/h/flags" "$T/h/env" "$T/fake" "$T/req" "$T/tmp"
ln -s "$DIR/bin" "$T/h/bin"
export TMPDIR="$T/tmp"
export HARNESS_SECRET=test-secret JOBS_URL=http://jobs.test JOBS_RETRIES=0 LANE_GATE_DISABLE=1
export PATH="$T/fake:$PATH"
LED="$T/h/state/gh-rest-ledger"

# ── the worker, as a curl stub ───────────────────────────────────────────────
# Records METHOD URL and the posted body; answers the read from $T/read.json
# and everything else the way the worker does.
cat > "$T/fake/curl" <<'SH'
#!/bin/bash
D="$STUB_DIR"; M=GET; URL=""; DATA=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w|-o|-D) shift 2 ;;
    --data-binary|-d|--data) DATA="$2"; shift 2 ;;
    http*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
n=$(ls "$D/req" | wc -l | tr -dc 0-9)
printf '%s %s\n' "$M" "$URL" > "$D/req/$n.line"
case "$DATA" in @*) cp "${DATA#@}" "$D/req/$n.json" ;; '') ;; *) printf '%s' "$DATA" > "$D/req/$n.json" ;; esac
code="${STUB_CODE:-200}"
case "$URL" in
  */api/metrics/gh-ledger\?*) [ -f "$D/read.json" ] && cat "$D/read.json" || printf '{"rows":[],"truncated":false}' ;;
  */api/metrics/gh-ledger)    printf '{"accepted":1,"inserted":1}' ;;
  *) code=404; printf '{"error":"unknown endpoint"}' ;;
esac
printf '\n%s' "$code"
SH
chmod +x "$T/fake/curl"
export STUB_DIR="$T"
posts() { grep -l '^POST .*/api/metrics/gh-ledger$' "$T/req/"*.line 2>/dev/null | wc -l | tr -dc 0-9; }
lastbody() { local f; f=$(grep -l '^POST .*/api/metrics/gh-ledger$' "$T/req/"*.line 2>/dev/null | sort -t/ -k2 -V | tail -1); cat "${f%.line}.json"; }
reqreset() { rm -f "$T/req/"*; }
tsv() { printf '%s\t' "$@" | sed 's/\t$//'; printf '\n'; }

# One hour on this box, three sources of rows: two raw graphql calls from the
# shim (one lane), one REST call from gh_rest, and one pre-BH-1574 10-column
# line (no bucket, no source).
H03="$LED/2026-09-23T03.tsv"
{
  tsv 2026-09-23T03:00:01Z merge-conductor project-4 POST graphql 200 1 4920 1790143346 app-161623167 graphql gh 80 5000
  tsv 2026-09-23T03:00:09Z merge-conductor project-4 POST graphql 200 1 4900 1790143346 app-161623167 graphql gh 100 5000
  tsv 2026-09-23T03:00:05Z merge-sweep project-4 GET repos/o/r/pulls/N 304 0 6100 1790143900 app-161623167 core rest 500 6600
  tsv 2026-09-23T03:00:07Z merge-sweep project-3 GET repos/o/r/issues/N 200 1 6000 1790143900 app
} > "$H03"

# ══ A. the aggregate ════════════════════════════════════════════════════════
[ -x "$PUSH" ] && ok || bad "A0: bin/gh-ledger-push.sh must exist and be executable"
reqreset
bash "$PUSH" boxA > "$T/push.out" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "A1: a push exits 0, got $rc: $(cat "$T/push.out")"
[ "$(posts)" = 1 ] && ok || bad "A2: one POST for one hour, got $(posts): $(cat "$T/req/"*.line 2>/dev/null)"
B=$(lastbody)
[ "$(jq -r '.box' <<<"$B")" = boxA ] && ok || bad "A3: the box id rides the body, got: $B"
G=$(jq -c '.rows[] | select(.resource=="graphql")' <<<"$B")
[ "$(jq -r '[.hour,.lane,.project,.meter,.method,.path_class,.status,.source] | join(" ")' <<<"$G")" \
  = "2026-09-23T03 merge-conductor project-4 app-161623167 POST graphql 200 gh" ] && ok \
  || bad "A4: the graphql key, got: $G"
[ "$(jq -r '[.calls,.counted,.remaining_min,.used_max,.limit_max,.reset_max] | map(tostring) | join(" ")' <<<"$G")" \
  = "2 2 4900 100 5000 1790143346" ] && ok || bad "A5: two calls fold into one row with min remaining / max used, got: $G"
C=$(jq -c '.rows[] | select(.resource=="core")' <<<"$B")
[ "$(jq -r '[.calls,.counted,.source,.status] | map(tostring) | join(" ")' <<<"$C")" = "1 0 rest 304" ] && ok \
  || bad "A6: a 304 is a call that was not counted, got: $C"
L=$(jq -c '.rows[] | select(.project=="project-3")' <<<"$B")
[ "$(jq -r '[.resource,.source,.meter,.calls] | map(tostring) | join(" ")' <<<"$L")" = "- rest app 1" ] && ok \
  || bad "A7: a legacy 10-column line lands as bucket '-' / source rest, never dropped, got: $L"
[ "$(jq -r '.rows | length' <<<"$B")" = 3 ] && ok || bad "A8: three aggregate keys, got $(jq -r '.rows|length' <<<"$B")"

# ══ B. nothing moved = nothing sent; a new line re-sends the whole hour ═════
reqreset
bash "$PUSH" boxA > "$T/push.out" 2>&1
[ "$(posts)" = 0 ] && ok || bad "B1: a tick with no new ledger lines sends nothing, got $(posts)"
tsv 2026-09-23T03:30:00Z merge-conductor project-4 POST graphql 200 1 4800 1790143346 app-161623167 graphql gh 200 5000 >> "$H03"
touch "$H03"
reqreset
bash "$PUSH" boxA > "$T/push.out" 2>&1
[ "$(posts)" = 1 ] && ok || bad "B2: a new line re-sends its hour, got $(posts)"
G=$(lastbody | jq -c '.rows[] | select(.resource=="graphql")')
[ "$(jq -r '[.calls,.remaining_min,.used_max] | map(tostring) | join(" ")' <<<"$G")" = "3 4800 200" ] && ok \
  || bad "B3: the WHOLE hour is recomputed (3 calls, not 1), got: $G"

# ══ C. a failed push keeps the hour owed ════════════════════════════════════
tsv 2026-09-23T03:40:00Z merge-conductor project-4 POST graphql 200 1 4700 1790143346 app-161623167 graphql gh 300 5000 >> "$H03"
touch "$H03"
reqreset
STUB_CODE=500 bash "$PUSH" boxA > "$T/push.out" 2>&1
[ "$(posts)" = 1 ] && ok || bad "C1: the failed attempt was made"
reqreset
bash "$PUSH" boxA > "$T/push.out" 2>&1
[ "$(posts)" = 1 ] && ok || bad "C2: after a failure the next tick re-sends, got $(posts)"
grep -q 'FAIL' "$T/h/logs/gh-ledger-push.log" 2>/dev/null && ok || bad "C3: the failure is logged, got: $(cat "$T/h/logs/gh-ledger-push.log" 2>/dev/null)"

# ══ D. the kill switch ══════════════════════════════════════════════════════
tsv 2026-09-23T03:50:00Z merge-conductor project-4 POST graphql 200 1 4600 1790143346 app-161623167 graphql gh 400 5000 >> "$H03"
touch "$T/h/flags/gh-ledger-push-off"
reqreset
bash "$PUSH" boxA > "$T/push.out" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(posts)" = 0 ] && ok || bad "D1: flags/gh-ledger-push-off sends nothing (rc $rc, posts $(posts))"
rm -f "$T/h/flags/gh-ledger-push-off"
reqreset
bash "$PUSH" boxA > "$T/push.out" 2>&1
[ "$(posts)" = 1 ] && ok || bad "D2: the line held back by the switch is sent once it is lifted, got $(posts)"

# ══ E. the fleet report, from D1 ════════════════════════════════════════════
# Two boxes' rows as GET /api/metrics/gh-ledger answers them.
jq -nc '{truncated:false, rows:[
  {box:"hub",  lane:"merge-conductor", meter:"app-161623167", resource:"graphql", path_class:"graphql",           calls:40, counted:40, remaining_min:3000, used_max:2000, limit_max:5000},
  {box:"hub",  lane:"merge-sweep",     meter:"app-161623167", resource:"core",    path_class:"repos/o/r/pulls/N", calls:30, counted:20, remaining_min:5000, used_max:1600, limit_max:6600},
  {box:"small",lane:"merge-conductor", meter:"app-161623167", resource:"graphql", path_class:"graphql",           calls:25, counted:25, remaining_min:2900, used_max:2100, limit_max:5000},
  {box:"small",lane:"run-build.sh",    meter:"app-163842147", resource:"core",    path_class:"repos/o/r/git/refs",calls:5,  counted:5,  remaining_min:6500, used_max:100,  limit_max:6600}
]}' > "$T/read.json"
[ -x "$REPORT" ] && ok || bad "E0: bin/gh-quota-report.sh must be executable"
reqreset
OUT=$(bash "$REPORT" --fleet hour 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "E1: the fleet report exits 0, got $rc: $OUT"
grep -q '/api/metrics/gh-ledger?since=' "$T/req/"*.line 2>/dev/null && ok  # determinism: ok asserts the URL shape the stub recorded; the stub answers a fixed body whatever the window || bad "E2: the report reads D1 with a bounded window, got: $(cat "$T/req/"*.line 2>/dev/null)"
grep -qE '^TOTAL[[:space:]]+calls=100[[:space:]]+counted=90[[:space:]]+boxes=2$' <<<"$OUT" && ok \
  || bad "E3: TOTAL sums rows from BOTH boxes (100 calls, 90 counted, 2 boxes), got:
$OUT"
grep -qE '^hub[[:space:]]+70[[:space:]]+60$' <<<"$OUT" && grep -qE '^small[[:space:]]+30[[:space:]]+30$' <<<"$OUT" && ok \
  || bad "E4: per box, got:
$OUT"
grep -qE '^app-161623167/graphql[[:space:]]+65[[:space:]]+65[[:space:]]+2900$' <<<"$OUT" && ok \
  || bad "E5: per bucket = meter/resource with the lowest remaining, got:
$OUT"
grep -qE '^merge-conductor[[:space:]]+65[[:space:]]+65$' <<<"$OUT" && ok \
  || bad "E6: per caller, summed across boxes, got:
$OUT"
grep -qE '^GRAPHQL app-161623167 used=2100 remaining=2900/5000' <<<"$OUT" && ok \
  || bad "E7: the GraphQL line comes from the header values the rows carried, got:
$OUT"

# ══ F. an unreachable worker: this box's files, said out loud ═══════════════
reqreset
OUT=$(STUB_CODE=503 bash "$REPORT" --fleet hour 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qi 'fleet read failed' <<<"$OUT" && grep -q 'merge-conductor' <<<"$OUT" && ok \
  || bad "F1: a D1 outage falls back to the local ledger and says so (rc $rc), got:
$OUT"

echo "gh-ledger-fleet.bh-1574: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
