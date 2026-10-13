#!/bin/bash
# tests/lookback-lane.bh-1795-test.sh — BH-1795.0: the weekly `lookback` hub lane
# skeleton, its registry entry and the shared contract in bin/lib/lookback-common.sh.
#
# DRIVEN, NOT GREPPED: every driver case runs the real bin/lookback.sh through
# `env -i … bash bin/lookback.sh` against a scratch $HARNESS ($T/h) rebuilt per
# case. The collector, lane-alert, agent-call and jobs-client are recorders; the
# sibling functions (clustering, the two filers) come from
# tests/lib/lookback-stub-filers.bh-1795.sh copied in as bin/lib/lookback-file.sh,
# which is the path the driver sources in production.
#
#   K1  registry: 14 knobs, types/defaults, cadence, switch, cost_stage
#   F1  lookback_fingerprint is 16 hex chars and stable
#   F2  it is sha1(target|project|key_kind|key_value)[:16]; each argument matters
#   M1  lookback_reason_family strips url, sha, digits; squeezes whitespace
#   M2  lookback_item_match_jq: file/lane/reason and the project rule
#   H1  the header documents the shapes, the rc convention and the sibling knobs
#   S1  no collector -> rc 0, `collector not installed`, nothing called
#   E1  empty week -> one `no repeat failures` line, no job row, no alert, no call
#   L1  flags/lane-off-lookback -> rc 0, collector never runs
#   N2  collector rc 3 -> rc 75, one ALERTS line, no lane-alert
#   N3  LOOKBACK_DRY=1 -> inventory printed, clustered, nothing filed, one warn summary (BH-3691)
#   R1  a same-day clusters.json is reused; lookback_cluster_run is not called
#   L3  settings row lane.lookback.lookback_max_issues=1 caps filing at one
#   C1  a filer rc 75 stops the walk
#   T1  dispatch by target; no filer installed -> `not filed: filer not installed`
#   V1  lookback_cluster_run rc 2 / rc 75 are named in the summary, nothing filed
#   L4  one lane-alert, --severity info, --id lookback-<date>, never --critical
#   D1  a second instance while the lock is held exits 0 without collecting
#   Z1  no `claude-` string in the four lane files
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' must not be in: $2" ;; *) ok ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "lookback-lane.bh-1795-test: SKIPPED — jq missing"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "lookback-lane.bh-1795-test: SKIPPED — flock missing"; exit 0; }

NOW=$(date -u +%s)
# The driver reads its own clock for the run dir; the test derives the same day
# from its one NOW read. determinism: ok the run dir is named by the driver's wall-clock day
DATE=$(date -u -d "@$NOW" +%Y-%m-%d)

REG=$(HARNESS_TEST_SANDBOX=1 bash -c '. "$1/bin/lib/lanes-registry.sh" && lanes_json_path "$1"' _ "$DIR") \
  || { echo "FAIL: could not render the lane registry"; exit 1; }
LIB="$DIR/bin/lib/lookback-common.sh"
H="$T/h"
RUN="$H/state/lookback/$DATE"

# fresh — a new scratch harness for one case.
fresh() {
  scratch_rm "$H"; rm -f "$T"/calls.* "$T/out"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$H/catalog"
  : > "$H/env/global.env"
  cp "$DIR/bin/lookback.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
  cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lanes-registry.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
  [ -r "$LIB" ] && cp "$LIB" "$H/bin/lib/"
  cp "$REG" "$H/catalog/lanes.json"
  cat > "$H/bin/jobs-client.sh" <<SH
job_lane_open()  { printf '%s\n' "\$*" >> "$T/calls.job_open"; }
job_lane_close() { printf '%s\n' "\$*" >> "$T/calls.job_close"; }
# BH-3691: the driver reads the lookback_cluster ledger once before filing and
# files nothing without it; an empty ledger here, the week cap is its own suite.
_jobs_req() { echo '{"ledgers":[]}'; }
SH
  cat > "$H/bin/lane-alert.sh" <<SH
#!/bin/bash
a="\$*"; printf '%s\n' "\${a//\$'\n'/ | }" >> "$T/calls.lane-alert"
SH
  cat > "$H/bin/agent-call.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.agent-call"
SH
  chmod +x "$H/bin/"*.sh
}

