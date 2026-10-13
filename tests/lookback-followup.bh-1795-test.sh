#!/bin/bash
# tests/lookback-followup.bh-1795-test.sh — BH-1795.4: lookback_followup_run,
# the 30-day check on every filed cluster: did the failure family stop or recur?
#
# The lib is sourced into this shell against a scratch $HARNESS ($T/h). The
# job_ledger_* functions, gh_rest_comment and lookback_board_comment are
# file-backed recorders (defined AFTER the source, so they replace the real
# ones); the collector is a stub that writes tests/fixtures/lookback/followup/
# items.json with `at` = NOW - age_s. Every filed_at is derived from ONE NOW.
# D2 drives the real bin/lookback.sh, with the real board comment path and a
# curl recorder on PATH.
#
#   U1  filed 31 days ago + one matching new item -> one gh comment `recurred: 1 new`,
#       then a followed_up_recurred put; the comment comes first; no state read
#   U2  no match, every source ok -> `stopped`, followed_up_stopped
#   U3  filed 29 days ago -> no collector run, no comment, no put
#   U4  no match, a source not ok / truncated / bundle incomplete -> deferred, nothing written
#   U5  job_ledger_list rc 1 -> rc 75 `follow-up skipped: ledger unreadable`, no collector
#   U6  a board row goes to lookback_board_comment, not gh
#   U7  the comment fails -> no put
#   U8  two due rows + a full 1000-row page -> ONE collector run, `incomplete` said,
#       a file key is exact (no prefix match)
#   U9  LOOKBACK_DRY=1 -> no comment, no put
#   U10 bad LOOKBACK_FOLLOWUP_DAYS, incomplete detail, collector missing / failing
#   D2  bin/lookback.sh runs the follow-up and posts the board comment through curl
#   Z1  no `claude-` string; item_matches is defined only in lookback-common.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' must not be in: $2" ;; *) ok ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "lookback-followup.bh-1795-test: SKIPPED — jq missing"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "lookback-followup.bh-1795-test: SKIPPED — flock missing"; exit 0; }

NOW=$(date -u +%s)
# determinism: ok the run dir is named by the driver's wall-clock day, derived from the one NOW read
DATE=$(date -u -d "@$NOW" +%Y-%m-%d)
LIB="$DIR/bin/lib/lookback-followup.sh"
ITEMS="$DIR/tests/fixtures/lookback/followup/items.json"
H="$T/h"
RUN="$H/state/lookback/$DATE"
iso() { jq -rn --argjson t "$1" '$t|todate'; }
F31=$(iso $((NOW - 31*86400)))
F29=$(iso $((NOW - 29*86400)))
GH_ROW() { jq -nc --arg f "$1" '{repo:"example-org/cromford",issue:77,filed_at:$f,key_kind:"lane",key_value:"rebase",project:"acme-os",target:"harness",items:2,item_ids:["alerts:old1"]}'; }
BOARD_ROW() { jq -nc --arg f "$1" '{board:"acme-os",ticket_id:"t-500",filed_at:$f,key_kind:"file",key_value:"bin/x.sh",project:"acme-os",target:"app",items:2,item_ids:[]}'; }

fresh() {
  scratch_rm "$H"; rm -rf "$T"/calls.* "$T/ledger" "$T/comments" "$T/out"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$RUN" "$T/ledger" "$T/comments"
  cat > "$H/bin/lookback-collect.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls.collect"
[ "\${STUB_COLLECT_RC:-0}" = 0 ] || exit "\$STUB_COLLECT_RC"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
jq --argjson now "$NOW" --arg set "\${STUB_SET:-match}" --arg ok "\${STUB_SRC_OK:-true}" \
   --arg tr "\${STUB_TRUNC:-false}" --arg inc "\${STUB_INCOMPLETE:-false}" '
  {window:{from:(\$now-30*86400|todate),to:(\$now|todate)},
   items:[.[] | select(\$set == "match" or .id != "alerts:new1")
          | (if has("age_s") then .at = (\$now - .age_s | todate) else . end) | del(.age_s)],
   sources:{alerts:{ok:true,n:3,truncated:false},builds:{ok:(\$ok=="true"),n:2,truncated:(\$tr=="true")}},
   incomplete:(\$inc=="true")}' "$ITEMS" > "\$out"
SH
  chmod +x "$H/bin/lookback-collect.sh"
  STUB_LIST_RC=0; STUB_LIST_FULL=0; STUB_COMMENT_RC=0; STUB_PUT_RC=0
}
seed() { jq -nc --arg s "${3:-filed}" --arg d "$2" '{status:$s,detail:$d}' > "$T/ledger/$1"; }

