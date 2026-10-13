#!/bin/bash
# tests/lookback-followup.bh-3691-test.sh — BH-3691: the 30-day follow-up in
# bin/lib/lookback-followup.sh also records whether a fix merged: a merged PR on
# ticket/bh-<issue> in the harness repo. The lib is sourced against a scratch
# $HARNESS; the ledger, the comment and gh_rest are file-backed recorders defined
# AFTER the source so they replace the real ones (the BH-1795 follow-up suite's
# scaffolding, copied). The collector is a stub writing one matching item.
#
#   FX1  a merged PR #901 on ticket/bh-77 -> `Fix: merged in PR #901.`, fix_merged yes, fix_pr 901,
#        comment then put
#   FX2  only a closed unmerged PR -> `Fix: no merged PR on ticket/bh-77.`, none
#   FX3  a merged PR whose head.ref is ticket/bh-770 -> not counted, none
#   FX4  gh_rest answers 500 -> `Fix: not checked.`, unknown, comment still posted
#   FX5  a board row -> unknown, no pulls read
#   FX6  a row on another repo -> unknown, no pulls read; no gh_rest at all -> unknown
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' must not be in: $2" ;; *) ok ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "lookback-followup.bh-3691-test: SKIPPED — jq missing"; exit 0; }

NOW=$(date -u +%s)
# determinism: ok the run dir is named by the wall-clock day, derived from the one NOW read
DATE=$(date -u -d "@$NOW" +%Y-%m-%d)
LIB="$DIR/bin/lib/lookback-followup.sh"
H="$T/h"
RUN="$H/state/lookback/$DATE"
F31=$(jq -rn --argjson t $((NOW - 31*86400)) '$t|todate')
GH_ROW() { jq -nc --arg f "$F31" --arg r "${1:-example-org/cromford}" '{repo:$r,issue:77,filed_at:$f,key_kind:"lane",key_value:"rebase",project:"cromford",target:"harness",items:2,item_ids:["old1"]}'; }
BOARD_ROW() { jq -nc --arg f "$F31" '{board:"acme-os",ticket_id:"t-500",filed_at:$f,key_kind:"lane",key_value:"rebase",project:"cromford",target:"app",items:2,item_ids:[]}'; }

fresh() {
  scratch_rm "$H"; rm -rf "$T"/calls.* "$T/ledger" "$T/comments"
  mkdir -p "$H/bin/lib" "$RUN" "$T/ledger" "$T/comments"
  cat > "$H/bin/lookback-collect.sh" <<SH
#!/bin/bash
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
jq -n --argjson now "$NOW" '{items:[{id:"alerts:new1",source:"alerts",at:(\$now-3600|todate),project:"cromford",
  ticket:null,pr:null,files:[],lane:"rebase",reason:"rebase failed"}],sources:{alerts:{ok:true,n:1,truncated:false}},incomplete:false}' > "\$out"
SH
  chmod +x "$H/bin/lookback-collect.sh"
  STUB_PULLS='[]'; STUB_PULLS_STATUS=200
}
seed() { jq -nc --arg d "$2" '{status:"filed",detail:$d}' > "$T/ledger/$1"; }

