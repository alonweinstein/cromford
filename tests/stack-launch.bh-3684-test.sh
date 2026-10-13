#!/bin/bash
# tests/stack-launch.bh-3684-test.sh — BH-3684: a decomposition's dependent
# children launch STACKED on their sibling's open PR by default, with no model
# in between.
#
# WHAT IS DRIVEN. The real bin/unblocked-children.sh emits the reading list, the
# real bin/stack-launch.sh filters it, and the real bin/lib/rt/scope.sh wires the
# two together (W1/W2). What is stubbed is everything past the decision:
# bin/launch-fastpath.sh records how it was called (its own stack mode has its
# own suite, tests/launch-fastpath-stack.bh-3684-test.sh), bin/jobs-client.sh
# answers the D1 ledger and verdict reads from files, bin/lib/block-gate.sh
# answers bg_scan_read from a per-PR file, and gh is a REST fixture server.
# Every assertion reads an artifact: the fastpath call log, the filtered
# stdout, logs/<project>.log and the recorded ledger PUTs.
#
#   E1-E3  the chain=#P tag on STACKABLE lines (siblings of one decomposition)
#   S1     three-child decomposition: both siblings launch stacked, no line left
#   S1b    a child whose parent has no PR yet is not launched
#   S2     a BLOCKed parent PR holds its children (block-gate, then build verdict)
#   S3     an unreadable block-gate never launches and never drops
#   S4     a fastpath decline leaves that line for the model
#   S5     a STACKABLE line with no chain= is printed unchanged, no launch
#   S6     a stacked row inside 6h holds the child; an older one does not
#   S7     depth 2 through the parent PR's own base
#   S8     fail-open: kill switch, STACKED_BUILDS=0, missing lib, in-app board
#   S9     non-STACKABLE lines pass through in order
#   L1     time saved on parent merge, parent-closed, other project untouched
#   W1/W2  board_section runs the filter; without the script it is today's text
# Run from anywhere: bash tests/stack-launch.bh-3684-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

NOW=$(date -u +%s)
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
P=cromford
REPO=example-org/cromford
PRURL="https://github.com/$REPO/pull"
mkdir -p "$H/bin/lib/rt" "$H/logs" "$H/state" "$H/flags" "$H/prompts" "$H/fixture" "$H/ledger" "$T/fakebin"
export HARNESS="$H" LANE_GATE_DISABLE=1
cp "$DIR/bin/unblocked-children.sh" "$H/bin/"
[ -f "$DIR/bin/stack-launch.sh" ] && cp "$DIR/bin/stack-launch.sh" "$H/bin/"
cp "$DIR/bin/lib/rt/scope.sh" "$H/bin/lib/rt/"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" \
   "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/preplan-lib.sh" "$H/bin/lib/"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
cat > "$H/fleet.conf" <<'CONF'
cromford example-org/cromford https://bh.example - 9 box-bh 10.0.0.13
project-3 example-org/project-3 https://project-3.example /api/feature-board 3 box-project-3 100.0.0.8
CONF
export FLEET_CONF="$H/fleet.conf"
printf '%s\n' '  `setsid /root/harness/bin/run-build.sh cromford <issue-number> BH-<issue-number> &`' > "$H/prompts/$P.md"

# The fastpath recorder: argv plus the stack env, and a per-issue scripted rc.
# Its stdout is what the real script prints for a DECLINED key, so the stub
# prints the key on a decline — a filter that leaked it into the tick's text
# would fail S4.
cat > "$H/bin/launch-fastpath.sh" <<'SH'
#!/bin/bash
mkdir -p "$HARNESS/calls"
printf '%s base=%s parent=%s pr=%s\n' "$*" "${FASTPATH_STACK_BASE:-}" "${FASTPATH_STACK_PARENT:-}" \
  "${FASTPATH_STACK_PARENT_PR:-}" >> "$HARNESS/calls/fastpath"
