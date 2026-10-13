#!/bin/bash
# tests/main-red-detector-test.sh — bin/main-red-detector.sh driven for real
# against a fake gh, a scratch $HARNESS and a recording lane-alert.sh.
#
#   THE PROPERTY UNDER TEST: a repo whose main has been red for two consecutive
#   runs of a REQUIRED workflow gets exactly ONE critical alert and exactly one
#   flag; a repo that goes green again gets exactly ONE resolve alert and loses
#   the flag; and a read that FAILS changes nothing at all — an existing flag is
#   never cleared because we could not look (2026-09-15, the day main was red
#   and four lanes each debugged their own innocent diff).
#
# Every timestamp here is a literal: this suite refuses to do to itself what it
# was written to catch.
# Run from anywhere: tests/main-red-detector-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

cp "$DIR/bin/main-red-detector.sh" "$T/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
: > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
# lane-alert.sh, recording: the first field says whether --critical was asked for.
cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"
# fleet.conf + fleet-conf.sh, for the discovery case only.
cat > "$T/fleet.conf" <<'CONF'
# a comment row
demo-os   example-org/demo-os   https://demo.invalid  /api/board  2 box-demo
greenfld  -                   -                     -           3 box-demo
CONF
cat > "$T/bin/fleet-conf.sh" <<'SHIM'
#!/bin/bash
case "$1 $2" in
  "demo-os repo")  echo "example-org/demo-os" ;;
  "greenfld repo") echo "-" ;;
esac
SHIM
chmod +x "$T/bin/fleet-conf.sh"

# gh shim. Visibility from $T/blind; runs from $T/runs.json ("" or absent = the
# API failed); the jobs read answers $JOBS_ANSWER.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id")   [ -f "$T/blind" ] && exit 1; exit 0 ;;
  *"/actions/runs/"*"/jobs"*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"actions/runs"*)         [ -s "$T/runs.json" ] || exit 1
                            jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]' "$T/runs.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

# runs <spec>... — spec: name|path|conclusion|created_at|sha[|status]
runs() {
  local out='{"workflow_runs":[' first=1 spec n p c t s sha
  for spec in "$@"; do
    IFS='|' read -r n p c t sha s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" --arg sha "$sha" \
      --arg c "$c" --arg u "https://github.com/o/r/actions/runs/${t//[^0-9]/}" \
      '{name:$n, path:$p, status:$s, conclusion:(if $c=="null" then null else $c end),
        created_at:$t, head_sha:$sha, html_url:$u, id:($t|gsub("[^0-9]";"")|tonumber)}')
  done
  printf '%s]}' "$out" > "$T/runs.json"
}
drive() { # drive [args...] — one tick of the detector
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt" JOBS_ANSWER="${JOBS_ANSWER:-}"; unset GH_TOKEN
    bash "$T/bin/main-red-detector.sh" "$@" >/dev/null 2>"$T/err.txt" )
}
alerts() { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
FLAG="$T/flags/main-red-o-r"
CI=".github/workflows/harness-ci.yml"; E2E=".github/workflows/e2e.yml"
reset_all() { : > "$T/alerts.txt"; : > "$T/gh.txt"; rm -f "$T"/flags/main-red-* "$T"/flags/alerted-repo-invisible-*; : > "$T/logs/ALERTS.log"; }

# 1. ONE red run is not a freeze: the run before it was green.
#    MAIN_RED_TIP_RED=0: the streak arm alone (BH-629.4's tip arm owns this shape).
reset_all
runs "Harness CI|$CI|failure|2026-09-15T14:10:00Z|aaaa111" \
     "Harness CI|$CI|success|2026-09-15T13:00:00Z|bbbb222"
MAIN_RED_TIP_RED=0 drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok || bad "one red run must not freeze: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt")"

# 2. red twice in a row: the flag, and ONE critical alert naming the failing JOB.
reset_all
JOBS_ANSWER="Pure-logic gate fixtures"
runs "Harness CI|$CI|failure|2026-09-15T14:10:00Z|aaaa111" \
     "Harness CI|$CI|failure|2026-09-15T13:02:00Z|cccc333" \
     "Harness CI|$CI|success|2026-09-15T11:00:00Z|dddd444"
