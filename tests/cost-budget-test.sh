#!/bin/bash
# tests/cost-budget-test.sh — the $/PR budget and the fleet daily ceiling in
# bin/pipeline-health.sh, extracted VERBATIM by their markers and driven with a
# fixture summary.json, a fixture cost.csv and a recording alert().
#
# WHAT IT PINS (2026-09-15, the "project-5 spent $1456 in 24h (cap $300)" page):
#   rate      a project over its $/PR budget pages ONCE, quoting spend, merged
#             PRs, $/PR, the budget and the top 3 stages — and a project that is
#             merely BUSY does not page at all.
#   small n   a project with fewer merged PRs than min_prs_for_rate is never
#             divided by, on either window, and is NAMED instead of skipped.
#   unknown   a merged count that could not be taken (null, the token cannot see
#             the repo) is not zero and not infinity: no rate alert, one line.
#   ceiling   the fleet daily hard ceiling pages separately, off the intraday
#             ledger, naming the biggest spenders.
#   grammar   the old flat "<project> <usd>" rows are refused and reported, not
#             silently reinterpreted as dollars per PR.
#
# Run from anywhere: tests/cost-budget-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/lib" "$T/logs" "$T/state/cost" "$T/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v awk >/dev/null || { echo "jq/awk missing — skipping"; exit 0; }

awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "could not extract the cost budget block — markers missing?"
cp "$DIR/bin/lib/cost-budget.sh" "$T/bin/lib/" && cp "$DIR/bin/lib/cost-budget.sh" "$T/lib/"
# No box is reachable from a fixture, so the ceiling sweep reads logs/cost.csv
# only. An empty tailnet_ip is exactly what the block is built to skip.
printf '#!/bin/bash\nexit 1\n' > "$T/bin/fleet-conf.sh"; chmod +x "$T/bin/fleet-conf.sh"

CONF="$T/caps.conf"
cat > "$CONF" <<'CONF'
default 80 5
budget busy      40 10
budget thin      40  5
budget blind     40  5
budget cheap    500  5
budget weekly    40  5
ceiling 1000
CONF

# summary.json: one project per shape the block has to tell apart.
#   busy   — 90 merged PRs in 24h at $80/PR against a $40 budget: the page
#   cheap  — the same dollars, a $500 budget: silence
#   thin   —  2 merged PRs and $900 spent: never divided by
#   blind  — a count that could not be taken at all
#   weekly —  1 merged PR in 24h but 20 in 7d: judged on the 7d window
cat > "$T/state/cost/summary.json" <<'JSON'
{ "projects": {
  "busy":   {"delivery_cost_24h": 7200, "merged_prs_24h": 90, "cost_7d": 30000, "product_7d": 0,
             "merged_prs_7d": 400, "merged_prs_status": "ok",
             "stages_24h": {"execute": 4000, "preplan": 2000, "review": 900, "fix": 300}},
  "cheap":  {"delivery_cost_24h": 7200, "merged_prs_24h": 90, "cost_7d": 30000, "product_7d": 0,
             "merged_prs_7d": 400, "merged_prs_status": "ok", "stages_24h": {"execute": 7200}},
  "thin":   {"delivery_cost_24h": 900,  "merged_prs_24h": 2,  "cost_7d": 1800, "product_7d": 0,
             "merged_prs_7d": 3, "merged_prs_status": "ok", "stages_24h": {"execute": 900}},
  "blind":  {"delivery_cost_24h": 5000, "merged_prs_24h": null, "cost_7d": 9000, "product_7d": 0,
             "merged_prs_7d": null, "merged_prs_status": "unknown", "merged_prs_token": "none",
             "stages_24h": {"execute": 5000}},
  "weekly": {"delivery_cost_24h": 100,  "merged_prs_24h": 1,  "cost_7d": 2000, "product_7d": 0,
             "merged_prs_7d": 20, "merged_prs_status": "ok", "stages_24h": {"execute": 100},
             "stages_7d": {"execute": 1500, "review": 500}},
  "other":  {"delivery_cost_24h": 99999, "merged_prs_24h": 1, "cost_7d": 0, "product_7d": 0,
             "merged_prs_7d": 1, "merged_prs_status": "ok", "stages_24h": {}}
} }
JSON

