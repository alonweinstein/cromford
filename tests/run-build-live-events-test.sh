#!/bin/bash
# tests/run-build-live-events-test.sh — the live-event emitters extracted
# VERBATIM from bin/run-build.sh (BH-520) and driven with a stubbed transport.
#
# What is tested here is the WIRING and the MESSAGES, not the jobs worker: the
# emitters run inside every build in the fleet, so the properties that matter
# are (1) a build with no claim posts nothing, (2) a failing suite, a missing
# artifact and a failed PR create can never render as green/open, and (3) no
# message carries a newline or more than 200 characters into the console.
#
# The real bin/jobs-client.sh job_event builds the body and the path; only
# _jobs_req (the curl call) is stubbed, so the asserted path is the one a live
# build would POST to.
# Run from anywhere: tests/run-build-live-events-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/build" "$T/logs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cut_block() { # cut_block <marker-name> <outfile>
  awk -v m="$1" '{ t=$0; sub(/^[[:space:]]+/, "", t) }
       t == "# >>> " m {f=1;next} t == "# <<< " m {exit} f' \
    "$RB_ALL" > "$2"
  [ -s "$2" ]
}

BLOCKS="live events|live emit plan|live emit execute|live emit tests_red|live emit semgrep|live emit e2e|live emit suite|live emit review|live emit fix|live emit tier|live emit pr|live emit verdict|live emit handoff"
IFS='|' read -r -a NAMES <<< "$BLOCKS"
for n in "${NAMES[@]}"; do
  cut_block "$n" "$T/$(echo "$n" | tr ' ' '-').sh" && ok || bad "could not extract block '$n' from bin/run-build.sh"
done

# The emitters run under `set -uo pipefail` in run-build.sh, with a stubbed
# transport. PRELUDE is the harness every row shares.
PRELUDE='set -uo pipefail
STAMP() { echo TS; }
PROJECT=p; KEY=BH-520; BUILD="'"$T"'/build"; ALERTS="'"$T"'/logs/ALERTS.log"
HARNESS_SECRET=x
. "'"$DIR"'/bin/jobs-client.sh"
_jobs_req() { printf "%s %s %s\n" "$1" "$2" "$3" >> "'"$T"'/posts"; }
. "'"$T"'/live-events.sh"
'

drive() { # drive <block-file> <extra-setup-shell>
  rm -f "$T/posts"
  ( cd "$T" && bash -c "$PRELUDE
$2
. \"$T/$1\"" ) >/dev/null 2>&1
  echo $?
}
posts()  { cat "$T/posts" 2>/dev/null; }
# The detail/stage/verdict fields as job_event actually serialised them.
field()  { posts | sed -n "${2:-1}p" | sed 's/^POST [^ ]* //' | jq -r ".${1} // \"\""; }
nposts() { posts | grep -c . ; }

JOB='JOB_ID=j1; JOBS_BOX=box'

# ---------------------------------------------------------------- 1. the helper
# 1a. No claim, no posts. Every box runs builds with the worker unreachable
# (JOB_ID stays empty, fail-open) and those builds must behave byte-identically.
rc=$(drive live-events.sh 'JOB_ID=""; LIVE plan pass "anything"')
[ "$rc" = 0 ] && ok || bad "LIVE with no JOB_ID must succeed (rc=$rc)"
[ -z "$(posts)" ] && ok || bad "LIVE with no JOB_ID must post nothing (got: $(posts))"

# 1b. The path and the body are job_event's, i.e. the existing transport.
rc=$(drive live-events.sh "$JOB; LIVE plan pass 'plan written'")
[ "$rc" = 0 ] && ok || bad "LIVE must return 0 (rc=$rc)"
[ "$(posts | awk '{print $1, $2}')" = "POST /api/jobs/j1/events" ] \
  && ok || bad "LIVE must POST through job_event to /api/jobs/j1/events (got: $(posts | awk '{print $1, $2}'))"
