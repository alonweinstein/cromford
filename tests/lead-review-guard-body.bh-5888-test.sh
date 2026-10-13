#!/bin/bash
# tests/lead-review-guard-body.bh-5888-test.sh — BH-5888 (re-plan 2): the paid
# lead call's K=1 guard key names the PR body when the lane knows the body
# changed since the stored review of this head. A body-only fix on one head is
# then paid once more (`lead:<slug>#<n>@<sha>~body<D>`, the unknown-verdict
# retry `~nvbody<D>`), and the same head and body is never paid twice. With no
# body change seen, the key stays `lead:<slug>#<n>@<sha>` (BH-3930). The stub
# agent-call.sh here emulates the guard: a key it already paid exits 74, as
# bin/lib/call-guard.sh does at lead-head=1. bin/lead-review.sh tick is run
# WHOLE against the scratch harness of tests/lead-review-body-change.bh-5888-test.sh.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-guard-body.bh-5888-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# fp <body> / reason <body> [nv] — the expected values, computed here, not by the lib
fp() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -c1-16)"; }
reason() { local f; f=$(fp "$1"); printf '%sbody%s' "${2:-}" "$((16#${f:7:12}))"; }
B1='Fixes the thing. Closes #1.'
B2=$'Fixes the thing. Closes #1.\n\nVerify: ran tests/x.sh, rc 0.'

# ── R: the helper, sourced on its own ──
# shellcheck source=/dev/null
. "$DIR/bin/lib/lead-reviews.sh" || { echo "FAIL: cannot source bin/lib/lead-reviews.sh"; exit 1; }
# shellcheck source=/dev/null
. "$DIR/bin/lib/review-bought.sh" || { echo "FAIL: cannot source bin/lib/review-bought.sh"; exit 1; }
FX=0123456789abcdef0123456789abcdef01234567
if ! declare -F lr_body_reason >/dev/null; then
  bad "R0 lr_body_reason is not defined in bin/lib/lead-reviews.sh"
