#!/bin/bash
# tests/cost-row-emit-cols-parity.bh-3220-test.sh — BH-3220: the immediate
# emitter (_cost_row_emit_body, bin/lib/cost-row.sh) posted rows cut at `note`,
# 24 columns, while the */10 mirror (_metric_cost_rows_chunk,
# bin/lib/jobs/cost.sh) and COST_ROW_HDR carry 26. The emitter's row landed
# first and ON CONFLICT DO NOTHING threw the mirror's full row away, so
# lane_id and guard_fp were NULL on nearly every row in D1.
#
#   (a) the REAL emitter body for a 26-column line carries lane_id and
#       guard_fp, and its row_hash equals the one the REAL mirror computes for
#       the same line
#   (b) emitter COLS == mirror COLS == COST_ROW_HDR, same length, same order;
#       a literal that cannot be found is a failure, not a pass
#   (c) a 24-column line (an old writer) still gives a body, with lane_id and
#       guard_fp null
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
trap scratch_cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

# shellcheck source=bin/lib/cost-row.sh
. "$DIR/bin/lib/cost-row.sh" || { echo "FAIL: cannot source bin/lib/cost-row.sh"; exit 1; }
# shellcheck source=bin/lib/jobs/cost.sh
. "$DIR/bin/lib/jobs/cost.sh" || { echo "FAIL: cannot source bin/lib/jobs/cost.sh"; exit 1; }

LINE26="2026-09-28T00:00:00Z,h,p,review,claude,m,0,1,1,1,0,0,0.01,sub,fp,acct,sess,agent,,BH-1,j1,,r1,,merge-conductor,mc-rereview:x"
LINE24="2026-09-28T00:00:01Z,h,p,review,claude,m,0,1,1,1,0,0,0.02,sub,fp,acct,sess,agent,,BH-1,j1,,r1,"

# ── (a) emitter body vs mirror body, same line ─────────────────────────────
if _cost_row_emit_body "$LINE26" hub 7 > "$T/emit26.json" 2>"$T/emit26.err"; then ok; else bad "(a) _cost_row_emit_body rc!=0 on a 26-column line: $(cat "$T/emit26.err")"; fi
printf '%s\n%s\n' "$COST_ROW_HDR" "$LINE26" > "$T/cost.csv"
if _metric_cost_rows_chunk "$T/cost.csv" 0 2000 hub "$T/mirror.json" > /dev/null 2>"$T/mirror.err" && [ -s "$T/mirror.json" ]; then ok; else bad "(a) _metric_cost_rows_chunk produced no body: $(cat "$T/mirror.err")"; fi
res=$(python3 - "$T/emit26.json" "$T/mirror.json" <<'PY'
import json, sys
try:
    e = json.load(open(sys.argv[1]))["rows"][0]
    m = json.load(open(sys.argv[2]))["rows"][0]
except Exception as x:
    print("unreadable body: %s" % x); sys.exit(0)
errs = []
if e.get("lane_id") != "merge-conductor": errs.append("emitter lane_id=%r" % e.get("lane_id"))
if e.get("guard_fp") != "mc-rereview:x": errs.append("emitter guard_fp=%r" % e.get("guard_fp"))
if e.get("row_hash") != m.get("row_hash"): errs.append("row_hash emitter=%s mirror=%s" % (e.get("row_hash"), m.get("row_hash")))
# Every column the mirror sends, the emitter sends with the same value.
for k, v in m.items():
    if k == "line_no":
        continue
    if e.get(k) != v: errs.append("%s: emitter=%r mirror=%r" % (k, e.get(k), v))
print("; ".join(errs) or "OK")
PY
)
[ "$res" = OK ] && ok || bad "(a) emitter body for a 26-column line: $res"

# ── (b) the three lists, read out of the source ────────────────────────────
res=$(python3 - "$DIR/bin/lib/cost-row.sh" "$DIR/bin/lib/jobs/cost.sh" "$COST_ROW_HDR" <<'PY'
import ast, re, sys
def cols(path, fn):
    src = open(path).read()
    i = src.find("\n%s() {" % fn)
    if i < 0:
        return None, "function %s not found in %s" % (fn, path)
    j = src.find("\nPYEOF", i)
    body = src[i:j if j > 0 else len(src)]
    m = re.search(r"^COLS = (\[.*?\])", body, re.S | re.M)
    if not m:
        return None, "no COLS literal in %s" % fn
    try:
        return ast.literal_eval(m.group(1)), None
    except Exception as x:
        return None, "COLS in %s does not parse: %s" % (fn, x)
emit, e1 = cols(sys.argv[1], "_cost_row_emit_body")
mirror, e2 = cols(sys.argv[2], "_metric_cost_rows_chunk")
hdr = sys.argv[3].split(",")
errs = [x for x in (e1, e2) if x]
if not errs:
    if len(hdr) != 26: errs.append("COST_ROW_HDR has %d names, expected 26" % len(hdr))
    if emit != mirror: errs.append("emitter COLS (%d) != mirror COLS (%d): %s vs %s" % (len(emit), len(mirror), emit, mirror))
    if emit != hdr: errs.append("emitter COLS (%d) != COST_ROW_HDR (%d)" % (len(emit), len(hdr)))
    if mirror != hdr: errs.append("mirror COLS (%d) != COST_ROW_HDR (%d)" % (len(mirror), len(hdr)))
print("; ".join(errs) or "OK")
PY
)
[ "$res" = OK ] && ok || bad "(b) COLS parity: $res"

# ── (c) an old 24-column line ──────────────────────────────────────────────
if _cost_row_emit_body "$LINE24" hub 8 > "$T/emit24.json" 2>"$T/emit24.err"; then ok; else bad "(c) _cost_row_emit_body rc!=0 on a 24-column line: $(cat "$T/emit24.err")"; fi
res=$(python3 - "$T/emit24.json" <<'PY'
import json, sys
try:
    r = json.load(open(sys.argv[1]))["rows"][0]
except Exception as x:
    print("unreadable body: %s" % x); sys.exit(0)
errs = []
for k in ("lane_id", "guard_fp"):
    if k not in r: errs.append("%s key missing" % k)
    elif r[k] is not None: errs.append("%s=%r, expected null" % (k, r[k]))
if r.get("cost_usd") != "0.02": errs.append("cost_usd=%r" % r.get("cost_usd"))
print("; ".join(errs) or "OK")
PY
)
[ "$res" = OK ] && ok || bad "(c) 24-column line: $res"

echo "cost-row-emit-cols-parity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