[ "$(field stage)" = plan ] && ok || bad "stage must be 'plan' (got: $(field stage))"
[ "$(field verdict)" = pass ] && ok || bad "verdict must be 'pass' (got: $(field verdict))"
[ "$(field detail)" = "plan written" ] && ok || bad "detail must survive (got: $(field detail))"

# 1c. 200 chars, no newlines, no tabs — the console renders these in one row.
LONG=$(printf 'a%.0s' $(seq 1 300))
rc=$(drive live-events.sh "$JOB; LIVE plan '' \"$LONG\"")
d=$(field detail)
[ "${#d}" -le 200 ] && [ "${#d}" -gt 0 ] && ok || bad "a 300-char message must arrive <=200 chars (got ${#d})"
rc=$(drive live-events.sh "$JOB; MSG=\$'one\\ntwo\\tthree'; LIVE plan '' \"\$MSG\"")
d=$(field detail)
case "$d" in *$'\n'*|*$'\t'*) bad "detail must carry no newline/tab (got: $(printf %q "$d"))" ;; *) ok ;; esac
grep -q 'one two three' <<<"$d" && ok || bad "flattening must keep the words (got: $d)"

# 1d. A transport that fails never fails the build (fail-open, like every other
# jobs-client call).
rc=$(drive live-events.sh "$JOB; _jobs_req() { return 1; }; LIVE plan '' x; echo survived")
[ "$rc" = 0 ] && ok || bad "a failing transport must not fail the build (rc=$rc)"

# 1e. LIVE_COUNT: absent heading is '-', never 0 (D11).
printf 'noise\n' > "$T/build/review.md"
rc=$(drive live-events.sh "$JOB; LIVE plan '' \"n=\$(LIVE_COUNT \"\$BUILD/review.md\")\"")
[ "$(field detail)" = "n=-" ] && ok || bad "no '## Blocking findings' heading must count '-' (got: $(field detail))"
printf '## Blocking findings\n- one\n- two\n\n## Notes\n- three\n' > "$T/build/review.md"
rc=$(drive live-events.sh "$JOB; LIVE plan '' \"n=\$(LIVE_COUNT \"\$BUILD/review.md\")\"")
[ "$(field detail)" = "n=2" ] && ok || bad "two findings under the heading must count 2 (got: $(field detail))"
printf '## Blocking findings\nnone\n' > "$T/build/review.md"
rc=$(drive live-events.sh "$JOB; LIVE plan '' \"n=\$(LIVE_COUNT \"\$BUILD/review.md\")\"")
[ "$(field detail)" = "n=0" ] && ok || bad "a heading with no items must count 0 (got: $(field detail))"

# 1f. LIVE_SUITE: failure is never green, absence is never green (D9/D13).
printf 'Tests: 248 passed\nHARNESS_EXIT: 0\n' > "$T/build/harness-suite.txt"
rc=$(drive live-events.sh "$JOB; LIVE_SUITE \"\$BUILD/harness-suite.txt\" ''")
[ "$(field stage)" = tests_green ] && [ "$(field verdict)" = pass ] \
  && ok || bad "exit 0 must be tests_green/pass (got: $(field stage))/$(field verdict)"
