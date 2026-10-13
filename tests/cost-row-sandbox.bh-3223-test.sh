#!/bin/bash
# tests/cost-row-sandbox.bh-3223-test.sh — a test never writes a cost row into
# the production cost_rows table (BH-3223).
#
# About 750 `project=testproj` rows reached prod D1 from Fly pool machines in
# 48h: a suite run on the machine inherited HARNESS_SECRET and COST_ROWS_BOX, and
# tests/lib/scratch.sh left JOBS_URL unset, which bin/lib/jobs/req.sh defaults
# to the live worker. So bin/agent-call.sh's cost_row_emit POSTed every stub
# runner's row. This suite drives the real code against a loopback stub:
#
#   S1  scratch.sh leaves JOBS_URL EXPORTED and EMPTY ("no worker here"), and
#       drops the machine's HARNESS_SECRET and COST_ROWS_BOX, so a
#       child process can never fall back to the live worker.
#   E1  cost_row_emit under HARNESS_TEST_SANDBOX=1: row in the CSV, 0 requests.
#   E2  cost_row_emit of a `testproj` row, flag unset: row in the CSV, 0 requests.
#   E3  positive control, flag unset: real projects (including the near-misses
#       `testproject` and `TestProj`) still POST, one request each, so E1/E2's zero is real.
#   E4  the production entry point: bin/agent-call.sh with a stub runner, the
#       shape that produced the rows, sends nothing to /api/metrics/cost-rows.
#   P1  bin/cost-rows-push.sh under HARNESS_TEST_SANDBOX=1: rc 0, 0 requests,
#       cursor untouched, stderr names BH-3223.
#   P2  flag unset, one testproj + one real row: one request carrying only the
#       real row; cursor at the end.
#   P3  flag unset, only testproj rows: 0 requests, cursor still advances, and
#       --verify reports nothing owed.
#   P4  flag unset, two real rows: one request with both (regression guard).
# Run from anywhere: tests/cost-row-sandbox.bh-3223-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ===========================================================================
# S1. scratch.sh exports JOBS_URL empty
# ===========================================================================
S1=$(bash -c 'printf %s "${JOBS_URL+set}:${JOBS_URL:-}"')
[ "$S1" = "set:" ] \
  && ok || bad "S1: after sourcing scratch.sh a child must see JOBS_URL set and empty, saw '$S1' (unset defaults to the live worker)"
S1B=$(bash -c 'printf %s "${HARNESS_SECRET+set}:${COST_ROWS_BOX+set}"')
[ "$S1B" = ":" ] \
  && ok || bad "S1: after sourcing scratch.sh a child must see no HARNESS_SECRET and no COST_ROWS_BOX (CI has neither), saw '$S1B'"

# The shape the pool machine leaks: secret and box id in the environment.
export HARNESS_SECRET=s COST_ROWS_BOX=pool-cromford-test

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
[ -n "$PORT" ] || { echo "FAIL: the loopback worker did not start"; echo "cost-row-sandbox: $PASS pass, 1 fail"; exit 1; }
STUB="http://127.0.0.1:$PORT"
posts() { grep -c '^POST /api/metrics/cost-rows ' "$REQS" 2>/dev/null; }

# 26 columns, COST_ROW_HDR's order; shaped like the evidence rows.
HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id,guard_fp"
row() { # row <project> <n>
  printf '2026-09-27T13:%02d:00Z,pool-cromford-815401a9e7e918,%s,eval,grok,grok-4,0,2,0,0,0,0,,api,,,,,,,,,,UNPRICED:no-usage,,\n' "$2" "$1"
}

# ===========================================================================
# E1-E3. cost_row_emit, the real library over the real transport
# ===========================================================================
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks"
emit() { # emit <sandbox 0|1> <row> — in a subshell, so the flag never leaks
  ( export HARNESS="$T/h" JOBS_URL="$STUB"
    if [ "$1" = 1 ]; then export HARNESS_TEST_SANDBOX=1; else unset HARNESS_TEST_SANDBOX; fi
    # shellcheck source=/dev/null
    . "$DIR/bin/jobs-client.sh" && . "$DIR/bin/lib/cost-row.sh" || exit 1
    COST="$T/h/logs/cost.csv"
    cost_row_emit "$2" )
}

