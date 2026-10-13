#!/bin/bash
# tests/launch-fastpath-stack.bh-3684-test.sh — BH-3684: bin/launch-fastpath.sh
# STACK MODE. With FASTPATH_STACK_BASE + FASTPATH_STACK_PARENT set, the named
# parent is accepted as the one open blocker WITHOUT asking dep-verify.sh, and
# the build is spawned with STACK_BASE / STACK_PARENT_PR in its environment and
# the same argv as ever. Every other condition still decides.
#
# Driven whole: the real script against a scratch $HARNESS with a gh REST
# fixture server, a curl stub for the two ledger reads, dep-verify.sh and
# run-build.sh as recorders. The scaffold is tests/launch-fastpath-test.sh's.
#
#   F1  stack mode launches a child whose one open blocker is the named parent
#   F2  the spawn: argv unchanged, STACK_BASE and STACK_PARENT_PR exported
#   F3  the same key without the stack env declines as today (HARD)
#   F4  a second open blocker still goes to dep-verify.sh and declines
#   F5  a parent that is not an open blocker declines
#   F6  two keys, or an unsafe base, decline every key
#   F7  stacked-builds-off declines, no spawn
#   F8  a HOLD comment still wins in stack mode
# Run from anywhere: bash tests/launch-fastpath-stack.bh-3684-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v flock   >/dev/null || { echo "flock missing — skipping"; exit 0; }

NOW=$(date -u +%s)
H="$T/h"
P=cromford
PRURL="https://github.com/example-org/cromford/pull"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H" LANE_GATE_DISABLE=1
cp "$DIR/bin/launch-fastpath.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/lock-hygiene.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" \
   "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
cat > "$H/fleet.conf" <<'CONF'
cromford example-org/cromford https://bh.example - 9 box-bh 10.0.0.13
CONF
export FLEET_CONF="$H/fleet.conf"
printf '%s\n' '  `setsid /root/harness/bin/run-build.sh cromford <issue-number> BH-<issue-number> > /root/harness/logs/cromford.bh-<issue-number>-build.out 2>&1 &`' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"

# run-build.sh: argv and the STACK_* environment it was spawned with.
cat > "$H/bin/run-build.sh" <<'SH'
#!/bin/bash
printf 'argv=%s STACK_BASE=%s STACK_PARENT_PR=%s\n' "$*" "${STACK_BASE:-}" "${STACK_PARENT_PR:-}" >> "$HARNESS/launches.log"
SH
chmod +x "$H/bin/run-build.sh"
cat > "$H/bin/dep-verify.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/dep-calls.log"
echo "${DEP_VERDICT:-HARD} shim says so"
SH
chmod +x "$H/bin/dep-verify.sh"

cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
A="$*"
PAGE=$(printf '%s' "$A" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
case "$A" in
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*)
    n=$(printf '%s' "$A" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ (.comments // [])[] ]' "$HARNESS/fixture/issue-$n.json")" ;;
  *"/issues/"*)
    n=$(printf '%s' "$A" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    [ -f "$HARNESS/fixture/issue-$n.json" ] || SEND 404 '{"message":"Not Found"}'
    SEND 200 "$(jq -c '{number, state:(.state|ascii_downcase), title, body, labels, comments:((.comments // [])|length)}' \
                 "$HARNESS/fixture/issue-$n.json")" ;;
  *"/issues"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(jq -c '[ .[] | {number, state:(.state|ascii_downcase)} ]' "$HARNESS/fixture/states.json")" ;;
  *"/pulls"*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 '[]' ;;
  *"api repos/"*) echo 12345 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  # TEST-CHANGE BH-4153: paused-* is now a harness_flags row read DB-first; the
  # catch-all 200 {"ok":true} is an unreadable flag answer, which fails closed as
  # "project paused". No row exists in this fixture, so answer 404 (= off).
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"; chmod +x "$T/fakebin/setsid"
export PATH="$T/fakebin:$PATH"

LAB='[{"name":"ai-build"}]'
mkissue() { # mkissue <n> <state> <title> <body> [comments-json]
  jq -n --argjson n "$1" --arg st "$2" --argjson lb "$LAB" --arg t "$3" --arg b "$4" --argjson c "${5:-[]}" \
    '{number:$n,state:$st,title:$t,body:$b,labels:$lb,comments:$c}' > "$H/fixture/issue-$1.json"
}
reset() {
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/launches.log" "$H/dep-calls.log" "$H/flags"/* "$H/fixture"/issue-*.json
  echo '[{"number":101,"state":"OPEN"},{"number":102,"state":"OPEN"},{"number":105,"state":"OPEN"}]' > "$H/fixture/states.json"
  mkissue 101 OPEN "BH-101 contract" $'Part of #100\n## Scope\nx\n## Acceptance tests\n- y\n'
  mkissue 102 OPEN "BH-102 sibling" $'Part of #100\nBlocked-by: #101 (hard)\n\n## Scope\nx\n\n## Acceptance tests\n- y\n'
}
STK=(FASTPATH_STACK_BASE=ticket/bh-101 FASTPATH_STACK_PARENT=101 "FASTPATH_STACK_PARENT_PR=$PRURL/900")
run() { OUT=$(env "$@" 2>/dev/null); RC=$?; }
fp() { printf '%s' "$H/bin/launch-fastpath.sh"; }
reason() { grep -F "FASTPATH-DECLINED $1 ::" "$H/logs/$P.log" 2>/dev/null | tail -1 | sed 's/.*:: //'; }
nlaunch() { local n; n=$(grep -c . "$H/launches.log" 2>/dev/null); echo "${n:-0}"; }

# ---------- F1 + F2 stack mode launches --------------------------------------
reset
run "${STK[@]}" "$(fp)" "$P" 102
[ "$RC" = 0 ] && ok || bad "F1: stack mode must launch 102 (rc=$RC, reason: $(reason 102))"
grep -qF "FASTPATH BH-102 (issue #102) — launched stacked on ticket/bh-101 (parent #101)" "$H/logs/$P.log" 2>/dev/null \
  && ok || bad "F1: the launch line names the stack (log: $(cat "$H/logs/$P.log" 2>/dev/null))"
grep -q ' 101$' "$H/dep-calls.log" 2>/dev/null && bad "F1: the named parent is not asked of dep-verify.sh ($(cat "$H/dep-calls.log"))" || ok
grep -qxF "argv=$P 102 BH-102 STACK_BASE=ticket/bh-101 STACK_PARENT_PR=$PRURL/900" "$H/launches.log" 2>/dev/null \
  && ok || bad "F2: argv unchanged + STACK_* env (got: $(cat "$H/launches.log" 2>/dev/null))"

# ---------- F3 no stack env: today's decline --------------------------------
reset
run "$(fp)" "$P" 102
[ "$RC" = 1 ] && ok || bad "F3: without the stack env 102 declines (rc=$RC)"
case "$(reason 102)" in "blocker #101 open (HARD"*) ok ;; *) bad "F3: reason was '$(reason 102)'" ;; esac
[ "$(nlaunch)" = 0 ] && ok || bad "F3: nothing spawned"
reset
run "$(fp)" "$P" 101
grep -q 'STACK_BASE= STACK_PARENT_PR=$' "$H/launches.log" 2>/dev/null && ok || bad "F3: a plain launch carries no STACK_* env ($(cat "$H/launches.log" 2>/dev/null))"
grep -qF "FASTPATH BH-101 (issue #101) — launched" "$H/logs/$P.log" && ! grep -q 'launched stacked' "$H/logs/$P.log" \
  && ok || bad "F3: the plain launch line is unchanged"

# ---------- F4 a second open blocker still decides -------------------------
reset
mkissue 102 OPEN "BH-102 sibling" $'Blocked-by: #101 (hard), #105\n\n## Scope\nx\n\n## Acceptance tests\n- y\n'
run "${STK[@]}" "$(fp)" "$P" 102
case "$(reason 102)" in "blocker #105 open (HARD"*) ok ;; *) bad "F4: the second blocker declines, reason '$(reason 102)'" ;; esac
grep -q "$P 102 105" "$H/dep-calls.log" 2>/dev/null && ok || bad "F4: #105 was asked of dep-verify ($(cat "$H/dep-calls.log" 2>/dev/null))"
[ "$(nlaunch)" = 0 ] && ok || bad "F4: nothing spawned"

