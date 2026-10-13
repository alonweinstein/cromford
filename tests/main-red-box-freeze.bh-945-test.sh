#!/bin/bash
# tests/main-red-box-freeze.bh-945-test.sh — BH-945: the main-red freeze reaches
# EVERY merge path, from the shared flag store.
#
# THE INCIDENT (2026-09-18). flags/main-red-example-org-cromford went up on
# the hub at 20:41Z and the merge conductor logged "MAIN_RED_FREEZE in force"
# every tick — while #931 (21:10Z) and #942 (22:42Z) merged into that same red
# main through box-side lanes that have no main-red awareness at all. Two halves
# were broken: the flag never left the hub (the detector wrote a local file and
# never published the pause_flags row), and only the conductor ever asked.
#
# Driven, not grepped. bin/merge-queue.sh, bin/tier2-merge-sweep.sh,
# bin/batch-resolve.sh and bin/main-red-detector.sh run WHOLE against a scratch
# $HARNESS; bin/merge-sweep.sh, bin/review-prs.sh and bin/run-build.sh have their
# production blocks extracted VERBATIM by their `# >>>` markers and run. Every
# assertion is on an artifact — the `gh pr merge` sink, the lane logs, the queue
# directory, the recorded HTTP requests — never on source text.
#
# bin/lib/main-red-gate.sh is copied only if it EXISTS, so this suite runs
# against the merge base too: there every lane merges straight through the flag
# and the detector records no PUT, which is this build's red proof.
#
# Every fixture value is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/main-red-box-freeze.bh-945-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-1939: the scratch tree below carries no lane registry, and main-red-gate.sh
# no longer has a literal default; these are the values a box resolves from
# catalog/lanes.d/_lib.main-red-gate.json.
export MC_MAIN_RED_LABEL=fix-main-red MC_MAIN_RED_TEST_PATHS='tests/* worker/*/test/*'
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PROJECT=demo-os
SLUG=example-org/demo-os
FLAGNAME=main-red-example-org-demo-os
PFLAGNAME=main-red-demo-os
OTHERFLAG=main-red-example-org-other-os
H1=aaaaaaaa1111
H2=bbbbbbbb2222
H3=cccccccc3333

# ---------------------------------------------------------------------------
# The scratch harness the lanes run against.
# ---------------------------------------------------------------------------
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/env" \
         "$T/h/builds" "$T/h/state" "$T/fakebin"
cp "$DIR/bin/merge-queue.sh" "$DIR/bin/batch-resolve.sh" \
   "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# The queue's own read (mq_pr) goes through bin/lib/gh-rest.sh since BH-784, so
# the fixture tree carries it exactly as a box does — without it the lib's
# fail-closed shim answers "unverifiable" to every read and every Q section
# below would be green on a queue that never read a PR. restpr
# (tests/lib/rest-emit.sh) is how the stub answers it: the contract judges the
# HTTP STATUS LINE, so an echoed word says nothing at all.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# THE FILE THAT MAKES THIS SUITE DRIVE THE MERGE BASE TOO: absent, every lane
# below behaves exactly as it did before BH-945 and its HELD assertions fail.
[ -r "$DIR/bin/lib/main-red-gate.sh" ] && cp "$DIR/bin/lib/main-red-gate.sh" "$T/h/bin/lib/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$T/h/env/global.env"
: > "$T/h/env/$PROJECT.env"
printf '%s %s - - 2 box-demo\n' "$PROJECT" "$SLUG" > "$T/h/fleet.conf"

cat > "$T/h/bin/fleet-conf.sh" <<SHIM
#!/bin/bash
case "\$1 \${2:-}" in
  "--projects ") echo "$PROJECT" ;;
  "$PROJECT repo") echo "$SLUG" ;;
  "$PROJECT board_prefix") echo "-" ;;
esac
exit 0
SHIM
chmod +x "$T/h/bin/fleet-conf.sh"
for s in beat.sh deploy-request.sh lander.sh lane-alert.sh review-tighten.sh; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "${BEAT_SINK:-/dev/null}"\nexit 0\n' > "$T/h/bin/$s"
  chmod +x "$T/h/bin/$s"
done
for s in flock git sleep; do
  printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/$s"; chmod +x "$T/fakebin/$s"
done