drive o/r
[ -f "$FLAG" ] && ok || bad "red twice must write the flag (err=$(cat "$T/err.txt"))"
grep -q '^sha=aaaa111$'                   "$FLAG" && ok || bad "flag must carry the head sha: $(cat "$FLAG" 2>/dev/null)"
grep -q '^workflow=Harness CI$'           "$FLAG" && ok || bad "flag must name the workflow: $(cat "$FLAG" 2>/dev/null)"
grep -q '^since=2026-09-15T13:02:00Z$'    "$FLAG" && ok || bad "flag's since must be the OLDEST run in the streak: $(cat "$FLAG" 2>/dev/null)"
[ "$(alerts)" = 1 ] && ok || bad "expected exactly one alert: $(cat "$T/alerts.txt")"
grep -q '^--critical main-red o/r main is RED' "$T/alerts.txt" && ok || bad "the alert must be critical and say main is RED: $(cat "$T/alerts.txt")"
grep -q 'job: Pure-logic gate fixtures'   "$T/alerts.txt" && ok || bad "the alert must name the failing job: $(cat "$T/alerts.txt")"
grep -q 'fix-main-red'                    "$T/alerts.txt" && ok || bad "the alert must say how to land a fix: $(cat "$T/alerts.txt")"

# 3. still red on the next tick: no second alert, flag untouched.
BEFORE=$(cat "$FLAG"); : > "$T/alerts.txt"
drive o/r
{ [ "$(alerts)" = 0 ] && [ "$(cat "$FLAG")" = "$BEFORE" ]; } && ok \
  || bad "a still-red repo re-alerted or rewrote its flag: alerts=$(cat "$T/alerts.txt")"

