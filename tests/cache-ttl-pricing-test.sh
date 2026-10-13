#!/bin/bash
# tests/cache-ttl-pricing-test.sh — a cache write is priced at the rate of the
# TTL it was written with, in all three pricers (P1, headless session profile).
#
# The table's `cache_write` is the 5-minute rate (1.25x prompt). A write at the
# one-hour TTL costs 2x prompt — or the row's explicit `cache_write_1h` when
# the table carries one. bin/transcript-cost.sh already read the split; the two
# pricers that re-price a row from its TOKENS (cost_price_tokens at the call
# site, row_cost in the hub rollup) charged every write at 5m, so a blank-dollar
# row from a session that wrote at 1h came out 37.5% low on its biggest term.
#
#   A  cost_price_tokens / cost_row_price (bin/lib/cost-row.sh), extracted by
#      their markers and executed
#   B  row_cost (bin/cost-rollup.sh), extracted the way
#      tests/cost-cash-split-test.sh extracts it, reading the row's note tag
#   C  bin/transcript-cost.sh honours an explicit cache_write_1h
# Every "untagged" case is the PARITY case: the number is today's.
# Run from anywhere: tests/cache-ttl-pricing-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/cfg/projects/-work"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

# claude-opus-5-5 at the catalog's published rates; `explicit` carries its own
# 1h rate so the table-wins rule is visible (9e-6 is neither 2x nor 1.6x).
cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "claude-opus-5-5": {"prompt": 0.000004, "completion": 0.00002, "cache_read": 2e-7, "cache_write": 0.000005},
  "explicit":        {"prompt": 0.000004, "completion": 0.00002, "cache_read": 2e-7, "cache_write": 0.000005, "cache_write_1h": 0.000009}
}}
EOF

# ── A. the call-site pricer ──────────────────────────────────────────────────
awk '/^# >>> cost_price_tokens/{f=1;next} /^# <<< cost_price_tokens/{exit} f' "$DIR/bin/lib/cost-row.sh" > "$T/bin/price.sh"
awk '/^# >>> cost_row_price/{f=1;next} /^# <<< cost_row_price/{exit} f' "$DIR/bin/lib/cost-row.sh" > "$T/bin/priced.sh"
grep -q 'cost_price_tokens()' "$T/bin/price.sh" && grep -q 'cost_row_price()' "$T/bin/priced.sh" \
  && ok || bad "A could not extract the pricers from bin/lib/cost-row.sh — markers missing?"
pt() { ( MODEL_PRICES="$T/prices.json"; . "$T/bin/price.sh"; cost_price_tokens "$@" ); }
pr() { ( MODEL_PRICES="$T/prices.json"; . "$T/bin/price.sh"; . "$T/bin/priced.sh"; cost_row_price "$@" ); }

# 100,000 written tokens and nothing else: 5m = 0.50, 1h = 0.80 (2 x 4e-6).
[ "$(pt claude-opus-5-5 0 0 0 100000)" = 0.500000 ]     && ok || bad "A1 untagged write must stay at the 5m rate (parity): $(pt claude-opus-5-5 0 0 0 100000)"
[ "$(pt claude-opus-5-5 0 0 0 100000 5m)" = 0.500000 ]  && ok || bad "A2 5m write: $(pt claude-opus-5-5 0 0 0 100000 5m)"
[ "$(pt claude-opus-5-5 0 0 0 100000 1h)" = 0.800000 ]  && ok || bad "A3 1h write must be 2x prompt = 0.80: $(pt claude-opus-5-5 0 0 0 100000 1h)"
[ "$(pt claude-opus-5-5 0 0 0 100000 mixed)" = 0.500000 ] && ok || bad "A4 a mixed split has no per-TTL counts; it stays at the table rate: $(pt claude-opus-5-5 0 0 0 100000 mixed)"
[ "$(pt explicit 0 0 0 100000 1h)" = 0.900000 ]         && ok || bad "A5 an explicit cache_write_1h must win: $(pt explicit 0 0 0 100000 1h)"
# the other three terms are untouched by the TTL
[ "$(pt claude-opus-5-5 1000 1000 100000 0 1h)" = "$(pt claude-opus-5-5 1000 1000 100000 0)" ] \
  && ok || bad "A6 the TTL moved a term that is not the cache write"
