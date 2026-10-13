#!/bin/bash
# tests/main-red-detector.bh-636-test.sh — BH-636 W4: THE WATCHDOG NOBODY CALLED.
#
# bin/main-red-detector.sh has shipped, has its own 26-case suite, and is
# invoked by NOTHING: no cron line, no caller, only comments. cromford's
# own main was red on 2026-09-17 and no flag was ever raised. A detector that
# nothing runs is a detector that does not exist.
#
# And once it runs: `still red — flag already set, no second alert` was written
# for one red episode with one cause. A main that stays red across NEW shas is
# new information every time — the job that fails changes, the fix that was
# supposed to land did not — and one line per NEW SHA is what says so without
# paging every five minutes for the same sha.
#
# Two properties, driven: (A) the conductor tick invokes the detector, once,
# before any project ticks, under a dedupe that skips rather than waits;
# (B) the detector alerts once per new red sha and never twice for one sha.
# Every timestamp is a literal.
# Run from anywhere: tests/main-red-detector.bh-636-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

# ============================================================================
# A. The conductor tick runs it — before any project ticks
# ============================================================================
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
printf 'demo-os example-org/demo-os - - 2 box-demo\n' > "$T/h/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"
# The detector, replaced by a recorder: this section is about the CALL, and the
# real detector's own behaviour is section B's business.
{ printf '#!/bin/bash\n'; printf 'printf "detector %%s\\n" "$*" >> %s/detector-calls.txt\n' "$T"; printf 'exit 0\n'; } > "$T/h/bin/main-red-detector.sh"
chmod +x "$T/h/bin/main-red-detector.sh"
{ printf '#!/bin/bash\nT=%s\n' "$T"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
case "$*" in
  *"pr list"*) echo "[]" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$T/fakebin/curl"
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }

# A1 — one invocation per tick, and it precedes the first project tick, so the
#      freeze flag every project reads is at most one tick old.
: > "$T/detector-calls.txt"
run_tick
[ "$(wc -l < "$T/detector-calls.txt")" = 1 ] \
  && ok || bad "A1: the conductor tick must invoke the main-red detector exactly once (got $(wc -l < "$T/detector-calls.txt") call(s))"
CLOG="$T/h/logs/merge-conductor.log"
DLINE=$(grep -n 'main-red detector' "$CLOG" | head -1 | cut -d: -f1)
TLINE=$(grep -n 'demo-os' "$CLOG" | head -1 | cut -d: -f1)
{ [ -n "$DLINE" ] && { [ -z "$TLINE" ] || [ "$DLINE" -lt "$TLINE" ]; }; } \
  && ok || bad "A1: the detector must run BEFORE the project ticks (detector line $DLINE, first project line $TLINE)"

# A2 — the dedupe is a SKIP, never a wait: a held lock costs the tick nothing.
: > "$T/detector-calls.txt"
LK="$T/h/locks/main-red-detect-tick.lock"
touch "$LK"
exec 7>"$LK"
flock -n 7 || bad "A2: the fixture could not take the lock it is testing"
run_tick
exec 7>&-
[ ! -s "$T/detector-calls.txt" ] \
  && ok || bad "A2: with the dedupe lock held the detector must be SKIPPED (got: $(cat "$T/detector-calls.txt"))"
grep -q 'main-red detector' "$CLOG" && ok || bad "A2: and the skip must say so in the log"

# A3 — the kill knob, and the absent-detector case every other fixture runs on.
: > "$T/detector-calls.txt"
run_tick MC_MAIN_RED_DETECT=0
[ ! -s "$T/detector-calls.txt" ] && ok || bad "A3: MC_MAIN_RED_DETECT=0 must turn it off (got: $(cat "$T/detector-calls.txt"))"
mv "$T/h/bin/main-red-detector.sh" "$T/h/bin/main-red-detector.off"
run_tick
[ ! -s "$T/detector-calls.txt" ] && ok || bad "A3: a tree with no detector at all must tick normally (got: $(cat "$T/detector-calls.txt"))"
[ -z "$(cat "$T/tick.err")" ] && ok || bad "A3: and must not error (stderr: $(cat "$T/tick.err"))"

# ============================================================================
# B. One alert per NEW red sha — the real bin/main-red-detector.sh
# ============================================================================
mkdir -p "$T/d/bin/lib" "$T/d/logs" "$T/d/flags" "$T/d/locks" "$T/d/env" "$T/dbin"
cp "$DIR/bin/main-red-detector.sh" "$T/d/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$T/d/bin/lib/"
: > "$T/d/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/d/bin/beat.sh"; chmod +x "$T/d/bin/beat.sh"
cat > "$T/d/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/d/bin/lane-alert.sh"
cat > "$T/dbin/gh" <<'SHIM'
#!/bin/bash
case "$*" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/actions/runs/"*"/jobs"*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"actions/runs"*)           [ -s "$D/runs.json" ] || exit 1
                              jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]' "$D/runs.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/dbin/gh"
runs() { # runs <spec>... — spec: name|path|conclusion|created_at|sha
  local out='{"workflow_runs":[' first=1 spec n p c t sha
  for spec in "$@"; do
    IFS='|' read -r n p c t sha <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg t "$t" --arg sha "$sha" --arg c "$c" \
      --arg u "https://github.com/o/r/actions/runs/${t//[^0-9]/}" \
      '{name:$n, path:$p, status:"completed", conclusion:$c, created_at:$t,
        head_sha:$sha, html_url:$u, id:($t|gsub("[^0-9]";"")|tonumber)}')
  done
  printf '%s]}' "$out" > "$T/d/runs.json"
}
drive() { ( export PATH="$T/dbin:$PATH" HARNESS="$T/d" D="$T/d" \
              ALERT_SINK="$T/d/alerts.txt" JOBS_ANSWER="${JOBS_ANSWER:-}"; unset GH_TOKEN
            bash "$T/d/bin/main-red-detector.sh" o/r >/dev/null 2>"$T/d/err.txt" ); }