# gh: one shim for every section. `pr merge` argv lands in its OWN sink, which
# is what "a hold writes nothing to GitHub" is asserted on. The PR number is the
# first number in the argv, which is true of every call shape below.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "$*" >> "${GH_SINK:-/dev/null}"
N=$(printf '%s' "$*" | grep -oE '[0-9]+' | head -1)
case "$*" in
  *"pr merge"*)   printf 'pr merge %s | %s\n' "$N" "$*" >> "${GH_MERGES:-/dev/null}"; exit 0 ;;
  *"pr comment"*) exit 0 ;;
  # THE QUEUE'S OWN READS ARE REST (BH-784): one pull object carries the state,
  # the head sha, the head ref, the labels and the merge commit, and the file
  # list is the paginated /files route. bin/lib/main-red-gate.sh still buys its
  # head+labels over `gh pr view --json headRefOid,labels`, so that arm stays.
  *"/pulls/"*"/files?per_page="*)
      restpr --raw 200 "$(jq -R -s -c 'split("\n")|map(select(length>0))|map({filename:.})' \
        < "$FIX/files-$N" 2>/dev/null)" ;;
  *"api -i -X GET repos/"*"/pulls/"*)
      MQL=$(cut -f2 "$FIX/labels-$N" 2>/dev/null | head -1)
      if grep -q "pr merge $N " "${GH_MERGES:-/dev/null}" 2>/dev/null
      then restpr MERGED aaaaaaaa1111 "ticket/demo-$N" main "$MQL" MERGEABLE CLEAN operator dddddddd4444
      else restpr OPEN   aaaaaaaa1111 "ticket/demo-$N" main "$MQL" MERGEABLE CLEAN operator; fi ;;
  *"--json headRefOid,labels"*)
      [ -f "$FIX/labels-$N" ] || exit 1
      cat "$FIX/labels-$N" ;;
  # mc_pr_files reads the list over REST now (BH-587 review round 1) and has no
  # GraphQL fallback; the old spelling stays for any caller still using it.
  *"/files"*)         cat "$FIX/files-$N" 2>/dev/null ;;
  *"--json files"*)   cat "$FIX/files-$N" 2>/dev/null ;;
  *"--json headRefOid"*) printf '%s\n' "aaaaaaaa1111" ;;
  *"--json state,mergeable,headRefName"*) printf 'OPEN MERGEABLE ticket/demo-%s\n' "$N" ;;
  *"--json state,headRefName"*)           printf 'OPEN ticket/demo-%s\n' "$N" ;;
  *"--json state,mergeStateStatus"*)      printf 'OPEN CLEAN\n' ;;
  *"--json state"*)
      if grep -q "pr merge $N " "${GH_MERGES:-/dev/null}" 2>/dev/null; then echo MERGED; else echo OPEN; fi ;;
  *"--json mergeCommit"*) printf 'dddddddd4444\n' ;;
  *"/actions/runs/"*"/jobs"*) printf '%s\n' "${JOBS_ANSWER:-}" ;;
  *"actions/runs"*)
      [ -s "$FIX/runs.json" ] || exit 1
      jq -c '[.workflow_runs[]? | {n:.name, p:.path, s:.status, c:.conclusion, sha:.head_sha, t:.created_at, u:.html_url, id:.id}]' "$FIX/runs.json" ;;
  *) printf '\n' ;;
esac
exit 0
SHIM
chmod +x "$T/fakebin/gh"

# curl: the coordination worker. CURL_MODE=down is an outage (exit 7); a GET of
# /api/flags/<name> answers a row only for $ROW_FLAG, everything else 404s.
# Every request is recorded so the detector's PUT can be read back.
cat > "$T/fakebin/curl" <<'SHIM'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "${REQ_SINK:-/dev/null}"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$METHOD $URL" in
  "PUT "*/api/flags)
      printf '{"flag":{"name":"x","active":1,"updated_at":"2026-09-19T01:00:00Z"}}\n200\n' ;;
  "GET "*/api/flags/*)
      NAME="${URL##*/}"
      if [ "$NAME" = "${ROW_FLAG:-}" ]; then
        printf '{"flag":{"name":"%s","active":%s,"updated_at":"%s"}}\n200\n' \
          "$NAME" "${ROW_ACTIVE:-1}" "${ROW_UPDATED:-2026-09-19T01:00:00Z}"
      else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
SHIM
chmod +x "$T/fakebin/curl"

FIX="$T/fix"; mkdir -p "$FIX"
# 41: a plain PR (no label, a bin/ diff). 42: labelled fix-main-red.
# 43: a test-only diff. 44: labelled fix-main-red-later (NOT the label).
# 45: tests/ + bin/ (NOT test-only). 46: an unreadable file list.
printf '%s\tqa,ai-build\n' "$H1" > "$FIX/labels-41"; printf 'bin/x.sh\n'            > "$FIX/files-41"
printf '%s\tai-build,fix-main-red\n' "$H1" > "$FIX/labels-42"; printf 'bin/x.sh\n'  > "$FIX/files-42"
printf '%s\t\n' "$H1" > "$FIX/labels-43";           printf 'tests/x-test.sh\n'      > "$FIX/files-43"
printf '%s\tfix-main-red-later\n' "$H1" > "$FIX/labels-44"; printf 'bin/x.sh\n'     > "$FIX/files-44"
printf '%s\t\n' "$H1" > "$FIX/labels-45"; printf 'tests/a-test.sh\nbin/b.sh\n'      > "$FIX/files-45"
printf '%s\t\n' "$H1" > "$FIX/labels-46"; : > "$FIX/files-46"

GH_SINK="$T/gh-calls.txt"; GH_MERGES="$T/gh-merges.txt"; REQ_SINK="$T/req.log"
BEAT_SINK="$T/beats.txt"
export FIX GH_SINK GH_MERGES REQ_SINK BEAT_SINK
reset_sinks() { : > "$GH_SINK"; : > "$GH_MERGES"; : > "$REQ_SINK"; : > "$BEAT_SINK"; }
flag_up()   { : > "$T/h/flags/$1"; }
flag_down() { rm -f "$T/h/flags"/main-red-*; }

Q="$T/h/state/merge-queue/$PROJECT"; mkdir -p "$Q"
MQLOG="$T/h/logs/merge-queue.log"

