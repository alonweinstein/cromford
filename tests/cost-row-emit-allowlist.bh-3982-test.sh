#!/bin/bash
# tests/cost-row-emit-allowlist.bh-3982-test.sh — the at-source cost row writer
# (cost_row_emit, once per agent call) refuses a row whose project is not in
# fleet.conf + the lane list (BH-3982, slice BH-4006). The row is still
# appended to cost.csv; only the immediate POST to /api/metrics/cost-rows is
# skipped. The */10 mirror (bin/cost-rows-push.sh, BH-4004) counts the drop.
#
#   A0  the base carries cost_row_allowed_projects (BH-4004), so A9d cannot pass
#       vacuously on a wrong base.
#   A9a a non-fleet project (`lproj`): row in cost.csv, 0 POSTs.
#   A9b a fleet project (`cromford`): 1 POST carrying it.
#   A9c a lane-name project (`medic`, the default COST_ROWS_LANE_PROJECTS): 1 POST.
#   A9d FAIL-OPEN: a tree with no bin/fleet-conf.sh filters nothing, so `lproj`
#       still POSTs.
#   A9e a direct _cost_row_emit_body caller with no COST_ROWS_ALLOW is
#       unchanged; with a list that excludes the project it exits 1, no output.
# Run from anywhere: tests/cost-row-emit-allowlist.bh-3982-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS_SECRET=s COST_ROWS_BOX=test-box

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
[ -n "$PORT" ] || { echo "FAIL: the loopback worker did not start"; echo "cost-row-emit-allowlist: $PASS pass, 1 fail"; exit 1; }
STUB="http://127.0.0.1:$PORT"
posts() { grep -c '^POST /api/metrics/cost-rows ' "$REQS" 2>/dev/null; }

row() { # row <project> <n>
  printf '2026-09-27T13:%02d:00Z,pool-cromford-815401a9e7e918,%s,eval,grok,grok-4,0,2,0,0,0,0,,api,,,,,,,,,,UNPRICED:no-usage,,\n' "$2" "$1"
}

# A harness tree: the lib and the siblings it looks up, copied so the lookups
# resolve inside the tree. mktree <dir> <with-fleet-conf 0|1>
mktree() {
  mkdir -p "$1/bin/lib/jobs" "$1/logs" "$1/state" "$1/flags" "$1/locks"
  cp "$DIR/bin/jobs-client.sh" "$1/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$1/bin/lib/jobs/"
  cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/cost-row.sh" "$1/bin/lib/"
  for f in box-id.sh lane-switch.sh; do
    [ -f "$DIR/bin/lib/$f" ] && cp "$DIR/bin/lib/$f" "$1/bin/lib/"
  done
  [ "$2" = 1 ] && cp "$DIR/bin/fleet-conf.sh" "$1/bin/"
  : > "$1/logs/cost.csv"
}
mktree "$T/p" 1
mktree "$T/q" 0
printf 'cromford\n' > "$T/fleet.conf"

emit() { # emit <tree> <row> — in a subshell, so nothing leaks
  ( unset HARNESS_TEST_SANDBOX COST_ROWS_LANE_PROJECTS
    export HARNESS="$1" JOBS_URL="$STUB" FLEET_CONF="${FC:-$T/fleet.conf}"
    # shellcheck source=/dev/null
    . "$1/bin/jobs-client.sh" && . "$1/bin/lib/cost-row.sh" || exit 1
    COST="$1/logs/cost.csv"
    cost_row_emit "$2" )
}

# A0 — the base carries BH-4004's list function
grep -q '^cost_row_allowed_projects()' "$DIR/bin/lib/cost-row.sh" \
  && ok || bad "A0: bin/lib/cost-row.sh has no cost_row_allowed_projects (the base lacks BH-4004; A9d would pass vacuously)"

# A9a — a non-fleet project is appended, not POSTed
: > "$REQS"
RA=$(row lproj 1)
emit "$T/p" "$RA"; RC=$?
[ "$RC" = 0 ] && ok || bad "A9a: cost_row_emit returned $RC, it must always return 0"
grep -qxF "$RA" "$T/p/logs/cost.csv" \
  && ok || bad "A9a: the lproj row must still be appended to cost.csv"
[ "$(posts)" = 0 ] \
  && ok || bad "A9a: a project outside fleet.conf must send 0 cost-row POSTs, the stub got $(posts): $(cat "$REQS")"

# A9b — a fleet project still POSTs
: > "$REQS"
emit "$T/p" "$(row cromford 2)"
[ "$(posts)" = 1 ] \
  && ok || bad "A9b: a fleet.conf project must POST once, the stub got $(posts) (is the transport broken? then A9a proves nothing)"
grep -q '"project": "cromford"' "$REQS" \
  && ok || bad "A9b: the POST must carry project cromford: $(cat "$REQS")"

# A9c — a lane-named row (default lane list) still POSTs
: > "$REQS"
emit "$T/p" "$(row medic 3)"
[ "$(posts)" = 1 ] \
  && ok || bad "A9c: a lane-name project (medic) must POST once, the stub got $(posts)"

# A9d — no fleet-conf.sh in the tree: fail open, no filter
: > "$REQS"
RD=$(row lproj 4)
FC="$T/missing.conf" emit "$T/q" "$RD"; RC=$?
[ "$RC" = 0 ] && ok || bad "A9d: cost_row_emit returned $RC with no fleet-conf.sh"
grep -qxF "$RD" "$T/q/logs/cost.csv" \
  && ok || bad "A9d: the row must be appended to cost.csv with no fleet-conf.sh"
[ "$(posts)" = 1 ] \
  && ok || bad "A9d: with no allow list the filter must fail open (1 POST), the stub got $(posts)"

# A9e — direct _cost_row_emit_body callers
OUT=$( unset COST_ROWS_ALLOW
       # shellcheck source=/dev/null
       . "$T/p/bin/lib/cost-row.sh" && _cost_row_emit_body "$(row lproj 9)" hub 1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "A9e: with COST_ROWS_ALLOW unset the body must build (rc 0), got $RC"
P=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rows"][0]["project"])' 2>/dev/null)
[ "$P" = lproj ] && ok || bad "A9e: with COST_ROWS_ALLOW unset rows[0].project must be lproj, got '$P' from: $OUT"
OUT=$( # shellcheck source=/dev/null
       . "$T/p/bin/lib/cost-row.sh" && COST_ROWS_ALLOW="cromford" _cost_row_emit_body "$(row lproj 9)" hub 1 ); RC=$?
[ "$RC" = 1 ] && ok || bad "A9e: a project outside COST_ROWS_ALLOW must exit 1, got $RC"
[ -z "$OUT" ] && ok || bad "A9e: a refused row must print no body, got: $OUT"

echo "cost-row-emit-allowlist: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
