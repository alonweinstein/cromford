#!/bin/bash
# tests/lead-review-participant.bh-5351-test.sh — BH-5351 (BH-5348.2): the lead
# review lane holds its claim with a heartbeat, and on an enrolled machine
# (HARNESS_PARTICIPANT_TOKEN_FILE readable) runs in participant mode. The tick
# runs WHOLE (bin/lead-review.sh tick) against a scratch harness carrying its
# real bin/lib closure; stubbed are curl (the jobs worker), gh (REST reads),
# df and /proc/meminfo (box room) and bin/agent-call.sh, which sleeps
# $T/sleep seconds and answers VERDICT: MERGE.
#   LP1 participant mode: the claim carries x-participant-token from a `-H @file`
#       header file; the token is never on curl's argv and the file is gone after.
#   LP2 a slow review (agent sleeps 5s) with stale_s=6 and LR_BEAT_MIN_S=1 (an
#       interval of 2s) posts >= 2 heartbeats for that request and job.
#   LP3 whoami knobs {"LEAD_REVIEW_CONCURRENCY":2,"LEAD_REVIEW_DEADLINE_S":120}
#       -> the summary says concurrency=2 and the knob line names both;
#       knobs {} keeps the lane's own value (3), and so does a junk value.
#   LP4 no token file: no x-participant-token in any request, no whoami call,
#       and the box still heartbeats its claim.
#   LP5 the participant report has `Reviewer: mac-b (enrolled machine)` on
#       line 1 and the title on line 2; a box report starts with the title.
#   LP6 after the tick no heartbeat loop is left running.
#   LP7 whoami 403: `participant whoami failed`, no claim.
#   LP8 lr_heartbeat, lr_whoami and lr_report_title, called straight from
#       bin/lib/lead-reviews.sh.
#   LP10 `one <id>` (the in-build review, BH-5023) heartbeats its claim too.
#   LP9 a retried participant tick reuses its own report on disk (the replay
#       guard reads the title under the Reviewer line): no second agent call.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-participant.bh-5351-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-4956: these cases review one PR more than the per-PR-day tripwire allows
# (LEAD_REVIEW_MAX_PER_PR_DAY, default 4, state/lead-review/started.tsv).
export LEAD_REVIEW_MAX_PER_PR_DAY=50
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }

TOKEN="ptok-bh5351-lead-review-participant-secret"
H="$T/h"
mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp" "$T/jobs"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "closure install of $s failed"; exit 1; }
done
[ -r "$H/bin/lib/lead-reviews.sh" ] || { echo "FAIL: the closure did not install bin/lib/lead-reviews.sh"; exit 1; }
[ -r "$H/bin/lib/jobs/jobs.sh" ] || { echo "FAIL: the closure did not install bin/lib/jobs/jobs.sh"; exit 1; }
cp "$SRC/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$H/prompts/"
# The owner column names box-demo; participant mode runs as another name.
printf 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$H/fleet.conf"
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo call >> "$T/agent.calls"
sleep "\$(cat "$T/sleep")"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"

O="$T/origin/demo-os.git"; W="$T/work/demo-os"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# demo\n\nNo contract here.\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" -c user.email=t@t -c user.name=t commit -qm base; git -C "$W" push -q "$O" main
echo two >> "$W/a.txt"; git -C "$W" -c user.email=t@t -c user.name=t commit -qam "pr change"
SHA=$(git -C "$W" rev-parse HEAD)
for n in 71 72 73 74; do git -C "$W" push -q "$O" "HEAD:refs/pull/$n/head"; done
git clone -q "$O" "$T/repos/demo-os"

