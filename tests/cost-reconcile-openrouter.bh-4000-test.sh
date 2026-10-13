#!/bin/bash
# tests/cost-reconcile-openrouter.bh-4000-test.sh — BH-4000 (BH-3983.2), the
# daily OpenRouter reconcile inside bin/cost-reconcile.sh: the
# `# >>> openrouter reconcile (BH-3983)` block that calls #3998's
# or_ledger_compare and alerts when OpenRouter's bill and our openrouter cost
# rows disagree by more than 15% AND $20, once a UTC day.
#
# Driven through the real script (env -i, a scratch $HARNESS, a PATH curl stub
# playing the jobs worker), never through the lib alone.
#
#   R1  $200 billed vs $100 of rows: one alert across two runs, two log lines
#       (alerted=1 then 0), the day flag, one account=openrouter pushed row
#   R2  a 5% gap: no alert
#   R3  $30 / 30%: alert; exactly $20 (33%): no alert (strict)
#   R4  OPENROUTER_RECONCILE_KEYS narrows to the named key; unset, account scope
#   R5  a named key missing from b: state=unread, no alert, no flag
#   R6  only auth-failed vendor rows: state=no-meter, no alert
#   R7  the lib's page cap hit: state=unread, no alert
#   R8  --window 1h: the block does not run
#   R9  --dry-run: `would alert`, no flag, no alert, nothing pushed
#   R10 RECONCILE_OR=0: the block does not run
#   R11 blank cost rows: unpriced=2 in the log and `2 unpriced` in the alert
#   R12 invalid threshold knobs fall back to 15 and 20
#   R13 the lib absent: state=no-lib, one line, no alert, nothing pushed
#   R14 --window day YYYY-MM-DD --dry-run (the by-hand form the map documents) runs the block
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
NOW=$(python3 -c 'import time; print(int(time.time()))')
DAY=$(python3 -c 'import sys,time; print(time.strftime("%Y%m%d", time.gmtime(int(sys.argv[1]))))' "$NOW")
iso() { python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' "$1"; }
VA=$(iso $((NOW - 23*3600))); VB=$(iso $((NOW - 600)))
R_1=$(iso $((NOW - 20*3600))); R_2=$(iso $((NOW - 10*3600))); R_3=$(iso $((NOW - 5*3600)))

mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/logs" "$T/flags" "$T/catalog" "$T/api" "$T/fakebin"
cp "$DIR/bin/cost-reconcile.sh" "$DIR/bin/jobs-client.sh" "$T/bin/"
scratch_install_closure bin/alert-line.sh "$T" >/dev/null || { echo "FAIL: closure bin/alert-line.sh"; exit 1; }
scratch_install_closure bin/cost-reconcile.sh "$T" >/dev/null || { echo "FAIL: closure bin/cost-reconcile.sh"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$T" >/dev/null || { echo "FAIL: closure bin/jobs-client.sh"; exit 1; }
chmod +x "$T/bin/cost-reconcile.sh"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
# The real alert writer: with no beat.sh in the tree it still appends the line
# to logs/ALERTS.log, which is what every alert assertion below reads.
cp "$DIR/bin/alert-line.sh" "$T/bin/"
# One account, so the script gets past its "account map has no accounts" exit.
cat > "$T/catalog/cost-accounts.json" <<'EOF'
{"anthropic_runners": ["claude"],
 "accounts": {"acct": {"auth_accounts": ["claude:x@y"], "boxes": {"cost_rows": ["hub"], "jobs": ["hub"]}}}}
EOF

# The worker: vendor-spend (vendor/since, newest first, cap 1000), cost-rows
# (since/until/runner/box/auth_account, newest first, limit honoured, cap 2000),
# extra-usage and jobs empty, the reconcile POST into $RECONCILE_SINK.
cat > "$T/fakebin/curl" <<'CURL'
#!/usr/bin/env python3
import json, os, sys, urllib.parse
argv = sys.argv[1:]
url = next((a for a in argv if a.startswith("http")), "")
method, body, i = "GET", None, 0
while i < len(argv):
    if argv[i] == "-X":
        method = argv[i + 1]; i += 2
    elif argv[i] in ("--data-binary", "-d", "--data"):
        body = argv[i + 1]; i += 2
    else:
        i += 1
if body and body.startswith("@"):
    body = open(body[1:]).read()
API = os.environ["API_DIR"]
u = urllib.parse.urlparse(url)
q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
def load(name):
    try:
        return json.load(open(os.path.join(API, name)))
    except Exception:
        return []
def answer(payload, code=200):
    sys.stdout.write(json.dumps(payload) + "\n" + str(code)); raise SystemExit(0)
if u.path == "/api/metrics/reconcile" and method == "POST":
    with open(os.environ["RECONCILE_SINK"], "a") as fh:
        fh.write((body or "") + "\n")
    answer({"accepted": 1})
if u.path == "/api/metrics/vendor-spend":
    rows = [r for r in load("vendor.json") if (not q.get("vendor") or r["vendor"] == q["vendor"])
            and (not q.get("since") or r["ts"] >= q["since"])]
    rows.sort(key=lambda r: r["ts"], reverse=True)
    answer({"vendor_spend": rows[:min(int(q.get("limit", 200)), 1000)]})
if u.path == "/api/metrics/cost-rows":
    rows = load("cost-rows.json")
    for k in ("runner", "box", "auth_account"):
        if q.get(k):
            rows = [r for r in rows if (r.get(k) or "") == q[k]]
    rows = [r for r in rows if (not q.get("since") or r["ts"] >= q["since"])
            and (not q.get("until") or r["ts"] <= q["until"])]
    rows.sort(key=lambda r: r["ts"], reverse=True)
    answer({"cost_rows": rows[:min(int(q.get("limit", 200)), 2000)]})
if u.path == "/api/metrics/extra-usage":
    answer({"snapshots": []})
if u.path == "/api/jobs":
    answer({"jobs": []})
answer({"error": "unstubbed " + u.path}, 404)
CURL
chmod +x "$T/fakebin/curl"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "[$3] in [$2]" ;; *) ok "$1" ;; esac; }