export HARNESS="$H"
fresh
if ! . "$LIB"; then bad "the lib does not source"; fi
job_ledger_list() { local f; for f in "$T/ledger"/*; do [ -f "$f" ] && printf '%s\t%s\t-\t-\n' "${f##*/}" "$(jq -r .status "$f")"; done; }
job_ledger_row()  { [ -f "$T/ledger/$2" ] || return 2; cat "$T/ledger/$2"; }
job_ledger_put()  {
  printf 'put %s %s\n' "$2" "$3" >> "$T/calls.seq"
  printf '%s\n' "$4" > "$T/calls.putdetail"
}
_rec_comment() { cp "$3" "$T/comments/c.txt"; printf 'comment %s %s\n' "$1" "$2" >> "$T/calls.seq"; return 0; }
gh_rest_comment()        { _rec_comment "$1" "$2" "$3"; }
lookback_board_comment() { _rec_comment "$1" "$2" "$3"; }
gh_rest() {
  printf '%s %s\n' "$1" "$2" >> "$T/calls.gh"
  GH_REST_STATUS="$STUB_PULLS_STATUS"
  [ "$STUB_PULLS_STATUS" = 200 ] || return 75
  printf '%s\n' "$STUB_PULLS"
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
PD() { jq -c "$1" "$T/calls.putdetail" 2>/dev/null; }
run() { OUT=$(lookback_followup_run "$RUN"); RC=$?; }
pr() { # pr <number> <head.ref> <merged_at|null>
  jq -nc --argjson n "$1" --arg r "$2" --arg m "$3" '{number:$n,head:{ref:$r},merged_at:(if $m == "null" then null else $m end)}'
}

# --- FX1 merged -----------------------------------------------------------------------
fresh; seed fpA "$(GH_ROW)"
STUB_PULLS=$(jq -sc . <<<"$(pr 905 ticket/bh-77 2026-09-02T00:00:00Z) $(pr 901 ticket/bh-77 2026-09-01T00:00:00Z) $(pr 899 ticket/bh-77 null)")
run
eq "FX1 rc" "$RC" 0
eq "FX1 one pulls read" "$(cat "$T/calls.gh" 2>/dev/null)" "GET repos/example-org/cromford/pulls?state=closed&head=example-org:ticket/bh-77&per_page=100"
has "FX1 comment first line unchanged" "$(head -1 "$T/comments/c.txt")" "recurred: 1 new"
has "FX1 comment" "$(cat "$T/comments/c.txt")" "Fix: merged in PR #901."
eq "FX1 detail" "$(PD '[.fix_merged,.fix_pr]')" '["yes",901]'
eq "FX1 comment then put" "$(cut -d' ' -f1 "$T/calls.seq" | tr '\n' ,)" "comment,put,"
has "FX1 summary" "$OUT" "followed up fpA: recurred 1, fix yes #901"

# --- FX2 closed, not merged -------------------------------------------------------------
fresh; seed fpA "$(GH_ROW)"; STUB_PULLS="[$(pr 899 ticket/bh-77 null)]"; run
has "FX2 comment" "$(cat "$T/comments/c.txt")" "Fix: no merged PR on ticket/bh-77."
eq "FX2 detail" "$(PD '[.fix_merged,.fix_pr]')" '["none",null]'
has "FX2 summary" "$OUT" "fix none"

# --- FX3 a prefix-sharing branch does not count -------------------------------------------
fresh; seed fpA "$(GH_ROW)"; STUB_PULLS="[$(pr 950 ticket/bh-770 2026-09-03T00:00:00Z)]"; run
eq "FX3 detail" "$(PD '.fix_merged')" '"none"'
hasnt "FX3 no PR 950" "$(cat "$T/comments/c.txt")" "#950"

# --- FX4 GitHub error is unknown, never none ------------------------------------------------
fresh; seed fpA "$(GH_ROW)"; STUB_PULLS_STATUS=500; run
has "FX4 comment" "$(cat "$T/comments/c.txt")" "Fix: not checked."
eq "FX4 detail" "$(PD '.fix_merged')" '"unknown"'
eq "FX4 comment still posted" "$(cut -d' ' -f1 "$T/calls.seq" | tr '\n' ,)" "comment,put,"
has "FX4 summary" "$OUT" "fix unknown"
# a 200 whose body is not a list is unknown too
fresh; seed fpA "$(GH_ROW)"; STUB_PULLS='{"message":"x"}'; run
eq "FX4b unparseable body" "$(PD '.fix_merged')" '"unknown"'

# --- FX5 a board row ------------------------------------------------------------------------
fresh; seed fpB "$(BOARD_ROW)"; run
eq "FX5 detail" "$(PD '.fix_merged')" '"unknown"'
eq "FX5 no pulls read" "$(lines "$T/calls.gh")" 0
has "FX5 comment" "$(cat "$T/comments/c.txt")" "Fix: not checked."

# --- FX6 another repo, and no gh_rest ------------------------------------------------------------
fresh; seed fpA "$(GH_ROW example-org/other)"; run
eq "FX6 other repo unknown" "$(PD '.fix_merged')" '"unknown"'
eq "FX6 no pulls read" "$(lines "$T/calls.gh")" 0
fresh; seed fpA "$(GH_ROW)"; unset -f gh_rest; run
eq "FX6 no gh_rest unknown" "$(PD '.fix_merged')" '"unknown"'

echo "lookback-followup.bh-3691-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
