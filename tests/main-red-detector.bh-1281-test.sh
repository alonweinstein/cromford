#!/bin/bash
# tests/main-red-detector.bh-1281-test.sh — BH-1281: the STREAK arm holds a
# RAISE while the same workflow is being re-tested.
#
#   THE PROPERTY UNDER TEST: a freeze is never raised on top of a re-test.
#   The TIP arm already waits when a newer non-completed run of its workflow
#   exists (`newest_any` vs `newest`); the STREAK arm read completed runs only.
#   In a multi-red episode that is a fight: batch-resolve lifts
#   flags/main-red-<repo> the moment a fix-main-red PR merges green (BH-1269),
#   the fix's own run on main is still in flight, and the detector's next tick
#   sees the same two completed reds, RE-RAISES the flag and pages --critical.
#   The rewrite gives the flag a new mtime, which is the very lower bound
#   `mrt_main_red_fixed` uses for "has a fix merged since the freeze went up",
#   so the merged fix is excluded and the lift can never happen again.
#
#   So: with NO flag on disk, a streak whose workflow has a newer queued /
#   in_progress run is HELD — no flag, no page, no jobs read, and a log line
#   that says why rather than the false `main green`. Everything that starts
#   with a flag on disk is judged byte-for-byte as before, and the controls
#   below (no in-flight run; a newer run of ANOTHER workflow; a newer
#   CANCELLED run) all still raise, so "it holds" cannot pass by not working.
#
# Every timestamp here is a literal. Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-detector.bh-1281-test: SKIPPED — jq/python3 is not installed"; exit 0; }

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

# The coordination-DB client the detector sources: a recorder here, so "the
# held tick published no pause row" is an assertion and not an assumption.
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
SHIM

# gh shim, same contract as tests/main-red-detector.bh-997-test.sh.
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
E2E=".github/workflows/e2e.yml"
FLAG="$T/flags/main-red-o-r"
LOCK="$T/locks/main-red-detector.lock"

