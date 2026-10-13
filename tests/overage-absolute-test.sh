#!/bin/bash
# tests/overage-absolute-test.sh — the account overage meter must be read
# ABSOLUTE, not as an in-window delta.
#
# THE BUG THIS PINS. extra_used_usd is a CUMULATIVE meter for the current
# weekly window (used_credits / 10^decimal_places, straight from the account).
# cash_overage_* summed the deltas BETWEEN SAMPLES instead, so it could only
# ever report what accrued while the tracker happened to be running. The
# tracker started ~90 minutes before the first rollup with the meter already at
# $18,835 — so it reported $4.33 against a real weekly overage of ~$18,863.
# Three orders of magnitude low, on the largest dollar figure in the system,
# and it looked like a healthy small number rather than a broken one.
#
# Same species as every other bug this wave: a number that can only ever read
# too low, with nothing about it that looks wrong.
#
# Functions are EXTRACTED FROM THE SCRIPT so this exercises shipped code.
#
# RED-FIRST, STATED EXACTLY: against main this file does not RUN at all — the
# shared extraction needs read_overage_meter/overage_fields, which main lacks,
# so all assertions fail on extraction rather than on behaviour. The "8 failed
# before the fix" figure was measured differently: this file present, against
# the branch with overage_state() stubbed to the OLD delta reading. That is the
# comparison that says something, and it is the one worth quoting.
# Run from anywhere: tests/overage-absolute-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/cost-rollup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/logs"

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
out.append(grab("def overage_delta(days):", "summary = {"))
out.append(grab("def overage_fields(", "_ost = read_overage_meter()"))
out.append(grab("def fleet_cash_total(", "_ofields = overage_fields("))
out.append(grab("def cash_note(", "_unk = summary["))
open(sys.argv[2], "w").write("\n".join(out))
EXTRACT
[ -s "$T/core.py" ] && ok || bad "could not extract the overage functions from cost-rollup.sh"
grep -q 'def read_overage_meter' "$T/core.py" && grep -q 'def cash_note' "$T/core.py" \
  && grep -q 'def overage_fields' "$T/core.py" \
  && grep -q 'def fleet_cash_total' "$T/core.py" \
  && ok || bad "extraction is missing read_overage_meter/cash_note/overage_fields — is the marker text still right?"

D() { date -u -v-"$1"H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "$1 hours ago" '+%Y-%m-%dT%H:%M:%SZ'; }

# Reset stamps are COMPUTED, never literal. read_overage_meter deliberately
# nulls used_usd when the newest sample predates the window it names (the
# post-reset blind window), so a fixture whose weekly_resets_at is hardcoded
# to a real date starts failing on the calendar rather than on behaviour --
# "2026-08-27T00:00:00Z" passed until 2026-08-27 and then broke three tests
# at once, on main, with nothing about the code changed. Relative stamps
# cannot rot.
RNEW=$(date -u -v+3d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -u -d '+3 days' '+%Y-%m-%dT00:00:00Z')
ROLD=$(date -u -v-4d '+%Y-%m-%dT00:00:00Z' 2>/dev/null || date -u -d '-4 days' '+%Y-%m-%dT00:00:00Z')

st() { python3 - "$T" <<'PY'
import sys, json, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
print(json.dumps(core.read_overage_meter()))
PY
}

# --- 1. THE HEADLINE: absolute meter, not the observed delta ----------------
# The real hub shape: tracking began minutes ago, meter already deep in the
# thousands. The delta across these samples is $27.87. The truth is $18,863.13.
cat > "$T/logs/extra-usage.csv" <<EOF
ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage
$(D 2),100,100,$RNEW,1,18835.26,0,1
$(D 1),100,100,$RNEW,1,18851.00,0,1
$(D 0),100,100,$RNEW,1,18863.13,0,1
EOF
S=$(st)
python3 - "$S" <<'PY' && ok || bad "the weekly overage must be the ABSOLUTE meter, not the sampled delta"
import json, sys
s = json.loads(sys.argv[1])
assert s["used_usd"] == 18863.13, s
# The delta this replaces would be 27.87. Asserting the wrong answer is NOT
# produced matters as much as asserting the right one: 27.87 is a plausible
# small number, which is exactly why the bug survived.
assert s["used_usd"] != 27.87, "still reporting the in-window delta"
PY

