#!/bin/bash
# tests/cost-rows-lane-backfill.bh-3220-test.sh — BH-3220: the one-shot
# bin/cost-rows-lane-backfill.sh refills lane_id / guard_fp from `raw` by
# re-POSTing the rows through the existing cost-rows route.
#
# DRIVEN, NOT GREPPED. The real script, through the real bin/jobs-client.sh and
# the real curl, against a python http.server stub on 127.0.0.1 that answers
# GET /api/metrics/cost-rows the way the worker does (since / until inclusive,
# newest first, limit clamped to 2000) and applies a POST the way the BH-3220
# conflict clause does (fill a NULL, never overwrite, inserted = rows changed).
#
#   B1  dry-run is the default: counts, per-box split, no POST at all
#   B2  --apply sends exactly the repairable rows, one body per box, each with
#       its STORED row_hash / line_no and the lane_id / guard_fp from raw
#   B3  a second run finds nothing to repair (idempotent)
#   B4  paging past one 2000-row page, and 2000-row bodies
#   B5  --max bounds the read and the run says the window was not fully read
#   B6  a POST that answers 500 stops the run: rc 1, no further POST
#   B7  a worker that repairs nothing (predates the clause) is rc 1, not success
#   B8  JOBS_URL empty: rc 2, no request; bad --max: rc 2
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV_PID=""
trap 'scratch_cleanup; [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "curl missing — skipping"; exit 0; }

BF="$DIR/bin/cost-rows-lane-backfill.sh"
mkdir -p "$T/h/logs" "$T/h/env" "$T/h/flags" "$T/h/state"
: > "$T/h/env/global.env"

# ── the stub worker ────────────────────────────────────────────────────────
cat > "$T/stub.py" <<'PY'
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
D = sys.argv[1]
state = os.path.join(D, "rows.json")      # the table
posts = os.path.join(D, "posts.jsonl")    # every POST body, verbatim
gets = os.path.join(D, "gets.log")        # every GET path
lock = threading.Lock()
def ctl(name, default):
    p = os.path.join(D, name)
    return open(p).read().strip() if os.path.exists(p) else default
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        with lock:
            open(gets, "a").write(self.path + "\n")
            rows = json.load(open(state))
        lim = min(max(int(q.get("limit") or 200), 1), 2000)
        if "since" in q: rows = [r for r in rows if r["ts"] >= q["since"]]
        if "until" in q: rows = [r for r in rows if r["ts"] <= q["until"]]
        rows.sort(key=lambda r: r["ts"], reverse=True)
        self.answer(200, {"cost_rows": rows[:lim], "as_of": "t"})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        with lock:
            open(posts, "a").write(json.dumps(body) + "\n")
            code = int(ctl("post_status", "200"))
            if code != 200:
                return self.answer(code, {"error": "stub says %d" % code})
            rows = json.load(open(state)); changed = 0
            if ctl("post_mode", "repair") == "repair":
                idx = {(r["box"], r["row_hash"]): r for r in rows}
                for x in body["rows"]:
                    r = idx.get((body["box"], x["row_hash"]))
                    if r is None: continue
                    c = False
                    for k in ("lane_id", "guard_fp"):
                        if r.get(k) is None and x.get(k) is not None:
                            r[k] = x[k]; c = True
                    changed += c
                json.dump(rows, open(state, "w"))
        self.answer(200, {"accepted": len(body["rows"]), "inserted": changed, "as_of": "t"})
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port.tmp"), "w").write(str(s.server_address[1]))
os.rename(os.path.join(D, "port.tmp"), os.path.join(D, "port"))
s.serve_forever()
PY

