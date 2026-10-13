#!/bin/bash
# tests/review-reuse-provenance.bh-4134-test.sh — BH-4134 (follow-up to
# BH-3940): a REUSED review APPROVE is held for provenance exactly as a
# rehydrated one is, and a paid read with no verdict does not leave the head
# refused for the conductor.
#
#   P1  bin/lib/review-bought.sh (the real reads over the real jobs client):
#       RB_SERVED carries the serving lane of the hit, stdout stays
#       `<source>\t<WORD>`, review_bought_prov sorts it into
#       claude | cleared | unknown | fallback. P1d: mc_rereview's rrverdict row
#       carries the served word as a 4th field.
#   P2  bin/review-prs.sh (the real lane), `# >>> review-prs bought`: a
#       Claude-served reuse is written served:claude; a no-served reuse is
#       written served:reused-unknown and beats the provenance akey once; a
#       fallback APPROVE is not reused and buys one read under ~prov; a fallback
#       BLOCK is still reused.
#   P3  `# >>> review-prs merge-retry`: served:claude reaches merge_step;
#       reused-unknown, codex, rehydrated and a legacy reused row with no
#       served do not; a row with neither field keeps the legacy default.
#   P4  the real conductor tick: a Claude-served bound approve is consumed; a
#       fallback or no-served one is refused (rbprov) and a read is spawned
#       under MC_RR_REASON=prov; a fallback block still parks.
#   P5  the resolver's `# >>> br rereview post` block: a Claude-served or lead
#       approve is reused; a fallback or no-served approve buys the read.
#   P6  mc_rereview_run's rc-3 arm: the first refusal on the plain key only
#       records `rrguardfirst` (the other lane's read may still be running);
#       one still standing MC_RR_GUARD_SETTLE_S later, with nobody holding a
#       verdict, writes `rrguardspent`, and the next spawn names noverdict.
#       P6f/P6g pin the in-flight cases; P6e drives review-prs's paid
#       no-verdict read into it.
#   P7  REVIEW_DEDUPE=0: no reads, the plain key, no marker.
#
# review_bought is stubbed for P2-P7 (STUB_RB_RC / _SOURCE / _WORD / _CLASS /
# _SERVED) on top of the real lib, so review_bought_prov, review_fp and
# review_skip_log are the real ones. The fake agent-call.sh emulates the K=1
# guard per fingerprint and writes $T/runner (default claude) to .runner.
# Run from anywhere: bash tests/review-reuse-provenance.bh-4134-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
unset REVIEW_DEDUPE REVIEW_DEDUPE_REBUY_AFTER HARNESS_ENV_DIR RB_SOURCE RB_WORD RB_CLASS RB_SERVED

HEAD=ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12
OLD=0123456789abcdef0123456789abcdef01234567
mkdir -p "$T/fakebin"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

# ============================================================================
# P1 — the real review_bought over the real jobs client and a fake curl
# ============================================================================
LIB="$DIR/bin/lib/review-bought.sh"
FIX="$T/fix"; mkdir -p "$FIX" "$T/jh/bin/lib/jobs"
cp "$DIR/bin/jobs-client.sh" "$T/jh/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/jh/bin/lib/jobs/"
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
case "$URL" in
  *"/api/pr-attempts?"*)     F="$FIX/attempts" ;;
  *"/api/verdict/history?"*) F="$FIX/history" ;;
  *"/api/verdicts?"*)        F="$FIX/verdicts" ;;
  *)                         F="" ;;
