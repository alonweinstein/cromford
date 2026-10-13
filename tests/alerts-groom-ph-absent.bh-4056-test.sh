#!/bin/bash
# tests/alerts-groom-ph-absent.bh-4056-test.sh — the groom resolves an open
# alert:ph-<key> console row whose condition pipeline-health no longer finds,
# and only on the word of a fresh, COMPLETE pass (BH-4056).
#
# pipeline-health touches state/health-active.txt at the START of every pass,
# so the file's mtime cannot say a pass finished. The pass now writes
# state/health-active.stamp after its epilogue's mv ({at,n,retract_ns}), and
# bin/ph_active.py only answers when that stamp is fresh and its n matches the
# file. bin/alerts-supersede.py (the groom's close-the-loop pass) runs the real
# script under --dry against a local http.server serving the fixture as
# GET /api/alerts/open. The stamp is written by the block extracted verbatim
# from bin/pipeline-health.sh, and every ph id by its own aid= line.
#
#   P1 the extracted stamp block writes {at,n,retract_ns} for the active file
#   P2 ph_id() equals pipeline-health's aid= line (':', '/', space, 130 bytes)
#   P3 every hold reason prints "ph-absent pass held: <reason>" and resolves nothing
#   P4 PH_ACTIVE_FRESH_MIN=0 / abc hold with "bad window"
#   G1 an absent retractable key's row resolves; a present key's row does not
#   G2 stamp 31 min old (window 30) -> untouched
#   G3 no stamp, active file just touched -> untouched
#   G4 stamp n != line count -> untouched; empty file with n:3 -> untouched
#   G5 a throttled namespace (costcap) and an alert:auto-* row -> not this pass's
#   G6 present keys with ':' '/' and >117 bytes -> their rows untouched
#   G7 ph_active.py missing -> rc 0, one stderr line, other passes still run
#
# Run from anywhere: tests/alerts-groom-ph-absent.bh-4056-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/bin" "$T/state" "$T/www/api/alerts"
cp "$DIR/bin/alerts-supersede.py" "$DIR/bin/alert_family.py" "$T/bin/"
cp "$DIR/bin/ph_active.py" "$T/bin/" 2>/dev/null || true
printf '#!/bin/bash\necho ts project-3\n' > "$T/bin/fleet-conf.sh"; chmod +x "$T/bin/fleet-conf.sh"

# The production code under test, extracted verbatim (D4): an empty extraction
# is a failure, never a vacuous pass (D3).
STAMP_BLOCK=$(sed -n '/^# >>> active stamp (BH-4056)/,/^# <<< active stamp/p' "$DIR/bin/pipeline-health.sh")
[ -n "$STAMP_BLOCK" ] && ok || bad "stamp block markers not found in bin/pipeline-health.sh"
AID_LINE=$(grep -m1 '^ *aid="ph-' "$DIR/bin/pipeline-health.sh" | sed 's/^ *//')
[ -n "$AID_LINE" ] && ok || bad "aid= line not found in alert()"
RNS_LINE=$(grep -m1 '^RETRACT_NS=' "$DIR/bin/pipeline-health.sh")
[ -n "$RNS_LINE" ] && ok || bad "RETRACT_NS= line not found"
eval "$RNS_LINE"
aid_of() { local key=$1 aid; eval "$AID_LINE"; printf '%s\n' "$aid"; }

