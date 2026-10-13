#!/bin/bash
# tests/cost-cash-split-test.sh — the cash-vs-notional split in cost-rollup.sh.
#
# The classifier and the overage reader are EXTRACTED FROM THE SCRIPT and run
# against fixture CSVs, so this exercises the shipped code rather than a copy
# that can drift away from it.
#
# What is worth pinning: the two numbers must not collapse into each other. A
# subscription row belongs in notional and NOT in cash — counting it as cash is
# what inflated the fleet figure by ~$1,940/7d. A metered row belongs in both,
# because for those lanes retail IS the invoice. And the account overage is
# fleet-level: apportioning it per project would be an invention dressed as
# data, in a change whose whole purpose is to stop presenting one kind of number
# as another.
# Run from anywhere: tests/cost-cash-split-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/cost-rollup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/logs" "$T/cost"

# Pull the real functions out of the script's python block. If the extraction
# ever comes back empty the suite must fail loudly rather than silently testing
# nothing — that is the failure mode this repo keeps producing.
python3 - "$SRC" "$T/core.py" <<'EXTRACT'
import re, sys
src = open(sys.argv[1]).read()
# Anchored on the python body's FIRST LINE, not on the invocation line. The
# invocation grew a stderr redirect ("2>\"$PYERR\"") and every test anchored on
# its exact text stopped extracting -- silently, since an empty extraction just
# fails everything at once. The import line is what the extraction actually
# needs to start from.
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
def grab(name, upto):
    i = body.index(name)
    return body[i:body.index(upto, i)]
out = []
out.append("import csv, json, datetime, sys\nprices = {}\nH = sys.argv[1]\nnow = datetime.datetime.utcnow()\n")
out.append(grab("def row_cost(r):", "# per-build exact attribution"))
out.append(grab("METERED_VENDORS =", "# project-level aggregates"))
out.append(grab("def overage_delta(days):", "summary = {"))
open(sys.argv[2], "w").write("\n".join(out))
EXTRACT
[ -s "$T/core.py" ] && ok || bad "could not extract the cash functions from cost-rollup.sh"
grep -q 'def cash_of' "$T/core.py" && grep -q 'def overage_delta' "$T/core.py" \
  && ok || bad "extraction is missing cash_of/overage_delta — is the marker text still right?"

# --- fixture: one row per billing shape, all priced via cost_usd ---
cat > "$T/fleet-cost.csv" <<'EOF'
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode
2026-08-24T10:00:00Z,box1,alpha-os,execute,claude,claude-opus-5,0,60,100,200,0,0,5.00,subscription
2026-08-24T10:01:00Z,box1,alpha-os,review,grok,grok-4.6,0,60,100,200,0,0,2.00,metered
2026-08-24T10:02:00Z,box1,beta-os,execute,fireworks,kimi,0,60,100,200,0,0,3.00,metered
2026-08-24T10:03:00Z,box1,beta-os,plan,codex,gpt-5,0,60,100,200,0,0,4.00,subscription
2026-08-24T10:04:00Z,box1,gamma-os,execute,openrouter,deepseek,0,60,100,200,0,0,1.50,
2026-08-24T10:05:00Z,box1,gamma-os,execute,claude,claude-opus-5,0,60,100,200,0,0,7.00,
EOF

run_py() { python3 - "$T" "$@" <<'PY'
import sys, csv, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec)
sys.argv = ["core", T]
spec.loader.exec_module(core)
rows = list(csv.DictReader(open(f"{T}/fleet-cost.csv")))
notional = sum(core.row_cost(r) for r in rows)
cash = sum(core.cash_of(r) for r in rows)
unknown = sum(1 for r in rows if core.is_unknown_billing(r))
print(f"notional={notional:.2f} cash={cash:.2f} unknown={unknown}")
print(f"overage7={core.overage_delta(7)}")
print(f"overage1={core.overage_delta(1)}")
PY
}

# --- 1. the split is real ----------------------------------------------------
# notional = everything (5+2+3+4+1.5+7 = 22.50)
# cash     = metered rows only, plus the missing-billing_mode openrouter row
#            classified by vendor (2+3+1.5 = 6.50). The subscription rows and
#            the ambiguous claude row contribute nothing.
OUT=$(run_py)
grep -q 'notional=22.50' <<<"$OUT" && ok || bad "notional must count every row (got: $OUT)"
grep -q 'cash=6.50' <<<"$OUT" && ok || bad "cash must count metered lanes only (got: $OUT)"

# A subscription row is in notional and NOT in cash — the ~\$1,940/7d error.
python3 - "$T" <<'PY' && ok || bad "a subscription row must add to notional but not to cash"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
sub = {"cost_usd": "5.00", "billing_mode": "subscription", "runner": "claude", "model": "claude-opus-5"}
assert core.row_cost(sub) == 5.0, core.row_cost(sub)
assert core.cash_of(sub) == 0.0, core.cash_of(sub)
met = {"cost_usd": "2.00", "billing_mode": "metered", "runner": "grok", "model": "grok-4.6"}
assert core.row_cost(met) == 2.0 and core.cash_of(met) == 2.0
PY

