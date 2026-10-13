#!/bin/bash
# tests/lead-review-body-change.bh-5888-test.sh — BH-5888: a stored lead review
# report is bound to the PR body it read. Every report carries a
# `- pr body: sha256:<16 hex>` header line (lr_body_fp). Before a replay (the
# job artifact first, the disk second) lr_report_body_ok compares it with the
# live body: same body = the BH-2202 replay, no agent call; another body = no
# replay, a real review that reads the new body. A report with no such line
# (written before BH-5888) is replayed as before. bin/lead-review.sh tick is run
# WHOLE against the scratch harness of tests/lead-review-lane.bh-2202-test.sh,
# with the artifact store of tests/lead-review-body-artifact.bh-2624-test.sh.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-body-change.bh-5888-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# fp <body> — the expected fingerprint, computed here, not by the lib
fp() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -c1-16)"; }
B1='Fixes the thing. Closes #1.'
B2=$'Fixes the thing. Closes #1.\n\nVerify: ran tests/x.sh, rc 0.'

# ── F: the helpers, sourced on their own ──
LIB="$DIR/bin/lib/lead-reviews.sh"
# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }
if ! declare -F lr_body_fp >/dev/null || ! declare -F lr_report_body_ok >/dev/null; then
  bad "F0 lr_body_fp / lr_report_body_ok are not defined in bin/lib/lead-reviews.sh"
else
  a=$(jq -nc --arg b "$B1" '{body:$b}' | lr_body_fp); b=$(jq -nc --arg b "$B1" '{body:$b}' | lr_body_fp)
  c=$(jq -nc --arg b "$B2" '{body:$b}' | lr_body_fp)
  [ "$a" = "$(fp "$B1")" ] && [ "$a" = "$b" ] && ok || bad "F1 same body: '$a' '$b' (want $(fp "$B1"))"
  [ "$c" = "$(fp "$B2")" ] && [ "$c" != "$a" ] && ok || bad "F1 changed body: '$c' vs '$a'"
  [ "$(echo '{"body":null}' | lr_body_fp)" = "$(fp '')" ] && ok || bad "F2 null body: $(echo '{"body":null}' | lr_body_fp)"
  [ "$(echo '{}' | lr_body_fp)" = "$(fp '')" ] && ok || bad "F2 missing body: $(echo '{}' | lr_body_fp)"
  R="$T/f.md"
  printf '# Lead review k (r#1 at s)\n\n- verdict: MERGE\n- reviewer model: m\n\nFindings\n- none\n' > "$R"
  lr_report_body_ok "$R" "$(fp "$B1")" && ok || bad "F3 a report with no pr body line is not ok"
  printf '# Lead review k (r#1 at s)\n\n- verdict: MERGE\n- reviewer model: m\n- pr body: %s\n\nFindings\n' "$(fp "$B1")" > "$R"
  lr_report_body_ok "$R" "$(fp "$B1")" && ok || bad "F3 a matching line is not ok"
  lr_report_body_ok "$R" "$(fp "$B2")" && bad "F3 a different line is ok" || ok
  printf 'Reviewer: x (enrolled machine)\n# Lead review k (r#1 at s)\n\n- verdict: MERGE\n- pr body: %s\n\nFindings\n' "$(fp "$B1")" > "$R"
  lr_report_body_ok "$R" "$(fp "$B2")" && bad "F3 a participant report with a different line is ok" || ok
  printf '# Lead review k (r#1 at s)\n\n- verdict: MERGE\n\nFindings\n- pr body: %s\n' "$(fp "$B2")" > "$R"
  lr_report_body_ok "$R" "$(fp "$B1")" && ok || bad "F4 a pr body line in the findings counted"
fi

# ── A3: one definition, no hash of its own in the lane (absent = a failure) ──
n=$(grep -rhc '^lr_body_fp()' "$DIR/bin" | awk '{s+=$1} END {print s+0}')
[ "$n" = 1 ] && ok || bad "A3 lr_body_fp defined $n times in bin/ (want 1)"
n=$(grep -rhc '^lr_report_body_ok()' "$DIR/bin" | awk '{s+=$1} END {print s+0}')
[ "$n" = 1 ] && ok || bad "A3 lr_report_body_ok defined $n times in bin/ (want 1)"
grep -q 'sha256sum' "$DIR/bin/lead-review.sh" && bad "A3 bin/lead-review.sh hashes the body itself" || ok
grep -q 'lr_report_body_ok' "$DIR/bin/lead-review.sh" && ok || bad "A3 bin/lead-review.sh never calls lr_report_body_ok"