grep -q 248 <<<"$(field detail)" && ok || bad "the pass count must ride along (got: $(field detail))"
printf 'boom\nHARNESS_EXIT: 1\n' > "$T/build/harness-suite.txt"
rc=$(drive live-events.sh "$JOB; LIVE_SUITE \"\$BUILD/harness-suite.txt\" ''")
[ "$(field verdict)" = fail ] && ok || bad "HARNESS_EXIT 1 must be verdict fail (got: $(field verdict))"
[ "$(field verdict)" != pass ] && ok || bad "a failing suite must never render as pass"
printf 'HARNESS_EXIT: no-test-script\n' > "$T/build/harness-suite.txt"
rc=$(drive live-events.sh "$JOB; LIVE_SUITE \"\$BUILD/harness-suite.txt\" ''")
[ "$(field verdict)" = none ] && ok || bad "no-test-script must be verdict none (got: $(field verdict))"
rm -f "$T/build/harness-suite.txt"
rc=$(drive live-events.sh "$JOB; LIVE_SUITE \"\$BUILD/harness-suite.txt\" ''")
[ "$(field verdict)" = not-run ] && ok || bad "a missing suite file must be not-run (got: $(field verdict))"
grep -qi 'not read that as green' <<<"$(field detail)" && ok || bad "the missing-suite message must say it is not green (got: $(field detail))"
rc=$(drive live-events.sh "$JOB; LIVE_SUITE \"\$BUILD/harness-suite.txt\" 'after the fix round: '")
grep -q 'after the fix round' <<<"$(field detail)" && ok || bad "the prefix must reach the message (got: $(field detail))"

# 1g. LIVE_LENS: a BLOCK last line can never render as APPROVE.
printf '## Blocking findings\n- one\nVERDICT: BLOCK\n' > "$T/build/review.md"
rc=$(drive live-events.sh "$JOB; LIVE_LENS review \"\$BUILD/review.md\" ''")
[ "$(field stage)" = review ] && ok || bad "LIVE_LENS must emit stage review (got: $(field stage))"
[ "$(field verdict)" = BLOCK ] && ok || bad "a BLOCK artifact must emit BLOCK (got: $(field verdict))"
grep -q '1 blocking' <<<"$(field detail)" && ok || bad "the finding count must ride along (got: $(field detail))"
printf '## Blocking findings\nnone\nVERDICT: APPROVE\n' > "$T/build/review.md"
rc=$(drive live-events.sh "$JOB; LIVE_LENS review \"\$BUILD/review.md\" ''")
[ "$(field verdict)" = APPROVE ] && ok || bad "an APPROVE artifact must emit APPROVE (got: $(field verdict))"
rm -f "$T/build/review.md"
rc=$(drive live-events.sh "$JOB; LIVE_LENS review \"\$BUILD/review.md\" ''")
[ "$(field verdict)" = none ] && ok || bad "a missing lens artifact must emit verdict none, never APPROVE (got: $(field verdict))"

# ------------------------------------------------- 2. the gate emitters, in turn
# 2a. plan: the size verdict and the declaration the planner wrote.
rc=$(drive live-emit-plan.sh "$JOB; SG_VERDICT=pass; SG_DECL='FILES: 2 LINES: 280'; PG_TASKS=7; PG_UNTRACED=0")
[ "$(field stage)" = plan ] && [ "$(field verdict)" = pass ] \
  && ok || bad "the plan emitter must post plan/pass (got: $(field stage))/$(field verdict)"
grep -q 'FILES: 2' <<<"$(field detail)" && ok || bad "the size declaration must ride along (got: $(field detail))"
# An undeclared size says so rather than posting a blank.
rc=$(drive live-emit-plan.sh "$JOB; SG_VERDICT=not-recorded; SG_DECL=''")
grep -qi 'no size declared' <<<"$(field detail)" && ok || bad "a missing declaration must be named (got: $(field detail))"
[ "$(field verdict)" = not-recorded ] && ok || bad "not-recorded must not become pass (got: $(field verdict))"

# 2b. execute
rc=$(drive live-emit-execute.sh "$JOB; EXECUTE_MODEL=sonnet")
[ "$(field stage)" = execute ] && ok || bad "the execute emitter must post stage execute (got: $(field stage))"
grep -q sonnet <<<"$(field detail)" && ok || bad "the execute model must ride along (got: $(field detail))"

# 2c. tests_red — the reproduction gate's four codes, none of them 'proven' by
# default. This block lives inside `# >>> mechanical gates`, which
# tests/run-build-gates-test.sh drives WITHOUT the helper: with LIVE undefined
# it must be a silent no-op rather than a command-not-found.
rc=$(drive live-emit-tests_red.sh "$JOB; REPRO_RC=0")
[ "$(field stage)" = tests_red ] && [ "$(field verdict)" = proven ] \
  && ok || bad "rc 0 must be tests_red/proven (got: $(field stage))/$(field verdict)"