# --- 2. the actionable state travels with the number ------------------------
# The number alone does not tell anyone what to DO. "In overage, every call
# billing cash until <reset>" is the part someone acts on.
python3 - "$S" "$RNEW" <<'PY' && ok || bad "overage_state must carry enabled/in_overage/resets_at"
import json, sys
s = json.loads(sys.argv[1])
assert s["extra_usage_enabled"] is True, s
assert s["in_overage"] is True, s
assert s["weekly_resets_at"] == sys.argv[2], s
# spend_limit_reached is reported as observed. It means "a cap was hit", NOT
# "a cap exists" — the CSV carries no limit value, so no caller can honestly
# render "no cap" from this. Pinned so nobody infers it later.
assert s["spend_limit_reached"] is False, s
assert "spend_limit_usd" not in s, "the CSV cannot support a limit figure — do not invent one"
PY

# --- 3. tracking_since kills the same bug for the 24h delta -----------------
# cash_overage_24h stays a delta (it is "what accrued today"), so it inherits
# the same blindness whenever the tracker has been up for less than the window.
# The fix is not to hide it but to publish how far back the meter is actually
# observed, so a low delta can be read correctly instead of trusted blindly.
python3 - "$S" <<'PY' && ok || bad "overage_state must report how long the meter has been observed"
import json, sys
s = json.loads(sys.argv[1])
assert s["tracking_since"].endswith("Z") and s["tracking_since"] < s["observed_at"], s
assert s["samples"] == 3, s
PY

# --- 4. THE RESET BOUNDARY ---------------------------------------------------
# The meter zeroes at the weekly reset. The latest value is therefore already
# "since the latest reset" BY CONSTRUCTION — reading it absolute needs no
# reset arithmetic at all, which is why this is simpler than the delta it
# replaces rather than more complex.
cat > "$T/logs/extra-usage.csv" <<EOF
ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage
$(D 5),100,100,$ROLD,1,9000.00,0,1
$(D 4),100,100,$ROLD,1,9500.00,0,1
$(D 3),10,12,$RNEW,1,0.00,0,0
$(D 2),40,45,$RNEW,1,120.50,0,0
EOF
S=$(st)
python3 - "$S" "$RNEW" <<'PY' && ok || bad "after a reset the meter must report the NEW window, not the old total"
import json, sys
s = json.loads(sys.argv[1])
assert s["used_usd"] == 120.50, s
assert s["weekly_resets_at"] == sys.argv[2], s
# The previous window's $9,500 is deliberately NOT added. It belongs to a
# different billing window, and part of it may pre-date the 7d cost window
# entirely — adding it would overstate exactly as surely as the delta
# understated. The exclusion is REPORTED, not silent.
assert s["prior_window_excluded_usd"] == 9500.00, s
PY

# --- 5. a box with no meter reports unknown, never zero ---------------------
# A missing meter and a genuinely quiet week are indistinguishable as numbers
# and must not read the same. This is the rule the delta version already got
# right, kept.
rm -f "$T/logs/extra-usage.csv"
python3 - "$(st)" <<'PY' && ok || bad "a missing meter must be unknown (None), not 0.00"
import json, sys
s = json.loads(sys.argv[1])
assert s is None or s.get("used_usd") is None, s
PY

# A file with only a header is the same case: measured nothing, know nothing.
printf '%s\n' 'ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage' \
  > "$T/logs/extra-usage.csv"
python3 - "$(st)" <<'PY' && ok || bad "a header-only meter file must be unknown, not 0.00"
import json, sys
s = json.loads(sys.argv[1])
assert s is None or s.get("used_usd") is None, s
PY

# --- 6. a malformed row must not take the whole rollup down -----------------
# The rollup writes summary.json for the entire fleet; an exception here means
# no snapshot at all rather than a degraded one.
cat > "$T/logs/extra-usage.csv" <<EOF
ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage
$(D 2),100,100,$RNEW,1,not-a-number,0,1
$(D 1),100,100,$RNEW,1,500.00,0,1
EOF
python3 - "$(st)" <<'PY' && ok || bad "a malformed row must be skipped, not raise"
import json, sys
s = json.loads(sys.argv[1])
assert s["used_usd"] == 500.00, s
PY

# --- 7. the caption must say the account is STILL BILLING ------------------
# The dollar figure says how bad it got; only this says it is ongoing. That is
# the actionable half, and arguably bigger than the number.
python3 - "$T" <<'PYX' && ok || bad "cash_note must announce an active overage and its reset time"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
live = {"in_overage": True, "weekly_resets_at": "2026-08-27T00:00:00Z",
        "prior_window_excluded_usd": None}