# ── the lane harness (tests/lead-review-lane.bh-2202-test.sh) ──
H="$T/h"; mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
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
# The stub gh answers the live body from $T/livebody.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "\$(cat "$T/livehead")" --rawfile b "$T/livebody" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:\$b}' ;;
esac
exit 0
EOF
# The stub agent keeps each prompt: argv is <lane> <project> <model> <secs> <out> @<prompt>.
cat > "$H/bin/agent-call.sh" <<EOF2
#!/bin/bash
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
# A request with no created_at/reset_at: what a worklist item and the OBSERVED case carry.
setreq() { jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:41,head_sha:$s,scope_notes:"only the lane",prior_verdict_ref:"verdict-9",status:"requested"}],truncated:false}' > "$T/requests.json"; }
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
wlog() { cat "$T/log/worker" 2>/dev/null; }
has() { wlog | grep -qE "$1"; }
lg() { grep -qF "$1" "$LOGF" 2>/dev/null; }
# tick 1: head H, body B1, the BLOCK is written and its result post fails
tick1() { reset; : > "$T/result500"; tick
  [ "$(agents)" = 1 ] && ok || bad "$1 tick 1 agents=$(agents) (want 1) out=$(cat "$T/out")"
  grep -qxF -- "- pr body: $(fp "$B1")" "$REPORT" 2>/dev/null && ok || bad "$1 tick 1 report does not name body B1: $(head -n 8 "$REPORT" 2>/dev/null)"; }

# (A1) body B1 -> B2 on the same head, retake: a real review reads B2
tick1 A1
printf '%s' "$B2" > "$T/livebody"; retake
[ "$RC" -eq 0 ] && ok || bad "A1 retake rc=$RC out=$(cat "$T/out")"
[ "$(agents)" = 2 ] && ok || bad "A1 the body change was not reviewed: agents=$(agents) (want 2); log: $(tail -n 6 "$LOGF")"
grep -qF 'Verify: ran tests/x.sh' "$T/log/prompt.2" 2>/dev/null && ok || bad "A1 prompt 2 does not carry body B2"
grep -c 'Fixes the thing' "$T/log/prompt.2" 2>/dev/null | grep -qx 1 && ok || bad "A1 prompt 2 carries the body more than once (or not at all)"
has '/result .*"outcome":"done","verdict":"MERGE"' && ok || bad "A1 the new verdict was not posted: $(wlog | grep /result)"
has '/result .*"verdict":"BLOCK"' && bad "A1 the stale B1 BLOCK was posted" || ok
grep -qxF -- "- pr body: $(fp "$B2")" "$REPORT" && ok || bad "A1 the new report does not name body B2"
lg 'written against another PR body' && ok || bad "A1 no 'another PR body' log line: $(tail -n 6 "$LOGF")"
lg 'no agent call' && bad "A1 a replay was logged: $(grep 'no agent call' "$LOGF")" || ok

# (A1b) the stale report reaches the lane as the job artifact only (no disk report)
tick1 A1b
rm -f "$REPORT"; printf '%s' "$B2" > "$T/livebody"; retake
[ "$(agents)" = 2 ] && ok || bad "A1b the artifact for body B1 was replayed: agents=$(agents) (want 2)"
lg 'reusing artifact' && bad "A1b 'reusing artifact' logged" || ok
lg "artifact lead_review_report for lr-41-$SHA12 was written against another PR body" && ok || bad "A1b no artifact log line: $(tail -n 6 "$LOGF")"
has '/result .*"verdict":"MERGE"' && ok || bad "A1b result: $(wlog | grep /result)"

# (A1c) the stale report is on disk only (no artifact)
tick1 A1c
rm -f "$T/artifacts.json"; printf '%s' "$B2" > "$T/livebody"; retake
[ "$(agents)" = 2 ] && ok || bad "A1c the disk report for body B1 was replayed: agents=$(agents) (want 2)"
lg "report for lr-41-$SHA12 was written against another PR body; it gets a real review" && ok || bad "A1c no disk log line: $(tail -n 6 "$LOGF")"

# (A2) body unchanged, retake: the BH-2202 replay holds, no agent call
tick1 A2
retake
[ "$(agents)" = 1 ] && ok || bad "A2 the same body paid twice: agents=$(agents) (want 1)"
lg 'no agent call' && ok || bad "A2 no replay log line: $(tail -n 6 "$LOGF")"
has '/result .*"outcome":"done","verdict":"BLOCK"' && ok || bad "A2 the stored verdict was not posted: $(wlog | grep /result)"
# A2b: the same, from the disk (no artifact)
tick1 A2b
rm -f "$T/artifacts.json"; retake
[ "$(agents)" = 1 ] && ok || bad "A2b the same body paid twice (disk): agents=$(agents) (want 1)"
lg "reusing $REPORT for lr-41-$SHA12; no agent call" && ok || bad "A2b no disk replay line: $(tail -n 6 "$LOGF")"

# (A4) an old-format report (no pr body line) with a matching title is replayed
reset; mkdir -p "$H/state/lead-reviews"
printf '# Lead review lr-41-%s (example-org/demo-os#41 at %s)\n\n- verdict: MERGE-WITH-NOTES\n- host suite: exit 3 rc=3\n- reviewer model: old-model\n\nFindings\n- none\n\nVERDICT: MERGE-WITH-NOTES\n' \
  "$SHA12" "$SHA" > "$REPORT"
printf '%s' "$B2" > "$T/livebody"; tick
[ "$(agents)" = 0 ] && ok || bad "A4 an old-format report was not replayed: agents=$(agents) (want 0)"
has '/result .*"verdict":"MERGE-WITH-NOTES".*"reviewer_model":"old-model"' && ok || bad "A4 result: $(wlog | grep /result)"

echo "lead-review-body-change.bh-5888: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
