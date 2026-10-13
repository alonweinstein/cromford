#!/bin/bash
# tests/lead-report-transcript.bh-5915-test.sh — BH-5915: a lead review report
# that lr_detail cuts at the worker's 4000-unit artifact cap is also pushed WHOLE
# to the job's transcript ledger as source=lead_report, so the hub can read it
# with `bin/jobs-client.sh transcript-get <job> source=lead_report`.
#   P1/P2  bin/transcript-push.sh allows lead_report and still refuses others.
#   L1     bin/lead-review.sh tick, run whole, pushes a ~12000-unit report and
#          the hub read gives it back byte-equal; the artifact stays cut.
#   L2     a report that fits pushes nothing.
#   L3     a failed transcript push does not stop the review.
#   L4     the stored-artifact replay pushes nothing.
#   L5     the backfill command in the dated note, run verbatim, makes the row.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-report-transcript.bh-5915-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$H/env" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp"
# The agent stub goes in first: scratch_install_closure never overwrites it.
cat > "$H/bin/agent-call.sh" <<EOF2
#!/bin/bash
echo x >> "$T/log/agent-count"
cp "$T/answer" "\$5"
exit 0
EOF2
chmod +x "$H/bin/agent-call.sh"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh \
         bin/transcript-push.sh bin/transcript-scrub.sh bin/transcript-render.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "could not install $s"; exit 1; }
done
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
[ -f "$DIR/prompts/lead-review.md" ] && cp "$DIR/prompts/lead-review.md" "$H/prompts/"
[ -f "$DIR/prompts/lead-review-checklist.md" ] && cp "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
printf 'HARNESS_SECRET=fixture-secret-5915\n' > "$H/env/global.env"
echo box-demo > "$H/state/box-name"
cat > "$H/fleet.conf" <<'EOF'
# project repo prod board offset box
demo-os   example-org/demo-os   https://demo.test  /api/board 1 box-demo
EOF

mk_repo() { # mk_repo <project> <pr> <claude-md-body> -> prints the PR head sha
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

# ── the stub worker: artifacts upsert by kind (as in the BH-2624 suite), and a
# transcript POST is kept in transcript.json and served back by the index and
# the body read, the way routes/transcripts.js answers. tr500 makes the POST a 500.
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
  "GET /api/jobs/job-7/artifacts")
    out=\$(cat "$T/artifacts.json" 2>/dev/null || echo '{"artifacts":[]}') ;;
  "PUT /api/jobs/job-7/artifacts")
    printf '%s' "\$body" > "$T/artifact.put"
    cur=\$(cat "$T/artifacts.json" 2>/dev/null || echo '{"artifacts":[]}')
    jq -c --argjson b "\$body" '.artifacts |= ([.[] | select(.artifact_kind != \$b.artifact_kind)] + [\$b])' <<<"\$cur" > "$T/artifacts.json.n" \
      && mv "$T/artifacts.json.n" "$T/artifacts.json" ;;
  "POST /api/jobs/job-7/transcript")
    if [ -e "$T/tr500" ]; then code=500; out='{"error":"boom"}'
    else printf '%s' "\$body" > "$T/transcript.json"; out='{"transcript":{}}'; fi ;;
  "GET /api/jobs/job-7/transcripts")
    if [ -s "$T/transcript.json" ]; then
      out=\$(jq -c '{transcripts:[{phase_id:(.phase_id // 0),attempt:(.attempt // 1),stage:.stage,runner:.runner,source:.source,bytes:(.body|length)}]}' "$T/transcript.json")
    else out='{"transcripts":[]}'; fi ;;
  "GET /api/jobs/job-7/transcript?phase_id=0&attempt=100")
    if [ -s "$T/transcript.json" ]; then out=\$(jq -c '{transcript:{body:.body,source:.source,truncated:(.truncated // 0)}}' "$T/transcript.json")
    else code=404; out='{"error":"no transcript for this attempt"}'; fi ;;
  "PATCH /api/jobs/"*)
    s=\$(printf '%s' "\$body" | jq -r '.status // empty'); [ -n "\$s" ] && echo "\$s" > "$T/jobstate" ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$SHA" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:"PR body text"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="$H/env" HARNESS_SECRET=fixture-secret-5915 \
  JOBS_URL=https://jobs.test JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" \
  FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1 GH_ETAG=0 CLAUDE_PROJECTS_DIR="$T/no-sessions"
unset BOX_NAME JOBS_BOX JOB_ID JOB_PHASE_ID TRANSCRIPT_SOURCE LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S VERDICT_WINDOW_LINES _VP_WINDOW