n = core.cash_note(18863.13, 0, 0, live)
assert "IN OVERAGE" in n, n
assert "2026-08-27T00:00:00Z" in n, n
assert "billing cash" in n, n
# The two windows differ and the caption must not imply otherwise.
assert "WEEKLY" in n or "weekly" in n, n

# Not in overage: no alarm text. A caption that always shouts gets ignored.
calm = core.cash_note(120.50, 0, 0, {"in_overage": False, "prior_window_excluded_usd": None})
assert "IN OVERAGE" not in calm, calm

# A reset inside the window must disclose what was excluded, with the amount,
# so the exclusion cannot be mistaken for the figure being complete.
reset = core.cash_note(120.50, 0, 0,
                       {"in_overage": False, "prior_window_excluded_usd": 9500.0})
assert "9500.0" in reset and "EXCLUDES" in reset, reset
assert "low by up to" in reset, reset

# No meter at all: still the unknown wording, never a confident zero.
assert "UNKNOWN" in core.cash_note(None, 0, 0, None)
PYX

# --- 8. THE SEAM: cash_overage_7d must come from the METER, not the delta ---
# Sections 1-7 cover the unit (overage_state) and the reading (cash_note).
# Neither touches the WIRING, and reverting that one line to overage_delta(7)
# restores the whole $18,863-reported-as-$4.33 bug with every other assertion
# still green. Verified: without this section that mutation passes.
python3 - "$T" <<'PYZ' && ok || bad "cash_overage_7d must be the absolute meter, not a delta"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
state = {"used_usd": 18863.13, "tracking_since": "2026-08-24T18:42:00Z",
         "observed_at": "2026-08-24T20:12:00Z", "samples": 3,
         "extra_usage_enabled": True, "in_overage": True,
         "weekly_resets_at": "2026-08-27T00:00:00Z", "spend_limit_reached": False,
         "prior_window_excluded_usd": None}
# delta_24h is deliberately a SMALL number, the shape the bug produced, so a
# wire-up that fed the delta into the 7d slot cannot coincide with the truth.
f = core.overage_fields(state, 27.87)
assert f["cash_overage_7d"] == 18863.13, f
assert f["cash_overage_7d"] != 27.87, "the 7d field is being fed the delta again"
assert f["cash_overage_24h"] == 27.87, f
# The state must ride along, or the dashboard cannot say it is ongoing.
assert f["overage_state"]["in_overage"] is True, f
assert f["overage_state"]["resets_at"] == "2026-08-27T00:00:00Z", f
assert f["overage_tracking_since"] == "2026-08-24T18:42:00Z", f

# No meter: every field unknown, and NOT zero. overage_samples is the one
# honest zero -- we genuinely observed no samples.
n = core.overage_fields(None, None)
assert n["cash_overage_7d"] is None and n["overage_state"] is None, n
assert n["overage_samples"] == 0, n
PYZ

# --- 9. THE PUBLISHED CONTRACT: overage_meter_usd + overage_state -----------
# overage_meter_usd is the dashboard's GATE: the cash line renders only when it
# is non-null, so a snapshot from a pre-fix rollup shows "measuring" instead of
# a plausible-looking wrong figure. That is why it is a NEW field rather than a
# semantics change to an existing one -- it makes merge and deploy order across
# rollup, console and SPA irrelevant in every ordering. Renaming or nulling it
# for a live meter silently blanks the dashboard, so the name is pinned here.
python3 - "$T" <<'PYQ' && ok || bad "the published overage contract must be emitted exactly"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
state = {"used_usd": 18863.13, "tracking_since": "2026-08-24T18:42:00Z",
         "observed_at": "2026-08-24T20:12:00Z", "samples": 3,
         "extra_usage_enabled": True, "in_overage": True,
         "weekly_resets_at": "2026-08-27T00:00:00Z", "spend_limit_reached": False,
         "prior_window_excluded_usd": None}
f = core.overage_fields(state, 27.87)

assert f["overage_meter_usd"] == 18863.13, f
os_ = f["overage_state"]
assert set(os_) == {"enabled", "in_overage", "resets_at", "spend_limit_reached"}, os_
assert os_["enabled"] is True and os_["in_overage"] is True, os_
assert os_["resets_at"] == "2026-08-27T00:00:00Z", os_
assert os_["spend_limit_reached"] is False, os_

