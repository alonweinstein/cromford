#!/bin/bash
# tests/lead-review-capped-alert.bh-6041-test.sh — BH-6041: one warn when a
# box's lead-review concurrency is capped below its configured value by /tmp
# or memory for LEAD_REVIEW_CAP_ALERT_AFTER_MIN (30) minutes, resolved on the
# first uncapped tick; and the tick's wiring of the worker's own /tmp dir.
#
# C-cases source the real bin/lib/lead-review-capped.sh in a fresh bash with
# set RPOOL_CAP_BY / RPOOL_K / the configured value, a fixed clock
# (LEAD_REVIEW_CAP_NOW) and a bin/lane-alert.sh stub that records each call:
#   C1  the first capped tick writes state/lead-review-capped.<box>, 0 calls;
#   C2  held 29 min: 0 calls; held 31 min: 1 warn, id lead-review-capped-<box>,
#       the text names the cap, the configured value, the reason and the minutes;
#       a memory cap held exactly 30 min fires (>=);
#   C3  3 more capped ticks: still 1 call;
#   C4  an operator cap (box_max) held 60 min: no state, 0 calls;
#   C5  uncapped after the warn: 1 resolve, state gone; uncapped with no state:
#       0 calls;
#   C6  configured 0 (no cap): a tmp cap 1 < LEAD_REVIEW_CAP_ALERT_MIN (4) held
#       31 min fires; a memory cap 8 >= 4 and a cap equal to the configured
#       value write no state;
#   C7  a state file that is not an integer counts as absent;
#   C8  LEAD_REVIEW_CAP_ALERT_AFTER_MIN=60 holds the warn at 31 min; an invalid
#       knob uses 30 and logs one line;
#   C9  no harness root: rc 1, nothing written;
#   C10 the registry rows for both knobs.
# L-cases run the REAL bin/lead-review.sh tick against a scratch harness with
# its real bin/lib closure (stubbed: curl, gh, df, /proc/meminfo,
# bin/agent-call.sh, bin/lane-alert.sh), as tests/lead-review-parallel.bh-5284:
#   L1  a memory cap over three ticks: the 31 min tick sends one warn, the
#       uncapped tick resolves it;
#   L2  one review: the agent runs with RULES_PACK_SNAPSHOT_TMP set to its own
#       lr<pid>-<id> dir under REVIEW_POOL_TMP_PATH, and after the tick that
#       fixture /tmp is empty.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-capped-alert.bh-6041-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export LEAD_REVIEW_MAX_PER_PR_DAY=50
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
unset LEAD_REVIEW_CAP_ALERT_AFTER_MIN LEAD_REVIEW_CAP_ALERT_MIN LEAD_REVIEW_CAP_NOW 2>/dev/null || true

N0=1790000000
# ══ the lib cases ═══════════════════════════════════════════════════════════
scratch_install_closure bin/lib/lead-review-capped.sh "$T/c" >/dev/null || { echo "FAIL: cannot install bin/lib/lead-review-capped.sh's closure"; exit 1; }
mkdir -p "$T/c/state"
cat > "$T/c/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls"
EOF
chmod +x "$T/c/bin/lane-alert.sh"
ST="$T/c/state/lead-review-capped.box-demo"
# cap <minutes since N0> <cap_by> <k> <configured> [VAR=val ...]
cap() {
  local m="$1" by="$2" k="$3" conf="$4"; shift 4
  timeout 30 env HARNESS="$T/c" LEAD_REVIEW_CAP_NOW=$((N0 + m * 60)) RPOOL_CAP_BY="$by" RPOOL_K="$k" \
    RPOOL_CAP_WHY="the why $by" "$@" bash -c '
    . "$0/bin/lib/lead-review-capped.sh" || exit 9
    log() { printf "%s\n" "$*" >> "$TT/log"; }
    lr_capped_check "$1" box-demo' "$T/c" "$conf" > /dev/null 2>&1
  RC=$?
}
export TT="$T"
calls() { local n; n=$(grep -c . "$T/calls" 2>/dev/null); echo "${n:-0}"; }
reset_c() { rm -f "$ST" "$T/calls" "$T/log"; }

