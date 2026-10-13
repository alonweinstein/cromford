#!/bin/bash
# tests/merge-sweep-line-retired.bh-1388-test.sh — BH-1388 (BH-1025.3): the hub
# merge-sweep CRON LINE is retired, and bin/pipeline-health.sh's "sweep should
# have landed" detector reads the merge LEDGER as a second "handled" answer.
#
# WHY BOTH HALVES ARE IN ONE SUITE. They are one change: the sweep stops running
# on the hub, so `state/merge-sweep-done.txt` stops growing, and the only
# durable record that a PR was landed is the ledger row the merge conductor
# writes (`mc_settle_merged`). A detector that kept asking only the file would
# page on every PR the conductor merged from the day the lane went — the exact
# silence-into-noise flip this ticket has to not cause.
#
# WHAT IS DRIVEN, AND WHAT IS ASSERTED.
#
#   "cron": the REAL renderers. cron/hub.cron and catalog/lanes.json are
#     GENERATED and not committed (BH-1247), so the section renders them through
#     tests/lib/rendered.sh and asserts on the rendered TEXT the hub would
#     install — never on the renderer's source. The merge conductor's own */5
#     line is asserted present in the same breath: "the sweep line is gone" is
#     only safe because something else still merges.
#
#   "pipeline-health": the detector block is extracted VERBATIM by its markers
#     (the shape tests/pipeline-health-detectors-test.sh established) and driven
#     with a recording alert(), a gh shim and the REAL bin/jobs-client.sh behind
#     a curl shim — so `merge_ledger_has` is the production verb reading the
#     production route shape, not a stub. Every case asserts on the alert sink
#     and the gh sink.
#
# THE STAMP IS PRE-SEEDED STALE in every pipeline-health case on purpose: with a
# fresh stamp the detector never pages at all, so a "no alert" assertion would
# pass for the wrong reason. Seeded stale, case 4 proves the alert DOES fire on
# the same fixture — which is what makes cases 1, 2 and 3 mean something.
#
# No network, no git, nothing written outside $T (bin/render-cron.sh writes its
# render into $T through tests/lib/rendered.sh).
#
# Run from anywhere: bash tests/merge-sweep-line-retired.bh-1388-test.sh
# (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/rendered.sh
. "$(dirname "$0")/lib/rendered.sh" || exit 1
# The extracted block reads review.md through verdict_is (bin/lib/verdict-parse.sh,
# BH-1625). The bash -c driver below does not source it, so without the shared
# fixture every APPROVE fixture reads as unknown and the block skips the record
# (ph4/ph5 went silent). vpf_export puts the REAL reader in every child bash.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): the stale
# stamp below is stale BY CONSTRUCTION, whatever the wall clock says.
NOW=$(date -u +%s)

# ===========================================================================
# cron — the lane is gone from the sources, so it is gone from the render
# ===========================================================================
echo "== cron =="

CRON=$(rendered_cron hub)
REG=$(rendered_registry)

# The sweep's own path, spelled with its directory so bin/tier2-merge-sweep.sh
# (a BOX lane this ticket does not touch) cannot satisfy a substring match.
N=$(grep -cF -- '/bin/merge-sweep.sh' "$CRON")
[ "$N" = 0 ] && ok || bad "cron: the hub crontab still runs the merge sweep ($N line(s)): $(grep -F -- '/bin/merge-sweep.sh' "$CRON")"

N=$(grep -cF -- '/bin/merge-conductor.sh' "$CRON")
[ "$N" = 1 ] && ok || bad "cron: the hub must still run the merge conductor exactly once, found $N"

# ...and that surviving line is still lease-gated, i.e. the sweep's removal did
# not take the hub-lanes block it lived in with it.
# Two greps through a file, never a pipe into grep -q: under pipefail the
# first grep can die of SIGPIPE when -q exits early (tests/rollup-crash-loud-test.sh).
grep -F -- '/bin/merge-conductor.sh' "$CRON" > "$T/mc-line.txt"
grep -q 'hub-lease.sh check && ' "$T/mc-line.txt" && ok \
  || bad "cron: the merge conductor line lost its lease gate: $(grep -F -- '/bin/merge-conductor.sh' "$CRON")"

