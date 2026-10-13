#!/bin/bash
# tests/lead-review-rings-land.bh-5317-test.sh — BH-5317 (BH-4057, the lead
# chain): a lead review that DELIVERED a terminal result rings lead-land from
# its pool worker's exit path, once per (pr, head), and nothing else rings.
# Every case runs the REAL bin/lead-review.sh tick on the review pool against a
# scratch harness carrying its real bin/lib closure ("$DIR/bin/lib/review-pool.sh"
# and "$DIR/bin/lib/lead-chain-wake.sh" included). Stubbed: curl (the jobs
# worker, with a POST /api/wakes/lane arm), gh (REST reads), df and
# /proc/meminfo (box room), bin/agent-call.sh and, for D3g, bin/rules-pack.sh.
#   D3  VERDICT: MERGE: one done/MERGE result, THEN exactly one wake, kind
#       lead-land, dedupe lead-land:7@<sha12>, repo o/r; `lead-land doorbell
#       rung for o/r#7@<sha12>`; the summary says ` rung=1` (before total=).
#   D3b live head moved: superseded, zero wakes, summary ` rung=0`.
#   D3c the agent call refused (rc 75): no result, zero wakes, rc=75 logged.
#   D3d the result post answers 500: zero wakes, `result post failed` logged.
#   D3e job_open 409 (rc 9): `skip lr-7-<sha12>`, zero wakes. A gh 500 on the
#       live head: `live head of o/r#7 unreadable`, zero wakes.
#   D3f no verdict twice: .empty, outcome failed, then exactly one wake.
#   D3g the harness repo whose rules pack could not run (rc 2): the result is
#       still done/MERGE, zero wakes, `lead-land doorbell withheld`.
#   D5  flags/lead-chain-wake-off: the done result posts, zero wakes,
#       `lead-land doorbell not rung for o/r#7 (rc 1)`.
#   D6  K=3 over PRs 7, 8, 9: the reviews overlap in pool workers, exactly 3
#       wakes, one per (pr, head), summary done=3 concurrency=3 rung=3.
# LR_BASE_SCRIPT=<path> runs every case against another bin/lead-review.sh
# (the red check against main's).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-rings-land.bh-5317-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-4956: these cases review one PR more than the per-PR-day tripwire allows
# (LEAD_REVIEW_MAX_PER_PR_DAY, default 4, state/lead-review/started.tsv).
export LEAD_REVIEW_MAX_PER_PR_DAY=50
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

H="$T/h"
mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$H/flags" "$T/fakebin" "$T/log" "$T/repos" "$T/tmp" "$T/jobs"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install of $s"; exit 1; }
done
[ -r "$H/bin/lib/review-pool.sh" ] && [ -r "$H/bin/lib/lead-chain-wake.sh" ] \
  || { echo "FAIL: the closure did not install review-pool.sh and lead-chain-wake.sh"; exit 1; }
[ -r "$H/bin/lib/jobs/req.sh" ] || { echo "FAIL: the closure did not install bin/lib/jobs/*.sh"; exit 1; }
if [ -n "${LR_BASE_SCRIPT:-}" ]; then cp "$LR_BASE_SCRIPT" "$H/bin/lead-review.sh"; chmod +x "$H/bin/lead-review.sh"; fi
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"

# origin: main + one PR commit published at refs/pull/{7,8,9}/head; two clones,
# one per fleet.conf project name the cases use.
O="$T/origin/r.git"; W="$T/work/r"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# demo\n\nNo contract here.\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
echo two >> "$W/a.txt"; git -C "$W" commit -qam "pr change"
SHA=$(git -C "$W" rev-parse HEAD); SHA12=${SHA:0:12}
for n in 7 8 9; do git -C "$W" push -q "$O" "HEAD:refs/pull/$n/head"; done
git clone -q "$O" "$T/repos/demo-os"; git clone -q "$O" "$T/repos/cromford"
MOVED=$(printf 'f%.0s' {1..40})

