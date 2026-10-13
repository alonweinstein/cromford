#!/bin/bash
# tests/lookback-live.bh-3691-test.sh — BH-3691: turning the lookback lane on.
# A dry week clusters and reports what it would file in the warn digest and
# files nothing; a live run files at most LOOKBACK_MAX_ISSUES in any rolling 7
# days, counted from the ledger and fail-closed; app-target clusters are not
# filed on a product board unless LOOKBACK_APP_FILING=1; every summary carries a
# measure line; the kill switch and the harness filer's dedupe/label/evidence
# hold through the real driver.
#
# DRIVEN, NOT GREPPED: every case runs the real bin/lookback.sh through
# `env -i … bash` against a scratch $HARNESS ($T/h) rebuilt per case (the same
# scaffolding as tests/lookback-lane.bh-1795-test.sh, copied, not sourced). The
# jobs client is a file-backed stub: $T/ledger/<fp> is one ledger row, served by
# _jobs_req GET /api/ledger (the list the driver reads) and by
# job_ledger_list/_row/_put (what the follow-up and the real filer use). The
# gh_rest* functions are recorders defined in the same stub, so the real
# bin/lib/lookback-file.sh never sources the real gh-rest.sh.
#
#   DR1  LOOKBACK_DRY=1 clusters once and sends ONE warn summary with `would file:`
#   DR2  the same run through the real filer: no filer call, no POST
#   DR3  DRY=1 with a due follow-up row: `would comment`, no comment, no put
#   DR4  LOOKBACK_DRY=yes / 2 is dry, says so, and the follow-up writes nothing
#   DR5  LOOKBACK_DRY=0 dispatches both clusters, --severity info
#   WC1  a row filed 6 days ago uses up one of MAX=2
#   WC2  a row filed 8 days ago but updated 1h ago is not counted
#   WC3  a 1000-row ledger page: nothing dispatched, `week cap unverifiable`
#   WC4  _jobs_req rc 1: same
#   WC5  a body with no `ledgers` array: same
#   WC6  no _jobs_req at all: same
#   WC7  ledger rows that are not objects: same
#   AP1  an app cluster with LOOKBACK_APP_FILING unset is never filed on a board
#   AP2  LOOKBACK_APP_FILING=1 from the settings cache files it
#   MS1  the measure line counts filed / followed up / recurred / merged fix
#   MS2  an unreadable ledger says so, never zeros
#   KS1  flags/lane-off-lookback: nothing runs, dry or live
#   KS2  a pause_flags row (flag_sync) does the same
#   DD1  the real harness filer: marker -> comment, no create; create -> ai-build + evidence
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' must not be in: $2" ;; *) ok ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "lookback-live.bh-3691-test: SKIPPED — jq missing"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "lookback-live.bh-3691-test: SKIPPED — flock missing"; exit 0; }

NOW=$(date -u +%s)
# determinism: ok the run dir is named by the driver's wall-clock day, derived from the one NOW read
DATE=$(date -u -d "@$NOW" +%Y-%m-%d)
iso() { jq -rn --argjson t "$1" '$t|todate'; }

REG=$(HARNESS_TEST_SANDBOX=1 bash -c '. "$1/bin/lib/lanes-registry.sh" && lanes_json_path "$1"' _ "$DIR") \
  || { echo "FAIL: could not render the lane registry"; exit 1; }
H="$T/h"
RUN="$H/state/lookback/$DATE"
PRURL="https://github.com/example-org/cromford/pull/42"