rc=$(drive live-emit-tests_red.sh "$JOB; REPRO_RC=2")
[ "$(field verdict)" = none ] && ok || bad "rc 2 (no new tests) must be verdict none (got: $(field verdict))"
rc=$(drive live-emit-tests_red.sh "$JOB; REPRO_RC=4")
[ "$(field verdict)" = not-green ] && ok || bad "rc 4 must be not-green (got: $(field verdict))"
rc=$(drive live-emit-tests_red.sh "$JOB; REPRO_RC=137")
[ "$(field verdict)" = not-run ] && ok || bad "an unknown rc must be not-run (got: $(field verdict))"
rm -f "$T/posts" "$T/survived"
( cd "$T" && bash -c 'set -uo pipefail
STAMP() { echo TS; }
PROJECT=p; KEY=BH-520; BUILD="'"$T"'/build"; ALERTS="'"$T"'/logs/ALERTS.log"
_jobs_req() { printf "POST %s %s\n" "$2" "$3" >> "'"$T"'/posts"; }
REPRO_RC=0
. "'"$T"'/live-emit-tests_red.sh"
echo yes > "'"$T"'/survived"' ) >/dev/null 2>&1
[ -f "$T/survived" ] && ok || bad "the tests_red emitter must not abort the gate block when LIVE is undefined"
[ -z "$(posts)" ] && ok || bad "no LIVE helper means no post (got: $(posts))"

# 2d. semgrep
printf 'a.js\nb.js\n' > "$T/build/changed-files.txt"
printf 'finding one\nfinding two\n' > "$T/build/semgrep.txt"
rc=$(drive live-emit-semgrep.sh "$JOB")
[ "$(field stage)" = semgrep ] && [ "$(field verdict)" = findings ] \
  && ok || bad "a non-empty semgrep.txt must be 'findings' (got: $(field stage))/$(field verdict)"
: > "$T/build/semgrep.txt"
rc=$(drive live-emit-semgrep.sh "$JOB")
[ "$(field verdict)" = clean ] && ok || bad "an empty semgrep.txt must be clean (got: $(field verdict))"
rm -f "$T/build/semgrep.txt"
rc=$(drive live-emit-semgrep.sh "$JOB")
[ "$(field verdict)" = skipped ] && ok || bad "no semgrep.txt at all must be skipped, never clean (got: $(field verdict))"

# 2e. e2e
rc=$(drive live-emit-e2e.sh "$JOB; E2E_VERDICT=fail; E2E_RC=4")
[ "$(field stage)" = e2e ] && [ "$(field verdict)" = fail ] \
  && ok || bad "the e2e emitter must carry the verdict (got: $(field stage))/$(field verdict)"
rc=$(drive live-emit-e2e.sh "$JOB; E2E_VERDICT=skip; E2E_RC=3")
[ "$(field verdict)" = skip ] && ok || bad "a skipped e2e must say skip (got: $(field verdict))"

# 2f. review + fix rounds, in order
printf '## Blocking findings\n- one\n- two\nVERDICT: BLOCK\n' > "$T/build/review.md"
rc=$(drive live-emit-review.sh "$JOB; LENSES='review security'; LENS_ART() { echo \"\$BUILD/review.md\"; }")
[ "$(nposts)" -ge 2 ] && ok || bad "one event per lens (got $(nposts))"
[ "$(field stage)" = review ] && ok || bad "the lens emitter must post stage review (got: $(field stage))"
rc=$(drive live-emit-fix.sh "$JOB; LENS_BLOCKED=' review'")
[ "$(field stage)" = fix ] && [ "$(field verdict)" = started ] \
  && ok || bad "the fix emitter must post fix/started (got: $(field stage))/$(field verdict)"
grep -q 'review' <<<"$(field detail)" && ok || bad "the refusing lens must be named (got: $(field detail))"

# 2g. tier
rc=$(drive live-emit-tier.sh "$JOB; TIER=2; TIER_HIT='migrations/'; DELTA=412")
[ "$(field stage)" = tier ] && [ "$(field verdict)" = 2 ] \
  && ok || bad "the tier emitter must carry the tier (got: $(field stage))/$(field verdict)"
grep -q 'migrations/' <<<"$(field detail)" && ok || bad "the matched pattern must ride along (got: $(field detail))"
rc=$(drive live-emit-tier.sh "$JOB; TIER=1; TIER_HIT=''; DELTA=12")
grep -q '12' <<<"$(field detail)" && ok || bad "the line delta must ride along (got: $(field detail))"

# 2h. pr_opened — the #745 finding. A build whose `gh pr create` failed must
# never emit a PR as opened, and must never post an empty url.
rc=$(drive live-emit-pr.sh "$JOB; PR_URL='https://github.com/o/r/pull/9'")
[ "$(field stage)" = pr_opened ] && ok || bad "a real PR must post pr_opened (got: $(field stage))"
grep -q 'pull/9' <<<"$(field detail)" && ok || bad "the PR url must ride along (got: $(field detail))"
rc=$(drive live-emit-pr.sh "$JOB; PR_URL=''; PR_CREATE_ERR='gh: HTTP 422'")
[ "$(field verdict)" = failed ] && ok || bad "a failed create must post verdict failed (got: $(field verdict))"
grep -q '422' <<<"$(field detail)" && ok || bad "the create error must ride along (got: $(field detail))"
grep -qi 'pull/' <<<"$(field detail)" && bad "a failed create must not name a PR url (got: $(field detail))" || ok

# 2i. verdict
printf 'VERDICT: APPROVE\n' > "$T/build/review.md"
rc=$(drive live-emit-verdict.sh "$JOB; VERDICT_WORD=APPROVE; VERDICT_PROV=claude; TIER=1; HEADBOUND_SHA=abc1234")
[ "$(field stage)" = verdict ] && [ "$(field verdict)" = APPROVE ] \
  && ok || bad "the verdict emitter must carry the word (got: $(field stage))/$(field verdict)"
grep -q abc1234 <<<"$(field detail)" && ok || bad "the reviewed sha must ride along (got: $(field detail))"

# 2j. handoff — same #745 rule on the tier-2 path.
rc=$(drive live-emit-handoff.sh "$JOB; TIER=2; PR_URL='https://github.com/o/r/pull/9'")
[ "$(field stage)" = handoff ] && [ "$(field verdict)" = hub-sweep ] \
  && ok || bad "the handoff emitter must carry the destination (got: $(field stage))/$(field verdict)"
rc=$(drive live-emit-handoff.sh "$JOB; TIER=2; PR_URL=''")
[ "$(field verdict)" = failed ] && ok || bad "no PR_URL must hand off as failed (got: $(field verdict))"
grep -qi 'open and approved' <<<"$(field detail)" && bad "a build with no PR must never claim the PR is open (got: $(field detail))" || ok
cut_block "live emit handoff merged" "$T/live-emit-handoff-merged.sh" && ok || bad "could not extract 'live emit handoff merged'"
rc=$(drive live-emit-handoff-merged.sh "$JOB; PR_URL='https://github.com/o/r/pull/9'")
[ "$(field stage)" = handoff ] && [ "$(field verdict)" = merged ] \
  && ok || bad "a tier-1 merge must hand off as merged (got: $(field stage))/$(field verdict)"

# ------------------------------------------- 3. every message is console-clean
for f in "$T"/live-emit-*.sh; do
  grep -qE 'LIVE(_SUITE|_LENS)? ' "$f" && ok || bad "$(basename "$f") contains no LIVE call"
done

echo "run-build-live-events-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
