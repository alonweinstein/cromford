#!/bin/bash
# tests/unknown-billing-window-test.sh — the unknown-billing HEALTH metric.
#
# WHY A 24h COUNT EXISTS AT ALL. fleet_unknown_billing_calls_7d cannot tell two
# opposite situations apart, and they want opposite responses:
#
#   * legacy backlog — rows written before billing_mode existed. Expected right
#     after the rollout, harmless, and it ages out of the window on its own.
#   * rows still landing untagged — a box whose 13->14 column header upgrade
#     never ran, or a runner nobody classified. That is the cost-capture-parity
#     failure: a lane we cannot price is a lane we cannot trust, and in the 7d
#     aggregate it hides inside the backlog.
#
# The 24h count separates them, because a legacy row can only ever sit in the
# 7d tail. 7d high + 24h ~0 = clearing. 24h staying high = broken.
#
# The functions are EXTRACTED FROM THE SCRIPT so this exercises shipped code.
# Run from anywhere: tests/unknown-billing-window-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/cost-rollup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/logs"

# agg() reads "{CD}/fleet-cost.csv", so CD points at the fixture dir.
python3 - "$SRC" "$T/core.py" <<'EXTRACT'
import sys
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
out = ["import csv, json, datetime, sys\nprices = {}\nH = CD = sys.argv[1]\n"
       "now = datetime.datetime.utcnow()\n"]
out.append(grab("def row_cost(r):", "# per-build exact attribution"))
out.append(grab("METERED_VENDORS =", "# project-level aggregates"))
out.append(grab("def agg(days):", "merged = {}"))
out.append(grab("def project_row(", "for p in sorted("))
out.append(grab("def cash_note(", "_unk = summary["))
open(sys.argv[2], "w").write("\n".join(out))
EXTRACT
[ -s "$T/core.py" ] && ok || bad "could not extract the aggregation functions from cost-rollup.sh"
grep -q 'def agg' "$T/core.py" && grep -q 'def fold_other' "$T/core.py" \
  && grep -q 'def cash_note' "$T/core.py" && grep -q 'def project_row' "$T/core.py" \
  && ok || bad "extraction is missing agg/fold_other/cash_note/project_row — is the marker text still right?"