rc=$(cat "$HARNESS/fixture/fp-rc-$2" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || printf '%s\n' "$2"
exit "$rc"
SH
chmod +x "$H/bin/launch-fastpath.sh"

# The D1 client, as files: ledger/<key with _ for space>.json holds {status,
# detail}; every PUT is also appended to ledger-puts.log. ledger-down makes
# every read an outage (rc 1). verdict-<prnum> is job_verdict's TSV answer.
cat > "$H/bin/jobs-client.sh" <<'SH'
#!/bin/bash
_lk() { printf '%s/ledger/%s__%s.json' "$HARNESS" "$1" "$(printf '%s' "$2" | tr ' ' '_')"; }
job_ledger_row() {
  [ -f "$HARNESS/fixture/ledger-down" ] && return 1
  local f; f=$(_lk "$1" "$2"); [ -f "$f" ] || return 2
  jq -c '{status, detail}' "$f"
}
job_ledger_put() {
  jq -nc --arg k "$1" --arg v "$2" --arg s "$3" --arg d "${4:-}" '{kind:$k,key:$v,status:$s,detail:$d}' \
    | tee -a "$HARNESS/ledger-puts.log" > "$(_lk "$1" "$2")"
}
ledger_page() {
  [ -f "$HARNESS/fixture/ledger-down" ] && return 1
  local f
  for f in "$HARNESS/ledger/$1__"*.json; do [ -f "$f" ] && cat "$f"; done | jq -sc '{ledgers: .}'
}
job_verdict() {
  [ -f "$HARNESS/fixture/verdict-down" ] && return 1
  local f="$HARNESS/fixture/verdict-${1##*/}"
  [ -f "$f" ] || return 2
  cat "$f"
}
SH

# block-gate: bg_scan_read answers bg-<prnum> (0 clear, 1 blocked, 2 unreadable).
cat > "$H/bin/lib/block-gate.sh" <<'SH'
bg_scan_read() {
  printf '%s\n' "$*" >> "$HARNESS/bg-calls.log"
  local rc; rc=$(cat "$HARNESS/fixture/bg-$2" 2>/dev/null || echo 0)
  case "$rc" in
    1) printf 'https://github.com/x/c/1\toperator\t2026-09-30T10:00:00Z\t1' ;;
    2) printf 'comments' ;;
  esac
  return "$rc"
}
bg_scan() { echo "bg_scan must not be called: it advances the merge lanes' streak" >> "$HARNESS/bg-calls.log"; bg_scan_read "$@"; }
SH

# gh: REST for the PR reads stack-launch.sh makes, the CLI adapter for the
# issue list, and the CLI shape for unblocked-children's `pr list`.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
A="$*"
case "$A" in
  *"GET repos/example-org/cromford/pulls/"[0-9]*)
    n=$(printf '%s' "$A" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    [ -f "$HARNESS/fixture/pull-rc-$n" ] && SEND "$(cat "$HARNESS/fixture/pull-rc-$n")" '{"message":"x"}'
    [ -f "$HARNESS/fixture/pull-$n.json" ] || SEND 404 '{"message":"Not Found"}'
    SEND 200 "$(cat "$HARNESS/fixture/pull-$n.json")" ;;
  *"GET repos/example-org/cromford/pulls?"*"head="*)
    ref=$(printf '%s' "$A" | sed -nE 's#.*head=example-org:([^& ]+).*#\1#p')
    SEND 200 "$(cat "$HARNESS"/fixture/pull-*.json 2>/dev/null | jq -sc --arg r "$ref" '[ .[] | select(.head.ref == $r and .state == "open") ]')" ;;
  *"GET repos/example-org/cromford")
    SEND 200 '{"default_branch":"main"}' ;;
esac
. "${GH_CLI_REST_ADAPTER:?}" || exit 1; gh_cli_rest "$0" "$@" && exit 0
case "$A" in
  *"issue list"*) cat "$HARNESS/fixture/issues.json" ;;
  *"pr list"*)    cat "$HARNESS/fixture/prs.json" ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# --- the board ---------------------------------------------------------------
