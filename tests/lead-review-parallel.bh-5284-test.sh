#!/bin/bash
# tests/lead-review-parallel.bh-5284-test.sh — BH-5284: bin/lead-review.sh runs
# up to LEAD_REVIEW_CONCURRENCY reviews at once (bin/lib/review-pool.sh). The
# tick runs WHOLE against a scratch harness carrying its real bin/lib closure;
# stubbed are curl (the jobs worker), gh (REST reads), df and /proc/meminfo
# (box room), bin/alert-line.sh and bin/agent-call.sh, which sleeps $T/sleep
# seconds and records how many calls were in flight when it started.
#   P1  K=3, MAX=10, 6 requests: never more than 3 at once, exactly 3 at the
#       peak, all 6 reviewed and recorded in ONE tick (the 4th starts when a
#       slot frees, not on a later tick); summary concurrency=3 started=6.
#   P1b LEAD_REVIEW_BOX_MAX=2 caps K=3 at 2, logged `concurrency capped at 2`.
#   P2  two ticks at once on two boxes over the same requests: each (pr, head)
#       is reviewed once; the other tick's job_open gets 409 (rc 9) and skips.
#   P3  free /tmp under LEAD_REVIEW_TMP_MIN_MB: no worker starts, one alert line
#       over two ticks; space back = reviews run and the marker goes.
#   P4  the lane's LLM_USD_CAP_DAY is spent: no worker starts, no agent call.
#   P5  past LEAD_REVIEW_DEADLINE_S no new worker starts, and the 3 still
#       running finish and post their done results; the tick waits for them.
#   P6  every worker's scratch is gone after the tick: no tmp/lead-review-*,
#       no pool dir, no worktree left registered in the clone.
#   P7  K=0 (no cap) and MAX=0: 12 eligible requests all run at once when the
#       box guardrails allow (64 GB free, 100 GB /tmp).
#   P10 BH-5337: REVIEW_POOL_NPROC=2 caps K=3 at 2 through the tick, logged
#       `concurrency capped at 2 by cpu`.
#   P8  an agent call answering 429: no verdict, no .empty, no result post, the
#       job failed (claim released), not counted as failed; new starts pause
#       (logged once, also across the next tick); once the pause ends the same
#       request is claimed and reviewed again.
#   P9  spillover: a box that does not own the repo takes requests that waited
#       LEAD_REVIEW_SPILL_AFTER_S only with LEAD_REVIEW_SPILLOVER=1; off, or a
#       request younger than the wait, it takes nothing.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-parallel.bh-5284-test.sh
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
[ -f "$SRC/bin/lib/review-pool.sh" ] || { echo "FAIL: bin/lib/review-pool.sh does not exist"; FAIL=1; }