# Recorders. calls.seq holds comment and put in the order they happened.
job_ledger_list() {
  printf 'list %s %s\n' "$1" "$2" >> "$T/calls.ledger"
  [ "$STUB_LIST_RC" = 0 ] || return "$STUB_LIST_RC"
  local f n=0
  for f in "$T/ledger"/*; do
    [ -f "$f" ] || continue
    printf '%s\t%s\t-\t-\n' "${f##*/}" "$(jq -r .status "$f")"; n=$((n+1))
  done
  if [ "$STUB_LIST_FULL" = 1 ]; then
    while [ "$n" -lt "$2" ]; do printf 'old%04d\tfollowed_up_stopped\t-\t-\n' "$n"; n=$((n+1)); done
  fi
}
job_ledger_row() {
  printf 'row %s %s\n' "$1" "$2" >> "$T/calls.ledger"
  [ -f "$T/ledger/$2" ] || return 2
  cat "$T/ledger/$2"
}
job_ledger_put() {
  printf 'put %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$T/calls.ledger"
  printf 'put %s %s\n' "$2" "$3" >> "$T/calls.seq"
  [ "$STUB_PUT_RC" = 0 ] || return "$STUB_PUT_RC"
  jq -nc --arg s "$3" --arg d "$4" '{status:$s,detail:$d}' > "$T/ledger/$2"
}
_rec_comment() { # _rec_comment <via> <target> <num> <file>
  local n; n=$(( $(ls "$T/comments" | wc -l) + 1 ))
  cp "$4" "$T/comments/$n.txt"
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$T/calls.comment"
  printf 'comment %s %s\n' "$1" "$3" >> "$T/calls.seq"
  return "$STUB_COMMENT_RC"
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
count() { grep -c -- "$2" "$1" 2>/dev/null || true; }
allc() { cat "$T/comments"/*.txt 2>/dev/null; }

export HARNESS="$H"
fresh
if ! . "$LIB"; then bad "the lib does not source"; fi
declare -F lookback_followup_run >/dev/null || bad "lookback_followup_run is not defined by $LIB"
gh_rest_comment()        { _rec_comment gh "$1" "$2" "$3"; }
lookback_board_comment() { _rec_comment board "$1" "$2" "$3"; }
gh_rest_issue_state()    { printf 'state %s\n' "$*" >> "$T/calls.state"; echo closed; }
# BH-3691: the follow-up reads pulls through gh_rest for its fix check; this
# suite stays off the network (an unverifiable read is fix `unknown`).
gh_rest()                { printf 'gh %s %s\n' "$1" "$2" >> "$T/calls.gh"; GH_REST_STATUS=000; return 75; }
# fu_env VAR=value... — run the follow-up with those variables set for the call.
fu_env() {
  local kv
  OUT=$( for kv in "$@"; do export "${kv?}"; done; lookback_followup_run "$RUN" ); RC=$?
}

# --- U1 recurred --------------------------------------------------------------------
fresh; seed fpA "$(GH_ROW "$F31")"; fu_env STUB_SET=match
eq "U1 rc" "$RC" 0
eq "U1 one collector run" "$(lines "$T/calls.collect")" 1
eq "U1 collector args" "$(cat "$T/calls.collect" 2>/dev/null)" "--days 30 --out $RUN/followup-bundle.json"
eq "U1 one gh comment" "$(cat "$T/calls.comment" 2>/dev/null)" "gh example-org/cromford 77"
has "U1 recurred" "$(allc)" "recurred: 1 new since ${F31%%T*}"
has "U1 lists the new item" "$(allc)" "alerts:new1"
hasnt "U1 the filed item is not new" "$(allc)" "alerts:old1"
hasnt "U1 another project is not new" "$(allc)" "alerts:other"
hasnt "U1 an unparseable at is not new" "$(allc)" "builds:badat"
eq "U1 comment then put" "$(cut -d' ' -f1 "$T/calls.seq" 2>/dev/null | tr '\n' ,)" "comment,put,"
eq "U1 status" "$(grep '^put ' "$T/calls.ledger" | cut -d' ' -f2-4)" "lookback_cluster fpA followed_up_recurred"
eq "U1 detail stamped" "$(grep '^put ' "$T/calls.ledger" | cut -d' ' -f5- | jq -c '[.followup_new, (.followed_up_at|type), .repo, .filed_at]')" \
  "[1,\"string\",\"example-org/cromford\",\"$F31\"]"
has "U1 summary" "$OUT" "followed up fpA: recurred 1"
eq "U1 no issue state read (a closed issue still gets it)" "$(lines "$T/calls.state")" 0

# --- U2 stopped -----------------------------------------------------------------------
fresh; seed fpA "$(GH_ROW "$F31")"; fu_env STUB_SET=nomatch
eq "U2 rc" "$RC" 0
eq "U2 one comment" "$(lines "$T/calls.comment")" 1
has "U2 stopped" "$(allc)" "stopped: no new occurrences in 30 days"
eq "U2 status" "$(grep '^put ' "$T/calls.ledger" | cut -d' ' -f4)" followed_up_stopped
has "U2 summary" "$OUT" "followed up fpA: stopped"

# --- U3 not due yet -------------------------------------------------------------------
fresh; seed fpA "$(GH_ROW "$F29")"; fu_env STUB_SET=match
eq "U3 rc" "$RC" 0
eq "U3 no collector" "$(lines "$T/calls.collect")" 0
eq "U3 no comment" "$(lines "$T/calls.comment")" 0
eq "U3 no put" "$(count "$T/calls.ledger" '^put ')" 0
# a row already followed up is never due again
fresh; seed fpA "$(GH_ROW "$F31")" followed_up_stopped; fu_env STUB_SET=match
eq "U3b followed-up row: no collector" "$(lines "$T/calls.collect")" 0

# --- U4 incomplete sources: no claim either way -----------------------------------------
for v in STUB_SRC_OK=false STUB_TRUNC=true STUB_INCOMPLETE=true; do
  fresh; seed fpA "$(GH_ROW "$F31")"; fu_env STUB_SET=nomatch "$v"
  eq "U4 rc ($v)" "$RC" 0
  eq "U4 no comment ($v)" "$(lines "$T/calls.comment")" 0
  eq "U4 no put ($v)" "$(count "$T/calls.ledger" '^put ')" 0
  has "U4 deferred ($v)" "$OUT" "follow-up deferred: incomplete sources (fpA)"
done
# a recurrence is still a fact in an incomplete bundle
fresh; seed fpA "$(GH_ROW "$F31")"; fu_env STUB_SET=match STUB_SRC_OK=false
has "U4b recurred with a source down" "$(allc)" "recurred: 1 new"

# --- U5 ledger outage ------------------------------------------------------------------
fresh; seed fpA "$(GH_ROW "$F31")"; STUB_LIST_RC=1; fu_env
eq "U5 rc" "$RC" 75
has "U5 message" "$OUT" "follow-up skipped: ledger unreadable"
eq "U5 no collector" "$(lines "$T/calls.collect")" 0
eq "U5 no comment" "$(lines "$T/calls.comment")" 0

# --- U6 a board row --------------------------------------------------------------------
fresh; seed fpB "$(BOARD_ROW "$F31")"; fu_env STUB_SET=match
eq "U6 board path" "$(cat "$T/calls.comment" 2>/dev/null)" "board acme-os t-500"
has "U6 stopped (file key is exact)" "$(allc)" "stopped"

# --- U7 the comment fails -----------------------------------------------------------------
fresh; seed fpA "$(GH_ROW "$F31")"; STUB_COMMENT_RC=75; fu_env STUB_SET=match
eq "U7 rc" "$RC" 0
eq "U7 no put" "$(count "$T/calls.ledger" '^put ')" 0
has "U7 message" "$OUT" "follow-up comment failed fpA"

# --- U8 two due rows, a full page ------------------------------------------------------------
fresh; seed fpA "$(GH_ROW "$F31")"; seed fpB "$(BOARD_ROW "$F31")"; STUB_LIST_FULL=1; fu_env STUB_SET=match
eq "U8 one collector run" "$(lines "$T/calls.collect")" 1
eq "U8 asks for 1000" "$(count "$T/calls.ledger" '^list lookback_cluster 1000$')" 1
has "U8 incomplete" "$OUT" "follow-up incomplete: ledger page full (1000 rows)"
eq "U8 two comments" "$(lines "$T/calls.comment")" 2
eq "U8 statuses" "$(grep '^put ' "$T/calls.ledger" | cut -d' ' -f3,4 | sort | tr '\n' ,)" "fpA followed_up_recurred,fpB followed_up_stopped,"
eq "U8 only filed rows read" "$(count "$T/calls.ledger" '^row ')" 2
# the plan's rule: a put failure after a sent comment is printed
fresh; seed fpA "$(GH_ROW "$F31")"; STUB_PUT_RC=1; fu_env STUB_SET=match
# TEST-CHANGE (BH-3691): the summary line gained the fix result before the put suffix.
has "U8b put failure printed" "$OUT" "followed up fpA: recurred 1, fix unknown; ledger write failed"

# --- U9 dry run --------------------------------------------------------------------------
fresh; seed fpA "$(GH_ROW "$F31")"; fu_env STUB_SET=match LOOKBACK_DRY=1
eq "U9 no comment" "$(lines "$T/calls.comment")" 0
eq "U9 no put" "$(count "$T/calls.ledger" '^put ')" 0
has "U9 says what it would do" "$OUT" "would comment example-org/cromford#77 fpA: recurred: 1 new"

# --- U10 edges ---------------------------------------------------------------------------
fresh; seed fpA "$(GH_ROW "$F31")"; fu_env LOOKBACK_FOLLOWUP_DAYS=abc
eq "U10 bad days rc" "$RC" 75
has "U10 bad days" "$OUT" "follow-up skipped: LOOKBACK_FOLLOWUP_DAYS invalid"
eq "U10 bad days: no ledger read" "$(lines "$T/calls.ledger")" 0
fresh; seed fpA "$(GH_ROW "$F31" | jq -c 'del(.filed_at)')"; fu_env
has "U10 incomplete detail" "$OUT" "follow-up skipped fpA: detail incomplete"
eq "U10 incomplete detail: no collector" "$(lines "$T/calls.collect")" 0
fresh; seed fpA "$(GH_ROW "$F31")"; rm -f "$H/bin/lookback-collect.sh"; fu_env
eq "U10 no collector rc" "$RC" 75
has "U10 no collector" "$OUT" "follow-up deferred: collector not installed"
fresh; seed fpA "$(GH_ROW "$F31")"; fu_env STUB_COLLECT_RC=3
eq "U10 collector fails rc" "$RC" 75
has "U10 collector fails" "$OUT" "follow-up deferred: collector rc=3"
eq "U10 collector fails: no comment" "$(lines "$T/calls.comment")" 0
fresh; seed fpA "$(GH_ROW "$F31")"; fu_env LOOKBACK_FOLLOWUP_DAYS=45
eq "U10 days knob moves the due line" "$(lines "$T/calls.collect")" 0

# --- D2 the driver end to end, board comment through curl --------------------------------------
fresh
cp "$DIR/bin/lookback.sh" "$DIR/bin/alert-line.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lanes-registry.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/lookback-common.sh" "$DIR/bin/lib/lookback-board.sh" "$LIB" "$DIR/bin/lib/gh-rest.sh" \
   "$DIR/bin/lib/internal-token.sh" "$DIR/bin/lib/board-creds.sh" "$DIR/bin/lib/deployment.sh" "$H/bin/lib/"
: > "$H/env/global.env"
printf 'acme-os  example-org/acme-os  https://os.acme.test  /api/board  2 box-a 10.0.0.1\n' > "$H/fleet.conf"
printf 'ACME_INTERNAL_API_TOKEN=tok\nACME_API_BASE=https://os.acme.test\n' > "$H/env/acme-os.env"
seed fpB "$(BOARD_ROW "$F31" | jq -c '.key_kind="lane" | .key_value="rebase"')"
cat > "$H/bin/jobs-client.sh" <<SH
job_lane_open()  { :; }
job_lane_close() { :; }
job_ledger_list() { for f in "$T/ledger"/*; do printf '%s\t%s\t-\t-\n' "\${f##*/}" "\$(jq -r .status "\$f")"; done; }
job_ledger_row()  { cat "$T/ledger/\$2"; }
job_ledger_put()  { printf 'put %s %s %s\n' "\$1" "\$2" "\$3" >> "$T/calls.ledger"; }
SH
cat > "$H/bin/lane-alert.sh" <<SH
#!/bin/bash
a="\$*"; printf '%s\n' "\${a//\$'\n'/ | }" >> "$T/calls.lane-alert"
SH
mkdir -p "$T/pbin"
cat > "$T/pbin/curl" <<SH
#!/bin/bash
url=""; data=""
while [ \$# -gt 0 ]; do case "\$1" in --data-binary) data="\${2#@}"; shift ;; -H|--max-time|-K|-X) shift ;; -*) ;; *) url="\$1" ;; esac; shift; done
cat > /dev/null
printf 'POST %s\n' "\$url" >> "$T/calls.curl"
[ -n "\$data" ] && cp "\$data" "$T/comments/curl.json"
echo '{"ok":true}'
SH
chmod +x "$H/bin/"*.sh "$T/pbin/curl"
env -i PATH="$T/pbin:$PATH" HOME="$T" HARNESS="$H" LANE_GATE_NOW="$NOW" STUB_SET=match bash "$H/bin/lookback.sh" > "$T/out" 2>&1
eq "D2 rc" "$?" 0
eq "D2 one board comment" "$(cat "$T/calls.curl" 2>/dev/null)" "POST https://os.acme.test/api/board/tickets/t-500/comments"
has "D2 comment body" "$(jq -r .body "$T/comments/curl.json" 2>/dev/null)" "recurred: 1 new"
has "D2 summary" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "followed up fpB: recurred 1"
eq "D2 row stamped" "$(cat "$T/calls.ledger" 2>/dev/null)" "put lookback_cluster fpB followed_up_recurred"
eq "D2 two collector runs (follow-up, then the week)" "$(cut -d' ' -f3- "$T/calls.collect" 2>/dev/null | tr '\n' ,)" \
  "--out $RUN/followup-bundle.json,--out $RUN/bundle.json,"

# --- Z1 --------------------------------------------------------------------------------
eq "Z1 claude- occurrences" "$(grep -c 'claude-' "$LIB")" 0
eq "Z1 item_matches is not re-implemented" "$(grep -c 'def item_matches' "$LIB")" 0

echo "lookback-followup.bh-1795-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
