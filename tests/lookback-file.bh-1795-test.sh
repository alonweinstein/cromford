#!/bin/bash
# tests/lookback-file.bh-1795-test.sh — BH-3328 (BH-1795.3): lookback_file_harness
# in bin/lib/lookback-file.sh files one `ai-build` issue per harness cluster on
# example-org/cromford, or comments on the open one that already exists.
#
# DRIVEN, NOT GREPPED: every case runs the real bin/lookback.sh through
# `env -i … bash bin/lookback.sh` against a scratch $HARNESS ($T/h) rebuilt per
# case, with the real bin/lib/lookback-file.sh, gh-rest.sh and gh-rest-list.sh.
# Today's clusters.json is pre-seeded from a fixture, so the driver reuses it and
# no model is called. The recorders:
#   gh           on PATH; logs `<METHOD> <path>` to calls.gh, keeps a copy of
#                every --input / -F body=@ file as payload.<n>, and answers
#                `HTTP/2 <status>`, a blank line and a body chosen by path
#   jobs-client  job_ledger_row answers $STUB_LEDGER_RC / $STUB_LEDGER_ROW;
#                job_ledger_put logs {kind,key,status,detail} to calls.put
#   lane-alert   the one summary line, newlines as ` | `, in calls.lane-alert
#
#   F1  no row, no marker -> one create with ai-build, both items, the marker,
#       the bundle's PR string verbatim; one ledger PUT (issue 101, 2 ids)
#   F2  no row, open #77 carries the marker -> a comment on #77, only new ids,
#       the row written with issue 77 (a lost row healed)
#   F2b another fingerprint's marker, the fp in prose, a PR with the marker ->
#       none of them is a match; one create
#   F3  7 clusters, LOOKBACK_MAX_ISSUES=5 -> 5 creates in rank order, 2 over cap
#   F4  no em dash in any posted title or body
#   F5  ledger outage -> no POST at all, filing stopped
#   F6  create answers 422 -> no ledger PUT, not counted
#   F7  a row pointing at open #41 -> one comment with only the new id
#   F8  a row pointing at closed #40 -> a new issue, detail keeps prior_issue
#   F9  the open list answers 500 -> nothing posted, failed rc=1
#   F10 the row already lists every item -> no comment, not filed
#   F11 the state read of the row's issue answers 500 -> nothing posted
#   F12 a 2xx that is not a 201 with a number -> not counted, no row
#   F13 an open list that fills the 1000-row cap -> nothing posted
#   B1  a cluster with no fingerprint -> rc 4, no REST call
#   M1  mutation: the lib without its create call turns F1's count red
#   Z1  no `claude-` string in the lib
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' must not be in: $2" ;; *) ok ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "lookback-file.bh-1795-test: SKIPPED — jq missing"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "lookback-file.bh-1795-test: SKIPPED — flock missing"; exit 0; }

NOW=$(date -u +%s)
# The driver reads its own clock for the run dir; the test derives the same day
# from its one NOW read. determinism: ok the run dir is named by the driver's wall-clock day
DATE=$(date -u -d "@$NOW" +%Y-%m-%d)

REG=$(HARNESS_TEST_SANDBOX=1 bash -c '. "$1/bin/lib/lanes-registry.sh" && lanes_json_path "$1"' _ "$DIR") \
  || { echo "FAIL: could not render the lane registry"; exit 1; }
LIB="$DIR/bin/lib/lookback-file.sh"
FX="$DIR/tests/fixtures/lookback/file"
H="$T/h"
RUN="$H/state/lookback/$DATE"
REPO=example-org/cromford
FP=a1b2c3d4e5f60718
MARK="<!-- lookback-cluster: $FP -->"