# 4. the read fails while the flag is up: NOTHING changes. "We could not look"
#    is not "it is fixed".
: > "$T/alerts.txt"; rm -f "$T/runs.json"
drive o/r
{ [ -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok || bad "an API failure cleared the flag or alerted"

# 5. green again: the flag goes, ONE resolve alert, and it is not critical.
: > "$T/alerts.txt"
runs "Harness CI|$CI|success|2026-09-15T15:40:00Z|eeee555" \
     "Harness CI|$CI|failure|2026-09-15T14:10:00Z|aaaa111"
drive o/r
[ ! -f "$FLAG" ] && ok || bad "a green main must clear the flag"
[ "$(alerts)" = 1 ] && ok || bad "expected exactly one resolve alert: $(cat "$T/alerts.txt")"
# BH-2337: GREEN resolves the RED's condition and opens no row of its own.
grep -q '^--resolve --log-only main-red o/r main is GREEN again' "$T/alerts.txt" && ok || bad "resolve alert wrong shape: $(cat "$T/alerts.txt")"
grep -q 'red since 2026-09-15T13:02:00Z'    "$T/alerts.txt" && ok || bad "the resolve must say how long it was red: $(cat "$T/alerts.txt")"
# and a green repo with no flag says nothing at all
: > "$T/alerts.txt"; drive o/r
[ "$(alerts)" = 0 ] && ok || bad "a green repo with no flag alerted: $(cat "$T/alerts.txt")"

# 5b. red ONCE after a fix, with nothing green: not a freeze, and not a resolve
#     either — the flag stays exactly as it was.
reset_all
runs "Harness CI|$CI|failure|2026-09-15T14:10:00Z|aaaa111" \
     "Harness CI|$CI|failure|2026-09-15T13:02:00Z|cccc333"
drive o/r                                    # sets the flag
: > "$T/alerts.txt"
runs "Harness CI|$CI|failure|2026-09-15T17:00:00Z|7777aaa" \
     "Harness CI|$CI|success|2026-09-15T16:30:00Z|6666bbb"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN
  # MAIN_RED_TIP_RED=0: the streak arm in isolation (BH-629.4's tip arm fires here)
  MAIN_RED_STREAK=3 MAIN_RED_TIP_RED=0 bash "$T/bin/main-red-detector.sh" o/r >/dev/null 2>&1 )
{ [ -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok \
  || bad "a fresh red below the streak resolved the flag: flag=$([ -f "$FLAG" ] && echo yes) alerts=$(cat "$T/alerts.txt")"

# 6. cancelled / in-progress runs are not evidence: they neither break a streak
#    nor make one. Two halves, because they answer different questions since
#    BH-1281 gave the streak arm the tip arm's in-flight suppression.
# 6a. A CANCELLED run between the two reds does not break the streak.
reset_all
runs "Harness CI|$CI|failure|2026-09-15T14:10:00Z|aaaa111" \
     "Harness CI|$CI|cancelled|2026-09-15T13:30:00Z|9999xxx" \
     "Harness CI|$CI|failure|2026-09-15T13:02:00Z|cccc333"
drive o/r
{ [ -f "$FLAG" ] && grep -q '^sha=aaaa111$' "$FLAG" && grep -q '^streak=2$' "$FLAG"; } && ok \
  || bad "a cancelled run must be ignored, not break the streak: $(cat "$FLAG" 2>/dev/null)"
# 6b. The same evidence with an IN-PROGRESS run newer than both reds: the streak
#     is still 2 (the in-progress run did not break it and did not make it), but
#     it is being re-tested, so BH-1281 holds the raise instead of freezing on
#     top of it. tests/main-red-detector.bh-1281-test.sh owns that behaviour;
#     what this case pins is that the STREAK COUNT is unchanged by either run.
reset_all
runs "Harness CI|$CI|null|2026-09-15T16:00:00Z|ffff666|in_progress" \
     "Harness CI|$CI|failure|2026-09-15T14:10:00Z|aaaa111" \
     "Harness CI|$CI|cancelled|2026-09-15T13:30:00Z|9999xxx" \
     "Harness CI|$CI|failure|2026-09-15T13:02:00Z|cccc333"
drive o/r
{ [ ! -f "$FLAG" ] && grep -q 'failed 2 runs in a row on main but a newer run of it is in flight on ffff666' "$T/logs/main-red.log"; } && ok \
  || bad "a re-test in flight must hold a streak of exactly 2: flag=$([ -f "$FLAG" ] && echo yes) log=$(cat "$T/logs/main-red.log" 2>/dev/null)"

# 7. a NOT-required workflow (e2e/nightly/smoke) red on main is perma-red's
#    business, never a merge freeze.
reset_all
runs "E2E Nightly|$E2E|failure|2026-09-15T14:10:00Z|aaaa111" \
     "E2E Nightly|$E2E|failure|2026-09-15T13:02:00Z|cccc333"
drive o/r
{ [ ! -f "$FLAG" ] && [ "$(alerts)" = 0 ]; } && ok || bad "a nightly/e2e red must not freeze merges"

# 8. one required workflow red among green siblings still freezes.
reset_all
runs "Harness CI|$CI|failure|2026-09-15T14:10:00Z|aaaa111" \
     "Harness CI|$CI|failure|2026-09-15T13:02:00Z|cccc333" \
     "Publish public copy (cromford)|.github/workflows/publish-cromford.yml|success|2026-09-15T14:11:00Z|aaaa111"
drive o/r
{ [ -f "$FLAG" ] && [ "$(alerts)" = 1 ]; } && ok || bad "a red required workflow beside a green sibling must still freeze"

# 9. a repo no token can see: the invisible-repo ALERT, no flag, and the runs
#    API is never asked.
reset_all; touch "$T/blind"
runs "Harness CI|$CI|failure|2026-09-15T14:10:00Z|aaaa111" \
     "Harness CI|$CI|failure|2026-09-15T13:02:00Z|cccc333"
drive o/r
{ grep -q 'repo o/r is INVISIBLE' "$T/logs/ALERTS.log" && [ ! -f "$FLAG" ] \
  && ! grep -q 'actions/runs' "$T/gh.txt"; } && ok \
  || bad "an invisible repo must page as invisible: alerts=$(cat "$T/logs/ALERTS.log") gh=$(cat "$T/gh.txt")"
rm -f "$T/blind"

# 10. repo discovery: fleet.conf's rows AND the harness repo itself, never the
#     greenfield "-" row.
reset_all
runs "Harness CI|$CI|success|2026-09-15T15:00:00Z|eeee555"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN
  HARNESS_REPO="example-org/cromford" bash "$T/bin/main-red-detector.sh" >/dev/null 2>&1 )
grep -q 'repos/example-org/demo-os/actions/runs'      "$T/gh.txt" && ok || bad "fleet.conf's repo was never asked: $(cat "$T/gh.txt")"
grep -q 'repos/example-org/cromford/actions/runs' "$T/gh.txt" && ok || bad "the harness repo itself was never asked: $(cat "$T/gh.txt")"
grep -q 'repos/-/'                                   "$T/gh.txt" && bad "a repo-less row reached gh" || ok

# 11. the kill switch.
reset_all
runs "Harness CI|$CI|failure|2026-09-15T14:10:00Z|aaaa111" \
     "Harness CI|$CI|failure|2026-09-15T13:02:00Z|cccc333"
touch "$T/flags/main-red-detector-off"
drive o/r
{ [ ! -f "$FLAG" ] && [ ! -s "$T/gh.txt" ]; } && ok || bad "flags/main-red-detector-off did not stop the run"
rm -f "$T/flags/main-red-detector-off"

# 12. the streak length is configurable, and 3 means three.
reset_all
runs "Harness CI|$CI|failure|2026-09-15T14:10:00Z|aaaa111" \
     "Harness CI|$CI|failure|2026-09-15T13:02:00Z|cccc333"
( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" ALERT_SINK="$T/alerts.txt"; unset GH_TOKEN
  # MAIN_RED_TIP_RED=0: the streak arm in isolation (BH-629.4's tip arm fires here)
  MAIN_RED_STREAK=3 MAIN_RED_TIP_RED=0 bash "$T/bin/main-red-detector.sh" o/r >/dev/null 2>&1 )
[ ! -f "$FLAG" ] && ok || bad "MAIN_RED_STREAK=3 must not fire on two reds"

echo "main-red-detector: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