# C1, C2, C3
reset_c
cap 0 tmp 1 10
[ "$RC" = 0 ] && ok || bad "C1 rc 0 (got $RC)"
[ "$(cat "$ST" 2>/dev/null)" = "$N0 0" ] && ok || bad "C1 the first capped tick writes '<epoch> 0' ($(cat "$ST" 2>/dev/null))"
[ "$(calls)" = 0 ] && ok || bad "C1 no alert on the first capped tick ($(cat "$T/calls" 2>/dev/null))"
cap 29 tmp 1 10
[ "$(calls)" = 0 ] && ok || bad "C2 held 29 min: no alert ($(cat "$T/calls" 2>/dev/null))"
cap 31 tmp 1 10
[ "$(calls)" = 1 ] && ok || bad "C2 held 31 min: one alert ($(cat "$T/calls" 2>/dev/null))"
c=$(head -1 "$T/calls" 2>/dev/null)
[[ $c == "--severity warn --id lead-review-capped-box-demo lead-review "* ]] && ok || bad "C2 a warn with id lead-review-capped-box-demo on the lead-review lane ('$c')"
[[ $c == *"capped at 1 "* && $c == *"configured value 10"* && $c == *"the why tmp"* && $c == *" 31 min"* ]] && ok \
  || bad "C2 the text names the cap, the configured value, the reason and the minutes ('$c')"
[ "$(cat "$ST" 2>/dev/null)" = "$N0 1" ] && ok || bad "C2 the state records the warn ($(cat "$ST" 2>/dev/null))"
for m in 40 50 60; do cap "$m" tmp 1 10; done
[ "$(calls)" = 1 ] && ok || bad "C3 three more capped ticks: still one alert ($(cat "$T/calls"))"
# memory at exactly 30 min
reset_c; cap 0 memory 2 10; cap 30 memory 2 10
[ "$(calls)" = 1 ] && ok || bad "C2 a memory cap held exactly 30 min fires ($(cat "$T/calls" 2>/dev/null))"

# C4 box_max
reset_c; cap 0 box_max 2 10; cap 60 box_max 2 10
[ ! -e "$ST" ] && [ "$(calls)" = 0 ] && ok || bad "C4 a box_max cap is an operator choice: no state, no alert ($(cat "$ST" "$T/calls" 2>/dev/null))"

# C5 resolve
reset_c; cap 0 tmp 1 10; cap 31 tmp 1 10; cap 35 "" 10 10
[ "$(calls)" = 2 ] && ok || bad "C5 uncapped after the warn: one more call ($(cat "$T/calls"))"
[ "$(sed -n 2p "$T/calls")" = "--resolve --id lead-review-capped-box-demo lead-review lead-review on box-demo: concurrency is back to 10 (configured value 10)." ] \
  && ok || bad "C5 the second call resolves the id ('$(sed -n 2p "$T/calls")')"
[ ! -e "$ST" ] && ok || bad "C5 the state file is removed"
cap 40 "" 10 10
[ "$(calls)" = 2 ] && ok || bad "C5 uncapped with no state: no call ($(cat "$T/calls"))"
# a box_max tick ends a tmp episode too
reset_c; cap 0 tmp 1 10; cap 10 box_max 2 10
[ ! -e "$ST" ] && ok || bad "C5 a box_max tick ends the /tmp episode"