# vendor <ts> <status> <cumulative|-> <raw-json|-> ...   (raw stored as a JSON STRING, as the route does)
vendor() { python3 - "$@" > "$T/api/vendor.json" <<'PY'
import json, sys
a = sys.argv[1:]; out = []
while a:
    ts, st, cum, raw = a[:4]; a = a[4:]
    out.append({"vendor": "openrouter", "ts": ts, "status": st, "usd": None, "kind": "metered",
                "cumulative_usd": None if cum == "-" else float(cum), "note": "",
                "raw": None if raw == "-" else raw})
out.append({"vendor": "xai", "ts": out[0]["ts"], "status": "ok", "cumulative_usd": 5.0, "raw": None})
json.dump(out, sys.stdout)
PY
}
# rows <ts> <runner> <cost|""> ...
rows() { python3 - "$@" > "$T/api/cost-rows.json" <<'PY'
import json, sys
a = sys.argv[1:]; out = []
while a:
    ts, runner, cost = a[:3]; a = a[3:]
    out.append({"box": "hub", "row_hash": "h%d" % len(out), "ts": ts, "host": "hub", "project": "p",
                "stage": "s", "runner": runner, "model": "m", "rc": 0, "auth_account": "",
                "cost_usd": None if cost == "" else float(cost), "note": ""})
json.dump(out, sys.stdout)
PY
}
run() { # run <args...>: the log, ALERTS.log and push sink are per run; flags/ is not
  : > "$T/logs/cost-reconcile.log"; : > "$T/logs/ALERTS.log"; : > "$T/pushed"
  env -i PATH="$T/fakebin:$PATH" HOME="$T" HARNESS="$T" API_DIR="$T/api" JOBS_RETRIES=0 \
    RECONCILE_SINK="$T/pushed" ${RUN_ENV:-} \
    bash "$T/bin/cost-reconcile.sh" "$@" >"$T/out" 2>"$T/err"
}
fresh() { rm -f "$T/flags"/alerted-cost-reconcile-*; }
orlog()  { grep 'cost-reconcile openrouter' "$T/logs/cost-reconcile.log"; }
nalert() { grep -c . "$T/logs/ALERTS.log"; }
orrow()  { jq -c '.rows[] | select(.account == "openrouter")' "$T/pushed" 2>/dev/null; }
FLAG="$T/flags/alerted-cost-reconcile-openrouter-$DAY"
r1_fixture() {
  vendor "$VA" ok 1000.00 - "$VB" ok 1200.00 -
  rows "$R_1" openrouter 60.00 "$R_2" openrouter 40.00 "$R_3" claude 500.00
}