# fresh [lib] — a new scratch harness for one case; [lib] replaces the real filer.
fresh() {
  scratch_rm "$H"; rm -rf "$T"/calls.* "$T/out" "$T"/payload.* "$T/sb"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$H/catalog" "$T/sb"
  : > "$H/env/global.env"
  cp "$DIR/bin/lookback.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
  cp "$DIR/bin/lib/lookback-common.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-list.sh" \
     "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lanes-registry.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/deployment.sh" "$H/bin/lib/"
  if [ -n "${1:-}" ]; then cp "$1" "$H/bin/lib/lookback-file.sh"; elif [ -r "$LIB" ]; then cp "$LIB" "$H/bin/lib/"; fi
  cp "$REG" "$H/catalog/lanes.json"
  cat > "$H/bin/jobs-client.sh" <<SH
job_lane_open()  { :; }
job_lane_close() { :; }
# BH-3691: the driver reads the lookback_cluster ledger once for its rolling-week
# cap and files nothing without it; an empty ledger here.
_jobs_req() { echo '{"ledgers":[]}'; }
job_ledger_row() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/calls.row"
  local rc="\${STUB_LEDGER_RC:-2}"
  [ "\$rc" = 0 ] && printf '%s\n' "\$STUB_LEDGER_ROW"
  return "\$rc"
}
job_ledger_put() {
  jq -nc --arg k "\$1" --arg v "\$2" --arg s "\$3" --arg d "\${4:-}" '{kind:\$k,key:\$v,status:\$s,detail:(\$d|fromjson)}' >> "$T/calls.put"
  return "\${STUB_PUT_RC:-0}"
}
SH
  cat > "$H/bin/lane-alert.sh" <<SH
#!/bin/bash
a="\$*"; printf '%s\n' "\${a//\$'\n'/ | }" >> "$T/calls.lane-alert"
SH
  cat > "$H/bin/lookback-collect.sh" <<SH
#!/bin/bash
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
mkdir -p "\$(dirname "\$out")"; cp "$FX/bundle.json" "\$out"
SH
  # The gh stub. STUB_CREATE_STATUS / STUB_CREATE_BODY, STUB_STATE_STATUS /
  # STUB_STATE, STUB_LIST_STATUS / STUB_LIST (a file) choose the answers.
  cat > "$T/sb/gh" <<SH
#!/bin/bash
m=GET p="" n=\$(ls "$T" | grep -c '^payload\.')
shift # api
while [ \$# -gt 0 ]; do
  case "\$1" in
    -i) ;;
    -X) m="\$2"; shift ;;
    --input) n=\$((n+1)); cp "\$2" "$T/payload.\$n"; shift ;;
    -F|-f) case "\$2" in body=@*) n=\$((n+1)); jq -Rs '{body:.}' "\${2#body=@}" > "$T/payload.\$n" ;; esac; shift ;;
    -H) shift ;;
    *) [ -z "\$p" ] && p="\$1" ;;
  esac; shift
done
printf '%s %s\n' "\$m" "\$p" >> "$T/calls.gh"
case "\$m \$p" in
  "POST repos/$REPO/issues")
    c=\$(grep -c '^POST repos/$REPO/issues\$' "$T/calls.gh"); num=\$((100 + c))
    printf 'HTTP/2 %s\n\n' "\${STUB_CREATE_STATUS:-201}"
    if [ -n "\${STUB_CREATE_BODY:-}" ]; then printf '%s\n' "\$STUB_CREATE_BODY"
    else printf '{"number":%s,"html_url":"https://github.com/$REPO/issues/%s"}\n' "\$num" "\$num"; fi ;;
  "POST repos/$REPO/issues/"*/comments)
    printf 'HTTP/2 201\n\n{"id":9}\n' ;;
  "GET repos/$REPO/issues")
    printf 'HTTP/2 %s\n\n' "\${STUB_LIST_STATUS:-200}"; cat "\${STUB_LIST:-/dev/null}" 2>/dev/null || true
    [ -n "\${STUB_LIST:-}" ] || printf '[]\n' ;;
  "GET repos/$REPO/issues/"*)
    printf 'HTTP/2 %s\n\n{"state":"%s"}\n' "\${STUB_STATE_STATUS:-200}" "\${STUB_STATE:-open}" ;;
  *) printf 'HTTP/2 500\n\n{}\n' ;;