runs() { # runs <name|path|conclusion|created_at|sha[|status]>...
  local out='{"workflow_runs":[' first=1 spec n p c t s sha
  for spec in "$@"; do
    IFS='|' read -r n p c t sha s <<<"$spec"; s=${s:-completed}; [ "$s" = - ] && s=
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
mrlog()    { cat "$T/logs/main-red.log" 2>/dev/null; }
alerts()   { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
publishes(){ awk 'END{print NR+0}' "$T/publish.txt" 2>/dev/null; }
runs_reads(){ grep -c 'actions/runs -f branch=main' "$T/gh.txt" 2>/dev/null | tr -d ' '; }
jobs_reads(){ grep -c '/jobs' "$T/gh.txt" 2>/dev/null | tr -d ' '; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/publish.txt"; : > "$T/logs/main-red.log"
  : > "$T/logs/ALERTS.log"; rm -f "$T"/flags/* "$LOCK" "$T/runs.json" "$T/blind"
  scratch_rm "$T/state/main-red"
}

# The episode: two completed reds of a required workflow, one success before
# them. Without an in-flight run this is the shape that freezes the fleet.
red_twice() {
  runs "Harness CI|$CI|failure|2026-09-21T20:00:00Z|aaaa1111" \
       "Harness CI|$CI|failure|2026-09-21T19:30:00Z|cccc3333" \
       "Harness CI|$CI|success|2026-09-21T18:00:00Z|dddd4444"
}
# … plus the fix's own run on main, newer than both reds and not concluded.
red_twice_plus_inflight() { # red_twice_plus_inflight [status] [path] [conclusion]
  runs "Harness CI|$CI|failure|2026-09-21T20:00:00Z|aaaa1111" \
       "Harness CI|$CI|failure|2026-09-21T19:30:00Z|cccc3333" \
       "Harness CI|$CI|success|2026-09-21T18:00:00Z|dddd4444" \
       "${4:-Harness CI}|${2:-$CI}|${3:-null}|2026-09-21T20:20:00Z|f1x00001|${1:-in_progress}"
}

# Asserts shared by every case that must still raise exactly as today.
assert_raised() { # assert_raised <case>
  local c="$1"
  [ -s "$FLAG" ] && ok || bad "$c: no flag written (err=$(cat "$T/err.txt"))"
  grep -q '^sha=aaaa1111$'                    "$FLAG" 2>/dev/null && ok || bad "$c: flag sha: $(mrlog)"
  grep -q '^since=2026-09-21T19:30:00Z$'      "$FLAG" 2>/dev/null && ok || bad "$c: flag since: $(cat "$FLAG" 2>/dev/null)"
  grep -q '^streak=2$'                        "$FLAG" 2>/dev/null && ok || bad "$c: flag streak: $(cat "$FLAG" 2>/dev/null)"
  grep -q '^reason=streak$'                   "$FLAG" 2>/dev/null && ok || bad "$c: flag reason: $(cat "$FLAG" 2>/dev/null)"
  grep -q '^job=Pure-logic gate fixtures$'    "$FLAG" 2>/dev/null && ok || bad "$c: flag job: $(cat "$FLAG" 2>/dev/null)"
  [ "$(alerts)" = 1 ] && ok || bad "$c: sent $(alerts) alerts, want 1: $(cat "$T/alerts.txt")"
  case "$(cat "$T/alerts.txt")" in
    "--critical main-red o/r main is RED"*"failed 2 runs in a row"*) ok ;;
    *) bad "$c: wrong alert: $(cat "$T/alerts.txt")" ;;
  esac
}

JOBS_ANSWER="Pure-logic gate fixtures"

# R1. THE TICKET'S CASE. Two completed reds, a newer in_progress run of the same
#     workflow, NO flag on disk: hold. No flag, no page, no row, no jobs read.
reset_case; red_twice_plus_inflight in_progress
drive o/r
[ -e "$FLAG" ] && bad "R1: raised the freeze on top of a re-test: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ]    && ok || bad "R1: paged: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ] && ok || bad "R1: published a pause row: $(cat "$T/publish.txt")"
[ "$(runs_reads)" = 1 ] && ok || bad "R1: made $(runs_reads) runs reads, want 1: $(cat "$T/gh.txt")"
[ "$(jobs_reads)" = 0 ] && ok || bad "R1: made $(jobs_reads) jobs reads, want 0: $(cat "$T/gh.txt")"
case "$(mrlog)" in *"in flight on f1x00001"*) ok ;; *) bad "R1: the log does not say why it held: $(mrlog)" ;; esac
case "$(mrlog)" in *"main green"*) bad "R1: a held streak logged as main green: $(mrlog)" ;; *) ok ;; esac

# R1q. Same, with `queued` — the status allow-list, not "anything not completed".
reset_case; red_twice_plus_inflight queued
drive o/r
[ -e "$FLAG" ] && bad "R1q: raised on top of a queued re-test: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ] && ok || bad "R1q: paged: $(cat "$T/alerts.txt")"
case "$(mrlog)" in *"in flight on f1x00001"*) ok ;; *) bad "R1q: no held line: $(mrlog)" ;; esac

# C1. CONTROL, "exactly as today": the same fixture with no run in flight still
#     raises the freeze and pages once.
reset_case; red_twice
drive o/r
assert_raised C1
[ "$(publishes)" = 1 ] && ok || bad "C1: published $(publishes) rows, want 1: $(cat "$T/publish.txt")"

# N1. The newer in-flight run belongs to ANOTHER workflow. Column 11 is per
#     workflow path, so the streak on harness-ci.yml is not held.
reset_case; red_twice_plus_inflight in_progress "$E2E" null "E2E"
drive o/r
assert_raised N1

# N2. A newer CANCELLED (and then SKIPPED) run is COMPLETED, not in flight: not
#     evidence, but not a re-test either, so the streak still raises.
for CONC in cancelled skipped; do
  reset_case; red_twice_plus_inflight completed "$CI" "$CONC"
  drive o/r
  assert_raised "N2/$CONC"
done

# N3. A newer run whose `status` field is EMPTY decides nothing: the allow-list
#     means an unreadable status is not read as "in flight", so the streak
#     raises rather than being held for ever on a run nobody can classify.
reset_case; red_twice_plus_inflight - "$CI" null
drive o/r
assert_raised N3

# F1. A FLAG ALREADY ON DISK is judged byte-for-byte as before. Drive C1 to
#     write a real flag, then switch to the R1 fixture: same sha, re-test in
#     flight. The still-red republish runs, no alert, and the flag is untouched.
reset_case; red_twice
drive o/r
[ -s "$FLAG" ] && ok || bad "F1: setup did not write the flag"
flag_before=$(sha256sum "$FLAG" | awk '{print $1}')
: > "$T/alerts.txt"; : > "$T/publish.txt"; : > "$T/logs/main-red.log"
red_twice_plus_inflight in_progress
drive o/r
[ -e "$FLAG" ] && ok || bad "F1: a standing flag was dropped by the hold"
[ "$(sha256sum "$FLAG" | awk '{print $1}')" = "$flag_before" ] && ok \
  || bad "F1: the standing flag was rewritten: $(cat "$FLAG")"
[ "$(alerts)" = 0 ] && ok || bad "F1: sent a second alert: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 1 ] && ok || bad "F1: published $(publishes) rows, want 1 (the still-red republish): $(cat "$T/publish.txt")"
case "$(mrlog)" in *"still red"*"flag already set"*) ok ;; *) bad "F1: wrong still-red line: $(mrlog)" ;; esac
case "$(mrlog)" in *"in flight on"*) bad "F1: the hold ran on the flag path: $(mrlog)" ;; *) ok ;; esac

# E1. --explain over the held fixture stays read-only (BH-997) and prints the
#     same held line.
reset_case; red_twice_plus_inflight in_progress
scratch_rm "$T/locks"; scratch_rm "$T/flags"
drive --explain o/r
[ -e "$FLAG" ]    && bad "E1: --explain wrote the flag" || ok
[ -d "$T/locks" ] && bad "E1: --explain created the locks/ directory" || ok
[ -d "$T/flags" ] && bad "E1: --explain created the flags/ directory" || ok
[ "$(alerts)" = 0 ]    && ok || bad "E1: --explain paged: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ] && ok || bad "E1: --explain published a row: $(cat "$T/publish.txt")"
case "$(out)" in *"in flight on f1x00001"*) ok ;; *) bad "E1: --explain did not print the held line: $(out)" ;; esac
case "$(out)" in *"WOULD "*) bad "E1: --explain said it would act on a held streak: $(out)" ;; *) ok ;; esac
mkdir -p "$T/locks" "$T/flags"

# G1. CONTROL for the log line: a genuinely green main still says so. Without
#     this, "the held tick must not say main green" could pass by never saying it.
reset_case
runs "Harness CI|$CI|success|2026-09-21T20:00:00Z|eeee5555"
drive o/r
[ -e "$FLAG" ] && bad "G1: raised on a green main: $(cat "$FLAG")" || ok
case "$(mrlog)" in *"main green (1 required workflow(s))"*) ok ;; *) bad "G1: green main lost its log line: $(mrlog)" ;; esac

echo "main-red-detector-bh-1281: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