# write_active <key>... — the active file as the epilogue leaves it (sort -u),
# then the stamp block run the way the epilogue runs it (after the mv).
write_active() {
  printf '%s\n' "$@" | sed '/^$/d' | sort -u > "$T/state/health-active.txt"
  ( H="$T"; ACTIVE="$T/state/health-active.txt"; FIRED="$T/state/health-fired.1"
    eval "$STAMP_BLOCK" )
}

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
( cd "$T/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 50); do
  python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:$PORT/')" 2>/dev/null && break
  sleep 0.1
done

NOWISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOURAGO=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
row() { # row <id> <akey> <line> [createdAt]
  jq -nc --arg i "$1" --arg k "$2" --arg l "$3" --arg c "${4:-$HOURAGO}" '{id:$i,akey:$k,line:$l,createdAt:$c}'
}
serve() { jq -s '{alerts: .}' > "$T/www/api/alerts/open"; }
run() { # run [bin-dir] — stdout; stderr to $T/err.txt; rc to $T/rc.txt
  ( export CONSOLE_URL="http://127.0.0.1:$PORT" HARNESS_SECRET=x
    python3 "${1:-$T/bin}/alerts-supersede.py" --dry ) 2>"$T/err.txt"
  echo $? > "$T/rc.txt"
}
ABS='condition absent from health-active.txt'

PX=$(aid_of 'stalepr:x'); PTS=$(aid_of 'stalepr:ts')
fixture_g() { # two stalepr rows, one absent (x) and one present (ts)
  { row X "alert:$PX" '[pipeline-health] x: harness PR(s) #1 open >12h awaiting merge'
    row S "alert:$PTS" '[pipeline-health] ts: harness PR(s) #2 open >12h awaiting merge'; } | serve
}

echo "--- P1: the stamp block records the completed pass"
write_active 'stalepr:ts' 'stuckqueue:p:x.json' 'tickloop:hub'
ST="$T/state/health-active.stamp"
if [ -s "$ST" ]; then
  N=$(jq -r .n "$ST"); AT=$(jq -r .at "$ST"); NS=$(jq -r .retract_ns "$ST")
  [ "$N" = 3 ] && ok || bad "P1: n=$N, want 3"
  D=$(( $(date +%s) - AT )); [ "$D" -ge 0 ] && [ "$D" -le 5 ] && ok || bad "P1: at is ${D}s off now"
  [ "$NS" = "$RETRACT_NS" ] && ok || bad "P1: retract_ns '$NS' is not pipeline-health's RETRACT_NS"
else
  bad "P1: no stamp written"
fi
[ -z "$(find "$T/state" -name '*.tmp')" ] && ok || bad "P1: a tmp file was left behind"
# The stamp follows the mv: an un-moved $FIRED.sorted means the active file is
# last pass's, and no stamp may vouch for it.
rm -f "$ST"; : > "$T/state/health-fired.1.sorted"
( H="$T"; ACTIVE="$T/state/health-active.txt"; FIRED="$T/state/health-fired.1"; eval "$STAMP_BLOCK" )
[ ! -e "$ST" ] && ok || bad "P1: stamp written although the epilogue mv did not happen"
rm -f "$T/state/health-fired.1.sorted"

echo "--- P2: ph_id() folds and truncates exactly as alert() does"
LONG="stalepr:$(printf 'a%.0s' $(seq 1 122))"
for K in 'stalepr:ts' 'stuckqueue:p:x.json' 'stalepr:a/b c' "$LONG"; do
  WANT=$(aid_of "$K")
  GOT=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import ph_active; print(ph_active.ph_id(sys.argv[2]))' "$T/bin" "$K" 2>&1)
  [ "$GOT" = "$WANT" ] && ok || bad "P2: ph_id('$K') = '$GOT', aid= says '$WANT'"
done
[ "${#LONG}" = 130 ] && ok || bad "P2: long key is ${#LONG} bytes"

echo "--- G1: an absent retractable key resolves; a present key does not"
write_active 'stalepr:ts'
fixture_g
OUT=$(run)
grep -q "^resolve X: $ABS (complete pass [0-9]*m ago, BH-4056)\$" <<<"$OUT" && ok || bad "G1: X not resolved as absent: $OUT $(cat "$T/err.txt")"
! grep -q '^resolve S:' <<<"$OUT" && ok || bad "G1: present row S resolved: $OUT"
grep -qx 'ph-absent resolve=1' <<<"$OUT" && ok || bad "G1: no count line: $OUT"
[ "$(cat "$T/rc.txt")" = 0 ] && ok || bad "G1: rc $(cat "$T/rc.txt")"
# n:0 is a real answer: a complete pass that found nothing.
write_active
OUT=$(run)
grep -q "^resolve S: $ABS" <<<"$OUT" && ok || bad "G1: empty complete pass did not resolve S: $OUT"

echo "--- G2: a stale stamp resolves nothing"
write_active 'stalepr:ts'
jq -c ".at = $(( $(date +%s) - 31*60 ))" "$ST" > "$ST.x" && mv "$ST.x" "$ST"
OUT=$(run)
! grep -qF "$ABS" <<<"$OUT" && ok || bad "G2: resolved on a stale stamp: $OUT"
grep -qx 'ph-absent pass held: stale: pass 31m ago > 30m' <<<"$OUT" && ok || bad "G2: no stale hold line: $OUT"
OUT=$(PH_ACTIVE_FRESH_MIN=40 run)
grep -q "^resolve X: $ABS" <<<"$OUT" && ok || bad "G2: window 40 from config did not admit a 31m stamp: $OUT"

echo "--- G3: no stamp — a just-touched active file is not a complete pass"
write_active 'stalepr:ts'; rm -f "$ST"; touch "$T/state/health-active.txt"
OUT=$(run)
! grep -qF "$ABS" <<<"$OUT" && ok || bad "G3: resolved with no stamp: $OUT"
grep -qx 'ph-absent pass held: no stamp' <<<"$OUT" && ok || bad "G3: no hold line: $OUT"

echo "--- G4: stamp and file disagree"
write_active 'stalepr:ts'
jq -c '.n = 2' "$ST" > "$ST.x" && mv "$ST.x" "$ST"
OUT=$(run)
! grep -qF "$ABS" <<<"$OUT" && ok || bad "G4: resolved on a count mismatch: $OUT"
grep -qx 'ph-absent pass held: active file has 1 keys, stamp says 2' <<<"$OUT" && ok || bad "G4: no mismatch hold line: $OUT"
write_active 'stalepr:ts' 'stalepr:y' 'tickloop:hub'; : > "$T/state/health-active.txt"
OUT=$(run)
! grep -qF "$ABS" <<<"$OUT" && ok || bad "G4: resolved on an emptied file: $OUT"
grep -qx 'ph-absent pass held: active file has 0 keys, stamp says 3' <<<"$OUT" && ok || bad "G4: no empty-file hold line: $OUT"

echo "--- P3: the remaining hold reasons"
write_active 'stalepr:ts'; echo 'not json' > "$ST"
OUT=$(run)
grep -qx 'ph-absent pass held: stamp unparseable' <<<"$OUT" && ok || bad "P3: unparseable: $OUT"
! grep -qF "$ABS" <<<"$OUT" && ok || bad "P3: resolved on an unparseable stamp: $OUT"
write_active 'stalepr:ts'; rm -f "$T/state/health-active.txt"
OUT=$(run)
grep -qx 'ph-absent pass held: active file missing' <<<"$OUT" && ok || bad "P3: missing file: $OUT"
write_active 'stalepr:ts'; jq -c '.retract_ns = ""' "$ST" > "$ST.x" && mv "$ST.x" "$ST"
OUT=$(run)
grep -qx 'ph-absent pass held: empty retract_ns' <<<"$OUT" && ok || bad "P3: empty retract_ns: $OUT"
! grep -qF "$ABS" <<<"$OUT" && ok || bad "P3: resolved with no namespace list: $OUT"

echo "--- P4: a bad window holds, never clamps"
write_active 'stalepr:ts'
for W in 0 abc -5; do
  OUT=$(PH_ACTIVE_FRESH_MIN=$W run)
  grep -qx "ph-absent pass held: bad window $W" <<<"$OUT" && ok || bad "P4: window '$W': $OUT"
  ! grep -qF "$ABS" <<<"$OUT" && ok || bad "P4: window '$W' resolved: $OUT"
done

echo "--- G5: throttled namespaces and non-ph rows are not this pass's"
write_active 'stalepr:ts'
PC=$(aid_of 'costcap:ts')
{ row C "alert:$PC" '[pipeline-health] ts: cost cap 90% used'
  row A alert:auto-aaaa-1111 '[pipeline-health] ts: queue row TK-9 stranded 3h'
  row S "alert:$PTS" '[pipeline-health] ts: harness PR(s) #2 open >12h awaiting merge'; } | serve
OUT=$(run)
! grep -q '^resolve C:' <<<"$OUT" && ok || bad "G5: throttled costcap row resolved: $OUT"
! grep -q "^resolve A: $ABS" <<<"$OUT" && ok || bad "G5: auto row resolved by this pass: $OUT"
grep -qx 'ph-absent resolve=0' <<<"$OUT" && ok || bad "G5: count: $OUT"

echo "--- G6: folded and truncated keys still match"
K1='stuckqueue:p:x.json'; K2='stalepr:a/b c'
write_active "$K1" "$K2" "$LONG"
{ row Q "alert:$(aid_of "$K1")" '[pipeline-health] queue p stuck'
  row R "alert:$(aid_of "$K2")" '[pipeline-health] a/b c aging'
  row L "alert:$(aid_of "$LONG")" '[pipeline-health] long key aging'; } | serve
OUT=$(run)
! grep -qE '^resolve (Q|R|L):' <<<"$OUT" && ok || bad "G6: a present folded key was resolved: $OUT"
grep -qx 'ph-absent resolve=0' <<<"$OUT" && ok || bad "G6: count: $OUT"

echo "--- G7: without ph_active the pass is skipped, the groom is not"
mkdir -p "$T/bin7"; cp "$T/bin/alerts-supersede.py" "$T/bin/alert_family.py" "$T/bin/fleet-conf.sh" "$T/bin7/"
write_active 'stalepr:ts'
{ row X "alert:$PX" '[pipeline-health] RESOLVED stalepr:x — condition no longer holds'
  row S "alert:$PTS" '[pipeline-health] ts: harness PR(s) #2 open >12h awaiting merge'; } | serve
OUT=$(run "$T/bin7")
[ "$(cat "$T/rc.txt")" = 0 ] && ok || bad "G7: rc $(cat "$T/rc.txt"): $(cat "$T/err.txt")"
[ "$(grep -c . "$T/err.txt")" = 1 ] && grep -q ph_active "$T/err.txt" && ok || bad "G7: want one ph_active stderr line: $(cat "$T/err.txt")"
grep -qx 'resolve X: informational / already declared settled' <<<"$OUT" && ok || bad "G7: the other passes did not run: $OUT"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
