#!/bin/bash
# tests/gh-budget-test.sh — bin/lib/gh-budget.sh: shared rate-limit budget.
#
# Run from anywhere: tests/gh-budget-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/fakebin" "$T/logs" "$T/state/gh-budget" "$T/flags" "$T/env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=1757725102
RESET=$((NOW+2700))

# gh shim: rate_limit answers from fixture; auth token echoes env.
cat > "$T/fakebin/gh" <<'SHIN'
#!/bin/bash
case "$*" in
  "auth token") [ -n "${GH_TOKEN:-}" ] && { printf '%s\n' "$GH_TOKEN"; exit 0; }; exit 1 ;;
  "api rate_limit"*) cat "$T/rate_limit.json" 2>/dev/null && exit 0; exit 1 ;;
esac
exit 1
SHIN
chmod +x "$T/fakebin/gh"

rate_limit_json() {
  local core=$1 graph=$2 lim=${3:-5000}
  jq -nc --argjson n "$NOW" --argjson r "$RESET" --argjson cr "$core" --argjson gl "$lim" --argjson gr "$graph" '{
    resources: {
      core: {limit: $gl, remaining: $cr, reset: $r, used: ($gl-$cr)},
      graphql: {limit: $gl, remaining: $gr, reset: $r, used: ($gl-$gr)},
      search: {limit:30, remaining:30, reset:$r, used:0},
      code_scanning_upload: {limit:1000, remaining:1000, reset:$r, used:0}
    }
  }'
}