esac
SH
  chmod +x "$H/bin/"*.sh "$T/sb/gh"
  mkdir -p "$RUN"
}
seed() { cp "$FX/$1" "$RUN/clusters.json"; }
drive() { # drive [VAR=value ...] -> rc in $RC, stdout in $T/out
  env -i PATH="$T/sb:$PATH" HOME="$T" HARNESS="$H" LANE_GATE_NOW="$NOW" TMPDIR="$T" \
    "$@" bash "$H/bin/lookback.sh" > "$T/out" 2>&1
  RC=$?
}
count() { if [ -f "$1" ]; then grep -c -- "$2" "$1" || true; else echo 0; fi; }
creates()  { count "$T/calls.gh" "^POST repos/$REPO/issues\$"; }
comments() { count "$T/calls.gh" "^POST repos/$REPO/issues/[0-9]*/comments\$"; }
puts()     { if [ -f "$T/calls.put" ]; then wc -l < "$T/calls.put" | tr -d ' '; else echo 0; fi; }
alert()    { cat "$T/calls.lane-alert" 2>/dev/null; }
# payload_of <n> — the n-th recorded payload (1-based).
payload_of() { cat "$T/payload.$1" 2>/dev/null; }
# a list fixture, one issue per argument, each `<number>|<pr:0|1>|<body>`
list() {
  local a; for a in "$@"; do
    IFS='|' read -r n pr b <<<"$a"
    jq -nc --argjson n "$n" --arg b "$b" --arg pr "$pr" '{number:$n,body:$b} + (if $pr=="1" then {pull_request:{url:"x"}} else {} end)'
  done | jq -s . > "$T/list.json"
}

# --- F1 create ---------------------------------------------------------------------
fresh; seed clusters-one.json; drive
eq "F1 rc" "$RC" 0
eq "F1 exactly one create" "$(creates)" 1
eq "F1 no comment" "$(comments)" 0
P=$(payload_of 1)
eq "F1 labels" "$(jq -c '.labels' <<<"$P")" '["ai-build"]'
B=$(jq -r '.body' <<<"$P")
has "F1 body lists i0" "$B" '`i0`'
has "F1 body lists i1" "$B" '`i1`'
has "F1 body has the marker" "$B" "$MARK"
eq "F1 the marker is the last line" "$(printf '%s\n' "$B" | tail -n 1)" "$MARK"
has "F1 PR string verbatim from the bundle" "$B" "PR: https://github.com/example-org/project-3/pull/912"
has "F1 ticket from the bundle" "$B" "ticket: TK-12"
has "F1 files" "$B" "files: bin/rebase.sh, bin/lib/x.sh"
has "F1 lane" "$B" "lane: rebase"
has "F1 cause" "$B" "The rebase lane stops after 3 rounds"
has "F1 proposed fix" "$B" "Teach the rebase lane to resolve the generated hunk."
hasnt "F1 a null PR is left out, not printed" "$B" "PR: null"
eq "F1 one ledger PUT" "$(puts)" 1
U=$(cat "$T/calls.put" 2>/dev/null)
eq "F1 put kind/key/status" "$(jq -r '"\(.kind) \(.key) \(.status)"' <<<"$U")" "lookback_cluster $FP filed"
eq "F1 put detail issue" "$(jq -r '.detail.issue' <<<"$U")" 101
eq "F1 put detail repo" "$(jq -r '.detail.repo' <<<"$U")" "$REPO"
eq "F1 put detail item_ids" "$(jq -c '.detail.item_ids' <<<"$U")" '["i0","i1"]'
eq "F1 put detail url from the response" "$(jq -r '.detail.url' <<<"$U")" "https://github.com/$REPO/issues/101"
eq "F1 put detail items/key" "$(jq -r '"\(.detail.items) \(.detail.key_kind) \(.detail.key_value) \(.detail.target)"' <<<"$U")" "2 file bin/rebase.sh harness"
[ "$(jq -r '.detail.filed_at' <<<"$U")" != null ] && ok || bad "F1 put detail has no filed_at"
eq "F1 no prior_issue on a first filing" "$(jq -r '.detail.prior_issue' <<<"$U")" null
eq "F1 the dedup read came first, for this fingerprint" "$(cat "$T/calls.row" 2>/dev/null)" "lookback_cluster $FP"
AL=$(alert)
has "F1 summary counts it" "$AL" "1 filed"
has "F1 summary names the issue and its url" "$AL" "filed: #101 "
has "F1 summary url is the response's" "$AL" "https://github.com/$REPO/issues/101"
hasnt "F1 the real filer ran" "$AL" "filer not installed"

