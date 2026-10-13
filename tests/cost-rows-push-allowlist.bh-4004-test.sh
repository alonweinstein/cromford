#!/bin/bash
# tests/cost-rows-push-allowlist.bh-4004-test.sh — the cron cost-rows mirror
# never sends a row whose project is outside fleet.conf + the lane names
# (BH-4004, tracer for BH-3982).
#
# Prod cost_rows held 274 fixture rows (lproj, gateproj, freeproj, otherproj)
# from pool-cromford-* boxes. This suite drives the real
# bin/cost-rows-push.sh <box> over the real transport to a loopback stub:
#
#   U1  cost_row_allowed_projects prints the fleet projects then the 7 default
#       lane words, in order, and never a case near-miss.
#   U2  an empty fleet.conf, or no fleet-conf.sh at all: empty output, rc 0.
#   U3  set -u with COST_ROWS_LANE_PROJECTS unset: rc 0, no unbound variable.
#   A1  fleet + lane rows are sent in one POST; fixture rows are not.
#   A2  one log line counts and names the dropped projects.
#   A3  the cursor reaches the end; a second run sends nothing and logs no drop.
#   A4  an all-fixture csv: 0 POSTs, cursor at the end, one drop line.
#   A5  COST_ROWS_LANE_PROJECTS decides the lane names, not a literal.
#   A6  fail-open: an empty fleet.conf filters nothing and logs no drop.
#   A7  no cost-rows-drop.* temp file is left behind.
# Run from anywhere: tests/cost-rows-push-allowlist.bh-4004-test.sh   (exit 0 = all pass)
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
import json, sys
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
        b = b'{"cost_rows":[]}'
        self.send_response(200); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a):
        pass
s = HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
python3 "$T/server.py" "$REQS" > "$T/port" 2>/dev/null &
SRV_PID=$!
trap 'kill "$SRV_PID" 2>/dev/null; __scratch_exit_trap' EXIT
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT=$(cat "$T/port" 2>/dev/null)
[ -n "$PORT" ] || { echo "FAIL: the loopback worker did not start"; echo "cost-rows-push-allowlist: $PASS pass, 1 fail"; exit 1; }
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

# ===========================================================================
# U1-U3. cost_row_allowed_projects
# ===========================================================================
allowed() { # allowed <tree> <fleet.conf>
  ( unset COST_ROWS_LANE_PROJECTS
    export HARNESS="$1" FLEET_CONF="$2"
    # shellcheck source=/dev/null
    . "$1/bin/lib/cost-row.sh" || exit 9
    cost_row_allowed_projects )
}
U1=$(allowed "$T/p" "$T/fleet.conf"); RC=$?
[ "$RC" = 0 ] && ok || bad "U1: rc $RC"
[ "$(printf '%s' "$U1" | tr '\n' ' ')" = "cromford project-5 fleet alert-triage responder medic rule-miner greenfield trap-eval" ] \
  && ok || bad "U1: expected fleet projects + the 7 lane words, one per line, got: $(printf '%s' "$U1" | tr '\n' ' ')"
grep -qx 'Cromford' <<<"$U1" && bad "U1: a case near-miss must not be allowed" || ok

U2=$(allowed "$T/p" "$T/empty.conf"); RC=$?
[ "$RC" = 0 ] && [ -z "$U2" ] && ok || bad "U2: an empty fleet.conf must print nothing, rc 0 (fail-open); rc $RC, got '$U2'"
mkdir -p "$T/nofc/bin/lib"; cp "$DIR/bin/lib/cost-row.sh" "$T/nofc/bin/lib/"
U2B=$(allowed "$T/nofc" "$T/fleet.conf"); RC=$?
[ "$RC" = 0 ] && [ -z "$U2B" ] && ok || bad "U2: no fleet-conf.sh must print nothing, rc 0 (fail-open); rc $RC, got '$U2B'"

U3E=$( ( unset COST_ROWS_LANE_PROJECTS; export HARNESS="$T/p" FLEET_CONF="$T/fleet.conf"
         bash -uc '. "$HARNESS/bin/lib/cost-row.sh" && cost_row_allowed_projects >/dev/null' ) 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "U3: under set -u rc $RC: $U3E"
case "$U3E" in *unbound*) bad "U3: unbound variable under set -u: $U3E" ;; *) ok ;; esac

# ===========================================================================
# A1-A3. the production entry point drops the fixture projects
# ===========================================================================
: > "$REQS"; : > "$PLOG"; echo 0 > "$PCUR"
{ echo "$HDR"; i=1
  for p in cromford lproj project-5 gateproj fleet alert-triage responder medic rule-miner freeproj otherproj; do
    row "$p" "$i"; i=$((i+1)); done; } > "$PCSV"