# the jobs worker; every request logged "<METHOD> <path> <body>", one line each
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
body=\$(printf '%s' "\$body" | tr -d '\n')
p="\${url#https://jobs.test}"
( flock 9; printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker" ) 9>"$T/worker.lock"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(jq -c '{requests:., truncated:false}' "$T/rows.json") ;;
  "POST /api/lead-reviews/"*"/result") [ -e "$T/result500" ] && { code=500; out='{"error":"boom"}'; } ;;
  "POST /api/jobs")
    k=\$(printf '%s' "\$body" | jq -r '.ticket_id')
    if mkdir "$T/jobs/\$k" 2>/dev/null; then out=\$(jq -nc --arg k "\$k" '{job:{id:("job-" + \$k)}}')
    else code=409; out='{"job":{"id":"job-x","box":"box-other"}}'; fi ;;
  "POST /api/wakes/lane") out='{"inserted":1,"id":"w-1"}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
# gh: the open-PR list and pulls/<n>; the live head is \$T/live (else the PR
# commit); \$T/gh500 makes pulls/<n> answer 500.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
a="\$*"; live=\$(cat "$T/live" 2>/dev/null || echo "$SHA")
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls\ .*page=([0-9]+) ]]; then
  printf 'HTTP/2 200\r\n\r\n'
  if [ "\${BASH_REMATCH[1]}" = 1 ]; then jq -nc --arg s "\$live" '[7, 8, 9 | {number:., head:{sha:\$s}, labels:[]}]'; else echo '[]'; fi
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls/([0-9]+) ]]; then
  if [ -e "$T/gh500" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"boom"}\n'; exit 1; fi
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg s "\$live" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}'
  exit 0
fi
exit 0
EOF
cat > "$T/fakebin/df" <<EOF
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 999999999 1 %s 1%% /tmp\n' "\$((102400 * 1024))"
EOF
printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$T/meminfo"
# The agent: \$T/agentrc = its exit code; \$T/answer = what it writes; \$T/sleep
# = seconds it takes. It records how many calls were in flight as it started.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
pr="\${AGENT_CALL_PR##*/}"
( flock 9; mkdir -p "$T/run"; : > "$T/run/\$pr"; ls "$T/run" | wc -l | tr -d ' ' >> "$T/log/conc"
  echo "\$pr" >> "$T/log/agent-prs" ) 9>"$T/agent.lock"
sleep "\$(cat "$T/sleep" 2>/dev/null || echo 0)"
( flock 9; rm -f "$T/run/\$pr" ) 9>"$T/agent.lock"
rc=\$(cat "$T/agentrc" 2>/dev/null || echo 0)
[ "\$rc" = 0 ] && cp "$T/answer" "\$5"
exit "\$rc"
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/df" "$H/bin/agent-call.sh"

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" FLEET_CONF="$H/fleet.conf" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S LEAD_REVIEW_MAX_PAGES PR_SNAPSHOT HOTFIX_LABEL HOTFIX_LANE
unset LEAD_REVIEW_CONCURRENCY LEAD_REVIEW_BOX_MAX LEAD_REVIEW_TMP_MIN_MB LLM_USD_CAP_DAY REVIEW_POOL_TMP_PATH
unset LEAD_CHAIN_RERUN_DEPTH AGENT_CALL_FP AGENT_CALL_GUARD_STAGE
# No owed-rerun chain in this suite: its subject is the ring.
export LEAD_REVIEW_RERUN_MAX=0