# C6 configured 0
reset_c; cap 0 tmp 1 0; cap 31 tmp 1 0
[ "$(calls)" = 1 ] && ok || bad "C6 configured 0: a tmp cap 1 < 4 held 31 min fires ($(cat "$T/calls" 2>/dev/null))"
[[ $(head -1 "$T/calls") == *"capped at 1 "*"LEAD_REVIEW_CAP_ALERT_MIN 4"* ]] && ok || bad "C6 the text names the floor it compared against ('$(head -1 "$T/calls")')"
reset_c; cap 0 memory 8 0; cap 31 memory 8 0
[ ! -e "$ST" ] && [ "$(calls)" = 0 ] && ok || bad "C6 configured 0: a memory cap 8 >= 4 is not capped"
reset_c; cap 0 tmp 4 4; cap 31 tmp 4 4
[ ! -e "$ST" ] && [ "$(calls)" = 0 ] && ok || bad "C6 a cap equal to the configured value is not capped"
reset_c; cap 0 tmp 2 0 LEAD_REVIEW_CAP_ALERT_MIN=2
[ ! -e "$ST" ] && ok || bad "C6 LEAD_REVIEW_CAP_ALERT_MIN=2: a cap of 2 is not capped"

# C7 a garbage state file
reset_c; echo 'not-a-number' > "$ST"; cap 31 tmp 1 10
[ "$(cat "$ST" 2>/dev/null)" = "$((N0 + 31 * 60)) 0" ] && [ "$(calls)" = 0 ] && ok || bad "C7 a non-integer state counts as absent ($(cat "$ST" 2>/dev/null))"

# C8 the age knob
reset_c; cap 0 tmp 1 10; cap 31 tmp 1 10 LEAD_REVIEW_CAP_ALERT_AFTER_MIN=60
[ "$(calls)" = 0 ] && ok || bad "C8 LEAD_REVIEW_CAP_ALERT_AFTER_MIN=60 holds the warn at 31 min"
cap 61 tmp 1 10 LEAD_REVIEW_CAP_ALERT_AFTER_MIN=60
[ "$(calls)" = 1 ] && ok || bad "C8 ... and sends it at 61 min"
reset_c; cap 0 tmp 1 10; cap 31 tmp 1 10 LEAD_REVIEW_CAP_ALERT_AFTER_MIN=abc
[ "$(calls)" = 1 ] && [ "$(grep -c "LEAD_REVIEW_CAP_ALERT_AFTER_MIN='abc'" "$T/log" 2>/dev/null)" = 1 ] && ok \
  || bad "C8 an invalid knob uses 30 and logs one line ($(cat "$T/log" 2>/dev/null))"

# C9 no harness root
reset_c
timeout 30 env -u HARNESS -u H LEAD_REVIEW_CAP_NOW=$N0 RPOOL_CAP_BY=tmp RPOOL_K=1 bash -c '
  . "$0/bin/lib/lead-review-capped.sh" || exit 9; lr_capped_check 10 box-demo' "$T/c" >/dev/null 2>&1
RC=$?
[ "$RC" = 1 ] && [ ! -e "$ST" ] && [ "$(calls)" = 0 ] && ok || bad "C9 no harness root: rc 1 and nothing written (rc=$RC)"

# C10 the registry
J="$SRC/catalog/lanes.d/lead-review.json"
[ "$(jq -r '.knobs[]|select(.env=="LEAD_REVIEW_CAP_ALERT_AFTER_MIN")|"\(.default) \(.min)"' "$J")" = "30 5" ] && ok \
  || bad "C10 LEAD_REVIEW_CAP_ALERT_AFTER_MIN: default 30, min 5"
[ "$(jq -r '.knobs[]|select(.env=="LEAD_REVIEW_CAP_ALERT_MIN")|"\(.default) \(.min) \(.max)"' "$J")" = "4 1 32" ] && ok \
  || bad "C10 LEAD_REVIEW_CAP_ALERT_MIN: default 4, min 1, max 32"

