#!/bin/bash
# tests/cost-rows-push-modes.bh-4007-test.sh — the cost-rows allow list
# (BH-3982) reaches every mode of bin/cost-rows-push.sh, and a run with no list
# says so once a day (BH-4007, slice 4 of BH-3982).
#
# Drives the real pusher over the real transport to a loopback worker:
#
#   A6  fail-open: no fleet-conf.sh sends every row, writes ONE
#       `allow list unavailable` line per UTC day (flag-gated), never ALERTS.
#   A7  --box (the pool reap) drops a fixture row, logs the same BH-3982 drop
#       line, keeps its stdout `pushed <n> (<m> dup)` byte-identical, writes no
#       fail-open line and leaves no temp file.
#   A8  --verify does not count a dropped row as owed and writes nothing.
#   K1  COST_ROWS_LANE_PROJECTS is a registered, settable string knob.
#   K2  the knob decides the lane names in --box mode too.
#   K3  the 377 env template carries the knob and the render is in sync.
# Run from anywhere: tests/cost-rows-push-modes.bh-4007-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------------------------------------------------------------------------
# A real loopback worker. One line per request: METHOD PATH BODY.
# ---------------------------------------------------------------------------
REQS="$T/requests.log"; : > "$REQS"
cat > "$T/server.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
LOG = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def _rec(self, body):
        with open(LOG, "a") as fh:
            fh.write("%s %s %s\n" % (self.command, self.path, body.replace("\n", "")))
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        self._rec(body)
        try:
            k = len(json.loads(body).get("rows", []))
        except Exception:
            k = 0
        b = json.dumps({"accepted": k, "inserted": k}).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self._rec("")
        k = int(os.environ.get("GET_ROWS") or 0)
        b = json.dumps({"cost_rows": [{"row_hash": "h%d" % i} for i in range(k)]}).encode()
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
GET_ROWS=7 python3 "$T/server.py" "$REQS" > "$T/port" 2>/dev/null &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null; __scratch_exit_trap' EXIT
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port" 2>/dev/null)
[ -n "$PORT" ] || { echo "FAIL: the loopback worker did not start"; echo "cost-rows-push-modes: $PASS pass, 1 fail"; exit 1; }
STUB="http://127.0.0.1:$PORT"
posts() { grep -c '^POST /api/metrics/cost-rows ' "$REQS" 2>/dev/null; }
body_projects() { # the projects in the Nth cost-row POST body
  grep '^POST /api/metrics/cost-rows ' "$REQS" | sed -n "${1}p" | cut -d' ' -f3- \
    | python3 -c 'import json,sys; print(" ".join(r["project"] for r in json.load(sys.stdin)["rows"]))'
}

# 26 columns, COST_ROW_HDR's order. Fixed literals only (determinism lint).
HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
row() { # row <project> <n>
  printf '2026-09-28T22:%02d:00Z,pool-cromford-815401a9e7e918,%s,eval,grok,grok-4,0,2,0,0,0,0,,api,,,,,,,,,,UNPRICED:no-usage,,\n' "$2" "$1"
}

# ---------------------------------------------------------------------------
# The scratch harness tree: the pusher, the client, the cost-row lib and the
# registry reader. FLEET_CONF is ALWAYS set, so this box's own fleet.conf
# never decides a case.
# ---------------------------------------------------------------------------
mkdir -p "$T/p/bin/lib/jobs" "$T/p/env" "$T/p/logs" "$T/p/state" "$T/p/locks" "$T/p/flags" "$T/tmp"
cp "$DIR/bin/cost-rows-push.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$T/p/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/p/bin/lib/jobs/"
cp "$DIR/bin/lib/cost-row.sh" "$DIR/bin/lib/env-path.sh" "$T/p/bin/lib/"
: > "$T/p/env/global.env"
printf '# fixture registry\ncromford example-org/cromford https://x.example - 0 hub\nproject-5 example-org/project-5 https://y.example - 1 hub\n' > "$T/fleet.conf"
: > "$T/empty.conf"
PCSV="$T/p/logs/cost.csv"; PCUR="$T/p/state/cost-rows-push.cursor"; PLOG="$T/p/logs/cost-rows-push.log"