push "$T/fleet.conf" test-box; RC=$?
[ "$RC" = 0 ] && ok || bad "A1: the pusher exited $RC: $(cat "$T/p/err")"
[ "$(posts)" = 1 ] && ok || bad "A1: expected exactly 1 POST, the stub got $(posts)"
[ "$(body_projects 1)" = "cromford project-5 fleet alert-triage responder medic rule-miner" ] \
  && ok || bad "A1: the POST must carry the fleet + lane rows in order, carried: '$(body_projects 1)'"
grep -Eq '"project": "(lproj|gateproj|freeproj|otherproj)"' "$REQS" \
  && bad "A1: a fixture project reached the worker: $(grep -Eo '"project": "(lproj|gateproj|freeproj|otherproj)"' "$REQS" | sort -u | tr '\n' ' ')" || ok

N2=$(grep -c 'dropped 4 row(s) whose project is not in fleet.conf or COST_ROWS_LANE_PROJECTS (freeproj gateproj lproj otherproj) — BH-3982' "$PLOG")
[ "$N2" = 1 ] && ok || bad "A2: expected exactly one drop line naming the 4 fixture projects, found $N2 in: $(cat "$PLOG")"
[ "$(drops)" = 1 ] && ok || bad "A2: expected one 'dropped' line in total, found $(drops)"

[ "$(cat "$PCUR")" = "$(wc -l < "$PCSV" | tr -dc '0-9')" ] \
  && ok || bad "A3: the cursor must reach the end ($(wc -l < "$PCSV")), is $(cat "$PCUR")"
: > "$REQS"
push "$T/fleet.conf" test-box
[ "$(posts)" = 0 ] && ok || bad "A3: a second run sent $(posts) POST(s)"
[ "$(drops)" = 1 ] && ok || bad "A3: a second run with nothing new must log no drop line (have $(drops))"

# ===========================================================================
# A4. only fixture rows: nothing sent, cursor still moves, one drop line
# ===========================================================================
: > "$REQS"; : > "$PLOG"; echo 0 > "$PCUR"
{ echo "$HDR"; row lproj 1; row gateproj 2; } > "$PCSV"
push "$T/fleet.conf" test-box
[ "$(posts)" = 0 ] && ok || bad "A4: an all-fixture csv sent $(posts) POST(s)"
[ "$(cat "$PCUR")" = 3 ] && ok || bad "A4: the cursor must pass the dropped rows (want 3, is $(cat "$PCUR"))"
[ "$(grep -c 'dropped 2 row(s) .*(gateproj lproj) — BH-3982' "$PLOG")" = 1 ] && [ "$(drops)" = 1 ] \
  && ok || bad "A4: expected one 'dropped 2 row(s) … (gateproj lproj)' line, log: $(cat "$PLOG")"

# ===========================================================================
# A5. the knob, not a literal, decides the lane names
# ===========================================================================
: > "$REQS"; : > "$PLOG"; echo 0 > "$PCUR"
{ echo "$HDR"; row medic 1; row fleet 2; } > "$PCSV"
( export COST_ROWS_LANE_PROJECTS=fleet; push "$T/fleet.conf" test-box )
[ "$(posts)" = 1 ] && [ "$(body_projects 1)" = fleet ] \
  && ok || bad "A5: with COST_ROWS_LANE_PROJECTS=fleet only the fleet row may go; posts=$(posts) carried '$(body_projects 1 2>/dev/null)'"
[ "$(grep -c 'dropped 1 row(s) .*(medic) — BH-3982' "$PLOG")" = 1 ] \
  && ok || bad "A5: expected one 'dropped 1 row(s) … (medic)' line, log: $(cat "$PLOG")"

# ===========================================================================
# A6. fail-open: an empty registry filters nothing
# ===========================================================================
: > "$REQS"; : > "$PLOG"; echo 0 > "$PCUR"
{ echo "$HDR"; row lproj 1; row cromford 2; } > "$PCSV"
push "$T/empty.conf" test-box
[ "$(posts)" = 1 ] && [ "$(body_projects 1)" = "lproj cromford" ] \
  && ok || bad "A6: an empty fleet.conf must filter nothing; posts=$(posts) carried '$(body_projects 1 2>/dev/null)'"
[ "$(drops)" = 0 ] && ok || bad "A6: fail-open must log no drop line, log: $(cat "$PLOG")"

# ===========================================================================
# A7. the per-run drop log never outlives the run
# ===========================================================================
LEFT=$(find "$T/tmp" -name 'cost-rows-drop.*' 2>/dev/null | wc -l | tr -dc '0-9')
[ "$LEFT" = 0 ] && ok || bad "A7: $LEFT cost-rows-drop.* temp file(s) left under TMPDIR"

echo "cost-rows-push-allowlist: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