else
  [ "$(lr_body_reason sha256:000000000001ffff)" = body1 ] && ok || bad "R1 low vector: '$(lr_body_reason sha256:000000000001ffff)'"
  v=$(lr_body_reason sha256:ffffffffffff0000)
  [ "$v" = body281474976710655 ] && [ "${#v}" = 19 ] && ok || bad "R1 high vector: '$v'"
  v=$(lr_body_reason sha256:ffffffffffff0000 nv)
  [ "$v" = nvbody281474976710655 ] && [ "${#v}" = 21 ] && ok || bad "R1 nv vector: '$v'"
  for b in "" "sha256:XYZ" "sha256:0123456789abcde" "sha256:0123456789ABCDEF" "0123456789abcdef"; do
    v=$(lr_body_reason "$b"); rc=$?
    [ "$rc" = 1 ] && [ -z "$v" ] && ok || bad "R2 bad fp '$b': rc=$rc out='$v'"
  done
  # R3: lead_fp output for four bodies through the review-paid-unchanged.sh regex
  big=$(head -c 65536 /dev/zero | tr '\0' 'a'); crlf=$'line one\r\nline two\r\n'
  : > "$T/r3.fps"
  for b in "" "$B1" "$big" "$crlf"; do
    f=$(jq -nc --arg b "$b" '{body:$b}' | lr_body_fp)
    for nv in "" nv; do
      r=$(lr_body_reason "$f" $nv)
      [ "${#r}" -le 24 ] && ok || bad "R3 reason '$r' longer than 24"
      printf '%s\t%s\n' "${nv}body" "$(HARNESS="$T/r4" lead_fp o/r 41 "$FX" "$r")" >> "$T/r3.fps"
    done
  done
  re=$(grep -A1 '^FP = re.compile' "$DIR/bin/review-paid-unchanged.sh")
  [ -n "$re" ] && ok || bad "R3 no FP regex in bin/review-paid-unchanged.sh"
  out=$(python3 -I -c "import re,sys
$re
for line in open(sys.argv[1]):
    want, k = line.rstrip('\n').split('\t')
    m = FP.match(k)
    got = m.group(3).rstrip('0123456789') if m and m.group(3) else None
    print('ok' if got == want else 'bad %s -> %s' % (k, got))" "$T/r3.fps" 2>&1)
  [ "$(grep -c '^ok$' <<<"$out")" = 8 ] && ok || bad "R3 regex round trip: $out"
  # R4: lead_fp keeps the reason, and _rb_fp drops nothing
  f=$(fp "$B2"); v=$(HARNESS="$T/r4" lead_fp o/r 41 "$FX" "$(lr_body_reason "$f")")
  [ "$v" = "lead:o/r#41@$FX~$(reason "$B2")" ] && ok || bad "R4 lead_fp: '$v'"
  grep -q 'dropped bad fp reason' "$T/r4/logs/review-bought.log" 2>/dev/null && bad "R4 _rb_fp dropped a reason: $(cat "$T/r4/logs/review-bought.log")" || ok
fi

# ── A3: one definition, no hex arithmetic in the lane (absent = a failure) ──
n=$(grep -rhc '^lr_body_reason()' "$DIR/bin" | awk '{s+=$1} END {print s+0}')
[ "$n" = 1 ] && ok || bad "A3 lr_body_reason defined $n times in bin/ (want 1)"
grep -q '16#' "$DIR/bin/lead-review.sh" && bad "A3 bin/lead-review.sh computes the reason itself" || ok

# ── the lane harness (tests/lead-review-body-change.bh-5888-test.sh) ──
H="$T/h"; mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
# Without review-bought.sh the lane has no lead_fp, the key is empty and every
# case below is vacuous.
[ -f "$H/bin/lib/review-bought.sh" ] || { echo "FAIL: bin/lib/review-bought.sh is not in the closure of bin/lead-review.sh"; exit 1; }
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
[ -f "$DIR/prompts/lead-review.md" ] && cp "$DIR/prompts/lead-review.md" "$H/prompts/"
[ -f "$DIR/prompts/lead-review-checklist.md" ] && cp "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
cat > "$H/fleet.conf" <<'EOF'
# project repo prod board offset box
demo-os   example-org/demo-os   https://demo.test  /api/board 1 box-demo
EOF
mk_repo() {
  local p="$1" pr="$2" o="$T/origin/$1.git" w="$T/work/$1"
  git init -q --bare -b main "$o"; git init -q -b main "$w"
  printf '%s\n' "$3" > "$w/CLAUDE.md"; echo one > "$w/a.txt"
  git -C "$w" add -A; git -C "$w" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$w" push -q "$o" main
  echo two >> "$w/a.txt"; git -C "$w" -c user.email=t@t -c user.name=t commit -qam "pr change"
  git -C "$w" push -q "$o" "HEAD:refs/pull/$pr/head"
  git clone -q "$o" "$T/repos/$p"
  git -C "$w" rev-parse HEAD
}
SHA=$(mk_repo demo-os 41 $'# demo\n\n## Verification Contract\n\n```bash\nexit 3\n```\n')
SHA12=${SHA:0:12}
PLAIN="lead:example-org/demo-os#41@$SHA"

# ── the stub worker: artifacts are kept by kind (bh-2624), served back on GET ──
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/requests.json") ;;
  "POST /api/jobs")
    st=\$(cat "$T/jobstate" 2>/dev/null)
    if [ "\$st" = running ]; then code=409; out='{"job":{"id":"job-7","box":"box-other"}}'
    else echo running > "$T/jobstate"; out='{"job":{"id":"job-7"}}'; fi ;;
  "GET /api/jobs/job-7/artifacts") out=\$(cat "$T/artifacts.json" 2>/dev/null || echo '{"artifacts":[]}') ;;
  "PUT /api/jobs/job-7/artifacts")
    cur=\$(cat "$T/artifacts.json" 2>/dev/null || echo '{"artifacts":[]}')
    jq -c --argjson b "\$body" '.artifacts |= ([.[] | select(.artifact_kind != \$b.artifact_kind)] + [\$b])' <<<"\$cur" > "$T/artifacts.json.n" \
      && mv "$T/artifacts.json.n" "$T/artifacts.json" ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "POST /api/lead-reviews/"*/result) [ -e "$T/result500" ] && { code=500; out='{"error":"boom"}'; } ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" --rawfile b "$T/livebody" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:\$b}' ;;
esac
exit 0
EOF
# The stub agent is the K=1 guard: every call logs "<stage> <fp>" to agent-fp; a
# fp already in paid exits 74 with no output (nothing billed). Otherwise the fp
# is paid, the prompt kept as prompt.<n> and answer.<n> (else answer) returned.
# argv is <lane> <project> <model> <secs> <out> @<prompt>.
cat > "$H/bin/agent-call.sh" <<EOF2
#!/bin/bash
echo "\${AGENT_CALL_GUARD_STAGE:-} \${AGENT_CALL_FP:-}" >> "$T/log/agent-fp"
[ -n "\${AGENT_CALL_FP:-}" ] && grep -qxF -- "\$AGENT_CALL_FP" "$T/log/paid" 2>/dev/null && exit 74
printf '%s\n' "\${AGENT_CALL_FP:-}" >> "$T/log/paid"
echo x >> "$T/log/agent-count"; n=\$(wc -l < "$T/log/agent-count")
cp "\${6#@}" "$T/log/prompt.\$n"
if [ -f "$T/answer.\$n" ]; then cp "$T/answer.\$n" "\$5"; else cp "$T/answer" "\$5"; fi
exit 0
EOF2
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW

LOGF="$H/logs/lead-review.log"
REPORT="$H/state/lead-reviews/lr-41-$SHA12.md"
STARTED="$H/state/lead-review/started.tsv"
# setreq [jq filter] — the one request, with no created_at/reset_at unless the filter adds them
setreq() { jq -nc --arg s "$SHA" "{requests:[({id:\"lr-1\",repo:\"example-org/demo-os\",pr:41,head_sha:\$s,scope_notes:\"only the lane\",prior_verdict_ref:\"verdict-9\",status:\"requested\"} | ${1:-.})],truncated:false}" > "$T/requests.json"; }
reset() {
  rm -f "${T:?}/log"/* "${T:?}"/{jobstate,result500,artifacts.json,answer.*} "$LOGF"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/model-routes"; scratch_rm "$H/state/lead-review"
  echo "$SHA" > "$T/livehead"; printf '%s' "$B1" > "$T/livebody"; setreq
  printf 'Findings\n- [BLOCK] the PR body has no verify evidence\n\nVERDICT: BLOCK\n' > "$T/answer.1"
  printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$T/answer"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
retake() { rm -f "${T:?}/result500" "${T:?}/log/worker"; echo queued_for_retry > "$T/jobstate"; tick; }
agents() { [ -f "$T/log/agent-count" ] && wc -l < "$T/log/agent-count" | tr -d ' ' || echo 0; }
fpline() { sed -n "${1}p" "$T/log/agent-fp" 2>/dev/null; }
fps() { [ -f "$T/log/agent-fp" ] && wc -l < "$T/log/agent-fp" | tr -d ' ' || echo 0; }
starts() { [ -f "$STARTED" ] && wc -l < "$STARTED" | tr -d ' ' || echo 0; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
has() { wlog | grep -qE "$1"; }
lg() { grep -qF "$1" "$LOGF" 2>/dev/null; }
# tick 1: head H, body B1, a BLOCK report on the plain key; [500] = the post fails
tick1() { reset; [ "${2:-}" = 500 ] && : > "$T/result500"; tick
  [ "$(agents)" = 1 ] && ok || bad "$1 tick 1 agents=$(agents) (want 1) out=$(cat "$T/out")"
  [ "$(fpline 1)" = "lead-head $PLAIN" ] && ok || bad "$1 tick 1 key '$(fpline 1)' (want lead-head $PLAIN)"
  grep -qxF -- "- pr body: $(fp "$B1")" "$REPORT" 2>/dev/null && ok || bad "$1 tick 1 report does not name body B1"; }
# the asserts every reviewed body change shares: one new paid call under the B2 key, reading B2
paid_b2() {
  [ "$(fpline 2)" = "lead-head $PLAIN~$(reason "$B2")" ] && ok || bad "$1 2nd key '$(fpline 2)' (want lead-head $PLAIN~$(reason "$B2")); log: $(tail -n 6 "$LOGF")"
  [ "$(agents)" = 2 ] && ok || bad "$1 agents=$(agents) (want 2); log: $(tail -n 6 "$LOGF")"
  grep -qF 'Verify: ran tests/x.sh' "$T/log/prompt.2" 2>/dev/null && ok || bad "$1 prompt 2 does not carry body B2"
  has '/result .*"outcome":"done","verdict":"MERGE"' && ok || bad "$1 the new verdict was not posted: $(wlog | grep /result)"
  grep -qxF -- "- pr body: $(fp "$B2")" "$REPORT" 2>/dev/null && ok || bad "$1 the new report does not name body B2"
  lg 'agent-call refused' && bad "$1 refused: $(grep 'agent-call refused' "$LOGF")" || ok
  lg "body changed since the stored review of lr-41-$SHA12; guard key $PLAIN~$(reason "$B2")" && ok || bad "$1 no guard key log line"
  [ "$(starts)" = 2 ] && ok || bad "$1 started.tsv has $(starts) lines (want 2, one per paid call)"
}

# (G1) the #5824 shape: B1 BLOCK, the body is fixed, the request is reset after
# the report was written. The disk report is the only evidence (no artifact).
tick1 G1
touch -d '-1 hour' "$REPORT"; rm -f "$T/artifacts.json" "$T/log/worker" "$T/jobstate"
printf '%s' "$B2" > "$T/livebody"
setreq ".reset_at=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | .reset_count=1"
tick
[ "$RC" -eq 0 ] && ok || bad "G1 rc=$RC out=$(cat "$T/out")"
paid_b2 G1
lg 'was written against another PR body' && ok || bad "G1 no 'another PR body' line: $(tail -n 6 "$LOGF")"

# (G2) B1 BLOCK whose post failed, the body is fixed, a retake (no reset), disk only
tick1 G2 500
rm -f "$T/artifacts.json"; printf '%s' "$B2" > "$T/livebody"; retake
paid_b2 G2
# (G4) the same head and body B2 again: the B2 report is replayed, no call
retake
[ "$(agents)" = 2 ] && [ "$(fps)" = 2 ] && ok || bad "G4 the same body paid again: agents=$(agents) calls=$(fps)"
lg 'no agent call' && ok || bad "G4 no replay line: $(tail -n 4 "$LOGF")"

# (G3) the stale report is the job artifact only (no disk report)
tick1 G3 500
rm -f "$REPORT"; printf '%s' "$B2" > "$T/livebody"; retake
paid_b2 G3
lg "artifact lead_review_report for lr-41-$SHA12 was written against another PR body" && ok || bad "G3 no artifact line"

# (G5) a body change whose first answer has no verdict: the retry is ~nvbody<D>
tick1 G5 500
rm -f "$T/artifacts.json"; printf '%s' "$B2" > "$T/livebody"
printf 'no verdict here\n' > "$T/answer.2"; retake
[ "$(fpline 2)" = "lead-head $PLAIN~$(reason "$B2")" ] && ok || bad "G5 2nd key '$(fpline 2)'"
[ "$(fpline 3)" = "lead-head $PLAIN~$(reason "$B2" nv)" ] && ok || bad "G5 retry key '$(fpline 3)' (want ~$(reason "$B2" nv))"
[ "$(agents)" = 3 ] && ok || bad "G5 agents=$(agents) (want 3)"
has '/result .*"outcome":"done","verdict":"MERGE"' && ok || bad "G5 result: $(wlog | grep /result)"

# (G6) an old-format report (no pr body line) with a matching title is replayed
reset; mkdir -p "$H/state/lead-reviews"
printf '# Lead review lr-41-%s (example-org/demo-os#41 at %s)\n\n- verdict: MERGE-WITH-NOTES\n- host suite: exit 3 rc=3\n- reviewer model: old-model\n\nFindings\n- none\n\nVERDICT: MERGE-WITH-NOTES\n' \
  "$SHA12" "$SHA" > "$REPORT"
printf '%s' "$B2" > "$T/livebody"; tick
[ "$(agents)" = 0 ] && [ "$(fps)" = 0 ] && ok || bad "G6 an old-format report was not replayed: agents=$(agents)"

# (G7) the first review of a head: the plain BH-3930 key, no guard key log line
reset; tick
[ "$(fpline 1)" = "lead-head $PLAIN" ] && ok || bad "G7 key '$(fpline 1)' (want lead-head $PLAIN)"
lg 'body changed since' && bad "G7 a body change was logged on a first review" || ok

# (G8) the B2 key was paid already (say, on another box): the call is refused
# rc 74, nothing is billed or counted, and the request is left for the next tick
tick1 G8 500
echo "$PLAIN~$(reason "$B2")" >> "$T/log/paid"
rm -f "$T/artifacts.json"; printf '%s' "$B2" > "$T/livebody"; retake
[ "$(fpline 2)" = "lead-head $PLAIN~$(reason "$B2")" ] && ok || bad "G8 2nd key '$(fpline 2)'"
[ "$(agents)" = 1 ] && ok || bad "G8 the paid key was paid twice: agents=$(agents)"
[ "$(grep -cxF "$PLAIN~$(reason "$B2")" "$T/log/paid")" = 1 ] && ok || bad "G8 paid count for the B2 key is not 1"
lg "agent-call refused lr-41-$SHA12 (rc=74, nothing billed)" && ok || bad "G8 no refusal line: $(tail -n 4 "$LOGF")"
[ "$(starts)" = 1 ] && ok || bad "G8 a refused call was counted: started.tsv has $(starts) lines"
has '/result ' && bad "G8 a result was posted: $(wlog | grep /result)" || ok

echo "lead-review-guard-body.bh-5888: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