# --- F2 a lost row healed by the marker ------------------------------------------------
fresh; seed clusters-one.json
list "77|0|Rebase trouble. Evidence: - \`i0\` project-3 ... $MARK" "12|0|unrelated"
drive STUB_LIST="$T/list.json"
eq "F2 no create" "$(creates)" 0
eq "F2 one comment" "$(comments)" 1
has "F2 the comment is on #77" "$(cat "$T/calls.gh")" "POST repos/$REPO/issues/77/comments"
C=$(payload_of 1 | jq -r '.body')
has "F2 comment carries the new id" "$C" '`i1`'
hasnt "F2 comment omits the id the body already lists" "$C" '`i0`'
has "F2 comment carries the marker" "$C" "$MARK"
eq "F2 one ledger PUT" "$(puts)" 1
U=$(cat "$T/calls.put" 2>/dev/null)
eq "F2 put issue 77" "$(jq -r '.detail.issue' <<<"$U")" 77
eq "F2 put status filed (there was no row)" "$(jq -r '.status' <<<"$U")" filed
eq "F2 put item_ids union" "$(jq -c '.detail.item_ids' <<<"$U")" '["i0","i1"]'
AL=$(alert)
has "F2 summary commented" "$AL" "commented: #77"
has "F2 summary 0 filed" "$AL" "0 filed"

# --- F2b the matcher's negatives -------------------------------------------------------
fresh; seed clusters-one.json
list "77|0|<!-- lookback-cluster: ffffffffffffffff --> mentions $FP in prose" "78|1|a PR $MARK"
drive STUB_LIST="$T/list.json"
eq "F2b one create" "$(creates)" 1
eq "F2b no comment" "$(comments)" 0
eq "F2b the create's row" "$(jq -r '.detail.issue' "$T/calls.put" 2>/dev/null)" 101

# --- F3 the cap, in rank order -----------------------------------------------------------
fresh; seed clusters-seven.json; drive LOOKBACK_MAX_ISSUES=5
eq "F3 five creates" "$(creates)" 5
T5=""; for i in 1 2 3 4 5; do T5="$T5$(payload_of "$i" | jq -r '.title'),"; done
eq "F3 creates in rank order" "$T5" "Cluster 1,Cluster 2,Cluster 3,Cluster 4,Cluster 5,"
AL=$(alert)
has "F3 over cap 6" "$AL" "over cap: Cluster 6 (2 items)"
has "F3 over cap 7" "$AL" "over cap: Cluster 7 (2 items)"
has "F3 five filed" "$AL" "5 filed"
eq "F3 five ledger PUTs" "$(puts)" 5

# --- F4 no em dash anywhere posted ---------------------------------------------------------
grep -q '—' "$FX/clusters-one.json" && grep -q '—' "$FX/bundle.json" && ok || bad "F4 the fixtures carry no em dash to strip"
fresh; seed clusters-one.json; drive
P=$(payload_of 1)
hasnt "F4 create title" "$(jq -r '.title' <<<"$P")" '—'
hasnt "F4 create body" "$(jq -r '.body' <<<"$P")" '—'
has "F4 the dash became a hyphen" "$(jq -r '.title' <<<"$P")" "same file - twice"
has "F4 the reason is there, dash stripped" "$(jq -r '.body' <<<"$P")" "reason: rebase conflicted - gave up after 3 rounds"
fresh; seed clusters-one.json
drive STUB_LEDGER_RC=0 STUB_LEDGER_ROW='{"status":"filed","detail":"{\"repo\":\"example-org/cromford\",\"issue\":41,\"item_ids\":[\"i1\"]}"}'
hasnt "F4 comment body" "$(payload_of 1 | jq -r '.body')" '—'
has "F4 the comment carried the dashed reason" "$(payload_of 1 | jq -r '.body')" "gave up after 3 rounds"