# ---------- F5 the parent must be an open blocker ---------------------------
reset
run FASTPATH_STACK_BASE=ticket/bh-999 FASTPATH_STACK_PARENT=999 "$(fp)" "$P" 102
[ "$(reason 102)" = "stack parent #999 is not an open blocker" ] && ok || bad "F5: a parent that is not a blocker declines, reason '$(reason 102)'"
[ "$(nlaunch)" = 0 ] && ok || bad "F5: nothing spawned"
reset
mkissue 102 OPEN "BH-102 sibling" $'Blocked-by: #107\n\n## Scope\nx\n\n## Acceptance tests\n- y\n'
echo '[{"number":107,"state":"CLOSED"}]' > "$H/fixture/states.json"
run FASTPATH_STACK_BASE=ticket/bh-107 FASTPATH_STACK_PARENT=107 "$(fp)" "$P" 102
[ "$(reason 102)" = "stack parent #107 is not an open blocker" ] && ok || bad "F5: a CLOSED parent declines, reason '$(reason 102)'"
[ "$(nlaunch)" = 0 ] && ok || bad "F5/closed: nothing spawned"
reset
mkissue 102 OPEN "BH-102 sibling" $'## Scope\nx\n\n## Acceptance tests\n- y\n'
run "${STK[@]}" "$(fp)" "$P" 102
[ "$(reason 102)" = "stack parent #101 is not an open blocker" ] && ok || bad "F5: no Blocked-by at all declines, reason '$(reason 102)'"

# ---------- F6 malformed stack env -------------------------------------------
reset
run "${STK[@]}" "$(fp)" "$P" 102 101
case "$(reason 102)|$(reason 101)" in "stack mode: "*"|stack mode: "*) ok ;; *) bad "F6: two keys decline both ('$(reason 102)' / '$(reason 101)')" ;; esac
reset
run FASTPATH_STACK_BASE=../x FASTPATH_STACK_PARENT=101 "$(fp)" "$P" 102
case "$(reason 102)" in "stack mode: "*) ok ;; *) bad "F6: unsafe base declines, reason '$(reason 102)'" ;; esac
reset
run FASTPATH_STACK_BASE=ticket/bh-101 FASTPATH_STACK_PARENT=abc "$(fp)" "$P" 102
case "$(reason 102)" in "stack mode: "*) ok ;; *) bad "F6: non-numeric parent declines, reason '$(reason 102)'" ;; esac
reset
run FASTPATH_STACK_BASE=ticket/bh-101 "$(fp)" "$P" 102
case "$(reason 102)" in "stack mode: "*) ok ;; *) bad "F6: base without parent declines, reason '$(reason 102)'" ;; esac
[ "$(nlaunch)" = 0 ] && ok || bad "F6: nothing spawned"

# ---------- F7 stacked builds off --------------------------------------------
reset
touch "$H/flags/stacked-builds-off"
run "${STK[@]}" "$(fp)" "$P" 102
[ "$(reason 102)" = "stacked builds off" ] && ok || bad "F7: flags/stacked-builds-off declines, reason '$(reason 102)'"
[ "$(nlaunch)" = 0 ] && ok || bad "F7: nothing spawned"
reset
run STACKED_BUILDS=0 "${STK[@]}" "$(fp)" "$P" 102
[ "$(reason 102)" = "stacked builds off" ] && ok || bad "F7: STACKED_BUILDS=0 declines, reason '$(reason 102)'"

# ---------- F8 HOLD still wins ------------------------------------------------
reset
mkissue 102 OPEN "BH-102 sibling" $'Blocked-by: #101 (hard)\n\n## Scope\nx\n\n## Acceptance tests\n- y\n' '[{"body":"HOLD: not yet"}]'
run "${STK[@]}" "$(fp)" "$P" 102
[ "$(reason 102)" = "HOLD in comment" ] && ok || bad "F8: HOLD declines in stack mode, reason '$(reason 102)'"
[ "$(nlaunch)" = 0 ] && ok || bad "F8: nothing spawned"

echo "launch-fastpath-stack.bh-3684: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