# mkbox <harness-dir> — a scratch harness on box box-demo
mkbox() {
  local h="$1" s
  mkdir -p "$h/bin" "$h/prompts" "$h/catalog/lanes.d" "$h/state"
  cp "$SRC/bin/lead-review.sh" "$SRC/bin/jobs-client.sh" "$SRC/bin/box-for.sh" "$SRC/bin/fleet-conf.sh" "$h/bin/"
  for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
    scratch_install_closure "$s" "$h" >/dev/null || { echo "closure install of $s failed"; exit 1; }
  done
  # jobs-client.sh exits on a missing module: the closure must have brought bin/lib/jobs/*.sh.
  [ -r "$h/bin/lib/jobs/req.sh" ] || { echo "the closure did not install bin/lib/jobs/*.sh"; exit 1; }
  cp "$SRC/catalog/lanes.d/_lib.json" "$h/catalog/lanes.d/"
  cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$h/prompts/"
  echo box-demo > "$h/state/box-name"
  printf 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$h/fleet.conf"
  cat > "$h/bin/alert-line.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/alerts"
EOF
  cat > "$h/bin/agent-call.sh" <<EOF
#!/bin/bash
pr="\${AGENT_CALL_PR##*/}"
if [ -e "$T/rl.\$pr" ]; then
  printf '%s\n' "\$pr" >> "$T/log/agent-prs"
  printf 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of concurrent connections has exceeded your rate limit"}}\n' > "\$5"
  exit 1
fi
( flock 9; mkdir -p "$T/run"; : > "$T/run/\$pr"; ls "$T/run" | wc -l | tr -d ' ' >> "$T/log/conc"
  printf '%s\n' "\$pr" >> "$T/log/agent-prs" ) 9>"$T/agent.lock"
# BH-6097 start barrier: with \$T/barrier = N, hold until N reviews have started
# (bounded, 20 s), so a peak check measures the dispatch decision, not how fast
# a loaded box happens to fork the workers. It counts starts, not runs in
# flight, so the workers after the first N pass at once.
if [ -s "$T/barrier" ]; then
  want=\$(cat "$T/barrier")
  for _ in \$(seq 1 400); do [ "\$(wc -l < "$T/log/agent-prs")" -ge "\$want" ] && break; sleep 0.05; done  # determinism: ok bounded barrier poll, 20 s at most
fi
sleep "\$(cat "$T/sleep")"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
( flock 9; rm -f "$T/run/\$pr" ) 9>"$T/agent.lock"
exit 0
EOF
  chmod +x "$h/bin/alert-line.sh" "$h/bin/agent-call.sh"
}
H="$T/h"; H2="$T/h2"
mkdir -p "$T/fakebin" "$T/log" "$T/repos" "$T/tmp" "$T/jobs"
mkbox "$H"; mkbox "$H2"

# git: one PR commit published at refs/pull/<n>/head for every PR
O="$T/origin/demo-os.git"; W="$T/work/demo-os"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# demo\n\nNo contract here.\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" -c user.email=t@t -c user.name=t commit -qm base; git -C "$W" push -q "$O" main
echo two >> "$W/a.txt"; git -C "$W" -c user.email=t@t -c user.name=t commit -qam "pr change"
SHA=$(git -C "$W" rev-parse HEAD)
PRS_ALL="51 52 53 54 55 56"
PRS_12="51 52 53 54 55 56 57 58 59 60 61 62"
for n in $PRS_12; do git -C "$W" push -q "$O" "HEAD:refs/pull/$n/head"; done
git clone -q "$O" "$T/repos/demo-os"

# the jobs worker. job_open is a test-and-set per ticket key (mkdir): a key
# another tick holds answers 409, which job_open returns as rc 9.
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
( flock 9; printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker" ) 9>"$T/worker.lock"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(jq -c '{requests:., truncated:false}' "$T/rows.json") ;;
  "POST /api/jobs")
    k=\$(printf '%s' "\$body" | jq -r '.ticket_id')
    if mkdir "$T/jobs/\$k" 2>/dev/null; then out=\$(jq -nc --arg k "\$k" '{job:{id:("job-" + \$k)}}')
    else code=409; out='{"job":{"id":"job-x","box":"box-other"}}'; fi ;;
  "PATCH /api/jobs/job-"*)
    # a failed job releases its key, as the worker lets a new attempt open it
    [ "\$(printf '%s' "\$body" | jq -r '.status // empty')" = failed ] && rmdir "$T/jobs/\${p#/api/jobs/job-}" 2>/dev/null ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
  "GET /api/metrics/llm-spend"*) out=\$(cat "$T/spend.json" 2>/dev/null || echo '{"usd":0}') ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
a="\$*"
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls\ .*page=([0-9]+) ]]; then
  printf 'HTTP/2 200\r\n\r\n'
  if [ "\${BASH_REMATCH[1]}" = 1 ]; then jq -nc --arg s "$SHA" '[range(51; 63) | {number:., head:{sha:\$s}, labels:[]}]'; else echo '[]'; fi
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls/([0-9]+) ]]; then
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg s "$SHA" '{state:"open",head:{sha:\$s},base:{ref:"main"},title:"t",body:"b"}'
  exit 0
