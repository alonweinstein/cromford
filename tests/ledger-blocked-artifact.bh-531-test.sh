#!/bin/bash
# tests/ledger-blocked-artifact.bh-531-test.sh — the box side of BH-531: a
# blocked result pulled from the ledger arrives WITH the file its first line
# names, driven through the real bin/run-triage.sh.
#
# THE BUG. A pool build that ends PLAN_BLOCKED writes its open questions to
# $BUILD/plan.md on the fly machine and records one line as its `result` row:
# `PLAN_BLOCKED /root/harness/builds/project-3-TK-77-x/plan.md`. The machine is
# destroyed at reap. The watcher box stages that line verbatim, the sweep hands
# it to a session, and the session is told to quote a file on a host that no
# longer exists — so the client is never asked the question the build stopped
# for. The fix is on both sides: the builder pushes the BODY as a transcript row
# (tests/run-build-blocked-artifact.bh-531-test.sh), and this loop fetches it
# into the staged dir and points RESULT at the local copy.
#
# DRIVEN, not grepped: everything load-bearing here is about what does NOT
# happen — a body fetched for a PR_CREATED row, a second dir for a build already
# staged, a `preplan.md` token rewritten because the matcher was loose, an
# ALERTS page for a builder that simply predates the feature.
# Run from anywhere: tests/ledger-blocked-artifact.bh-531-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "ledger-blocked-artifact.bh-531-test: SKIPPED — jq is not installed"; exit 0; }

mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/state/fly-pool/project-3" "$T/h/env" "$T/h/prompts" \
         "$T/h/catalog/agent-contracts" "$T/fakebin" "$T/tr"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T/h" project-3 || exit 1  # BH-1510.2: lanes read models from model_routes
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/triage-contract.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
mkdir -p "$T/h/bin/lib/rt" && cp "$DIR"/bin/lib/rt/*.sh "$T/h/bin/lib/rt/"
cp "$DIR/fleet.conf" "$T/h/fleet.conf"
cp "$DIR/catalog/agent-contracts/triage-system-append.txt" "$T/h/catalog/agent-contracts/"
: > "$T/h/env/global.env"
printf 'SOP BODY\n' > "$T/h/prompts/project-3.md"

printf '#!/bin/bash\n[ "${2:-}" = "--pending" ] && exit 0\necho "RUN results-sweep"\n' > "$T/h/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 2\n' > "$T/h/bin/gate-diff.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/decision-log.sh"
printf '#!/bin/bash\nprintf "tickets=0\\n" > "${5:-/dev/null}"\nexit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/"*.sh
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/ssh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/scp"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/tailscale"

# The transport. Artifacts honour ?since= (the watermark is load-bearing in this
# loop); transcripts are served from $TRDIR fixture files, and a job with no
# fixture 404s exactly as the worker does.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$M" "$URL" >> "$REQ_SINK"
case "${CURL_MODE:-arts}" in down) exit 7 ;; esac
case "$URL" in
  */api/artifacts\?*)
    SINCE=""
    case "$URL" in *since=*) SINCE="${URL##*since=}"; SINCE="${SINCE%%&*}" ;; esac
    printf '%s\n200\n' "$(jq -c --arg s "$SINCE" \
      '{artifacts: [ .artifacts[] | select($s == "" or .updated_at > $s) ]}' \
      "${ARTS_FIXTURE:-/dev/null}" 2>/dev/null || echo '{"artifacts":[]}')" ;;
  */transcripts)
    J="${URL##*/api/jobs/}"; J="${J%/transcripts}"
    if [ -f "${TRDIR:-/nonexistent}/$J.index" ]; then printf '%s\n200\n' "$(cat "$TRDIR/$J.index")"
    else printf '{"transcripts":[]}\n200\n'; fi ;;
  */transcript\?*)
    Q="${URL#*\?}"; U="${URL%%\?*}"; J="${U##*/api/jobs/}"; J="${J%/transcript}"
    P="${Q#*phase_id=}"; P="${P%%&*}"; A="${Q##*attempt=}"; A="${A%%&*}"
    if [ -f "${TRDIR:-/nonexistent}/$J.$P.$A" ]; then printf '%s\n200\n' "$(cat "$TRDIR/$J.$P.$A")"
    else printf '{"error":"no transcript for this attempt"}\n404\n'; fi ;;
  */api/queue\?*) printf '{"queue":[]}\n200\n' ;;
  # TEST-CHANGE BH-4153: paused-*/automerge-disabled* are now harness_flags rows read DB-first; a 200 with no .flag row is UNREADABLE and fails closed (paused), so the flag GET must answer the worker's real no-row 404.
  */api/flags/*)  printf '{"error":"not found"}\n404\n' ;;
  *)              printf '{"ok":true}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin"/*

# --- the rows, and the bodies that belong to them -----------------------------
row() { # row <key> <job-suffix> <box> <ts> <ref>
  jq -nc --arg j "build-project-3-$1-$2" --arg r "$5" --arg b "$3" --arg k "$1" --arg t "$4" \
    --arg tid "${1#TK-}" \
    '{job_id:$j,artifact_kind:"result",artifact_ref:$r,box:$b,ticket_id:$tid,updated_at:$t,
      detail:({build_dir:("project-3-"+$k+"-x"),key:$k,job_status:"parked"}|tostring)}'
}
{ printf '{"artifacts":['
  row TK-77 1 pool-machine-1 2026-09-10T02:00:01Z "PLAN_BLOCKED /root/harness/builds/project-3-TK-77-x/plan.md"
  printf ','; row TK-78 1 pool-machine-1 2026-09-10T02:00:02Z "REVIEW_BLOCKED /root/harness/builds/project-3-TK-78-x/review.md"
  printf ','; row TK-79 1 pool-machine-1 2026-09-10T02:00:03Z "DECOMPOSE_FAILED see /root/harness/builds/project-3-TK-79-x/decompose-run.txt"
  printf ','; row TK-80 1 pool-machine-1 2026-09-10T02:00:04Z "PLAN_BLOCKED /root/harness/builds/project-3-TK-80-x/plan.md"
  printf ','; row TK-81 1 pool-machine-1 2026-09-10T02:00:05Z "PR_CREATED https://github.com/o/r/pull/12"
  printf ','; row TK-82 1 pool-machine-1 2026-09-10T02:00:06Z "PLAN_BLOCKED /root/harness/builds/project-3-TK-82-x/plan.md"
  printf ','; row TK-83 1 pool-machine-1 2026-09-10T02:00:07Z "PLAN_BLOCKED /root/harness/builds/project-3-TK-83-t/preplan.md"
  printf ','; row TK-84 1 pool-machine-1 2026-09-10T02:00:08Z "PLAN_BLOCKED /root/harness/builds/project-3-TK-84-x/plan.mdx"
  printf ','; row TK-85 1 pool-machine-1 2026-09-10T02:00:09Z "REVIEW_BLOCKED test-tamper: tests/x.sh was weakened — no TEST-CHANGE justification; see /root/harness/builds/project-3-TK-85-x/test-tamper.txt"
  printf ']}\n'; } > "$T/arts.json"

TRDIR="$T/tr"
index() { # index <job> <source>
  jq -nc --arg s "$2" '{transcripts:[{phase_id:0,attempt:100,stage:"plan",runner:"pipeline",source:$s,bytes:40}]}' \
    > "$TRDIR/$1.index"
}
body() { # body <job> <text> [truncated]
  jq -nc --arg b "$2" --argjson t "${3:-0}" '{transcript:{phase_id:0,attempt:100,body:$b,truncated:$t}}' \
    > "$TRDIR/$1.0.100"
}
PLANBODY='Q1: which fee does the rep set, and where?
Q2: per invoice or per client?
'
index build-project-3-TK-77-1 plan_md;      body build-project-3-TK-77-1 "$PLANBODY"
index build-project-3-TK-78-1 review_md;    body build-project-3-TK-78-1 'BLOCK: no test covers the new branch
'
index build-project-3-TK-79-1 decompose_run; body build-project-3-TK-79-1 'decompose refused: this ticket is one change
'
# TK-80: the row exists, the body does NOT — a builder running an older bin/.
# TK-81: a PR_CREATED result that happens to have a stray plan_md row on file.
index build-project-3-TK-81-1 plan_md;      body build-project-3-TK-81-1 'should never be fetched
'
index build-project-3-TK-82-1 plan_md;      body build-project-3-TK-82-1 'the tail of a very long plan
' 1
index build-project-3-TK-83-1 plan_md;      body build-project-3-TK-83-1 'a plan for a preplan-named artifact
'
index build-project-3-TK-84-1 plan_md;      body build-project-3-TK-84-1 'a plan whose pointer is plan.mdx
'
index build-project-3-TK-85-1 review_md;    body build-project-3-TK-85-1 'BLOCK: a test was weakened
'

triage() { # triage <curl-mode>
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 \
           JOBS_BEAT_SECS=3600 CURL_MODE="$1" REQ_SINK="$T/req.txt" \
           ARTS_FIXTURE="$T/arts.json" TRDIR="$TRDIR"
    bash "$DIR/bin/run-triage.sh" project-3 >/dev/null 2>&1 )
}
staged() { ls -d "$T/h/builds/project-3-$1-remote"* 2>/dev/null | head -1; }

triage arts

# ══ 1. PLAN_BLOCKED: the plan arrives, and RESULT points at the local copy ══
D=$(staged TK-77)
[ -n "$D" ] && ok || bad "precondition: the TK-77 result row must be staged at all"
[ -s "$D/plan.md" ] && ok || bad "THE BUG: the staged dir has no plan.md — the file RESULT names died with the machine"
# BYTE-FOR-BYTE, trailing newline included: this file is written back to disk and
# quoted to a client, so "close enough" is not a property worth asserting.
printf '%s' "$PLANBODY" > "$T/expect-plan.md"
cmp -s "$D/plan.md" "$T/expect-plan.md" \
  && ok || bad "the staged plan.md must be the ledger body byte-for-byte: $(head -3 "$D/plan.md" 2>/dev/null)"
[ "$(head -1 "$D/RESULT" 2>/dev/null)" = "PLAN_BLOCKED $D/plan.md" ] \
  && ok || bad "RESULT line 1 must point at the STAGED copy, got '$(head -1 "$D/RESULT" 2>/dev/null)'"
[ -f "$(head -1 "$D/RESULT" 2>/dev/null | awk '{print $2}')" ] \
  && ok || bad "the file RESULT names must exist on this box — that is the whole ticket"
grep -qxF 'ORIGINAL_RESULT: PLAN_BLOCKED /root/harness/builds/project-3-TK-77-x/plan.md' "$D/RESULT" \
  && ok || bad "the builder's own line must be kept as ORIGINAL_RESULT: $(cat "$D/RESULT")"
grep -qxF 'JOB_ID: build-project-3-TK-77-1' "$D/RESULT" && ok || bad "the staged RESULT lost its job id"
grep -q 'TICKET_ID: 77' "$D/RESULT" && ok || bad "the staged RESULT lost its ticket id"

# ══ 2. REVIEW_BLOCKED ═══════════════════════════════════════════════════════
D=$(staged TK-78)
[ -s "$D/review.md" ] && ok || bad "REVIEW_BLOCKED must stage review.md beside its RESULT"
[ "$(head -1 "$D/RESULT" 2>/dev/null)" = "REVIEW_BLOCKED $D/review.md" ] \
  && ok || bad "the REVIEW_BLOCKED line must be rewritten, got '$(head -1 "$D/RESULT" 2>/dev/null)'"

# ══ 3. DECOMPOSE_FAILED — the path is not the last token on the line ════════
D=$(staged TK-79)
[ -s "$D/decompose-run.txt" ] && ok || bad "DECOMPOSE_FAILED must stage decompose-run.txt"
[ "$(head -1 "$D/RESULT" 2>/dev/null)" = "DECOMPOSE_FAILED see $D/decompose-run.txt" ] \
  && ok || bad "the DECOMPOSE_FAILED line must be rewritten in place, got '$(head -1 "$D/RESULT" 2>/dev/null)'"

# ══ 4. NO BODY ON FILE: today's behaviour, said out loud ═══════════════════
# A builder on an older bin/ pushes nothing. The close-out must still be staged
# with the line it came with — and the box must say it could not quote it.
D=$(staged TK-80)
[ -n "$D" ] && ok || bad "a blocked row with no body must still be staged"
[ "$(head -1 "$D/RESULT" 2>/dev/null)" = "PLAN_BLOCKED /root/harness/builds/project-3-TK-80-x/plan.md" ] \
  && ok || bad "with no body the builder's own line must be kept, got '$(head -1 "$D/RESULT" 2>/dev/null)'"
[ ! -e "$D/plan.md" ] && ok || bad "a missing body must not leave an empty plan.md behind"
grep -q 'ORIGINAL_RESULT:' "$D/RESULT" \
  && bad "an unrewritten line must not also carry ORIGINAL_RESULT" || ok
grep -q 'no plan_md body on file' "$T/h/logs/project-3.log" \
  && ok || bad "the miss must be in the project log, naming what was missing"
[ -f "$T/h/state/remote-results/project-3/.handled/build-project-3-TK-80-1.job" ] \
  && ok || bad "a staged row must still be marked handled — a retry cannot invent a body the builder never pushed"

# A PR_CREATED result is never a blocking artifact, whatever rows the job has.
grep -q 'jobs/build-project-3-TK-81-1/transcript' "$T/req.txt" \
  && bad "a PR_CREATED row must not fetch a body at all" || ok
D=$(staged TK-81)
[ ! -e "$D/plan.md" ] && ok || bad "a PR_CREATED result staged a plan.md"
[ "$(head -1 "$D/RESULT" 2>/dev/null)" = "PR_CREATED https://github.com/o/r/pull/12" ] \
  && ok || bad "a PR_CREATED line must be staged untouched, got '$(head -1 "$D/RESULT" 2>/dev/null)'"

# ══ 5. A TAILED BODY SAYS SO ON DISK ═══════════════════════════════════════
D=$(staged TK-82)
head -1 "$D/plan.md" 2>/dev/null | grep -q '^\[tail only:' \
  && ok || bad "a truncated body must say so in the staged file: $(head -1 "$D/plan.md" 2>/dev/null)"
grep -q 'the tail of a very long plan' "$D/plan.md" 2>/dev/null \
  && ok || bad "the tail note must be a prefix, not a replacement"

# ══ 6. preplan.md IS NOT plan.md ═══════════════════════════════════════════
# The rewrite substitutes a path token, and a matcher anchored only on the file
# name turns …/preplan.md into …-remote…/plan.md — a path that names a file the
# box never wrote.
D=$(staged TK-83)
[ "$(head -1 "$D/RESULT" 2>/dev/null)" = "PLAN_BLOCKED /root/harness/builds/project-3-TK-83-t/preplan.md" ] \
  && ok || bad "a preplan.md token must NOT be rewritten, got '$(head -1 "$D/RESULT" 2>/dev/null)'"
grep -q 'ORIGINAL_RESULT:' "$D/RESULT" \
  && bad "a line that was not rewritten must not carry ORIGINAL_RESULT" || ok

# ...and the token has to END where the file name ends, or `…/plan.mdx` is
# rewritten to a staged `plan.md` that the rest of its name no longer matches.
D=$(staged TK-84)
[ "$(head -1 "$D/RESULT" 2>/dev/null)" = "PLAN_BLOCKED /root/harness/builds/project-3-TK-84-x/plan.mdx" ] \
  && ok || bad "a plan.mdx token must NOT be rewritten, got '$(head -1 "$D/RESULT" 2>/dev/null)'"

# A GATE-PRODUCED REVIEW_BLOCKED points at its OWN file, not review.md. The
# ticket's mapping is verbatim — push review.md when it exists — so this line
# keeps every token it came with and the test-tamper path is left alone.
D=$(staged TK-85)
head -1 "$D/RESULT" 2>/dev/null | grep -q 'see /root/harness/builds/project-3-TK-85-x/test-tamper.txt' \
  && ok || bad "a gate's own artifact path must survive untouched: '$(head -1 "$D/RESULT" 2>/dev/null)'"
grep -q "$D" <<<"$(head -1 "$D/RESULT" 2>/dev/null)" \
  && bad "a REVIEW_BLOCKED line with no review.md token must not be rewritten at all" || ok

# ══ 7. IDEMPOTENT: a second tick stages nothing new ════════════════════════
BEFORE=$(ls -d "$T/h/builds"/project-3-*-remote* 2>/dev/null | wc -l | tr -d ' ')
triage arts
AFTER=$(ls -d "$T/h/builds"/project-3-*-remote* 2>/dev/null | wc -l | tr -d ' ')
[ "$BEFORE" = "$AFTER" ] && ok || bad "a second tick staged more dirs ($BEFORE -> $AFTER)"

# ══ 8. THE RELAY JSON FOR A REWRITTEN RESULT IS STILL A DUPLICATE ══════════
# The relay json carries the BUILDER's line, which is no longer the staged
# dir's first line. Without a cross-path identity this arrives a tick later and
# stages a second dir — two close-out comments on one ticket.
# TEST-CHANGE (BH-1041): that identity is no longer the result line, so the
# fixture carries `machine_build_dir` — the same `project-3-TK-77-x` this row's
# detail.build_dir holds (row() above), which the staged RESULT now records as
# its BUILT_AS: line. The assertions are unchanged.
mkdir -p "$T/h/state/remote-results/project-3"
printf '{"key":"TK-77","ticket_id":"77","result":"PLAN_BLOCKED /root/harness/builds/project-3-TK-77-x/plan.md","build_dir":"pool-project-3-TK-77-1","machine_build_dir":"project-3-TK-77-x"}\n' \
  > "$T/h/state/remote-results/project-3/TK-77.json"
triage arts
N=$(ls -d "$T/h/builds/project-3-TK-77-remote"* 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 1 ] \
  && ok || bad "a relay json whose line was REWRITTEN on the staged copy must not stage a second dir (dirs=$N)"
[ ! -f "$T/h/state/remote-results/project-3/TK-77.json" ] \
  && ok || bad "the superseded relay json must be consumed, not retried every tick"

# ══ 9. NOBODY IS PAGED FOR ANY OF THIS ═════════════════════════════════════
# Every box in the fleet will have builders on an older bin/ for a while, and a
# missing body is the expected state during that rollout — not an incident.
[ ! -s "$T/h/logs/ALERTS.log" ] \
  && ok || bad "a missing blocking artifact must not page: $(cat "$T/h/logs/ALERTS.log")"
grep -rq test-secret "$T/h/logs" 2>/dev/null && bad "HARNESS_SECRET leaked into a log" || ok
grep -rq test-secret "$T/h/builds" 2>/dev/null && bad "HARNESS_SECRET leaked into a build record" || ok

echo "ledger-blocked-artifact.bh-531-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