alerts() { awk 'END{print NR+0}' "$T/d/alerts.txt" 2>/dev/null; }
FLAG="$T/d/flags/main-red-o-r"
CI=".github/workflows/harness-ci.yml"
: > "$T/d/alerts.txt"; rm -f "$FLAG"

# B1 — the first red episode is unchanged: one CRITICAL alert, one flag.
JOBS_ANSWER="Pure-logic gate fixtures"
runs "Harness CI|$CI|failure|2026-09-17T14:10:00Z|aaaa1111" \
     "Harness CI|$CI|failure|2026-09-17T13:02:00Z|aaaa1111" \
     "Harness CI|$CI|success|2026-09-17T11:00:00Z|dddd4444"
drive
[ -f "$FLAG" ] && ok || bad "B1: red twice must raise the flag (err: $(cat "$T/d/err.txt"))"
[ "$(alerts)" = 1 ] && ok || bad "B1: exactly one alert for the first red (got: $(cat "$T/d/alerts.txt"))"
grep -q '^--critical main-red o/r main is RED' "$T/d/alerts.txt" \
  && ok || bad "B1: and it is the critical one (got: $(cat "$T/d/alerts.txt"))"
grep -q '^sha=aaaa1111$' "$FLAG" && ok || bad "B1: the flag records the sha it is red on (got: $(cat "$FLAG"))"

# B2 — same sha on the next tick: nothing. This is the noise the flag exists for.
: > "$T/d/alerts.txt"; BEFORE=$(cat "$FLAG")
drive
[ "$(alerts)" = 0 ] && ok || bad "B2: a still-red repo on the SAME sha must not re-alert (got: $(cat "$T/d/alerts.txt"))"
[ "$(cat "$FLAG")" = "$BEFORE" ] && ok || bad "B2: and must not rewrite its flag"

# B3 — a NEW red sha is new information: exactly one more line, naming it.
: > "$T/d/alerts.txt"
JOBS_ANSWER="Syntax + shellcheck + config integrity"
runs "Harness CI|$CI|failure|2026-09-17T16:40:00Z|bbbb2222" \
     "Harness CI|$CI|failure|2026-09-17T14:10:00Z|aaaa1111" \
     "Harness CI|$CI|success|2026-09-17T11:00:00Z|dddd4444"
drive
[ "$(alerts)" = 1 ] && ok || bad "B3: a new red sha must raise exactly one line (got: $(cat "$T/d/alerts.txt"))"
grep -q 'bbbb2222' "$T/d/alerts.txt" && ok || bad "B3: naming the new sha (got: $(cat "$T/d/alerts.txt"))"
grep -q 'Syntax + shellcheck' "$T/d/alerts.txt" && ok || bad "B3: and the job that failed on it (got: $(cat "$T/d/alerts.txt"))"
grep -q '^--critical' "$T/d/alerts.txt" \
  && bad "B3: a repo already known to be red does not page critical again — the first alert did that" || ok
grep -q '^sha=bbbb2222$' "$FLAG" && ok || bad "B3: the flag's watermark must move to the new sha (got: $(cat "$FLAG"))"
grep -q '^since=2026-09-17T13:02:00Z$' "$FLAG" \
  && ok || bad "B3: but 'since' still says when main first broke (got: $(cat "$FLAG"))"
: > "$T/d/alerts.txt"; drive
[ "$(alerts)" = 0 ] && ok || bad "B3: and the new sha alerts once, not once per tick (got: $(cat "$T/d/alerts.txt"))"

# B4 — a main-only workflow counts. PR-green never proves main-green.
: > "$T/d/alerts.txt"; rm -f "$T/d"/flags/main-red-*
JOBS_ANSWER="drift"
runs "Registry drift (main only)|.github/workflows/drift.yml|failure|2026-09-17T16:00:00Z|cccc3333" \
     "Registry drift (main only)|.github/workflows/drift.yml|failure|2026-09-17T15:00:00Z|cccc3333"
drive
[ -f "$FLAG" ] && ok || bad "B4: a workflow that only ever runs on main must be able to freeze main (err: $(cat "$T/d/err.txt"))"
[ "$(alerts)" = 1 ] && ok || bad "B4: with one alert (got: $(cat "$T/d/alerts.txt"))"

# B5 — the newest run on a new sha is CANCELLED: not evidence, not an alert.
#      (the streak below it is still red, so the flag stays)
: > "$T/d/alerts.txt"
runs "Registry drift (main only)|.github/workflows/drift.yml|cancelled|2026-09-17T17:00:00Z|eeee5555" \
     "Registry drift (main only)|.github/workflows/drift.yml|failure|2026-09-17T16:00:00Z|cccc3333" \
     "Registry drift (main only)|.github/workflows/drift.yml|failure|2026-09-17T15:00:00Z|cccc3333"
drive
[ "$(alerts)" = 0 ] && ok || bad "B5: a cancelled run is not a red sha — it must not alert (got: $(cat "$T/d/alerts.txt"))"
grep -q '^sha=cccc3333$' "$FLAG" && ok || bad "B5: and the watermark must not move to it (got: $(cat "$FLAG"))"

echo "main-red-detector.bh-636: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
