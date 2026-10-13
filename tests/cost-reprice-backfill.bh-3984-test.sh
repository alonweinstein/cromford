#!/bin/bash
# tests/cost-reprice-backfill.bh-3984-test.sh — BH-3984: the one-off, human-run
# bin/cost-reprice-backfill.sh reprices historic grok rows and blank rows with
# tokens from cost_price_tokens, and only ever writes a SQL file.
#
# DRIVEN, NOT GREPPED. The real script, through the real bin/jobs-client.sh and
# the real curl, against a python http.server stub on 127.0.0.1 that answers
# GET /api/metrics/cost-rows the way the worker does (since / until inclusive,
# newest first, limit clamped to 2000). The SQL it writes is applied to a local
# sqlite copy of the stub's rows.
#
#   BF1 dry run: counts and totals printed, no file written, the stub saw GETs only
#   BF2 blank rows WITHOUT tokens are listed by runner|stage and are not candidates
#   BF3 negatives: a claude row with dollars, a grok row within $0.005, an
#       unpriceable model, a no-token rc!=0 row -> no UPDATE
#   BF4 --sql: one guarded UPDATE per candidate, quotes escaped, the wrangler
#       command in the header; applied to sqlite it fixes exactly the candidates,
#       a second apply changes 0 rows, and a re-run after the fix finds none
#   BF5 two pages walked; --max smaller than the window -> rc 3, "NOT fully read"
#   BF6 no JOBS_URL -> rc 2; a 500 on GET -> rc 1 and no SQL file left behind
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/cost-reprice-backfill.bh-3984-test.sh
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
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

BF="$DIR/bin/cost-reprice-backfill.sh"
mkdir -p "$T/h/logs" "$T/h/env" "$T/h/flags" "$T/h/state"
: > "$T/h/env/global.env"
cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "grok-4.6": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7, "cache_write": null, "cliff_tokens": 200000},
  "deepseek/deepseek-v4-flash": {"prompt": 1e-7, "completion": 4e-7, "cache_read": 1e-8, "cache_write": null},
  "claude-x": {"prompt": 0.000005, "completion": 0.000025, "cache_read": 5e-7, "cache_write": 0.00000625, "cache_write_1h": 0.00001}
}}
EOF

# ── the stub worker ────────────────────────────────────────────────────────
cat > "$T/stub.py" <<'PY'
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
D = sys.argv[1]
state = os.path.join(D, "rows.json")
reqs = os.path.join(D, "reqs.log")        # every request: METHOD path
lock = threading.Lock()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def answer(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
        with lock:
            open(reqs, "a").write("GET " + self.path + "\n")
            rows = json.load(open(state))
        if os.path.exists(os.path.join(D, "get_500")):
            return self.answer(500, {"error": "stub says 500"})
        lim = min(max(int(q.get("limit") or 200), 1), 2000)
        if "since" in q: rows = [r for r in rows if r["ts"] >= q["since"]]
        if "until" in q: rows = [r for r in rows if r["ts"] <= q["until"]]
        rows.sort(key=lambda r: r["ts"], reverse=True)
        self.answer(200, {"cost_rows": rows[:lim], "as_of": "t"})
    def other(self):
        with lock:
            open(reqs, "a").write(self.command + " " + self.path + "\n")
        self.answer(405, {"error": "read-only stub"})
    do_POST = do_PUT = do_PATCH = do_DELETE = other
s = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(D, "port.tmp"), "w").write(str(s.server_address[1]))
os.rename(os.path.join(D, "port.tmp"), os.path.join(D, "port"))
s.serve_forever()
PY