# fixture <dir> <kind>: writes <dir>/rows.json
#   small — seven rows covering every case
#   many  — 2101 repairable hub rows (two GET pages, two POST bodies)
fixture() {
  python3 - "$1" "$2" <<'PY'
import csv, hashlib, json, sys
d, kind = sys.argv[1], sys.argv[2]
H = lambda s: hashlib.sha256(s.encode()).hexdigest()
BASE = "p,review,claude,m,0,1,1,1,0,0,0.01,sub,fp,acct,,,,,,,"
def row(box, ts, tail, lane=None, gfp=None, n=1, raw=None, rh=None):
    line = "%s,h,%s,%s" % (ts, BASE, tail)
    # The fixture's own width, so an off-by-one here fails loudly rather than
    # reading as a backfill bug: tail "" is the 24-column writer, ",a" 25, ",a,b" 26.
    assert len(next(csv.reader([line]))) == 24 + tail.count(","), line
    return {"box": box, "row_hash": rh or H(line), "line_no": n, "ts": ts, "host": "h", "project": "p",
            "stage": "review", "runner": "claude", "model": "m", "rc": 0, "cost_usd": 0.01,
            "raw": line if raw is None else raw, "lane_id": lane, "guard_fp": gfp,
            "inserted_at": "2026-09-26T00:00:00Z"}
rows = []
if kind == "small":
    rows = [
        row("hub",   "2026-09-26T00:00:01Z", ",merge-conductor,mc:x", n=11),                    # repairable, both
        row("hub",   "2026-09-26T00:00:02Z", "", n=12),                                          # 24 fields: unrepairable
        row("hub",   "2026-09-26T00:00:03Z", ",oauth-refresh,fp3", lane="oauth-refresh", gfp="fp3", n=13),  # stamped
        row("small", "2026-09-26T00:00:04Z", ",review-autopilot,ra:4", n=14),                  # repairable, other box
        row("small", "2026-09-26T00:00:05Z", ",,", n=15),                                        # empty 25/26: unrepairable
        row("hub",   "2026-09-26T00:00:06Z", ",prompt-eval", n=16),                              # 25 fields: lane only
        row("hub",   "2026-09-26T00:00:07Z", ",x,y", n=17, rh="0" * 64),                         # raw does not verify
        row("hub",   "2026-09-20T00:00:00Z", ",old-lane,old", n=10),                             # before --since
    ]
else:
    for i in range(2101):
        rows.append(row("hub", "2026-09-26T%02d:%02d:%02dZ" % (i // 3600, i // 60 % 60, i % 60),
                        ",lane-%d,g%d" % (i, i), n=i + 1))
json.dump(rows, open(d + "/rows.json", "w"))
PY
}

# start <kind>: a fresh stub + table in $S
start() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; SRV_PID=""
  S=$(mktemp -d "$T/srv.XXXXXX")
  fixture "$S" "$1" || { echo "FAIL: fixture $1"; exit 1; }
  python3 "$T/stub.py" "$S" & SRV_PID=$!
  for _ in $(seq 1 50); do [ -s "$S/port" ] && break; sleep 0.1; done
  [ -s "$S/port" ] || { echo "FAIL: stub did not start"; exit 1; }
  PORT=$(cat "$S/port")
}
run() { # run <args...> — sets RC and OUT
  OUT=$(HARNESS="$T/h" JOBS_URL="http://127.0.0.1:$PORT" HARNESS_SECRET=test-secret JOBS_ALERT=0 \
        bash "$BF" "$@" 2>&1); RC=$?
}
nposts() { [ -f "$S/posts.jsonl" ] && wc -l < "$S/posts.jsonl" | tr -dc '0-9' || echo 0; }

# ── B1 dry-run ─────────────────────────────────────────────────────────────
start small
run
[ "$RC" = 0 ] && ok || bad "B1 dry-run rc=$RC: $OUT"
[ "$(nposts)" = 0 ] && ok || bad "B1 dry-run POSTed $(nposts) bodies"
case "$OUT" in *"would repair 3 of 7 scanned (by box: hub=2 small=1); unrepairable 3"*) ok ;; *) bad "B1 dry-run summary: $OUT" ;; esac
grep -q 'since=2026-09-25T00:00:00Z' "$S/gets.log" && ok || bad "B1 default --since not sent: $(cat "$S/gets.log")"