fi
exit 0
EOF
# box room: df answers from $T/tmpfree (MB), meminfo has 64 GB available
cat > "$T/fakebin/df" <<EOF
#!/bin/bash
mb=\$(cat "$T/tmpfree" 2>/dev/null || echo 102400)
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 999999999 1 %s 1%% /tmp\n' "\$((mb * 1024))"
EOF
printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$T/meminfo"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/df"

export PATH="$T/fakebin:$PATH" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 REVIEW_POOL_MEMINFO="$T/meminfo" REVIEW_POOL_POLL_S=0.05
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S LEAD_REVIEW_MAX_PAGES PR_SNAPSHOT HOTFIX_LABEL HOTFIX_LANE
unset LEAD_REVIEW_CONCURRENCY LEAD_REVIEW_BOX_MAX LEAD_REVIEW_TMP_MIN_MB LLM_USD_CAP_DAY REVIEW_POOL_TMP_PATH

rows() { # rows <pr>... -> $T/rows.json, one requested row per PR
  local n i=0 out='[]'
  for n in "$@"; do
    out=$(jq -c --arg n "$n" --arg s "$SHA" --argjson i "$i" \
      '. + [{id:("r-" + $n), repo:"example-org/demo-os", pr:($n|tonumber), head_sha:$s, status:"requested",
             created_at:("2026-10-07 05:00:0" + ($i|tostring)), scope_notes:null}]' <<<"$out")
    i=$((i + 1))
  done
  printf '%s\n' "$out" > "$T/rows.json"
}
reset() {
  rm -f "$T/log"/* "$T"/{tmpfree,spend.json} "$T"/rl.* "$H/logs/lead-review.log" "$H2/logs/lead-review.log"
  scratch_rm "$T/jobs"; mkdir -p "$T/jobs"; scratch_rm "$T/run"
  for h in "$H" "$H2"; do scratch_rm "$h/state/lead-reviews"; rm -f "$h/state"/review-pool-tmp-low.* "$h/state"/review-pool-backoff.*; done
  echo box-demo > "$H2/state/box-name"
  echo 1 > "$T/sleep"; rm -f "$T/barrier"
  rows $PRS_ALL
}
tick() { ( cd "$T" && HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1; RC=$?; }
L="$H/logs/lead-review.log"
summary() { grep ' tick seen=' "${1:-$L}" 2>/dev/null | tail -1; }
cnt() { local n; n=$(grep -c "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
agents() { cnt . "$T/log/agent-prs"; }
peak() { sort -n "$T/log/conc" 2>/dev/null | tail -1; }
dones() { cnt '^POST /api/lead-reviews/.*/result .*"outcome":"done"' "$T/log/worker"; }

# ── P1: K=3 over 6 requests, one tick ──
# TEST-CHANGE (BH-6097, flake fix): the start barrier holds the first 3 workers
# until 3 have started, so a slow fork cannot hide the cap's peak.
reset; echo 3 > "$T/barrier"
LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
[ "$RC" -eq 0 ] && ok || bad "P1 rc=$RC $(cat "$T/out")"
[ "$(agents)" = 6 ] && ok || bad "P1 agent calls=$(agents) (want 6): $(cat "$L")"
[ "$(peak)" = 3 ] && ok || bad "P1 peak in-flight=$(peak) (want 3): $(paste -sd' ' "$T/log/conc" 2>/dev/null)"
[ "$(dones)" = 6 ] && ok || bad "P1 done results=$(dones) (want 6)"
[ "$(grep -c ' tick seen=' "$L")" = 1 ] && ok || bad "P1 want one tick: $(cat "$L")"
S=$(summary)
[[ "$S" == *" done=6 "* && "$S" == *" concurrency=3 "* && "$S" == *" started=6 "* && "$S" == *" deferred=0 "* ]] && ok || bad "P1 summary: $S"
# P6: the scratch went with the workers
ls -d "$H/tmp"/lead-review-* >/dev/null 2>&1 && bad "P6 scratch left: $(ls "$H/tmp")" || ok
ls -d "$H/tmp"/lead-review-queue-* >/dev/null 2>&1 && bad "P6 queue/pool files left: $(ls "$H/tmp")" || ok
[ "$(git -C "$T/repos/demo-os" worktree list | wc -l | tr -d ' ')" = 1 ] && ok || bad "P6 worktrees left: $(git -C "$T/repos/demo-os" worktree list)"

# ── P1b: the box cap ──
reset; echo 2 > "$T/barrier"   # TEST-CHANGE (BH-6097): as P1, a start barrier of 2
LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_BOX_MAX=2 LEAD_REVIEW_MAX_PER_TICK=10 tick
[ "$(peak)" = 2 ] && ok || bad "P1b peak=$(peak) (want 2)"
grep -q 'concurrency capped at 2 by LEAD_REVIEW_BOX_MAX=2' "$L" && ok || bad "P1b no cap line: $(cat "$L")"
[ "$(agents)" = 6 ] && ok || bad "P1b agent calls=$(agents)"

# ── P2: two ticks at once, two boxes, the same 6 requests ──
reset; echo 2 > "$T/sleep"
( cd "$T" && HARNESS="$H2" FLEET_CONF="$H2/fleet.conf" LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 \
    bash "$H2/bin/lead-review.sh" tick ) > "$T/out2" 2>&1 &
P2=$!
LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
wait "$P2"
[ "$(agents)" = 6 ] && ok || bad "P2 agent calls=$(agents) (want 6, one per head): $(sort "$T/log/agent-prs" | uniq -c | tr '\n' ' ')"
[ "$(sort "$T/log/agent-prs" | uniq -d | wc -l | tr -d ' ')" = 0 ] && ok || bad "P2 a head reviewed twice: $(sort "$T/log/agent-prs" | uniq -d)"
SK=$(( $(cnt '^.* skip lr-' "$L") + $(cnt '^.* skip lr-' "$H2/logs/lead-review.log") ))
[ "$SK" -ge 1 ] && ok || bad "P2 no claim skip on either box: $(cat "$L" "$H2/logs/lead-review.log")"
[ "$(dones)" = 6 ] && ok || bad "P2 done results=$(dones) (want 6)"

# ── P3: /tmp under the floor ──
reset; echo 1000 > "$T/tmpfree"
LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
[ "$(agents)" = 0 ] && ok || bad "P3 agent called with /tmp low: $(agents)"
[ "$(cnt '/claim' "$T/log/worker")" = 0 ] && ok || bad "P3 a request was claimed with /tmp low"
grep -q 'no new worker: .* has 1000MB free, below LEAD_REVIEW_TMP_MIN_MB=1536' "$L" && ok || bad "P3 no refusal line: $(cat "$L")"
[ "$(cnt . "$T/log/alerts")" = 1 ] && ok || bad "P3 alerts=$(cnt . "$T/log/alerts") over two ticks (want 1): $(cat "$T/log/alerts" 2>/dev/null)"
[[ "$(summary)" == *" deferred=6 "* ]] && ok || bad "P3 summary: $(summary)"
rm -f "$T/tmpfree"; LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
[ "$(agents)" = 6 ] && ok || bad "P3 space back: agent calls=$(agents)"
[ -e "$H/state/review-pool-tmp-low.lead-review" ] && bad "P3 the low marker outlived the episode" || ok

# ── P4: the lane's daily spend cap is used up ──
reset; echo '{"usd":12.5}' > "$T/spend.json"
LLM_USD_CAP_DAY=5 LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
[ "$(agents)" = 0 ] && ok || bad "P4 agent called over the cap: $(agents)"
[ "$(cnt '/claim' "$T/log/worker")" = 0 ] && ok || bad "P4 a request was claimed over the cap"
grep -q 'spend cap reached for demo-os' "$L" && ok || bad "P4 no cap line: $(cat "$L")"
[[ "$(summary)" == *" deferred=6 "* ]] && ok || bad "P4 summary: $(summary)"
# under the cap: reviews run
reset; echo '{"usd":1}' > "$T/spend.json"
LLM_USD_CAP_DAY=5 LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
[ "$(agents)" = 6 ] && ok || bad "P4 under the cap: agent calls=$(agents)"

# ── P5: the deadline passes with 3 reviews running ──
# BH-4956: the deadline is 3 s, not 2 s. The tick now reads two settings rows
# before its first start and checks the per-PR tripwire per claim, and on a
# slow box 3 claims no longer fit in 2 s (main itself missed it 1 run in 3).
# The review still outlasts the deadline, so the behaviour pinned is the same.
reset; echo 4 > "$T/sleep"
LEAD_REVIEW_DEADLINE_S=3 LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
[ "$RC" -eq 0 ] && ok || bad "P5 rc=$RC"
[ "$(agents)" = 3 ] && ok || bad "P5 agent calls=$(agents) (want the 3 started before the deadline)"
[ "$(dones)" = 3 ] && ok || bad "P5 done results=$(dones) (want 3: the running ones finish and record)"
S=$(summary)
[[ "$S" == *" done=3 "* && "$S" == *" deferred=3 "* && "$S" == *" running=3 "* ]] && ok || bad "P5 summary: $S"
grep -q 'starts closed concurrency=3 running=3 started=3' "$L" && ok || bad "P5 no starts-closed line: $(cat "$L")"
[ -z "$(ls "$T/run" 2>/dev/null)" ] && ok || bad "P5 a review was still running when the tick returned"

# ── P7: K=0 is no cap ──
# TEST-CHANGE (BH-6097, flake fix): a start barrier of 12 holds every worker
# until all 12 are in flight. Without it a loaded box forked them slowly enough
# that the first ones finished first (peak 8 of 12, on main too).
reset; rows $PRS_12; echo 2 > "$T/sleep"; echo 12 > "$T/barrier"
LEAD_REVIEW_CONCURRENCY=0 LEAD_REVIEW_MAX_PER_TICK=0 tick
[ "$(agents)" = 12 ] && ok || bad "P7 agent calls=$(agents) (want 12)"
[ "$(peak)" = 12 ] && ok || bad "P7 peak in-flight=$(peak) (want all 12 at once): $(paste -sd' ' "$T/log/conc" 2>/dev/null)"
[[ "$(summary)" == *" done=12 "*" started=12 "* ]] && ok || bad "P7 summary: $(summary)"
# the box guardrails still bound it: 5 GB of memory at 1024 MB a worker is 5
# workers (BH-5337 raised the default to 2048, so the case names its 1024)
printf 'MemTotal: 67108864 kB\nMemAvailable: 5242880 kB\n' > "$T/meminfo2"
# The barrier is 5: a cap that let more start would still show a peak above 5.
reset; rows $PRS_12; echo 5 > "$T/barrier"
REVIEW_POOL_MEMINFO="$T/meminfo2" LEAD_REVIEW_WORKER_MEM_MB=1024 LEAD_REVIEW_CONCURRENCY=0 LEAD_REVIEW_MAX_PER_TICK=0 tick
[ "$(peak)" = 5 ] && ok || bad "P7 memory-capped peak=$(peak) (want 5)"
grep -q 'concurrency capped at 5 by memory' "$L" && ok || bad "P7 no memory cap line: $(grep capped "$L")"

# ── P10: the vCPU term caps the real tick (BH-5337) ──
reset
REVIEW_POOL_NPROC=2 LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
[ "$(peak)" = 2 ] && ok || bad "P10 peak=$(peak) on 2 vCPU (want 2)"
grep -q 'concurrency capped at 2 by cpu (2 vCPU, 1 a worker)' "$L" && ok || bad "P10 no cpu cap line: $(grep capped "$L")"
[[ "$(summary)" == *" concurrency=2 "* ]] && ok || bad "P10 summary: $(summary)"
[ "$(agents)" = 6 ] && ok || bad "P10 agent calls=$(agents) (want 6)"

# ── P8: a 429 releases the claim and pauses new starts ──
reset; rows 51 52 53; : > "$T/rl.51"
LEAD_REVIEW_DEADLINE_S=4 LEAD_REVIEW_RATE_BACKOFF_S=60 LEAD_REVIEW_CONCURRENCY=1 LEAD_REVIEW_MAX_PER_TICK=10 tick
[ "$RC" -eq 0 ] && ok || bad "P8 rc=$RC"
[ "$(agents)" = 1 ] && ok || bad "P8 agent calls=$(agents) (want only the limited one: starts paused after it)"
[ "$(cnt '^POST /api/lead-reviews/r-51/result' "$T/log/worker")" = 0 ] && ok || bad "P8 a result was posted for the limited review: $(grep result "$T/log/worker")"
grep -q '^PATCH /api/jobs/job-lr-51-.*"status":"failed"' "$T/log/worker" && ok || bad "P8 the job was not failed (claim not released)"
ls "$H/state/lead-reviews"/*.empty >/dev/null 2>&1 && bad "P8 a .empty was written for a rate limit" || ok
S=$(summary)
[[ "$S" == *" failed=0 "* && "$S" == *" ratelimited=1 "* && "$S" == *" deferred=2 "* ]] && ok || bad "P8 summary: $S"
[ "$(cnt 'new starts paused for 60s' "$L")" = 1 ] && ok || bad "P8 pause lines: $(grep -c 'paused' "$L")"
grep -q 'hit a rate or concurrency limit (rc=1)' "$L" && ok || bad "P8 no limit line: $(cat "$L")"
# the next tick, still inside the pause: nothing starts, nothing logged again
rm -f "$T/rl.51"
LEAD_REVIEW_DEADLINE_S=2 LEAD_REVIEW_CONCURRENCY=1 LEAD_REVIEW_MAX_PER_TICK=10 tick
[ "$(agents)" = 1 ] && ok || bad "P8 a review started inside the pause: $(agents)"
[ "$(cnt 'new starts paused for' "$L")" = 1 ] && ok || bad "P8 the pause was logged again"
# the pause over: the released request is claimed and reviewed
rm -f "$H/state/review-pool-backoff.lead-review"
LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 tick
grep -q '^POST /api/lead-reviews/r-51/result .*"outcome":"done"' "$T/log/worker" && ok || bad "P8 the released request was not reviewed: $(grep r-51 "$T/log/worker" | tail -3)"
[ "$(dones)" = 3 ] && ok || bad "P8 done results after the pause=$(dones) (want 3)"

# ── P9: spillover to a box that does not own the repo ──
reset; echo box-other > "$H2/state/box-name"
tick2() { ( cd "$T" && HARNESS="$H2" FLEET_CONF="$H2/fleet.conf" LEAD_REVIEW_CONCURRENCY=3 LEAD_REVIEW_MAX_PER_TICK=10 \
            bash "$H2/bin/lead-review.sh" tick ) > "$T/out2" 2>&1; }
tick2
[ "$(agents)" = 0 ] && ok || bad "P9 spillover off: the other box reviewed $(agents)"
[[ "$(summary "$H2/logs/lead-review.log")" == *" owned=0 "* ]] && ok || bad "P9 off summary: $(summary "$H2/logs/lead-review.log")"
LEAD_REVIEW_SPILLOVER=1 LEAD_REVIEW_SPILL_AFTER_S=999999999 tick2
[ "$(agents)" = 0 ] && ok || bad "P9 a request younger than the wait spilled: $(agents)"
LEAD_REVIEW_SPILLOVER=1 LEAD_REVIEW_SPILL_AFTER_S=60 tick2
[ "$(agents)" = 6 ] && ok || bad "P9 spillover on: the other box reviewed $(agents) (want 6)"
[[ "$(summary "$H2/logs/lead-review.log")" == *" done=6 "*" spill=6" ]] && ok || bad "P9 on summary: $(summary "$H2/logs/lead-review.log")"

echo "lead-review-parallel.bh-5284: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