N=$(jq -r '.lanes[].id' "$REG" | grep -cx merge-sweep)
[ "$N" = 0 ] && ok || bad "cron: catalog/lanes.json still registers the merge-sweep lane"
N=$(jq -r '.lanes[].id' "$REG" | grep -cx merge-conductor)
[ "$N" = 1 ] && ok || bad "cron: catalog/lanes.json must still register merge-conductor, found $N"

[ ! -e "$DIR/cron/lanes/400-merge-sweep.cron" ] && ok \
  || bad "cron: cron/lanes/400-merge-sweep.cron must be deleted"
[ ! -e "$DIR/catalog/lanes.d/merge-sweep.json" ] && ok \
  || bad "cron: catalog/lanes.d/merge-sweep.json must be deleted"

# NEGATIVE: the SCRIPT stays, and stays runnable. The ticket retires the lane,
# not the sweep — bin/batch-resolve.sh and an operator still run it by hand.
[ -f "$DIR/bin/merge-sweep.sh" ] && ok || bad "cron: bin/merge-sweep.sh must NOT be deleted"
bash -n "$DIR/bin/merge-sweep.sh" 2>"$T/sweep-n.err" && ok \
  || bad "cron: bin/merge-sweep.sh no longer parses: $(cat "$T/sweep-n.err")"

# TEST-CHANGE (lead review of 7082ef6): the two "box tier2-merge-sweep lane is
# untouched" assertions that stood here are gone. BH-1366 (#1366) retired that
# lane on main separately, so the files they asserted present no longer exist
# anywhere and the assertions were red on main's own tree. This ticket never
# touched them; nothing is left for this suite to pin about them.

# ===========================================================================
# pipeline-health — the merge ledger is a second "handled" answer
# ===========================================================================
echo "== pipeline-health =="

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/flags" "$H/builds" "$T/fakebin"
awk '/^# >>> sweep should have landed/{f=1;next} /^# <<< sweep should have landed/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/c1.sh"
[ -s "$T/c1.sh" ] && ok || bad "pipeline-health: the '>>> sweep should have landed' block did not extract"

cp "$DIR/bin/jobs-client.sh" "$H/bin/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/" || exit 1
# TEST-CHANGE (BH-1585, #1614): the block reads the record's PR through
# bin/lib/pr-terminal.sh (REST, a persisted terminal marker) instead of
# `gh pr view`, and skips every record when that lib is absent. The driver
# sources it exactly as bin/pipeline-health.sh does; gh-rest-var.sh rides along
# for the contract lib, as in tests/pipeline-health-detectors-test.sh.
cp "$DIR/bin/lib/pr-terminal.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/" || exit 1
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

# The curl shim: the BH-1385 shape. /api/flags/* is a 404 so flag_active falls
# to the file; /api/ledger is answered from a TSV fixture so the REAL
# job_ledger_get (and merge_ledger_has above it) is what decides; LEDGER_DOWN_KIND
# is a transport failure for one kind, which is what a worker outage looks like.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -sS|-S|-s|-L|-f) shift;;
    *) URL="$1"; shift;;
  esac