# collector — install the stub collector: it writes $STUB_ITEMS items (each file
# bin/x.sh, lane rebase, a reason with a number in it) and exits $STUB_COLLECT_RC.
collector() {
  cat > "$H/bin/lookback-collect.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.collect"
[ "\${STUB_COLLECT_RC:-0}" = 0 ] || exit "\$STUB_COLLECT_RC"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
mkdir -p "\$(dirname "\$out")"
jq -n --argjson n "\${STUB_ITEMS:-0}" --argjson now "$NOW" --arg tr "\${STUB_TRUNC:-0}" '
  {window:{from:(\$now-7*86400|todate),to:(\$now|todate)},
   items:[range(\$n)|{id:"i\(.)",source:"alerts",at:(\$now-3600*(.+1)|todate),project:"cromford",
                     ticket:null,pr:null,files:["bin/x.sh"],lane:"rebase",reason:"rebase failed \(.)"}],
   sources:{alerts:{ok:true,n:\$n,truncated:(\$tr=="1")},builds:{ok:(\$tr!="1"),n:0,truncated:false}},
   incomplete:(\$tr=="1")}' > "\$out"
SH
  chmod +x "$H/bin/lookback-collect.sh"
}
stubs() { cp "$DIR/tests/lib/lookback-stub-filers.bh-1795.sh" "$H/bin/lib/lookback-file.sh"; }
clusters() { # clusters <target>... — seed today's clusters.json, one cluster per target
  mkdir -p "$RUN"
  local i=0 t; for t in "$@"; do i=$((i+1))
    jq -nc --arg t "$t" --argjson i "$i" '{fingerprint:"fp\($i)",key_kind:"file",key_value:"bin/f\($i).sh",
      item_ids:["i0","i1"],target:$t,project:"cromford",title:"Cluster \($i)",cause:"c",proposed_fix:"p"}'
  done | jq -s . > "$RUN/clusters.json"
}
drive() { # drive [VAR=value ...] -> rc in $RC, stdout in $T/out
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" LANE_GATE_NOW="$NOW" \
    LOOKBACK_STUB_CALLS="$T/calls.stub" "$@" bash "$H/bin/lookback.sh" > "$T/out" 2>&1
  RC=$?
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
count() { grep -c -- "$2" "$1" 2>/dev/null || true; }

# --- K1 the registry entry -----------------------------------------------------
L=$(jq -c '.lanes[]|select(.id=="lookback")' "$REG")
eq "K1 knob envs" "$(printf '%s' "$L" | jq -r '[.knobs[].env]|sort|join(" ")')" \
  "LLM_LANE_ENABLED LLM_RUNNER_ALLOWED LLM_USD_CAP_DAY LOOKBACK_ALERT_MIN LOOKBACK_APP_FILING LOOKBACK_BUNDLE_MAX_ITEMS LOOKBACK_CLUSTER_MIN LOOKBACK_DAYS LOOKBACK_DRY LOOKBACK_FOLLOWUP_DAYS LOOKBACK_MAX_ISSUES LOOKBACK_MAX_USD LOOKBACK_MODEL LOOKBACK_REREVIEW_MIN"
kv() { printf '%s' "$L" | jq -c --arg e "$1" '.knobs[]|select(.env==$e)|[.type,.default]'; }
eq "K1 LOOKBACK_MAX_USD" "$(kv LOOKBACK_MAX_USD)" '["float",15]'
eq "K1 LOOKBACK_MODEL" "$(kv LOOKBACK_MODEL)" '["string",""]'
# TEST-CHANGE (lead, BH-3327): llm-lane-knobs.bh-2533 requires every LLM lane's
# registry default to be 0 (the per-lane ceiling is a lane.<id>.llm_usd_cap_day
# settings row); the lane's spend stays bounded per run by LOOKBACK_MAX_USD.
eq "K1 LLM_USD_CAP_DAY" "$(kv LLM_USD_CAP_DAY)" '["float",0]'
eq "K1 LOOKBACK_DAYS" "$(kv LOOKBACK_DAYS)" '["int",7]'
eq "K1 LOOKBACK_MAX_ISSUES" "$(kv LOOKBACK_MAX_ISSUES)" '["int",5]'
eq "K1 lane shape" "$(printf '%s' "$L" | jq -c '[.scope,.script,.cadence,.boxes,.switch.name,.stats.cost_stage,.stats.log]')" \
  '["hub","bin/lookback.sh","45 6 * * 1",["hub"],"lane-off-lookback","lookback","logs/lookback.log"]'

# --- F / M / H the contract lib ------------------------------------------------
if [ -r "$LIB" ] && . "$LIB"; then
  a=$(lookback_fingerprint harness cromford file bin/x.sh); b=$(lookback_fingerprint harness cromford file bin/x.sh)
  [[ "$a" =~ ^[0-9a-f]{16}$ ]] && ok || bad "F1 fingerprint is not 16 hex chars: '$a'"
  eq "F1 stable across two calls" "$b" "$a"
  eq "F2 formula" "$a" "$(printf 'harness|cromford|file|bin/x.sh' | sha1sum | cut -c1-16)"
  for v in "app cromford file bin/x.sh" "harness project-3 file bin/x.sh" "harness cromford lane bin/x.sh" "harness cromford file bin/y.sh"; do
    # shellcheck disable=SC2086
    [ "$(lookback_fingerprint $v)" != "$a" ] && ok || bad "F2 changing one argument ($v) kept the fingerprint"
  done
  eq "M1 reason family" "$(lookback_reason_family "Build 1234 FAILED at abc1234def https://x.y/z  now")" "build failed at now"
  eq "M1 a 40-char sha" "$(lookback_reason_family "rebase of 0123456789abcdef0123456789abcdef01234567 conflicted")" "rebase of conflicted"
  M=$(lookback_item_match_jq)
  mt() { jq -n --argjson it "$1" "$M"' $it | item_matches($k;$v;$p)' --arg k "$2" --arg v "$3" --arg p "$4" 2>&1; }
  IT='{"files":["bin/x.sh"],"lane":"rebase","reason":"Build 1234 FAILED at abc1234def https://x.y/z  now","project":"project-3"}'
  eq "M2 file hit"   "$(mt "$IT" file bin/x.sh project-3)" true
  eq "M2 file miss"  "$(mt "$IT" file bin/y.sh project-3)" false
  eq "M2 lane hit"   "$(mt "$IT" lane rebase project-3)" true
  eq "M2 lane miss"  "$(mt "$IT" lane review project-3)" false
  eq "M2 reason hit" "$(mt "$IT" reason "$(lookback_reason_family "Build 1234 FAILED at abc1234def https://x.y/z  now")" project-3)" true
  eq "M2 reason miss" "$(mt "$IT" reason "build passed" project-3)" false
  eq "M2 project mismatch" "$(mt "$IT" lane rebase project-1)" false
  eq "M2 cromford ignores project" "$(mt "$IT" lane rebase cromford)" true
  eq "M2 no files" "$(mt '{"lane":"x","project":"project-3"}' file bin/x.sh project-3)" false
  HDR=$(sed -n '1,/^[a-z_]*()/p' "$LIB")
  for w in incomplete key_kind lookback_cluster followed_up_stopped 75 LOOKBACK_MAX_USD LOOKBACK_CLUSTER_MIN \
           LOOKBACK_ALERT_MIN LOOKBACK_REREVIEW_MIN LOOKBACK_FOLLOWUP_DAYS LOOKBACK_BUNDLE_MAX_ITEMS LOOKBACK_MODEL; do
    has "H1 header" "$HDR" "$w"
  done
else
  bad "F/M/H bin/lib/lookback-common.sh is missing or does not source"
fi

# --- S1 no collector ------------------------------------------------------------
fresh; drive
eq "S1 rc" "$RC" 0
eq "S1 log line" "$(count "$H/logs/lookback.log" 'collector not installed')" 1
eq "S1 no lane-alert" "$(lines "$T/calls.lane-alert")" 0
eq "S1 no agent-call" "$(lines "$T/calls.agent-call")" 0

# --- E1 empty week --------------------------------------------------------------
fresh; collector; stubs; drive STUB_ITEMS=0
eq "E1 rc" "$RC" 0
eq "E1 collector args" "$(cat "$T/calls.collect" 2>/dev/null)" "--days 7 --out $RUN/bundle.json"
eq "E1 exactly one no-repeat line" "$(count "$H/logs/lookback.log" 'no repeat failures in window')" 1
eq "E1 no lane-alert" "$(lines "$T/calls.lane-alert")" 0
eq "E1 no agent-call" "$(lines "$T/calls.agent-call")" 0
eq "E1 no job row" "$(lines "$T/calls.job_open")" 0
eq "E1 no clustering or filing" "$(lines "$T/calls.stub")" 0

# --- L1 lane off ------------------------------------------------------------------
fresh; collector; : > "$H/flags/lane-off-lookback"; drive STUB_ITEMS=3
eq "L1 rc" "$RC" 0
[ ! -e "$T/calls.collect" ] && ok || bad "L1 the collector ran with flags/lane-off-lookback set"
eq "L1 no lane-alert" "$(lines "$T/calls.lane-alert")" 0

# --- N2 collector fails ------------------------------------------------------------
fresh; collector; drive STUB_COLLECT_RC=3
eq "N2 rc" "$RC" 75
eq "N2 one ALERTS line" "$(count "$H/logs/ALERTS.log" 'lookback: collector rc=3')" 1
eq "N2 ALERTS has nothing else" "$(lines "$H/logs/ALERTS.log")" 1
eq "N2 no lane-alert" "$(lines "$T/calls.lane-alert")" 0
eq "N2 no job row" "$(lines "$T/calls.job_open")" 0
# rc 0 with a bundle that is not a bundle is the same failure, not an empty week
fresh; printf '#!/bin/bash\necho garbage > "$4"\n' > "$H/bin/lookback-collect.sh"; chmod +x "$H/bin/lookback-collect.sh"
drive
eq "N2b unparseable bundle rc" "$RC" 75
eq "N2b not an empty week" "$(count "$H/logs/lookback.log" 'no repeat failures')" 0
eq "N2b one ALERTS line" "$(count "$H/logs/ALERTS.log" 'week not reviewed')" 1

# --- N3 dry run ----------------------------------------------------------------------
# TEST-CHANGE (BH-3691): a dry run used to stop before clustering; the ticket
# wants its clusters in the digest, so it now clusters, files nothing and sends
# one warn summary. The "nothing filed" half of the old case is kept.
fresh; collector; stubs; clusters harness; rm -f "$RUN/clusters.json"; drive STUB_ITEMS=3 LOOKBACK_DRY=1
eq "N3 rc" "$RC" 0
has "N3 item count" "$(cat "$T/out")" "3 item(s)"
has "N3 source inventory" "$(cat "$T/out")" "alerts ok=true n=3 truncated=false"
eq "N3 clustered once" "$(count "$T/calls.stub" '^cluster ')" 1
eq "N3 no filer call" "$(count "$T/calls.stub" '^harness \|^board ')" 0
eq "N3 one lane-alert" "$(lines "$T/calls.lane-alert")" 1
has "N3 warn" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "--severity warn"
eq "N3 job row" "$(lines "$T/calls.job_open")" 1
fresh; collector; stubs; clusters harness; drive STUB_ITEMS=3 LOOKBACK_DRY=1
eq "N3b a seeded cluster: no cluster or filer call" "$(lines "$T/calls.stub")" 0
has "N3b it is listed" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "would file: harness Cluster 1"

# --- R1 same-day re-run reuses clusters.json ---------------------------------------
fresh; collector; stubs; clusters harness; drive STUB_ITEMS=3
eq "R1 rc" "$RC" 0
eq "R1 lookback_cluster_run not called" "$(count "$T/calls.stub" '^cluster ')" 0
eq "R1 the seeded cluster was filed" "$(count "$T/calls.stub" "^harness fp1 $RUN\$")" 1
eq "R1 job row opened once" "$(lines "$T/calls.job_open")" 1
eq "R1 job row closed with rc 0" "$(cat "$T/calls.job_close" 2>/dev/null)" "0 lookback"
# and with no clusters.json the clustering function IS called
fresh; collector; stubs; drive STUB_ITEMS=3
eq "R1b lookback_cluster_run called when nothing to reuse" "$(count "$T/calls.stub" '^cluster ')" 1

# --- L3 the settings row beats the default ------------------------------------------
fresh; collector; stubs; clusters harness harness; drive STUB_ITEMS=3
eq "L3 control: two filer calls" "$(count "$T/calls.stub" '^harness ')" 2
fresh; collector; stubs; clusters harness harness
jq -nc --argjson n "$NOW" '{fetched_at:$n,values:{"lane.lookback.lookback_max_issues":"1"},seeded:{}}' > "$H/state/settings-cache.json"
drive STUB_ITEMS=3
eq "L3 exactly one filer call" "$(count "$T/calls.stub" '^harness ')" 1
has "L3 over cap listed" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "over cap: Cluster 2 (2 items) fp2"

# --- C1 a ledger outage stops the walk ----------------------------------------------
fresh; collector; stubs; clusters harness harness; drive STUB_ITEMS=3 STUB_FILE_RCS=75
eq "C1 rc" "$RC" 0
eq "C1 second cluster never dispatched" "$(count "$T/calls.stub" '^harness ')" 1
has "C1 summary names the stop" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "ledger outage"
# rc 3 (commented) and rc 4 (not filed) do not use up the cap
fresh; collector; stubs; clusters harness harness harness
jq -nc --argjson n "$NOW" '{fetched_at:$n,values:{"lane.lookback.lookback_max_issues":"1"},seeded:{}}' > "$H/state/settings-cache.json"
drive STUB_ITEMS=3 STUB_FILE_RCS="3 4 0"
eq "C1b rc 3 and rc 4 are not counted as filed" "$(count "$T/calls.stub" '^harness ')" 3
AL=$(cat "$T/calls.lane-alert" 2>/dev/null)
has "C1b commented line" "$AL" "commented: stub fp1 rc=3"
has "C1b not-filed line" "$AL" "not filed: stub fp2 rc=4"
has "C1b filed line" "$AL" "filed: stub fp3 rc=0"

# --- T1 dispatch by target ----------------------------------------------------------
# TEST-CHANGE (BH-3691): app-target dispatch is opt-in (LOOKBACK_APP_FILING=1).
fresh; collector; stubs; clusters app harness; drive STUB_ITEMS=3 LOOKBACK_APP_FILING=1
eq "T1 order and target" "$(cut -d' ' -f1,2 "$T/calls.stub" | tr '\n' ,)" "board fp1,harness fp2,"
fresh; collector; clusters harness; drive STUB_ITEMS=3
eq "T1b rc" "$RC" 0
has "T1b no filer" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "not filed: filer not installed: Cluster 1"
has "T1b nothing counted as filed" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "0 filed"
fresh; collector; drive STUB_ITEMS=3
has "T1c clustering not installed" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "clustering not installed"

# --- V1 clustering outcomes that file nothing ---------------------------------------
fresh; collector; stubs; drive STUB_ITEMS=3 STUB_CLUSTER_RC=2
has "V1 invalid model output" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "invalid model output"
eq "V1 nothing filed" "$(count "$T/calls.stub" '^harness \|^board ')" 0
fresh; collector; stubs; drive STUB_ITEMS=3 STUB_CLUSTER_RC=75
has "V1 not configured" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "clustering not configured"
eq "V1 no agent-call from the driver" "$(lines "$T/calls.agent-call")" 0

# --- L4 the one summary alert --------------------------------------------------------
fresh; collector; stubs; clusters harness; drive STUB_ITEMS=3 STUB_TRUNC=1
eq "L4 exactly one lane-alert" "$(lines "$T/calls.lane-alert")" 1
AL=$(cat "$T/calls.lane-alert" 2>/dev/null)
has "L4 info" "$AL" "--severity info"
has "L4 id" "$AL" "--id lookback-$DATE lookback"
hasnt "L4 never critical" "$AL" "--critical"
has "L4 truncated source surfaced" "$AL" "source alerts: truncated"
has "L4 failed source surfaced" "$AL" "source builds: not ok"
has "L4 incomplete surfaced" "$AL" "bundle incomplete"
eq "L4 one run line in the log" "$(count "$H/logs/lookback.log" "items, ")" 1

# --- D1 the lock is dedupe --------------------------------------------------------------
fresh; collector
exec 8>"$H/locks/lookback.lock"; flock -n 8 || bad "D1 the test could not take the lock"
drive STUB_ITEMS=3
exec 8>&-
eq "D1 rc" "$RC" 0
[ ! -e "$T/calls.collect" ] && ok || bad "D1 a second instance collected while the lock was held"

# --- Z1 no model id -------------------------------------------------------------------
Z=0
for f in bin/lookback.sh bin/lib/lookback-common.sh catalog/lanes.d/lookback.json cron/lanes/465-lookback.cron; do
  [ -f "$DIR/$f" ] || { bad "Z1 $f missing"; continue; }
  Z=$((Z + $(grep -c 'claude-' "$DIR/$f")))
done
eq "Z1 claude- occurrences" "$Z" 0

echo "lookback-lane.bh-1795-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