drive() { # drive <bash snippet> [env...]
  local snippet="$1"; shift
  ( export T="$T" PATH="$T/fakebin:$PATH" HARNESS="$T" GH_TOKEN="${GH_TOKEN:-}" GH_BUDGET_MIN_REMAINING="${GH_BUDGET_MIN_REMAINING:-}" GH_BUDGET_TTL_S="${GH_BUDGET_TTL_S:-60}"
    env "$@" bash -c '
      set -uo pipefail
      . "$T/bin/lib/gh-budget.sh"
      eval "$0"' "$snippet" )
}

cp "$DIR/bin/lib/gh-budget.sh" "$T/bin/lib/"

# 1. healthy: remaining 5000/5000, threshold 800 -> rc 1, no log
rate_limit_json 5000 5000 > "$T/rate_limit.json"
: > "$T/logs/testlane.log"
drive 'gh_budget_low testlane; echo rc=$?' > "$T/out.txt"
grep -q 'rc=1' "$T/out.txt" && ok || bad "healthy should return 1: $(cat "$T/out.txt")"
[ ! -s "$T/logs/testlane.log" ] && ok || bad "healthy must not log: $(cat "$T/logs/testlane.log")"

# 2. core low: one log line across three TTL calls
rate_limit_json 799 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
: > "$T/logs/lowlane.log"
for _ in 1 2 3; do drive 'gh_budget_low lowlane; echo rc=$?' > "$T/out.txt"; done
grep -q 'rc=0' "$T/out.txt" && ok || bad "core 799 should be low: $(cat "$T/out.txt")"
[ "$(grep -c "budget low" "$T/logs/lowlane.log")" = 1 ] && ok || bad "expected exactly one low log line: $(cat "$T/logs/lowlane.log")"

# 3. graphql low
rate_limit_json 5000 400 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
: > "$T/logs/graphlane.log"
drive 'gh_budget_low graphlane; echo rc=$?' > "$T/out.txt"
grep -q 'rc=0' "$T/out.txt" && ok || bad "graphql 400 should be low: $(cat "$T/out.txt")"
grep -q "graphlane" "$T/logs/graphlane.log" && ok || bad "graphql low should log: $(cat "$T/logs/graphlane.log")"

# 4. read failure -> unknown (rc 2), "unknown" log line
: > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
: > "$T/logs/unknownlane.log"
drive 'gh_budget_low unknownlane; echo rc=$?' > "$T/out.txt"
grep -q 'rc=2' "$T/out.txt" && ok || bad "read failure should be unknown (2): $(cat "$T/out.txt")"
grep -q "unknown" "$T/logs/unknownlane.log" && ok || bad "unknown should log: $(cat "$T/logs/unknownlane.log")"

# 5. two token fingerprints -> two caches
rate_limit_json 5000 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
GH_TOKEN=tok_a drive 'gh_budget_low a; echo ok' >/dev/null
GH_TOKEN=tok_b drive 'gh_budget_low b; echo ok' >/dev/null
[ "$(find "$T/state/gh-budget" -maxdepth 1 -name '*.json' | wc -l)" = 2 ] && ok || bad "two tokens should create two caches: $(ls "$T/state/gh-budget")"

# 6. threshold resolution: setting_get 750 -> env ignored -> default ignored
rate_limit_json 749 5000 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
: > "$T/logs/setlane.log"
GH_BUDGET_MIN_REMAINING=900 drive 'setting_get() { case "$1" in gh_budget_min_remaining) printf "%s\n" "750"; return 0 ;; esac; return 2; }; gh_budget_low setlane; echo rc=$?' > "$T/out.txt"
grep -q 'rc=0' "$T/out.txt" && ok || bad "setting 750 should make 749 low: $(cat "$T/out.txt")"

# 7. env threshold when no setting
rate_limit_json 850 5000 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
: > "$T/logs/envlane.log"
drive 'setting_get() { return 2; }; GH_BUDGET_MIN_REMAINING=900 gh_budget_low envlane; echo rc=$?' > "$T/out.txt"
grep -q 'rc=0' "$T/out.txt" && ok || bad "env threshold 900 should make 850 low: $(cat "$T/out.txt")"

# 8. default 800 when nothing set
rate_limit_json 800 5000 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
drive 'setting_get() { return 2; }; gh_budget_low deflane; echo rc=$?' > "$T/out.txt"
grep -q 'rc=1' "$T/out.txt" && ok || bad "default threshold 800: 800 remaining should be healthy: $(cat "$T/out.txt")"
rate_limit_json 799 5000 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
drive 'setting_get() { return 2; }; gh_budget_low deflane; echo rc=$?' > "$T/out.txt"
grep -q 'rc=0' "$T/out.txt" && ok || bad "default threshold 800: 799 should be low: $(cat "$T/out.txt")"

# 9. non-numeric setting -> fallback with "unusable setting" log
rate_limit_json 850 5000 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
: > "$T/logs/gh-budget.log"
drive 'setting_get() { case "$1" in gh_budget_min_remaining) printf "%s\n" "abc"; return 0 ;; esac; return 2; }; GH_BUDGET_MIN_REMAINING=900 gh_budget_low badsetlane; echo rc=$?' > "$T/out.txt"
grep -q 'rc=0' "$T/out.txt" && ok || bad "non-numeric setting should fall back to env: $(cat "$T/out.txt")"
grep -q "unusable setting" "$T/logs/gh-budget.log" && ok || bad "unusable setting should be logged: $(cat "$T/logs/gh-budget.log")"

# 10. exhausted core alert: wording, reset ISO, dedup
rate_limit_json 0 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/* "$T/flags/alerted-gh-ratelimit"-*
: > "$T/logs/ALERTS.log"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
drive 'gh_budget_ratelimit_alert exhaustlane "stalepr skipped"; gh_budget_ratelimit_alert exhaustlane "stalepr skipped"; echo done' > "$T/out.txt"
grep -q "GitHub API rate-limited: core 0/5000 resets at" "$T/logs/ALERTS.log" && ok || bad "exhausted core alert wording: $(cat "$T/logs/ALERTS.log")"
[ "$(grep -c "GitHub API rate-limited" "$T/logs/ALERTS.log")" = 1 ] && ok || bad "dedup should allow only one alert: $(cat "$T/logs/ALERTS.log")"
ISO=$(date -u -d "@$RESET" '+%Y-%m-%dT%H:%M:%SZ')
grep -q "$ISO" "$T/logs/ALERTS.log" && ok || bad "reset ISO missing: $(cat "$T/logs/ALERTS.log")"
grep -qE "HTTP 429|rate_limit_error" "$T/logs/ALERTS.log" && bad "alert must avoid ACCOUNT_EXHAUST_REGEX wording" || ok

# 11. both buckets exhausted -> two alert lines with distinct akeys
rate_limit_json 0 0 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/* "$T/flags/alerted-gh-ratelimit"-*
: > "$T/logs/ALERTS.log"
cat > "$T/bin/beat.sh" <<'SHIN'
#!/bin/bash
printf '%s\n' "$*" >> "$T/beats.jsonl"
SHIN
chmod +x "$T/bin/beat.sh"
: > "$T/beats.jsonl"
drive 'gh_budget_ratelimit_alert bothlane "starved skipped"; echo done' > "$T/out.txt"
[ "$(grep -c "GitHub API rate-limited" "$T/logs/ALERTS.log")" = 2 ] && ok || bad "two exhausted buckets should produce two lines: $(cat "$T/logs/ALERTS.log")"
[ "$(grep -c '"akey":"ghratelimit:bothlane:' "$T/beats.jsonl")" = 2 ] && ok || bad "two distinct fleet_alert akeys expected: $(cat "$T/beats.jsonl")"

# 12. stale cache 0 is not exhausted (gh_budget_exhausted bypasses TTL)
rate_limit_json 0 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
drive 'gh_budget_low stalelane; echo rc=$?' >/dev/null
rate_limit_json 5000 5000 > "$T/rate_limit.json"
# do not remove cache; exhausted does a fresh read
drive 'gh_budget_exhausted; echo rc=$?' > "$T/out.txt"
grep -q 'rc=1' "$T/out.txt" && ok || bad "stale cache 0 must not read as exhausted: $(cat "$T/out.txt")"

# 13. read failure in exhausted -> non-zero
: > "$T/rate_limit.json"
drive 'gh_budget_exhausted; echo rc=$?' > "$T/out.txt"
grep -q 'rc=1' "$T/out.txt" && ok || bad "exhausted with read failure should be non-zero: $(cat "$T/out.txt")"

# 14. no token leakage into cache filename, logs, or beats
rm -f "$T/state/gh-budget"/* "$T/flags/alerted-gh-ratelimit"-*
rate_limit_json 0 5000 > "$T/rate_limit.json"
: > "$T/logs/ALERTS.log"
GH_TOKEN=supersecrettoken drive 'gh_budget_low leaklane; gh_budget_ratelimit_alert leaklane "x"; echo done' >/dev/null
grep -qR "supersecrettoken" "$T/state/gh-budget" "$T/logs" "$T/flags" 2>/dev/null && bad "token leaked to disk" || ok
find "$T/state/gh-budget" -maxdepth 1 -name '*.json' -print0 2>/dev/null | xargs -0 -I{} sh -c 'grep -q "supersecrettoken" "$1" 2>/dev/null && exit 1 || exit 0' _ {} 2>/dev/null && ok || bad "token leaked into cache file"

# 15. one free api rate_limit per TTL window
rate_limit_json 5000 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
rm -f "$T/gh-calls.txt"
cat > "$T/fakebin/gh" <<'SHIN'
#!/bin/bash
printf '%s\n' "$*" >> "$T/gh-calls.txt"
case "$*" in
  "auth token") [ -n "${GH_TOKEN:-}" ] && { printf '%s\n' "$GH_TOKEN"; exit 0; }; exit 1 ;;
  "api rate_limit"*) cat "$T/rate_limit.json" 2>/dev/null && exit 0; exit 1 ;;
esac
exit 1
SHIN
chmod +x "$T/fakebin/gh"
(
  export GH_BUDGET_TTL_S=60
  for _ in 1 2 3; do drive 'gh_budget_low onelane; echo ok' >/dev/null; done
)
[ "$(grep -c "api rate_limit" "$T/gh-calls.txt")" = 1 ] && ok || bad "three calls in TTL should issue one api rate_limit: $(cat "$T/gh-calls.txt")"

# 16. high-limit remaining 900 healthy with default
rate_limit_json 900 900 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
drive 'setting_get() { return 2; }; gh_budget_low highlane; echo rc=$?' > "$T/out.txt"
grep -q 'rc=1' "$T/out.txt" && ok || bad "900/900 with default 800 should be healthy: $(cat "$T/out.txt")"

# 17. strict < edge: 799 low, 800 healthy
rate_limit_json 799 5000 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
drive 'setting_get() { return 2; }; gh_budget_low edge799; echo rc=$?' > "$T/out.txt"
grep -q 'rc=0' "$T/out.txt" && ok || bad "799 should be low (strict <): $(cat "$T/out.txt")"
rate_limit_json 800 5000 5000 > "$T/rate_limit.json"
rm -f "$T/state/gh-budget"/*
drive 'setting_get() { return 2; }; gh_budget_low edge800; echo rc=$?' > "$T/out.txt"
grep -q 'rc=1' "$T/out.txt" && ok || bad "800 should be healthy (strict <): $(cat "$T/out.txt")"

echo "gh-budget: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