push() { # push <fleet.conf> [args...] — the cron entry point
  local fc="$1"; shift
  ( unset HARNESS_TEST_SANDBOX
    export HARNESS="$T/p" JOBS_URL="$STUB" HARNESS_SECRET=s FLEET_CONF="$fc" TMPDIR="$T/tmp"
    bash "$T/p/bin/cost-rows-push.sh" "$@" > "$T/p/out" 2> "$T/p/err" )
}
drops() { grep -c 'dropped ' "$PLOG" 2>/dev/null; }
reap() { # reap <box> <csv> <cursor> — the pool reap entry point
  ( unset HARNESS_TEST_SANDBOX
    export HARNESS="$T/p" JOBS_URL="$STUB" HARNESS_SECRET=s FLEET_CONF="$T/fleet.conf" TMPDIR="$T/tmp"
    bash "$T/p/bin/cost-rows-push.sh" --box "$1" --csv "$2" --cursor "$3" > "$T/p/out" 2> "$T/p/err" )
}
NOALLOW='allow list unavailable (fleet-conf.sh --projects answered nothing) — not filtering'
noallow() { grep -c "$NOALLOW" "$PLOG" 2>/dev/null; }
noflags() { find "$T/p/flags" -name 'alerted-cost-rows-noallow-*' 2>/dev/null | wc -l | tr -dc '0-9'; }

# ===========================================================================
# A6. fail-open: no fleet-conf.sh, every row goes, one day line
# ===========================================================================
mv "$T/p/bin/fleet-conf.sh" "$T/fleet-conf.sh.bak"
: > "$REQS"; : > "$PLOG"; echo 0 > "$PCUR"
{ echo "$HDR"; row lproj 1; row cromford 2; } > "$PCSV"
push "$T/missing.conf" test-box; RC=$?
[ "$RC" = 0 ] && ok || bad "A6a: the pusher exited $RC: $(cat "$T/p/err")"
[ "$(posts)" = 1 ] && [ "$(body_projects 1)" = "lproj cromford" ] \
  && ok || bad "A6a: fail-open must send every row; posts=$(posts) carried '$(body_projects 1 2>/dev/null)'"
[ "$(noallow)" = 1 ] && ok || bad "A6b: expected one '$NOALLOW' line, log: $(cat "$PLOG")"
[ "$(noflags)" = 1 ] && ok || bad "A6b: expected one flags/alerted-cost-rows-noallow-* file, found $(noflags)"
[ -s "$T/p/logs/ALERTS.log" ] && bad "A6c: fail-open must not write ALERTS.log: $(cat "$T/p/logs/ALERTS.log")" || ok
[ "$(drops)" = 0 ] && ok || bad "A6c: fail-open must log no drop line, log: $(cat "$PLOG")"
: > "$REQS"
row project-5 3 >> "$PCSV"
push "$T/missing.conf" test-box
[ "$(posts)" = 1 ] && [ "$(body_projects 1)" = project-5 ] \
  && ok || bad "A6d: the second run must send the new row; posts=$(posts) carried '$(body_projects 1 2>/dev/null)'"
[ "$(noallow)" = 1 ] && ok || bad "A6d: a second run the same day must add no day line (have $(noallow))"
mv "$T/fleet-conf.sh.bak" "$T/p/bin/fleet-conf.sh"

# ===========================================================================
# A7. --box: the reap filters, logs the drop, keeps its stdout
# ===========================================================================
: > "$REQS"; : > "$PLOG"; rm -f "$T/p/flags"/alerted-cost-rows-noallow-*
{ echo "$HDR"; row lproj 1; row cromford 2; } > "$T/reap.csv"; echo 0 > "$T/reap.cur"
reap pool-x "$T/reap.csv" "$T/reap.cur"; RC=$?
[ "$RC" = 0 ] && ok || bad "A7a: --box exited $RC: $(cat "$T/p/err")"
[ "$(cat "$T/p/out")" = "pushed 1 (0 dup)" ] && ok || bad "A7b: --box stdout must be exactly 'pushed 1 (0 dup)', was '$(cat "$T/p/out")'"
[ "$(posts)" = 1 ] && [ "$(body_projects 1)" = cromford ] \
  && ok || bad "A7c: --box must send only cromford; posts=$(posts) carried '$(body_projects 1 2>/dev/null)'"
