#!/bin/bash
# tests/main-red-hold-overrun.bh-1475-test.sh — BH-1475: a held streak is
# BOUNDED. The hold ends the moment main runs away from the sha it is holding.
#
#   THE SILENCE THIS KILLS. BH-1281 taught the streak arm to HOLD rather than
#   raise while the same workflow is being re-tested: two completed reds plus a
#   newer in-flight run of that workflow means a fix is probably on its way, and
#   re-raising would page again and reset the flag mtime that
#   `mrt_main_red_fixed` reads. That hold has no upper bound. While it is held
#   no flag exists, so every merge lane reads "not frozen" and keeps merging —
#   onto a main whose last COMPLETED evidence is two reds. The re-test that
#   bought the hold can sit in flight for an hour while five more PRs land.
#
#   THE PROPERTY UNDER TEST: while a streak is held AND main has advanced by at
#   least MAIN_RED_HOLD_OVERRUN (2) distinct shas past the held sha, the hold
#   ends early — the freeze is written on the HELD sha's failure with
#   reason=held-overrun, the flag names the head main has moved on to, and the
#   log names the merges that landed during the hold. And every shape that is
#   NOT an overrun still holds: depth below the bound (which is BH-1281's own
#   fixture, depth 1), no merges at all, the knob at 0, a skip-listed workflow,
#   a flag already on disk. The arm gates a fleet-wide merge freeze and a
#   --critical page, so its negatives carry as much weight as its positive.
#
# Every timestamp here is a literal — this suite reads no clock at all.
# Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A suite whose subject is absent must fail LOUD, never skip into green.
[ -f "$DIR/bin/main-red-detector.sh" ] || {
  echo "FAIL: bin/main-red-detector.sh does not exist — there is nothing to test"
  echo "main-red-hold-overrun-bh-1475: PASS=0 FAIL=1"; exit 1; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-hold-overrun-bh-1475: SKIPPED — jq/python3 is not installed"; exit 0; }

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

# The coordination-DB client the detector sources: a recorder, so "the held
# tick published no pause row" is an assertion and not an assumption.
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
SHIM

# gh shim, same contract as tests/main-red-detector.bh-1281-test.sh.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id")     exit 0 ;;
  # The -q read gets the joined names; a raw read (the BH-2165 infra check,
  # whose body names the job) gets the jobs JSON GitHub would send.
  *"/actions/runs/"*"/jobs"*" -q "*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"/actions/runs/"*"/jobs"*) jq -nc --arg n "${JOBS_ANSWER:-}" \
      '{total_count:(if $n=="" then 0 else 1 end), jobs:(if $n=="" then [] else [{name:$n, conclusion:"failure", run_attempt:1, steps:[{name:"tests/ suite", conclusion:"failure"}]}] end)}' ;;
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
           JOBS_ANSWER="${JOBS_ANSWER:-}" \
           MAIN_RED_HOLD_OVERRUN="${MAIN_RED_HOLD_OVERRUN:-}"; unset GH_TOKEN
    [ -n "$MAIN_RED_HOLD_OVERRUN" ] || unset MAIN_RED_HOLD_OVERRUN
    bash "$T/bin/main-red-detector.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