# #100 is the decomposed master (unlabelled, so not in the list). #101 is the
# contract child with an open PR. #102/#103 are its siblings; #104 waits on
# #102; #110 names #101 with no decomposition; #111 belongs to ANOTHER one.
cat > "$H/fixture/issues.json" <<'JSON'
[
 {"number":101,"state":"OPEN","title":"BH-101 contract","body":"Part of #100\nOrder: 1 of 4\n"},
 {"number":102,"state":"OPEN","title":"BH-102 sibling a","body":"Part of #100\nOrder: 2 of 4\nBlocked-by: #101 (hard)\n"},
 {"number":103,"state":"OPEN","title":"BH-103 sibling b","body":"Part of #100\nOrder: 3 of 4\nBlocked-by: #101 (hard)\n"},
 {"number":104,"state":"OPEN","title":"BH-104 third level","body":"Part of #100\nOrder: 4 of 4\nBlocked-by: #102 (hard)\n"},
 {"number":110,"state":"OPEN","title":"BH-110 not a decomposition","body":"Blocked-by: #101\n"},
 {"number":111,"state":"OPEN","title":"BH-111 other decomposition","body":"Part of #200\nBlocked-by: #101 (hard)\n"}
]
JSON
PRS_BASE='[{"number":900,"url":"'"$PRURL"'/900","title":"BH-101: contract","headRefName":"ticket/bh-101","isDraft":false}]'
PRS_S7='[{"number":900,"url":"'"$PRURL"'/900","title":"BH-101: contract","headRefName":"ticket/bh-101","isDraft":false},
 {"number":901,"url":"'"$PRURL"'/901","title":"BH-102: sibling a","headRefName":"ticket/bh-102","isDraft":false}]'