# The jobs worker. Every call is one line of $T/log/worker; its argv goes to
# $T/log/argv, and a `-H @file` header file is copied to $T/log/hdr.<n> with its
# path in $T/log/hdrpaths (so the test can see it is gone afterwards).
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""; hdrs=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; -H) case "\$a" in @*) hdrs="\$hdrs \${a#@}" ;; esac ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
(
  flock 9
  printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker"
  printf '%s\n' "\$*" >> "$T/log/argv"
  for f in \$hdrs; do
    n=\$(wc -l < "$T/log/hdrpaths" 2>/dev/null || echo 0); n=\$((n + 1))
    printf '%s\n' "\$f" >> "$T/log/hdrpaths"; { printf '%s %s\n' "\$m" "\$p"; cat "\$f"; } > "$T/log/hdr.\$n"
  done
) 9>"$T/worker.lock"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews/r-"*) out=\$(jq -c '{request:.[0]}' "$T/rows.json") ;;
  "GET /api/lead-reviews"*) out=\$(jq -c '{requests:., truncated:false}' "$T/rows.json") ;;
  "GET /api/participants/whoami") code=\$(cat "$T/whoami.code"); out=\$(cat "$T/whoami.json") ;;
  "GET /api/settings/lead_review_claim_stale_s")
    if [ -s "$T/stale" ]; then out=\$(jq -nc --arg v "\$(cat "$T/stale")" '{setting:{key:"lead_review_claim_stale_s",value:\$v}}')
    else code=404; out='{"error":"no such setting"}'; fi ;;
  "POST /api/jobs")
    k=\$(printf '%s' "\$body" | jq -r '.ticket_id')
    if mkdir "$T/jobs/\$k" 2>/dev/null; then out=\$(jq -nc --arg k "\$k" '{job:{id:("job-" + \$k)}}')
    else code=409; out='{"job":{"id":"job-x","box":"box-other"}}'; fi ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
  "GET /api/metrics/llm-spend"*) out='{"usd":0}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
a="\$*"
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls\ .*page=([0-9]+) ]]; then
  printf 'HTTP/2 200\r\n\r\n'
  if [ "\${BASH_REMATCH[1]}" = 1 ]; then jq -nc --arg s "$SHA" '[range(71; 75) | {number:., head:{sha:\$s}, labels:[]}]'; else echo '[]'; fi
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls/([0-9]+) ]]; then
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg s "$SHA" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}'
  exit 0
fi
exit 0
EOF
cat > "$T/fakebin/df" <<'EOF'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 999999999 1 104857600 1%% /tmp\n'
EOF
printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$T/meminfo"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/df"
printf '%s\n' "$TOKEN" > "$T/ptoken"; chmod 600 "$T/ptoken"

export PATH="$T/fakebin:$PATH" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=60 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S LEAD_REVIEW_MAX_PAGES PR_SNAPSHOT HOTFIX_LABEL HOTFIX_LANE
unset LEAD_REVIEW_CONCURRENCY LEAD_REVIEW_BOX_MAX LEAD_REVIEW_TMP_MIN_MB LLM_USD_CAP_DAY REVIEW_POOL_TMP_PATH
unset HARNESS_PARTICIPANT_TOKEN_FILE LR_BEAT_MIN_S