L="$H/logs/lead-review.log"
rows() { # rows <pr>... -> $T/rows.json, one requested row per PR, repo o/r
  local n i=0 out='[]'
  for n in "$@"; do
    out=$(jq -c --arg n "$n" --arg s "$SHA" --argjson i "$i" \
      '. + [{id:("r-" + $n), repo:"o/r", pr:($n|tonumber), head_sha:$s, status:"requested",
             created_at:("2026-10-07 05:00:0" + ($i|tostring)), scope_notes:null}]' <<<"$out")
    i=$((i + 1))
  done
  printf '%s\n' "$out" > "$T/rows.json"
}
reset() {
  rm -f "$T/log"/* "$T"/{live,gh500,result500,agentrc,sleep} "$L" "$H/flags/lead-chain-wake-off" "$H/bin/rules-pack.sh"
  scratch_rm "$T/jobs"; mkdir -p "$T/jobs"; scratch_rm "$T/run"
  scratch_rm "$H/state/lead-reviews"; rm -f "$H/state"/review-pool-*
  printf 'demo-os o/r https://demo.test /api/board 1 box-demo\n' > "$H/fleet.conf"
  printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "$T/answer"
  rows 7
}
tick() { ( cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
wlog() { cat "$T/log/worker" 2>/dev/null; }
wakes() { local n; n=$(wlog | grep -c '^POST /api/wakes/lane '); echo "${n:-0}"; }
wakebody() { wlog | sed -n 's#^POST /api/wakes/lane ##p' | sed -n "${1:-1}p"; }
results() { local n; n=$(wlog | grep -c '^POST /api/lead-reviews/.*/result '); echo "${n:-0}"; }
summary() { grep ' tick seen=' "$L" 2>/dev/null | tail -1; }
logtxt() { cat "$L" 2>/dev/null; }

# ── D3: a MERGE verdict rings lead-land once, after its result ──
reset; tick
[ "$RC" -eq 0 ] && ok || bad "D3 rc=$RC $(cat "$T/out")"
[ "$(results)" = 1 ] && ok || bad "D3 results=$(results) (want 1): $(wlog)"
wlog | grep -q '^POST /api/lead-reviews/r-7/result .*"outcome":"done".*"verdict":"MERGE"' && ok || bad "D3 no done/MERGE result: $(wlog)"
[ "$(wakes)" = 1 ] && ok || bad "D3 wakes=$(wakes) (want 1): $(wlog)"
WB=$(wakebody 1)
[ "$(jq -r '[.kind, .dedupe, .repo, (.key|tostring)] | join("|")' <<<"$WB" 2>/dev/null)" = "lead-land|lead-land:7@$SHA12|o/r|7" ] \
  && ok || bad "D3 wake body: $WB"
LR=$(wlog | grep -n -m1 '^POST /api/lead-reviews/r-7/result ' | cut -d: -f1)
LW=$(wlog | grep -n -m1 '^POST /api/wakes/lane ' | cut -d: -f1)
[ -n "$LR" ] && [ -n "$LW" ] && [ "$LW" -gt "$LR" ] && ok || bad "D3 the wake (line ${LW:-none}) is not after the result (line ${LR:-none})"
grep -qF "lead-land doorbell rung for o/r#7@$SHA12" "$L" && ok || bad "D3 no rung line: $(logtxt)"
[[ "$(summary)" == *" rung=1 total="* ]] && ok || bad "D3 summary has no rung=1: $(summary)"

# ── D3b: the live head moved: superseded, no ring ──
reset; echo "$MOVED" > "$T/live"; tick
wlog | grep -q '"outcome":"superseded"' && ok || bad "D3b not superseded: $(wlog)"
[ "$(wakes)" = 0 ] && ok || bad "D3b wakes=$(wakes) for a superseded row"
[[ "$(summary)" == *" rung=0 total="* ]] && ok || bad "D3b summary: $(summary)"

# ── D3c: the agent call refused before billing ──
reset; echo 75 > "$T/agentrc"; tick
[ "$(results)" = 0 ] && ok || bad "D3c a result was posted: $(wlog)"
[ "$(wakes)" = 0 ] && ok || bad "D3c wakes=$(wakes)"
grep -q 'rc=75' "$L" && ok || bad "D3c no rc=75 line: $(logtxt)"

# ── D3d: the result post fails ──
reset; : > "$T/result500"; tick
[ "$(results)" -ge 1 ] && ok || bad "D3d no result attempt: $(wlog)"
[ "$(wakes)" = 0 ] && ok || bad "D3d wakes=$(wakes) after a failed result post"
grep -q 'result post failed' "$L" && ok || bad "D3d no failed-post line: $(logtxt)"

# ── D3e: another box holds the job; then an unreadable live head ──
reset; mkdir -p "$T/jobs/lr-7-$SHA12"; tick
grep -q "skip lr-7-$SHA12" "$L" && ok || bad "D3e no skip line: $(logtxt)"
[ "$(wakes)" = 0 ] && ok || bad "D3e skip: wakes=$(wakes)"
reset; : > "$T/gh500"; tick
grep -q 'live head of o/r#7 unreadable' "$L" && ok || bad "D3e no unreadable line: $(logtxt)"
[ "$(wakes)" = 0 ] && ok || bad "D3e unreadable: wakes=$(wakes)"

# ── D3f: no verdict twice: billed, outcome failed, which is terminal: one ring ──
reset; printf 'I looked at it.\n' > "$T/answer"; tick
[ -f "$H/state/lead-reviews/lr-7-$SHA12.empty" ] && ok || bad "D3f no .empty: $(logtxt)"
wlog | grep -q '^POST /api/lead-reviews/r-7/result .*"outcome":"failed"' && ok || bad "D3f no failed result: $(wlog)"
[ "$(wakes)" = 1 ] && ok || bad "D3f wakes=$(wakes) (want 1)"
LR=$(wlog | grep -n -m1 '^POST /api/lead-reviews/r-7/result ' | cut -d: -f1)
LW=$(wlog | grep -n -m1 '^POST /api/wakes/lane ' | cut -d: -f1)
[ -n "$LR" ] && [ -n "$LW" ] && [ "$LW" -gt "$LR" ] && ok || bad "D3f the wake is not after the result"

# ── D3g: the harness repo, its rules pack could not run: withheld ──
reset
printf 'cromford o/r https://demo.test /api/board 1 box-demo\n' > "$H/fleet.conf"
printf '#!/bin/bash\necho "rules pack broke" >&2\nexit 2\n' > "$H/bin/rules-pack.sh"; chmod +x "$H/bin/rules-pack.sh"
tick
wlog | grep -q '^POST /api/lead-reviews/r-7/result .*"outcome":"done".*"verdict":"MERGE"' && ok || bad "D3g the result was not delivered: $(wlog)"
grep -q -- '- rules pack: could not run (rc 2)' "$H/state/lead-reviews/lr-7-$SHA12.md" 2>/dev/null && ok || bad "D3g the report does not say could not run"
[ "$(wakes)" = 0 ] && ok || bad "D3g wakes=$(wakes) with the rules pack unrun"
grep -qF "lead-land doorbell withheld for o/r#7@$SHA12 (rules pack could not run)" "$L" && ok || bad "D3g no withheld line: $(logtxt)"
# a replay of that stored report withholds too (the header line is read)
scratch_rm "$T/jobs"; mkdir -p "$T/jobs"; rm -f "$T/log/worker" "$L"; tick
grep -q "reusing .*lr-7-$SHA12.md for lr-7-$SHA12; no agent call" "$L" && ok || bad "D3g the second tick did not replay: $(logtxt)"
[ "$(wakes)" = 0 ] && ok || bad "D3g replay: wakes=$(wakes)"
grep -qF "lead-land doorbell withheld for o/r#7@$SHA12" "$L" && ok || bad "D3g replay: no withheld line: $(logtxt)"

# ── D5: the kill switch ──
reset; : > "$H/flags/lead-chain-wake-off"; tick
wlog | grep -q '^POST /api/lead-reviews/r-7/result .*"outcome":"done"' && ok || bad "D5 the done result was not posted: $(wlog)"
[ "$(wakes)" = 0 ] && ok || bad "D5 wakes=$(wakes) with the switch on"
grep -qF 'lead-land doorbell not rung for o/r#7 (rc 1)' "$L" && ok || bad "D5 no not-rung line: $(logtxt)"
[[ "$(summary)" == *" rung=0 total="* ]] && ok || bad "D5 summary: $(summary)"

# ── D6: three MERGE verdicts in one pooled tick: three rings, one per head ──
reset; rows 7 8 9; echo 1 > "$T/sleep"
LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
PEAK=$(sort -n "$T/log/conc" 2>/dev/null | tail -1)
[ "${PEAK:-0}" -gt 1 ] && ok || bad "D6 peak in-flight=${PEAK:-0}: the reviews did not run in pool workers"
[ "$(wakes)" = 3 ] && ok || bad "D6 wakes=$(wakes) (want 3): $(wlog | grep wakes)"
DD=$(wlog | sed -n 's#^POST /api/wakes/lane ##p' | jq -r '.dedupe' 2>/dev/null | sort | paste -sd' ')
[ "$DD" = "lead-land:7@$SHA12 lead-land:8@$SHA12 lead-land:9@$SHA12" ] && ok || bad "D6 dedupe set: '$DD'"
S=$(summary)
[[ "$S" == *" done=3 "* && "$S" == *" concurrency=3 "* && "$S" == *" rung=3 total="* ]] && ok || bad "D6 summary: $S"

echo "lead-review-rings-land.bh-5317: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
