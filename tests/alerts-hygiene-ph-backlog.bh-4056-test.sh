#!/bin/bash
# tests/alerts-hygiene-ph-backlog.bh-4056-test.sh — the one-shot sweep of
# pipeline-health console rows still open under the pre-#3997 keys
# (health:<key>, alert:auto-* with a [pipeline-health] line) (BH-4056).
#
# The real bin/alerts-hygiene-ph-backlog.sh runs from a copy under $T/h/bin,
# against a tiny local server that serves GET /api/alerts/open and records
# every POST body. The active set is written by the stamp block extracted from
# bin/pipeline-health.sh, so "fresh, complete pass" means what the groom means.
#
#   H1 no flag = dry run: would-close lines, mode=dry-run, no POST, no file written
#   H2 inactive health:stalepr:old and an unmatched [pipeline-health] auto row -> would-close
#   H3 still-active health key, throttled namespace, auto row matching an active
#      ph row -> hold; an auto row that is not pipeline-health's -> not listed
#   H4 --apply -> exactly one POST of exactly the H2 set, closed (#3997) lines, one log line
#   H5 an alert:ph-* row is never listed and never posted
#   H6 stale stamp under --apply -> held, rc 3, no POST; POST 500 -> apply FAILED,
#      rc 1, no closed lines; bad or conflicting flags -> rc 2; no console env -> rc 2
#
# Run from anywhere: tests/alerts-hygiene-ph-backlog.bh-4056-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; S="$T/srv"
mkdir -p "$H/bin" "$H/state" "$S"
cp "$DIR/bin/alerts-hygiene-ph-backlog.sh" "$H/bin/" 2>/dev/null || true
cp "$DIR/bin/ph_active.py" "$DIR/bin/alert_family.py" "$H/bin/" 2>/dev/null || true
HYG="$H/bin/alerts-hygiene-ph-backlog.sh"
[ -f "$HYG" ] && ok || bad "bin/alerts-hygiene-ph-backlog.sh does not exist"

STAMP_BLOCK=$(sed -n '/^# >>> active stamp (BH-4056)/,/^# <<< active stamp/p' "$DIR/bin/pipeline-health.sh")
[ -n "$STAMP_BLOCK" ] && ok || bad "stamp block markers not found in bin/pipeline-health.sh"
AID_LINE=$(grep -m1 '^ *aid="ph-' "$DIR/bin/pipeline-health.sh" | sed 's/^ *//')
eval "$(grep -m1 '^RETRACT_NS=' "$DIR/bin/pipeline-health.sh")"
aid_of() { local key=$1 aid; eval "$AID_LINE"; printf '%s\n' "$aid"; }
write_active() {
  printf '%s\n' "$@" | sed '/^$/d' | sort -u > "$H/state/health-active.txt"
  ( H="$H"; ACTIVE="$H/state/health-active.txt"; FIRED="$H/state/health-fired.1"
    eval "$STAMP_BLOCK" )
}

cat > "$S/srv.py" <<'PY'
import http.server, os, sys
D = sys.argv[2]
class Q(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        b = open(os.path.join(D, "open.json"), "rb").read()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        with open(os.path.join(D, "posts.jsonl"), "ab") as f:
            f.write(body + b"\n")
        code = 500 if os.path.exists(os.path.join(D, "fail")) else 200
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"ok":true}' if code == 200 else b'{"error":"boom"}')
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), Q).serve_forever()
PY
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$S/srv.py" "$PORT" "$S" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
echo '{"alerts":[]}' > "$S/open.json"
for _ in $(seq 1 50); do
  python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:$PORT/api/alerts/open')" 2>/dev/null && break
  sleep 0.1
done

HOURAGO=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)
row() { jq -nc --arg i "$1" --arg k "$2" --arg l "$3" --arg c "$HOURAGO" '{id:$i,akey:$k,line:$l,createdAt:$c}'; }
serve() { jq -s '{alerts: .}' > "$S/open.json"; }
hyg() { # hyg [flags] — stdout+stderr; rc to $T/rc.txt
  ( export HARNESS="$H" CONSOLE_URL="http://127.0.0.1:$PORT" HARNESS_SECRET=x
    bash "$HYG" "$@" ) 2>&1
  echo $? > "$T/rc.txt"
}
rc() { cat "$T/rc.txt"; }
posts() { [ -f "$S/posts.jsonl" ] && grep -c . "$S/posts.jsonl" || echo 0; }

SP='[pipeline-health] ts: harness PR(s) %s open >12h awaiting merge — built work aging into the next watchdog owed-tickets alert'
# shellcheck disable=SC2059
L1=$(printf "$SP" '#50'); L2=$(printf "$SP" '#50,#51')
PTS=$(aid_of 'stalepr:ts')
write_active 'stalepr:ts' 'tickloop:hub'
{ row 1 'health:stalepr:old' '[pipeline-health] old: harness PR(s) #9 open >12h awaiting merge'
  row 2 'alert:auto-aaaa-1111' '[pipeline-health] ts: queue row TK-9 stranded 3h'
  row 3 'health:stalepr:ts' "$L1"
  row 4 'health:costcap:x' '[pipeline-health] x: cost cap 90% used'
  row 5 'alert:auto-bbbb-2222' "$L1"
  row 6 'alert:auto-cccc-3333' '[medic] ts: build TK-4 failed twice'
  row 7 "alert:$PTS" "$L2"
  row 8 'auto-dddd-4444' '[pipeline-health] hub: tick loop stalled 40m'; } | serve
CLOSE_SET='1 2 8'