# ── R1 ──
r1_fixture; fresh
run --window 24h; L1=$(orlog); A1=$(cat "$T/logs/ALERTS.log"); P1=$(orrow)
run --window 24h; L2=$(orlog); A2=$(cat "$T/logs/ALERTS.log")
check "R1 one alert across two runs" "$(printf '%s%s' "$A1" "$A2" | grep -c .)" 1
for s in 'OPENROUTER RECONCILE' '$200' '$100' '50' 'scope=account' 'OPENROUTER_RECONCILE_KEYS'; do
  has "R1 alert names $s" "$A1" "$s"
done
hasnt "R1 alert has no em dash" "$A1" "—"
has "R1 first log line, alerted=1" "$L1" 'cost-reconcile openrouter 24h scope=account state=ok vendor=$200.00 rows=$100.00'
has "R1 first run alerted=1" "$L1" 'alerted=1'
has "R1 second log line" "$L2" 'cost-reconcile openrouter 24h scope=account state=ok vendor=$200.00 rows=$100.00'
has "R1 second run alerted=0" "$L2" 'alerted=0'
check "R1 one line per run" "$(printf '%s\n' "$L1" | grep -c .)" 1
[ -f "$FLAG" ] && ok "R1 day flag written" || bad "R1 day flag written" "$FLAG missing"
check "R1 pushed openrouter row" "$(printf '%s' "$P1" | jq -r '[.state, .alerted, .meter_delta_usd, .rows_usd, .rows_count, .window_key] | map(if type == "number" then (. + 0 | tostring) else tostring end) | join(" ")')" "ok 1 200 100 2 24h"
has "R1 audit command in the alert" "$A1" "bin/openrouter-audit.sh --since $VA --until $VB"

# ── R2 ──
vendor "$VA" ok 1000.00 - "$VB" ok 1200.00 -
rows "$R_1" openrouter 190.00
fresh; run --window 24h
check "R2 no alert on 5%" "$(nalert)" 0
has "R2 log alerted=0" "$(orlog)" 'alerted=0'
has "R2 log carries the pct" "$(orlog)" '(5.0%)'

# ── R3 ──
vendor "$VA" ok 1000.00 - "$VB" ok 1100.00 -
rows "$R_1" openrouter 70.00
fresh; run --window 24h
check "R3 \$30 / 30% alerts" "$(nalert)" 1
vendor "$VA" ok 1000.00 - "$VB" ok 1060.00 -
rows "$R_1" openrouter 40.00
fresh; run --window 24h
check "R3 exactly \$20 does not alert" "$(nalert)" 0
has "R3 exactly \$20 logs alerted=0" "$(orlog)" 'gap=$20.00 (33.3%) alerted=0'

# ── R4 ──
RA='{"keys":[{"name":"harness-a","usage":50},{"name":"project-4-app","usage":0}]}'
RB='{"keys":[{"name":"harness-a","usage":150},{"name":"project-4-app","usage":900}]}'
vendor "$VA" ok 1000.00 "$RA" "$VB" ok 2000.00 "$RB"
rows "$R_1" openrouter 95.00
fresh; RUN_ENV="OPENROUTER_RECONCILE_KEYS=harness-a" run --window 24h
check "R4 harness keys: no alert" "$(nalert)" 0
has "R4 harness-keys scope" "$(orlog)" 'scope=harness-keys state=ok vendor=$100.00 rows=$95.00'
hasnt "R4 no key name in the log" "$(orlog)" 'harness-a'
fresh; run --window 24h
check "R4 account scope alerts" "$(nalert)" 1
has "R4 account alert says scope=account" "$(cat "$T/logs/ALERTS.log")" 'scope=account'

# ── R5 ──
vendor "$VA" ok 1000.00 "$RA" "$VB" ok 2000.00 '{"keys":[{"name":"project-4-app","usage":900}]}'
fresh; RUN_ENV="OPENROUTER_RECONCILE_KEYS=harness-a" run --window 24h
has "R5 missing key is unread" "$(orlog)" 'state=unread'
has "R5 unread logs n/a, not zero" "$(orlog)" 'vendor=$n/a'
check "R5 no alert" "$(nalert)" 0
[ ! -f "$FLAG" ] && ok "R5 no flag" || bad "R5 no flag"