# mq <pr> [curl-mode] [row-flag] [row-active] — bin/merge-queue.sh, WHOLE, with
# exactly one entry queued, so the serial landing path is the one under test.
mq() {
  reset_sinks
  rm -f "$Q"/*; : > "$Q/$1"; : > "$MQLOG"
  rm -rf "$T/h/state/merge-conductor"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" \
      CURL_MODE="${2:-ok}" ROW_FLAG="${3:-}" ROW_ACTIVE="${4:-1}" \
      bash "$T/h/bin/merge-queue.sh" "$PROJECT" >/dev/null 2>"$T/mq.err" ) || true
}
merged()  { grep -q "pr merge $1 " "$GH_MERGES"; }

# ============================================================================
# Q. bin/merge-queue.sh, run WHOLE — the box lane the ticket names first.
# ============================================================================
flag_down; flag_up "$FLAGNAME"
mq 41
merged 41 && bad "Q/queue-plain-held: THE DEFECT — the box queue merged #41 into a red main ($(cat "$GH_MERGES"))" || ok
grep -q "#41 HELD by the main-red freeze" "$MQLOG" \
  && ok || bad "Q/queue-plain-held: the queue must log one HELD line (log: $(cat "$MQLOG"), err: $(cat "$T/mq.err"))"
grep -qF "flags/$FLAGNAME" "$MQLOG" \
  && ok || bad "Q/queue-plain-held: the HELD line must name the flag (log: $(cat "$MQLOG"))"
[ -f "$Q/41" ] && ok || bad "Q/queue-plain-held: the entry must stay queued — it lands when the flag clears"
[ -f "$Q/41.blocked" ] && bad "Q/queue-plain-held: a freeze hold must not park the entry .blocked" || ok
[ -s "$BEAT_SINK" ] && bad "Q/queue-plain-held: a held entry pages nobody ($(cat "$BEAT_SINK"))" || ok

mq 42
merged 42 && ok || bad "Q/queue-label-exempt: a PR labelled fix-main-red must still land from a box (log: $(cat "$MQLOG"), err: $(cat "$T/mq.err"))"

mq 43
merged 43 && ok || bad "Q/queue-test-only-exempt: a test-only diff must still land from a box (log: $(cat "$MQLOG"))"

# The freeze costs NOTHING when main is green: no flag, no extra GitHub read.
flag_down
mq 41
merged 41 && ok || bad "Q/queue-green-lands: with no flag the queue must land exactly as before (log: $(cat "$MQLOG"), err: $(cat "$T/mq.err"))"
grep -q 'headRefOid,labels' "$GH_SINK" \
  && bad "Q/queue-green-costs-nothing: a green main must not buy a labels read ($(cat "$GH_SINK"))" || ok

# ============================================================================
# Q2. THE BOX CASE: no local flag file at all, the coordination row says active.
#     This is the half the detector never published.
# ============================================================================
flag_down
mq 41 ok "$FLAGNAME" 1
merged 41 && bad "Q2/queue-row-held: a box with no local file merged through a freeze the DB knows about ($(cat "$GH_MERGES"))" || ok
grep -q "#41 HELD by the main-red freeze" "$MQLOG" \
  && ok || bad "Q2/queue-row-held: the queue must hold on the published row (log: $(cat "$MQLOG"))"
[ -f "$T/h/flags/$FLAGNAME" ] \
  && ok || bad "Q2/queue-row-materialised: the row must materialise the flag file on the box"

# ============================================================================
# Q3. Fail-OPEN on the flag read: an unreachable worker never invents a freeze.
# ============================================================================
flag_down
mq 41 ok "" 1
merged 41 && ok || bad "Q3/queue-no-row-lands: a 404 (no row) and no file is not a freeze (log: $(cat "$MQLOG"))"

flag_down
mq 41 down "" 1
merged 41 && ok || bad "Q3/queue-worker-down-lands: an outage with no local file must not stop a merge (log: $(cat "$MQLOG"))"

# A STALE local file whose newer row says inactive is cleared by the first read.
# Stale means OLDER than the row (2026-09-19T01:00Z): under last-writer-wins on
# mtime (BH-1370) a file touched now would rightly outrank that row.
flag_down; flag_up "$FLAGNAME"; touch -d 2026-09-18T00:00:00Z "$T/h/flags/$FLAGNAME"
mq 41 ok "$FLAGNAME" 0
merged 41 && ok || bad "Q3/queue-row-off-clears: a newer inactive row must clear a stale flag and land (log: $(cat "$MQLOG"))"
[ -f "$T/h/flags/$FLAGNAME" ] && bad "Q3/queue-row-off-clears: the stale flag file must be gone" || ok

# ============================================================================
# Q4. The merge train's two call sites: a member held by the freeze never enters
#     the union, and one held between assembly and landing is not merged either.
# ============================================================================
awk '/^# >>> main-red gate/{f=1;next} /^# <<< main-red gate/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/qmr.sh"
[ -s "$T/qmr.sh" ] && ok || bad "Q4: could not extract the queue's main-red wrapper — markers missing in bin/merge-queue.sh"
awk '/^    # >>> head-bound train members/{f=1;next} /^    # <<< head-bound train members/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/train.sh"
awk '/^        # >>> train landing/{f=1;next} /^        # <<< train landing/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/land.sh"
# mq_land is the queue's own landing call (BH-892), lifted by ITS markers for the
# same reason bg_queue_hold is: the landing loop under test calls it by name.
# With no bin/lib/gh-pr-merge.sh in this fixture it is today's `gh pr merge`
# line, which is what the fake gh records and this lane asserts on.
awk '/^# >>> mq_land/{f=1;next} /^# <<< mq_land/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/mqland.sh"
[ -s "$T/mqland.sh" ] && ok || bad "Q4: could not extract mq_land from bin/merge-queue.sh"
# mq_pr is the queue's ONE read and the slice below calls it by name (BH-784:
# it is mc_pr_view over bin/lib/gh-rest.sh, not a `gh pr view` line any more),
# so it is lifted from the same script rather than retyped, and the conductor
# lib it resolves through is sourced in the arm.
grep '^mq_pr() {' "$DIR/bin/merge-queue.sh" > "$T/mqpr.sh"
[ -s "$T/mqpr.sh" ] && ok || bad "Q4: could not extract mq_pr from bin/merge-queue.sh"
: > "$T/train.log"; : > "$GH_MERGES"
BATCH_OUT=$( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SLUG="$SLUG" PROJECT="$PROJECT" \
  LOG="$T/train.log" WT="$T" QUEUED="41 43" \
  bash -c 'set -uo pipefail
    . "$HARNESS/bin/lib/merge-conductor-lib.sh"
    . "'"$T"'/mqpr.sh"
    STAMP() { printf TS; }
    bh_held()    { return 1; }
    hb_blocked() { return 1; }
    bg_queue_hold() { return 1; }
    dep_queue_hold() { return 1; }
    main_red_queue_hold() { [ "$1" = 41 ] && { MRG_FLAG="'"$FLAGNAME"'"; return 0; }; return 1; }
    . "'"$T"'/qmr.sh"
    BATCH=""
    . "$0"
    printf "BATCH=[%s]" "$BATCH"' "$T/train.sh" 2>"$T/train.err" )
grep -q 'BATCH=\[ 43\]' <<<"$BATCH_OUT" \
  && ok || bad "Q4/train-member-held: a frozen member must not enter the union (got $BATCH_OUT, stderr: $(cat "$T/train.err"))"
grep -q "#41 HELD by the main-red freeze" "$T/train.log" \
  && ok || bad "Q4/train-member-held: the log must name the held member (log: $(cat "$T/train.log"))"

: > "$GH_MERGES"; : > "$T/land.log"
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SLUG="$SLUG" PROJECT="$PROJECT" \
  LOG="$T/land.log" Q="$Q" BATCH="41 43" \
  bash -c 'set -uo pipefail
    STAMP() { printf TS; }
    MQROW() { :; }
    bg_queue_hold() { return 1; }
    dep_queue_hold() { return 1; }
    main_red_queue_hold() { [ "$1" = 41 ] && { MRG_FLAG="'"$FLAGNAME"'"; return 0; }; return 1; }
    LANDED=0; LAST_SHA=""
    . "'"$T"'/qmr.sh"
    . "'"$T"'/mqland.sh"
    . "$0"' "$T/land.sh" >/dev/null 2>"$T/land.err" ) || true
merged 41 && bad "Q4/train-landing-held: a member frozen between assembly and landing must not be merged ($(cat "$GH_MERGES"))" || ok
merged 43 && ok || bad "Q4/train-landing-held: the rest of the train must still land ($(cat "$GH_MERGES"), stderr: $(cat "$T/land.err"))"

# BH-1366: section T ran bin/tier2-merge-sweep.sh WHOLE and pinned that a PR
# frozen by the main-red flag was never enqueued. That lane is retired. The
# freeze is enforced on the CONSUMER instead — mr_queue_hold in
# bin/merge-queue.sh, sections Q and Q4 above — which is where it has to be
# now that a don't-enqueue is permanent rather than re-offered every ten
# minutes. Section R below still covers the reviewer lane.

# ============================================================================
# R. bin/review-prs.sh's merge step — the lane that merged #931 and #942.
# ============================================================================
awk '/^# >>> review-prs merge/{f=1;next} /^# <<< review-prs merge/{exit} f' \
  "$DIR/bin/review-prs.sh" > "$T/rp.sh"
[ -s "$T/rp.sh" ] && ok || bad "R: could not extract the review-prs merge block — markers missing?"
RPLOG="$T/rp.log"
rp() { # rp <pr>
  reset_sinks; : > "$RPLOG"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SLUG="$SLUG" PROJECT="$PROJECT" \
      LOG="$RPLOG" \
      bash -c 'set -uo pipefail
        STAMP() { printf TS; }
        rp_prov_is_claude() { return 0; }
        mc_queue_conductor_only() { return 1; }
        mc_pr_queued() { return 1; }
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        . "$0"
        MERGED=
        merge_step "$1" "aaaaaaaa1111" claude
        printf "MERGED=%s\n" "$MERGED"' "$T/rp.sh" "$1" 2>"$T/rp.err" )
}
flag_down; flag_up "$FLAGNAME"
OUT=$(rp 41)
merged 41 && bad "R/review-held: THE DEFECT — the reviewer merged an APPROVE into a red main ($(cat "$GH_MERGES"))" || ok
grep -q "MERGED=no" <<<"$OUT" && ok || bad "R/review-held: a held merge is MERGED=no (got '$OUT', stderr: $(cat "$T/rp.err"))"
grep -q "#41 APPROVE left unmerged, HELD by the main-red freeze" "$RPLOG" \
  && ok || bad "R/review-held: the reviewer must log one HELD line (log: $(cat "$RPLOG"))"
OUT=$(rp 42)
merged 42 && ok || bad "R/review-label-exempt: a fix-main-red APPROVE must still merge (got '$OUT', stderr: $(cat "$T/rp.err"))"

# R2. The approved-head retry does not SPEND its budget on the freeze. Seven
#     ticks under the flag: no merge, no ALERT, merge_retries still 0 — so the
#     APPROVE is still retried when main goes green, instead of the lane having
#     alerted "needs a look" and stopped after six frozen ticks.
awk '/^# >>> review-prs merge-retry/{f=1;next} /^# <<< review-prs merge-retry/{exit} f' \
  "$DIR/bin/review-prs.sh" > "$T/rpr.sh"
[ -s "$T/rpr.sh" ] && ok || bad "R2: could not extract the review-prs merge-retry block — markers missing?"
RPSTATE="$T/rp-state.json"
printf '{"41":{"verdict":"APPROVE","served":"claude","merge_retries":0}}\n' > "$RPSTATE"
: > "$T/h/logs/ALERTS.log"
rpr() { # rpr <pr> <ticks>
  reset_sinks; : > "$RPLOG"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SLUG="$SLUG" PROJECT="$PROJECT" \
      LOG="$RPLOG" STATE="$RPSTATE" \
      bash -c 'set -uo pipefail
        STAMP() { printf TS; }
        rp_prov_is_claude() { return 0; }
        mc_queue_conductor_only() { return 1; }
        mc_pr_queued() { return 1; }
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        . "$1"
        . "$0"
        i=0; while [ "$i" -lt "$3" ]; do MERGED=; merge_retry "$2" "aaaaaaaa1111"; i=$((i+1)); done' \
        "$T/rpr.sh" "$T/rp.sh" "$1" "$2" 2>"$T/rpr.err" )
}
flag_down; flag_up "$FLAGNAME"
rpr 41 7
merged 41 && bad "R2/retry-held: the approved-head retry merged into a red main ($(cat "$GH_MERGES"))" || ok
[ -s "$T/h/logs/ALERTS.log" ] && bad "R2/retry-held: a frozen tick is not a failed attempt — no ALERT ($(cat "$T/h/logs/ALERTS.log"))" || ok
[ "$(jq -r '.["41"].merge_retries' "$RPSTATE")" = 0 ] \
  && ok || bad "R2/retry-held: merge_retries must stay 0 under the freeze (state: $(cat "$RPSTATE"), stderr: $(cat "$T/rpr.err"))"
flag_down
rpr 41 1
merged 41 && ok || bad "R2/retry-green: with the flag gone the same APPROVE is retried and merges (stderr: $(cat "$T/rpr.err"), log: $(cat "$RPLOG"))"

# ============================================================================
# S. bin/merge-sweep.sh (hub) — the gate block extracted by its markers.
# ============================================================================
awk '/^  # >>> main-red gate/{f=1;next} /^  # <<< main-red gate/{exit} f' \
  "$DIR/bin/merge-sweep.sh" > "$T/sw.sh"
[ -s "$T/sw.sh" ] && ok || bad "S: could not extract the sweep's main-red gate — markers missing in bin/merge-sweep.sh"
SWLOG="$T/sweep.log"
sweep() { # sweep <pr>
  reset_sinks; : > "$SWLOG"; : > "$T/claims.txt"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" H="$T/h" \
      PA_SLUG="$SLUG" PA_NUM="$1" PROJECT="$PROJECT" PHEAD="" LOG="$SWLOG" CSINK="$T/claims.txt" \
      bash -c 'set -uo pipefail
        STAMP() { printf TS; }
        sweep_claim()  { printf "claim\n"  >> "$CSINK"; }
        sweep_record() { printf "record\n" >> "$CSINK"; }
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        for PR in "https://github.com/'"$SLUG"'/pull/'"$1"'"; do
          . "$0"
          sweep_claim
          printf "FELL_THROUGH\n"
        done' "$T/sw.sh" 2>"$T/sweep.err" )
}
flag_down; flag_up "$FLAGNAME"
OUT=$(sweep 41)
grep -q FELL_THROUGH <<<"$OUT" && bad "S/sweep-held: the hub sweep fell through to the merge on a red main" || ok
grep -q "HELD by the main-red freeze" "$SWLOG" \
  && ok || bad "S/sweep-held: the sweep must log the hold (log: $(cat "$SWLOG"), stderr: $(cat "$T/sweep.err"))"
[ -s "$T/claims.txt" ] && bad "S/sweep-held: a held PR is neither claimed nor ledgered ($(cat "$T/claims.txt"))" || ok
OUT=$(sweep 42)
grep -q FELL_THROUGH <<<"$OUT" && ok || bad "S/sweep-label-exempt: a fix-main-red PR must reach sweep_claim (stderr: $(cat "$T/sweep.err"))"
flag_down
OUT=$(sweep 41)
grep -q FELL_THROUGH <<<"$OUT" && ok || bad "S/sweep-green-passes: with no flag the gate must fall through (stderr: $(cat "$T/sweep.err"))"
[ -s "$SWLOG" ] && bad "S/sweep-green-passes: a pass says nothing ($(cat "$SWLOG"))" || ok
# S2. A hand-raised flag in the PROJECT spelling holds the hub sweep too: the
#     project is resolved from fleet.conf for this PR's slug, not passed empty.
flag_down; flag_up "$PFLAGNAME"
OUT=$(sweep 41)
grep -q FELL_THROUGH <<<"$OUT" && bad "S2/sweep-project-spelling: flags/$PFLAGNAME must hold the hub sweep (stderr: $(cat "$T/sweep.err"))" || ok
grep -q "flags/$PFLAGNAME" "$SWLOG" && ok || bad "S2/sweep-project-spelling: the hold line names the flag in force (log: $(cat "$SWLOG"))"
flag_down

# ============================================================================
# G. bin/run-build.sh's tier-1 merge gate, extracted and driven.
# ============================================================================
awk '/^# >>> tier-1 merge gate/{f=1;next} /^# <<< tier-1 merge gate/{exit} f' \
  "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "G: could not extract the tier-1 merge gate — markers missing?"
run_gate() { # run_gate <pr> ; prints the RESULT line
  reset_sinks
  rm -f "$T/RESULT"; mkdir -p "$T/h/builds/gate"
  printf 'VERDICT: APPROVE\n' > "$T/h/builds/gate/review.md"; printf 'plan\n' > "$T/h/builds/gate/plan.md"
  : > "$T/h/builds/gate/pipeline.log"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD="$T/h/builds/gate" ALERTS="$T/h/logs/ALERTS.log" \
      PROJECT="$PROJECT" KEY=BH-1 SLUG="$SLUG" TIER=1 PR_URL="https://github.com/$SLUG/pull/$1" \
      QA_NOTE="" MIG_NOTE="" REBASE_NOTE="" CLOSES_LINE="Closes #$1" HEADBOUND_SHA="$H1" \
      BUILDER_NO_MERGE= \
      bash -c 'set -uo pipefail
        STAMP() { printf TS; }
        RESULT() { echo "$*" > '"$T"'/RESULT; }
        BB() { :; }
        CLOSE_ISSUE_AFTER_MERGE() { :; }
        mc_queue_conductor_only() { return 1; }
        mc_pr_queued() { return 1; }
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        . "$0"' "$T/gate.sh" >/dev/null 2>"$T/gate.err" ) || true
  cat "$T/RESULT" 2>/dev/null
}
flag_down; flag_up "$FLAGNAME"
OUT=$(run_gate 41)
merged 41 && bad "G/tier1-held: THE DEFECT — a tier-1 build merged its own PR into a red main ($(cat "$GH_MERGES"))" || ok
grep -q "^PR_CREATED https://github.com/$SLUG/pull/41" <<<"$OUT" \
  && ok || bad "G/tier1-held: a held tier-1 build exits through PR_CREATED (got '$OUT', stderr: $(cat "$T/gate.err"))"
grep -q "tier-1 merge HELD by the main-red freeze" "$T/h/builds/gate/pipeline.log" \
  && ok || bad "G/tier1-held: the build log must say why (log: $(cat "$T/h/builds/gate/pipeline.log"))"
OUT=$(run_gate 42)
merged 42 && ok || bad "G/tier1-label-exempt: a fix-main-red build must merge as before (got '$OUT', stderr: $(cat "$T/gate.err"))"

# ============================================================================
# B. bin/batch-resolve.sh — no NEW train is built while main is red.
# ============================================================================
BRLOG="$T/h/logs/batch-resolve.log"
# Its OWN gh sink: run-build's tier-1 path above leaves a detached merge-queue
# behind on the base tree, and a shared sink would read that lane's calls as
# this one's.
BRGH="$T/gh-batch.txt"
br() { # br [BATCH_RESOLVE value] [BATCH_MAIN_RED_CLEAR value]
  : > "$BRLOG"; : > "$BRGH"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" BATCH_RESOLVE="${1:-1}" \
      BATCH_MAIN_RED_CLEAR="${2:-1}" \
      GH_SINK="$BRGH" \
      bash "$T/h/bin/batch-resolve.sh" "$PROJECT" >/dev/null 2>"$T/br.err" ) || true
}
flag_down; flag_up "$FLAGNAME"
br
grep -qF "flags/$FLAGNAME" "$BRLOG" \
  && ok || bad "B/batch-held: batch-resolve must refuse to build a train into a red main (log: $(cat "$BRLOG"), err: $(cat "$T/br.err"))"
grep -q "nothing to do" "$BRLOG" \
  && ok || bad "B/batch-held: the refusal is the script's own GATED line (log: $(cat "$BRLOG"))"
# THE ZERO-CALL PROPERTY, NOW UNDER A KNOB (BH-1269, and this is the only line
# of this suite that ticket changed).
#
# What BH-945 defends is that a freeze stops this lane BEFORE it spends
# anything: no token probe, no clone, no fetch, no union typecheck, and above
# all nothing WRITTEN. BH-1269 gave the lane exactly one bounded READ while a
# freeze is on — "has a PR carrying the fix label merged since the flag went up,
# and did its merge-ref run conclude green" — because that read is the only way
# a freeze can END without waiting for bin/main-red-detector.sh's next pass over
# main, a wait that cost ~20 minutes per red episode on 2026-09-21. A lane that
# may never ask cannot answer it.
#
# So the property splits in two, and BOTH are asserted rather than one being
# relaxed: with the lift OFF the behaviour is BH-945's, byte for byte; with it
# on, every call the freeze buys is a READ on the fix-probe endpoints and
# nothing at all is written.
BRBAD=$(grep -vE '^api -i -X GET repos/[^ ]+/(pulls|commits/[0-9a-f]+/check-runs|actions/runs)( |$)' "$BRGH" | head -3)
[ -z "$BRBAD" ] \
  && ok || bad "B/batch-held: under a freeze the lane may make ONLY the fix-PR probe READS, got: $BRBAD"
grep -qE '^api -i -X (POST|PATCH|PUT|DELETE)|^pr (create|merge|comment)|^api -X' "$BRGH" \
  && bad "B/batch-held: a freeze must buy no WRITE of any kind ($(cat "$BRGH"))" || ok
br 1 0
grep -qF "flags/$FLAGNAME" "$BRLOG" \
  && ok || bad "B/batch-held-noclear: the refusal is unchanged with the lift off (log: $(cat "$BRLOG"))"
[ -s "$BRGH" ] && bad "B/batch-held-noclear: with BATCH_MAIN_RED_CLEAR=0 the gate sits before the token probe — no GitHub call at all ($(cat "$BRGH"))" || ok
# With main green the main-red gate must not be the reason anything stops.
flag_down
br 0
grep -q "BATCH_RESOLVE=0 — nothing to do" "$BRLOG" \
  && ok || bad "B/batch-green: with no flag the gate must be silent (log: $(cat "$BRLOG"))"

# ============================================================================
# N. The exemption negatives. The gate gates an irreversible merge, so every
#    near-miss must FAIL to exempt, and a flag for another repo must not hold.
# ============================================================================
flag_down
if [ -r "$T/h/bin/lib/main-red-gate.sh" ]; then
  n_hold() { # n_hold <pr> [flagname] ; prints HOLD or PASS
    ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" \
        bash -c 'set -uo pipefail
          . "$HARNESS/bin/lib/merge-conductor-lib.sh"
          [ -n "$2" ] && : > "$HARNESS/flags/$2"
          if main_red_hold "'"$PROJECT"'" "'"$SLUG"'" "$1" "https://github.com/'"$SLUG"'/pull/$1"; then
            printf "HOLD %s\n" "${MRG_FLAG:-}"
          else printf "PASS %s\n" "${MRG_FLAG:-}"; fi' bash "$1" "${2:-}" 2>/dev/null )
    rm -f "$T/h/flags"/main-red-*
  }
  [ "$(n_hold 41 "$FLAGNAME")" = "HOLD $FLAGNAME" ] && ok || bad "N/slug-spelling: the owner-repo flag must hold (got '$(n_hold 41 "$FLAGNAME")')"
  [ "$(n_hold 41 "$PFLAGNAME")" = "HOLD $PFLAGNAME" ] && ok || bad "N/project-spelling: a hand-raised flags/$PFLAGNAME must hold too"
  case "$(n_hold 41 "$OTHERFLAG")" in PASS*) ok ;; *) bad "N/other-repo: a flag for another repo must not freeze this one" ;; esac
  case "$(n_hold 42 "$FLAGNAME")" in PASS*) ok ;; *) bad "N/label-exempt: fix-main-red must exempt" ;; esac
  case "$(n_hold 43 "$FLAGNAME")" in PASS*) ok ;; *) bad "N/test-only-exempt: a whole-diff-of-tests PR must exempt" ;; esac
  case "$(n_hold 44 "$FLAGNAME")" in HOLD*) ok ;; *) bad "N/label-prefix: 'fix-main-red-later' is not the label and must NOT exempt" ;; esac
  case "$(n_hold 45 "$FLAGNAME")" in HOLD*) ok ;; *) bad "N/mixed-diff: tests/a-test.sh PLUS bin/b.sh is not test-only" ;; esac
  case "$(n_hold 46 "$FLAGNAME")" in HOLD*) ok ;; *) bad "N/unreadable-diff: a file list nobody can read is NOT exempt — fail closed" ;; esac
  case "$(n_hold 41 "")" in PASS*) ok ;; *) bad "N/no-flag: nothing red must never hold" ;; esac
else
  bad "N: bin/lib/main-red-gate.sh does not exist — the freeze has no shared implementation, so no lane but the conductor can read it"
fi

# ============================================================================
# D. bin/main-red-detector.sh PUBLISHES the flag, so a box can see it at all.
# ============================================================================
mkdir -p "$T/d/bin/lib" "$T/d/logs" "$T/d/flags" "$T/d/locks" "$T/d/env" "$T/d/state"
cp "$DIR/bin/main-red-detector.sh" "$DIR/bin/jobs-client.sh" "$T/d/bin/"
mkdir -p "$T/d/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/d/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$T/d/bin/lib/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$T/d/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/d/bin/lane-alert.sh"; chmod +x "$T/d/bin/lane-alert.sh"
CI=".github/workflows/harness-ci.yml"
runs() { # runs <name|path|conclusion|created_at|sha[|status]>...
  local out='{"workflow_runs":[' first=1 spec n p c t s sha
  for spec in "$@"; do
    IFS='|' read -r n p c t sha s <<<"$spec"; s=${s:-completed}
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg n "$n" --arg p "$p" --arg s "$s" --arg t "$t" --arg sha "$sha" --arg c "$c" \
      --arg u "https://github.com/o/r/actions/runs/${t//[^0-9]/}" \
      '{name:$n, path:$p, status:$s, conclusion:$c, created_at:$t, head_sha:$sha, html_url:$u,
        id:($t|gsub("[^0-9]";"")|tonumber)}')
  done
  printf '%s]}' "$out" > "$FIX/runs.json"
}
detect() { # detect [curl-mode]
  : > "$REQ_SINK"; : > "$GH_SINK"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/d" CURL_MODE="${1:-ok}" \
      bash "$T/d/bin/main-red-detector.sh" o/r >/dev/null 2>"$T/det.err" ) || true
}
puts() { awk '/PUT .*\/api\/flags /{n++} END{print n+0}' "$REQ_SINK" 2>/dev/null; }
DFLAG="$T/d/flags/main-red-o-r"

# D1. main goes red: the file is written AND the row is published.
runs "Harness CI|$CI|failure|2026-09-18T20:41:00Z|aaaa111" \
     "Harness CI|$CI|failure|2026-09-18T20:10:00Z|cccc333" \
     "Harness CI|$CI|success|2026-09-18T19:00:00Z|dddd444"
detect
[ -f "$DFLAG" ] && ok || bad "D1: the detector did not write the flag file (err: $(cat "$T/det.err"))"
grep -q '^sha=aaaa111$' "$DFLAG" 2>/dev/null \
  && ok || bad "D1: publishing must not clobber the flag BODY the conductor reads ($(cat "$DFLAG" 2>/dev/null))"
grep -q 'PUT .*/api/flags .*"name":"main-red-o-r".*"active":1' "$REQ_SINK" \
  && ok || bad "D1: THE DEFECT — no pause_flags row is published, so no box can ever see the freeze (requests: $(cat "$REQ_SINK"))"

# D2. still red on the SAME sha: the republish is what makes a missed PUT
#     self-heal, so the row is written again even though nothing else is.
detect
grep -q 'PUT .*/api/flags .*"active":1' "$REQ_SINK" \
  && ok || bad "D2: a still-red tick must republish the row (requests: $(cat "$REQ_SINK"))"

# D3. a read that FAILS publishes nothing and changes nothing.
rm -f "$FIX/runs.json"
detect
[ "$(puts)" = 0 ] && ok || bad "D3: a failed runs read must publish nothing (requests: $(cat "$REQ_SINK"))"
[ -f "$DFLAG" ] && ok || bad "D3: a failed read must leave the flag alone"

# D4. green again: the row is published OFF and the file is gone.
runs "Harness CI|$CI|success|2026-09-18T23:10:00Z|eeee555" \
     "Harness CI|$CI|failure|2026-09-18T20:41:00Z|aaaa111"
detect
[ -f "$DFLAG" ] && bad "D4: a green main must clear the flag file" || ok
grep -q 'PUT .*/api/flags .*"name":"main-red-o-r".*"active":0' "$REQ_SINK" \
  && ok || bad "D4: a green main must publish the row OFF, or every box stays frozen for ever (requests: $(cat "$REQ_SINK"))"
DMARK="$T/d/state/main-red/main-red-o-r.published"
[ -f "$DMARK" ] && bad "D4: a landed OFF PUT clears the published marker" || ok

# D5. The OFF side self-heals. Red again (the row is published ON), then green
#     while the worker is DOWN: the file goes, the OFF PUT dies. The next green
#     tick has no flag file to prompt it and used to publish nothing, leaving
#     every box frozen for ever. Now the marker prompts it: it publishes
#     active:0, and once that lands the tick after publishes nothing.
runs "Harness CI|$CI|failure|2026-09-19T01:41:00Z|ffff666" \
     "Harness CI|$CI|failure|2026-09-19T01:10:00Z|9999777" \
     "Harness CI|$CI|success|2026-09-18T23:10:00Z|eeee555"
detect
[ -f "$DFLAG" ] && [ -f "$DMARK" ] && ok || bad "D5: red again must write the file and the published marker (err: $(cat "$T/det.err"))"
runs "Harness CI|$CI|success|2026-09-19T02:10:00Z|1111888" \
     "Harness CI|$CI|failure|2026-09-19T01:41:00Z|ffff666"
detect down
[ -f "$DFLAG" ] && bad "D5: a green main clears the flag file even when the PUT dies" || ok
[ -f "$DMARK" ] && ok || bad "D5: a dead OFF PUT must leave the published marker, or nothing ever republishes"
detect
grep -q 'PUT .*/api/flags .*"name":"main-red-o-r".*"active":0' "$REQ_SINK" \
  && ok || bad "D5: THE HOLE — the green tick after a dead OFF PUT must publish active:0 (requests: $(cat "$REQ_SINK"), err: $(cat "$T/det.err"))"
[ -f "$DMARK" ] && bad "D5: a landed OFF PUT clears the marker" || ok
detect
[ "$(puts)" = 0 ] && ok || bad "D5: once the OFF landed, a green tick publishes nothing (requests: $(cat "$REQ_SINK"))"

echo "main-red-box-freeze.bh-945: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