done
[ -n "${REQ_LOG:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
[ "${CURL_MODE:-ok}" = down ] && exit 7
ud() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
qp() { printf '%s' "${URL#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
case "$URL" in
  */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;;
  */api/ledger\?*)
    K=$(ud "$(qp kind)"); V=$(ud "$(qp key)")
    if [ -n "${LEDGER_DOWN_KIND:-}" ] && [ "$K" = "${LEDGER_DOWN_KIND}" ]; then exit 7; fi
    LINE=$(awk -F'\t' -v k="$K" -v v="$V" '$1==k && $2==v {print; exit}' "${LEDGER_ROWS:-/dev/null}" 2>/dev/null)
    if [ -n "$LINE" ]; then
      jq -nc --arg s "$(printf '%s' "$LINE" | cut -f3)" '{ledger:{status:$s}}'
      printf '\n200\n'
    else
      printf '{"error":"not found"}\n404\n'
    fi
    exit 0 ;;
esac
printf '{"ok":true}\n200\n'
CURL
chmod +x "$T/fakebin/curl"

# The gh shim: every call is recorded, so "did the detector even ask GitHub"
# is a fact about the run. The PR reads OPEN CLEAN on a fixed head — over the
# REST pull read prt_read makes since BH-1585 (the shape
# tests/pipeline-health-detectors-test.sh answers), and over the old
# `gh pr view` too, so a regression back to it would still be recorded.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/o/r -q .id") exit 0 ;;
  *"repos/o/r/pulls/"[0-9]*)
    printf 'HTTP/2.0 200\r\n\r\n'
    printf '{"state":"open","merged":false,"merged_at":null,"mergeable_state":"clean","user":{"login":"operator"},"head":{"ref":"b","sha":"headsha"}}\n' ;;
  *"pr view"*) echo "OPEN CLEAN headsha" ;;
  *"api rate_limit"*)
    now=$(date +%s)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":5000,"limit":5000,"reset":%s}}}' "$((now + 3600))" "$((now + 3600))" ;;
  *) echo "" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"

PR="https://github.com/o/r/pull/7"
REC="$H/builds/pool-ts-TK-269-202609120001"; mkdir -p "$REC"
echo "PR_CREATED $PR" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
: > "$H/logs/merge-sweep.log"
LEDGER="$T/ledger.tsv"; : > "$LEDGER"

# drive — the extracted block, with the REAL jobs client sourced under it.
# job_verdict is stubbed to a real MISS (rc 2) so the verdict comes from
# review.md, exactly as it does on a hub whose ledger has no verdict row: the
# ledger this suite is about is the MERGE ledger, not the verdict one.
drive() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/req.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" T="$T" H="$H" GH_SINK="$T/gh.txt" \
           GH_BUDGET_TTL_S=0 HARNESS_SECRET=x JOBS_BOX=testbox JOBS_URL=http://jobs.test \
           JOBS_RETRIES=0 JOBS_ALERT=0 REQ_LOG="$T/req.log" \
           LEDGER_ROWS="$LEDGER" LEDGER_DOWN_KIND="${LEDGER_DOWN_KIND:-}" \
           CURL_MODE=ok
    unset GH_TOKEN
    bash -c '
      set -uo pipefail
      NOW=$(date +%s)
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      . "$H/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90
      job_verdict() { return 2; }
      . "$H/bin/lib/gh-repo-token.sh"
      . "$H/bin/lib/gh-pr-list.sh"
      . "$H/bin/lib/gh-budget.sh"
      . "$H/bin/lib/pr-terminal.sh"
      . "$0"' "$T/c1.sh" 2>"$T/err.txt" )
}

# SEED — a stale first-seen-CLEAN stamp and an empty merge-sweep-done.txt, i.e.
# the exact state in which today's detector PAGES. Every case below starts here.
seed() {
  printf '%s headsha %s\n' "$PR" "$((NOW - 1900))" > "$H/state/sweep-clean-seen.txt"
  : > "$H/state/merge-sweep-done.txt"
  : > "$LEDGER"
  rm -f "$REC/pr-terminal"   # a marker a previous case persisted would skip the record
  LEDGER_DOWN_KIND=""
}

# --- 1. a `merge` ledger row that says merged: handled, no alert, no gh read
seed
printf 'merge\t%s\tmerged\n' "$PR" > "$LEDGER"
drive
[ ! -s "$T/alerts.txt" ] && ok \
  || bad "ph1: a PR the merge ledger says MERGED must not page: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"