# ── R6 ──
vendor "$VA" auth-failed - - "$VB" auth-failed - -
rows "$R_1" openrouter 10.00
fresh; run --window 24h
has "R6 no-meter" "$(orlog)" 'state=no-meter'
check "R6 no alert" "$(nalert)" 0

# ── R7 ──
vendor "$VA" ok 1000.00 - "$VB" ok 1200.00 -
rows "$R_1" openrouter 40.00 "$R_2" openrouter 30.00 "$R_3" openrouter 30.00
fresh; RUN_ENV="COST_ROWS_READ_LIMIT=2 COST_ROWS_READ_PAGES=1" run --window 24h
has "R7 capped rows read is unread" "$(orlog)" 'state=unread'
check "R7 no alert" "$(nalert)" 0

# ── R8 ──
r1_fixture; fresh; run --window 1h
check "R8 1h writes no openrouter line" "$(orlog | grep -c .)" 0
check "R8 1h no alert" "$(nalert)" 0

# ── R9 ──
fresh; run --window 24h --dry-run
has "R9 dry run says would alert" "$(orlog)" 'alerted=0 would alert'
check "R9 dry run no alert" "$(nalert)" 0
[ ! -f "$FLAG" ] && ok "R9 dry run no flag" || bad "R9 dry run no flag"
[ ! -s "$T/pushed" ] && ok "R9 dry run pushes nothing" || bad "R9 dry run pushes nothing" "$(cat "$T/pushed")"

# ── R10 ──
fresh; RUN_ENV="RECONCILE_OR=0" run --window 24h
check "R10 RECONCILE_OR=0 writes no line" "$(orlog | grep -c .)" 0
check "R10 no alert" "$(nalert)" 0
fresh; RUN_ENV="RECONCILE_OR=x" run --window 24h
check "R10 an invalid RECONCILE_OR counts as on" "$(nalert)" 1

# ── R11 ──
vendor "$VA" ok 1000.00 - "$VB" ok 1200.00 -
rows "$R_1" openrouter 60.00 "$R_2" openrouter 40.00 "$R_3" claude 500.00 "$R_2" openrouter "" "$R_3" openrouter ""
fresh; run --window 24h
has "R11 log unpriced=2" "$(orlog)" 'rows=$100.00 (4) unpriced=2'
has "R11 alert says 2 unpriced" "$(cat "$T/logs/ALERTS.log")" '2 unpriced'

# ── R12 ──
r1_fixture; fresh; RUN_ENV="RECONCILE_OR_GAP_PCT=abc RECONCILE_OR_MIN_USD=" run --window 24h
check "R12 invalid knobs fall back and still alert" "$(nalert)" 1
has "R12 alert names the default thresholds" "$(cat "$T/logs/ALERTS.log")" 'over 15% and $20'
fresh; RUN_ENV="RECONCILE_OR_GAP_PCT=60" run --window 24h
check "R12 a valid knob is honoured (60% > 50% gap)" "$(nalert)" 0

# ── R13 ──
mv "$T/bin/lib/openrouter-ledger.sh" "$T/bin/lib/openrouter-ledger.sh.off"
fresh; run --window 24h
has "R13 no lib logs no-lib" "$(orlog)" "Z cost-reconcile openrouter 24h state=no-lib alerted=0"
check "R13 exactly one line" "$(orlog | grep -c .)" 1
check "R13 no alert" "$(nalert)" 0
check "R13 nothing pushed for openrouter" "$(orrow)" ""
mv "$T/bin/lib/openrouter-ledger.sh.off" "$T/bin/lib/openrouter-ledger.sh"

# ── R14 ──
D14=$(python3 -c 'import sys,time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' "$NOW")
r1_fixture; fresh; run --window day "$D14" --dry-run
has "R14 a named day runs the block" "$(orlog)" "cost-reconcile openrouter day:$D14 scope=account state="
check "R14 dry run, no alert" "$(nalert)" 0

echo "cost-reconcile-openrouter: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