# The intraday ledger the CEILING reads: ts,host,project,stage,...,cost_usd is
# column 13. Two rows inside the window, one ancient row that must not count.
cost_csv() { # cost_csv <usd-busy> <usd-thin> [usd-for-the-project-named-fleet]
  local now old
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); old=$(date -u -d '40 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
  { echo "ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd"
    echo "$now,hub,busy,execute,claude,m,0,1,0,0,0,0,$1"
    echo "$now,hub,thin,execute,claude,m,0,1,0,0,0,0,$2"
    # THE LEDGER HAS A PROJECT LITERALLY CALLED `fleet` — orchestrator and
    # remediation spend, ~$137/24h on 2026-09-15. It is in every fixture here on
    # purpose: label the sweep's TOTAL row "fleet" and the two become
    # indistinguishable, which is exactly the shape that ships a ceiling check
    # comparing a two-line string against a number.
    echo "$now,hub,fleet,orchestrator,claude,m,0,1,0,0,0,0,${3:-50}"
    echo "$old,hub,busy,execute,claude,m,0,1,0,0,0,0,99999"
  } > "$T/logs/cost.csv"
}

drive() { # drive [stamp-age-seconds]   -> alerts in $T/alerts.txt
  : > "$T/alerts.txt"
  local age="${1:-99999}"
  echo $(( $(date +%s) - age )) > "$T/state/costbreaker.stamp"
  ( export HARNESS="$T" T="$T" COST_CAPS_CONF="$CONF"
    bash -c '
      set -uo pipefail
      H="$T"; NOW=$(date +%s)
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      . "$0"' "$T/blk.sh" >"$T/out.txt" 2>"$T/err.txt" )
}
akeys() { cut -d'|' -f2 "$T/alerts.txt" 2>/dev/null | sort; }
aline() { grep "^[0-9]*|$1|" "$T/alerts.txt" 2>/dev/null | head -1; }

# ============================================================================
# 1. the RATE
# ============================================================================
cost_csv 10 10
drive

# 1a. busy is over budget: exactly one page, once a day, with all four numbers
N=$(grep -c "^[0-9]*|costrate:busy|" "$T/alerts.txt")
L=$(aline "costrate:busy")
[ "$N" = 1 ] && ok || bad "busy should page exactly once per run, got $N: $(cat "$T/alerts.txt")"
grep -q '^86400|costrate:busy|' <<<"$L" \
  && grep -q '\$80.00 per merged PR over 24h' <<<"$L" \
  && grep -q '\$7200 delivery spend / 90 merged PRs' <<<"$L" \
  && grep -q 'budget of \$40/PR' <<<"$L" \
  && ok || bad "the rate line must carry spend, PRs, \$/PR and the budget: $L"
# the top 3 stages by cost, and only three
grep -q 'Top stages: execute \$4000, preplan \$2000, review \$900\.' <<<"$L" \
  && ok || bad "the rate line must name the top 3 stages of the SAME window: $L"

# 1b. the same dollars under a budget that allows them: silence
grep -q '|costrate:cheap|' "$T/alerts.txt" \
  && bad "a project inside its budget must not page: $(aline costrate:cheap)" || ok

# 1c. NEVER divided by a tiny count — and never silently
grep -q '|costrate:thin|' "$T/alerts.txt" \
  && bad "2 merged PRs is under min_prs_for_rate and must not be divided by: $(aline costrate:thin)" || ok
L=$(aline "costratenoeval:fleet")
grep -q 'thin (2 merged/24h, 3/7d, needs 5' <<<"$L" \
  && ok || bad "a project too thin to judge must be NAMED with its counts: $L"

# 1d. a count that could not be taken is not zero
grep -q '|costrate:blind|' "$T/alerts.txt" \
  && bad "an uncountable repo must not produce a rate: $(aline costrate:blind)" || ok
grep -q 'no token on this box can count — blind' <<<"$L" \
  && ok || bad "an uncountable repo must be named with its reason: $L"

# 1e. the 7d fallback: 1 PR in 24h, 20 in 7d, $100/PR over 7d against $40
L=$(aline "costrate:weekly")
grep -q 'per merged PR over 7d' <<<"$L" && grep -q '/ 20 merged PRs' <<<"$L" \
  && ok || bad "a low-volume project must be judged on 7d, not skipped: $L"
grep -q 'Top stages: execute \$1500, review \$500\.' <<<"$L" \
  && ok || bad "the 7d rate must quote the 7d stage split: $L"

# 1f. "other" is the fold-everything-else bucket, not a project with a budget
grep -q '|costrate:other|' "$T/alerts.txt" \
  && bad "the synthetic 'other' bucket must not be budgeted: $(aline costrate:other)" || ok

# ============================================================================
# 2. the fleet daily CEILING — a separate, one-time alert
# ============================================================================
# 2a. under it: nothing
cost_csv 300 300
drive
grep -q '|costceiling:fleet|' "$T/alerts.txt" \
  && bad "600 is under the 1000 ceiling: $(aline costceiling:fleet)" || ok
# 2b. over it: one line, naming the biggest spenders, and NOT counting the
#     40-hour-old row that sits in the same file
cost_csv 900 200 50
drive
L=$(aline "costceiling:fleet")
N=$(grep -c '|costceiling:fleet|' "$T/alerts.txt")
[ "$N" = 1 ] && grep -q '^86400|' <<<"$L" \
  && ok || bad "the ceiling must page once a day, got $N: $(cat "$T/alerts.txt")"
grep -q 'spent \$1150.00 in 24h against a HARD CEILING of \$1000' <<<"$L" \
  && ok || bad "the ceiling line must quote the 24h total and the ceiling (and exclude the 40h-old row): $L"
grep -q 'Biggest: busy \$900.00, thin \$200.00, fleet \$50.00' <<<"$L" \
  && ok || bad "the ceiling line must name the biggest spenders, costliest first, the project called 'fleet' among them: $L"
# 2c. and the project called `fleet` must not be mistaken for the TOTAL: at
#     $50 it is far under the ceiling, and the total ($1150) is what tripped it.
grep -q 'spent \$50' <<<"$L" \
  && bad "the project named 'fleet' was read as the fleet total: $L" || ok

# ============================================================================
# 3. the throttle — the check does not re-page every tick
# ============================================================================
drive 10
[ ! -s "$T/alerts.txt" ] && ok \
  || bad "a tick inside the throttle window must do nothing: $(cat "$T/alerts.txt")"

# ============================================================================
# 4. the OLD grammar is refused, not reinterpreted
# ============================================================================
# "$300 a day" must never become "$300 a PR" — that would raise busy's bar from
# $40 to $300 and silence the very alert this file exists to make honest.
cat > "$CONF" <<'CONF'
busy 300
fleet 800
budget busy 40 10
ceiling 1000
CONF
cost_csv 10 10
drive
L=$(aline "costcapsbadrows:fleet")
grep -q 'IGNORING: busy fleet' <<<"$L" \
  && ok || bad "legacy rows must be named: $L"
grep -q '\$80.00 per merged PR over 24h' <<<"$(aline costrate:busy)" \
  && ok || bad "busy must still be judged on its real budget row, not the legacy one: $(aline costrate:busy)"

# ============================================================================
# 5. no summary.json at all — the rate is unknowable, the ceiling still works
# ============================================================================
mv "$T/state/cost/summary.json" "$T/state/cost/summary.json.away"
cost_csv 900 200
drive
grep -q '^costrate:' <<<"$(akeys)" \
  && bad "no summary.json must mean no rate claims: $(cat "$T/alerts.txt")" || ok
grep -q '|costceiling:fleet|' "$T/alerts.txt" \
  && ok || bad "the ceiling reads the ledger directly and must survive a missing summary.json"
mv "$T/state/cost/summary.json.away" "$T/state/cost/summary.json"

echo "cost-budget-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