# OpenRouter rows leave raw cost_usd blank because the codex wrapper reports
# tokens, not the vendor invoice. row_cost must still price those tokens from
# the model catalog, and metered cash must inherit the same computed figure.
if python3 - "$T" <<'PY'
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
core.prices = {
    "anthropic/claude-opus-5": {
        "prompt": 0.000005,
        "completion": 0.000025,
        "cache_read": 0.0000005,
        "cache_write": 0.00000625,
    }
}
row = {
    "cost_usd": "",
    "billing_mode": "metered",
    "runner": "openrouter",
    "model": "anthropic/claude-opus-5",
    "input_toks": "2000000",
    "output_toks": "20000",
    "cache_read": "0",
    "cache_write": "0",
}
assert core.row_cost(row) == 10.5, core.row_cost(row)
assert core.cash_of(row) == 10.5, core.cash_of(row)
PY
then
  ok
else
  bad "token-bearing OpenRouter rows must price even when raw cost_usd is blank"
fi

# --- 2. a row with no billing_mode ------------------------------------------
# openrouter/fireworks have no subscription tier, so the vendor alone settles
# it. claude/codex/grok genuinely cannot be settled that way — the same runner
# is flat-rate on one box and per-token on another — so those count as unknown
# and are FLAGGED rather than guessed in either direction.
grep -q 'unknown=1' <<<"$OUT" \
  && ok || bad "exactly the ambiguous legacy row should be unknown (got: $OUT)"
python3 - "$T" <<'PY' && ok || bad "legacy rows must classify by vendor only where it is unambiguous"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
legacy_or = {"cost_usd": "1.50", "runner": "openrouter", "model": "deepseek"}
legacy_cl = {"cost_usd": "7.00", "runner": "claude", "model": "claude-opus-5"}
assert core.cash_of(legacy_or) == 1.5, "openrouter has no subscription tier — it is cash"
assert core.cash_of(legacy_cl) == 0.0, "ambiguous legacy claude must not be guessed as cash"
assert core.is_unknown_billing(legacy_cl) is True
assert core.is_unknown_billing(legacy_or) is False
PY

# --- 2b. MIXED-WIDTH ROWS during rollout --------------------------------------
# harness-sync lands bin/ per box, so for a window the fleet file holds 13-column
# rows from un-synced boxes beside 14-column rows from synced ones. Both shapes
# must price correctly; a schema change that mangles the old rows would corrupt
# the very number it was added to fix.
cat > "$T/fleet-cost.csv" <<'EOF'
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode
2026-08-24T10:00:00Z,oldbox,alpha-os,execute,claude,claude-opus-5,0,60,100,200,0,0,9.00
2026-08-24T10:01:00Z,newbox,alpha-os,execute,fireworks,kimi,0,60,100,200,0,0,1.00,metered
EOF
OUT=$(run_py)
# Both rows priced: 9 + 1 = 10 notional. Only the metered one is cash.
grep -q 'notional=10.00' <<<"$OUT"   && ok || bad "a 13-column legacy row must still price correctly (got: $OUT)"
grep -q 'cash=1.00' <<<"$OUT"   && ok || bad "only the synced metered row is cash (got: $OUT)"
grep -q 'unknown=1' <<<"$OUT"   && ok || bad "the legacy row must be FLAGGED unknown, not silently counted (got: $OUT)"

# And the reverse, which happens if the hub syncs last: a 14-column row read
# under a 13-column header. The extra value lands in DictReader's restkey and
# must not corrupt cost_usd.
cat > "$T/fleet-cost.csv" <<'EOF'
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd
2026-08-24T10:00:00Z,newbox,alpha-os,execute,fireworks,kimi,0,60,100,200,0,0,1.00,metered
EOF
OUT=$(run_py)
grep -q 'notional=1.00' <<<"$OUT"   && ok || bad "a 14-column row under an old header must still price (got: $OUT)"
# It degrades to unknown rather than mis-reading — safe, and visible.
grep -q 'cash=1.00' <<<"$OUT"   && ok || bad "openrouter/fireworks stay cash by vendor even with no readable mode (got: $OUT)"