# fixture <dir> <kind>: writes <dir>/rows.json
#   small — every case once
#   many  — 2101 blank deepseek rows with tokens (two GET pages)
fixture() {
  python3 - "$1" "$2" <<'PY'
import json, sys
d, kind = sys.argv[1], sys.argv[2]
def row(n, box, ts, runner, model, stage, rc, i, o, cr, cw, usd, note=None, result_usd=None):
    return {"box": box, "row_hash": "h%04d" % n, "line_no": n, "ts": ts, "stage": stage,
            "runner": runner, "model": model, "rc": rc, "input_toks": i, "output_toks": o,
            "cache_read": cr, "cache_write": cw, "cost_usd": usd, "result_usd": result_usd,
            "note": note, "raw": "verbatim-%d" % n}
rows = []
if kind == "small":
    rows = [
        # grok, vendor ticks recorded: reprice 0.289 (a quote in the box name)
        row(1, "o'box", "2026-09-22T00:00:01Z", "grok", "grok-4.6", "triage", 0, 120000, 4000, 50000, None, 0.05, result_usd=0.05),
        # grok above the cliff, a stored figure that only repr() prints back exactly
        row(2, "hub", "2026-09-22T00:00:02Z", "grok", "grok-4.6", "triage", 0, 260000, 4000, 40000, None, 0.43521519999999997),
        # blank with tokens: reprice 1000*1e-7 + 200*4e-7 + 300*1e-8 = 0.000183
        row(3, "pool-project-4-1", "2026-09-22T00:00:03Z", "openrouter", "deepseek/deepseek-v4-flash", "plan", 0, 1000, 200, 300, None, None, note="UNPRICED:no-price:deepseek/deepseek-v4-flash"),
        # blank claude with tokens and a 1h cache: 10*5e-6 + 100*25e-6 + 1000*1e-5 = 0.01255
        row(4, "hub", "2026-09-22T00:00:04Z", "claude", "claude-x", "execute", 0, 10, 100, None, 1000, None, note="x;cache_ttl=1h"),
        # NEGATIVES
        row(5, "hub", "2026-09-22T00:00:05Z", "claude", "claude-x", "plan", 0, 10, 100, 0, 0, 0.9, result_usd=0.9),          # claude with dollars
        row(6, "hub", "2026-09-22T00:00:06Z", "grok", "grok-4.6", "triage", 0, 1000, 0, 0, None, 0.003),                    # within $0.005 of 0.002
        row(7, "hub", "2026-09-22T00:00:07Z", "openrouter", "mystery/x", "review", 0, 1000, 10, None, None, None),          # unpriceable
        row(8, "hub", "2026-09-22T00:00:08Z", "grok", "grok-4.7", "triage", 1, None, None, None, None, None),               # no tokens, rc 1
        row(9, "hub", "2026-09-22T00:00:09Z", "openrouter", "deepseek/deepseek-v4-flash", "plan", 1, None, None, None, None, None),
        row(10, "hub", "2026-09-22T00:00:10Z", "openrouter", "deepseek/deepseek-v4-flash", "plan", 1, None, None, None, None, None),
        row(11, "hub", "2026-09-20T00:00:00Z", "grok", "grok-4.6", "triage", 0, 120000, 4000, 50000, None, 0.05),          # before --since
    ]
else:
    for n in range(2101):
        rows.append(row(n, "pool-x", "2026-09-22T%02d:%02d:%02dZ" % (n // 3600, n // 60 % 60, n % 60),
                        "openrouter", "deepseek/deepseek-v4-flash", "plan", 0, 1000, 200, 300, None, None))
json.dump(rows, open(d + "/rows.json", "w"))
PY
}

start() { # start <kind>: a fresh stub + table in $S
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; SRV_PID=""
  S=$(mktemp -d "$T/srv.XXXXXX")
  fixture "$S" "$1" || { echo "FAIL: fixture $1"; exit 1; }
  python3 "$T/stub.py" "$S" & SRV_PID=$!
  for _ in $(seq 1 50); do [ -s "$S/port" ] && break; sleep 0.1; done
  [ -s "$S/port" ] || { echo "FAIL: stub did not start"; exit 1; }
  PORT=$(cat "$S/port")
}
run() { # run <args...> — sets RC and OUT
  OUT=$(cd "$T" && HARNESS="$T/h" JOBS_URL="http://127.0.0.1:$PORT" HARNESS_SECRET=test-secret JOBS_ALERT=0 \
        MODEL_PRICES="$T/prices.json" bash "$BF" "$@" 2>&1); RC=$?
}
has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }

# ── BF1 dry run ────────────────────────────────────────────────────────────
start small
BEFORE=$(cd "$T" && find . -newer "$S/port" -type f | grep -v '^./srv' | sort)
run
[ "$RC" = 0 ] && ok || bad "BF1 dry-run rc=$RC: $OUT"
has "scanned 10 rows" && ok || bad "BF1 must scan the 10 rows since --since: $OUT"
has "candidates 4: 2 grok rows with a vendor figure, 2 blank rows with tokens" && ok || bad "BF1 candidate counts: $OUT"
has "candidate grok|grok-4.6|triage 2" && ok || bad "BF1 candidates by runner|model|stage: $OUT"
has "candidate openrouter|deepseek/deepseek-v4-flash|plan 1" && ok || bad "BF1 the blank deepseek row: $OUT"
has "candidate claude|claude-x|execute 1" && ok || bad "BF1 the blank claude row: $OUT"
# recorded 0.05 + 0.4352152; repriced 0.289 + 1.128 + 0.000183 + 0.01255
has 'recorded $0.485215 on the 2 grok candidates' && ok || bad "BF1 recorded total: $OUT"
has 'repriced $1.429733 on all 4' && ok || bad "BF1 repriced total (1h cache_write rate included): $OUT"
has "dry run: nothing written" && ok || bad "BF1 must say it wrote nothing: $OUT"
grep -q . <<<"$(grep -v '^GET ' "$S/reqs.log")" && bad "BF1 a dry run sent a non-GET: $(grep -v '^GET ' "$S/reqs.log")" || ok
grep -q 'since=2026-09-21T00:00:00Z' "$S/reqs.log" && ok || bad "BF1 default --since not sent: $(cat "$S/reqs.log")"
AFTER=$(cd "$T" && find . -newer "$S/port" -type f | grep -v '^./srv' | sort)
[ "$BEFORE" = "$AFTER" ] && ok || bad "BF1 a dry run wrote a file: $AFTER"

# ── BF2 blank rows without tokens ──────────────────────────────────────────
has "blank cost_usd rows WITHOUT tokens, left blank: 3" && ok || bad "BF2 blank no-token count: $OUT"
has "blank-no-tokens openrouter|plan 2" && ok || bad "BF2 by runner|stage (openrouter plan): $OUT"
has "blank-no-tokens grok|triage 1" && ok || bad "BF2 by runner|stage (grok triage): $OUT"

# ── BF3 negatives (summary side) ───────────────────────────────────────────
has 'within $0.005 of their reprice: 1' && ok || bad "BF3 the near grok row must be left alone: $OUT"
has "unpriceable 1 unpriceable:mystery/x=1" && ok || bad "BF3 the unpriceable model must be counted and named: $OUT"

# ── BF4 --sql ──────────────────────────────────────────────────────────────
run --sql "$T/fix.sql"
[ "$RC" = 0 ] && ok || bad "BF4 --sql rc=$RC: $OUT"
has "wrote 4 UPDATE statements to $T/fix.sql" && ok || bad "BF4 must report 4 statements: $OUT"
grep -q . <<<"$(grep -v '^GET ' "$S/reqs.log")" && bad "BF4 --sql sent a non-GET: $(grep -v '^GET ' "$S/reqs.log")" || ok
[ "$(grep -c '^UPDATE ' "$T/fix.sql")" = 4 ] && ok || bad "BF4 one UPDATE per candidate: $(cat "$T/fix.sql")"
grep -q 'npx wrangler d1 execute harness-jobs --remote --file=' "$T/fix.sql" && ok || bad "BF4 the header must name the wrangler apply"
grep -qF "WHERE box = 'o''box' AND row_hash = 'h0001' AND cost_usd = 0.05;" "$T/fix.sql" && ok || bad "BF4 grok guard + quote escaping: $(grep h0001 "$T/fix.sql")"
grep -qF "SET cost_usd = 1.128000 WHERE box = 'hub' AND row_hash = 'h0002' AND cost_usd = 0.43521519999999997;" "$T/fix.sql" && ok || bad "BF4 the exact stored double in the guard: $(grep h0002 "$T/fix.sql")"
grep -qF "row_hash = 'h0003' AND cost_usd IS NULL;" "$T/fix.sql" && ok || bad "BF4 a blank row is guarded on IS NULL: $(grep h0003 "$T/fix.sql")"
for h in h0005 h0006 h0007 h0008 h0009 h0010 h0011; do
  grep -q "'$h'" "$T/fix.sql" && bad "BF3 $h must get no UPDATE: $(grep "$h" "$T/fix.sql")" || ok
