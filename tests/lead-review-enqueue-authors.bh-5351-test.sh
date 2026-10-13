#!/bin/bash
# tests/lead-review-enqueue-authors.bh-5351-test.sh — BH-5351 (BH-5348.2): the
# hub trigger, bin/lead-review-enqueue.sh, records who wrote the head it asks a
# lead review for, in head_authors. The tick runs WHOLE against a scratch
# harness carrying its real bin/lib closure (scratch_install_closure only).
# Stubbed:
#   * curl — the jobs worker: GET /api/verdict?pr= answers $T/jv/<n>.json
#            (missing = 404); GET /api/fix-rounds?project=demo-os&cap_key=
#            demo-os-BH-41&limit=500 answers $T/fr-key.json and
#            ?project=demo-os&limit=500 answers $T/fr-proj.json (a 503 for both
#            when $T/fr503 exists); POST /api/lead-reviews answers 201.
#   * gh   — the PR list (head ref ticket/bh-41), the single-PR read, a compare.
#   E1 head_authors = the build box, then the box and claimed_by of the fix
#      rounds whose cap_key names BH-41 (never BH-410), starts dqw-41-, or whose
#      args[3] is the PR url; trimmed, lowercased, de-duplicated. Both
#      fix-round queries use the existing filters only (no pr filter).
#   E2 the fix-round lookup answers 503: head_authors = the build box, and the
#      log names the failure.
#   E3 no identity at all (the build job names no box, no fix rounds): no
#      head_authors key, and the log says why; a 404 verdict read is driven
#      straight through head_authors_json.
#   E4 a truncated project list: what was read is sent, the log says incomplete.
#   E5 a participant build: job.box participant:mac-a and job.participant mac-a.
#   E6 over 16 identities: the first 16 are sent, the build identity first.
# Dispatcher section (BH-5874): gate 14, bin/lib/lead-gates.d/25-authors.sh,
# on the worklist. bin/lead-review.sh tick runs WHOLE over
# tests/lib/lead-worklist-fixture.bh-4956.sh; the head ref comes from the PR
# body gate 55 (55-snapshot.sh) read.
#   DA1 the build job names box-a, a fix round with cap_key demo-os-BH-12 was
#       claimed by box-b, the PR head ref is ticket/bh-12: the lead_review
#       job's meta.head_authors holds box-a and box-b.
#   DA2 the fix-round reads answer 500: the job still opens, head_authors
#       holds box-a, and the log names the failure.
#   DA3 no identity at all: the job opens with no head_authors key, and the
#       log says why.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-enqueue-authors.bh-5351-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin" "$H/state" "$H/logs" "$T/fakebin" "$T/log" "$T/tmp" "$T/cfg" "$T/jv" "$T/head"
for s in bin/lead-review-enqueue.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
[ -r "$H/bin/lib/lead-reviews.sh" ] || { echo "FAIL: the closure did not install bin/lib/lead-reviews.sh"; exit 1; }
[ -r "$H/bin/lib/jobs/jobs.sh" ] || { echo "FAIL: the closure did not install bin/lib/jobs/jobs.sh"; exit 1; }
printf 'lead-test-token-fixture\n' > "$T/cfg/token"; chmod 600 "$T/cfg/token"
printf 'demo-os example-org/demo-os https://demo.test /api 3 box-hub\n' > "$H/fleet.conf"
SHA=$(printf 'a%.0s' {1..40})
URL41="https://github.com/example-org/demo-os/pull/41"

cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/verdict?pr="*)
    n="\${p##*%2F}"
    if [ -f "$T/jv/\$n.json" ]; then out=\$(cat "$T/jv/\$n.json"); else code=404; out='{"error":"no job has recorded this PR"}'; fi ;;
  "GET /api/fix-rounds?project=demo-os&cap_key=demo-os-BH-41&limit=500")
    if [ -e "$T/fr503" ]; then code=503; out='{"error":"fix_round_jobs unavailable"}'; else out=\$(cat "$T/fr-key.json"); fi ;;
  "GET /api/fix-rounds?project=demo-os&limit=500")
    if [ -e "$T/fr503" ]; then code=503; out='{"error":"fix_round_jobs unavailable"}'; else out=\$(cat "$T/fr-proj.json"); fi ;;
  "GET /api/verdicts?"*) out='{"standing":null,"rows":[],"truncated":false}' ;;
  "POST /api/lead-reviews") code=201; out=\$(jq -c '{request:(. + {id:"lr-1", status:"requested"})}' <<<"\$body") ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"-X GET repos/example-org/demo-os/pulls?"*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$T/prs.json" ;;
  *"-X GET repos/example-org/demo-os/pulls/"*)
    a="\$*"; n="\${a##*/pulls/}"; n="\${n%% *}"
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "\$(cat "$T/head/\$n")" '{head:{sha:\$s,ref:"ticket/bh-41-r2"},base:{ref:"main"}}' ;;
  *"-X GET repos/example-org/demo-os/compare/"*)
    printf 'HTTP/2 200\r\n\r\n{"total_commits":1,"commits":[{"parents":[{"sha":"p"}],"commit":{"message":"feat: the thing"}}]}\n' ;;