: > "$REQS"; : > "$T/h/logs/cost.csv"
R1=$(row project-2 1)
emit 1 "$R1"; RC=$?
[ "$RC" = 0 ] && ok || bad "E1: cost_row_emit returned $RC"
grep -qxF "$R1" "$T/h/logs/cost.csv" \
  && ok || bad "E1: the row must still be written to cost.csv under the sandbox flag"
[ "$(posts)" = 0 ] \
  && ok || bad "E1: HARNESS_TEST_SANDBOX=1 must send 0 cost-row requests, the stub got $(posts): $(cat "$REQS")"

: > "$REQS"; : > "$T/h/logs/cost.csv"
R2=$(row testproj 2)
emit 0 "$R2"
grep -qxF "$R2" "$T/h/logs/cost.csv" \
  && ok || bad "E2: a testproj row must still be written to cost.csv"
[ "$(posts)" = 0 ] \
  && ok || bad "E2: a testproj row must send 0 requests, the stub got $(posts): $(cat "$REQS")"

# BH-3982: cost_row_emit POSTs only fleet.conf projects, so the positive control
# names its projects in a fixture registry instead of the repo's fleet.conf.
printf '%s\n' project-2 testproject TestProj cromford project-2-os > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
: > "$REQS"; : > "$T/h/logs/cost.csv"
for p in project-2 testproject TestProj cromford; do emit 0 "$(row "$p" 3)"; done
[ "$(posts)" = 4 ] \
  && ok || bad "E3: real rows must still POST, one each; expected 4, the stub got $(posts) (is the transport broken? then E1/E2 prove nothing)"
for p in project-2 testproject TestProj cromford; do
  grep -q "\"project\": \"$p\"" "$REQS" && ok || bad "E3: no POST carried project $p"
done

# ===========================================================================
# E4. the production entry point: bin/agent-call.sh with a stub runner
# ===========================================================================
# A recording curl, not the loopback stub: JOBS_URL is left exactly as
# scratch.sh set it, and on a tree where scratch.sh leaves it UNSET that means
# the LIVE worker. A real curl there would repeat the very write this ticket is
# about. This one records the URL and never touches a network.
mkdir -p "$T/a/bin/lib/jobs" "$T/a/logs" "$T/a/locks" "$T/a/flags" "$T/a/state" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/a/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/a/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$T/a/bin/lib/"
CURLS="$T/curls.log"; : > "$CURLS"
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
printf '%s\n' "${!#}" >> "$CURL_SINK"
exit 7
CURL
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/claude" "$T/fakebin/billing-mode.sh" "$T/fakebin/timeout"
( export PATH="$T/fakebin:$PATH" HARNESS="$T/a" HOME="$T" CURL_SINK="$CURLS" HARNESS_TEST_SANDBOX=1 \
         CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json"
  bash "$DIR/bin/agent-call.sh" eval testproj claude-fable-5 60 "$T/a/out.txt" "hello" >/dev/null 2>&1 )
grep -q ',testproj,eval,' "$T/a/logs/cost.csv" 2>/dev/null \
  && ok || bad "E4: agent-call.sh did not write its testproj row to \$HARNESS/logs/cost.csv (did the stub runner run?)"
N4=$(grep -c '/api/metrics/cost-rows' "$CURLS" 2>/dev/null)
[ "$N4" = 0 ] \
  && ok || bad "E4: agent-call.sh under the sandbox sent $N4 cost-row request(s): $(grep '/api/metrics/cost-rows' "$CURLS" | sort -u | tr '\n' ' ')"