grep -qE 'pr view|pulls/[0-9]' "$T/gh.txt" \
  && bad "ph1: a ledgered PR must be skipped BEFORE the gh read: $(cat "$T/gh.txt")" || ok
grep -q '/api/ledger' "$T/req.log" && ok \
  || bad "ph1: the detector never asked the ledger at all: $(cat "$T/req.log")"

# --- 2. the same answer under the OTHER kind: pr_merged
seed
printf 'pr_merged\t%s\tmerged\n' "$PR" > "$LEDGER"
drive
[ ! -s "$T/alerts.txt" ] && ok \
  || bad "ph2: a PR ledgered merged under kind pr_merged must not page: $(cat "$T/alerts.txt")"

# --- 3. ledger OUTAGE + the file says handled: no alert, exactly as today
seed
echo "$PR" > "$H/state/merge-sweep-done.txt"
LEDGER_DOWN_KIND=merge
drive
[ ! -s "$T/alerts.txt" ] && ok \
  || bad "ph3: the sweep-done FILE must still answer while the ledger is out: $(cat "$T/alerts.txt")"

# --- 4. ledger OUTAGE + no file line + stale CLEAN stamp: THE alert fires.
#        rc 1 is never read as "merged" (D9): an outage falls through to today's
#        classification, and today's classification pages.
seed
LEDGER_DOWN_KIND=merge
drive
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && ok \
  || bad "ph4: a ledger outage must fall through to today's classification and page: $(cat "$T/alerts.txt") err=$(cat "$T/err.txt")"

# --- 5. a ledger row with some OTHER status is a real MISS, not a merge.
#        bin/reconcile-prs.sh writes `closed` under kind `merge`; that PR was
#        never landed and the detector must still page.
seed
printf 'merge\t%s\tclosed\n' "$PR" > "$LEDGER"
drive
grep -q "^3600|sweepstall:o/r#7|" "$T/alerts.txt" && ok \
  || bad "ph5: a ledger row with status 'closed' is not a merge and must still page: $(cat "$T/alerts.txt")"

# --- 6. and the file is still checked FIRST, so a PR the file has answered
#        costs no ledger request at all (the block runs over every PR_CREATED
#        record every ten minutes).
seed
echo "$PR" > "$H/state/merge-sweep-done.txt"
printf 'merge\t%s\tmerged\n' "$PR" > "$LEDGER"
drive
grep -q '/api/ledger' "$T/req.log" \
  && bad "ph6: a PR the sweep-done file already answers must cost no ledger GET: $(cat "$T/req.log")" || ok

# --- 7. a ledger rc 0 is PERSISTED as the record's terminal marker (review N2),
#        in the format bin/lib/pr-terminal.sh writes and reads, so the next tick
#        answers from the record and costs neither a ledger GET nor a PR read.
seed
printf 'merge\t%s\tmerged\n' "$PR" > "$LEDGER"
drive
MK=""; MTS=""; MURL=""
[ -r "$REC/pr-terminal" ] && read -r MK MTS MURL < "$REC/pr-terminal"
[ "$MK" = merged ] && [ "$MURL" = "$PR" ] && [ -n "$MTS" ] && ok \
  || bad "ph7: a ledgered merge must persist 'merged <epoch> <url>' on the record, got: $(cat "$REC/pr-terminal" 2>/dev/null)"
drive
grep -q '/api/ledger' "$T/req.log" \
  && bad "ph7: the second tick must answer from the persisted marker, not the ledger: $(cat "$T/req.log")" || ok
grep -qE 'pr view|pulls/[0-9]' "$T/gh.txt" \
  && bad "ph7: the second tick must not read the PR: $(cat "$T/gh.txt")" || ok
[ ! -s "$T/alerts.txt" ] && ok || bad "ph7: the second tick must not page: $(cat "$T/alerts.txt")"

echo "merge-sweep-line-retired.bh-1388-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