mkpull() { # mkpull <n> <head> <base> [state] [merged_at]
  jq -n --argjson n "$1" --arg h "$2" --arg b "$3" --arg s "${4:-open}" --arg m "${5:-}" \
        --arg u "$PRURL/$1" --arg ca "$(iso $((NOW - 7200)))" \
    '{number:$n,state:$s,draft:false,html_url:$u,created_at:$ca,
      merged_at:(if $m == "" then null else $m end),
      head:{ref:$h,sha:"abcdef0123456789abcdef0123456789abcdef01"},base:{ref:$b}}' > "$H/fixture/pull-$1.json"
}
reset() {
  scratch_rm "$H/logs"; scratch_rm "$H/ledger"; scratch_rm "$H/calls"; scratch_rm "$H/state"
  mkdir -p "$H/logs" "$H/ledger" "$H/state"
  rm -f "$H/flags"/* "$H/fixture"/pull-* "$H/fixture"/fp-rc-* "$H/fixture"/bg-* "$H/fixture"/verdict-* \
        "$H/fixture/ledger-down" "$H/gh-calls.log" "$H/bg-calls.log" "$H/ledger-puts.log"
  printf '%s' "$PRS_BASE" > "$H/fixture/prs.json"
  mkpull 900 ticket/bh-101 main
}
uc()  { "$H/bin/unblocked-children.sh" "$P" </dev/null 2>/dev/null; }
sl()  { "$H/bin/stack-launch.sh" "${1:-$P}" 2>/dev/null; }
fpcalls() { cat "$H/calls/fastpath" 2>/dev/null; }
nfp() { local n; n=$(grep -c . "$H/calls/fastpath" 2>/dev/null); echo "${n:-0}"; }
lg()  { cat "$H/logs/$P.log" 2>/dev/null; }
seedrow() { # seedrow <key> <status> <detail-json>
  jq -nc --arg k "$1" --arg s "$2" --arg d "$3" '{kind:"stack",key:$k,status:$s,detail:$d}' > "$H/ledger/stack__$(printf '%s' "$1" | tr ' ' '_').json"
}
put_for() { grep -F "\"key\":\"$1\"" "$H/ledger-puts.log" 2>/dev/null | tail -1; }

# ---------- E1-E3 the chain tag ---------------------------------------------
reset
E=$(uc)
grep -qF "board issues: STACKABLE 102 \"BH-102 sibling a\" base=ticket/bh-101 parent-pr=$PRURL/900 chain=#100 (Blocked-by #101 " <<<"$E" \
  && ok || bad "E1: 102 must carry chain=#100 right after parent-pr (got: $E)"
grep -qF "STACKABLE 103 \"BH-103 sibling b\" base=ticket/bh-101 parent-pr=$PRURL/900 chain=#100 (Blocked-by #101 " <<<"$E" \
  && ok || bad "E1: 103 must carry chain=#100 (got: $E)"
grep -qE '^board issues: STACKABLE 110 .*parent-pr=[^ ]+/900 \(Blocked-by #101 ' <<<"$E" \
  && ok || bad "E2: 110 (no Part of) must be STACKABLE with no chain= token (got: $E)"
grep -qE 'STACKABLE 111 .*chain=' <<<"$E" && bad "E3: 111's blocker is from another decomposition — no chain= (got: $E)" || ok
grep -qE 'STACKABLE 111 .*parent-pr=[^ ]+/900 \(Blocked-by #101 ' <<<"$E" && ok || bad "E3: 111 must still be STACKABLE (got: $E)"

# ---------- S1 + S1b + S5 + S9 the default launch ----------------------------
reset
IN=$(printf 'board issues: UNBLOCKED 50 "BH-50 first" (x)\n%s\nboard issues: CHANGED 51 "BH-51" (y)\n' "$E")
OUT=$(sl <<<"$IN")
grep -qF "cromford 102 base=ticket/bh-101 parent=101 pr=$PRURL/900" "$H/calls/fastpath" 2>/dev/null \
  && ok || bad "S1: fastpath must be called for 102 in stack mode (calls: $(fpcalls))"
grep -qF "cromford 103 base=ticket/bh-101 parent=101 pr=$PRURL/900" "$H/calls/fastpath" 2>/dev/null \
  && ok || bad "S1: fastpath must be called for 103 in stack mode (calls: $(fpcalls))"
[ "$(nfp)" = 2 ] && ok || bad "S1/S5: exactly two launches (102, 103), got: $(fpcalls)"
grep -qE 'STACKABLE (102|103) ' <<<"$OUT" && bad "S1: a launched sibling must not reach the model (out: $OUT)" || ok
lg | grep -qF "STACK-LAUNCH BH-102 base=ticket/bh-101 parent=#101 pr=#900 depth=1 chain=#100" \
  && ok || bad "S1: STACK-LAUNCH log line for BH-102 (log: $(lg))"
R=$(put_for "$P BH-102")
[ "$(jq -r '.status' <<<"$R" 2>/dev/null)" = stacked ] && ok || bad "S1: ledger PUT status stacked for BH-102 (got: $R)"
[ "$(jq -r '.detail|fromjson|"\(.depth) \(.base) \(.parent) \(.chain) \(.parent_pr)"' <<<"$R" 2>/dev/null)" = "1 ticket/bh-101 101 100 $PRURL/900" ] \
  && ok || bad "S1: ledger detail depth/base/parent/chain/parent_pr (got: $R)"
[ -n "$(jq -r '.detail|fromjson|.stacked_at // empty' <<<"$R" 2>/dev/null)" ] && ok || bad "S1: ledger detail carries stacked_at (got: $R)"
[ "$(grep -c 'pulls/900' "$H/gh-calls.log" 2>/dev/null)" = 1 ] && ok \
  || bad "S1: the parent PR is read once for two siblings: $(grep 'pulls/900' "$H/gh-calls.log")"
grep -q 'STACKABLE 104' <<<"$OUT" && bad "S1b: 104's parent has no PR — no line" || ok
grep -q ' 104 ' "$H/calls/fastpath" 2>/dev/null && bad "S1b: 104 must not be launched" || ok
grep -qE '^board issues: STACKABLE 110 .*\(Blocked-by #101 ' <<<"$OUT" && ok || bad "S5: 110 (no chain) is printed unchanged (out: $OUT)"
grep -q 'cromford 110' "$H/calls/fastpath" 2>/dev/null && bad "S5: 110 must not be launched" || ok
grep -qF "$(grep 'STACKABLE 110' <<<"$E")" <<<"$OUT" && ok || bad "S5: 110's line must be byte-identical"
[ "$(head -1 <<<"$OUT")" = 'board issues: UNBLOCKED 50 "BH-50 first" (x)' ] && ok || bad "S9: first line unchanged (out: $OUT)"
[ "$(tail -1 <<<"$OUT")" = 'board issues: CHANGED 51 "BH-51" (y)' ] && ok || bad "S9: last line unchanged, in order (out: $OUT)"
grep -q 'bg_scan must not' "$H/bg-calls.log" 2>/dev/null && bad "S1: bg_scan (streak) called instead of bg_scan_read" || ok
grep -qF "example-org/cromford 900 $PRURL/900 abcdef0123456789abcdef0123456789abcdef01 101" "$H/bg-calls.log" 2>/dev/null \
  && ok || bad "S1: bg_scan_read gets slug, PR, url, head sha, parent issue: $(cat "$H/bg-calls.log" 2>/dev/null)"

# ---------- S2 a BLOCKed parent PR holds the chain -------------------------
reset
echo 1 > "$H/fixture/bg-900"
OUT=$(sl <<<"$E")
[ "$(nfp)" = 0 ] && ok || bad "S2: a BLOCKed parent launches nothing (calls: $(fpcalls))"
grep -qE 'STACKABLE (102|103|110|111) ' <<<"$OUT" && bad "S2: every child of a BLOCKed parent waits (out: $OUT)" || ok
lg | grep -qF "STACK-WAIT BH-102 :: parent #101 PR #900 is BLOCKed (block-gate" && ok || bad "S2: STACK-WAIT (block-gate) log (log: $(lg))"
reset
printf 'BLOCK\t2\tfable\t-\tjob-1\tabc' > "$H/fixture/verdict-900"
OUT=$(sl <<<"$E")
[ "$(nfp)" = 0 ] && ok || bad "S2/verdict: a BLOCK build verdict launches nothing (calls: $(fpcalls))"
grep -qE 'STACKABLE (102|103) ' <<<"$OUT" && bad "S2/verdict: children wait (out: $OUT)" || ok
lg | grep -qF "STACK-WAIT BH-102 :: parent #101 PR #900 is BLOCKed (build-verdict" && ok || bad "S2/verdict: STACK-WAIT (build-verdict) log (log: $(lg))"
reset
printf 'APPROVE\t1\tfable\t-\tjob-1\tabc' > "$H/fixture/verdict-900"
sl <<<"$E" >/dev/null
[ "$(nfp)" = 2 ] && ok || bad "S2/approve: an APPROVE verdict is not a block (calls: $(fpcalls))"

# ---------- S3 unreadable block state: no launch, no drop -------------------
reset
echo 2 > "$H/fixture/bg-900"
OUT=$(sl <<<"$E")
[ "$(nfp)" = 0 ] && ok || bad "S3: unreadable block-gate must not launch (calls: $(fpcalls))"
grep -qF "$(grep 'STACKABLE 102' <<<"$E")" <<<"$OUT" && ok || bad "S3: 102 printed unchanged (out: $OUT)"
grep -qF "$(grep 'STACKABLE 103' <<<"$E")" <<<"$OUT" && ok || bad "S3: 103 printed unchanged (out: $OUT)"
reset
touch "$H/fixture/verdict-down"
OUT=$(sl <<<"$E")
[ "$(nfp)" = 0 ] && ok || bad "S3/verdict-down: a verdict outage must not launch (calls: $(fpcalls))"
grep -q 'STACKABLE 102' <<<"$OUT" && ok || bad "S3/verdict-down: 102 printed unchanged (out: $OUT)"

# ---------- S4 fastpath declines one --------------------------------------
reset
echo 1 > "$H/fixture/fp-rc-102"
OUT=$(sl <<<"$E")
grep -qF "$(grep 'STACKABLE 102' <<<"$E")" <<<"$OUT" && ok || bad "S4: a declined 102 goes to the model unchanged (out: $OUT)"
grep -qx '102' <<<"$OUT" && bad "S4: fastpath's stdout leaked into the tick's text (out: $OUT)" || ok
lg | grep -qF "STACK-PASS BH-102 :: fastpath declined" && ok || bad "S4: STACK-PASS log (log: $(lg))"
grep -q 'STACKABLE 103' <<<"$OUT" && bad "S4: 103 still launched and dropped (out: $OUT)" || ok
[ -z "$(put_for "$P BH-102")" ] && ok || bad "S4: no ledger row for a launch that did not happen"

# ---------- S6 the ledger dedupe --------------------------------------------
reset
seedrow "$P BH-102" stacked "$(jq -nc --arg b ticket/bh-101 --arg t "$(iso $((NOW - 3600)))" --arg u "$PRURL/900" \
  '{chain:100,parent:101,parent_pr:$u,base:$b,depth:1,stacked_at:$t}')"
OUT=$(sl <<<"$E")
grep -q 'cromford 102' "$H/calls/fastpath" 2>/dev/null && bad "S6: stacked 1h ago — no relaunch (calls: $(fpcalls))" || ok
grep -q 'STACKABLE 102' <<<"$OUT" && bad "S6: a held line is dropped (out: $OUT)" || ok
lg | grep -qF "STACK-HELD BH-102 :: stacked on ticket/bh-101 at" && ok || bad "S6: STACK-HELD log (log: $(lg))"
grep -q 'cromford 103' "$H/calls/fastpath" 2>/dev/null && ok || bad "S6: 103 still launches"
reset
seedrow "$P BH-102" stacked "$(jq -nc --arg b ticket/bh-101 --arg t "$(iso $((NOW - 25200)))" --arg u "$PRURL/900" \
  '{chain:100,parent:101,parent_pr:$u,base:$b,depth:1,stacked_at:$t}')"
sl <<<"$E" >/dev/null
grep -q 'cromford 102' "$H/calls/fastpath" 2>/dev/null && ok || bad "S6: stacked 7h ago — fastpath is asked again (calls: $(fpcalls))"
reset
seedrow "$P BH-102" stacked "$(jq -nc --arg b ticket/bh-999 --arg t "$(iso $((NOW - 60)))" --arg u "$PRURL/900" \
  '{chain:100,parent:101,parent_pr:$u,base:$b,depth:1,stacked_at:$t}')"
sl <<<"$E" >/dev/null
grep -q 'cromford 102' "$H/calls/fastpath" 2>/dev/null && ok || bad "S6: a row on a DIFFERENT base does not hold (calls: $(fpcalls))"

# ---------- S7 depth 2 ------------------------------------------------------
reset
printf '%s' "$PRS_S7" > "$H/fixture/prs.json"
mkpull 901 ticket/bh-102 ticket/bh-101
E7=$(uc)
grep -qF "STACKABLE 104 \"BH-104 third level\" base=ticket/bh-102 parent-pr=$PRURL/901 chain=#100 " <<<"$E7" \
  && ok || bad "S7: 104 is STACKABLE on 102's branch with chain=#100 (got: $E7)"
sl <<<"$E7" >/dev/null
lg | grep -qF "STACK-LAUNCH BH-104 base=ticket/bh-102 parent=#102 pr=#901 depth=2 chain=#100" \
  && ok || bad "S7: depth=2 in the log (log: $(lg))"
[ "$(put_for "$P BH-104" | jq -r '.detail|fromjson|.depth' 2>/dev/null)" = 2 ] && ok || bad "S7: depth 2 in the ledger ($(put_for "$P BH-104"))"

# ---------- S8 fail-open -------------------------------------------------------
IN8=$(printf 'board issues: UNBLOCKED 50 "BH-50" (x)\n%s\n' "$E")
s8() { # s8 <label> [project]  — stdout byte-identical, nothing called
  local o; o=$("$H/bin/stack-launch.sh" "${2:-$P}" 2>/dev/null <<<"$IN8"; printf x); o="${o%x}"
  [ "$o" = "$IN8"$'\n' ] && ok || bad "S8 $1: stdout must be stdin verbatim (got: $o)"
  [ "$(nfp)" = 0 ] && ok || bad "S8 $1: nothing may be launched (calls: $(fpcalls))"
}
reset; touch "$H/flags/stack-default-off"; s8 stack-default-off
reset; STACKED_BUILDS=0 s8 STACKED_BUILDS=0
reset; touch "$H/flags/stacked-builds-off"; s8 stacked-builds-off
reset; mv "$H/bin/lib/block-gate.sh" "$T/bg-away"; s8 no-block-gate-lib; mv "$T/bg-away" "$H/bin/lib/block-gate.sh"
reset; s8 in-app-board project-3
reset; s8 bad-project '../x'

# ---------- L1 time saved ------------------------------------------------------
reset
T0=$((NOW - 7200))
seedrow "$P BH-102" stacked "$(jq -nc --arg t "$(iso "$T0")" --arg u "$PRURL/900" \
  '{chain:100,parent:101,parent_pr:$u,base:"ticket/bh-101",depth:1,stacked_at:$t}')"
seedrow "$P BH-120" stacked "$(jq -nc --arg t "$(iso "$T0")" --arg u "$PRURL/902" \
  '{chain:100,parent:119,parent_pr:$u,base:"ticket/bh-119",depth:1,stacked_at:$t}')"
seedrow "other BH-102" stacked "$(jq -nc --arg t "$(iso "$T0")" --arg u "$PRURL/900" \
  '{chain:100,parent:101,parent_pr:$u,base:"ticket/bh-101",depth:1,stacked_at:$t}')"
mkpull 900 ticket/bh-101 main closed "$(iso $((T0 + 3600)))"
mkpull 902 ticket/bh-119 main closed ""
sl </dev/null >/dev/null
R=$(put_for "$P BH-102")
[ "$(jq -r '.status' <<<"$R" 2>/dev/null)" = parent-merged ] && ok || bad "L1: parent merged -> parent-merged (got: $R)"
[ "$(jq -r '.detail|fromjson|.saved_s' <<<"$R" 2>/dev/null)" = 3600 ] && ok || bad "L1: saved_s 3600 (got: $R)"
[ -n "$(jq -r '.detail|fromjson|.saved_basis // empty' <<<"$R" 2>/dev/null)" ] && ok || bad "L1: saved_basis stated (got: $R)"
[ "$(jq -r '.detail|fromjson|.depth' <<<"$R" 2>/dev/null)" = 1 ] && ok || bad "L1: the stored detail is kept (got: $R)"
lg | grep -qF "STACK-SAVED BH-102 depth=1 saved=60m (parent #101 merged)" && ok || bad "L1: STACK-SAVED log (log: $(lg))"
R=$(put_for "$P BH-120")
[ "$(jq -r '.status' <<<"$R" 2>/dev/null)" = parent-closed ] && ok || bad "L1: closed unmerged -> parent-closed (got: $R)"
[ "$(jq -r '.detail|fromjson|.saved_s' <<<"$R" 2>/dev/null)" = null ] && ok || bad "L1: no saving claimed for a closed parent (got: $R)"
[ -z "$(put_for "other BH-102")" ] && ok || bad "L1: another project's row is untouched"
: > "$H/ledger-puts.log"
sl </dev/null >/dev/null
[ ! -s "$H/ledger-puts.log" ] && ok || bad "L1: a finalised row is never rewritten: $(cat "$H/ledger-puts.log")"

# ---------- W1/W2 the tick wiring --------------------------------------------
reset
printf '#!/bin/bash\nexit 0\n' > "$H/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 2\n' > "$H/bin/gate-diff.sh"
chmod +x "$H/bin/triage-gate.sh" "$H/bin/gate-diff.sh"
w() { ( PROJECT="$P"; . "$H/bin/lib/rt/scope.sh" 2>/dev/null; board_section; printf '%s' "$BOARD_SEC" ); }
BS=$(w)
grep -q 'STACKABLE 102' <<<"$BS" && bad "W1: board_section must not hand a launched sibling to the model (BOARD_SEC: $BS)" || ok
grep -q 'cromford 102 base=ticket/bh-101' "$H/calls/fastpath" 2>/dev/null && ok || bad "W1: the tick launched 102 stacked (calls: $(fpcalls))"
grep -q 'STACKABLE 110' <<<"$BS" && ok || bad "W1: the non-chain line still reaches the model (BOARD_SEC: $BS)"
reset
mv "$H/bin/stack-launch.sh" "$T/sl-away" 2>/dev/null
BS=$(w)
grep -qF "$(grep 'STACKABLE 102' <<<"$E")" <<<"$BS" && ok || bad "W2: without the script the line reaches the model as today (BOARD_SEC: $BS)"
[ "$(nfp)" = 0 ] && ok || bad "W2: nothing launched without the script"
mv "$T/sl-away" "$H/bin/stack-launch.sh" 2>/dev/null

echo "stack-launch.bh-3684: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