# ===========================================================================
# P1-P4. bin/cost-rows-push.sh, the real pusher over the real transport
# ===========================================================================
mkdir -p "$T/p/bin/lib/jobs" "$T/p/env" "$T/p/logs" "$T/p/state" "$T/p/locks" "$T/p/flags"
cp "$DIR/bin/cost-rows-push.sh" "$DIR/bin/jobs-client.sh" "$T/p/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/p/bin/lib/jobs/"
PCSV="$T/p/logs/cost.csv"; PCUR="$T/p/state/cost-rows-push.cursor"
push() { # push <sandbox 0|1> [args...] — stdout/stderr to $T/p/out, $T/p/err
  local sb="$1"; shift
  ( export HARNESS="$T/p" JOBS_URL="$STUB"
    if [ "$sb" = 1 ]; then export HARNESS_TEST_SANDBOX=1; else unset HARNESS_TEST_SANDBOX; fi
    bash "$T/p/bin/cost-rows-push.sh" "$@" > "$T/p/out" 2> "$T/p/err" )
}
body_projects() { # the projects in the Nth cost-row POST body
  grep '^POST /api/metrics/cost-rows ' "$REQS" | sed -n "${1}p" | cut -d' ' -f3- \
    | python3 -c 'import json,sys; print(" ".join(r["project"] for r in json.load(sys.stdin)["rows"]))'
}

# P1 — sandbox: refuse, cursor untouched
: > "$REQS"; { echo "$HDR"; row project-2 1; row project-2-os 2; } > "$PCSV"; echo 0 > "$PCUR"
push 1 test-box; RC=$?
[ "$RC" = 0 ] && ok || bad "P1: the pusher under the sandbox must exit 0, got $RC"
[ "$(posts)" = 0 ] \
  && ok || bad "P1: HARNESS_TEST_SANDBOX=1 must send 0 cost-row requests, the stub got $(posts)"
[ "$(cat "$PCUR")" = 0 ] && ok || bad "P1: the cursor moved to $(cat "$PCUR") under the sandbox"
grep -q 'BH-3223' "$T/p/err" && ok || bad "P1: stderr must name the refusal (BH-3223), got: $(cat "$T/p/err")"
: > "$REQS"; push 1 --box test-box --csv "$PCSV" --cursor "$PCUR"
[ "$(posts)" = 0 ] && ok || bad "P1: --box push mode under the sandbox sent $(posts) request(s)"

# P2 — a testproj row is dropped, the real row is sent
: > "$REQS"; { echo "$HDR"; row testproj 1; row project-2 2; } > "$PCSV"; echo 0 > "$PCUR"
push 0 test-box
[ "$(posts)" = 1 ] && ok || bad "P2: expected 1 request, the stub got $(posts)"
[ "$(body_projects 1)" = project-2 ] \
  && ok || bad "P2: the request must carry only the project-2 row, carried: '$(body_projects 1)'"
[ "$(cat "$PCUR")" = 3 ] && ok || bad "P2: cursor should be at line 3, is $(cat "$PCUR")"

# P3 — only testproj rows: nothing sent, the cursor still moves past them
: > "$REQS"; { echo "$HDR"; row testproj 1; row testproj 2; } > "$PCSV"; echo 0 > "$PCUR"
push 0 test-box
[ "$(posts)" = 0 ] && ok || bad "P3: a file of only testproj rows sent $(posts) request(s)"
[ "$(cat "$PCUR")" = 3 ] && ok || bad "P3: the cursor must advance past fixture rows (want 3, is $(cat "$PCUR")) or the pusher wedges"
push 0 --verify test-box --csv "$PCSV" --cursor "$PCUR"
grep -q 'data_rows=0 .*unpushed=0' "$T/p/out" \
  && ok || bad "P3: --verify must not count testproj rows as owed: $(cat "$T/p/out")"

# P4 — regression guard: real rows still go, in one request
: > "$REQS"; { echo "$HDR"; row project-2 1; row cromford 2; } > "$PCSV"; echo 0 > "$PCUR"
push 0 test-box
[ "$(posts)" = 1 ] && ok || bad "P4: expected 1 request, the stub got $(posts)"
[ "$(body_projects 1)" = "project-2 cromford" ] \
  && ok || bad "P4: the request must carry both real rows, carried: '$(body_projects 1)'"

echo "cost-row-sandbox: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