# Timestamps relative to now, in the ledger's own format.
TS() { python3 -c "
import datetime,sys
print((datetime.datetime.utcnow()-datetime.timedelta(hours=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
OLD=$(TS 120)      # 5 days ago  — inside 7d, outside 24h
RECENT=$(TS 2)     # 2 hours ago — inside both

agg_py() { python3 - "$T" <<'PY'
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
a1, a7 = core.agg(1), core.agg(7)
def unk(a): return sum(v.get("unknown_billing", 0) for v in a.values())
print(f"unk24={unk(a1)} unk7={unk(a7)}")
PY
}

# --- 1. the window actually discriminates ------------------------------------
# Two untagged rows, one old and one recent. The 7d count must see both; the
# 24h count must see only the recent one. If 24h counted the old row too, the
# metric would be a second copy of the 7d number and could never tell the
# backlog from a live failure.
#
# HONEST SCOPE: the PROPERTY sections 1 and 2 guard already held in the
# pre-change script — agg() windowed unknown_billing correctly all along, and
# what was missing was exposing the 24h figure and reading it. They are
# regression guards on an existing property, not proof of the new behaviour;
# sections 4 and 5 are that. (Precisely: they would not RUN against the
# pre-change script, since the shared extraction needs fold_other/cash_note.
# The claim is about the property holding, not about these sections passing.)
cat > "$T/fleet-cost.csv" <<EOF
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode
$OLD,oldbox,alpha-os,execute,claude,claude-opus-5,0,60,100,200,0,0,9.00,
$RECENT,newbox,alpha-os,execute,claude,claude-opus-5,0,60,100,200,0,0,3.00,
$RECENT,newbox,alpha-os,review,grok,grok-4.6,0,60,100,200,0,0,2.00,metered
EOF
OUT=$(agg_py)
grep -q 'unk7=2' <<<"$OUT"  && ok || bad "7d must count both untagged rows (got: $OUT)"
grep -q 'unk24=1' <<<"$OUT" && ok || bad "24h must count ONLY the recent untagged row (got: $OUT)"

# --- 2. tagging the recent rows drops the 24h count to zero ------------------
# This is the metric's whole purpose: once a box syncs and starts tagging, the
# health number goes green while the 7d number is still working off the
# backlog. Both directions asserted — a metric that only ever goes up is not a
# health signal.
cat > "$T/fleet-cost.csv" <<EOF
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode
$OLD,oldbox,alpha-os,execute,claude,claude-opus-5,0,60,100,200,0,0,9.00,
$RECENT,newbox,alpha-os,execute,claude,claude-opus-5,0,60,100,200,0,0,3.00,subscription
$RECENT,newbox,alpha-os,review,claude,claude-opus-5,0,60,100,200,0,0,2.00,metered
EOF
OUT=$(agg_py)
grep -q 'unk24=0' <<<"$OUT" && ok || bad "tagged recent rows must clear the 24h count (got: $OUT)"
grep -q 'unk7=1'  <<<"$OUT" && ok || bad "the legacy row must remain visible in 7d (got: $OUT)"

# --- 3. THE "other" BUCKET MUST CARRY cash AND unknown_billing ---------------
# Non-fleet projects (alert-triage, bench, probes) fold into "other". That fold
# summed a HARDCODED field list which was never extended when the cash split
# added "cash" and "unknown_billing" — so a metered non-fleet lane contributed
# $0 to fleet cash and its untagged rows were invisible to the health count.
#
# That is precisely the failure the bucket was created to prevent ("$1k/7d of
# alert-triage spend invisible to every per-project view"), reintroduced one
# field at a time. It also silently defeats THIS metric: alert-triage could
# stop tagging entirely and the 24h count would read a healthy 0.
python3 - "$T" <<'PY' && ok || bad "fold_other must carry cash and unknown_billing into \"other\""
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
s = {"alert-triage": {"total": 10.0, "cash": 6.0, "calls": 3, "unknown_billing": 2, "stages": {"triage": 10.0}}}
core.fold_other(s, {"alpha-os"})
o = s["other"]
assert "alert-triage" not in s, "the non-fleet project must be folded, not left alongside"
assert o.get("total") == 10.0, o
assert o.get("cash") == 6.0, f"metered non-fleet spend was dropped from cash: {o}"
assert o.get("unknown_billing") == 2, f"untagged non-fleet rows were dropped from the health count: {o}"
assert o.get("stages") == {"triage": 10.0}, o
PY

# The fold must not drift again when a field is added. Summing whatever the
# aggregate carries — rather than a fixed list — is what makes that structural
# instead of a thing someone has to remember.
python3 - "$T" <<'PY' && ok || bad "fold_other must carry a field it was never told about"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
s = {"bench": {"total": 1.0, "some_future_field": 4, "stages": {}}}
core.fold_other(s, set())
assert s["other"].get("some_future_field") == 4, s["other"]
PY

# Two non-fleet projects must ADD, not overwrite — the bucket is a sum.
python3 - "$T" <<'PY' && ok || bad "fold_other must sum across every non-fleet project"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
s = {"alert-triage": {"cash": 6.0, "unknown_billing": 2, "stages": {"triage": 1.0}},
     "bench":        {"cash": 1.5, "unknown_billing": 1, "stages": {"triage": 2.0}},
     "alpha-os":     {"cash": 99.0, "unknown_billing": 9, "stages": {}}}
core.fold_other(s, {"alpha-os"})
assert s["other"]["cash"] == 7.5, s["other"]
assert s["other"]["unknown_billing"] == 3, s["other"]
assert s["other"]["stages"] == {"triage": 3.0}, s["other"]
assert s["alpha-os"]["cash"] == 99.0, "a real fleet project must be left untouched"
PY

# A fleet with nothing to fold still gets a named bucket, and reads as zero
# through the same .get() defaults the summary uses.
python3 - "$T" <<'PY' && ok || bad "an empty other bucket must still exist and read as zero"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
s = {"alpha-os": {"total": 5.0, "stages": {}}}
core.fold_other(s, {"alpha-os"})
assert "other" in s, s
assert s["other"].get("cash", 0) == 0 and s["other"].get("unknown_billing", 0) == 0, s["other"]
PY

# --- 4. the note must READ the two counts differently ------------------------
# This is the new behaviour. The number alone is useless to whoever reads the
# snapshot at 3am: the same "unknown: 4,000" means "ignore me, I am draining"
# on the day after a rollout and "a lane is unpriced" a week later. The caption
# has to make that call, and it has to make it in BOTH directions.
python3 - "$T" <<'PY' && ok || bad "cash_note must distinguish a clearing backlog from live untagged rows"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)

# Backlog clearing: lots in 7d, none today. Must NOT read as a live failure.
clearing = core.cash_note(12.0, 4000, 0)
assert "LOWER BOUND" in clearing, clearing
assert "aging out" in clearing, clearing
assert "STILL" not in clearing, f"a clearing backlog must not be reported as a live failure: {clearing}"

# Live failure: still landing today. Must say so and name what to check.
live = core.cash_note(12.0, 4000, 37)
assert "STILL" in live, live
assert "37" in live, live
assert "aging out" not in live, f"live untagged rows must not read as a clearing backlog: {live}"
assert "header" in live, f"the caption must name what to check: {live}"

# The two readings must not be the same string — the whole point is that they
# differ at identical 7d counts.
assert clearing != live, "the note ignores the 24h count entirely"

# Nothing unknown: no caveat at all, and no scary wording either way.
clean = core.cash_note(12.0, 0, 0)
assert "CAVEAT" not in clean and "LOWER BOUND" not in clean, clean

# A missing meter is still reported as unknown, not folded into the new text.
nometer = core.cash_note(None, 0, 0)
assert "UNKNOWN" in nometer and "overage could not be read" in nometer, nometer
PY

# --- 5. THE SEAM: which aggregate feeds the 24h field -----------------------
# Sections 1-2 prove agg() windows correctly and section 4 proves the note
# reads the counts correctly, but neither touches the WIRING between them —
# and a1-vs-a7 in the summary assembly is a one-token edit that both would
# survive. That inversion is the worst outcome available here: the 24h count
# becomes a copy of the 7d count, the caption reads "rows are STILL being
# written untagged" permanently, and someone goes looking for a header-sync
# failure that never happened. Untested wiring between tested units is where
# this keeps hiding.
python3 - "$T" <<'PY' && ok || bad "the 24h field must come from the 24h aggregate, not the 7d one"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
# Deliberately different counts so a swap cannot coincide.
a1 = {"total": 1.0, "cash": 1.0, "unknown_billing": 1, "unpriced": 0, "stages": {}}
a7 = {"total": 9.0, "cash": 9.0, "unknown_billing": 2, "unpriced": 0, "stages": {}}
row = core.project_row(a1, a7, {}, None, None)
assert row["unknown_billing_calls_24h"] == 1, f"24h field took the 7d aggregate: {row}"
assert row["unknown_billing_calls_7d"] == 2, row
# The neighbouring 24h fields must come from the same side, or the swap could
# be "fixed" in one place and left in another.
assert row["cost_24h"] == 1.0 and row["cash_cost_24h"] == 1.0, row
assert row["cost_7d"] == 9.0 and row["cash_cost_7d"] == 9.0, row
PY

# A project with no rows in the last 24h reports a measured zero, not the 7d
# figure and not null — "quiet today" and "still untagged today" must not look
# the same to whoever reads the snapshot.
python3 - "$T" <<'PY' && ok || bad "an empty 24h window must report 0, not the 7d count"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
row = core.project_row({}, {"unknown_billing": 5, "total": 5.0, "stages": {}}, {}, None, None)
assert row["unknown_billing_calls_24h"] == 0, row
assert row["unknown_billing_calls_7d"] == 5, row
PY

# fold_other must not crash the whole rollup on a non-numeric field. Without
# the isinstance guard this raises TypeError before json.dump, so there is no
# summary.json AT ALL — every box's dashboard figure goes stale, from one
# unexpected field type.
python3 - "$T" <<'PY' && ok || bad "a non-numeric aggregate field must be skipped, not crash the rollup"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
s = {"bench": {"total": 2.0, "host": "hub-1", "note": None, "flagged": True, "stages": {}}}
core.fold_other(s, set())          # must not raise
assert s["other"]["total"] == 2.0, s["other"]
assert "host" not in s["other"] and "note" not in s["other"], s["other"]
# bool is an int subclass; counting it would silently add 1 to a spend figure.
assert "flagged" not in s["other"], s["other"]
PY

echo "unknown-billing-window-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