out()      { cat "$T/out.txt" 2>/dev/null; }
mrlog()    { cat "$T/logs/main-red.log" 2>/dev/null; }
verdict()  { cat "$T/state/main-red/o-r.verdict" 2>/dev/null; }
alerts()   { awk 'END{print NR+0}' "$T/alerts.txt" 2>/dev/null; }
publishes(){ awk 'END{print NR+0}' "$T/publish.txt" 2>/dev/null; }
runs_reads(){ grep -c 'actions/runs -f branch=main' "$T/gh.txt" 2>/dev/null | tr -d ' '; }
jobs_reads(){ grep -c '/jobs' "$T/gh.txt" 2>/dev/null | tr -d ' '; }
reset_case() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/publish.txt"; : > "$T/logs/main-red.log"
  : > "$T/logs/ALERTS.log"; rm -f "$T"/flags/* "$LOCK" "$T/runs.json"
  scratch_rm "$T/state/main-red"
  mkdir -p "$T/flags" "$T/locks"
}

# THE OVERRUN FIXTURE. Two completed reds on aaaa1111/cccc3333, the re-test in
# flight on f1x00001, and then a SECOND merge (b2b20002) landing on top of it
# while the re-test is still running. Depth of the held sha = 2.
overrun() { # overrun [path] [name]
  runs "${2:-Harness CI}|${1:-$CI}|failure|2026-09-21T20:00:00Z|aaaa1111" \
       "${2:-Harness CI}|${1:-$CI}|failure|2026-09-21T19:30:00Z|cccc3333" \
       "${2:-Harness CI}|${1:-$CI}|success|2026-09-21T18:00:00Z|dddd4444" \
       "${2:-Harness CI}|${1:-$CI}|null|2026-09-21T20:20:00Z|f1x00001|in_progress" \
       "${2:-Harness CI}|${1:-$CI}|null|2026-09-21T20:25:00Z|b2b20002|queued"
}
# NO merges at all: the re-test is a re-RUN of the same red sha. Depth 0.
rerun_same_sha() {
  runs "Harness CI|$CI|failure|2026-09-21T20:00:00Z|aaaa1111" \
       "Harness CI|$CI|failure|2026-09-21T19:30:00Z|cccc3333" \
       "Harness CI|$CI|success|2026-09-21T18:00:00Z|dddd4444" \
       "Harness CI|$CI|null|2026-09-21T20:20:00Z|aaaa1111|in_progress"
}
# BH-1281's own R1: exactly ONE merge landed (the fix), its run in flight. Depth 1.
bh1281_r1() {
  runs "Harness CI|$CI|failure|2026-09-21T20:00:00Z|aaaa1111" \
       "Harness CI|$CI|failure|2026-09-21T19:30:00Z|cccc3333" \
       "Harness CI|$CI|success|2026-09-21T18:00:00Z|dddd4444" \
       "Harness CI|$CI|null|2026-09-21T20:20:00Z|f1x00001|in_progress"
}

JOBS_ANSWER="Pure-logic gate fixtures"
MAIN_RED_HOLD_OVERRUN=""

# ── H1. THE TICKET'S FIRST TEST: two-red main + hold + two merges -> freeze ──
reset_case; overrun
drive o/r
[ -s "$FLAG" ] && ok || bad "H1: no freeze written after main ran away from the held sha (err=$(cat "$T/err.txt"); log=$(mrlog))"
grep -q '^sha=aaaa1111$'               "$FLAG" 2>/dev/null && ok || bad "H1: the freeze must sit on the HELD sha's failure: $(cat "$FLAG" 2>/dev/null)"
grep -q '^reason=held-overrun$'        "$FLAG" 2>/dev/null && ok || bad "H1: flag reason: $(cat "$FLAG" 2>/dev/null)"
grep -q '^streak=2$'                   "$FLAG" 2>/dev/null && ok || bad "H1: flag streak: $(cat "$FLAG" 2>/dev/null)"
grep -q '^since=2026-09-21T19:30:00Z$' "$FLAG" 2>/dev/null && ok || bad "H1: flag since: $(cat "$FLAG" 2>/dev/null)"
grep -q '^head=b2b20002$'              "$FLAG" 2>/dev/null && ok || bad "H1: the flag must name the head main has moved on to: $(cat "$FLAG" 2>/dev/null)"
grep -q '^depth=2$'                    "$FLAG" 2>/dev/null && ok || bad "H1: the flag must say how far main ran: $(cat "$FLAG" 2>/dev/null)"
grep -q '^job=Pure-logic gate fixtures$' "$FLAG" 2>/dev/null && ok || bad "H1: flag job: $(cat "$FLAG" 2>/dev/null)"
grep -q '^workflow=Harness CI$'        "$FLAG" 2>/dev/null && ok || bad "H1: flag workflow: $(cat "$FLAG" 2>/dev/null)"
case "$(verdict)" in *"decision=red"*) ok ;; *) bad "H1: verdict: $(verdict)" ;; esac
case "$(verdict)" in *"reason=held-overrun"*) ok ;; *) bad "H1: verdict reason: $(verdict)" ;; esac
case "$(verdict)" in *"sha=aaaa1111"*) ok ;; *) bad "H1: verdict sha: $(verdict)" ;; esac
[ "$(alerts)" = 1 ]     && ok || bad "H1: sent $(alerts) alerts, want 1: $(cat "$T/alerts.txt")"
case "$(cat "$T/alerts.txt")" in
  "--critical main-red o/r main is RED"*"merge(s) landed on top of it"*"sha aaaa1111"*) ok ;;
  *) bad "H1: wrong alert: $(cat "$T/alerts.txt")" ;;
esac
[ "$(publishes)" = 1 ]  && ok || bad "H1: published $(publishes) rows, want 1: $(cat "$T/publish.txt")"
# 2: the page, and the re-read every NEW raise makes to confirm it (BH-1927).
[ "$(runs_reads)" = 2 ] && ok || bad "H1: made $(runs_reads) runs reads, want 2: $(cat "$T/gh.txt")"
[ "$(jobs_reads)" = 1 ] && ok || bad "H1: made $(jobs_reads) jobs reads, want 1: $(cat "$T/gh.txt")"
case "$(mrlog)" in *"hold ended after 2 merge(s)"*) ok ;; *) bad "H1: the log does not say the hold ended: $(mrlog)" ;; esac
case "$(mrlog)" in *"b2b20002"*) ok ;; *) bad "H1: the log does not name the newest merge: $(mrlog)" ;; esac
case "$(mrlog)" in *"f1x00001"*) ok ;; *) bad "H1: the log does not name the first merge: $(mrlog)" ;; esac
case "$(mrlog)" in *"main green"*) bad "H1: an overrun logged as main green: $(mrlog)" ;; *) ok ;; esac

# ── H2. THE TICKET'S SECOND TEST: two-red main + hold + no merges -> held ───
reset_case; rerun_same_sha
drive o/r
[ -e "$FLAG" ] && bad "H2: a re-run in flight on the SAME sha is not an overrun: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ]    && ok || bad "H2: paged: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ] && ok || bad "H2: published a pause row: $(cat "$T/publish.txt")"
[ "$(jobs_reads)" = 0 ] && ok || bad "H2: made $(jobs_reads) jobs reads, want 0: $(cat "$T/gh.txt")"
# A KEPT HOLD RECORDS THE HOLD, not "nothing decided" (BH-1451, merged after
# this branch opened): the held tick writes decision=held / reason=re-test and
# its sha= names the run in flight it is waiting on. The assertion is the same
# claim as before — this tick raised no freeze — against the verdict the
# detector now writes for it.
case "$(verdict)" in *"decision=held"*) ok ;; *) bad "H2: verdict: $(verdict)" ;; esac
case "$(verdict)" in *"reason=re-test"*) ok ;; *) bad "H2: verdict reason: $(verdict)" ;; esac
case "$(verdict)" in *"sha=aaaa1111"*) ok ;; *) bad "H2: verdict sha: $(verdict)" ;; esac
case "$(mrlog)" in *"in flight on aaaa1111"*) ok ;; *) bad "H2: the held line lost its BH-1281 wording: $(mrlog)" ;; esac
case "$(mrlog)" in *"the hold ends at 2"*) ok ;; *) bad "H2: the held line must say where the hold ends: $(mrlog)" ;; esac
case "$(mrlog)" in *"main green"*) bad "H2: a held streak logged as main green: $(mrlog)" ;; *) ok ;; esac

# ── K1. THE DEFAULT holds BH-1281's own shape (depth 1, one merge) ──────────
reset_case; bh1281_r1
drive o/r
[ -e "$FLAG" ] && bad "K1: the default ended BH-1281's hold — one merge is not an overrun: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ] && ok || bad "K1: paged: $(cat "$T/alerts.txt")"
case "$(mrlog)" in *"in flight on f1x00001"*) ok ;; *) bad "K1: no held line: $(mrlog)" ;; esac
case "$(mrlog)" in *"the hold ends at 2"*) ok ;; *) bad "K1: the held line must say where the hold ends: $(mrlog)" ;; esac

# ── K2. THE KNOB IS READ: the same fixture at 1 fires, exactly at the bound ──
reset_case; bh1281_r1
MAIN_RED_HOLD_OVERRUN=1 drive o/r
[ -s "$FLAG" ] && ok || bad "K2: MAIN_RED_HOLD_OVERRUN=1 did not fire on a depth-1 hold: $(mrlog)"
grep -q '^reason=held-overrun$' "$FLAG" 2>/dev/null && ok || bad "K2: flag reason: $(cat "$FLAG" 2>/dev/null)"
grep -q '^depth=1$'             "$FLAG" 2>/dev/null && ok || bad "K2: the arm must fire AT the bound, not past it: $(cat "$FLAG" 2>/dev/null)"
grep -q '^head=f1x00001$'       "$FLAG" 2>/dev/null && ok || bad "K2: flag head: $(cat "$FLAG" 2>/dev/null)"
grep -q '^sha=aaaa1111$'        "$FLAG" 2>/dev/null && ok || bad "K2: flag sha: $(cat "$FLAG" 2>/dev/null)"
case "$(mrlog)" in *"hold ended after 1 merge(s)"*"f1x00001"*) ok ;; *) bad "K2: log: $(mrlog)" ;; esac

# ── K3. ZERO DISARMS: byte-for-byte the pre-BH-1475 decision ────────────────
reset_case; overrun
MAIN_RED_HOLD_OVERRUN=0 drive o/r
[ -e "$FLAG" ] && bad "K3: MAIN_RED_HOLD_OVERRUN=0 must never end a hold: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ]    && ok || bad "K3: paged: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ] && ok || bad "K3: published a pause row: $(cat "$T/publish.txt")"
case "$(mrlog)" in *"in flight on b2b20002"*) ok ;; *) bad "K3: the hold lost its line when disarmed: $(mrlog)" ;; esac
case "$(mrlog)" in *"the hold ends at 0"*) bad "K3: a disarmed hold must not advertise a bound: $(mrlog)" ;; *) ok ;; esac

# ── K4. A GARBAGE KNOB falls back to 2 — a typo must not disarm a freeze ────
reset_case; overrun
MAIN_RED_HOLD_OVERRUN=abc drive o/r
[ -s "$FLAG" ] && ok || bad "K4: a non-numeric knob silently disarmed the arm: $(mrlog)"
grep -q '^reason=held-overrun$' "$FLAG" 2>/dev/null && ok || bad "K4: flag reason: $(cat "$FLAG" 2>/dev/null)"

# ── N1. A SKIP-LISTED workflow is never held, so it can never overrun ───────
reset_case; overrun "$E2E" "E2E"
drive o/r
[ -e "$FLAG" ] && bad "N1: a perma-red nightly froze the fleet: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ] && ok || bad "N1: paged on a skip-listed workflow: $(cat "$T/alerts.txt")"
case "$(mrlog)" in *"no completed run of a REQUIRED workflow"*) ok ;; *) bad "N1: wrong line: $(mrlog)" ;; esac

# ── N2. A FLAG ALREADY ON DISK is judged byte-for-byte as before ────────────
reset_case; overrun
drive o/r
[ -s "$FLAG" ] && ok || bad "N2: setup did not write the flag"
flag_before=$(sha256sum "$FLAG" | awk '{print $1}')
: > "$T/alerts.txt"; : > "$T/publish.txt"; : > "$T/logs/main-red.log"; : > "$T/gh.txt"
drive o/r
[ "$(sha256sum "$FLAG" | awk '{print $1}')" = "$flag_before" ] && ok \
  || bad "N2: the standing flag was rewritten: $(cat "$FLAG")"
[ "$(alerts)" = 0 ]    && ok || bad "N2: sent a second alert: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 1 ] && ok || bad "N2: published $(publishes) rows, want 1 (the still-red republish): $(cat "$T/publish.txt")"
case "$(mrlog)" in *"still red"*"flag already set"*) ok ;; *) bad "N2: wrong still-red line: $(mrlog)" ;; esac
case "$(mrlog)" in *"hold ended"*) bad "N2: the overrun arm ran on the flag path: $(mrlog)" ;; *) ok ;; esac
case "$(mrlog)" in *"in flight on"*) bad "N2: the hold ran on the flag path: $(mrlog)" ;; *) ok ;; esac

# ── N3. --explain over the overrun stays read-only (BH-997) ────────────────
reset_case; overrun
scratch_rm "$T/locks"; scratch_rm "$T/flags"
drive --explain o/r
[ -e "$FLAG" ]    && bad "N3: --explain wrote the flag" || ok
[ -d "$T/locks" ] && bad "N3: --explain created the locks/ directory" || ok
[ -d "$T/flags" ] && bad "N3: --explain created the flags/ directory" || ok
[ -e "$T/state/main-red/o-r.verdict" ] && bad "N3: --explain wrote a verdict file" || ok
[ "$(alerts)" = 0 ]    && ok || bad "N3: --explain paged: $(cat "$T/alerts.txt")"
[ "$(publishes)" = 0 ] && ok || bad "N3: --explain published a row: $(cat "$T/publish.txt")"
case "$(out)" in *"WOULD WRITE"*"reason=held-overrun"*) ok ;; *) bad "N3: --explain did not describe the raise: $(out)" ;; esac
case "$(out)" in *"head=b2b20002"*"depth=2"*) ok ;; *) bad "N3: --explain lost the head/depth fields: $(out)" ;; esac
case "$(out)" in *"hold ended after 2 merge(s)"*"b2b20002,f1x00001"*) ok ;; *) bad "N3: --explain did not name the merges: $(out)" ;; esac
mkdir -p "$T/locks" "$T/flags"

# ── N4. The in-flight run belongs to ANOTHER workflow: never held at all, so
#       the raise is the ordinary streak. The arm cannot claim what it never held.
reset_case
runs "Harness CI|$CI|failure|2026-09-21T20:00:00Z|aaaa1111" \
     "Harness CI|$CI|failure|2026-09-21T19:30:00Z|cccc3333" \
     "Harness CI|$CI|success|2026-09-21T18:00:00Z|dddd4444" \
     "E2E|$E2E|null|2026-09-21T20:20:00Z|f1x00001|in_progress" \
     "E2E|$E2E|null|2026-09-21T20:25:00Z|b2b20002|queued"
drive o/r
[ -s "$FLAG" ] && ok || bad "N4: the plain streak raise was lost: $(mrlog)"
grep -q '^reason=streak$' "$FLAG" 2>/dev/null && ok || bad "N4: a never-held streak must raise as reason=streak: $(cat "$FLAG" 2>/dev/null)"
grep -q '^head=' "$FLAG" 2>/dev/null && bad "N4: the streak arm must not grow burst fields: $(cat "$FLAG" 2>/dev/null)" || ok
case "$(mrlog)" in *"hold ended"*) bad "N4: claimed a hold it never had: $(mrlog)" ;; *) ok ;; esac

# ── N5. AN UNREADABLE DEPTH decides nothing. The held row's sha is missing, so
#       it is in no sha ordering and column 12 comes out empty — the same
#       doctrine as the unparseable created_at guard on the arms above. The
#       hold stands, and the line says so rather than printing "" merge(s).
reset_case
runs "Harness CI|$CI|failure|2026-09-21T20:00:00Z|" \
     "Harness CI|$CI|failure|2026-09-21T19:30:00Z|" \
     "Harness CI|$CI|success|2026-09-21T18:00:00Z|dddd4444" \
     "Harness CI|$CI|null|2026-09-21T20:20:00Z|f1x00001|in_progress"
drive o/r
[ -e "$FLAG" ] && bad "N5: an unreadable depth must decide nothing: $(cat "$FLAG")" || ok
[ "$(alerts)" = 0 ] && ok || bad "N5: paged on a depth it could not read: $(cat "$T/alerts.txt")"
case "$(mrlog)" in *"unreadable, so the hold stands"*) ok ;; *) bad "N5: the held line must stay true when depth is unreadable: $(mrlog)" ;; esac
case "$(mrlog)" in *" merge(s) have landed"*) bad "N5: printed a merge count it does not have: $(mrlog)" ;; *) ok ;; esac

# ── G1. GREEN CONTROL: a genuinely green main still says so ────────────────
reset_case
runs "Harness CI|$CI|success|2026-09-21T20:00:00Z|eeee5555"
drive o/r
[ -e "$FLAG" ] && bad "G1: raised on a green main: $(cat "$FLAG")" || ok
case "$(mrlog)" in *"main green (1 required workflow(s))"*) ok ;; *) bad "G1: green main lost its log line: $(mrlog)" ;; esac

echo "main-red-hold-overrun-bh-1475: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