esac
[ -n "$F" ] && [ -f "$F" ] && { printf '%s\n200\n' "$(cat "$F")"; exit 0; }
[ "$F" = "$FIX/attempts" ] && { printf '{"attempts":[],"count":0}\n200\n'; exit 0; }
printf '{"error":"not found"}\n404\n'
STUB
chmod +x "$T/fakebin/curl"
fx_reset() { rm -f "$FIX"/*; }
att() { printf '%s' "$1" | jq -c '{attempts: [.[] | {sha: .}], count: length}' > "$FIX/attempts"; }
ver() { jq -nc --arg h "$1" --arg w "$2" --arg s "$3" \
          '{rows:[{id:1,repo:"o/r",pr:7,head_sha:$h,verdict:$w,source:$s,created_at:"2025-10-01T10:00:00.000Z"}]}' > "$FIX/verdicts"; }
# his <word> <source> <detail-json> — one history round at $HEAD, shaped like
# the one review-prs writes (bin/review-prs.sh, the review-verdict job).
his() { jq -nc --arg h "$HEAD" --arg w "$1" --arg s "$2" --arg d "$3" \
          '{rounds:[{verdict:$w,reviewed_sha:$h,source:$s,detail:$d,created_at:"2025-10-01T10:00:00.000Z",job_id:"j1"}]}' > "$FIX/history"; }
rpdetail() { jq -nc --arg p "$1" --arg sv "$2" --arg h "$HEAD" \
          '{tier:"2",provenance:$p,served_by:$sv,reviewed_sha:$h,settled:true,source:"review-prs",pr:"https://github.com/o/r/pull/7"}'; }
# lib — one review_bought call; prints rc|stdout|RB_SOURCE|RB_SERVED|prov
lib() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/jh" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box FIX="$FIX" JOBS_RETRIES=0
    # shellcheck source=/dev/null
    . "$T/jh/bin/jobs-client.sh" || exit 9
    # shellcheck source=/dev/null
    . "$LIB" || exit 9
    RB_SERVED=stale
    review_bought o/r 7 "$HEAD" > "$T/lib.out"; rc=$?
    out=$(cat "$T/lib.out")
    printf '%s|%s|%s|%s|%s' "$rc" "${out//$'\t'/>}" "$RB_SOURCE" "$RB_SERVED" "$(review_bought_prov 2>/dev/null)" )
}
want() { [ "$2" = "$3" ] && ok || bad "$1: got '$2', want '$3'"; }

# ---- P1a: rrverdict with a served word
fx_reset; att "[\"$HEAD APPROVE 1759500000 claude\"]"
want "P1a rrverdict claude" "$(lib)" "0|mc-rereview>APPROVE|mc-rereview|claude|claude"
# ---- P1b: a review-prs history round served via OpenRouter
fx_reset; his APPROVE review-prs "$(rpdetail claude claude-via-openrouter)"
want "P1b history claude-via-openrouter" "$(lib)" "0|review-prs>APPROVE|review-prs|claude-via-openrouter|claude"
# ---- P1c: unknown, fallback, cleared
fx_reset; att "[\"$HEAD APPROVE 1759500000\"]"
want "P1c legacy 3-field rrverdict" "$(lib)" "0|mc-rereview>APPROVE|mc-rereview||unknown"
fx_reset; his APPROVE review-prs "$(rpdetail codex codex)"
want "P1c history served by codex" "$(lib)" "0|review-prs>APPROVE|review-prs|codex|fallback"
fx_reset; his APPROVE review-prs "$(jq -nc --arg h "$HEAD" '{tier:"2",provenance:"grok",reviewed_sha:$h,settled:true}')"
want "P1c history with provenance only" "$(lib)" "0|review-prs>APPROVE|review-prs|grok|fallback"
fx_reset; ver "$HEAD" MERGE box
want "P1c box verdicts row" "$(lib)" "0|box>MERGE|box||unknown"
fx_reset; ver "$HEAD" MERGE lead
want "P1c lead verdicts row" "$(lib)" "0|lead>MERGE|lead||cleared"
fx_reset; ver "$HEAD" MERGE human
want "P1c human verdicts row" "$(lib)" "0|human>MERGE|human||cleared"
# a miss leaves RB_SERVED empty, never a stale word
fx_reset
want "P1c miss" "$(lib)" "2||||unknown"

# ============================================================================
# P2-P7 — the stubbed review_bought on top of the real lib
# ============================================================================
{ cat "$DIR/bin/lib/review-bought.sh"
  cat <<'EOF'
review_bought() {
  RB_SOURCE=""; RB_WORD=""; RB_CLASS=""; RB_SERVED=""
  printf '%s\n' "$*" >> "${STUB_RB_CALLS:-/dev/null}"
  local rc="${STUB_RB_RC:-2}"
  if [ "$rc" = 0 ]; then
    RB_SOURCE="${STUB_RB_SOURCE:-}"; RB_WORD="${STUB_RB_WORD:-}"; RB_CLASS="${STUB_RB_CLASS:-}"; RB_SERVED="${STUB_RB_SERVED:-}"
    printf '%s\t%s\n' "$RB_SOURCE" "$RB_WORD"
  fi
  return "$rc"
}
EOF
} > "$T/rb-stub.sh"
export STUB_RB_CALLS="$T/rb-calls.txt"
rb() { export STUB_RB_RC="$1" STUB_RB_SOURCE="${2:-}" STUB_RB_WORD="${3:-}" STUB_RB_CLASS="${4:-}" STUB_RB_SERVED="${5:-}"; }

mk_agent() { # mk_agent <file> <verdict-file>
  cat > "$1" <<EOF
#!/bin/bash
if grep -qxF "\${AGENT_CALL_FP:-}" "$T/seen-fps.txt" 2>/dev/null || [ -f "$T/guard-refuse" ]; then
  printf 'stage=%s fp=%s\n' "\${AGENT_CALL_GUARD_STAGE-}" "\${AGENT_CALL_FP-}" >> "$T/refused.txt"
  printf 'AGENT_CALL_REFUSED call-guard repeat review-head paid=1/1 fp=%s\n' "\${AGENT_CALL_FP:-}" > "\$5"
  exit 74
fi
printf '%s\n' "\${AGENT_CALL_FP:-}" >> "$T/seen-fps.txt"
printf 'stage=%s fp=%s\n' "\${AGENT_CALL_GUARD_STAGE-}" "\${AGENT_CALL_FP-}" >> "$T/sink.txt"
printf '%s\n' "\$(cat "$T/runner" 2>/dev/null || echo claude)" > "\$5.runner"; printf '%s\n' "\$(cat "$T/model" 2>/dev/null || echo claude-fable-5-1)" > "\$5.model"
if [ -f "$T/noverdict" ]; then printf 'findings and no verdict line\n' > "\$5"; exit 0; fi
printf 'Static review.\nTIER: 2\nVERDICT: %s\n' "\$(cat "$2" 2>/dev/null || echo APPROVE)" > "\$5"
EOF
  chmod +x "$1"
}
reset_calls() { rm -f "$T/sink.txt" "$T/refused.txt" "$T/seen-fps.txt" "$T/rb-calls.txt" "$T/guard-refuse" "$T/noverdict" "$T/runner" "$T/model"; }
sinkn() { [ -f "$T/sink.txt" ] && wc -l < "$T/sink.txt" | tr -d ' ' || echo 0; }

# ============================================================================
# P2 — bin/review-prs.sh, the real lane
# ============================================================================
PROJECT=project-1
SLUG=example-org/project-1
NUM=7
RP="$DIR/bin/review-prs.sh"
STATE="$T/h/state/$PROJECT.pr-reviews.json"
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *"pr list"*) cat "$TEST_ROOT/prs.tsv" ;;
  *"pr diff"*"name-only"*) printf 'f.txt\n' ;;
  *"pr diff"*) printf 'diff --git a/f.txt b/f.txt\n+line 10 CHANGED BY PR\n' ;;
  *"pr view"*"state,mergeStateStatus"*) printf '{"state":"OPEN","mergeStateStatus":"BLOCKED"}\n' ;;
  *"pr view"*"comments,reviews"*) printf '{"comments":[],"reviews":[]}\n' ;;
  *"pr view"*"body"*) printf '{"body":"test body"}\n' ;;
  *"pr review"*|*"pr comment"*) printf '%s\n' "$*" >> "$TEST_ROOT/gh-writes.log" ;;
  *"pr merge"*) : ;;
  *actions/runs*) printf '{"s":"completed","c":"success","n":"CI"}\n' ;;
  *"issues/7/comments"*) restpr --raw 200 '[]' ;;
  *"api"*) : ;;
esac
exit 0
STUB
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
chmod +x "$T/fakebin/gh" "$T/fakebin/sleep"
cat > "$T/stub.sh" <<'STUB'
job_lane_open() { JOB_ID="job-x"; export JOB_ID; return 0; }
job_lane_close() { JOB_ID=""; export JOB_ID; return 0; }
job_artifact_put() { return 0; }
job_event() { return 0; }
job_heartbeat() { return 0; }
job_update() { return 0; }
job_phase_open() { return 0; }
job_verdict_rebind() { return 0; }
STUB
fresh_rp() { # fresh_rp <state-json>
  scratch_rm "$T/h" 2>/dev/null
  reset_calls; rm -f "$T/gh-writes.log" "$T/rp-verdict" "$T/beats.txt"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  mk_agent "$T/h/bin/agent-call.sh" "$T/rp-verdict"
  cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/fixround-preflight.sh" "$DIR/bin/lib/review-provenance.sh" "$T/h/bin/lib/"
  cp "$T/rb-stub.sh" "$T/h/bin/lib/review-bought.sh"
  mrs_fixture "$T/h" "$PROJECT"
  cp "$T/stub.sh" "$T/h/bin/stub.sh"
  for b in deploy-request.sh merge-queue.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$b"; chmod +x "$T/h/bin/$b"; done
  printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
  printf '%s\n' "$1" > "$STATE"
  printf '%s\t%s\texternaldev\tTest PR\n' "$NUM" "$HEAD" > "$T/prs.tsv"
}
run_rp() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$DIR/fleet.conf" TEST_ROOT="$T" \
      REPOS_ROOT="$T/no-repos" BASH_ENV="$T/h/bin/stub.sh" REVIEW_LIVE_CI=0
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED
    bash "$RP" "$PROJECT" >/dev/null 2>&1 )
}
st() { jq -r --arg n "$NUM" ".[\$n].$1 // \"\"" "$STATE" 2>/dev/null; }
rplog() { cat "$T/h/logs/"*review* 2>/dev/null; }
provbeats() { [ -f "$T/beats.txt" ] || { echo 0; return; }; grep -c '"akey":"provenance:' "$T/beats.txt"; }
SEED="{\"$NUM\":{\"sha\":\"$OLD\",\"verdict\":\"APPROVE\",\"served\":\"claude\"}}"

# ---- P2a: a Claude-served reuse stays mergeable
fresh_rp "$SEED"; rb 0 review-prs APPROVE approve claude
run_rp
[ "$(sinkn)" = 0 ] && ok || bad "P2a a Claude-served reuse buys nothing: $(cat "$T/sink.txt" 2>/dev/null)"
[ "$(st sha)" = "$HEAD" ] && [ "$(st verdict)" = APPROVE ] && [ "$(st reused_from)" = review-prs ] && [ "$(st served)" = claude ] && ok \
  || bad "P2a state must be {sha:HEAD, verdict:APPROVE, reused_from:review-prs, served:claude}: $(cat "$STATE")"
[ "$(provbeats)" = 0 ] && ok || bad "P2a a Claude-served reuse must not beat a provenance hold: $(cat "$T/beats.txt" 2>/dev/null)"
# ---- P2b: no served -> reused-unknown, held, one provenance beat
fresh_rp "$SEED"; rb 0 box APPROVE approve
run_rp
[ "$(sinkn)" = 0 ] && ok || bad "P2b a no-served reuse buys nothing: $(cat "$T/sink.txt" 2>/dev/null)"
[ "$(st served)" = reused-unknown ] && [ "$(st reused_from)" = box ] && [ "$(st verdict)" = APPROVE ] && ok \
  || bad "P2b a no-served reuse must be written served:reused-unknown: $(cat "$STATE")"
[ "$(provbeats)" = 1 ] && grep -q "\"akey\":\"provenance:$PROJECT:$NUM:$HEAD\"" "$T/beats.txt" && ok \
  || bad "P2b exactly one provenance:<project>:<n>:<sha> beat (the rehydrate akey): $(cat "$T/beats.txt" 2>/dev/null)"
grep -q "APPROVED on its current head by a box verdict that does not say which lane served it" "$T/beats.txt" \
  && ! grep -q "lost the record" "$T/beats.txt" && ok \
  || bad "P2b the reuse beat names the reuse, not a lost ledger: $(cat "$T/beats.txt" 2>/dev/null)"
# ---- P2c: a fallback-served APPROVE is not reused; one read under ~prov
fresh_rp "$SEED"; rb 0 review-prs APPROVE approve codex
run_rp
[ "$(sinkn)" = 1 ] && grep -qx "stage=review-head fp=review:$SLUG#$NUM@$HEAD~prov" "$T/sink.txt" && ok \
  || bad "P2c a fallback APPROVE must buy exactly one read under ~prov: $(cat "$T/sink.txt" 2>/dev/null)"
[ -z "$(st reused_from)" ] && [ "$(st served)" = claude ] && ok || bad "P2c the state is the bought read, not a reuse: $(cat "$STATE")"
rplog | grep -q "review-prs's APPROVE on ${HEAD:0:7} was served by codex, a fallback lane — not reused; buying one read under ~prov" && ok \
  || bad "P2c the 'not reused' line: $(rplog | tail -3)"
# ---- P2d: a fallback BLOCK is still reused
fresh_rp "$SEED"; rb 0 review-prs REQUEST_CHANGES block codex
run_rp
[ "$(sinkn)" = 0 ] && [ "$(st verdict)" = REQUEST_CHANGES ] && [ "$(st reused_from)" = review-prs ] && ok \
  || bad "P2d a fallback BLOCK is reused: calls=$(sinkn) $(cat "$STATE")"
[ "$(provbeats)" = 0 ] && ok || bad "P2d a reused BLOCK beats nothing: $(cat "$T/beats.txt" 2>/dev/null)"

# ============================================================================
# P3 — `# >>> review-prs merge-retry`, extracted
# ============================================================================
awk '/^# >>> review-prs merge-retry/{f=1;next} /^# <<< review-prs merge-retry/{exit} f' "$RP" > "$T/rpr.sh"
[ -s "$T/rpr.sh" ] && ok || bad "P3 could not extract the merge-retry block"
P3S="$T/p3-state.json"
p3() { # p3 <row-json> — merge_retry 9 HEAD; merge_step's argv lands in $T/p3-ms.txt
  printf '{"9":%s}\n' "$1" > "$P3S"; rm -f "$T/p3-ms.txt"
  ( export HARNESS="$T/p3h" STATE="$P3S" LOG="$T/p3.log" SLUG=acme/widgets PROJECT=widgets MS="$T/p3-ms.txt"
    bash -c 'set -uo pipefail
      STAMP() { printf TS; }
      . "$1"
      rp_state_write() { local t; t=$(mktemp); jq "$@" "$STATE" > "$t" && mv "$t" "$STATE"; }
      hold_conductor_owns_merges() { return 1; }; mc_queue_conductor_only() { return 1; }
      hold_automerge_disabled() { return 1; }; hold_paused_project() { return 1; }
      mc_pr_view() { printf "OPEN CLEAN"; }
      merge_step() { printf "%s\n" "$*" >> "$MS"; MERGED=no; }
      . "$2"
      merge_retry 9 '"$HEAD" _ "$DIR/bin/lib/review-provenance.sh" "$T/rpr.sh" 2>"$T/p3.err" )
}
p3r() { jq -r '.["9"].merge_retries // ""' "$P3S"; }
p3 "{\"sha\":\"$HEAD\",\"verdict\":\"APPROVE\",\"reused_from\":\"review-prs\",\"served\":\"claude\"}"
[ "$(cat "$T/p3-ms.txt" 2>/dev/null)" = "9 $HEAD claude " ] && [ "$(p3r)" = 1 ] && ok \
  || bad "P3a a Claude-served reuse reaches merge_step as claude: ms=$(cat "$T/p3-ms.txt" 2>/dev/null) retries=$(p3r) err=$(cat "$T/p3.err")"
for row in "\"reused_from\":\"box\",\"served\":\"reused-unknown\"" "\"served\":\"codex\"" "\"served\":\"rehydrated\"" "\"reused_from\":\"box\""; do
  p3 "{\"sha\":\"$HEAD\",\"verdict\":\"APPROVE\",$row}"
  [ ! -s "$T/p3-ms.txt" ] && [ -z "$(p3r)" ] && ok || bad "P3b {$row} must not reach merge_step: ms=$(cat "$T/p3-ms.txt" 2>/dev/null) retries=$(p3r)"
done
p3 "{\"sha\":\"$HEAD\",\"verdict\":\"APPROVE\"}"
[ "$(cat "$T/p3-ms.txt" 2>/dev/null)" = "9 $HEAD claude " ] && ok || bad "P3b control: a row with neither field keeps the legacy claude default: $(cat "$T/p3-ms.txt" 2>/dev/null)"

# ============================================================================
# P1d, P6, P7 — the conductor lib: mc_rereview, _spawn, _run
# ============================================================================
M="$T/mc"; MFB="$T/mc-fakebin"
mkdir -p "$M/bin/lib/mc" "$M/logs" "$M/state" "$M/env" "$MFB"
cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/review-provenance.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$M/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$M/bin/lib/mc/"
cp "$T/rb-stub.sh" "$M/bin/lib/review-bought.sh"
cp "$T/fakebin/restpr" "$MFB/restpr"
mrs_fixture "$M" proj
mk_agent "$M/bin/agent-call.sh" "$T/mc-verdict"
cat > "$M/bin/jobs-client.sh" <<EOF
pr_rows_on() { return 1; }
pr_attempt_put() { printf 'PUT /api/pr-attempts repo=%s num=%s kind=%s sha=%s\n' "\$1" "\$2" "\$3" "\$4" >> "$T/puts.txt"; return 0; }
EOF
cat > "$MFB/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"v3.diff"*) restpr --diff '--- a/x.sh
+++ b/x.sh
+echo hi
' ;;
  *"api -i -X GET repos/acme/widgets/pulls/34"*) restpr OPEN deadbeef ticket/x main "" MERGEABLE CLEAN operator "" 'a PR body' ;;
esac
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/setsid.txt"\nexit 0\n' "$T" > "$MFB/setsid"
chmod +x "$MFB/gh" "$MFB/setsid"
MLOG="$M/logs/merge-conductor.log"
mc() { ( export HARNESS="$M" PATH="$MFB:$PATH" MC_RR_LIVE_CI=0
         bash -c 'set -uo pipefail; . "$HARNESS/bin/lib/merge-conductor-lib.sh"; '"$1" ); }
RRARGS="acme/widgets 34 proj https://github.com/acme/widgets/pull/34 oldsha $HEAD ''"

# ---- P1d: the rrverdict row records who served it
reset_calls; rm -f "$T/puts.txt"; : > "$MLOG"
V=$(mc "mc_rereview $RRARGS \"$T/rr.out\"")
[ "$V" = APPROVE ] && grep -qE "^PUT /api/pr-attempts repo=acme/widgets num=34 kind=rrverdict sha=$HEAD APPROVE [0-9]{10} claude\$" "$T/puts.txt" 2>/dev/null && ok \
  || bad "P1d the rrverdict row must be '<head> <WORD> <epoch> <served>': v=$V $(cat "$T/puts.txt" 2>/dev/null)"
reset_calls; rm -f "$T/puts.txt"; echo openrouter > "$T/runner"
echo anthropic/claude-fable-5-1 > "$T/model"
V=$(mc "mc_rereview $RRARGS \"$T/rr.out\"")
grep -qE "kind=rrverdict sha=$HEAD APPROVE [0-9]{10} claude-via-openrouter\$" "$T/puts.txt" 2>/dev/null && ok \
  || bad "P1d a Claude-via-OpenRouter read records claude-via-openrouter: v=$V $(cat "$T/puts.txt" 2>/dev/null)"
rm -f "$T/runner" "$T/model"

# ---- P6: the rc-3 arm on a plain-key refusal
run_rr() { # run_rr <reason> — one mc_rereview_run; MC_ATTEMPTS copied to $T/att.txt
  mc '
    mkdir -p "$MC_RR_DIR"; touch "$MC_ATTEMPTS"
    jf=$(mc_rr_file acme/widgets 34 '"$HEAD"')
    MC_RR_REASON="'"$1"'" mc_rereview_run acme/widgets 34 proj https://github.com/acme/widgets/pull/34 oldsha '"$HEAD"' "" "$jf" "${jf%.json}.out"
    cp "$MC_ATTEMPTS" "'"$T"'/att.txt"'
}
spawn_reason() { # the MC_RR_REASON word the next spawn passes
  rm -f "$T/setsid.txt"
  mc '
    mkdir -p "$MC_RR_DIR"; touch "$MC_ATTEMPTS"
    mc_rereview_spawn acme/widgets 34 proj https://github.com/acme/widgets/pull/34 oldsha '"$HEAD"' ""
    rm -f "$(mc_rr_file acme/widgets 34 '"$HEAD"')"'
  tr ' ' '\n' < "$T/setsid.txt" 2>/dev/null | grep '^MC_RR_REASON=' | head -1
}
mc_clear() { mc 'mkdir -p "$MC_RR_DIR"; : > "$MC_ATTEMPTS"; rm -f "$MC_RR_DIR"/*.json "$MC_RR_DIR"/*.out*'; : > "$MLOG"; }
# first_at <key> <epoch> — a first plain-key refusal recorded at <epoch>
first_at() { mc 'echo "rrguardfirst '"$1 $HEAD $2"'" >> "$MC_ATTEMPTS"'; }
OLD=$(( $(date -u +%s) - 3001 ))
plainfp="review:acme/widgets#34@$HEAD"
# P6f: the FIRST refusal on the plain key: the other lane's read may still be
# in flight (the guard counts from the claim), so nothing is asked or marked
reset_calls; mc_clear; printf '%s\n' "$plainfp" > "$T/seen-fps.txt"; rb 2
run_rr ""
grep -q "deferred by the call-guard" "$MLOG" && ok || bad "P6f the rc-3 arm must be taken: $(cat "$MLOG")"
grep -qE "^rrguardfirst acme/widgets#34 $HEAD [0-9]{10}\$" "$T/att.txt" && ok || bad "P6f the first refusal records rrguardfirst: $(cat "$T/att.txt")"
! grep -q '^rrguardspent ' "$T/att.txt" && [ ! -s "$T/rb-calls.txt" ] && ok \
  || bad "P6f a fresh refusal neither asks review_bought nor marks: $(cat "$T/att.txt") asks=$(cat "$T/rb-calls.txt" 2>/dev/null)"
R=$(spawn_reason); [ "$R" = MC_RR_REASON= ] && ok || bad "P6f the next spawn stays plain (got '$R')"
# P6g: still refused, but younger than MC_RR_GUARD_SETTLE_S: still nothing,
# and the first epoch is not moved
run_rr ""
[ "$(grep -c '^rrguardfirst ' "$T/att.txt")" = 1 ] && ! grep -q '^rrguardspent ' "$T/att.txt" && [ ! -s "$T/rb-calls.txt" ] && ok \
  || bad "P6g a young refusal marks nothing and keeps one rrguardfirst: $(cat "$T/att.txt") asks=$(cat "$T/rb-calls.txt" 2>/dev/null)"
# P6g': the window is the knob, not a constant
( export MC_RR_GUARD_SETTLE_S=0; run_rr "" )
grep -qx "rrguardspent acme/widgets#34 $HEAD" "$T/att.txt" && ok || bad "P6g' MC_RR_GUARD_SETTLE_S=0 settles at once: $(cat "$T/att.txt")"
# P6a: review-prs paid the plain key with no verdict and the refusal has
# stood past the settle window; nobody holds a verdict
reset_calls; mc_clear; printf '%s\n' "$plainfp" > "$T/seen-fps.txt"; rb 2; first_at acme/widgets#34 "$OLD"
run_rr ""
grep -q "deferred by the call-guard" "$MLOG" && ok || bad "P6a the rc-3 arm must be taken: $(cat "$MLOG")"
grep -qx "rrguardspent acme/widgets#34 $HEAD" "$T/att.txt" && ok || bad "P6a rrguardspent must be recorded: $(cat "$T/att.txt")"
[ "$(grep -c 'already paid by another lane' "$MLOG")" = 1 ] && ok || bad "P6a the 'already paid' line once: $(cat "$MLOG")"
grep -qx "acme/widgets 34 $HEAD --except-builder" "$T/rb-calls.txt" 2>/dev/null && ok || bad "P6a review_bought asked with --except-builder: $(cat "$T/rb-calls.txt" 2>/dev/null)"
R=$(spawn_reason); [ "$R" = MC_RR_REASON=noverdict ] && ok || bad "P6a the next spawn must name noverdict (got '$R')"
run_rr noverdict
[ "$(sinkn)" = 1 ] && grep -qx "stage=review-head fp=$plainfp~noverdict" "$T/sink.txt" && ok \
  || bad "P6a the retry buys exactly one read under ~noverdict: $(cat "$T/sink.txt" 2>/dev/null)"
grep -q "detached re-review finished: APPROVE" "$MLOG" && ok || bad "P6a the retry produces a verdict: $(tail -2 "$MLOG")"
# P6b: unreadable -> no marker
reset_calls; mc_clear; printf '%s\n' "$plainfp" > "$T/seen-fps.txt"; rb 1; first_at acme/widgets#34 "$OLD"
run_rr ""
! grep -q '^rrguardspent ' "$T/att.txt" && ok || bad "P6b an unreadable review_bought writes no marker: $(cat "$T/att.txt")"
R=$(spawn_reason); [ "$R" = MC_RR_REASON= ] && ok || bad "P6b the next spawn stays plain (got '$R')"
# P6c: a verdict on record -> no marker
reset_calls; mc_clear; printf '%s\n' "$plainfp" > "$T/seen-fps.txt"; rb 0 review-prs APPROVE approve claude; first_at acme/widgets#34 "$OLD"
run_rr ""
! grep -q '^rrguardspent ' "$T/att.txt" && ok || bad "P6c a verdict on record writes no marker: $(cat "$T/att.txt")"
# P6d: a refusal on ~noverdict writes no rrguardspent; rrnvdefer once
reset_calls; mc_clear; touch "$T/guard-refuse"; rb 2
run_rr noverdict; run_rr noverdict
! grep -q '^rrguardspent ' "$T/att.txt" && ok || bad "P6d a ~noverdict refusal writes no rrguardspent: $(cat "$T/att.txt")"
[ "$(grep -c 'deferred by the call-guard' "$MLOG")" = 1 ] && grep -qx "rrnvdefer acme/widgets#34 $HEAD" "$T/att.txt" && ok \
  || bad "P6d the noverdict deferral is said once: $(cat "$MLOG")"
# P6d': a ~prov refusal is said once too, under rrprovdefer
reset_calls; mc_clear; touch "$T/guard-refuse"; rb 2
run_rr prov; run_rr prov
[ "$(grep -c 'deferred by the call-guard' "$MLOG")" = 1 ] && grep -qx "rrprovdefer acme/widgets#34 $HEAD" "$T/att.txt" && ! grep -q '^rrguardspent ' "$T/att.txt" && ok \
  || bad "P6d' the prov deferral is said once, no rrguardspent: $(cat "$MLOG") / $(cat "$T/att.txt")"
# P6e: end to end — review-prs pays the plain key with no verdict, then the conductor
fresh_rp "$SEED"; rb 2; touch "$T/noverdict"
run_rp
[ "$(sinkn)" = 1 ] && grep -qx "stage=review-head fp=review:$SLUG#$NUM@$HEAD" "$T/sink.txt" && ok \
  || bad "P6e review-prs pays the plain key: $(cat "$T/sink.txt" 2>/dev/null)"
rm -f "$T/noverdict"; mc_clear
e2e_run() { mc '
    mkdir -p "$MC_RR_DIR"; touch "$MC_ATTEMPTS"
    jf=$(mc_rr_file '"$SLUG $NUM"' '"$HEAD"')
    MC_RR_REASON="'"$1"'" mc_rereview_run '"$SLUG $NUM"' proj https://github.com/'"$SLUG"'/pull/'"$NUM"' oldsha '"$HEAD"' "" "$jf" "${jf%.json}.out"'; }
e2e_spawn() { rm -f "$T/setsid.txt"
  mc 'mkdir -p "$MC_RR_DIR"; touch "$MC_ATTEMPTS"; mc_rereview_spawn '"$SLUG $NUM"' proj https://github.com/'"$SLUG"'/pull/'"$NUM"' oldsha '"$HEAD"' ""
      rm -f "$(mc_rr_file '"$SLUG $NUM"' '"$HEAD"')"'
  tr ' ' '\n' < "$T/setsid.txt" 2>/dev/null | grep '^MC_RR_REASON=' | head -1 | cut -d= -f2; }
# Two ticks inside the settle window (review-prs's read could still be
# running): both plain, both refused, nothing bought.
R1=$(e2e_spawn); e2e_run "$R1"
R2=$(e2e_spawn); e2e_run "$R2"
[ -z "$R1" ] && [ -z "$R2" ] && [ "$(sinkn)" = 1 ] && ok \
  || bad "P6e inside the settle window the conductor stays plain and buys nothing (got '$R1' / '$R2'): $(cat "$T/sink.txt")"
# The refusal has now stood past the window: age the first one.
mc 'sed -i "s/^\(rrguardfirst [^ ]* [^ ]*\) [0-9]*\$/\1 '"$OLD"'/" "$MC_ATTEMPTS"'
R3=$(e2e_spawn); e2e_run "$R3"
R4=$(e2e_spawn); e2e_run "$R4"
[ -z "$R3" ] && [ "$R4" = noverdict ] && ok || bad "P6e past the window the refused plain spawn is followed by noverdict (got '$R3' / '$R4')"
[ "$(sinkn)" = 2 ] && grep -qx "stage=review-head fp=review:$SLUG#$NUM@$HEAD~noverdict" "$T/sink.txt" && ok \
  || bad "P6e two paid reads for the head in total, the second on ~noverdict: $(cat "$T/sink.txt")"
[ "$(wc -l < "$T/refused.txt" | tr -d ' ')" = 3 ] && ok || bad "P6e three refusals, all the conductor's plain key: $(cat "$T/refused.txt" 2>/dev/null)"

# ---- P7: REVIEW_DEDUPE=0
fresh_rp "$SEED"; rb 0 review-prs APPROVE approve codex
REVIEW_DEDUPE=0 run_rp
[ "$(sinkn)" = 1 ] && grep -qx "stage=review-head fp=review:$SLUG#$NUM@$HEAD" "$T/sink.txt" && [ ! -s "$T/rb-calls.txt" ] && ok \
  || bad "P7 REVIEW_DEDUPE=0 review-prs asks nothing and buys the plain key: $(cat "$T/sink.txt" 2>/dev/null) asks=$(cat "$T/rb-calls.txt" 2>/dev/null)"
reset_calls; mc_clear; printf '%s\n' "$plainfp" > "$T/seen-fps.txt"; rb 2; first_at acme/widgets#34 "$OLD"
( export REVIEW_DEDUPE=0; run_rr "" )
! grep -q '^rrguardspent ' "$T/att.txt" && ok || bad "P7 REVIEW_DEDUPE=0 writes no rrguardspent: $(cat "$T/att.txt")"

# ============================================================================
# P4 — the real conductor tick
# ============================================================================
export JOBS_URL=https://jobs.invalid
C="$T/c"
mkdir -p "$C/bin/lib/mc" "$C/bin/lib/jobs" "$C/logs" "$C/state" "$C/flags" "$C/locks" "$C/builds" "$C/env" \
         "$T/cfb" "$T/runs" "$T/repos"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" \
   "$DIR/bin/lib/review-provenance.sh" "$C/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$C/bin/lib/mc/"; cp "$DIR"/bin/lib/jobs/*.sh "$C/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$C/bin/"
cp "$T/rb-stub.sh" "$C/bin/lib/review-bought.sh"
cp "$T/fakebin/restpr" "$T/cfb/restpr"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$C/fleet.conf"
: > "$C/env/global.env"
printf '#!/bin/bash\nprintf "static review\\nVERDICT: APPROVE\\n" > "$5"; exit 0\n' > "$C/bin/agent-call.sh"
chmod +x "$C/bin/agent-call.sh"
H_OLD=aaaaaaaa1111
H_GRN=$HEAD
REC="$C/builds/pool-demo-os-TK-12-202609120002"
mkdir -p "$REC"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/12" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
runs_green() { printf '{"workflow_runs":[{"id":%s,"name":"Harness CI","run_started_at":"2026-09-18T00:00:00Z","run_attempt":1,"status":"completed","conclusion":"success"}]}\n' "$2" > "$T/runs/$1.json"; }
runs_green "$H_OLD" 900; runs_green "$H_GRN" 901
for S in "$H_OLD" "$H_GRN"; do printf 'patch for %s\n' "$S" > "$T/patch.$S"; done
cat > "$T/cfb/gh" <<EOF
#!/bin/bash
Q=""; ARGS=()
while [ \$# -gt 0 ]; do case "\$1" in -q|--jq) Q="\$2"; shift 2 ;; *) ARGS+=("\$1"); shift ;; esac; done
A="\${ARGS[*]}"
HEAD=\$(cat "$T/prhead" 2>/dev/null)
answer() {
  case "\$A" in *"api -i -X GET "*) [ -f "\$1" ] || { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }; restpr --raw 200 "\$(cat "\$1")"; exit 0 ;; esac
  [ -f "\$1" ] || exit 1
  if [ -n "\$Q" ]; then jq -r "\$Q" "\$1"; else cat "\$1"; fi
}
case "\$A" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*) echo "MERGE ATTEMPTED" >> "$T/c-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    printf '[{"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"%s","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]\n' "\$HEAD" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) SHA="\${A#*head_sha=}"; SHA="\${SHA%%&*}"; SHA="\${SHA%% *}"; answer "$T/runs/\$SHA.json" ;;
  *"api -i -X POST repos/example-org/demo-os/issues/12/comments"*)
    { printf 'pr comment\n'; for a in "\${ARGS[@]}"; do case "\$a" in body=@*) cat "\${a#body=@}"; echo ;; esac; done; } >> "$T/c-comments.txt"
    restpr --raw 201 '{"id":1}' ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/12"*) restpr OPEN "\$HEAD" ticket/TK-12 main "" MERGEABLE CLEAN app/cromford "" "plain body" ;;
  *"issues/12/comments"*) echo '[]' > "$T/c-empty.json"; answer "$T/c-empty.json" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
cat > "$T/cfb/git" <<EOF
#!/bin/bash
A="\$*"
case "\$A" in
  *--version*) echo "git version 2.43.0" ;;
  *merge-tree*) exit 0 ;;
  *merge-base*) echo base0000base0000 ;;
  *patch-id*) md5sum | cut -d' ' -f1 ;;
  *" diff "*) SHA="\${A##* }"; cat "$T/patch.\$SHA" 2>/dev/null || printf 'diff-%s\n' "\$SHA" ;;
esac
exit 0
EOF
cat > "$T/cfb/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "GET "*/api/verdicts\?*) printf '{"standing":null,"rows":[],"truncated":false}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
# setsid records the detached job's argv and runs nothing
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-setsid.txt"\nexit 0\n' "$T" > "$T/cfb/setsid"
chmod +x "$T/cfb/gh" "$T/cfb/git" "$T/cfb/curl" "$T/cfb/setsid"
touch "$C/flags/merge-conductor-actions"
( export HARNESS="$C"; . "$C/bin/lib/merge-conductor-lib.sh"; mc_init ) >/dev/null 2>&1
CATT="$C/state/merge-conductor/attempts.txt"; CROWS="$C/state/merge-conductor/pr-state.tsv"
CLOG="$C/logs/merge-conductor.log"; CRR="$C/state/merge-conductor/rereview"
CKEY='example-org/demo-os#12'
ctick() { ( cd "$T" && PATH="$T/cfb:$PATH" HARNESS="$C" HARNESS_SECRET=x MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" \
            MC_RR_PATH="$T/cfb:$PATH" MC_MERGE_TREE=0 bash "$C/bin/merge-conductor.sh" >/dev/null 2>"$T/ctick.err" ); }
c_state() { awk -F'\t' -v k="$CKEY" '$1==k {print $2}' "$CROWS" 2>/dev/null; }
c_why()   { awk -F'\t' -v k="$CKEY" '$1==k {print $7}' "$CROWS" 2>/dev/null; }
c_jobs()  { ls "$CRR"/*.json 2>/dev/null | wc -l | tr -d ' '; }
c_reset() { # c_reset <head>
  rm -f "$CROWS" "$CATT" "$T/c-comments.txt" "$T/rb-calls.txt" "$T/c-setsid.txt"; touch "$CATT"
  find "$CRR" -maxdepth 1 -type f -delete 2>/dev/null
  scratch_rm "$C/state/merge-conductor/handoff" 2>/dev/null; scratch_rm "$C/state/merge-conductor/stuck" 2>/dev/null
  echo "$H_OLD" > "$REC/reviewed-sha"; printf '%s' "$1" > "$T/prhead"; : > "$CLOG"
}
# ---- P4a: a Claude-served bound approve is consumed
c_reset "$H_GRN"; rb 0 review-prs APPROVE approve claude
ctick
grep -q "review-prs already verdicted APPROVE on this exact head" "$T/c-comments.txt" 2>/dev/null && ok \
  || bad "P4a the approval is rebound with the 'already verdicted' comment: $(cat "$T/c-comments.txt" 2>/dev/null) / $(tail -3 "$CLOG")"
grep -qx "rbverdict $CKEY $H_GRN" "$CATT" && [ "$(c_jobs)" = 0 ] && ! grep -q '^rbprov ' "$CATT" && ok \
  || bad "P4a rbverdict, no job, no rbprov: jobs=$(c_jobs) $(cat "$CATT")"
# ---- P4b: a fallback or no-served bound approve is refused and a read is bought under ~prov
for case_ in codex none; do
  c_reset "$H_GRN"
  if [ "$case_" = codex ]; then rb 0 review-prs APPROVE approve codex; else rb 0 box APPROVE approve; fi
  ctick
  ! grep -q '^rbverdict ' "$CATT" && ! grep -q "already verdicted" "$T/c-comments.txt" 2>/dev/null && ok \
    || bad "P4b/$case_ the approve must not be consumed: $(cat "$CATT") / $(cat "$T/c-comments.txt" 2>/dev/null)"
  grep -qx "rbprov $CKEY $H_GRN" "$CATT" && ok || bad "P4b/$case_ rbprov must be recorded: $(cat "$CATT")"
  [ "$(grep -c 'BOUND_VERDICT refused' "$CLOG")" = 1 ] && ok || bad "P4b/$case_ 'BOUND_VERDICT refused' once: $(grep -i bound "$CLOG")"
  [ "$(c_jobs)" = 1 ] && [ "$(wc -l < "$T/c-setsid.txt" 2>/dev/null | tr -d ' ')" = 1 ] \
    && tr ' ' '\n' < "$T/c-setsid.txt" | grep -qx 'MC_RR_REASON=prov' && ok \
    || bad "P4b/$case_ exactly one job spawned under MC_RR_REASON=prov: jobs=$(c_jobs) $(cat "$T/c-setsid.txt" 2>/dev/null) / $(tail -3 "$CLOG")"
done
grep -q "box's APPROVE on ${H_GRN:0:8} carries provenance 'none'" "$CLOG" && ok || bad "P4b a no-served approve names provenance 'none': $(grep -i bound "$CLOG")"
# ---- P4c: a fallback block still parks
c_reset "$H_GRN"; rb 0 review-prs BLOCK block codex
ctick
[ "$(c_state)" = BLOCKED_HUMAN ] && [ "$(c_why)" = head-not-reapproved ] && [ "$(c_jobs)" = 0 ] && ok \
  || bad "P4c a fallback block parks head-not-reapproved (got $(c_state) / $(c_why), jobs=$(c_jobs))"

# ============================================================================
# P5 — bin/blocked-resolver.sh's `# >>> br rereview post`, extracted
# ============================================================================
awk '/^ *# >>> br rereview post/{f=1;next} /^ *# <<< br rereview post/{exit} f' \
  "$DIR/bin/blocked-resolver.sh" > "$T/br-post.sh"
[ -s "$T/br-post.sh" ] && ok || bad "P5 no '# >>> br rereview post' block to drive"
br_drive() { # br_drive <name> <kind> <n>
  local d="$1"
  rm -f "$T/br-$d".*
  mkdir -p "$T/br-rec-$d"
  ( set -uo pipefail
    . "$T/rb-stub.sh"
    mc_rereview() { printf 'MC_RR_REASON=%s\n' "${MC_RR_REASON-<unset>}" >> "$T/br-$d.rr"
      printf 'findings\nVERDICT: APPROVE\n' > "$8"; printf APPROVE; return 0; }
    mc_transition() { printf '%s\n' "$*" >> "$T/br-$d.tr"; }
    mc_slug_of_url() { printf 'acme/widgets'; }
    mc_num_of_url()  { printf '7'; }
    mc_row_field()   { printf '0000111122223333'; }
    br_pr_field()    { printf '%s' "$HEAD"; return 0; }
    br_record()      { local a; for a in "$@"; do printf '%s|' "$a"; done >> "$T/br-$d.rec"; echo >> "$T/br-$d.rec"; }
    say()            { printf '%s\n' "$*" >> "$T/br-$d.say"; }
    rp_post()        { printf '%s\n' "$5" >> "$T/br-$d.note"; }
    br_count()       { printf '%s\n' "$1" >> "$T/br-$d.count"; }
    p=widgets; rkey=WI-1; url=https://github.com/acme/widgets/pull/7; rec="$T/br-rec-$d"
    kind="$2"; n="$3"
    tag=no-verdict ctr=rereviews lfctr=lanefails nth="read $((n+1)) of 5"
    bought='after the conductor got no verdict'
    . "$T/br-post.sh"
  ) 2> "$T/br-$d.err"
}
# ---- P5a: a Claude-served approve is reused
rb 0 review-prs APPROVE approve claude
br_drive p5a no-verdict 0
[ ! -s "$T/br-p5a.rr" ] && grep -q ' WAIT_REVIEW ' "$T/br-p5a.tr" 2>/dev/null \
  && grep -q "Re-review not bought: review-prs verdicted APPROVE" "$T/br-p5a.note" 2>/dev/null && ok \
  || bad "P5a a Claude-served approve is reused: rr=$(cat "$T/br-p5a.rr" 2>/dev/null) tr=$(cat "$T/br-p5a.tr" 2>/dev/null) note=$(cat "$T/br-p5a.note" 2>/dev/null) err=$(cat "$T/br-p5a.err")"
# ---- P5b: a fallback or no-served approve buys the read
for case_ in codex none; do
  if [ "$case_" = codex ]; then rb 0 review-prs APPROVE approve codex; else rb 0 box APPROVE approve; fi
  br_drive "p5b$case_" no-verdict 0
  grep -qx 'MC_RR_REASON=brnv1' "$T/br-p5b$case_.rr" 2>/dev/null && grep -qx llm "$T/br-p5b$case_.count" 2>/dev/null && ok \
    || bad "P5b/$case_ the read is bought under brnv1 and counted: rr=$(cat "$T/br-p5b$case_.rr" 2>/dev/null) count=$(cat "$T/br-p5b$case_.count" 2>/dev/null) err=$(cat "$T/br-p5b$case_.err")"
  ! grep -q "Re-review not bought" "$T/br-p5b$case_.note" 2>/dev/null && grep -q '|rereviews|$' "$T/br-p5b$case_.rec" 2>/dev/null && ok \
    || bad "P5b/$case_ no 'not bought' note and the counter bumped: note=$(cat "$T/br-p5b$case_.note" 2>/dev/null) rec=$(cat "$T/br-p5b$case_.rec" 2>/dev/null)"
  grep -q "not reused, buying the read" "$T/br-p5b$case_.say" 2>/dev/null && ok || bad "P5b/$case_ the say line: $(cat "$T/br-p5b$case_.say" 2>/dev/null)"
done
# ---- P5c: a lead MERGE (cleared) is still reused
rb 0 lead MERGE approve
br_drive p5c no-verdict 0
[ ! -s "$T/br-p5c.rr" ] && grep -q ' WAIT_REVIEW ' "$T/br-p5c.tr" 2>/dev/null && ok \
  || bad "P5c a lead MERGE is reused: rr=$(cat "$T/br-p5c.rr" 2>/dev/null) tr=$(cat "$T/br-p5c.tr" 2>/dev/null)"
# a fallback BLOCK is still reused (D3)
rb 0 review-prs BLOCK block codex
br_drive p5d no-verdict 0
[ ! -s "$T/br-p5d.rr" ] && grep -q 'BLOCKED_HUMAN head-not-reapproved' "$T/br-p5d.tr" 2>/dev/null && ok \
  || bad "P5d a fallback block is reused: rr=$(cat "$T/br-p5d.rr" 2>/dev/null) tr=$(cat "$T/br-p5d.tr" 2>/dev/null)"

echo "review-reuse-provenance.bh-4134: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