# ── B2 apply ───────────────────────────────────────────────────────────────
run --apply
[ "$RC" = 0 ] && ok || bad "B2 apply rc=$RC: $OUT"
case "$OUT" in *"scanned 7, repairable 3, unrepairable 3, sent 3, repaired 3"*) ok ;; *) bad "B2 apply summary: $OUT" ;; esac
res=$(python3 - "$S/posts.jsonl" "$S/rows.json" <<'PY'
import json, sys
posts = [json.loads(l) for l in open(sys.argv[1])]
table = json.load(open(sys.argv[2]))
errs = []
if [p["box"] for p in posts] != ["hub", "small"]:
    errs.append("bodies by box: %s" % [p["box"] for p in posts])
want = {("hub", 11): ("merge-conductor", "mc:x"), ("hub", 16): ("prompt-eval", None),
        ("small", 14): ("review-autopilot", "ra:4")}
got = {}
for p in posts:
    for r in p["rows"]:
        got[(p["box"], r["line_no"])] = (r.get("lane_id"), r.get("guard_fp"))
        orig = [t for t in table if t["box"] == p["box"] and t["line_no"] == r["line_no"]][0]
        if r["row_hash"] != orig["row_hash"]:
            errs.append("line %d sent row_hash %s, stored %s" % (r["line_no"], r["row_hash"], orig["row_hash"]))
if got != want:
    errs.append("sent %s, want %s" % (sorted(got.items()), sorted(want.items())))
stamped = {(t["box"], t["line_no"]): (t["lane_id"], t["guard_fp"]) for t in table}
if stamped[("hub", 13)] != ("oauth-refresh", "fp3"): errs.append("stamped row changed")
if stamped[("hub", 10)] != (None, None): errs.append("row before --since was touched")
print("; ".join(errs) or "OK")
PY
)
[ "$res" = OK ] && ok || bad "B2 apply bodies: $res"

# ── B3 idempotent ──────────────────────────────────────────────────────────
: > "$S/posts.jsonl"
run --apply
[ "$RC" = 0 ] && ok || bad "B3 re-run rc=$RC: $OUT"
case "$OUT" in *"repairable 0,"*"sent 0, repaired 0"*) ok ;; *) bad "B3 re-run summary: $OUT" ;; esac
[ "$(nposts)" = 0 ] && ok || bad "B3 re-run POSTed $(nposts) bodies"

# ── B4 paging and 2000-row bodies ──────────────────────────────────────────
start many
run --apply
[ "$RC" = 0 ] && ok || bad "B4 rc=$RC: $OUT"
case "$OUT" in *"scanned 2101, repairable 2101, unrepairable 0, sent 2101, repaired 2101"*) ok ;; *) bad "B4 summary: $OUT" ;; esac
[ "$(grep -c 'until=' "$S/gets.log")" -ge 1 ] && ok || bad "B4 never paged with until: $(cat "$S/gets.log")"
sizes=$(python3 -c 'import json,sys; print(" ".join(str(len(json.loads(l)["rows"])) for l in open(sys.argv[1])))' "$S/posts.jsonl")
[ "$sizes" = "2000 101" ] && ok || bad "B4 body sizes: '$sizes', want '2000 101'"

# ── B5 --max ───────────────────────────────────────────────────────────────
start many
run --max 5
[ "$RC" = 3 ] && ok || bad "B5 --max rc=$RC (want 3): $OUT"
case "$OUT" in *"NOT fully scanned"*"would repair 5 of 5 scanned"*) ok ;; *) bad "B5 --max summary: $OUT" ;; esac
grep -q 'limit=5&' "$S/gets.log" && ! grep -q 'until=' "$S/gets.log" && ok || bad "B5 --max did not bound the read: $(cat "$S/gets.log")"

# ── B6 a 500 stops the run ─────────────────────────────────────────────────
start small
echo 500 > "$S/post_status"
run --apply
[ "$RC" = 1 ] && ok || bad "B6 rc=$RC (want 1): $OUT"
[ "$(nposts)" = 1 ] && ok || bad "B6 POSTs after a 500: $(nposts), want 1"
case "$OUT" in *"POST failed"*"sent 0, repaired 0"*) ok ;; *) bad "B6 message: $OUT" ;; esac

# ── B7 a worker that repairs nothing ───────────────────────────────────────
start small
echo noop > "$S/post_mode"
run --apply
[ "$RC" = 1 ] && ok || bad "B7 rc=$RC (want 1): $OUT"
case "$OUT" in *"predates the BH-3220 repair clause"*) ok ;; *) bad "B7 message: $OUT" ;; esac

# ── B8 not configured, bad args ────────────────────────────────────────────
start small
OUT=$(HARNESS="$T/h" JOBS_URL="" HARNESS_SECRET=test-secret JOBS_ALERT=0 bash "$BF" --apply 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "B8 empty JOBS_URL rc=$RC: $OUT"
[ ! -f "$S/gets.log" ] && ok || bad "B8 empty JOBS_URL still sent a request"
run --max 0
[ "$RC" = 2 ] && ok || bad "B8 --max 0 rc=$RC"
run --max abc
[ "$RC" = 2 ] && ok || bad "B8 --max abc rc=$RC"

echo "cost-rows-lane-backfill: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