# cost_row_price hands the TTL through, and never overrides a vendor dollar figure
[ "$(pr claude claude-opus-5-5 0 0 0 0 100000 '' 'cache_ttl=1h' 1h)" = '0.800000|cache_ttl=1h' ] \
  && ok || bad "A7 cost_row_price did not price a 1h row at the 1h rate: $(pr claude claude-opus-5-5 0 0 0 0 100000 '' 'cache_ttl=1h' 1h)"
[ "$(pr claude claude-opus-5-5 0 0 0 0 100000 '' '')" = '0.500000|' ] \
  && ok || bad "A8 cost_row_price without a TTL changed today's number: $(pr claude claude-opus-5-5 0 0 0 0 100000 '' '')"
[ "$(pr claude claude-opus-5-5 0 0 0 0 100000 0.42 'cache_ttl=1h' 1h)" = '0.42|cache_ttl=1h' ] \
  && ok || bad "A9 a measured dollar figure was overwritten"

# ── B. the hub rollup's row_cost ─────────────────────────────────────────────
python3 - "$DIR/bin/cost-rollup.sh" "$T/core.py" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
i = body.index("def row_cost(r):")
fn = body[i:body.index("# per-build exact attribution", i)]
open(sys.argv[2], "w").write("import csv, json, datetime, sys\nprices = {}\n" + fn)
EXTRACT
grep -q 'def row_cost' "$T/core.py" && ok || bad "B could not extract row_cost from bin/cost-rollup.sh"
OUTB=$(python3 - "$T" <<'PY'
import sys, json, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); spec.loader.exec_module(core)
core.prices = json.load(open(f"{T}/prices.json"))["per_token"]
def row(model, note, usd=""):
    return {"model": model, "input_toks": "0", "output_toks": "0", "cache_read": "0",
            "cache_write": "100000", "cost_usd": usd, "note": note}
cases = [
    ("B1 untagged (parity)",        row("claude-opus-5-5", ""),                       0.5),
    ("B2 cache_ttl=5m",             row("claude-opus-5-5", "cache_ttl=5m"),           0.5),
    ("B3 cache_ttl=1h",             row("claude-opus-5-5", "cache_ttl=1h"),           0.8),
    ("B4 1h after another tag",     row("claude-opus-5-5", "cliff-routed:x;cache_ttl=1h"), 0.8),
    ("B5 a look-alike tag",         row("claude-opus-5-5", "cache_ttl=1hx"),          0.5),
    ("B6 explicit 1h rate wins",    row("explicit", "cache_ttl=1h"),                  0.9),
    ("B7 vendor dollars are final", row("claude-opus-5-5", "cache_ttl=1h", "0.42"),   0.42),
    ("B8 a row with no note key",   {k: v for k, v in row("claude-opus-5-5", "").items() if k != "note"}, 0.5),
]
for name, r, want in cases:
    got = core.row_cost(r)
    print(("ok " if abs(got - want) < 1e-9 else "BAD ") + f"{name}: got {got} want {want}")
PY
)
while IFS= read -r l; do
  case "$l" in "ok "*) ok ;; *) bad "$l" ;; esac
done <<<"$OUTB"
[ "$(printf '%s\n' "$OUTB" | grep -c '')" = 8 ] && ok || bad "B the row_cost harness did not run all 8 cases: $OUTB"

# ── C. transcript-cost honours an explicit cache_write_1h ────────────────────
S=00000000-0000-0000-0000-00000000cc01
python3 - "$T/cfg/projects/-work/$S.jsonl" <<'PY'
import json, sys
e = {"type": "assistant", "uuid": "u1", "timestamp": "2026-09-24T20:00:00.000Z",
     "message": {"id": "m1", "type": "message", "role": "assistant", "model": "explicit",
                 "content": [{"type": "text", "text": "hi"}],
                 "usage": {"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0,
                           "cache_creation_input_tokens": 100000,
                           "cache_creation": {"ephemeral_5m_input_tokens": 0,
                                              "ephemeral_1h_input_tokens": 100000}}}}
open(sys.argv[1], "w").write(json.dumps(e) + "\n")
PY
L=$("$DIR/bin/transcript-cost.sh" "$S" --cwd /work --config-dir "$T/cfg" --prices "$T/prices.json" 2>"$T/err")
[ "$(printf '%s' "$L" | cut -d'|' -f5)" = 0.900000 ] \
  && ok || bad "C transcript-cost priced a 1h write at $(printf '%s' "$L" | cut -d'|' -f5), not the table's cache_write_1h 0.900000 ($(cat "$T/err"))"

echo "cache-ttl-pricing-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