jq -nc --arg s "$SHA" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:41,head_sha:$s,status:"requested"}],truncated:false}' > "$T/requests.json"
KEY="lr-41-$SHA12"
REPORT="$H/state/lead-reviews/$KEY.md"
LOGF="$H/logs/lead-review.log"
reset() {
  rm -f "${T:?}/log"/* "${T:?}"/{jobstate,tr500,artifacts.json,artifact.put,transcript.json,hub.body,hub.trunc} "$LOGF"
  scratch_rm "$H/state/lead-reviews"; scratch_rm "$H/state/model-routes"
}
tick() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
tr_posts() { wlog | grep -c '^POST /api/jobs/job-7/transcript ' ; }
det() { jq -r ".detail | fromjson | $1" "$T/artifact.put" 2>/dev/null; }
u16() { jq -r '.detail | explode | map(if . > 65535 then 2 else 1 end) | add' "$T/artifact.put"; }
hub_read() { # the hub's read: job_transcript_get_source, body and truncated flag to files
  ( . "$H/bin/jobs-client.sh"
    job_transcript_get_source job-7 lead_report > "$T/hub.body"; r=$?
    printf '%s' "$JOBS_TRANSCRIPT_TRUNCATED" > "$T/hub.trunc"; exit "$r" )
}
# long_answer: about 12000 UTF-16 units, astral characters, 15 BLOCK items with
# the last five far past unit 4000, ending in the lane's verdict line.
long_answer() {
  { printf 'Findings\n'
    for i in $(seq 1 15); do
      printf -- '- [BLOCK] a.txt:%s — item %s breaks é 😀\n' "$i" "$i"
      for j in $(seq 1 12); do printf -- '  context line %s.%s: the change reads the wrong field here 😀\n' "$i" "$j"; done
    done
    printf -- '- [BLOCK] a.txt:99 — the last finding, past the cap\n'
    printf '\nVERDICT: BLOCK\n'; } > "$T/answer"
}
short_answer() { printf 'Findings\n- [BLOCK] a.txt:2 — it breaks\n\nVERDICT: BLOCK\n' > "$T/answer"; }
units() { jq -Rs 'explode | map(if . > 65535 then 2 else 1 end) | add' "$1"; }

# ══ P1/P2: the allowlist in bin/transcript-push.sh ══════════════════════════
reset; printf '# a report\n- [BLOCK] x\n\nVERDICT: BLOCK\n' > "$T/p.md"
( JOB_ID=job-7 TRANSCRIPT_SOURCE=lead_report bash "$H/bin/transcript-push.sh" lead-review pipeline "" "$T/p.md" 7 ) >/dev/null 2>&1
[ "$(jq -r .source "$T/transcript.json" 2>/dev/null)" = lead_report ] && ok || bad "P1 source: $(cat "$T/transcript.json" 2>/dev/null | head -c 200)"
[ "$(jq -r .attempt "$T/transcript.json" 2>/dev/null)" = 100 ] && ok || bad "P1 attempt is not the reserved 100"
[ "$(jq -r 'has("phase_id")' "$T/transcript.json" 2>/dev/null)" = false ] && ok || bad "P1 carries a phase_id"
cmp -s <(jq -j .body "$T/transcript.json" 2>/dev/null) "$T/p.md" && ok || bad "P1 body is not the file byte for byte"
reset
( JOB_ID=job-7 TRANSCRIPT_SOURCE=evil bash "$H/bin/transcript-push.sh" lead-review pipeline "" "$T/p.md" ) >/dev/null 2>&1
[ "$(tr_posts)" = 0 ] && ok || bad "P2 TRANSCRIPT_SOURCE=evil pushed a body"
grep -q 'ignored TRANSCRIPT_SOURCE=evil' "$H/logs/transcripts.log" && ok || bad "P2 no refusal line in transcripts.log"

# ══ L1: a cut report reaches the hub whole ══════════════════════════════════
reset; long_answer; tick
[ "$RC" -eq 0 ] && ok || bad "L1 rc=$RC out=$(cat "$T/out")"
n=$(units "$REPORT" 2>/dev/null || echo 0)
[ "$n" -ge 11000 ] && [ "$n" -le 14000 ] && ok || bad "L1 fixture report is $n UTF-16 units (want about 12000)"
[ "$(jq -r .source "$T/transcript.json" 2>/dev/null)" = lead_report ] && ok || bad "L1 (a) no lead_report transcript: $(wlog | grep -c transcript)"
if hub_read; then ok; else bad "L1 (b) the hub read answered rc=$?"; fi
cmp -s "$T/hub.body" "$REPORT" && ok || bad "L1 (b) the hub copy is not the report byte for byte ($(wc -c < "$T/hub.body") vs $(wc -c < "$REPORT" 2>/dev/null))"
grep -qF -- '- [BLOCK] a.txt:99 — the last finding, past the cap' "$T/hub.body" && ok || bad "L1 (b) the last BLOCK item is missing on the hub"
[ "$(grep -c -- '- \[BLOCK\]' "$T/hub.body")" = 16 ] && ok || bad "L1 (b) BLOCK items on the hub: $(grep -c -- '- \[BLOCK\]' "$T/hub.body")"
[ "$(cat "$T/hub.trunc")" = 0 ] && ok || bad "L1 (c) JOBS_TRANSCRIPT_TRUNCATED=$(cat "$T/hub.trunc")"
[ "$(det .truncated)" = true ] && ok || bad "L1 (d) the artifact detail is not flagged truncated"
[ "$(u16)" -le 4000 ] && ok || bad "L1 (d) the artifact detail is $(u16) units"
grep -qF 'the last finding, past the cap' <<<"$(det .body)" && bad "L1 (d) the artifact now carries the whole report" || ok
grep -qF "full report for $KEY handed to transcript-push.sh as lead_report (job job-7)" "$LOGF" && ok || bad "L1 (e) no log line: $(tail -n 5 "$LOGF")"
order=$(wlog | awk '
  /^POST \/api\/jobs\/job-7\/transcript / {print "transcript"}
  /^PUT \/api\/jobs\/job-7\/artifacts / {print "artifact"}
  /^POST \/api\/lead-reviews\/lr-1\/result .*"outcome":"done"/ {print "result"}
  /^PATCH \/api\/jobs\/job-7 .*"status":"done"/ {print "done"}' | paste -sd' ')
[ "$order" = "transcript artifact result done" ] && ok || bad "L1 order '$order'"

# ══ L2: a report that fits is not stored twice ══════════════════════════════
reset; short_answer; tick
[ "$(cat "$T/jobstate")" = done ] && ok || bad "L2 job not done: $(cat "$T/jobstate" 2>/dev/null)"
[ "$(tr_posts)" = 0 ] && ok || bad "L2 a report that fits was pushed"
[ "$(det 'has("truncated")')" = false ] && ok || bad "L2 the artifact is flagged truncated"
grep -qF 'handed to transcript-push.sh' "$LOGF" && bad "L2 logged a push it did not make" || ok

# ══ L3: the push fails, the review still lands ══════════════════════════════
reset; long_answer; : > "$T/tr500"; tick
[ "$(tr_posts)" = 1 ] && ok || bad "L3 transcript POSTs: $(tr_posts) (want 1)"
[ "$(det .truncated)" = true ] && ok || bad "L3 the artifact was not put"
wlog | grep -q '^POST /api/lead-reviews/lr-1/result .*"outcome":"done"' && ok || bad "L3 no done result"
[ "$(cat "$T/jobstate")" = done ] && ok || bad "L3 job not done: $(cat "$T/jobstate" 2>/dev/null)"
hub_read && bad "L3 the hub read found a row after a failed push" || ok

# ══ L4: the stored-artifact replay pushes nothing ═══════════════════════════
reset
hdr=$(printf '# Lead review %s (example-org/demo-os#41 at %s)\n\n- verdict: BLOCK\n- host suite: exit 3 rc=3\n- reviewer model: old-model' "$KEY" "$SHA")
jq -nc --arg b "$hdr" --arg p "$REPORT" '{artifacts:[{artifact_kind:"lead_review_report",artifact_ref:$p,
  detail:({body:$b,path:$p,verdict:"BLOCK",truncated:true}|tojson)}]}' > "$T/artifacts.json"
tick
[ -f "$T/log/agent-count" ] && bad "L4 the replay paid an agent call" || ok
wlog | grep -q '^POST /api/lead-reviews/lr-1/result .*"outcome":"done","verdict":"BLOCK"' && ok || bad "L4 the replay posted no done result: $(wlog | grep /result)"
[ "$(tr_posts)" = 0 ] && ok || bad "L4 the replay pushed a transcript"

# ══ L5: the backfill command in the dated note, verbatim ════════════════════
reset; long_answer; mkdir -p "$H/state/lead-reviews"
{ printf '# Lead review %s (example-org/demo-os#41 at %s)\n\n' "$KEY" "$SHA"; cat "$T/answer"; } > "$REPORT"
NOTE="$DIR/docs/notes/2026-10-10-BH-5915-lead-report-transcript.md"
cmd=$(grep -m1 '^JOB_ID=<job> TRANSCRIPT_SOURCE=lead_report ' "$NOTE" 2>/dev/null)
[ -n "$cmd" ] && ok || bad "L5 the note carries no backfill command"
cmd=${cmd//<job>/job-7}; cmd=${cmd//<key>/$KEY}
( cd "$H" && bash -c "$cmd" ) >/dev/null 2>&1   # the documented text itself, run from the harness root
[ "$(jq -r .source "$T/transcript.json" 2>/dev/null)" = lead_report ] && ok || bad "L5 the backfill made no lead_report row"
hub_read >/dev/null 2>&1; cmp -s "$T/hub.body" "$REPORT" && ok || bad "L5 the backfilled body is not the report"

echo "lead-report-transcript.bh-5915: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