echo "--- H1: the default is a dry run that writes nothing"
touch "$T/marker"; sleep 1
OUT=$(hyg)
[ "$(rc)" = 0 ] && ok || bad "H1: rc $(rc): $OUT"
grep -q '^would-close ' <<<"$OUT" && ok || bad "H1: no would-close lines: $OUT"
grep -qE '^legacy=[0-9]+ close=[0-9]+ hold=[0-9]+ mode=dry-run$' <<<"$OUT" && ok || bad "H1: no dry-run summary: $OUT"
[ "$(posts)" = 0 ] && ok || bad "H1: the dry run POSTed: $(cat "$S/posts.jsonl")"
NEW=$(find "$H" -newer "$T/marker" -type f)
[ -z "$NEW" ] && ok || bad "H1: the dry run wrote files: $NEW"
! grep -q '^closed ' <<<"$OUT" && ok || bad "H1: a dry run claimed closed rows: $OUT"

echo "--- H2: inactive legacy rows would close"
grep -q '^would-close 1 health:stalepr:old ' <<<"$OUT" && ok || bad "H2: inactive health key not closable: $OUT"
grep -q '^would-close 2 alert:auto-aaaa-1111 ' <<<"$OUT" && ok || bad "H2: unmatched auto row not closable: $OUT"
grep -q '^would-close 8 auto-dddd-4444 ' <<<"$OUT" && ok || bad "H2: bare auto- key not closable: $OUT"
grep -qx 'legacy=6 close=3 hold=3 mode=dry-run' <<<"$OUT" && ok || bad "H2: summary counts: $OUT"

echo "--- H3: still-active, throttled and foreign rows are not closed"
grep -q '^hold 3 health:stalepr:ts (still active)' <<<"$OUT" && ok || bad "H3: active health key not held: $OUT"
grep -q '^hold 4 health:costcap:x (throttled check, cannot judge)' <<<"$OUT" && ok || bad "H3: throttled key not held: $OUT"
grep -q "^hold 5 alert:auto-bbbb-2222 (still active as alert:$PTS)" <<<"$OUT" && ok || bad "H3: auto row of an active ph shape not held: $OUT"
! grep -qE '^(would-close|closed|hold) 6 ' <<<"$OUT" && ok || bad "H3: a non-pipeline-health auto row was listed: $OUT"

echo "--- H5: an alert:ph-* row is never legacy"
! grep -qE '^(would-close|closed|hold) 7 ' <<<"$OUT" && ok || bad "H5: the stable ph row was listed: $OUT"

echo "--- H4: --apply posts exactly the close set, once"
OUT=$(hyg --apply)
[ "$(rc)" = 0 ] && ok || bad "H4: rc $(rc): $OUT"
[ "$(posts)" = 1 ] && ok || bad "H4: want one POST, got $(posts)"
GOT=$(jq -r '.ids[]' "$S/posts.jsonl" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//')
[ "$GOT" = "$CLOSE_SET" ] && ok || bad "H4: posted ids '$GOT', want '$CLOSE_SET'"
for i in $CLOSE_SET; do
  grep -q "^closed $i .*(superseded by stable-key alerts (#3997))" <<<"$OUT" && ok || bad "H4: no closed line for $i: $OUT"
done
grep -qx 'legacy=6 close=3 hold=3 mode=apply' <<<"$OUT" && ok || bad "H4: summary: $OUT"
[ "$(grep -c 'hygiene ph-backlog' "$H/logs/alerts-groom.log" 2>/dev/null)" = 1 ] && ok || bad "H4: want one groom-log line: $(cat "$H/logs/alerts-groom.log" 2>/dev/null)"
! grep -qx 7 <<<"$(jq -r '.ids[]' "$S/posts.jsonl")" && ok || bad "H5: the ph row was posted"
! grep -qxE '3|4|5|6' <<<"$(jq -r '.ids[]' "$S/posts.jsonl")" && ok || bad "H4: a held or foreign row was posted"

echo "--- H6: holds, failures and bad flags"
rm -f "$S/posts.jsonl"
ST="$H/state/health-active.stamp"
jq -c ".at = $(( $(date +%s) - 31*60 ))" "$ST" > "$ST.x" && mv "$ST.x" "$ST"
OUT=$(hyg --apply)
[ "$(rc)" = 3 ] && ok || bad "H6: stale stamp rc $(rc), want 3: $OUT"
grep -q '^held: stale: pass 31m ago > 30m' <<<"$OUT" && ok || bad "H6: no held line: $OUT"
[ "$(posts)" = 0 ] && ok || bad "H6: POSTed on a stale stamp"
! grep -qE '^(closed|would-close) ' <<<"$OUT" && ok || bad "H6: listed closes while held: $OUT"

write_active 'stalepr:ts' 'tickloop:hub'
touch "$S/fail"
OUT=$(hyg --apply)
[ "$(rc)" = 1 ] && ok || bad "H6: POST 500 rc $(rc), want 1: $OUT"
grep -q '^apply FAILED: ' <<<"$OUT" && ok || bad "H6: no apply FAILED line: $OUT"
! grep -q '^closed ' <<<"$OUT" && ok || bad "H6: claimed closed rows on a failed POST: $OUT"
rm -f "$S/fail"

for F in --bogus "--apply --dry-run"; do
  rm -f "$S/posts.jsonl"
  # shellcheck disable=SC2086
  OUT=$(hyg $F)
  [ "$(rc)" = 2 ] && ok || bad "H6: flags '$F' rc $(rc), want 2: $OUT"
  [ "$(posts)" = 0 ] && ok || bad "H6: flags '$F' POSTed"
done
OUT=$( ( export HARNESS="$H"; unset CONSOLE_URL HARNESS_SECRET; bash "$HYG" ) 2>&1 ); R=$?
[ "$R" = 2 ] && ok || bad "H6: no console env rc $R, want 2: $OUT"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