# ══ the tick cases ══════════════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/bin" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/lg" "$T/repos" "$T/tmp" "$T/jobs" "$T/fxtmp"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install of $s"; exit 1; }
done
[ -r "$H/bin/lib/lead-review-capped.sh" ] && ok || bad "L0 the closure of bin/lead-review.sh installs bin/lib/lead-review-capped.sh"
cp "$SRC/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$SRC/prompts/lead-review.md" "$SRC/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
printf 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$H/fleet.conf"
cat > "$H/bin/alert-line.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/lg/lane-alert"
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
d="\${RULES_PACK_SNAPSHOT_TMP:-unset}"
printf '%s %s\n' "\$d" "\$([ -d "\$d" ] && echo dir || echo none)" >> "$T/lg/agent"
printf 'Findings\n- none\n\nVERDICT: MERGE\n' > "\$5"
exit 0
EOF
chmod +x "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/agent-call.sh"

O="$T/origin/demo-os.git"; W="$T/work/demo-os"
git init -q --bare -b main "$O"; git init -q -b main "$W"
printf '# demo\n\nNo contract here.\n' > "$W/CLAUDE.md"; echo one > "$W/a.txt"
git -C "$W" add -A; git -C "$W" -c user.email=t@t -c user.name=t commit -qm base; git -C "$W" push -q "$O" main
echo two >> "$W/a.txt"; git -C "$W" -c user.email=t@t -c user.name=t commit -qam "pr change"
SHA=$(git -C "$W" rev-parse HEAD)
git -C "$W" push -q "$O" "HEAD:refs/pull/51/head"
git clone -q "$O" "$T/repos/demo-os"

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
printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/lg/worker"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(jq -c '{requests:., truncated:false}' "$T/rows.json") ;;
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
  if [ "\${BASH_REMATCH[1]}" = 1 ]; then jq -nc --arg s "$SHA" '[{number:51, head:{sha:\$s}, labels:[]}]'; else echo '[]'; fi
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
printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\n' > "$T/mem-big"
printf 'MemTotal: 67108864 kB\nMemAvailable: 2097152 kB\n' > "$T/mem-2g"
chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$T/fakebin/df"

export PATH="$T/fakebin:$PATH" HARNESS_SECRET=test-secret-fixture JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/tmp" REPOS_ROOT="$T/repos" \
  LANE_GATE_DISABLE=1 GH_ETAG=0 REVIEW_POOL_POLL_S=0.05 REVIEW_POOL_TMP_SWEEP= REVIEW_POOL_TMP_PATH="$T/fxtmp"
