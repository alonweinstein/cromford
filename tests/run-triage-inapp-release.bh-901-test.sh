#!/bin/bash
# tests/run-triage-inapp-release.bh-901-test.sh — BH-901 (BH-815.2): on an in-app
# board, a ticket whose `blocked` went true -> false THIS tick reaches the triage
# prompt as an UNBLOCKED line, the GitHub lane is untouched, and the in-app
# parent-close lane gets its one caller per tick.
#
# WHY IT HAS TO BE THE PROMPT. bin/unblocked-children.sh is the GitHub half of
# this: it reads `Blocked-by: #N` out of issue bodies and names the released
# child so the watcher launches it on the tick the blocker closed, not on the
# daily sweep. In-app boards have no Blocked-by convention, so that script exits
# 0 for them and the released child waited up to 24h. The in-app half is the
# fingerprint diff: bin/triage-gate.sh carries `blocked` per ticket (BH-899), the
# gate already keeps the consumed fingerprint beside the live one, and a boolean
# flip between those two files IS the release.
#
# This drives the REAL bin/run-triage.sh with its roots rewritten (the shape
# tests/event-wake-scope-test.sh established) and asserts on what agent-call.sh
# RECEIVES — never on the source of the function under test. Shards are disarmed
# so one tick is one prompt. The fingerprints for the main cases are the CONTRACT
# fixtures (tests/fixtures/triage-gate-dependencies/*.json) projected through
# bin/triage-gate.sh's own fetch_fingerprint jq, so the rows under test are the
# rows the board API contract describes — including the adversarial 1840, whose
# `blocked` is the STRING "true" and which the projection therefore never adopts.
# No network, no model.
# Run from anywhere: tests/run-triage-inapp-release.bh-901-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "run-triage-inapp-release.bh-901: jq missing, cannot run"; exit 1; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" x-os ghproj || exit 1  # BH-1510.2: lanes read models from model_routes
FIX="$DIR/tests/fixtures/triage-gate-dependencies"
mkdir -p "$H/bin/lib/rt" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/calls" "$T/repos"
: > "$H/env/global.env"
echo "SOP for x-os. Fetch the thread. Do the work." > "$H/prompts/x-os.md"
echo "SOP for ghproj. Fetch the thread. Do the work." > "$H/prompts/ghproj.md"

# A scratch registry with one in-app row and one GitHub-Issues row, so "behind
# the same board_prefix != '-' test the GH lane uses" is a real assertion and not
# a reading of the code.
cat > "$T/fleet.conf" <<'EOC'
x-os   example-org/x-os    https://board.example  /api/board  2 box-1 10.0.0.1
ghproj example-org/ghproj  https://gh.example     -           4 box-1 10.0.0.1
EOC
export FLEET_CONF="$T/fleet.conf"

sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/run-triage.sh" > "$H/bin/run-triage.sh"
chmod +x "$H/bin/run-triage.sh"
for s in "$DIR"/bin/lib/rt/*.sh; do
  [ -r "$s" ] || continue
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
for s in fleet-conf.sh project-of.sh decision-log.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
cp "$DIR/bin/lib/triage-shards-lib.sh" "$H/bin/lib/triage-shards-lib.sh"
printf '#!/bin/sh\necho box-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"

# --- stubs -------------------------------------------------------------------
# The gate: writes the fixture's live fingerprint where the real one does, and
# prints the fixture's verdict. The two fingerprint FILES are the input under
# test, so they are what the fixture controls.
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
PRJ="\$1"; MODE="\${2:-}"
printf '%s %s\n' "\$PRJ" "\$MODE" >> "$H/gate-calls.log"
cp "$H/fixture/pending.json" "$H/state/\$PRJ.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
[ "\$MODE" = "--buildable" ] && { echo OK; exit 0; }
cat "$H/fixture/gate-decision"
exit 0
STUB
chmod +x "$H/bin/triage-gate.sh"
# The REAL gate-diff (roots repointed like the driver's, because it resolves
# $HARNESS itself), so the scope arm sees the lines production would see.
sed -e "s|/root/harness|$H|g" "$DIR/bin/gate-diff.sh" > "$H/bin/gate-diff.sh"
chmod +x "$H/bin/gate-diff.sh"
# The GitHub dependency pass: records its calls, prints nothing of its own.
cat > "$H/bin/unblocked-children.sh" <<STUB
#!/bin/bash
cat > /dev/null
echo "\$1" >> "$H/unblocked-calls.log"
exit 0
STUB
chmod +x "$H/bin/unblocked-children.sh"
# The parent-close lane: records the argv it was handed, closes nothing.
cat > "$H/bin/decompose-parent-close.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$H/parent-close-calls.log"
cat "$H/fixture/parent-closed" 2>/dev/null
exit 0
STUB
chmod +x "$H/bin/decompose-parent-close.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
D="${CALLDIR:?}"
PR="$6"; case "$PR" in @/*) PR=$(cat "${PR#@}") ;; esac
F=$(mktemp "$D/prompt-XXXXXXXX.txt")
printf '%s' "$PR" > "$F"
echo "tickets=1 done" > "$5"
exit 0
STUB
chmod +x "$H/bin/agent-call.sh"

# --- the fingerprints --------------------------------------------------------
# fp_of <contract-fixture.json> — the SAME projection bin/triage-gate.sh's
# fetch_fingerprint applies to a board listing (copied from bin/triage-gate.sh),
# wrapped as the one-board object {boardId:[ticket,…]} the gate writes. A row
# whose `blocked` is not a JSON boolean (1840: the string "true") keeps only the
# seven original keys, which is why nothing about it can ever flip.
fp_of() {
  jq -cS '[(.tickets? // .) | .[]? | {id,status,waitingOn,triageVerdict,commentCount,lastActivityAt,title}
           + (if ((.blocked | type) == "boolean")
              then {key, blocked, parentId, dependsOn: [.dependsOn[]? | .id]}
              else {} end)] | sort_by(.id) | {b1: .}' "$1"
}
BEFORE=$(fp_of "$FIX/tickets-cap.json")        # 1825 blocked:true, dependsOn [1800]
AFTER=$(fp_of "$FIX/tickets-cap-after.json")   # 1825 blocked:false — the release
# The un-adopted board: every row keeps the seven pre-dependency keys.
PLAIN_OLD=$(fp_of "$FIX/tickets-null.json")
PLAIN_NEW=$(jq -cS '.b1[0].title = "renamed this tick"' <<<"$PLAIN_OLD")

# Inline rows for the shapes the contract fixtures cannot express: a field the
# board DROPPED next tick, a ticket that did not exist last tick, and N flips.
tkt() { # tkt <id> <key> <blocked-json> <dependsOn-json> <title>
  jq -cn --arg id "$1" --arg k "$2" --argjson b "$3" --argjson d "$4" --arg t "$5" \
    '{id:$id, status:"todo", waitingOn:"team", triageVerdict:"ready",
      commentCount:1, lastActivityAt:"2026-09-18T05:00:00Z", title:$t,
      key:$k, blocked:$b, parentId:null, dependsOn:$d}'
}
plain() { jq -cn --arg id "$1" --arg t "$2" \
  '{id:$id, status:"todo", waitingOn:"team", triageVerdict:"ready",
    commentCount:1, lastActivityAt:"2026-09-18T05:00:00Z", title:$t}'; }

reset() { # reset <project> <gate-decision> <old-fp> <new-fp>
  rm -rf "$T/calls" "$H/state" "$H/locks" "$H/logs" "$H/builds"
  model_routes_fixture "$H" x-os ghproj || exit 1   # the reset above took the model-routes cache with it
  mkdir -p "$T/calls" "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/gate-calls.log" "$H/unblocked-calls.log" "$H/parent-close-calls.log" \
        "$H/fixture/parent-closed"
  printf '%s' "$3" > "$H/state/$1.gate.json"
  printf '%s' "$4" > "$H/fixture/pending.json"
  echo "$2" > "$H/fixture/gate-decision"
  : > "$H/logs/READY-QUEUE.log"
  return 0
}
run() { CALLDIR="$T/calls" TRIAGE_SHARDS=0 "$H/bin/run-triage.sh" "$1" >/dev/null 2>&1; }
prompt() { cat "$(ls "$T/calls"/prompt-*.txt 2>/dev/null | head -1)" 2>/dev/null; }
# ONLY the release lines. The TICK SCOPE instruction text says the word
# UNBLOCKED four times on its own, so a bare grep would count the prompt's
# explanation of the class as members of it.
rlines()   { prompt | grep -E '^board [^:]+: UNBLOCKED ' 2>/dev/null || true; }
nrelease() { rlines | grep -c . || true; }
pclines()  { grep -c . "$H/parent-close-calls.log" 2>/dev/null || true; }

# ---------- AT-1. the release reaches the board-changed tick's scope ---------
reset x-os "RUN board-changed" "$BEFORE" "$AFTER"
run x-os
R=$(rlines)
[ "$(nrelease)" = 1 ] && ok || bad "AT-1 exactly one release line expected, got $(nrelease): $R"
grep -q 'UNBLOCKED 1825 ' <<<"$R" && ok || bad "AT-1 the released ticket must be named: $R"
grep -q 'TK-1825 — dependency TK-1800 done' <<<"$R" && ok \
  || bad "AT-1 the line must name the child's key and the dependency's key: $R"
grep -q '^TICK SCOPE (deterministic' <<<"$(prompt)" && ok \
  || bad "AT-1 the tick must still be the deterministic scope shape: $(prompt | head -2)"

# ---------- AT-2. THE NEGATIVES, one per way a flip can look like one -------
grep -q 'UNBLOCKED 1826' <<<"$R" && bad "AT-2 false -> false must not release" || ok
grep -q 'UNBLOCKED 1800' <<<"$R" && bad "AT-2 the blocker itself must not be released" || ok
grep -q 'UNBLOCKED 1830' <<<"$R" && bad "AT-2 an untouched parent must not be released" || ok
grep -q 'UNBLOCKED 1840' <<<"$R" \
  && bad "AT-2 blocked:\"true\" (string) is never adopted, so it cannot flip" || ok

# true -> absent: the board dropped the field on the next tick.
DROP_OLD=$(jq -cn --slurpfile a <(tkt tk-drop TK-1840 true '["dep-1"]' "field dropped next tick") '{b1: $a}')
DROP_NEW=$(jq -cn --slurpfile a <(plain tk-drop "field dropped next tick, renamed") '{b1: $a}')
reset x-os "RUN board-changed" "$DROP_OLD" "$DROP_NEW"
run x-os
[ -z "$(rlines)" ] && ok || bad "AT-2 true -> absent must not release: $(rlines)"

# still blocked: the row moved (its title changed, so the board diff carries it)
# but the boolean did not. A release is a FLIP, not a state.
STUCK_OLD=$(jq -cn --slurpfile a <(tkt tk-stuck TK-1841 true '["dep-1"]' "waiting on the blocker") '{b1: $a}')
STUCK_NEW=$(jq -cn --slurpfile a <(tkt tk-stuck TK-1841 true '["dep-1"]' "waiting on the blocker, retitled") '{b1: $a}')
reset x-os "RUN board-changed" "$STUCK_OLD" "$STUCK_NEW"
run x-os
[ -z "$(rlines)" ] && ok || bad "AT-2 true -> true must not release: $(rlines)"

# null -> false, and the field ABSENT -> false. Neither is a release: the board
# was not holding this ticket last tick, and "not blocked now" is not the same
# fact as "was blocked and now is not" (D11, absent is not false). The contract
# fixtures cannot express either shape — tickets-cap.json carries only a
# false -> false row — so they are built inline, and each run also asserts the
# tick produced a prompt, or "no release line" would pass on a tick that never ran.
NULL_OLD=$(jq -cn --slurpfile a <(tkt tk-null TK-1842 null '["dep-1"]' "never carried a blocked boolean") '{b1: $a}')
NULL_NEW=$(jq -cn --slurpfile a <(tkt tk-null TK-1842 false '["dep-1"]' "never carried a blocked boolean, retitled") '{b1: $a}')
reset x-os "RUN board-changed" "$NULL_OLD" "$NULL_NEW"
run x-os
[ -n "$(prompt)" ] && [ -z "$(rlines)" ] && ok \
  || bad "AT-2 null -> false must not release (and the tick must still run): $(rlines)"

ABSENT_OLD=$(jq -cn --slurpfile a <(tkt tk-abs TK-1843 null '["dep-1"]' "no blocked field last tick" | jq -c 'del(.blocked)') '{b1: $a}')
ABSENT_NEW=$(jq -cn --slurpfile a <(tkt tk-abs TK-1843 false '["dep-1"]' "no blocked field last tick, retitled") '{b1: $a}')
reset x-os "RUN board-changed" "$ABSENT_OLD" "$ABSENT_NEW"
run x-os
[ -n "$(prompt)" ] && [ -z "$(rlines)" ] && ok \
  || bad "AT-2 absent -> false must not release (and the tick must still run): $(rlines)"

# a ticket that did not exist last tick, arriving unblocked.
NEW_OLD=$(jq -cn --slurpfile a <(tkt tk-keep TK-1900 false '[]' "already here") '{b1: $a}')
NEW_NEW=$(jq -cn --slurpfile a <(
  tkt tk-keep TK-1900 false '[]' "already here"
  tkt tk-new  TK-1901 false '[]' "filed this tick, never blocked"
) '{b1: $a}')
reset x-os "RUN board-changed" "$NEW_OLD" "$NEW_NEW"
run x-os
[ -z "$(rlines)" ] && ok || bad "AT-2 a ticket NEW this tick must not release: $(rlines)"

# a board that never adopted the dependency fields at all.
reset x-os "RUN board-changed" "$PLAIN_OLD" "$PLAIN_NEW"
run x-os
[ -z "$(rlines)" ] && ok || bad "AT-2 an un-adopted board must produce no release line: $(rlines)"
grep -q 'TICK SCOPE (deterministic' <<<"$(prompt)" && ok \
  || bad "AT-2 …and the tick must otherwise behave exactly as before: $(prompt | head -2)"

# ---------- AT-3. the parent-close lane has a caller ------------------------
# A lane with no production caller is a dead feature. It is called --cooled: the
# cooldown is a dedupe window, never a wait (the operator, 2026-09-13).
reset x-os "RUN board-changed" "$BEFORE" "$AFTER"
printf 'TK-1800\n' > "$H/fixture/parent-closed"
run x-os
[ "$(pclines)" = 1 ] && ok \
  || bad "AT-3 the in-app parent-close lane must be called exactly once per tick, got $(pclines)"
[ "$(head -1 "$H/parent-close-calls.log" 2>/dev/null)" = "x-os --cooled" ] && ok \
  || bad "AT-3 it must be called '<project> --cooled': $(cat "$H/parent-close-calls.log" 2>/dev/null)"
grep -q 'PARENT_CLOSED TK-1800' "$H/logs/x-os.log" 2>/dev/null && ok \
  || bad "AT-3 a parent the lane closed must be recorded in the tick's own log"
# …and its stdout is NOT scope: a closed parent is a board change the next
# fingerprint diff carries, not a ticket to work this tick. Asserted on the
# prompt with the release lines (which legitimately name TK-1800 as the
# dependency that landed) removed.
grep -q 'TK-1800' <<<"$(prompt | grep -vE '^board [^:]+: UNBLOCKED ')" \
  && bad "AT-3 the closed parent key must not leak into the prompt" || ok

# ---------- AT-4. the GitHub lane is untouched ------------------------------
reset ghproj "RUN board-changed" "$BEFORE" "$AFTER"
run ghproj
[ -z "$(rlines)" ] && ok || bad "AT-4 a board_prefix '-' project must get no in-app release line: $(rlines)"
[ -s "$H/unblocked-calls.log" ] && ok || bad "AT-4 the GitHub dependency pass must still be called on a '-' project"
[ -f "$H/parent-close-calls.log" ] \
  && bad "AT-4 the in-app parent-close lane must not run on a GitHub board: $(cat "$H/parent-close-calls.log")" || ok

# ---------- AT-5. the cap ---------------------------------------------------
# WHAT BOUNDS THIS IN PRODUCTION, honestly. bin/gate-diff.sh refuses a diff of
# more than MAX_CHANGES=25 tickets (rc 1), and every caller of this function sits
# behind a usable diff, so the upstream bound already holds at 25. The cap here
# is the belt to that braces and, being a knob, is what the suite can drive.
FLIPS=5
BIG_OLD=$(jq -cn --argjson n "$FLIPS" '{b1: [range($n) | {id:("tk-\(.)"), status:"todo", waitingOn:"team",
   triageVerdict:"ready", commentCount:1, lastActivityAt:"2026-09-18T05:00:00Z",
   title:("t\(.)"), key:("TK-\(.)"), blocked:true, parentId:null, dependsOn:[]}]}')
BIG_NEW=$(jq -cn --argjson n "$FLIPS" '{b1: [range($n) | {id:("tk-\(.)"), status:"todo", waitingOn:"team",
   triageVerdict:"ready", commentCount:1, lastActivityAt:"2026-09-18T05:00:00Z",
   title:("t\(.)"), key:("TK-\(.)"), blocked:false, parentId:null, dependsOn:[]}]}')
reset x-os "RUN board-changed" "$BIG_OLD" "$BIG_NEW"
run x-os
[ "$(nrelease)" = "$FLIPS" ] && ok \
  || bad "AT-5 under the default ceiling all $FLIPS released tickets must be named, got $(nrelease)"
grep -q 'dependency unlisted done' <<<"$(rlines)" && ok \
  || bad "AT-5 a release with an empty dependsOn must say 'unlisted': $(rlines | head -1)"

# ---------- AT-6. …and the ceiling is a knob, not a constant ----------------
reset x-os "RUN board-changed" "$BIG_OLD" "$BIG_NEW"
CALLDIR="$T/calls" TRIAGE_SHARDS=0 INAPP_RELEASE_MAX_LINES=1 "$H/bin/run-triage.sh" x-os >/dev/null 2>&1
[ "$(nrelease)" = 1 ] && ok || bad "AT-6 INAPP_RELEASE_MAX_LINES must bound the lines, got $(nrelease)"
# 0 disables the LINES and nothing else: the parent-close lane still runs, because
# a knob about prompt size has no business switching a board write off.
reset x-os "RUN board-changed" "$BIG_OLD" "$BIG_NEW"
CALLDIR="$T/calls" TRIAGE_SHARDS=0 INAPP_RELEASE_MAX_LINES=0 "$H/bin/run-triage.sh" x-os >/dev/null 2>&1
[ "$(nrelease)" = 0 ] && ok || bad "AT-6 INAPP_RELEASE_MAX_LINES=0 must print no line, got $(nrelease)"
[ "$(pclines)" = 1 ] && ok \
  || bad "AT-6 …and the parent-close lane must still be called once, got $(pclines)"

# ---------- AT-7. a queue tick carries the release too ----------------------
# board_section's rc-0 arm. The release is not about the queue, but a tick that
# already re-checked the fingerprint knows about it and must not sit on it.
reset x-os "RUN queue-pending" "$BEFORE" "$AFTER"
printf 'TK-1900 waiting on PR #3\n' > "$H/logs/READY-QUEUE.log"
run x-os
grep -q 'UNBLOCKED 1825 ' <<<"$(prompt)" && ok \
  || bad "AT-7 a queue tick must carry the released child: $(prompt | head -5)"

# ---------- AT-8. a missing fingerprint file is "no line", never a guess ----
reset x-os "RUN board-changed" "$BEFORE" "$AFTER"
rm -f "$H/state/x-os.gate.json"
run x-os
[ -z "$(rlines)" ] && ok || bad "AT-8 no consumed fingerprint must mean no release line: $(rlines)"
[ -n "$(prompt)" ] && ok || bad "AT-8 …and the tick must still run"

# ---------- AT-9. a results sweep on an UNCHANGED board ---------------------
# board_section's rc-2 arm: gate-diff answers "verified unchanged", which is an
# answer about the BOARD and not about the lane. Nothing flipped, so no release
# line — but the parent-close lane still gets its tick.
reset x-os "RUN results-sweep" "$AFTER" "$AFTER"
mkdir -p "$H/builds/x-os-TK-1"
echo "PR opened: https://example.invalid/pr/1" > "$H/builds/x-os-TK-1/RESULT"
run x-os
[ -z "$(rlines)" ] && ok || bad "AT-9 an unchanged board must release nothing: $(rlines)"
grep -q 'TICK SCOPE (results sweep' <<<"$(prompt)" && ok \
  || bad "AT-9 the sweep scope must still be built: $(prompt | head -2)"
[ "$(pclines)" = 1 ] && ok \
  || bad "AT-9 the rc-2 arm must still call the parent-close lane once, got $(pclines)"

echo "run-triage-inapp-release.bh-901: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
