#!/bin/bash
# tests/main-red-detector.bh-997-test.sh — BH-997: `--explain` is READ-ONLY.
#
#   THE PROPERTY UNDER TEST: an operator's dry run must cost the lane nothing.
#   The sibling half of this ticket (tests/main-red-pr-pair.bh-997-test.sh) is
#   about a ledger row; this half is worse. Before this, `--explain` on the
#   detector shared the ONE code path with the live `*/5` tick and differed
#   only in that log() also echoed: it took the lane lock, WROTE
#   flags/main-red-<slug> (which is the merge freeze every box reads), PUT the
#   pause row that carries that freeze off this hub, paged --critical, and on a
#   green repo CLEARED the flag and sent the resolve. An operator asking "what
#   would this say?" froze or unfroze the fleet.
#
#   So: --explain takes no lock, creates no flags/ or locks/ dir, writes and
#   clears no flag file, publishes no row, sends no alert — it prints WOULD
#   lines instead. The last case is the control: a plain tick still does all of
#   it, so "explain writes nothing" cannot pass because nothing works.
#
# Every timestamp here is a literal. Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-detector.bh-997-test: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
cp "$DIR/bin/main-red-detector.sh" "$T/bin/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$T/bin/lib/"
: > "$T/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# The coordination-DB client the detector sources. Real one on a box; here a
# recorder, so "published no row" is an assertion and not an assumption.
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
SHIM

# gh shim, same contract as tests/main-red-detector-test.sh: visibility from
# $T/blind, runs from $T/runs.json, the failing job from $JOBS_ANSWER.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id")     [ -f "$T/blind" ] && exit 1; exit 0 ;;
  *"/actions/runs/"*"/jobs"*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"actions/runs"*)           [ -s "$T/runs.json" ] || exit 1
                              jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]' "$T/runs.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"
FLAG="$T/flags/main-red-o-r"
LOCK="$T/locks/main-red-detector.lock"

runs() { # runs <name|path|conclusion|created_at|sha[|status]>...
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
drive() { # drive [args...] — one tick; stdout in $T/out.txt
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt" PUBLISH_SINK="$T/publish.txt" \
           JOBS_ANSWER="${JOBS_ANSWER:-}"; unset GH_TOKEN
    bash "$T/bin/main-red-detector.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
out()      { cat "$T/out.txt" 2>/dev/null; }
alerts()   { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
publishes(){ awk 'END{print NR+0}' "$T/publish.txt" 2>/dev/null; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/publish.txt"; : > "$T/logs/main-red.log"
  : > "$T/logs/ALERTS.log"; rm -f "$T"/flags/* "$LOCK" "$T/runs.json" "$T/blind"
  scratch_rm "$T/state/main-red"
}
# main is red twice in a row on the same required workflow: the shape that
# freezes the fleet.
red_twice() {
  runs "Harness CI|$CI|failure|2026-09-18T14:10:00Z|aaaa111" \
       "Harness CI|$CI|failure|2026-09-18T13:02:00Z|cccc333" \
       "Harness CI|$CI|success|2026-09-18T11:00:00Z|dddd444"
}

# 1. A RED REPO, DRY RUN: it says what it would do and does none of it.
reset_case; red_twice; JOBS_ANSWER="Pure-logic gate fixtures"
drive --explain o/r
case "$(out)" in *"WOULD "*) ok ;; *) bad "1: --explain printed no WOULD line: $(out)" ;; esac
[ -e "$FLAG" ] && bad "1: --explain wrote the merge-freeze flag $(basename "$FLAG")" || ok
[ "$(alerts)" = 0 ]    && ok || bad "1: --explain paged: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ] && ok || bad "1: --explain published a pause row: $(cat "$T/publish.txt")"
case "$(out)" in
  *"WOULD ALERT(critical)"*"main is RED"*) ok ;;
  *) bad "1: --explain did not say it would page: $(out)" ;;
esac

# 2. THE LOCK IS NOT THE DRY RUN'S TO TAKE. A live tick holding it must not
#    silence --explain (the detector's held-lock path is a bare `exit 0`, so a
#    dry run next to the */5 tick printed NOTHING AT ALL), and --explain must
#    not truncate the file that tick is holding.
reset_case; red_twice
printf 'held by the tick\n' > "$LOCK"
lock_before=$(stat -c '%s' "$LOCK")
exec 9>>"$LOCK"
if command -v flock >/dev/null 2>&1 && flock -n 9; then
  drive --explain o/r
  case "$(out)" in *"WOULD "*) ok ;; *) bad "2: --explain printed nothing while the lane lock was held: $(out)" ;; esac
  [ "$(stat -c '%s' "$LOCK")" = "$lock_before" ] && ok \
    || bad "2: --explain truncated the lock file ($lock_before bytes -> $(stat -c '%s' "$LOCK"))"
  flock -u 9
else
  echo "2: flock unavailable — lock cases not run"; ok; ok
fi
exec 9>&-

# 3. --explain creates neither the lock file, the locks/ dir, nor flags/.
reset_case; red_twice
scratch_rm "$T/locks"; scratch_rm "$T/flags"
drive --explain o/r
[ -e "$LOCK" ]     && bad "3: --explain created $LOCK" || ok
[ -d "$T/locks" ]  && bad "3: --explain created the locks/ directory" || ok
[ -d "$T/flags" ]  && bad "3: --explain created the flags/ directory" || ok
mkdir -p "$T/locks" "$T/flags"

# 4. AN OPEN EPISODE IS NOT THE DRY RUN'S TO CLOSE. main is green again with the
#    freeze flag up: --explain must leave the flag exactly where it is, publish
#    no `off` row, and send no resolve.
reset_case
printf 'sha=aaaa111\nworkflow=Harness CI\npath=%s\njob=x\nsince=2026-09-18T13:02:00Z\nstreak=2\nrun=u\ndetected=2026-09-18T14:11:00Z\nreason=streak\n' "$CI" > "$FLAG"
flag_before=$(sha256sum "$FLAG" | awk '{print $1}')
runs "Harness CI|$CI|success|2026-09-18T15:00:00Z|eeee555" \
     "Harness CI|$CI|failure|2026-09-18T14:10:00Z|aaaa111"
drive --explain o/r
[ -e "$FLAG" ] && ok || bad "4: --explain cleared the merge-freeze flag on a green repo"
[ "$(sha256sum "$FLAG" | awk '{print $1}')" = "$flag_before" ] && ok || bad "4: --explain rewrote the flag: $(cat "$FLAG")"
[ "$(alerts)" = 0 ]    && ok || bad "4: --explain sent the resolve: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ] && ok || bad "4: --explain published an off row: $(cat "$T/publish.txt")"
case "$(out)" in *"WOULD "*) ok ;; *) bad "4: --explain did not say what it would do: $(out)" ;; esac