# The alias is DERIVED, not recomputed, so the two cannot drift apart.
assert f["cash_overage_7d"] == f["overage_meter_usd"], f
# ...and neither is the 24h delta, which is a different question.
assert f["cash_overage_24h"] == 27.87, f

# No meter: the gate must be null so the dashboard says "measuring" rather
# than rendering a confident zero. overage_samples is the one honest 0.
n = core.overage_fields(None, None)
assert n["overage_meter_usd"] is None, n
assert n["overage_state"] is None, n
assert n["cash_overage_7d"] is None, n
assert n["overage_samples"] == 0, n
PYQ

# --- 10. THE HEADLINE TOTAL must add the METER, not a delta ----------------
# fleet_cash_7d_total is the one number answering "what did the fleet actually
# spend". Swapping the meter for the 24h delta here restores the whole
# understatement on the biggest figure in the system, and section 9 does not
# see it -- verified: that mutation passed 12/12 before this section existed.
# Third instance of the same shape this session, so it gets its own assertion
# rather than a comment saying to be careful.
python3 - "$T" <<'PYW' && ok || bad "fleet_cash_7d_total must add the absolute meter, not a delta"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
# Metered-lane cash $100, meter $18,863.13, and a small delta that must NOT be
# what lands in the total.
# It is handed the WHOLE overage block and must pick the meter itself. Both
# candidate keys are present with very different values, so picking the wrong
# one cannot coincide with the right answer.
block = {"overage_meter_usd": 18863.13, "cash_overage_24h": 27.87,
         "cash_overage_7d": 18863.13}
assert core.fleet_cash_total(100.0, block) == 18963.13, core.fleet_cash_total(100.0, block)
assert core.fleet_cash_total(100.0, block) != 127.87, "the total is adding the 24h delta"
# Unknown overage must not read as zero: a total of exactly the metered cash
# would look like a complete answer while the overage was simply unmeasured.
assert core.fleet_cash_total(100.0, {"overage_meter_usd": None}) is None
assert core.fleet_cash_total(100.0, None) is None
PYW