# --- 2c. THE BLOCKER: a metered CLAUDE/GROK row under an OLD 13-col header ----
# This is the case 2b missed. It used a FIREWORKS row, which METERED_VENDORS
# rescues by vendor alone — so it proved the safe half and left the broken half
# untested. claude and grok are exactly the runners the vendor fallback CANNOT
# classify (the same runner is flat-rate on one box and per-token on another),
# so if their billing_mode is lost they report $0 cash while looking healthy.
#
# Every box in the fleet had a 13-column header, so this was the real state on
# 100% of them: the column inert, in the direction the wave exists to fix.
cat > "$T/fleet-cost.csv" <<'EOF'
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd
2026-08-24T10:00:00Z,project-10,alpha-os,execute,claude,claude-opus-5,0,60,100,200,0,0,12.00,metered
2026-08-24T10:01:00Z,hub,alpha-os,triage,grok,grok-4.6,0,60,100,200,0,0,4.00,metered
2026-08-24T10:02:00Z,hub,alpha-os,plan,claude,claude-opus-5,0,60,100,200,0,0,6.00,subscription
EOF
OUT=$(run_py)
grep -q 'notional=22.00' <<<"$OUT" && ok || bad "all three rows must price notionally (got: $OUT)"
grep -q 'cash=16.00' <<<"$OUT" \
  && ok || bad "a metered claude/grok row under an old header MUST count as cash (got: $OUT)"
grep -q 'unknown=0' <<<"$OUT" \
  && ok || bad "a row that DID report its mode must not read as unclassifiable (got: $OUT)"

# Recovery must not become "count everything" — that would restore the original
# overstatement this wave exists to remove.
python3 - "$T" <<'PY' && ok || bad "restkey recovery must preserve subscription=0 cash"
import sys, csv, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
rows = list(csv.DictReader(open(f"{T}/fleet-cost.csv")))
sub = [r for r in rows if r["stage"] == "plan"][0]
assert core.billing_of(sub) == "subscription", core.billing_of(sub)
assert core.cash_of(sub) == 0.0
met = [r for r in rows if r["stage"] == "execute"][0]
assert core.billing_of(met) == "metered"
assert core.cash_of(met) == 12.0
PY

# A stray trailing field must behave as unknown: no cash, and flagged.
#
# HONEST SCOPE: this pins the END BEHAVIOUR, not the whitelist in billing_of().
# Mutation-checked — widening that whitelist to accept ANY value does not change
# the outcome, because cash_of only acts on the exact strings "metered" and
# "subscription", so an unrecognised value already falls through to unknown. The
# whitelist is belt-and-braces against a future mode being added, and it has no
# observable effect today. Saying so beats a comment claiming a guard this
# assertion cannot actually see.
cat > "$T/fleet-cost.csv" <<'EOF'
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd
2026-08-24T10:00:00Z,hub,alpha-os,execute,claude,claude-opus-5,0,60,100,200,0,0,5.00,garbage
EOF
OUT=$(run_py)
grep -q 'cash=0.00' <<<"$OUT" && grep -q 'unknown=1' <<<"$OUT" \
  && ok || bad "an unrecognised trailing field must be unknown, not a mode (got: $OUT)"

# --- 3. the overage meter ----------------------------------------------------
# extra_used_usd is monotonic WITHIN a weekly window and resets at the boundary.
# Summing positive deltas survives the reset; last-minus-first would not.
NOW=$(date -u '+%Y-%m-%dT%H:%M:%S')
D() { date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%S'; }
cat > "$T/logs/extra-usage.csv" <<EOF
ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage
$(D 6),50,80,x,1,10.00,0,1
$(D 5),60,90,x,1,14.00,0,1
$(D 4),70,100,x,1,20.00,0,1
$(D 3),10,5,x,1,0.00,0,0
$(D 2),20,30,x,1,3.00,0,1
$(D 0),30,40,x,1,5.00,0,1
EOF
OUT=$(run_py)
# 6d->5d: +4, 5d->4d: +6, reset to 0 ignored, 3d->2d: +3, 2d->now: +2  => 15.00
grep -q 'overage7=15.0' <<<"$OUT" \
  && ok || bad "7d overage must sum positive deltas across the weekly reset (got: $OUT)"
# The reset must not appear as a negative or inflate the total.
grep -qE 'overage7=-|overage7=20' <<<"$OUT" \
  && bad "the weekly reset was mishandled (got: $OUT)" || ok

# A box with no meter reports UNKNOWN, never 0.00 — a missing meter and a week
# with no overage look identical as a number and must not read the same.
rm -f "$T/logs/extra-usage.csv"
OUT=$(run_py)
grep -q 'overage7=None' <<<"$OUT" \
  && ok || bad "a missing meter must be None (unknown), not 0.00 (got: $OUT)"

# --- 5. the reset boundary must not silently undercount ----------------------
# 50 -> reset -> 3 : the $3 the new week had already accrued by the first
# post-reset sample is real spend. Dropping it errs toward understating, which
# is the direction that lets a burn hide.
cat > "$T/logs/extra-usage.csv" <<EOF
ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage
$(D 3),90,100,x,1,50.00,0,1
$(D 2),5,10,x,1,3.00,0,1
$(D 1),10,20,x,1,7.00,0,1
EOF
OUT=$(run_py)
# 50 -> 3 is a reset carrying 3, then 3 -> 7 adds 4  => 7.00
grep -q 'overage7=7.0' <<<"$OUT" \
  && ok || bad "the post-reset accrual must be counted, not dropped (got: $OUT)"

echo "cost-cash-split-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
