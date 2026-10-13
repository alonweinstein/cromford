#!/bin/bash
# tests/merge-queue-enqueue-on-verdict.bh-1366-test.sh — THE MERGE QUEUE IS FED
# AT THE VERDICT, NOT BY A SWEEP, AND THE QUEUE ITSELF CAN BE ROWS.
#
# WHAT BH-1026.2 MOVED. bin/tier2-merge-sweep.sh ran six times an hour on eight
# boxes, re-grepping every directory under builds/ for a `VERDICT: APPROVE` it
# had already read, to decide something the build itself knew the moment the
# review settled. The enqueue now happens where the judgement is made — the two
# marked verdict blocks of bin/run-build.sh and the two of bin/review-prs.sh —
# and the sweep is retired in the same change. That makes a missed enqueue
# PERMANENT (nothing re-offers the PR any more), which is why every negative
# below carries as much weight as the happy path.
#
# WHY DRIVEN AND NOT GREPPED (D2/D3). The four verdict blocks are EXTRACTED from
# the production scripts by their own `# >>>` / `# <<<` markers and executed,
# against the real bin/jobs-client.sh talking to a file-backed fake worker;
# bin/merge-queue.sh is run WHOLE against a scratch $HARNESS. Every assertion is
# about a request the fake worker recorded or a file on disk. Nothing here reads
# the source text of a script to decide whether it passes — except §A7, which
# MUTATES the gate on purpose and requires the suite to go red.
#
# THE ADVERSARIAL NEGATIVE THIS EXISTS FOR. The gate is an irreversible action's
# classifier: "is this an APPROVE" decides whether a PR joins a merge queue.
# bin/run-build.sh's own prompt strings contain the literal sentence
# `Last line exactly VERDICT: APPROVE or VERDICT: BLOCK`, so a gate that greps
# review.md enqueues a BLOCKED build. §A3 feeds every one of those real prompt
# lines as a review body whose last line is `VERDICT: BLOCK`, and §A7 proves the
# fixture has teeth by pointing the gate at the text and watching it post.
#
# Run from anywhere: bash tests/merge-queue-enqueue-on-verdict.bh-1366-test.sh
# (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
# ONE clock read for the whole file (bin/test-determinism-lint.sh). Nothing here
# compares times; it only keeps fixture directory names unique.
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive these blocks"; exit 1; }
# A real credential in the runner's environment must never reach a fixture.
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR JOB_ID JOB_PHASE_ID

PROJECT=demo-os
SLUG=example-org/demo-os
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }

# ── the scratch harness ──────────────────────────────────────────────────────
mkdir -p "$T/h/bin/lib/jobs" "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/flags" "$T/h/locks" \
         "$T/h/env" "$T/h/builds" "$T/h/state/merge-queue/$PROJECT" "$T/fakebin" "$T/rows"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" \
   "$DIR/bin/lib/gh-pr-merge.sh" "$DIR/bin/lib/env-path.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf '%s %s - - 2 box-demo\n' "$PROJECT" "$SLUG" > "$T/h/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for S in beat.sh deploy-request.sh merge-queue.sh lander.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$S"; chmod +x "$T/h/bin/$S"
done

# THE FLAG THE CONTRACT SLICE OWNS. `merge_queue_rows_only_on` is defined by
# BH-1364's bin/lib/jobs/queue.sh; this branch is cut from main, so the scratch
# client defines it here and the cases flip it through a file. Production reads
# it through `command -v` for exactly this reason: with the contract absent the
# function does not exist and bin/merge-queue.sh behaves byte for byte as today
# — which is what §C4 pins.
cat >> "$T/h/bin/jobs-client.sh" <<'STUBEOF'
merge_queue_rows_only_on() { [ -f "${HARNESS:-/root/harness}/flags/merge-queue-rows-only" ]; }
STUBEOF