# fresh — a new scratch harness for one case: driver, lane gate, the stub jobs
# client (ledger + gh recorders), the stub collector, lane-alert recorder, and
# a cluster stub that copies $STUB_CLUSTERS to the clusters file.
fresh() {
  scratch_rm "$H"; rm -rf "$T"/calls.* "$T/out" "$T/ledger" "$T/payload.json" "$T/comments"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$H/catalog" "$T/ledger" "$T/comments"
  : > "$H/env/global.env"
  cp "$DIR/bin/lookback.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
  cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lanes-registry.sh" "$DIR/bin/lib/env-path.sh" \
     "$DIR/bin/lib/lookback-common.sh" "$DIR/bin/lib/deployment.sh" "$H/bin/lib/"
  cp "$REG" "$H/catalog/lanes.json"
  cat > "$H/bin/jobs-client.sh" <<SH
job_lane_open()  { printf '%s\n' "\$*" >> "$T/calls.job_open"; }
job_lane_close() { printf '%s\n' "\$*" >> "$T/calls.job_close"; }
# a pause_flags row for lane-off-lookback when STUB_PAUSE_ROW=1 (flag_sync drives the file)
flag_sync() {
  if [ "\${STUB_PAUSE_ROW:-0}" = 1 ] && [ "\$1" = lane-off-lookback ]; then : > "$H/flags/\$1"; return 0; fi
  return 2
}
if [ "\${STUB_NO_JOBS_REQ:-0}" != 1 ]; then
_jobs_req() {
  printf '%s\n' "\$*" >> "$T/calls.jobs_req"
  [ "\${STUB_LEDGER_RC:-0}" = 0 ] || return "\$STUB_LEDGER_RC"
  if [ -n "\${STUB_LEDGER_BODY:-}" ]; then cat "\$STUB_LEDGER_BODY"; return 0; fi
  local f; for f in "$T/ledger"/*; do if [ -f "\$f" ]; then cat "\$f"; fi; done | jq -sc '{ledgers:., as_of:"x"}'
}
fi
job_ledger_list() { local f; for f in "$T/ledger"/*; do if [ -f "\$f" ]; then jq -r '[.key,.status,"-","-"]|@tsv' "\$f"; fi; done; }
job_ledger_row()  { [ -f "$T/ledger/\$2" ] || return 2; jq -c '{status,detail}' "$T/ledger/\$2"; }
job_ledger_put()  {
  printf 'put %s %s %s\n' "\$1" "\$2" "\$3" >> "$T/calls.put"
  jq -nc --arg k "\$2" --arg s "\$3" --arg d "\$4" '{kind:"lookback_cluster",key:\$k,status:\$s,detail:\$d,updated_at:"now"}' > "$T/ledger/\$2"
}
gh_rest() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/calls.gh"
  local a prev=""; for a in "\$@"; do [ "\$prev" = --input ] && cp "\$a" "$T/payload.json"; prev="\$a"; done
  GH_REST_STATUS=201
  echo '{"number":501,"html_url":"https://github.com/example-org/cromford/issues/501"}'
}
gh_rest_issue_list()  { printf 'list %s\n' "\$*" >> "$T/calls.gh"; GH_REST_STATUS=200; if [ -n "\${STUB_OPEN_ISSUES:-}" ]; then cat "\$STUB_OPEN_ISSUES"; else echo '[]'; fi; }
gh_rest_issue_state() { printf 'state %s\n' "\$*" >> "$T/calls.gh"; GH_REST_STATUS=200; echo open; }
gh_rest_comment()     { printf 'comment %s %s\n' "\$1" "\$2" >> "$T/calls.gh"; cp "\$3" "$T/comments/\$2.txt"; return 0; }
SH
  cat > "$H/bin/lane-alert.sh" <<SH
#!/bin/bash
a="\$*"; printf '%s\n' "\${a//\$'\n'/ | }" >> "$T/calls.lane-alert"
SH
  cat > "$H/bin/lookback-collect.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.collect"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
mkdir -p "\$(dirname "\$out")"
jq -n --argjson n "\${STUB_ITEMS:-3}" --argjson now "$NOW" --arg pr "$PRURL" '
  {window:{from:(\$now-7*86400|todate),to:(\$now|todate)},
   items:[range(\$n)|{id:"i\(.)",source:"alerts",at:(\$now-3600*(.+1)|todate),project:"cromford",
                     ticket:null,pr:\$pr,files:["bin/x.sh"],lane:"rebase",reason:"rebase failed \(.)"}],
   sources:{alerts:{ok:true,n:\$n,truncated:false}},incomplete:false}' > "\$out"
SH
  cat > "$H/bin/lib/lookback-cluster.sh" <<'SH'
lookback_cluster_run() { printf 'cluster %s %s\n' "$1" "$2" >> "$LOOKBACK_STUB_CALLS"; cp "$STUB_CLUSTERS" "$2"; }
SH
  cat > "$H/bin/lib/lookback-board.sh" <<'SH'
lookback_file_board() { printf 'board %s %s\n' "$(jq -r .fingerprint <<<"$1")" "$2" >> "$LOOKBACK_STUB_CALLS"; echo "stub board rc=0"; }
SH
  chmod +x "$H/bin/"*.sh
}
# stubfile — the harness filer is a recorder (rc 0 each call)
stubfile() {
  cat > "$H/bin/lib/lookback-file.sh" <<'SH'
lookback_file_harness() { printf 'harness %s %s\n' "$(jq -r .fingerprint <<<"$1")" "$2" >> "$LOOKBACK_STUB_CALLS"; echo "stub $(jq -r .fingerprint <<<"$1") rc=0"; }
SH
}
realfile() { cp "$DIR/bin/lib/lookback-file.sh" "$H/bin/lib/"; }
realfollowup() { cp "$DIR/bin/lib/lookback-followup.sh" "$H/bin/lib/"; }
# clusters <target>... — write $T/clusters.src, one cluster per target
clusters() {
  local i=0 t; for t in "$@"; do i=$((i+1))
    jq -nc --arg t "$t" --argjson i "$i" '{fingerprint:"fp\($i)",key_kind:"file",key_value:"bin/f\($i).sh",
      item_ids:["i0","i1"],target:$t,project:"cromford",title:"Cluster \($i)",cause:"c",proposed_fix:"p"}'
  done | jq -s . > "$T/clusters.src"
}
# seed <fp> <status> <filed_at_epoch> [extra detail json] [updated_at]
seed() {
  local x="${4:-}"; [ -n "$x" ] || x='{}'
  jq -nc --arg k "$1" --arg s "$2" --arg f "$(iso "$3")" --argjson x "$x" --arg u "${5:-$(iso "$NOW")}" '
    {kind:"lookback_cluster",key:$k,status:$s,updated_at:$u,
     detail:({repo:"example-org/cromford",issue:77,filed_at:$f,key_kind:"lane",key_value:"rebase",
              project:"cromford",target:"harness",items:2,item_ids:["old1"]} + $x | tojson)}' > "$T/ledger/$1"
}
drive() { # drive [VAR=value ...] -> rc in $RC, stdout in $T/out
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" LANE_GATE_NOW="$NOW" STUB_CLUSTERS="$T/clusters.src" \
    LOOKBACK_STUB_CALLS="$T/calls.stub" "$@" bash "$H/bin/lookback.sh" > "$T/out" 2>&1
  RC=$?
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
count() { if [ -f "$1" ]; then grep -c -- "$2" "$1" || true; else echo 0; fi; }
AL() { cat "$T/calls.lane-alert" 2>/dev/null; }

# --- DR1 dry run clusters and reports ------------------------------------------------
fresh; stubfile; clusters harness harness; drive LOOKBACK_DRY=1
eq "DR1 rc" "$RC" 0
eq "DR1 clustering called once" "$(count "$T/calls.stub" '^cluster ')" 1
eq "DR1 exactly one lane-alert" "$(lines "$T/calls.lane-alert")" 1
has "DR1 warn" "$(AL)" "--severity warn"
has "DR1 id" "$(AL)" "--id lookback-$DATE lookback"
has "DR1 head" "$(AL)" "lookback $DATE DRY RUN: 3 items, 2 clusters, 0 filed"
has "DR1 would file 1" "$(AL)" "would file: harness Cluster 1 (2 items) fp1"
has "DR1 would file 2" "$(AL)" "would file: harness Cluster 2 (2 items) fp2"
has "DR1 go-live step" "$(AL)" "dry run: nothing filed; go live with bin/harness-ctl.sh set lookback LOOKBACK_DRY 0"
has "DR1 measure" "$(AL)" "measure: 0 clusters filed to date"
has "DR1 inventory still printed" "$(cat "$T/out")" "3 item(s)"
has "DR1 log says dry" "$(cat "$H/logs/lookback.log" 2>/dev/null)" "(dry)"

# --- DR2 the same run files nothing through the real filer -----------------------------
eq "DR2 no filer call (stub)" "$(count "$T/calls.stub" '^harness \|^board ')" 0
fresh; realfile; clusters harness harness app; drive LOOKBACK_DRY=1 LOOKBACK_APP_FILING=1
eq "DR2 rc" "$RC" 0
eq "DR2 no GitHub call at all" "$(lines "$T/calls.gh")" 0
eq "DR2 no board filer call" "$(count "$T/calls.stub" '^board ')" 0
eq "DR2 no ledger put" "$(lines "$T/calls.put")" 0
has "DR2 app would file" "$(AL)" "would file: app Cluster 3 (2 items) fp3"

# --- DR3 dry follow-up writes nothing ----------------------------------------------------
fresh; stubfile; realfollowup; clusters; seed fpA filed $((NOW - 31*86400)); drive LOOKBACK_DRY=1
eq "DR3 rc" "$RC" 0
has "DR3 would comment" "$(AL)" "would comment example-org/cromford#77 fpA: recurred: 3 new"
eq "DR3 no comment" "$(count "$T/calls.gh" '^comment ')" 0
eq "DR3 no put" "$(lines "$T/calls.put")" 0

# --- DR4 anything but 0/1 is dry ------------------------------------------------------------
for v in yes 2; do
  fresh; stubfile; realfollowup; clusters harness; seed fpA filed $((NOW - 31*86400)); drive LOOKBACK_DRY="$v"
  eq "DR4 rc ($v)" "$RC" 0
  eq "DR4 no filer call ($v)" "$(count "$T/calls.stub" '^harness \|^board ')" 0
  has "DR4 note ($v)" "$(AL)" "LOOKBACK_DRY=$v is not 0 or 1, treated as dry"
  has "DR4 head ($v)" "$(AL)" "DRY RUN:"
  eq "DR4 follow-up wrote no comment ($v)" "$(count "$T/calls.gh" '^comment ')" 0
  eq "DR4 follow-up wrote no put ($v)" "$(lines "$T/calls.put")" 0
done

# --- DR5 live dispatches ------------------------------------------------------------------
fresh; stubfile; clusters harness harness; drive LOOKBACK_DRY=0
eq "DR5 two filer calls" "$(count "$T/calls.stub" '^harness ')" 2
has "DR5 info" "$(AL)" "--severity info"
hasnt "DR5 not a dry head" "$(AL)" "DRY RUN"
has "DR5 head" "$(AL)" "lookback $DATE: 3 items, 2 clusters, 2 filed"
fresh; stubfile; clusters harness; drive
eq "DR5 unset LOOKBACK_DRY is live" "$(count "$T/calls.stub" '^harness ')" 1

# --- WC the rolling-week cap ----------------------------------------------------------------
fresh; stubfile; clusters harness harness harness; seed fpOld filed $((NOW - 6*86400)); drive LOOKBACK_MAX_ISSUES=2
eq "WC1 one filer call" "$(count "$T/calls.stub" '^harness ')" 1
has "WC1 over cap names the week" "$(AL)" "over cap (week: 1 already filed): Cluster 2 (2 items) fp2"
has "WC1 over cap 3" "$(AL)" "over cap (week: 1 already filed): Cluster 3"
eq "WC1 one ledger GET" "$(count "$T/calls.jobs_req" '^GET /api/ledger?kind=lookback_cluster&limit=1000$')" 1
fresh; stubfile; clusters harness harness harness
seed fpOld filed $((NOW - 8*86400)) '{}' "$(iso $((NOW - 3600)))"; drive LOOKBACK_MAX_ISSUES=2
eq "WC2 old filed_at is not this week" "$(count "$T/calls.stub" '^harness ')" 2
# a full page cannot prove the count
jq -nc --argjson n "$NOW" '{ledgers:[range(1000)|{key:"k\(.)",status:"followed_up_stopped",detail:"{}"}]}' > "$T/full.json"
wc_closed() { # wc_closed <case> <reason fragment>
  eq "$1 no filer call" "$(count "$T/calls.stub" '^harness \|^board ')" 0
  has "$1 unverifiable" "$(AL)" "week cap unverifiable ($2"
  has "$1 filing stopped" "$(AL)" "filing stopped"
  has "$1 not dispatched 1" "$(AL)" "not dispatched: Cluster 1"
  has "$1 not dispatched 2" "$(AL)" "not dispatched: Cluster 2"
  has "$1 measure unreadable" "$(AL)" "measure: ledger unreadable ($2"
  hasnt "$1 no zero measure" "$(AL)" "0 clusters filed to date"
}
fresh; stubfile; clusters harness harness; drive STUB_LEDGER_BODY="$T/full.json"; wc_closed WC3 "ledger page full"
fresh; stubfile; clusters harness harness; drive STUB_LEDGER_RC=1; wc_closed WC4 "ledger read rc=1"
echo '{}' > "$T/empty.json"
fresh; stubfile; clusters harness harness; drive STUB_LEDGER_BODY="$T/empty.json"; wc_closed WC5 "no ledgers array"
fresh; stubfile; clusters harness harness; drive STUB_NO_JOBS_REQ=1; wc_closed WC6 "no jobs client"
# rows the count cannot parse are an unverifiable week, never zero filed
echo '{"ledgers":["x"]}' > "$T/odd.json"
fresh; stubfile; clusters harness harness; drive STUB_LEDGER_BODY="$T/odd.json"; wc_closed WC7 "ledger rows unparseable"

# --- AP app filing is opt-in ----------------------------------------------------------------
fresh; stubfile; clusters app; drive
eq "AP1 no board call" "$(count "$T/calls.stub" '^board ')" 0
has "AP1 not filed" "$(AL)" "not filed: app filing off: Cluster 1"
has "AP1 0 filed" "$(AL)" "1 clusters, 0 filed"
# and it does not use up the cap
fresh; stubfile; clusters app harness; drive LOOKBACK_MAX_ISSUES=1
eq "AP1b the harness cluster still files" "$(count "$T/calls.stub" '^harness ')" 1
fresh; stubfile; clusters app
jq -nc --argjson n "$NOW" '{fetched_at:$n,values:{"lane.lookback.lookback_app_filing":"1"},seeded:{}}' > "$H/state/settings-cache.json"
drive
eq "AP2 settings row files on the board" "$(count "$T/calls.stub" '^board fp1 ')" 1

# --- MS the measure line --------------------------------------------------------------------
fresh; stubfile; clusters harness
seed fa filed $((NOW - 10*86400))
seed fb followed_up_recurred $((NOW - 40*86400)) '{"fix_merged":"yes","fix_pr":9}'
seed fc followed_up_stopped $((NOW - 40*86400)) '{"fix_merged":"yes","fix_pr":8}'
seed fd followed_up_stopped $((NOW - 40*86400)) '{"fix_merged":"none"}'
drive LOOKBACK_DRY=1
has "MS1 measure" "$(AL)" "measure: 4 clusters filed to date, 0 in the last 7 days, 3 followed up (1 recurred, 2 stopped), 2 with a merged fix (1 of those recurred)"
fresh; stubfile; clusters harness; drive LOOKBACK_DRY=1 STUB_LEDGER_RC=1
has "MS2 unreadable" "$(AL)" "measure: ledger unreadable (ledger read rc=1)"
hasnt "MS2 no zeros" "$(AL)" "0 clusters filed to date"

# --- KS the kill switch -----------------------------------------------------------------------
for d in 1 0; do
  fresh; stubfile; clusters harness; : > "$H/flags/lane-off-lookback"; drive LOOKBACK_DRY=$d
  eq "KS1 rc (DRY=$d)" "$RC" 0
  eq "KS1 no collector (DRY=$d)" "$(lines "$T/calls.collect")" 0
  eq "KS1 no cluster/file (DRY=$d)" "$(lines "$T/calls.stub")" 0
  eq "KS1 no alert (DRY=$d)" "$(lines "$T/calls.lane-alert")" 0
  fresh; stubfile; clusters harness; drive LOOKBACK_DRY=$d STUB_PAUSE_ROW=1
  eq "KS2 rc (DRY=$d)" "$RC" 0
  eq "KS2 no collector (DRY=$d)" "$(lines "$T/calls.collect")" 0
  eq "KS2 no cluster/file (DRY=$d)" "$(lines "$T/calls.stub")" 0
  eq "KS2 no alert (DRY=$d)" "$(lines "$T/calls.lane-alert")" 0
done

# --- DD1 the real harness filer: dedupe, label, evidence ------------------------------------------
fresh; realfile; clusters harness
jq -nc '[{number:300,body:"x\n<!-- lookback-cluster: fp1 -->",created_at:"2026-09-01T00:00:00Z"}]' > "$T/open.json"
drive STUB_OPEN_ISSUES="$T/open.json"
eq "DD1 marker: no create" "$(count "$T/calls.gh" '^POST repos/example-org/cromford/issues$')" 0
eq "DD1 marker: one comment on #300" "$(count "$T/calls.gh" '^comment example-org/cromford 300$')" 1
has "DD1 commented" "$(AL)" "commented: #300"
fresh; realfile; clusters harness; drive
eq "DD1 create: one POST" "$(count "$T/calls.gh" '^POST repos/example-org/cromford/issues$')" 1
eq "DD1 create: ai-build label" "$(jq -c .labels "$T/payload.json" 2>/dev/null)" '["ai-build"]'
has "DD1 create: evidence" "$(jq -r .body "$T/payload.json" 2>/dev/null)" "Evidence:"
has "DD1 create: the item's PR" "$(jq -r .body "$T/payload.json" 2>/dev/null)" "PR: $PRURL"
has "DD1 filed" "$(AL)" "1 filed"
eq "DD1 ledger row written" "$(cat "$T/calls.put" 2>/dev/null)" "put lookback_cluster fp1 filed"

echo "lookback-live.bh-3691-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
