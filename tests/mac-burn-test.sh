#!/bin/bash
# tests/mac-burn-test.sh — the Mac-side burn scanner's honesty guards.
#
# Fixture doctrine: the synthetic ledger line is SEEDED FROM A REAL producer
# line (Z-suffixed ISO timestamp, the ledger's own usage key names
# cache_read_input_tokens / cache_creation_input_tokens) — never from memory
# of the schema. The properties pinned are the two this wave watched degrade
# elsewhere: an unpriced model quietly becoming $0, and a failure quietly
# pushing anyway. Assertions match via process substitution, never
# `grep | grep -q` (the SIGPIPE-under-pipefail flake, #69).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$DIR/bin/mac/mac-burn-push.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---- fixture: ledger seeded from a real line's shape ------------------------
mkdir -p "$T/ledger/proj" "$T/bin"
NOW_TS=$(date -u '+%Y-%m-%dT%H:%M:%S').000Z
OLD_TS=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=25)).strftime('%Y-%m-%dT%H:%M:%S')+'.000Z')")
row() { # row <ts> <model> <in> <out> <cr> <cw>
  printf '{"timestamp":"%s","message":{"model":"%s","usage":{"input_tokens":%d,"output_tokens":%d,"cache_read_input_tokens":%d,"cache_creation_input_tokens":%d}}}\n' "$@"
}
{ row "$NOW_TS" priced-model 100 10 1000 50
  row "$NOW_TS" mystery-model 7777 888 0 0
  row "$OLD_TS" priced-model 200 20 0 0      # 25h old: in 7d, NOT in 24h
} > "$T/ledger/proj/s1.jsonl"
cat > "$T/prices.json" <<'EOF'
{"per_token": {"priced-model": {"prompt": 0.01, "completion": 0.05, "cache_read": 0.001, "cache_write": 0.0125}}}
EOF
printf 'testsecret' > "$T/secret"
# curl stub: records invocation; the push must be observable, never assumed
cat > "$T/bin/curl" <<EOF
#!/bin/bash
echo "\$@" >> "$T/curl-invoked"
exit 0
EOF
chmod +x "$T/bin/curl"

run() { HOME="$T" PATH="$T/bin:$PATH" MACBURN_SECRET_FILE="$T/secret" \
        MACBURN_LEDGER_DIR="$T/ledger" MACBURN_PRICES="${1:-$T/prices.json}" \
        WATCHDOG_URL="http://localhost:1" bash "$SCRIPT"; }

# ---- 1. unpriced model: named, tokens survive, caveat RIDES the number ------
rm -f "$T/curl-invoked"; run; RC=$?
[ "$RC" -eq 0 ] || bad "clean run must exit 0 (got $RC)"
[ -f "$T/curl-invoked" ] || bad "clean run must actually push (curl never invoked)"
PAYLOAD=$(grep -o '{.*}' "$T/curl-invoked" | head -1)
check() { printf '%s' "$PAYLOAD" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"; }
check 'd["cost_is_lower_bound"] is True' && ok || bad "unpriced model present but cost_is_lower_bound is not True"
check '"mystery-model" in d["unpriced_models"]' && ok || bad "unpriced model not named"
check '"LOWER BOUND" in (d["note"] or "")' && ok || bad "note does not say LOWER BOUND"
check 'd["by_model_7d"]["mystery-model"]["in"] == 7777' && ok || bad "unpriced model tokens vanished from by_model_7d"
check 'd["by_model_7d"]["mystery-model"]["cost"] == 0.0' && ok || bad "unpriced model cost must be honest 0.0 (unpriced), not invented"
# ---- 2. window: 25h row in 7d, not in 24h ----------------------------------
check 'd["by_model_7d"]["priced-model"]["in"] == 300' && ok || bad "7d must include the 25h-old row (in=300)"
check 'abs(d["cost_24h"] - 3.13) < 0.01' && ok || bad "24h cost must exclude the 25h-old row (expect 3.13)"
check 'abs(d["cost_7d"] - 6.13) < 0.01' && ok || bad "7d cost must include the 25h-old row (expect 6.13)"
# ---- 3. all-priced: caveat OFF ---------------------------------------------
cat > "$T/prices2.json" <<'EOF'
{"per_token": {"priced-model": {"prompt": 0.01, "completion": 0.05, "cache_read": 0.001, "cache_write": 0.0125},
               "mystery-model": {"prompt": 0.01, "completion": 0.05, "cache_read": 0.001, "cache_write": 0.0125}}}
EOF
rm -f "$T/curl-invoked"; run "$T/prices2.json"
PAYLOAD=$(grep -o '{.*}' "$T/curl-invoked" | head -1)
check 'd["cost_is_lower_bound"] is False' && ok || bad "all models priced but lower-bound still claimed"
check 'd["note"] is None' && ok || bad "note must be null when nothing is unpriced"
# ---- 4. malformed price table: exit 1, curl NEVER called -------------------
printf 'not json' > "$T/prices3.json"
rm -f "$T/curl-invoked"
run "$T/prices3.json" 2>"$T/stderr3"; RC=$?
[ "$RC" -eq 1 ] && ok || bad "malformed price table must exit 1 (got $RC)"
[ ! -f "$T/curl-invoked" ] && ok || bad "malformed price table PUSHED anyway — a failure must push nothing"
# ...and it says WHY, in the log, without spraying a python traceback at cron.
# The traceback was real output on every CI run of this suite until 2026-09-16:
# correct behaviour (exit 1, no push) whose reason went to a stderr nobody reads.
grep -q Traceback "$T/stderr3" && bad "the scan leaked a python traceback to stderr: $(head -1 "$T/stderr3")" || ok
grep -q 'unreadable price table' "$T/.mk-macburn.log" && ok || bad "the log must name the unreadable price table (log: $(tail -1 "$T/.mk-macburn.log" 2>/dev/null))"

echo "mac-burn-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