done
[ ! -e "$T/fix.sql.tmp" ] && ok || bad "BF4 the .tmp file was left behind"
APPLY=$(python3 - "$S/rows.json" "$T/fix.sql" "$T/d1.sqlite" <<'PY'
import json, sqlite3, sys
rows, sql, db = json.load(open(sys.argv[1])), open(sys.argv[2]).read(), sys.argv[3]
c = sqlite3.connect(db)
c.execute("CREATE TABLE cost_rows (box TEXT NOT NULL, row_hash TEXT NOT NULL, cost_usd REAL, raw TEXT, PRIMARY KEY (box, row_hash))")
c.executemany("INSERT INTO cost_rows VALUES (?,?,?,?)", [(r["box"], r["row_hash"], r["cost_usd"], r["raw"]) for r in rows])
c.commit()
before = dict(((b, h), u) for b, h, u in c.execute("SELECT box, row_hash, cost_usd FROM cost_rows"))
t0 = c.total_changes; c.executescript(sql); first = c.total_changes - t0
t0 = c.total_changes; c.executescript(sql); second = c.total_changes - t0
after = dict(((b, h), u) for b, h, u in c.execute("SELECT box, row_hash, cost_usd FROM cost_rows"))
changed = sorted(h for (b, h) in after if after[(b, h)] != before[(b, h)])
raw_ok = all(r == "verbatim-%d" % int(h[1:]) for h, r in c.execute("SELECT row_hash, raw FROM cost_rows"))
print(first, second, ",".join(changed), after[("o'box", "h0001")], after[("hub", "h0004")], raw_ok)
# hand the fixed table back to the stub, for the re-run below
for r in rows: r["cost_usd"] = after[(r["box"], r["row_hash"])]
json.dump(rows, open(sys.argv[1], "w"))
PY
)
read -r A_FIRST A_SECOND A_CHANGED A_H1 A_H4 A_RAW <<<"$APPLY"
[ "$A_FIRST" = 4 ] && ok || bad "BF4 the first apply must change exactly the 4 candidates: $APPLY"
[ "$A_CHANGED" = "h0001,h0002,h0003,h0004" ] && ok || bad "BF4 the rows changed must be the candidates: $APPLY"
[ "$A_SECOND" = 0 ] && ok || bad "BF4 a second apply must change 0 rows: $APPLY"
[ "$A_H1" = 0.289 ] && [ "$A_H4" = 0.01255 ] && ok || bad "BF4 the applied values: h0001=$A_H1 h0004=$A_H4"
[ "$A_RAW" = True ] && ok || bad "BF4 raw must stay verbatim: $APPLY"
run
has "candidates 0:" && ok || bad "BF4 a re-run after the apply must find no candidates: $OUT"

# ── BF5 paging + --max ─────────────────────────────────────────────────────
start many
run
[ "$RC" = 0 ] && ok || bad "BF5 two-page run rc=$RC: $OUT"
has "scanned 2101 rows" && ok || bad "BF5 both pages must be walked: $OUT"
has "candidates 2101: 0 grok rows with a vendor figure, 2101 blank rows with tokens" && ok || bad "BF5 candidates: $OUT"
[ "$(grep -c '^GET ' "$S/reqs.log")" -ge 2 ] && ok || bad "BF5 expected at least two GETs: $(cat "$S/reqs.log")"
grep -q 'until=' "$S/reqs.log" && ok || bad "BF5 the second page must walk until back: $(cat "$S/reqs.log")"
run --max 1000 --sql "$T/partial.sql"
[ "$RC" = 3 ] && ok || bad "BF5 --max below the window must be rc 3 (got $RC): $OUT"
has "NOT fully read" && ok || bad "BF5 must say the window was not fully read: $OUT"
[ "$(grep -c '^UPDATE ' "$T/partial.sql" 2>/dev/null)" = 1000 ] && ok || bad "BF5 the partial SQL covers what was read: $(grep -c '^UPDATE ' "$T/partial.sql" 2>/dev/null)"

# ── BF6 failures ───────────────────────────────────────────────────────────
OUT=$(cd "$T" && HARNESS="$T/h" JOBS_URL="" HARNESS_SECRET=test-secret JOBS_ALERT=0 bash "$BF" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "BF6 no JOBS_URL must be rc 2 (got $RC): $OUT"
run --max 0
[ "$RC" = 2 ] && ok || bad "BF6 --max 0 must be rc 2 (got $RC): $OUT"
start small
touch "$S/get_500"
run --sql "$T/fail.sql"
[ "$RC" = 1 ] && ok || bad "BF6 a 500 on GET must be rc 1 (got $RC): $OUT"
[ ! -e "$T/fail.sql" ] && [ ! -e "$T/fail.sql.tmp" ] && ok || bad "BF6 a failed GET must leave no SQL file"

# -h prints the header
OUT=$(bash "$BF" -h); RC=$?
[ "$RC" = 0 ] && grep -q 'npx wrangler d1 execute harness-jobs --remote --file=<file>' <<<"$OUT" && ok || bad "BF -h must print the header with the apply command (rc=$RC)"
grep -q 'set -uo pipefail' <<<"$OUT" && bad "BF -h printed past the header" || ok

echo "cost-reprice-backfill.bh-3984-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