ROWS="$T/rows"
rows_reset() { rm -f "$ROWS"/*; }
row_set() { printf '%s\n' "$2" > "$ROWS/$1"; }
row_of()  { cat "$ROWS/$1" 2>/dev/null || echo none; }

# ── the fake worker ──────────────────────────────────────────────────────────
# File-backed, so a POST and the GET after it agree. Records every request to
# $REQ_SINK as "<METHOD> <URL> <BODY>" — that file is what every assertion here
# reads.
cat > "$T/fakebin/curl" <<'CURLEOF'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
[ "${CURL_MODE:-ok}" = down ] && exit 7
PATHONLY="${URL%%\?*}"
case "$M ${PATHONLY##*jobs.invalid}" in
  "POST /api/merge-queue")
    PR=$(printf '%s' "$BODY" | jq -r '.pr // empty' 2>/dev/null)
    if [ -f "$ROWS/$PR" ] && [ "$(cat "$ROWS/$PR")" = queued ]; then
      printf '{"merge":{"project":"demo-os","pr":%s,"status":"queued"},"duplicate":true}\n200\n' "$PR"
    else
      echo queued > "$ROWS/$PR"
      printf '{"merge":{"project":"demo-os","pr":%s,"status":"queued"},"duplicate":false}\n201\n' "$PR"
    fi ;;
  "PATCH /api/merge-queue")
    if [ "${MQSET_MODE:-ok}" = 404 ]; then printf '{"error":"not found"}\n404\n'; exit 0; fi
    PR=$(printf '%s' "$BODY" | jq -r '.pr // empty' 2>/dev/null)
    ST=$(printf '%s' "$BODY" | jq -r '.status // empty' 2>/dev/null)
    echo "$ST" > "$ROWS/$PR"
    printf '{"merge":{"project":"demo-os","pr":%s,"status":"%s"}}\n200\n' "$PR" "$ST" ;;
  "GET /api/merge-queue")
    WANT=$(printf '%s' "$URL" | sed -n 's/.*[?&]status=\([a-z]*\).*/\1/p')
    OUT="["; SEP=""
    for f in $(ls "$ROWS" 2>/dev/null | sort -n); do
      ST=$(cat "$ROWS/$f")
      [ -n "$WANT" ] && [ "$ST" != "$WANT" ] && continue
      OUT="$OUT$SEP$(jq -nc --argjson n "$f" --arg s "$ST" \
        '{project:"demo-os",pr:$n,status:$s,repo:"example-org/demo-os",enqueued_by:"box-a",enqueued_at:"2026-09-22T00:00:00Z",reason:"fixture"}')"
      SEP=","
    done
    printf '{"merge_queue":%s]}\n200\n' "$OUT" ;;
  "GET /api/verdict")
    printf '{"verdict":"APPROVE","tier":"2","provenance":"claude","reviewed_sha":"%s","artifacts":[]}\n200\n' \
      "${VERDICT_SHA:-deadbeefdeadbeef}" ;;
  *) case "$PATHONLY" in
       */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
       *)             printf '{"ok":true}\n200\n' ;;
     esac ;;
esac
CURLEOF
chmod +x "$T/fakebin/curl"

REQ="$T/req.txt"; : > "$REQ"
posts()   { grep -c "^POST https://jobs.invalid/api/merge-queue " "$REQ" 2>/dev/null || true; }
body_of() { grep -m1 "^$1 https://jobs.invalid$2 " "$REQ" | awk '{ $1=""; $2=""; sub(/^ +/, ""); print }'; }

jobsenv() { # the environment every driver shares
  export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
         JOBS_URL=https://jobs.invalid JOBS_BOX=box-demo JOBS_RETRIES=0 \
         REQ_SINK="$REQ" ROWS="$ROWS" FLEET_CONF="$T/h/fleet.conf"
}

# ═════════════════════════════════════════════════════════════════════════════
# §A — bin/run-build.sh's two verdict blocks, extracted and executed
# ═════════════════════════════════════════════════════════════════════════════
A1F="$T/rb-early.sh"; A2F="$T/rb-settle.sh"
marked '# >>> verdict at review' '# <<< verdict at review' "$RB" > "$A1F"
marked '# >>> verdict artifact'  '# <<< verdict artifact'  "$RB" > "$A2F"
[ -s "$A1F" ] && ok || bad "§A: bin/run-build.sh carries no '# >>> verdict at review' block"
[ -s "$A2F" ] && ok || bad "§A: bin/run-build.sh carries no '# >>> verdict artifact' block"