rows() { # rows <pr>... -> $T/rows.json, one requested row per PR
  local n i=0 out='[]'
  for n in "$@"; do
    out=$(jq -c --arg n "$n" --arg s "$SHA" --argjson i "$i" \
      '. + [{id:("r-" + $n), repo:"example-org/demo-os", pr:($n|tonumber), head_sha:$s, status:"requested",
             created_at:("2026-10-08 05:00:0" + ($i|tostring)), scope_notes:null}]' <<<"$out")
    i=$((i + 1))
  done
  printf '%s\n' "$out" > "$T/rows.json"
}
# reset <box-name> — clean logs, jobs and reports; whoami answers mac-b with no knobs
reset() {
  rm -f "$T/log"/* "$T/stale" "$T/agent.calls" "$H/logs/lead-review.log"
  scratch_rm "$T/jobs"; mkdir -p "$T/jobs"; scratch_rm "$H/state/lead-reviews"
  echo "$1" > "$H/state/box-name"
  echo 0 > "$T/sleep"; echo 200 > "$T/whoami.code"
  echo '{"id":"pm-1","name":"mac-b","status":"approved","granted_roles":["lead-review"],"knobs":{}}' > "$T/whoami.json"
  rows 71
}
tick() { ( cd "$T" && HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
L="$H/logs/lead-review.log"
summary() { grep ' tick seen=' "$L" 2>/dev/null | tail -1; }
cnt() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
REPORT="$H/state/lead-reviews/lr-71-${SHA:0:12}.md"
beaters() { pgrep -f "$H/bin/lead-review.sh" 2>/dev/null | wc -l | tr -d ' '; }
# Bounded wait for the tick's beater processes to be gone (up to 5s).
settle() { local i; for i in $(seq 1 50); do [ "$(beaters)" = 0 ] && return 0; sleep 0.1; done; return 1; }
# Watch the heartbeat count for 3s and return 1 the moment it moves.
beats_hold() { local i; for i in $(seq 1 30); do [ "$(cnt '/heartbeat' "$T/log/worker")" = "$1" ] || return 1; sleep 0.1; done; }

# ── LP1 + LP5 + LP6: participant mode, header file, report line ──
reset mac-b-host
HARNESS_PARTICIPANT_TOKEN_FILE="$T/ptoken" LEAD_REVIEW_MAX_PER_TICK=5 tick
[ "$RC" -eq 0 ] && ok || bad "LP1 rc=$RC $(cat "$T/out")"
[ "$(cnt '^GET /api/participants/whoami' "$T/log/worker")" = 1 ] && ok || bad "LP1 want one whoami: $(cat "$T/log/worker")"
[ "$(cnt '^POST /api/lead-reviews/r-71/claim' "$T/log/worker")" = 1 ] && ok || bad "LP1 the owned-by-clone request was not claimed: $(cat "$L")"
CH=$(grep -l '^POST /api/lead-reviews/r-71/claim' "$T/log"/hdr.* 2>/dev/null | head -1)
[ -n "$CH" ] && grep -qx "x-participant-token: $TOKEN" "$CH" && ok || bad "LP1 the claim carried no x-participant-token header file"
grep -q "$TOKEN" "$T/log/argv" && bad "LP1 the participant token reached curl's argv" || ok
left=0; while read -r f; do [ -e "$f" ] && left=$((left + 1)); done < <(cat "$T/log/hdrpaths" 2>/dev/null)
[ "$left" = 0 ] && ok || bad "LP1 $left header file(s) left behind"
grep -q "$TOKEN" "$L" "$T/out" && bad "LP1 the token was logged" || ok
[ "$(sed -n 1p "$REPORT" 2>/dev/null)" = "Reviewer: mac-b (enrolled machine)" ] && ok || bad "LP5 line 1: $(sed -n 1p "$REPORT" 2>/dev/null)"
[ "$(sed -n 2p "$REPORT" 2>/dev/null)" = "# Lead review lr-71-${SHA:0:12} (example-org/demo-os#71 at $SHA)" ] && ok || bad "LP5 line 2: $(sed -n 2p "$REPORT" 2>/dev/null)"
grep -q 'participant mode as mac-b' "$L" && ok || bad "LP1 no participant mode line: $(cat "$L")"
[[ "$(summary)" == *" done=1 "* ]] && ok || bad "LP1 summary: $(summary)"
settle
[ "$(beaters)" = 0 ] && ok || bad "LP6 $(beaters) process(es) of the tick left: $(pgrep -af "$H/bin/lead-review.sh")"

# ── LP9: the same request again (the job re-opened): the report on disk is reused ──
rm -f "$T/log"/* "$T/agent.calls"; scratch_rm "$T/jobs"; mkdir -p "$T/jobs"
HARNESS_PARTICIPANT_TOKEN_FILE="$T/ptoken" LEAD_REVIEW_MAX_PER_TICK=5 tick
grep -q "reusing $REPORT for lr-71-${SHA:0:12}; no agent call" "$L" && ok || bad "LP9 the participant report was not reused: $(cat "$L")"
[ ! -e "$T/agent.calls" ] && ok || bad "LP9 a second agent call was made ($(wc -l < "$T/agent.calls"))"
settle

# ── LP2: heartbeats during a slow review ──
reset mac-b-host; echo 5 > "$T/sleep"; echo 6 > "$T/stale"
HARNESS_PARTICIPANT_TOKEN_FILE="$T/ptoken" LR_BEAT_MIN_S=1 LEAD_REVIEW_MAX_PER_TICK=5 tick
HB=$(cnt '^POST /api/lead-reviews/r-71/heartbeat {"job_id":"job-lr-71-'"${SHA:0:12}"'"}' "$T/log/worker")
[ "$HB" -ge 2 ] && ok || bad "LP2 heartbeats=$HB (want >= 2): $(grep heartbeat "$T/log/worker")"
HBH=$(grep -l '^POST /api/lead-reviews/r-71/heartbeat' "$T/log"/hdr.* 2>/dev/null | head -1)
[ -n "$HBH" ] && grep -qx "x-participant-token: $TOKEN" "$HBH" && ok || bad "LP2 heartbeat sent without the participant header file"
settle
[ "$(beaters)" = 0 ] && ok || bad "LP6 after a slow review $(beaters) process(es) left"
beats_hold "$HB" && ok || bad "LP6 heartbeats kept coming after the tick"

# ── LP3: knobs from whoami, and the fallback ──
reset mac-b-host
echo '{"id":"pm-1","name":"mac-b","status":"approved","granted_roles":["lead-review"],"knobs":{"LEAD_REVIEW_CONCURRENCY":2,"LEAD_REVIEW_DEADLINE_S":120}}' > "$T/whoami.json"
HARNESS_PARTICIPANT_TOKEN_FILE="$T/ptoken" LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=5 tick
[[ "$(summary)" == *" concurrency=2 "* ]] && ok || bad "LP3 machine knob not taken: $(summary)"
grep -q 'knobs from the machine: LEAD_REVIEW_CONCURRENCY=2 LEAD_REVIEW_DEADLINE_S=120' "$L" && ok || bad "LP3 no knob line: $(cat "$L")"
reset mac-b-host
HARNESS_PARTICIPANT_TOKEN_FILE="$T/ptoken" LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=5 tick
[[ "$(summary)" == *" concurrency=3 "* ]] && ok || bad "LP3 the lane setting was not kept with knobs {}: $(summary)"
reset mac-b-host
echo '{"id":"pm-1","name":"mac-b","status":"approved","granted_roles":["lead-review"],"knobs":{"LEAD_REVIEW_CONCURRENCY":"lots"}}' > "$T/whoami.json"
HARNESS_PARTICIPANT_TOKEN_FILE="$T/ptoken" LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=5 tick
[[ "$(summary)" == *" concurrency=3 "* ]] && ok || bad "LP3 a junk knob replaced the lane setting: $(summary)"

# ── LP4 + LP5b: a box run, no token file ──
reset box-demo; echo 3 > "$T/sleep"; echo 6 > "$T/stale"
LR_BEAT_MIN_S=1 LEAD_REVIEW_MAX_PER_TICK=5 tick
[ "$RC" -eq 0 ] && ok || bad "LP4 rc=$RC $(cat "$T/out")"
[ "$(cnt 'whoami' "$T/log/worker")" = 0 ] && ok || bad "LP4 a box run called whoami"
grep -qi 'x-participant-token' "$T/log/argv" "$T/log"/hdr.* 2>/dev/null && bad "LP4 a box run sent x-participant-token" || ok
grep -q '^POST /api/lead-reviews/r-71/claim {"job_id":"job-lr-71-[0-9a-f]*","box":"box-demo"}' "$T/log/worker" && ok || bad "LP4 box claim body changed: $(grep claim "$T/log/worker")"
[ "$(cnt '^POST /api/lead-reviews/r-71/heartbeat' "$T/log/worker")" -ge 1 ] && ok || bad "LP4 the box did not heartbeat its claim"
[ "$(sed -n 1p "$REPORT" 2>/dev/null)" = "# Lead review lr-71-${SHA:0:12} (example-org/demo-os#71 at $SHA)" ] && ok || bad "LP5b a box report line 1: $(sed -n 1p "$REPORT" 2>/dev/null)"
[ "$(sed -n 2p "$REPORT" 2>/dev/null)" = "" ] && ok || bad "LP5b a box report has line 2: $(sed -n 2p "$REPORT" 2>/dev/null)"
grep -q '^Reviewer:' "$REPORT" 2>/dev/null && bad "LP5b a box report names a Reviewer" || ok
# a participant (no clone check) is not the owner column: a box run that is not the owner takes nothing
reset some-other-box
LEAD_REVIEW_MAX_PER_TICK=5 tick
[ "$(cnt '/claim' "$T/log/worker")" = 0 ] && ok || bad "LP4 a non-owner box claimed without spillover"

# ── LP10: the in-build `one <id>` path beats its claim ──
reset box-demo; echo 3 > "$T/sleep"; echo 6 > "$T/stale"
( cd "$T" && HARNESS="$H" FLEET_CONF="$H/fleet.conf" LR_BEAT_MIN_S=1 bash "$H/bin/lead-review.sh" one r-71 ) > "$T/out" 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "LP10 one rc=$RC $(cat "$T/out") $(cat "$L")"
[ "$(cnt '^POST /api/lead-reviews/r-71/claim' "$T/log/worker")" = 1 ] && ok || bad "LP10 one did not claim: $(cat "$T/log/worker")"
[ "$(cnt '^POST /api/lead-reviews/r-71/heartbeat' "$T/log/worker")" -ge 1 ] && ok || bad "LP10 one posted no heartbeat: $(grep -c . "$T/log/worker") calls; $(cat "$T/out")"
settle

# ── LP7: whoami refused ──
reset mac-b-host; echo 403 > "$T/whoami.code"; echo '{"error":"participant is revoked"}' > "$T/whoami.json"
HARNESS_PARTICIPANT_TOKEN_FILE="$T/ptoken" LEAD_REVIEW_MAX_PER_TICK=5 tick
[ "$RC" -eq 0 ] && ok || bad "LP7 rc=$RC"
grep -q 'participant whoami failed (.*participant is revoked.*HTTP 403.*); tick skipped' "$L" && ok || bad "LP7 no whoami line: $(cat "$L")"
[ "$(cnt '/claim' "$T/log/worker")" = 0 ] && ok || bad "LP7 claimed after a refused whoami"
[ "$(cnt 'GET /api/lead-reviews' "$T/log/worker")" = 0 ] && ok || bad "LP7 listed requests after a refused whoami"

# ── LP8: the lib, called straight ──
reset mac-b-host
(
  export HARNESS="$H" HARNESS_PARTICIPANT_TOKEN_FILE="$T/ptoken"
  # shellcheck source=/dev/null
  . "$H/bin/jobs-client.sh"; . "$H/bin/lib/lead-reviews.sh"
  lr_heartbeat r-9 job-9 >/dev/null || exit 3
  lr_whoami > "$T/who.out" || exit 4
  unset HARNESS_PARTICIPANT_TOKEN_FILE
  lr_heartbeat r-9 job-9 >/dev/null || exit 5
  lr_whoami >/dev/null 2>&1 && exit 6
  # lr_report_title, the way bin/lead-review-land.sh reads an artifact body (stdin)
  [ "$(printf 'Reviewer: mac-b (enrolled machine)\n# Lead review k (o/r#1 at s)\n\n- verdict: MERGE\n' | lr_report_title)" = "# Lead review k (o/r#1 at s)" ] || exit 7
  [ "$(printf '# Lead review k (o/r#1 at s)\n\n- verdict: MERGE\n' | lr_report_title)" = "# Lead review k (o/r#1 at s)" ] || exit 8
  [ "$(printf 'Reviewer: someone\n# Lead review k (o/r#1 at s)\n' | lr_report_title)" = "Reviewer: someone" ] || exit 9
  exit 0
); rc=$?
[ "$rc" = 0 ] && ok || bad "LP8 lib calls rc=$rc"
[ "$(cnt '^POST /api/lead-reviews/r-9/heartbeat {"job_id":"job-9"}' "$T/log/worker")" = 2 ] && ok || bad "LP8 heartbeat posts: $(cat "$T/log/worker")"
[ "$(jq -r .name "$T/who.out" 2>/dev/null)" = mac-b ] && ok || bad "LP8 whoami body: $(cat "$T/who.out")"
[ "$(cnt 'x-participant-token' <(cat "$T/log"/hdr.* 2>/dev/null))" = 2 ] && ok || bad "LP8 want the header on exactly the two participant calls"

echo "lead-review-participant.bh-5351: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