esac
exit 0
EOF
for f in lane-alert.sh agent-call.sh; do printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"; done
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 LEAD_VERDICT_TOKEN_FILE="$T/cfg/token" \
  FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LEAD_REVIEW_AUTO_REPOS=example-org/demo-os \
  LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=5 LEAD_REVIEW_MAX_PER_PR_DAY=4
unset BOX_NAME JOBS_BOX HUB_BOX_NAME

# reset <job-json> — PR 41 at SHA on head ref ticket/bh-41, its builder APPROVE
#   on SHA from a job shaped <job-json>, and the fix rounds of E1
reset() {
  rm -f "$T/log"/* "$T/fr503" "$H/logs"/*
  scratch_rm "$H/state"; mkdir -p "$H/state"; echo box-hub > "$H/state/box-name"
  jq -nc --arg s "$SHA" '[{number:41, html_url:"https://github.com/example-org/demo-os/pull/41", title:"t", draft:false,
    state:"open", user:{login:"operator",type:"User"}, head:{sha:$s,ref:"ticket/bh-41-r2"}, base:{ref:"main"}}]' > "$T/prs.json"
  echo "$SHA" > "$T/head/41"
  jq -nc --arg s "$SHA" --argjson j "$1" '{verdict:"APPROVE", tier:"2", provenance:"-", merge_sha:null, job_id:"job-1", reviewed_sha:$s,
    job:$j, artifacts:[{artifact_kind:"verdict", detail:({tier:"2", headbound:"n/a", reviewed_sha:$s, settled:true}|tojson)}]}' > "$T/jv/41.json"
  echo '{"fix_round_jobs":[{"id":1,"cap_key":"demo-os-BH-41","box":"orgo-3","claimed_by":"orgo-3b"}],"truncated":false}' > "$T/fr-key.json"
  jq -nc --arg u "$URL41" '{fix_round_jobs:[
      {id:1, cap_key:"demo-os-BH-41", box:" ORGO-3 ", claimed_by:"orgo-3b"},
      {id:2, cap_key:"dqw-41-aaaaaaaaaaaa-ci", box:"orgo-4", claimed_by:null},
      {id:3, cap_key:"demo-os-BH-410", box:"orgo-9", claimed_by:"orgo-9b"},
      {id:4, cap_key:"dqw-410-bbbbbbbbbbbb-ci", box:"orgo-8", claimed_by:null},
      {id:5, cap_key:"resolver-x", box:"orgo-5", claimed_by:null, args:["demo-os","BH-7","blocked",$u,"rec","BH-7"]},
      {id:6, cap_key:"resolver-y", box:"orgo-7", claimed_by:null, args:["demo-os","BH-8","blocked",($u + "0"),"rec","BH-8"]}
    ], truncated:false}' > "$T/fr-proj.json"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review-enqueue.sh" tick ) > "$T/out" 2>&1; RC=$?; }
LOGF="$H/logs/lead-review-enqueue.log"
body() { sed -n 's#^POST /api/lead-reviews \(.*\)$#\1#p' "$T/log/worker" 2>/dev/null | head -1; }
posts() { grep -c '^POST /api/lead-reviews ' "$T/log/worker" 2>/dev/null || echo 0; }
authors() { jq -c '.head_authors // "ABSENT"' <<<"$(body)" 2>/dev/null; }
requested() { # requested <case>
  [ "$RC" -eq 0 ] && ok || bad "$1 rc=$RC $(cat "$T/out")"
  [ "$(posts)" = 1 ] && ok || bad "$1 want one POST: $(cat "$T/log/worker")"
}

# ── E1: the build box and the fix-round identities ──
reset '{"id":"job-1","box":"orgo-2"}'; tick
requested E1
[ "$(authors)" = '["orgo-2","orgo-3","orgo-3b","orgo-4","orgo-5"]' ] && ok || bad "E1 head_authors: $(body)"
grep -qF 'GET /api/fix-rounds?project=demo-os&cap_key=demo-os-BH-41&limit=500 ' "$T/log/worker" && ok \
  || bad "E1 no cap_key query: $(grep fix-rounds "$T/log/worker")"
grep -qF 'GET /api/fix-rounds?project=demo-os&limit=500 ' "$T/log/worker" && ok \
  || bad "E1 no project query: $(grep fix-rounds "$T/log/worker")"
grep -q 'fix-rounds?\(.*&\)\?pr[_=]' "$T/log/worker" && bad "E1 a pr filter reached the fix-rounds route" || ok
grep -q 'head_authors may be incomplete\|no head authorship' "$LOGF" && bad "E1 logged a failure on a good read: $(cat "$LOGF")" || ok

# ── E2: the fix-round lookup fails; the build identity still goes ──
reset '{"id":"job-1","box":"orgo-2"}'; touch "$T/fr503"; tick
requested E2
[ "$(authors)" = '["orgo-2"]' ] && ok || bad "E2 head_authors: $(body)"
grep -q 'example-org/demo-os#41: fix-round lookup (project=demo-os&limit=500) failed (rc 1); head_authors may be incomplete' "$LOGF" && ok \
  || bad "E2 log: $(cat "$LOGF")"

# ── E3: no identity at all: no head_authors, and the log says why ──
reset '{"id":"job-1"}'
echo '{"fix_round_jobs":[],"truncated":false}' > "$T/fr-key.json"; cp "$T/fr-key.json" "$T/fr-proj.json"; tick
requested E3
[ "$(authors)" = '"ABSENT"' ] && ok || bad "E3 head_authors was sent: $(body)"
grep -q 'example-org/demo-os#41: the build job names no box; head_authors has no build identity' "$LOGF" && ok || bad "E3 log (box): $(cat "$LOGF")"
grep -q "example-org/demo-os#41 @${SHA:0:12}: no head authorship (no build or fix-round identity was readable); requested without head_authors" "$LOGF" \
  && ok || bad "E3 log (request): $(cat "$LOGF")"
# No jobs row for the PR: job_verdict is rc 2 too, so the tick's own path is
# the unapproved replay; head_authors_json's 404 branch is driven straight.
reset '{"id":"job-1","box":"orgo-2"}'; rm -f "$T/jv/41.json"
echo '{"fix_round_jobs":[],"truncated":false}' > "$T/fr-key.json"; cp "$T/fr-key.json" "$T/fr-proj.json"
OUT=$(
  export HARNESS="$H"; LOG="$T/direct.log"; log() { echo "$*" >> "$LOG"; }
  # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh"
  eval "$(sed -n '/^head_authors_json() {/,/^}/p' "$H/bin/lead-review-enqueue.sh")"
  head_authors_json example-org/demo-os 41 ticket/bh-41 demo-os; echo "rc=$?")
[ "$OUT" = $'no build or fix-round identity was readable\nrc=1' ] && ok || bad "E3 404 verdict read: $OUT"
grep -q 'no build job recorded the PR' "$T/direct.log" && ok || bad "E3 404 not logged: $(cat "$T/direct.log" 2>/dev/null)"

# ── E4: a truncated project list ──
reset '{"id":"job-1","box":"orgo-2"}'
jq -c '.truncated = true | .fix_round_jobs |= .[:2]' "$T/fr-proj.json" > "$T/fr.tmp" && mv "$T/fr.tmp" "$T/fr-proj.json"; tick
requested E4
[ "$(authors)" = '["orgo-2","orgo-3","orgo-3b","orgo-4"]' ] && ok || bad "E4 head_authors: $(body)"
grep -q 'example-org/demo-os#41: fix-round list truncated; head_authors may be incomplete' "$LOGF" && ok || bad "E4 log: $(cat "$LOGF")"

# ── E5: a participant build ──
reset '{"id":"job-1","box":"participant:Mac-A","participant":"mac-a"}'; tick
requested E5
[ "$(jq -c '.[:2]' <<<"$(authors)")" = '["participant:mac-a","mac-a"]' ] && ok || bad "E5 head_authors: $(body)"

# ── E6: over 16 ──
reset '{"id":"job-1","box":"orgo-2"}'
jq -c '.fix_round_jobs = [range(1; 21) | {id:., cap_key:("demo-os-BH-41-" + (.|tostring)), box:("fx-" + (.|tostring)), claimed_by:null}]' \
  "$T/fr-proj.json" > "$T/fr.tmp" && mv "$T/fr.tmp" "$T/fr-proj.json"; tick
requested E6
[ "$(jq -c 'length, .[0]' <<<"$(authors)" | tr '\n' ' ')" = '16 "orgo-2" ' ] && ok || bad "E6 head_authors: $(body)"
grep -q 'example-org/demo-os#41: head_authors over 16; first 16 sent' "$LOGF" && ok || bad "E6 log: $(cat "$LOGF")"

# ═══════════ dispatcher section (BH-5874): gate 14 on the worklist ═══════════
T="$T/disp"; mkdir -p "$T"
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os"
[ -r "$H/bin/lib/lead-gates.d/25-authors.sh" ] && ok || bad "setup: the closure of bin/lead-review.sh did not install bin/lib/lead-gates.d/25-authors.sh"
# job_meta — the meta object of the one lead_review job POST for #101
job_meta() { grep '^POST /api/jobs .*"ticket_id":"lr-101-' "$T/log/worker" | sed 's/^POST \/api\/jobs //' | jq -c '.meta // empty | fromjson' 2>/dev/null; }
djobs() { lwf_cnt '^POST /api/jobs .*"ticket_id":"lr-101-' "$T/log/worker"; }
fixround() {
  jq -nc '{fix_round_jobs:[{cap_key:"demo-os-BH-12", box:"box-b", claimed_by:"box-b"},
    {cap_key:"demo-os-BH-120", box:"box-c", claimed_by:"box-c"}], truncated:false}' > "$FX/fixrounds.json"
}

# ── DA1: build box and fix-round claimer ──
lwf_reset; lwf_needs example-org/demo-os 101; lwf_bv 101 APPROVE "$SHA" "" box-a; fixround
echo ticket/bh-12 > "$FX/ref.101"
lwf_tick
[ "$(djobs)" = 1 ] && ok || bad "DA1 jobs=$(djobs) (want 1): $(cat "$L")"
au=$(job_meta | jq -c '.head_authors // empty | fromjson' 2>/dev/null)
[ "$au" = '["box-a","box-b"]' ] && ok || bad "DA1 head_authors='$au' (want [\"box-a\",\"box-b\"]): $(grep '^POST /api/jobs' "$T/log/worker")"
grep -q 'GET /api/fix-rounds?project=demo-os&cap_key=demo-os-BH-12&limit=500' "$T/log/worker" && ok || bad "DA1 no keyed fix-round read: $(grep fix-rounds "$T/log/worker")"

# ── DA2: the fix-round reads fail ──
lwf_reset; lwf_needs example-org/demo-os 101; lwf_bv 101 APPROVE "$SHA" "" box-a; : > "$FX/fixrounds.fail"
echo ticket/bh-12 > "$FX/ref.101"
lwf_tick
[ "$(djobs)" = 1 ] && ok || bad "DA2 jobs=$(djobs) (want 1): $(cat "$L")"
au=$(job_meta | jq -c '.head_authors // empty | fromjson' 2>/dev/null)
[ "$au" = '["box-a"]' ] && ok || bad "DA2 head_authors='$au' (want [\"box-a\"])"
grep -q 'example-org/demo-os#101: fix-round lookup (project=demo-os&limit=500) failed' "$L" && ok || bad "DA2 no failure line: $(cat "$L")"

# ── DA3: no identity at all ──
lwf_reset; lwf_needs example-org/demo-os 101
lwf_tick
[ "$(djobs)" = 1 ] && ok || bad "DA3 jobs=$(djobs) (want 1): $(cat "$L")"
job_meta | jq -e 'has("head_authors")' >/dev/null 2>&1 && bad "DA3 a head_authors key with no identity: $(job_meta)" || ok
grep -q "example-org/demo-os#101 @${SHA:0:12}: no head authorship (no build or fix-round identity was readable); the job carries no head_authors" "$L" \
  && ok || bad "DA3 no reason line: $(cat "$L")"

echo "lead-review-enqueue-authors.bh-5351: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