# --- 11. THE POST-RESET BLIND WINDOW ----------------------------------------
# The meter is cumulative since the weekly reset, but the newest SAMPLE can
# predate the reset it names. Latest sample 03:58 carrying resets_at 04:00,
# rollup runs 04:05: the sample describes a window that has ENDED, while the
# current window is five minutes old at roughly nothing. Reporting the sample
# hands over $18,863 as "this week" — in the confident direction, folded into
# the headline total, with prior_window_excluded_usd null because every row
# shares the same stale resets_at, so the block is self-consistently
# describing the wrong week and nothing contradicts it.
#
# A window with no sample yet is the same class as a missing meter: unknown,
# not zero and not stale. So the meter goes null and the gate closes.
python3 - "$T" "$(python3 -c "
import datetime
n=datetime.datetime.utcnow()
print((n-datetime.timedelta(minutes=7)).strftime('%Y-%m-%dT%H:%M:%SZ'))
print((n-datetime.timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%M:%SZ'))" | tr '\n' ' ')" <<'PYV' && ok || bad "a sample from an ENDED weekly window must not be reported as the current one"
import sys, importlib.util, csv, os
T = sys.argv[1]
sample_ts, reset_ts = sys.argv[2].split()
with open(f"{T}/logs/extra-usage.csv", "w") as f:
    f.write("ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage\n")
    # EVERY row carries the now-past reset stamp -- the self-consistent shape.
    f.write(f"{sample_ts},100,100,{reset_ts},1,18863.13,0,1\n")
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
st = core.read_overage_meter()
assert st["used_usd"] is None, f"stale window reported as current: {st}"
assert st["window_stale"] is True, st
# The stale figure is not destroyed, just demoted out of the live field, so
# the reading stays explainable rather than mysteriously blank.
assert st["last_window_usd"] == 18863.13, st

# ...and the gate must close so the dashboard says "measuring".
f2 = core.overage_fields(st, 1.23)
assert f2["overage_meter_usd"] is None, f2
assert f2["cash_overage_7d"] is None, f2
assert f2["overage_state"] is None, "the state describes the window that ended"
# The headline total must not be built on it either.
assert core.fleet_cash_total(100.0, f2) is None, core.fleet_cash_total(100.0, f2)
PYV

# A reset stamp still in the FUTURE is the normal case and must be untouched --
# a freshness guard that fires all the time would blank the dashboard forever,
# which is the failure this whole PR exists to avoid, inverted.
python3 - "$T" "$(python3 -c "
import datetime
n=datetime.datetime.utcnow()
print((n-datetime.timedelta(minutes=5)).strftime('%Y-%m-%dT%H:%M:%SZ'))
print((n+datetime.timedelta(days=2)).strftime('%Y-%m-%dT%H:%M:%SZ'))" | tr '\n' ' ')" <<'PYV' && ok || bad "a live window must still report its meter"
import sys, importlib.util
T = sys.argv[1]
sample_ts, reset_ts = sys.argv[2].split()
with open(f"{T}/logs/extra-usage.csv", "w") as f:
    f.write("ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage\n")
    f.write(f"{sample_ts},100,100,{reset_ts},1,18863.13,0,1\n")
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
st = core.read_overage_meter()
assert st["used_usd"] == 18863.13, st
assert st["window_stale"] is False, st
assert core.overage_fields(st, 1.0)["overage_meter_usd"] == 18863.13
PYV

# An UNPARSEABLE reset stamp must not blank the line. We cannot verify
# freshness, so we report the number and say freshness is unverified -- a
# parse quirk taking out the whole cash line would be a self-inflicted outage,
# and this failure direction is visible rather than silent.
python3 - "$T" <<'PYV' && ok || bad "an unparseable reset stamp must degrade to unverified, not blank"
import sys, importlib.util
T = sys.argv[1]
with open(f"{T}/logs/extra-usage.csv", "w") as f:
    f.write("ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage\n")
    f.write("2026-08-24T10:00:00Z,100,100,not-a-timestamp,1,4242.00,0,1\n")
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
st = core.read_overage_meter()
assert st["used_usd"] == 4242.00, st
assert st["window_verified"] is False, st
assert st["window_stale"] is False, st
PYV

# --- 12. the excluded prior window must never be ADDED to the total ---------
# The guard's whole point is that the figure is REPORTED and not folded in.
# Only the reporting half was pinned: making fleet_cash_7d_total add it left
# the suite green, and "it is right there in the block, just add it" is
# precisely the tempting mistake.
python3 - "$T" <<'PYV' && ok || bad "prior_window_excluded_usd must never be added to the headline total"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
block = {"overage_meter_usd": 120.50, "prior_window_excluded_usd": 9500.0,
         "cash_overage_24h": 3.0}
total = core.fleet_cash_total(100.0, block)
assert total == 220.50, f"the excluded prior window was folded in: {total}"
assert total != 9720.50, "prior_window_excluded_usd must not be added"
PYV

# --- 13. the note must disclose the window mismatch -------------------------
# cash_overage_7d is a WEEKLY-window figure added to a strict-7d cost total:
# same length, different window. The field name cannot say that, so the note
# has to, and stripping the wording left the suite green.
python3 - "$T" <<'PYV' && ok || bad "the note must say the overage window differs from the 7d cost window"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
n = core.cash_note(18863.13, 0, 0, {"in_overage": False, "prior_window_excluded_usd": None})
low = n.lower()
assert "weekly" in low, n
assert "different window" in low or "not the same window" in low, n
PYV

# --- 14. CROSS-REPO CONTRACT: the names spend.js reads must be emitted ------
# The dashboard and the rollup live in one repo but are wired only by STRING
# FIELD NAMES across a JSON snapshot, and nothing checked that they agree. A
# name the SPA reads and the rollup never writes fails silently and in the
# worst possible way: the rollup computes the right number, the snapshot looks
# healthy to anyone eyeballing it, and the screen stays dark or blank. An
# eyeball check of the snapshot PASSES while the UI shows nothing.
#
# This reads the actual consumer source rather than a copy of its field list,
# so renaming on either side breaks the test instead of the dashboard.
python3 - "$DIR" <<'PYX' && ok || bad "spend.js reads a field the rollup never emits"
import re, sys
DIR = sys.argv[1]
spa = open(f"{DIR}/console-ui/src/lib/spend.js").read()
roll = open(f"{DIR}/bin/cost-rollup.sh").read()

# What the consumer reads off the costs object.
read = set(re.findall(r"\bc\.([a-z_0-9]+)", spa))

# Fields this rollup owns. Others on the costs object (spend_stale, spend_age_min,
# spend_unavailable, ...) are stamped by the console worker, not here, so they
# are deliberately out of scope rather than silently ignored.
OWNED = {
    "overage_meter_usd", "overage_state", "cash_overage_7d", "cash_note",
    "fleet_cash_7d", "fleet_cash_7d_total", "fleet_notional_7d",
    "fleet_unknown_billing_calls_7d", "fleet_unknown_billing_calls_24h",
}
missing = sorted(n for n in (read & OWNED) if f'"{n}"' not in roll)
assert not missing, f"spend.js reads these, cost-rollup.sh never emits them: {missing}"

# The nested keys inside overage_state, read as over.<key> in the SPA.
nested = set(re.findall(r"\bover\.([a-z_0-9]+)", spa))
CONTRACT = {"enabled", "in_overage", "resets_at", "spend_limit_reached"}
assert nested <= CONTRACT, f"spend.js reads an overage_state key outside the contract: {nested - CONTRACT}"
for k in nested:
    assert f'"{k}":' in roll, f"overage_state.{k} is read by spend.js but never emitted"

# And the gate itself, by name -- renaming it silently blanks the cash line.
assert "overage_meter_usd" in read, "spend.js no longer gates on overage_meter_usd; the contract moved"
PYX

# --- 15. THE REAL TIMESTAMP FORMAT (production crash, 2026-08-24) ----------
# Every fixture above writes reset stamps as "2026-08-27T00:00:00Z". The
# TRACKER writes the endpoint's own stamp, which is TZ-AWARE with an offset:
#
#     2026-08-27T03:59:59.110228+00:00
#
# fromisoformat gives an AWARE datetime for that, `now` is naive utcnow(), and
# the freshness comparison sits outside the ValueError guard — so it raised
# TypeError and killed the whole python block. The rollup then fell through
# (the script is -uo pipefail, not -e), pushed the STALE summary, and logged
# "summary written". First deploy of the guard took the dashboard down to
# last hour's numbers while reporting success.
#
# The fixtures were the bug: hand-written stamps in a format the producer never
# emits. This section uses the real string VERBATIM, and the naive form beside
# it, so the parse handles both shapes rather than trading one for the other.
python3 - "$T" <<'PYT' && ok || bad "the REAL tz-aware reset stamp must parse, not raise"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)

hdr = ("ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,"
       "extra_used_usd,spend_limit_reached,in_overage\n")

# (a) the verbatim production stamp, comfortably in the FUTURE -> live window.
with open(f"{T}/logs/extra-usage.csv", "w") as f:
    f.write(hdr)
    f.write("2026-08-24T20:58:00Z,100,100,2126-08-27T03:59:59.110228+00:00,1,18863.13,0,1\n")
st = core.read_overage_meter()          # must not raise
assert st["used_usd"] == 18863.13, st
assert st["window_stale"] is False, st
assert st["window_verified"] is True, f"an aware stamp is parseable and must count as verified: {st}"

# (b) same real format, but already PAST -> the stale-window guard still fires.
# Both halves matter: fixing the crash by giving up on the guard would pass (a)
# and silently reintroduce blocker 1.
with open(f"{T}/logs/extra-usage.csv", "w") as f:
    f.write(hdr)
    f.write("2020-01-01T00:00:00Z,100,100,2020-01-02T03:59:59.110228+00:00,1,18863.13,0,1\n")
st = core.read_overage_meter()
assert st["used_usd"] is None, f"a PAST aware stamp must still be caught as stale: {st}"
assert st["window_stale"] is True, st

# (c) a NON-UTC offset must be converted, not truncated. Stripping the offset
# instead of converting would mis-order by up to a day at the boundary.
with open(f"{T}/logs/extra-usage.csv", "w") as f:
    f.write(hdr)
    f.write("2020-01-01T00:00:00Z,100,100,2020-01-02T03:59:59.110228-05:00,1,50.00,0,1\n")
st = core.read_overage_meter()
assert st["window_stale"] is True, st

# (d) the naive "Z" form every earlier fixture uses must keep working.
with open(f"{T}/logs/extra-usage.csv", "w") as f:
    f.write(hdr)
    f.write("2026-08-24T10:00:00Z,100,100,2126-08-27T00:00:00Z,1,77.00,0,1\n")
st = core.read_overage_meter()
assert st["used_usd"] == 77.00, st
assert st["window_stale"] is False, st
PYT

echo "overage-absolute-test: $PASS pass, $FAIL fail"
echo "NOTE: the \$ scaling comes from the endpoint's own decimal_places. That has"
echo "      NOT been checked against Anthropic's billing dashboard, and it is now"
echo "      the headline number — one manual reconciliation is warranted."
[ "$FAIL" -eq 0 ]