# --- F5 ledger outage ------------------------------------------------------------------------
fresh; seed clusters-seven.json; drive STUB_LEDGER_RC=1
eq "F5 no REST call at all" "$(count "$T/calls.gh" .)" 0
eq "F5 no ledger PUT" "$(puts)" 0
AL=$(alert)
has "F5 filing stopped" "$AL" "ledger outage, filing stopped"
has "F5 the rest not dispatched" "$AL" "not dispatched: Cluster 2"
eq "F5 one ledger read, then stop" "$(count "$T/calls.row" .)" 1

# --- F6 a failed create -----------------------------------------------------------------------
fresh; seed clusters-one.json; drive STUB_CREATE_STATUS=422 STUB_CREATE_BODY='{"message":"Validation Failed"}'
eq "F6 the create was tried" "$(creates)" 1
eq "F6 no ledger PUT" "$(puts)" 0
AL=$(alert)
has "F6 failed" "$AL" "failed rc=1"
has "F6 the status is named" "$AL" "create failed HTTP 422"
has "F6 not counted" "$AL" "0 filed"

# --- F7 a row pointing at an open issue ----------------------------------------------------------
fresh; seed clusters-one.json
drive STUB_LEDGER_RC=0 STUB_STATE=open \
  STUB_LEDGER_ROW='{"status":"followed_up_recurred","detail":"{\"repo\":\"example-org/cromford\",\"issue\":41,\"item_ids\":[\"i0\"],\"filed_at\":\"2026-08-01T00:00:00Z\"}"}'
eq "F7 no create" "$(creates)" 0
eq "F7 no list read (the row answered)" "$(count "$T/calls.gh" "^GET repos/$REPO/issues\$")" 0
eq "F7 one comment" "$(comments)" 1
has "F7 on #41" "$(cat "$T/calls.gh")" "POST repos/$REPO/issues/41/comments"
C=$(payload_of 1 | jq -r '.body')
has "F7 comment has the new id" "$C" '`i1`'
hasnt "F7 comment omits the known id" "$C" '`i0`'
has "F7 comment says how many are new" "$C" "1 new item"
U=$(cat "$T/calls.put" 2>/dev/null)
eq "F7 status kept" "$(jq -r '.status' <<<"$U")" followed_up_recurred
eq "F7 item_ids union" "$(jq -c '.detail.item_ids' <<<"$U")" '["i0","i1"]'
eq "F7 filed_at kept" "$(jq -r '.detail.filed_at' <<<"$U")" 2026-08-01T00:00:00Z
AL=$(alert)
has "F7 summary" "$AL" "commented: #41"
has "F7 0 filed" "$AL" "0 filed"

# --- F8 a row pointing at a closed issue -----------------------------------------------------------
fresh; seed clusters-one.json
drive STUB_LEDGER_RC=0 STUB_STATE=closed \
  STUB_LEDGER_ROW='{"status":"followed_up_stopped","detail":{"repo":"example-org/cromford","issue":40,"item_ids":["i0","i1"]}}'
eq "F8 one create" "$(creates)" 1
eq "F8 no comment" "$(comments)" 0
U=$(cat "$T/calls.put" 2>/dev/null)
eq "F8 prior_issue kept" "$(jq -r '.detail.prior_issue' <<<"$U")" 40
eq "F8 new issue" "$(jq -r '"\(.status) \(.detail.issue)"' <<<"$U")" "filed 101"
has "F8 counted" "$(alert)" "1 filed"
# A 404 on the row's issue (deleted or transferred) is the same as closed.
fresh; seed clusters-one.json
drive STUB_LEDGER_RC=0 STUB_STATE_STATUS=404 \
  STUB_LEDGER_ROW='{"status":"filed","detail":{"repo":"example-org/cromford","issue":40,"item_ids":["i0"]}}'
eq "F8b a 404 falls through to create" "$(creates)" 1
eq "F8b prior_issue" "$(jq -r '.detail.prior_issue' "$T/calls.put" 2>/dev/null)" 40