rb_run() { # rb_run <case> <script...> — sources each script in ONE process
  local case_id="$1"; shift
  B="$T/b-$case_id-$NOW"; scratch_rm "$B"; mkdir -p "$B"
  : > "$REQ"
  printf 'read the diff\n%s\n' "${RB_REVIEW:-VERDICT: APPROVE}" > "$B/review.md"
  [ -n "${RB_SECREVIEW:-}" ] && printf 'sec\n%s\n' "$RB_SECREVIEW" > "$B/security-review.md"
  ( jobsenv
    export BUILD="$B" PROJECT="$PROJECT" KEY=BH-1366 SLUG="$SLUG" \
           JOB_ID="${RB_JOB:-job-1}" TIER="${RB_TIER:-2}" PR_URL="${RB_PR-https://github.com/$SLUG/pull/7}" \
           CURL_MODE="${RB_CURL:-ok}" BUILDER_NO_MERGE="${RB_BNM:-}" SCRIPTS="$*"
    bash -c '
      STAMP() { printf "2026-09-22 14:10:00Z"; }
      job_artifact_put() { return 0; }
      rp_out_is_claude() { return 0; }
      rp_out_prov() { printf claude; }
      . "$HARNESS/bin/jobs-client.sh"
      for s in $SCRIPTS; do . "$s"; done' ) 2>"$T/rb.err"
}

# ── A1: a tier-2 APPROVE with a PR enqueues exactly once, by row ─────────────
rows_reset; RB_REVIEW="VERDICT: APPROVE" rb_run a1 "$A1F"
[ "$(posts)" = 1 ] && ok || bad "A1: a tier-2 APPROVE must POST exactly one merge-queue row, got $(posts) ($(cat "$T/rb.err"))"
[ "$(jq -r .pr <<<"$(body_of POST /api/merge-queue)")" = 7 ] \
  && ok || bad "A1: the row must name PR 7, got: $(body_of POST /api/merge-queue)"
[ "$(jq -r .project <<<"$(body_of POST /api/merge-queue)")" = "$PROJECT" ] \
  && ok || bad "A1: the row must name the project, got: $(body_of POST /api/merge-queue)"
grep -q 'APPROVE' <<<"$(jq -r .reason <<<"$(body_of POST /api/merge-queue)")" \
  && ok || bad "A1: the row must carry a reason a filename could not, got: $(body_of POST /api/merge-queue)"
[ ! -e "$T/h/state/merge-queue/$PROJECT/7" ] \
  && ok || bad "A1: a row that was accepted must not also leave a queue FILE behind"

# ── A2: VERDICT: BLOCK enqueues nothing ──────────────────────────────────────
rows_reset; RB_REVIEW="VERDICT: BLOCK" rb_run a2 "$A1F"
[ "$(posts)" = 0 ] && ok || bad "A2: a BLOCK verdict must enqueue nothing, got $(posts) POSTs"

# ── A3: the real prompt bodies, with a BLOCK last line ───────────────────────
# Every line of bin/run-build.sh that carries the literal instruction is fed as
# the review BODY. The last line is `VERDICT: BLOCK`, which is what the block's
# own reader answers on, so none of them may enqueue.
PROMPTN=0
while IFS= read -r PL; do
  PROMPTN=$((PROMPTN+1))
  rows_reset; : > "$REQ"
  B="$T/b-a3-$PROMPTN-$NOW"; scratch_rm "$B"; mkdir -p "$B"
  printf '%s\nVERDICT: BLOCK\n' "$PL" > "$B/review.md"
  ( jobsenv
    export BUILD="$B" PROJECT="$PROJECT" KEY=BH-1366 SLUG="$SLUG" JOB_ID=job-1 TIER=2 \
           PR_URL="https://github.com/$SLUG/pull/7"
    bash -c '
      STAMP() { printf "2026-09-22 14:10:00Z"; }
      job_artifact_put() { return 0; }
      rp_out_is_claude() { return 0; }
      rp_out_prov() { printf claude; }
      . "$HARNESS/bin/jobs-client.sh"
      . "'"$A1F"'"' ) 2>/dev/null
  [ "$(posts)" = 0 ] \
    || bad "A3/$PROMPTN: a review whose BODY quotes the prompt but whose last line is BLOCK enqueued: $PL"
done < <(grep -h 'Last line exactly VERDICT: APPROVE' "$RB")
[ "$PROMPTN" -gt 0 ] \
  && ok || bad "A3: bin/run-build.sh carries no 'Last line exactly VERDICT: APPROVE' prompt line — the fixture this negative is built on is gone"
ok

# ── A4: a security-only APPROVE never enqueues ───────────────────────────────
rows_reset; RB_REVIEW="VERDICT: BLOCK" RB_SECREVIEW="VERDICT: APPROVE" rb_run a4 "$A1F"
[ "$(posts)" = 0 ] && ok || bad "A4: an APPROVE in security-review.md must not enqueue — review.md is the word"

# ── A5: no PR number yet — nothing posted, and the skip is SAID ──────────────
rows_reset; RB_PR="" rb_run a5 "$A1F"
[ "$(posts)" = 0 ] && ok || bad "A5: an APPROVE with no PR number must POST nothing, got $(posts)"
grep -q 'no PR number yet' "$B/pipeline.log" 2>/dev/null \
  && ok || bad "A5: the skip must be named in pipeline.log: $(cat "$B/pipeline.log" 2>/dev/null)"

# ── A6: both blocks in one build enqueue ONCE ────────────────────────────────
rows_reset; rb_run a6 "$A1F" "$A2F"
[ "$(posts)" = 1 ] && ok || bad "A6: two verdict blocks in one build must produce exactly one POST, got $(posts)"

# ── A7: THE MUTATION. Point the gate at the text and A3's fixture must post ──
# Without this, §A2/§A3 would pass against a gate that greps review.md. The
# mutant is the exact defect the ticket forbids: `never a grep over a file`.
MUT="$T/rb-early-mutant.sh"
sed 's/\[ "\$VERDICT_WORD" = APPROVE \]/grep -q "VERDICT: APPROVE" "$BUILD\/review.md"/' "$A1F" > "$MUT"
if ! cmp -s "$A1F" "$MUT"; then
  rows_reset; : > "$REQ"
  B="$T/b-a7-$NOW"; scratch_rm "$B"; mkdir -p "$B"
  printf '%s\nVERDICT: BLOCK\n' "$(grep -h -m1 'Last line exactly VERDICT: APPROVE' "$RB")" > "$B/review.md"
  ( jobsenv
    export BUILD="$B" PROJECT="$PROJECT" KEY=BH-1366 SLUG="$SLUG" JOB_ID=job-1 TIER=2 \
           PR_URL="https://github.com/$SLUG/pull/7"
    bash -c '
      STAMP() { printf "2026-09-22 14:10:00Z"; }
      job_artifact_put() { return 0; }
      rp_out_is_claude() { return 0; }
      rp_out_prov() { printf claude; }
      . "$HARNESS/bin/jobs-client.sh"
      . "'"$MUT"'"' ) 2>/dev/null
  [ "$(posts)" -ge 1 ] \
    && ok || bad "A7: the mutant (gate = grep over review.md) enqueued nothing — §A2/§A3 have no teeth"
else
  bad "A7: could not build the mutant — the gate is not the '[ \"\$VERDICT_WORD\" = APPROVE ]' comparison the ticket requires"
fi

# ── A8: flags/conductor-owns-merges stands the enqueue down ──────────────────
rows_reset; touch "$T/h/flags/conductor-owns-merges"
rb_run a8 "$A1F"
[ "$(posts)" = 0 ] && ok || bad "A8: with conductor-owns-merges on nothing may be enqueued, got $(posts)"
rm -f "$T/h/flags/conductor-owns-merges"

# ── A9: the same PR twice is a DUPLICATE, not a second row ───────────────────
rows_reset; rb_run a9a "$A1F"; P1=$(posts)
rb_run a9b "$A1F"; P2=$(posts)
[ "$P1" = 1 ] && [ "$P2" = 1 ] && ok || bad "A9: each build must POST once ($P1, $P2)"
DUP=$( jobsenv; bash -c '. "$HARNESS/bin/jobs-client.sh"; merge_queue_put demo-os 7 "" "third try"' 2>/dev/null )
[ "$DUP" = duplicate ] && ok || bad "A9: a re-enqueue of a queued PR must answer 'duplicate', got '$DUP'"

# ── A10: a row parked between the two blocks is not walked back to queued ────
rows_reset; : > "$T/mid.sh"
printf 'merge_queue_set %s 7 blocked "parked mid-build" >/dev/null 2>&1\n' "$PROJECT" > "$T/mid.sh"
rb_run a10 "$A1F" "$T/mid.sh" "$A2F"
[ "$(posts)" = 1 ] && ok || bad "A10: the second block must not re-POST, got $(posts)"
[ "$(row_of 7)" = blocked ] && ok || bad "A10: the parked row must still be blocked, got $(row_of 7)"

# ── A11: tier 1 is not this enqueue's business ───────────────────────────────
rows_reset; RB_TIER=1 rb_run a11 "$A1F" "$A2F"
[ "$(posts)" = 0 ] && ok || bad "A11: a tier-1 APPROVE must not be enqueued here (the tier-1 paths own it), got $(posts)"

# ── A12: a refused row is never silent ───────────────────────────────────────
rows_reset; : > "$T/h/logs/ALERTS.log"
RB_CURL=down rb_run a12 "$A1F"
[ -e "$T/h/state/merge-queue/$PROJECT/7" ] \
  && ok || bad "A12: with the worker down the FILE is the queue — it must be written"
[ "$(grep -c '#7' "$T/h/logs/ALERTS.log")" -ge 1 ] \
  && ok || bad "A12: a refused enqueue must write one ALERTS line naming the PR: $(cat "$T/h/logs/ALERTS.log")"
rm -f "$T/h/state/merge-queue/$PROJECT/7"; : > "$T/h/logs/ALERTS.log"
rows_reset; RB_CURL=down RB_BNM=1 rb_run a12b "$A1F"
[ ! -e "$T/h/state/merge-queue/$PROJECT/7" ] \
  && ok || bad "A12b: on a builder box (BUILDER_NO_MERGE) no box-queue file may be written"
[ "$(grep -c '#7' "$T/h/logs/ALERTS.log")" -ge 1 ] \
  && ok || bad "A12b: a builder box still names the PR in ALERTS: $(cat "$T/h/logs/ALERTS.log")"
: > "$T/h/logs/ALERTS.log"

# ═════════════════════════════════════════════════════════════════════════════
# §B — bin/review-prs.sh: only the path that already wanted the box queue
# ═════════════════════════════════════════════════════════════════════════════
RPM="$T/rp-merge.sh"; RPD1="$T/rp-d1.sh"; RPL="$T/rp-ledger.sh"
marked '# >>> review-prs merge'        '# <<< review-prs merge'        "$DIR/bin/review-prs.sh" > "$RPM"
marked '# >>> review-prs d1 artifacts' '# <<< review-prs d1 artifacts' "$DIR/bin/review-prs.sh" > "$RPD1"
marked '# >>> review verdict ledger'   '# <<< review verdict ledger'   "$DIR/bin/review-prs.sh" > "$RPL"
[ -s "$RPM" ] && [ -s "$RPD1" ] && [ -s "$RPL" ] \
  && ok || bad "§B: could not extract review-prs.sh's merge + verdict blocks by their markers"

rp_run() { # rp_run <mode> <verdict-block...>
  local mode="$1"; shift
  : > "$REQ"; : > "$T/rp.log"
  rm -rf "$T/h/state/merge-queue/$PROJECT"; mkdir -p "$T/h/state/merge-queue/$PROJECT"
  cat > "$T/fakebin/gh" <<GHEOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
case "\$*" in
  *"pr view"*"--json state"*) [ "$mode" = merged ] && echo MERGED || echo OPEN ;;
  # TEST-CHANGE (BH-1585): merge_step's state-after read is this REST read now
  # (it was the 'pr view --json state' arm above), so it carries the same mode.
  *"api -i -X GET repos/"*"/pulls/"*) restpr $([ "$mode" = merged ] && echo MERGED || echo OPEN) ticket-head ticket/x main "" ;;
  *) echo "" ;;
esac
exit 0
GHEOF
  chmod +x "$T/fakebin/gh"
  ( jobsenv
    export PROJECT="$PROJECT" SLUG="$SLUG" LOG="$T/rp.log" RPMODE="$mode" \
           JOB_ID="" TIER=2 SCRIPTS="$*"
    bash -c '
      STAMP() { printf "2026-09-22 14:10:00Z"; }
      mc_queue_conductor_only() { return 1; }
      mc_pr_queued() { [ "$RPMODE" = queued ]; }
      rp_prov_is_claude() { [ "$RPMODE" != fallback ]; }
      # TEST-CHANGE (BH-1585): merge_step reads the state-after over REST
      # (mc_pr_view, which review-prs.sh always has in scope); the driver
      # provides it over the stub arm above, through the real gh_rest.
      # TEST-CHANGE (BH-1285): merge_step now reads .base.ref before the
      # direct merge (a stacked PR is held), so the shim carries base.ref too.
      . "'"$DIR"'/bin/lib/gh-rest.sh"
      mc_pr_view() { local f; f=$(mktemp); gh_rest GET "repos/$SLUG/pulls/${1##*/}" > "$f" || { rm -f "$f"; return 75; }
        jq -r "{STATE: (if .merged_at != null then \"MERGED\" elif .state == \"open\" then \"OPEN\" else \"CLOSED\" end), base: {ref: .base.ref}} | ${2:-.}" "$f"; rm -f "$f"; }
      . "$HARNESS/bin/jobs-client.sh"
      . "'"$RPM"'"
      NUM=7; SHA=aaaaaaaa1111; SERVED=claude; VERDICT=APPROVE; AUTHOR=operator
      MERGED=no; RP_MQ_WANT=0
      merge_step "$NUM" "$SHA" "$SERVED"
      for s in $SCRIPTS; do . "$s"; done
      printf "MERGED=%s WANT=%s\n" "$MERGED" "${RP_MQ_WANT:-unset}"' ) 2>"$T/rp.err"
}

rows_reset; OUT=$(rp_run else "$RPD1")
[ -e "$T/h/state/merge-queue/$PROJECT/7" ] \
  && ok || bad "B1: merge_step's queue arm must still write the file it always did (out: $OUT, err: $(cat "$T/rp.err"))"
[ "$(posts)" = 1 ] && ok || bad "B1: an APPROVE that reached merge_step's queue arm must enqueue once, got $(posts) (out: $OUT, err: $(cat "$T/rp.err"))"
rows_reset; OUT=$(rp_run merged "$RPD1")
[ "$(posts)" = 0 ] && ok || bad "B2: a PR this lane just MERGED must not be enqueued, got $(posts) (out: $OUT)"
rows_reset; OUT=$(rp_run queued "$RPD1")
[ "$(posts)" = 0 ] && ok || bad "B3: a PR in the repo's own provider queue must not be enqueued, got $(posts) (out: $OUT)"
rows_reset; touch "$T/h/flags/conductor-owns-merges"
OUT=$(rp_run else "$RPD1")
[ "$(posts)" = 0 ] && ok || bad "B4: conductor-owns-merges must stand the enqueue down, got $(posts) (out: $OUT)"
rm -f "$T/h/flags/conductor-owns-merges"
rows_reset; OUT=$(rp_run fallback "$RPD1")
[ "$(posts)" = 0 ] && ok || bad "B5: a fallback-lane APPROVE must never reach the merge queue, got $(posts) (out: $OUT)"
rows_reset; OUT=$(rp_run else "$RPD1" "$RPL")
[ "$(posts)" = 1 ] && ok || bad "B6: both verdict blocks in sequence must produce ONE POST, got $(posts) (out: $OUT)"

# ═════════════════════════════════════════════════════════════════════════════
# §C — bin/merge-queue.sh, run whole
# ═════════════════════════════════════════════════════════════════════════════
Q="$T/h/state/merge-queue/$PROJECT"
MQLOG="$T/h/logs/merge-queue.log"
gh_state() { # gh_state <STATE|403>
  if [ "$1" = 403 ]; then
    cat > "$T/fakebin/gh" <<'GHEOF'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
case "$*" in
  *"api -i -X GET repos/"*) printf 'HTTP/2 403\n\n{"message":"nope"}\n' ;;
  *) echo "" ;;