grep -q '^POST /api/metrics/cost-rows .*"box": "pool-x"' "$REQS" && ok || bad "A7c: the POST body must carry box pool-x: $(cat "$REQS")"
N7=$(grep -c 'dropped 1 row(s) whose project is not in fleet.conf or COST_ROWS_LANE_PROJECTS (lproj) — BH-3982' "$PLOG")
[ "$N7" = 1 ] && [ "$(drops)" = 1 ] && ok || bad "A7d: expected one --box drop line naming lproj, log: $(cat "$PLOG")"
[ "$(noallow)" = 0 ] && [ "$(noflags)" = 0 ] && ok || bad "A7e: a present list must write no fail-open line or flag, log: $(cat "$PLOG")"
LEFT=$(find "$T/tmp" -name 'cost-rows-drop.*' 2>/dev/null | wc -l | tr -dc '0-9')
[ "$LEFT" = 0 ] && ok || bad "A7f: $LEFT cost-rows-drop.* temp file(s) left under TMPDIR"

# ===========================================================================
# K2. the knob decides the lane names in --box mode
# ===========================================================================
: > "$REQS"; : > "$PLOG"
{ echo "$HDR"; row medic 1; row fleet 2; } > "$T/reap.csv"; echo 0 > "$T/reap.cur"
( export COST_ROWS_LANE_PROJECTS=fleet; reap pool-x "$T/reap.csv" "$T/reap.cur" )
[ "$(posts)" = 1 ] && [ "$(body_projects 1)" = fleet ] \
  && ok || bad "K2: with COST_ROWS_LANE_PROJECTS=fleet --box may send only fleet; posts=$(posts) carried '$(body_projects 1 2>/dev/null)'"

# ===========================================================================
# A8. --verify does not count a dropped row as owed
# ===========================================================================
: > "$REQS"; : > "$PLOG"; echo 0 > "$PCUR"
{ echo "$HDR"; i=1
  for p in cromford lproj project-5 gateproj fleet alert-triage responder medic rule-miner freeproj otherproj; do
    row "$p" "$i"; i=$((i+1)); done; } > "$PCSV"
push "$T/fleet.conf" test-box
: > "$PLOG"; F0=$(find "$T/p/flags" -type f | wc -l | tr -dc '0-9')
V=$( ( export HARNESS="$T/p" JOBS_URL="$STUB" HARNESS_SECRET=s FLEET_CONF="$T/fleet.conf" TMPDIR="$T/tmp"
       bash "$T/p/bin/cost-rows-push.sh" --verify test-box 2>&1 ) ); RC=$?
[ "$RC" = 0 ] && ok || bad "A8: --verify exited $RC: $V"
case "$V" in *data_rows=7*unpushed=0*db_rows=7*) ok ;; *) bad "A8: expected data_rows=7 unpushed=0 db_rows=7, got: $V" ;; esac
[ -s "$PLOG" ] && bad "A8: --verify must write no log line: $(cat "$PLOG")" || ok
[ "$(find "$T/p/flags" -type f | wc -l | tr -dc '0-9')" = "$F0" ] && ok || bad "A8: --verify must create no flag"

# ===========================================================================
# K1. the knob is registered; K3. its env template renders
# ===========================================================================
( cd "$DIR" && bin/lanes-build.sh --to "$T/lanes.json" ) > "$T/lb.out" 2>&1 || bad "K1: lanes-build --to failed: $(cat "$T/lb.out")"
K=$(jq -c '.lanes[]? // .[]? | select(.id=="cost-rows-push") | .knobs[] | select(.env=="COST_ROWS_LANE_PROJECTS")
          | [.type, .settable, .zero_means, .read_in, .default]' "$T/lanes.json" 2>/dev/null)
[ "$K" = '["string",true,null,"bin/lib/cost-row.sh","fleet alert-triage responder medic rule-miner greenfield trap-eval"]' ] \
  && ok || bad "K1: COST_ROWS_LANE_PROJECTS knob wrong or missing: '$K'"
grep -q '^#COST_ROWS_LANE_PROJECTS=' "$DIR/env-templates/lanes/377-cost-rows-allow-list.env.example" 2>/dev/null \
  && ok || bad "K3: env-templates/lanes/377-cost-rows-allow-list.env.example must carry #COST_ROWS_LANE_PROJECTS="
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/render-env-example.sh --check ) > "$T/re.out" 2>&1 \
  && ok || bad "K3: render-env-example.sh --check failed: $(cat "$T/re.out")"

echo "cost-rows-push-modes: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