# --- F9 the open list cannot be read ---------------------------------------------------------------
fresh; seed clusters-one.json; drive STUB_LIST_STATUS=500
eq "F9 no create" "$(creates)" 0
eq "F9 no comment" "$(comments)" 0
eq "F9 no ledger PUT" "$(puts)" 0
AL=$(alert)
has "F9 failed" "$AL" "failed rc=1"
has "F9 named" "$AL" "open issue list unverifiable"

# --- F10 every item already listed ----------------------------------------------------------------
fresh; seed clusters-one.json
drive STUB_LEDGER_RC=0 STUB_STATE=open \
  STUB_LEDGER_ROW='{"status":"filed","detail":{"repo":"example-org/cromford","issue":41,"item_ids":["i0","i1"]}}'
eq "F10 no comment" "$(comments)" 0
eq "F10 no create" "$(creates)" 0
eq "F10 no PUT" "$(puts)" 0
has "F10 not filed" "$(alert)" "not filed: #41 already lists every item"

# --- F11 the row's issue state cannot be read ---------------------------------------------------------
fresh; seed clusters-one.json
drive STUB_LEDGER_RC=0 STUB_STATE_STATUS=500 \
  STUB_LEDGER_ROW='{"status":"filed","detail":{"repo":"example-org/cromford","issue":41,"item_ids":["i0"]}}'
eq "F11 no create" "$(creates)" 0
eq "F11 no comment" "$(comments)" 0
has "F11 failed" "$(alert)" "issue state unverifiable #41"

# --- F12 a 2xx that is not a real create ---------------------------------------------------------------
fresh; seed clusters-one.json; drive STUB_CREATE_STATUS=200
eq "F12a a 200 writes no row" "$(puts)" 0
has "F12a not counted" "$(alert)" "0 filed"
fresh; seed clusters-one.json; drive STUB_CREATE_BODY='{"html_url":"x"}'
eq "F12b a 201 with no number writes no row" "$(puts)" 0
has "F12b not counted" "$(alert)" "create failed HTTP 201"

# --- F13 an open list at the helper's 1000-row cap proves nothing absent -----------------------------------
fresh; seed clusters-one.json
jq -nc '[range(1;1001) | {number: ., body: "unrelated"}]' > "$T/list.json"
drive STUB_LIST="$T/list.json"
eq "F13 no create" "$(creates)" 0
eq "F13 no comment" "$(comments)" 0
has "F13 named" "$(alert)" "open issue list truncated"

# --- B1 a bad cluster ---------------------------------------------------------------------------------
fresh
jq -c '.[0].fingerprint = ""' "$FX/clusters-one.json" > "$RUN/clusters.json"
drive
eq "B1 no REST call" "$(count "$T/calls.gh" .)" 0
eq "B1 no ledger read" "$(count "$T/calls.row" .)" 0
has "B1 not filed" "$(alert)" "not filed: bad cluster"
# ... and the function's own rc is 4.
B1RC=$(HARNESS="$H" bash -c '. "$1/bin/lib/lookback-common.sh"; . "$1/bin/lib/lookback-file.sh" || exit 9
  lookback_file_harness "{\"fingerprint\":\"\",\"title\":\"x\",\"item_ids\":[]}" "$2" >/dev/null; echo $?' _ "$H" "$RUN")
eq "B1 rc 4" "$B1RC" 4

# --- M1 mutation: the create call removed -----------------------------------------------------------------
if [ -r "$LIB" ]; then
  grep -v 'gh_rest POST "repos/' "$LIB" > "$T/mutant.sh"
  [ "$(wc -l < "$T/mutant.sh")" -lt "$(wc -l < "$LIB")" ] && ok || bad "M1 the mutation removed nothing"
  fresh "$T/mutant.sh"; seed clusters-one.json; drive
  [ "$(creates)" != 1 ] && ok || bad "M1 F1's create count stayed 1 with the create call deleted"
  eq "M1 and no row was written" "$(puts)" 0
else
  bad "M1 $LIB missing"
fi

# --- Z1 no model id ---------------------------------------------------------------------------------------
if [ -f "$LIB" ]; then eq "Z1 claude- occurrences" "$(grep -c 'claude-' "$LIB")" 0; else bad "Z1 $LIB missing"; fi

echo "lookback-file.bh-1795-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