esac
exit 0
GHEOF
  else
    cat > "$T/fakebin/gh" <<GHEOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"*) restpr $1 ticket-head ticket/x main "" ;;
  *) echo "" ;;
esac
exit 0
GHEOF
  fi
  chmod +x "$T/fakebin/gh"
}
mq() { # mq [script] — run the queue against the scratch harness
  : > "$REQ"; : > "$MQLOG"
  ( jobsenv
    export CURL_MODE="${MQ_CURL:-ok}" MQSET_MODE="${MQ_SET:-ok}"
    bash "${1:-$DIR/bin/merge-queue.sh}" "$PROJECT" >/dev/null 2>"$T/mq.err" )
}
flag_rows_on()  { touch "$T/h/flags/merge-queue-rows-only"; }
flag_rows_off() { rm -f "$T/h/flags/merge-queue-rows-only"; }
q_reset() { rm -f "$Q"/*; }

# C1 — flag on, one queued ROW and no file: the loop reaches that PR
gh_state CLOSED; flag_rows_on; q_reset; rows_reset; row_set 41 queued
mq
grep -q '#41 dequeued (state=CLOSED)' "$MQLOG" \
  && ok || bad "C1: a queued ROW with no file must be reached by the queue (log: $(cat "$MQLOG"), err: $(cat "$T/mq.err"))"

# C7 — and it was never materialised into a file
gh_state 403; q_reset; rows_reset; row_set 41 queued
mq
[ -z "$(ls -A "$Q" 2>/dev/null)" ] \
  && ok || bad "C7: with the rows as the queue nothing may be touched into state/merge-queue/: $(ls -A "$Q")"
grep -q 'taken from the coordination DB' "$MQLOG" \
  && bad "C7: the row->file materialiser must be SKIPPED when the rows are the queue" || ok
grep -q '#41 read UNVERIFIABLE' "$MQLOG" \
  && ok || bad "C7: the row must still be offered to the loop (log: $(cat "$MQLOG"))"

# C2 — a blocked ROW is not re-offered
gh_state CLOSED; q_reset; rows_reset; row_set 41 blocked
mq
grep -q '#41' "$MQLOG" && bad "C2: a blocked row must not be re-offered (log: $(cat "$MQLOG"))" || ok

# C3 — a .blocked file that already exists is read one more cycle, never migrated
gh_state CLOSED; q_reset; rows_reset; : > "$Q/41.blocked"
mq
grep -q '#41' "$MQLOG" && bad "C3: a .blocked FILE must not be re-offered (log: $(cat "$MQLOG"))" || ok
[ -e "$Q/41.blocked" ] && ok || bad "C3: an existing .blocked file must be left exactly where it is"

# C9 — a plain file with no row is still reached (the union, not a bare row read)
gh_state CLOSED; q_reset; rows_reset; : > "$Q/77"
mq
grep -q '#77 dequeued (state=CLOSED)' "$MQLOG" \
  && ok || bad "C9: a file-only entry must survive the rows-only read (log: $(cat "$MQLOG"), err: $(cat "$T/mq.err"))"

# C5 — the rows unreadable is not "nothing queued"
gh_state CLOSED; q_reset; rows_reset; : > "$Q/77"
MQ_CURL=down mq
grep -q '#77 dequeued (state=CLOSED)' "$MQLOG" \
  && ok || bad "C5: with the worker down the FILE queue must behave exactly as today (log: $(cat "$MQLOG"))"
grep -q 'merge-queue rows could not be read' "$MQLOG" \
  && ok || bad "C5: an unreadable row list must SAY so — silence reads as an empty queue (log: $(cat "$MQLOG"))"

# C8 — flags/automerge-disabled still stops everything
gh_state CLOSED; q_reset; rows_reset; row_set 41 queued
touch "$T/h/flags/automerge-disabled"; mq; rm -f "$T/h/flags/automerge-disabled"
grep -q '#41 dequeued' "$MQLOG" && bad "C8: nothing may be landed or dequeued while automerge-disabled is on (log: $(cat "$MQLOG"))" || ok

# C4 — FLAG OFF IS MAIN, LOG FOR LOG
BASESHA=716647c
BASEFIX="$DIR/tests/fixtures/bh-1366/merge-queue.main-716647c.sh"
cp "$BASEFIX" "$T/mq-main.sh" 2>/dev/null || : > "$T/mq-main.sh"
if git -C "$DIR" cat-file -e "$BASESHA^{commit}" 2>/dev/null; then
  git -C "$DIR" show "$BASESHA:bin/merge-queue.sh" | cmp -s - "$T/mq-main.sh" \
    && ok || bad "C4: the vendored baseline $BASEFIX no longer matches $BASESHA:bin/merge-queue.sh"
fi
if [ -s "$T/mq-main.sh" ]; then
  strip_ts() { sed 's/^[0-9][0-9-]* [0-9:]*Z //' "$1"; }
  gh_state CLOSED; flag_rows_off
  q_reset; rows_reset; row_set 41 queued; mq; strip_ts "$MQLOG" > "$T/log-now.txt"
  q_reset; rows_reset; row_set 41 queued; mq "$T/mq-main.sh"; strip_ts "$MQLOG" > "$T/log-main.txt"
  diff -q "$T/log-now.txt" "$T/log-main.txt" >/dev/null \
    && ok || bad "C4: with the flag OFF the queue must behave exactly as main does:
$(diff "$T/log-main.txt" "$T/log-now.txt")"
  grep -q 'taken from the coordination DB' "$T/log-now.txt" \
    && ok || bad "C4: with the flag off the materialiser must still run (log: $(cat "$T/log-now.txt"))"
else
  bad "C4: the vendored baseline $BASEFIX is missing or empty — the flag-off baseline is unverifiable"
fi

# ═════════════════════════════════════════════════════════════════════════════
# §D — mq_park: a blocking decision carries its REASON
# ═════════════════════════════════════════════════════════════════════════════
# A head-bound mismatch: the ledger says the review approved deadbeefdeadbeef,
# the PR's head is ticket-head. That is the queue's most consequential park.
gh_state OPEN; flag_rows_on; q_reset; rows_reset; row_set 41 queued
mq
PB=$(body_of PATCH /api/merge-queue)
[ "$(jq -r .status <<<"$PB")" = blocked ] \
  && ok || bad "D1: a head-bound mismatch must set the row to blocked, got: $PB (log: $(cat "$MQLOG"))"
grep -q 'is not the reviewed sha' <<<"$(jq -r .reason <<<"$PB")" \
  && ok || bad "D1: the row must carry the same sentence the .blocked filename could not say, got: $PB"
[ ! -e "$Q/41.blocked" ] \
  && ok || bad "D1: with the rows as the queue a park creates NO .blocked file"
[ "$(row_of 41)" = blocked ] && ok || bad "D1: the row must actually be blocked, got $(row_of 41)"

# D2 — the PATCH refused: the file is the fallback, and nothing is healed
gh_state OPEN; q_reset; rows_reset; row_set 41 queued
MQ_SET=404 mq
[ -e "$Q/41.blocked" ] \
  && ok || bad "D2: a refused merge_queue_set must fall back to the .blocked file ($(ls -A "$Q"), log: $(cat "$MQLOG"))"
[ "$(posts)" = 0 ] \
  && ok || bad "D2: a 404 on the set must not create a phantom row, got $(posts) POSTs"

# D3 — flag off: the .blocked file and the MQROW mirror, exactly as today
gh_state OPEN; flag_rows_off; q_reset; rows_reset; row_set 41 queued
mq
[ -e "$Q/41.blocked" ] && ok || bad "D3: with the flag off the park must still write the .blocked file ($(ls -A "$Q"))"
[ "$(row_of 41)" = blocked ] && ok || bad "D3: MQROW must still mirror the park onto the row, got $(row_of 41)"

# ═════════════════════════════════════════════════════════════════════════════
# §E — the neighbours read the same queue through the same endpoint
# ═════════════════════════════════════════════════════════════════════════════
rows_reset; row_set 41 queued; row_set 42 blocked; : > "$REQ"
ELIST=$( jobsenv; bash -c '. "$HARNESS/bin/jobs-client.sh"; merge_queue_list demo-os queued' 2>/dev/null )
[ "$(awk -F'\t' 'NR==1{print $2}' <<<"$ELIST")" = 41 ] \
  && ok || bad "E: merge_queue_list must still answer the queued rows, got: $ELIST"
[ "$(grep -vc '^GET https://jobs.invalid/api/merge-queue?' "$REQ")" = 0 ] \
  && ok || bad "E: a neighbour's read must be the SAME endpoint, no new request kinds: $(cat "$REQ")"

# ── no secrets ───────────────────────────────────────────────────────────────
grep -rq test-secret "$T/h/logs" 2>/dev/null && bad "HARNESS_SECRET leaked into a log" || ok

echo "merge-queue-enqueue-on-verdict: $PASS pass, $FAIL failed"
[ "$FAIL" -eq 0 ]