unset BOX_NAME JOBS_BOX LEAD_REVIEW_MAX_PER_TICK LEAD_REVIEW_DEADLINE_S LEAD_REVIEW_MAX_PAGES PR_SNAPSHOT HOTFIX_LABEL HOTFIX_LANE
unset LEAD_REVIEW_CONCURRENCY LEAD_REVIEW_BOX_MAX LEAD_REVIEW_TMP_MIN_MB LLM_USD_CAP_DAY
# TEST-CHANGE (BH-5337 merge): BH-5337 raised the per-worker memory default to
# 2048 MB and added a cpu term (vCPUs / LEAD_REVIEW_WORKER_CPUS). The fixtures
# below are sized for 1024 MB a worker and no cpu bound, so both are pinned:
# 1024 MB a worker, and REVIEW_POOL_NPROC=64 so the test box's own vCPU count
# never caps a tick below the memory and /tmp cases this suite is about.
export LEAD_REVIEW_WORKER_MEM_MB=1024 REVIEW_POOL_NPROC=64
L="$H/logs/lead-review.log"
tick() { # tick <minutes since N0> <meminfo>
  ( cd "$T" && HARNESS="$H" FLEET_CONF="$H/fleet.conf" LEAD_REVIEW_CAP_NOW=$((N0 + $1 * 60)) REVIEW_POOL_MEMINFO="$2" \
      timeout 120 bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1
  RC=$?
}

# L1 a memory cap: 2 GB free / 1024 MB a worker = 2 < 10
echo '[]' > "$T/rows.json"
tick 0 "$T/mem-2g"
[ "$RC" = 0 ] && grep -q 'concurrency capped at 2 by memory' "$L" && ok || bad "L1 fixture: the tick is capped at 2 by memory (rc=$RC: $(cat "$L" "$T/out" 2>/dev/null | tail -5))"
[ -f "$H/state/lead-review-capped.box-demo" ] && ok || bad "L1 the first capped tick writes the state file ($(ls "$H/state"))"
[ ! -s "$T/lg/lane-alert" ] && ok || bad "L1 no alert on the first capped tick ($(cat "$T/lg/lane-alert"))"
tick 31 "$T/mem-2g"
tick 45 "$T/mem-2g"
[ "$(grep -c -- '--severity warn --id lead-review-capped-box-demo lead-review ' "$T/lg/lane-alert" 2>/dev/null)" = 1 ] && ok \
  || bad "L1 the real tick sends one warn for a cap held 31 and 45 min ($(cat "$T/lg/lane-alert" 2>/dev/null))"
tick 50 "$T/mem-big"
[ "$(grep -c -- '--resolve --id lead-review-capped-box-demo' "$T/lg/lane-alert" 2>/dev/null)" = 1 ] && ok \
  || bad "L1 the first uncapped tick resolves it ($(cat "$T/lg/lane-alert" 2>/dev/null))"
[ ! -e "$H/state/lead-review-capped.box-demo" ] && ok || bad "L1 the uncapped tick removes the state file"

# L1c a cpu cap warns like a /tmp or memory cap (BH-5337: 2 vCPU / 1 a worker = 2)
echo '[]' > "$T/rows.json"; rm -f "$T/lg/lane-alert"
REVIEW_POOL_NPROC=2 tick 100 "$T/mem-big"
[ "$RC" = 0 ] && grep -q 'concurrency capped at 2 by cpu' "$L" && ok || bad "L1c fixture: the tick is capped at 2 by cpu (rc=$RC: $(tail -3 "$L"))"
REVIEW_POOL_NPROC=2 tick 131 "$T/mem-big"
[ "$(grep -c -- '--severity warn --id lead-review-capped-box-demo lead-review ' "$T/lg/lane-alert" 2>/dev/null)" = 1 ] && ok \
  || bad "L1c a cpu cap held 31 min sends one warn ($(cat "$T/lg/lane-alert" 2>/dev/null))"
tick 140 "$T/mem-big"
[ "$(grep -c -- '--resolve --id lead-review-capped-box-demo' "$T/lg/lane-alert" 2>/dev/null)" = 1 ] && ok \
  || bad "L1c the first uncapped tick resolves the cpu warn ($(cat "$T/lg/lane-alert" 2>/dev/null))"

# L2 the worker's own /tmp dir, through the real tick
jq -nc --arg s "$SHA" '[{id:"r-51", repo:"example-org/demo-os", pr:51, head_sha:$s, status:"requested", created_at:"2026-10-07 05:00:00", scope_notes:null}]' > "$T/rows.json"
rm -f "$T/lg/agent"
tick 60 "$T/mem-big"
read -r snap there < "$T/lg/agent" 2>/dev/null || snap=""
case "$snap" in "$T/fxtmp"/lr[0-9]*-r[0-9]*) ok ;; *) bad "L2 the agent runs with RULES_PACK_SNAPSHOT_TMP = its own lr<pid>-<id> dir (got '$snap'; $(tail -5 "$L"))" ;; esac
[ "${there:-}" = dir ] && ok || bad "L2 that dir exists while the review runs ('${there:-}')"
[ -z "$(ls -A "$T/fxtmp")" ] && ok || bad "L2 after the tick the fixture /tmp is empty ($(ls -A "$T/fxtmp"))"

echo "lead-review-capped-alert.bh-6041: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
