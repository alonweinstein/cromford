#!/bin/bash
# tests/pipeline-health-permared-test.sh — the perma-red check detector in
# bin/pipeline-health.sh (E2E policy point 5, 2026-09-12), extracted VERBATIM
# by its markers and driven with a gh shim and a recording alert().
#
#   A workflow whose newest concluded runs on main are an unbroken red streak
#   of >=3 runs spanning >=3 days pages ONCE per day per (repo, workflow):
#   "check <workflow> red <N> days on <repo> — fix or delete". A success ends
#   the streak; cancelled/skipped runs are not evidence either way; a green
#   sibling workflow in the same payload is never named; an invisible repo
#   pages as invisible, not as red; the hourly stamp throttles the API call.
#
# Run from anywhere: tests/pipeline-health-permared-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

awk '/^# >>> perma-red check/{f=1;next} /^# <<< perma-red check/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/blk.sh"
[ -s "$T/blk.sh" ] && ok || bad "could not extract the perma-red block — markers missing?"
cp "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "ts repo") echo "o/r" ;;
  "gf repo") echo "-" ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"
# gh shim: repo visibility from $T/blind; the runs payload from $T/runs.json
# (the block asks with -X GET -f fields, so the query never appears in "$*").
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/o/r -q .id") [ -f "$T/blind" ] && exit 1; exit 0 ;;
  "api repos/"*" -q .id") exit 1 ;;
  *"actions/runs"*)       [ -f "$T/runs.json" ] || exit 1
                          jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, t:.created_at, u:.html_url}]' "$T/runs.json" ;;
  *) echo "" ;;
esac
SH
chmod +x "$T/fakebin/gh"

drive() { # drive [env...]
  : > "$T/alerts.txt"; : > "$T/gh.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt"; unset GH_TOKEN
    env PERMARED_EVERY=0 "$@" bash -c '
      set -uo pipefail
      H="$T"; NOW=$(date +%s); PROJECTS="ts gf"
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      . "$T/bin/lib/gh-repo-token.sh"
      . "$0"' "$T/blk.sh" 2>"$T/err.txt" )
}
# runs <spec>...: each spec is name|path|conclusion|days-ago[|status]; newest first is not required.
runs() {
  local out='{"workflow_runs":[' first=1 spec n p c d s
  for spec in "$@"; do
    IFS='|' read -r n p c d s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg c "$c" --arg s "$s" \
      --arg t "$(date -u -d "$d days ago" +%Y-%m-%dT%H:%M:%SZ)" --arg u "https://x/$p/$d" \
      '{name:$n, path:$p, status:$s, conclusion:(if $c=="null" then null else $c end), created_at:$t, html_url:$u}')
  done
  printf '%s]}' "$out" > "$T/runs.json"
}
E=".github/workflows/e2e.yml"; TC=".github/workflows/ci.yml"

# 1. the page: 5 red runs over 4 days, plus a green Typecheck alongside
runs "E2E Tests|$E|failure|0" "E2E Tests|$E|failure|1" "E2E Tests|$E|timed_out|2" "E2E Tests|$E|failure|3" "E2E Tests|$E|failure|4" \
     "Typecheck|$TC|success|0" "Typecheck|$TC|success|2"
drive
grep -q "^86400|permared:o/r:$E|check E2E Tests red 4 days on o/r — fix or delete (5 consecutive red runs" "$T/alerts.txt" \
  && ok || bad "perma-red E2E did not page as expected: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
grep -q "ci.yml" "$T/alerts.txt" && bad "the green Typecheck workflow was named" || ok
[ "$(grep -c . "$T/alerts.txt")" -eq 1 ] && ok || bad "expected exactly one alert line: $(cat "$T/alerts.txt")"
grep -q "actions/runs" "$T/gh.txt" && ok || bad "the runs API was never asked"
# 2. a success 1 day ago ends the streak: no page even with old failures behind it
runs "E2E Tests|$E|failure|0" "E2E Tests|$E|success|1" "E2E Tests|$E|failure|2" "E2E Tests|$E|failure|3" "E2E Tests|$E|failure|5"
drive; [ ! -s "$T/alerts.txt" ] && ok || bad "a recent success must end the streak: $(cat "$T/alerts.txt")"
# 3. two red runs only: not enough runs
runs "E2E Tests|$E|failure|0" "E2E Tests|$E|failure|4"
drive; [ ! -s "$T/alerts.txt" ] && ok || bad "2 runs must not page: $(cat "$T/alerts.txt")"
# 4. three red runs all today: not enough days
runs "E2E Tests|$E|failure|0" "E2E Tests|$E|failure|0" "E2E Tests|$E|failure|0"
drive; [ ! -s "$T/alerts.txt" ] && ok || bad "a same-day streak must not page: $(cat "$T/alerts.txt")"
# 5. cancelled / skipped / in-progress runs are not evidence and do not break the streak
runs "E2E Tests|$E|failure|0" "E2E Tests|$E|cancelled|1" "E2E Tests|$E|skipped|1" "E2E Tests|$E|null|0|in_progress" \
     "E2E Tests|$E|failure|2" "E2E Tests|$E|failure|3"
drive
grep -q "red 3 days on o/r — fix or delete (3 consecutive red runs" "$T/alerts.txt" \
  && ok || bad "cancelled/skipped/in-progress must be ignored, not break the streak: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
# 6. an all-green history: silence
runs "E2E Tests|$E|success|0" "E2E Tests|$E|success|1" "E2E Tests|$E|success|4"
drive; [ ! -s "$T/alerts.txt" ] && ok || bad "green history paged: $(cat "$T/alerts.txt")"
# 7. the runs API fails: no page, no guess
rm -f "$T/runs.json"
drive; [ ! -s "$T/alerts.txt" ] && ok || bad "an API failure must not page: $(cat "$T/alerts.txt")"
# 8. invisible repo: the invisible-repo ALERT, and the runs API is never asked
runs "E2E Tests|$E|failure|0" "E2E Tests|$E|failure|2" "E2E Tests|$E|failure|4"
touch "$T/blind"; : > "$T/logs/ALERTS.log"; rm -f "$T"/flags/alerted-repo-invisible-*
drive
grep -q "\[pipeline-health\] repo o/r is INVISIBLE to the default gh token" "$T/logs/ALERTS.log" \
  && ! grep -q "actions/runs" "$T/gh.txt" && [ ! -s "$T/alerts.txt" ] \
  && ok || bad "invisible repo must page as such: ALERTS=$(cat "$T/logs/ALERTS.log") gh=$(cat "$T/gh.txt") alerts=$(cat "$T/alerts.txt")"
rm -f "$T/blind"
# 9. a project without a repo (greenfield "-") is never asked about
grep -q "repos/-/" "$T/gh.txt" && bad "a repo-less project reached gh" || ok
# 10. the hourly stamp: a fresh stamp means no API call this tick
date +%s > "$T/state/permared.stamp"
: > "$T/alerts.txt"; : > "$T/gh.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt"; unset GH_TOKEN
  bash -c 'set -uo pipefail; H="$T"; NOW=$(date +%s); PROJECTS="ts"; STAMP() { echo TS; }
    alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
    . "$T/bin/lib/gh-repo-token.sh"; . "$0"' "$T/blk.sh" 2>/dev/null )
! grep -q "actions/runs" "$T/gh.txt" && [ ! -s "$T/alerts.txt" ] && ok || bad "a fresh stamp must throttle the API call: $(cat "$T/gh.txt")"

echo "pipeline-health-permared: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