# 5. STILL RED ON A NEW SHA: the flag is rewritten by a real tick. A dry run
#    must not touch its bytes and must not send the notice.
reset_case
printf 'sha=cccc333\nworkflow=Harness CI\npath=%s\njob=x\nsince=2026-09-18T13:02:00Z\nstreak=2\nrun=u\ndetected=2026-09-18T13:11:00Z\nreason=streak\n' "$CI" > "$FLAG"
flag_before=$(sha256sum "$FLAG" | awk '{print $1}')
red_twice; JOBS_ANSWER="decisions"
drive --explain o/r
[ "$(sha256sum "$FLAG" | awk '{print $1}')" = "$flag_before" ] && ok || bad "5: --explain rewrote the flag on a new red sha: $(cat "$FLAG")"
[ "$(alerts)" = 0 ]    && ok || bad "5: --explain sent the still-red notice: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ] && ok || bad "5: --explain republished the row: $(cat "$T/publish.txt")"

# 6. A REPO NO TOKEN CAN SEE pages once a day and touches a flag to remember it.
#    A dry run does neither.
reset_case; red_twice; : > "$T/blind"
drive --explain o/r
[ -z "$(ls -A "$T/flags" 2>/dev/null)" ] && ok \
  || bad "6: --explain wrote an invisible-repo flag: $(ls -A "$T/flags")"
[ -s "$T/logs/ALERTS.log" ] && bad "6: --explain wrote an ALERTS.log line: $(cat "$T/logs/ALERTS.log")" || ok
rm -f "$T/blind"

# 7. CONTROL: the real tick still writes the flag, publishes the row and pages.
reset_case; red_twice; JOBS_ANSWER="Pure-logic gate fixtures"
drive o/r
[ -s "$FLAG" ] && ok || bad "7: a real tick did not write the flag (err=$(cat "$T/err.txt"))"
grep -q '^sha=aaaa111$' "$FLAG" && ok || bad "7: the flag lost its head sha: $(cat "$FLAG" 2>/dev/null)"
[ "$(alerts)" = 1 ]    && ok || bad "7: a real tick sent $(alerts) alerts, want 1: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 1 ] && ok || bad "7: a real tick published $(publishes) rows, want 1: $(cat "$T/publish.txt")"
[ -e "$LOCK" ]         && ok || bad "7: a real tick did not take the lane lock"
case "$(out)" in *"WOULD "*) bad "7: a real tick printed WOULD: $(out)" ;; *) ok ;; esac

# 8. CONTROL: the real tick on a green repo still clears the flag and resolves.
reset_case
printf 'sha=aaaa111\nworkflow=Harness CI\npath=%s\njob=x\nsince=2026-09-18T13:02:00Z\nstreak=2\nrun=u\ndetected=2026-09-18T14:11:00Z\nreason=streak\n' "$CI" > "$FLAG"
runs "Harness CI|$CI|success|2026-09-18T15:00:00Z|eeee555" \
     "Harness CI|$CI|failure|2026-09-18T14:10:00Z|aaaa111"
drive o/r
[ -e "$FLAG" ] && bad "8: a real tick did not clear the flag on a green repo" || ok
[ "$(alerts)" = 1 ] && ok || bad "8: a real tick sent $(alerts) resolve alerts, want 1: $(cat "$T/alerts.txt")"
grep -q ' off ' "$T/publish.txt" && ok || bad "8: a real tick did not publish the off row: $(cat "$T/publish.txt")"

echo "main-red-detector-bh-997: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
