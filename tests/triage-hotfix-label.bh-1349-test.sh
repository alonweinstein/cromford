#!/bin/bash
# tests/triage-hotfix-label.bh-1349-test.sh — BH-1349, the two code follow-ups
# from the round-2 review of #750 (BH-645).
#
# ITEM 1 — THE LABEL IS A URL COMPONENT, NOT A STRING TO GLUE ON. The hotfix set
# is read as `repos/<slug>/issues?labels=ai-build,<label>&state=open`, and until
# this ticket <label> went in raw. A label with a SPACE (`hot fix`) gives `gh`
# a URL it cannot build: nothing comes back, not even an HTTP status line, so
# bin/lib/gh-rest.sh answers 75 and the whole tick silently degrades to FIFO. A
# label with an AMPERSAND (`p0&urgent`) is worse than silent — `&` ends the
# `labels` parameter, GitHub reads the filter as `ai-build,p0` alone, and the
# tick marks a SUPERSET of the right issues while looking like it worked.
#
# ITEM 2 — THE FOURTH SLICE. Three of bin/lib/rt/scope.sh's scope arms pipe
# their lines through triage_hot_mark (:132, :159, :383). The TICK_SCOPE arm —
# the one a `board-changed` or `event-wake` tick actually takes — did not, so a
# hotfix that reached the session through the board diff sat in diff order.
#
# WHAT IS ASSERTED IS THE RENDERED PROMPT — the artifact the stubbed
# bin/agent-call.sh receives — never the source of the script. The whole script
# runs against a scratch $HARNESS with only its roots repointed, exactly like
# tests/triage-hotfix-order-test.sh.
#
# THE FAKE gh IS STRICT ABOUT THE QUERY, which is what makes case 1 red before
# the fix: it answers the fixture list only when the `labels=` value is exactly
# the encoded string the test expects, answers `[]` (GitHub's answer to a label
# filter naming nothing) for any other value, and answers NOTHING AT ALL for a
# path carrying a raw space, which is what `gh api` does with a URL it cannot
# parse.
#
# THE NEGATIVES CARRY THE WEIGHT: a tick with no hotfix, and a tick with the
# lane off, must render a prompt BYTE-IDENTICAL to main's own render of the same
# fixture — the control is built by swapping this branch's changed bin/ files
# for `git show main:<path>` inside the SAME scratch harness, so the two runs
# differ by the product diff and by nothing else.
#
# Run from anywhere: tests/triage-hotfix-label.bh-1349-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
: "$NOW"

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" project-5 || exit 1  # BH-1510.2: lanes read models from model_routes
BKP="$T/branchcopy"
mkdir -p "$H/bin/lib/rt" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" \
         "$H/builds" "$H/catalog" "$T/calls" "$T/repos" "$T/fakebin" "$T/fixture" "$BKP"
: > "$H/env/global.env"
# A GitHub-Issues project (fleet.conf board prefix "-"): the label lives on a
# GitHub issue, so this lane is the only board shape the feature acts on.
P=project-5
echo "SOP for $P. Fetch the thread. Do the work." > "$H/prompts/$P.md"
export FLEET_CONF="$DIR/fleet.conf"

# --- the scripts under test, with only their roots repointed ------------------
for s in run-triage.sh triage-shard.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/$s" > "$H/bin/$s"
  chmod +x "$H/bin/$s"
done
# bin/run-triage.sh's stage bodies (BH-479) live in bin/lib/rt/*.sh, not inline.
for s in "$DIR"/bin/lib/rt/*.sh; do
  sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$s" > "$H/bin/lib/rt/$(basename "$s")"
done
# the real decision-makers — stubbing any of these would test the stub
cp "$DIR/bin/lib/triage-shards-lib.sh" "$DIR/bin/lib/hotfix-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/triage-hotfix-lib.sh" "$H/bin/lib/"
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do
  ln -sf "$DIR/bin/$s" "$H/bin/$s"
done
printf '#!/bin/sh\necho box-project-5-1\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"

# --- THE MAIN CONTROL --------------------------------------------------------
# Every bin/ file this branch changed, swapped for main's copy IN PLACE, in the
# same scratch harness. A control built in a second harness root would differ in
# every absolute path the prompt quotes, which is not a difference this ticket
# made; a control built from the branch could only prove the feature agrees with
# itself. A checkout with no `main` ref (a shallow CI clone) says so out loud
# and the byte-identity arms fall back to comparing this branch against itself.
MAIN_CTL=0
CHANGED=""
if git -C "$DIR" rev-parse --verify -q main >/dev/null 2>&1; then
  CHANGED=$(git -C "$DIR" diff --name-only main -- bin/ 2>/dev/null)
  MAIN_CTL=1
else
  echo "NOTE: no main ref in this checkout — the byte-identical control is the feature's own no-hotfix run, not main's"
fi
use_main() {
  local f
  for f in $CHANGED; do
    case " ${STUBBED:-} " in *" $f "*) continue ;; esac
    [ -e "$H/$f" ] || continue
    # ...and only where the scratch copy IS this branch's file, rendered. The
    # fixture STUBS most of $H/bin (bin/agent-call.sh is the recorder every
    # assertion below reads its evidence out of), and swapping a stub for
    # main's production copy does not build a control — it removes the
    # recorder, the control tick captures no prompt at all, and every
    # byte-identity arm fails on a file this ticket never touched. A branch
    # that edits bin/agent-call.sh must not turn this suite red for that
    # reason alone (BH-1384).
    sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/$f" > "$T/branch.raw" 2>/dev/null
    cmp -s "$T/branch.raw" "$H/$f" || continue
    mkdir -p "$BKP/$(dirname "$f")"
    cp -p "$H/$f" "$BKP/$f"
    if git -C "$DIR" show "main:$f" > "$T/main.raw" 2>/dev/null; then
      sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$T/main.raw" > "$H/$f"
      chmod +x "$H/$f"
    else
      rm -f "$H/$f"
    fi
  done
}
use_branch() {
  local f
  for f in $CHANGED; do
    case " ${STUBBED:-} " in *" $f "*) continue ;; esac
    [ -e "$BKP/$f" ] && cp -p "$BKP/$f" "$H/$f"
  done
  return 0
}

# --- stubs: the gate, the deterministic pass, the model call ------------------
cat > "$H/bin/triage-gate.sh" <<STUB
#!/bin/bash
PP="\$1"; MODE="\${2:-}"
cp "$T/fixture/pending.json" "$H/state/\$PP.gate.pending" 2>/dev/null
[ "\$MODE" = "--pending" ] && exit 0
[ "\$MODE" = "--buildable" ] && { echo OK; exit 0; }
cat "$T/fixture/gate-decision"
exit 0
STUB
chmod +x "$H/bin/triage-gate.sh"
# gate-diff's three answers, verbatim from its header: 0 with a diff, 2 for
# "fingerprints identical — nothing moved", 1 for anything unusable.
cat > "$H/bin/gate-diff.sh" <<STUB
#!/bin/bash
[ -s "$T/fixture/diff" ] || exit 2
cat "$T/fixture/diff"
exit 0
STUB
chmod +x "$H/bin/gate-diff.sh"
cat > "$H/bin/unblocked-children.sh" <<STUB
#!/bin/sh
cat "$T/fixture/unblocked" 2>/dev/null
exit 0
STUB
chmod +x "$H/bin/unblocked-children.sh"
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"; chmod +x "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
# agent-call.sh <stage> <project> <model> <timeout> <outfile> <prompt|@file>
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

# THE SUITE'S OWN STUBS ARE NOT SWAPPABLE (BH-1494). use_main() replaces every
# bin/ file the branch changed with main's copy, and $H/bin holds seven files
# this suite deliberately replaced with stubs. bin/agent-call.sh is the worst
# case: it is the PROMPT CAPTOR every assertion reads, so swapping in the real
# production script left $T/calls empty and section 0d failed with
# `diff: : No such file or directory` — on any branch that happens to touch
# bin/agent-call.sh, whatever the change was. The control is "main's copy of the
# code under test", never "main's copy of the harness around it".
STUBBED="bin/box-name.sh bin/triage-gate.sh bin/gate-diff.sh bin/unblocked-children.sh bin/triage-contract.sh bin/beat.sh bin/agent-call.sh"

# --- the fake gh -------------------------------------------------------------
# Every invocation is recorded. The hotfix read is answered ONLY when the
# `labels=` value in the path is byte-for-byte what $T/fixture/expect-labels
# says; a raw space in the path answers nothing at all (no status line, which is
# how bin/lib/gh-rest.sh learns the read is unverifiable); any other value
# answers 200 + `[]`, which is GitHub's answer to a label filter that names no
# such label.
cat > "$T/fakebin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls"
PATHARG=""
for A in "\$@"; do
  case "\$A" in *"/issues"\?"labels="*) PATHARG="\$A" ;; esac
done
if [ -n "\$PATHARG" ]; then
  case "\$PATHARG" in
    *" "*) exit 1 ;;
  esac
  LV="\${PATHARG#*labels=}"; LV="\${LV%%&*}"
  printf 'HTTP/1.1 200 OK\r\n\r\n'
  if [ "\$LV" = "\$(cat "$T/fixture/expect-labels" 2>/dev/null)" ]; then
    jq -R -s -c 'split("\n") | map(select(length>0)) | map({number:(.|tonumber), pull_request:null})' \
      "$T/fixture/hotfix-numbers" 2>/dev/null || printf '[]'
  else
    printf '[]'
  fi
  exit 0
fi
case "\$*" in
  *"api rate_limit"*) cat "$T/fixture/rate_limit.json" 2>/dev/null ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$T/fakebin/gh"

FP_GH='{"issues":[{"number":9101,"state":"OPEN","title":"plain"},{"number":9102,"state":"OPEN","title":"the emergency"}],"prs":[]}'
RATE_OK='{"resources":{"core":{"remaining":4900,"limit":5000,"reset":0},"graphql":{"remaining":4900,"limit":5000,"reset":0}}}'

# The board-changed diff shape bin/gate-diff.sh emits, hotfix SECOND.
DIFF2='board issues: CHANGED 9101 "plain" (state: OPEN -> OPEN)
board issues: CHANGED 9102 "the emergency" (state: OPEN -> OPEN)'
# The deterministic pass's shape, hotfix SECOND. Its last line carries no
# trailing newline in production; bin/unblocked-children.sh is stubbed here, so
# the loop's `|| [ -n "$line" ]` read is pinned by triage-hotfix-order-test 1h2.
UNBLOCKED2='board issues: UNBLOCKED 9101 "plain child" (parent PR merged)
board issues: UNBLOCKED 9102 "the emergency" (parent PR merged)'

reset() { # reset <gate-decision> <diff> <unblocked> <hotfix-numbers> <expect-labels>
  rm -rf "$T/calls"; mkdir -p "$T/calls"
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  model_routes_fixture "$H" project-5 || exit 1   # the reset above took the model-routes cache with it
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/builds"
  rm -f "$H/flags/hotfix-lane-off"
  printf '%s' "$FP_GH" > "$T/fixture/pending.json"
  printf '%s' "$FP_GH" > "$H/state/$P.gate.json"
  echo "$1" > "$T/fixture/gate-decision"
  printf '%s' "$2" > "$T/fixture/diff"
  printf '%s' "$3" > "$T/fixture/unblocked"
  printf '%s\n' "$4" | grep -v '^$' > "$T/fixture/hotfix-numbers" || : > "$T/fixture/hotfix-numbers"
  printf '%s' "$5" > "$T/fixture/expect-labels"
  printf '%s' "$RATE_OK" > "$T/fixture/rate_limit.json"
  : > "$T/gh-calls"
  : > "$H/logs/READY-QUEUE.log"
}
run() { # run <project> [VAR=VAL ...] — one tick of the shipped script
  local proj="$1"; shift
  CALLDIR="$T/calls" PATH="$T/fakebin:$PATH" \
    env TRIAGE_SHARDS=0 "$@" bash "$H/bin/run-triage.sh" "$proj" >/dev/null 2>&1
}
prompt_file() { ls "$T/calls"/prompt-*.txt 2>/dev/null | head -1; }
qblock() { # the rendered READY-QUEUE slice of the captured prompt
  awk '/^READY-QUEUE lines:$/{f=1;next} /^Queued launch requests for /{f=0} f' "$(prompt_file)"
}
sblock() { # the rendered TICK SCOPE slice of the captured prompt
  awk '/^TICK SCOPE \(deterministic/{f=1;next} f && NF==0{exit} f' "$(prompt_file)"
}
hot_calls() { grep -c 'issues?labels=' "$T/gh-calls" 2>/dev/null | tr -d ' '; }
SOP_LINE='Lines marked [HOTFIX] are launched before any other line.'

# 45 READY-QUEUE lines, the 43rd the hotfix key: the cap is 40, so a hotfix the
# tick never marked is a hotfix the session never sees.
queue_45() {
  local i n
  : > "$H/logs/READY-QUEUE.log"
  for i in $(seq 1 45); do
    n=$(printf '80%02d' "$i")
    [ "$i" = 43 ] && n=9102
    echo "BH-$n tid-$n — ready to build, waiting on PR #12 project=project-5" >> "$H/logs/READY-QUEUE.log"
  done
}

# ---------------------------------------------------------------------------
# 0. THE CONTROLS — one per tick shape, with no hotfix among the open issues.
#    Every negative below must reproduce these byte for byte.
# ---------------------------------------------------------------------------
reset "RUN board-changed" "$DIFF2" "" "" "ai-build,hotfix"
run "$P"
SCTL="$T/scope-control.prompt"
if [ -n "$(prompt_file)" ]; then cp "$(prompt_file)" "$SCTL"; ok; else bad "0: the board-changed control tick rendered no prompt at all"; : > "$SCTL"; fi
grep -q '\[HOTFIX\]' "$SCTL" && bad "0a: a tick with no hotfix issue must carry no [HOTFIX] marker" || ok
grep -qF "$SOP_LINE" "$SCTL" && bad "0b: the SOP sentence must be ABSENT when nothing is marked" || ok
[ "$(sblock | grep -c .)" = 2 ] && ok || bad "0c: the control TICK SCOPE must hold both diff lines (got: $(sblock | tr '\n' '|'))"

if [ "$MAIN_CTL" = 1 ]; then
  use_main
  reset "RUN board-changed" "$DIFF2" "" "" "ai-build,hotfix"
  run "$P"
  if [ -n "$(prompt_file)" ] && diff -q "$SCTL" "$(prompt_file)" >/dev/null 2>&1; then ok
  else bad "0d: with no hotfix the TICK SCOPE prompt must be byte-identical to main's own render ($(diff "$SCTL" "$(prompt_file)" 2>&1 | head -5))"; fi
  use_branch
fi

reset "RUN queue-pending" "" "" "" "ai-build,hotfix"
queue_45
run "$P"
QCTL="$T/queue-control.prompt"
if [ -n "$(prompt_file)" ]; then cp "$(prompt_file)" "$QCTL"; ok; else bad "0e: the queue-pending control tick rendered no prompt at all"; : > "$QCTL"; fi
[ "$(qblock | grep -c .)" = 40 ] && ok || bad "0f: the control queue block must hold exactly 40 lines (got $(qblock | grep -c .))"

# ---------------------------------------------------------------------------
# 1. §encode — the label reaches GitHub as a URL COMPONENT
# ---------------------------------------------------------------------------
# 1a: a space. Raw, `gh` gets a URL it cannot build and answers nothing at all,
# so the tick reads "no hotfixes" and the emergency stays at line 43 — past the
# cap, which is to say nowhere.
reset "RUN queue-pending" "" "" "9102" "ai-build,hot%20fix"
queue_45
run "$P" HOTFIX_LABEL='hot fix'
FIRSTQ=$(qblock | head -1)
case "$FIRSTQ" in
  '[HOTFIX] BH-9102 '*) ok ;;
  *) bad "1a: a label with a space must still select the hotfix and put it first (got: $FIRSTQ)" ;;
esac
[ "$(qblock | grep -c .)" = 40 ] && ok || bad "1a2: the cap still binds (got $(qblock | grep -c .))"

# 1c: and the recorded call carries the ENCODED label, never the raw space.
grep -q 'labels=ai-build,hot%20fix&state=open' "$T/gh-calls" && ok \
  || bad "1c: the recorded gh call must carry labels=ai-build,hot%20fix&state=open (got: $(head -1 "$T/gh-calls"))"
grep -q 'labels=ai-build,hot fix' "$T/gh-calls" && bad "1c2: the recorded gh call must not carry a raw space in its labels filter" || ok

# 1b: an ampersand. Raw, it ENDS the labels parameter — GitHub reads the filter
# as `ai-build,p0`, a superset, and the tick marks whatever that returns while
# looking like it worked.
reset "RUN queue-pending" "" "" "9102" "ai-build,p0%26urgent"
queue_45
run "$P" HOTFIX_LABEL='p0&urgent'
FIRSTQ=$(qblock | head -1)
case "$FIRSTQ" in
  '[HOTFIX] BH-9102 '*) ok ;;
  *) bad "1b: a label with an ampersand must still select the hotfix (got: $FIRSTQ)" ;;
esac
grep -q 'labels=ai-build,p0%26urgent&state=open' "$T/gh-calls" && ok \
  || bad "1b2: the ampersand must be encoded, not left to truncate the filter (got: $(head -1 "$T/gh-calls"))"

# 1d: the default label encodes to itself, so the fleet's own query — and the
# ETag key computed over it — does not move.
reset "RUN queue-pending" "" "" "9102" "ai-build,hotfix"
queue_45
run "$P"
grep -q 'labels=ai-build,hotfix&state=open' "$T/gh-calls" && ok \
  || bad "1d: the default label's query must be unchanged (got: $(head -1 "$T/gh-calls"))"
case "$(qblock | head -1)" in
  '[HOTFIX] BH-9102 '*) ok ;;
  *) bad "1d2: the default label must still select the hotfix (got: $(qblock | head -1))" ;;
esac

# ---------------------------------------------------------------------------
# 2. §tick-scope — the fourth slice is marked like the other three
# ---------------------------------------------------------------------------
# 2a: the board diff names the hotfix SECOND; the session must read it first.
reset "RUN board-changed" "$DIFF2" "" "9102" "ai-build,hotfix"
run "$P"
SFIRST=$(sblock | head -1)
case "$SFIRST" in
  '[HOTFIX] board issues: CHANGED 9102 '*) ok ;;
  *) bad "2a: the hotfix board line must be marked and FIRST in the TICK SCOPE (got: $SFIRST)" ;;
esac
# 2b: and nothing is dropped or spuriously marked on the way.
sblock | grep -q '^board issues: CHANGED 9101 ' && ok \
  || bad "2b: the plain diff line must still be listed, unmarked (got: $(sblock | tr '\n' '|'))"
[ "$(sblock | grep -c .)" = 2 ] && ok || bad "2b2: both diff lines must survive the sort (got: $(sblock | tr '\n' '|'))"
[ "$(sblock | grep -c '\[HOTFIX\] ')" = 1 ] && ok || bad "2b3: exactly one scope line may be marked (got $(sblock | grep -c '\[HOTFIX\] '))"

# 2c: a marker with no instruction is half a feature — and the sentence is said
# once, not once per marked line.
[ "$(grep -cF "$SOP_LINE" "$(prompt_file)")" = 1 ] && ok \
  || bad "2c: the SOP sentence must appear exactly once in a marked TICK SCOPE (got $(grep -cF "$SOP_LINE" "$(prompt_file)"))"

# 2d: ONE read per tick. The set is loaded in the parent shell, so a scope of N
# lines costs one gh call, not one per line and not one per slice.
[ "$(hot_calls)" = 1 ] && ok || bad "2d: the hotfix set must be read exactly once per tick (got $(hot_calls))"

# 2e: a tick with no hotfix renders today's prompt, byte for byte.
reset "RUN board-changed" "$DIFF2" "" "" "ai-build,hotfix"
run "$P"
if [ -n "$(prompt_file)" ] && diff -q "$SCTL" "$(prompt_file)" >/dev/null 2>&1; then ok
else bad "2e: a tick with no hotfix must render the control prompt byte for byte ($(diff "$SCTL" "$(prompt_file)" 2>&1 | head -5))"; fi

# 2f: the kill switch removes the READ, not just the prefix.
reset "RUN board-changed" "$DIFF2" "" "9102" "ai-build,hotfix"
touch "$H/flags/hotfix-lane-off"
run "$P"
[ "$(hot_calls)" = 0 ] && ok || bad "2f: flags/hotfix-lane-off must make ZERO hotfix reads (got $(hot_calls))"
if [ -n "$(prompt_file)" ] && diff -q "$SCTL" "$(prompt_file)" >/dev/null 2>&1; then ok
else bad "2f2: with the lane off the TICK SCOPE prompt must be byte-identical to the control ($(diff "$SCTL" "$(prompt_file)" 2>&1 | head -5))"; fi
rm -f "$H/flags/hotfix-lane-off"

# 2g: a child the DETERMINISTIC pass released is marked too. The board itself
# did not move (gate-diff rc 2), so these lines ARE the scope — and a hotfix
# child released by a parent merge is exactly the emergency this lane exists
# for, so the mark runs over the whole scope, after the UNBLOCKED append.
reset "RUN board-changed" "" "$UNBLOCKED2" "9102" "ai-build,hotfix"
run "$P"
SFIRST=$(sblock | head -1)
case "$SFIRST" in
  '[HOTFIX] board issues: UNBLOCKED 9102 '*) ok ;;
  *) bad "2g: a hotfix released by the deterministic pass must be marked and first (got: $SFIRST)" ;;
esac
[ "$(sblock | grep -c .)" = 2 ] && ok || bad "2g2: both released lines must survive (got: $(sblock | tr '\n' '|'))"
grep -qF "$SOP_LINE" "$(prompt_file)" && ok || bad "2g3: the SOP sentence must ride a deterministic-pass scope too"

# 2h: the lib may be absent entirely (a caller that does not source it — this is
# what tests/event-wake-scope-test.sh drives). The arm must fall back to the
# plain lines, never render a "command not found" into the prompt.
mv "$H/bin/lib/triage-hotfix-lib.sh" "$T/triage-hotfix-lib.parked"
reset "RUN board-changed" "$DIFF2" "" "9102" "ai-build,hotfix"
run "$P"
if [ -n "$(prompt_file)" ] && diff -q "$SCTL" "$(prompt_file)" >/dev/null 2>&1; then ok
else bad "2h: with bin/lib/triage-hotfix-lib.sh absent the prompt must be the control's ($(diff "$SCTL" "$(prompt_file)" 2>&1 | head -5))"; fi
grep -qi 'command not found' "$(prompt_file)" && bad "2h2: an unsourced lib must not leak a shell error into the prompt" || ok
mv "$T/triage-hotfix-lib.parked" "$H/bin/lib/triage-hotfix-lib.sh"

# ---------------------------------------------------------------------------
# 2i. §sharding-survives — a marked TICK_SCOPE must not disarm the split
# ---------------------------------------------------------------------------
# Every key regex in bin/lib/triage-shards-lib.sh anchors at the start of the
# line, so a raw `[HOTFIX] ` prefix makes triage_shard_key return 1, which makes
# shard_collect abandon the whole split and silently run the single session on
# every tick that has a hotfix. bin/lib/rt/shards.sh strips the marker at its
# one funnel and already reads $TICK_SCOPE through it — this case is what says
# so out loud, because on a live box TRIAGE_SHARDS is ON and the TICK_SCOPE arm
# is the tick shape it takes most often. LAST case in the file: the shards it
# dispatches are detached and write into $T/calls on their own time.
reset "RUN board-changed" "$DIFF2" "" "9102" "ai-build,hotfix"
CALLDIR="$T/calls" PATH="$T/fakebin:$PATH" env TRIAGE_SHARDS=1 \
  bash "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1
grep -q 'could not place' "$H/logs/$P.log" \
  && bad "2i: the marker must not make the dispatcher abandon the split ($(grep 'could not place' "$H/logs/$P.log"))" || ok
grep -q 'dispatched [1-9][0-9]* shards:' "$H/logs/$P.log" && ok \
  || bad "2i2: a marked TICK SCOPE must still dispatch shards (log: $(tail -2 "$H/logs/$P.log"))"

echo "triage-hotfix-label.bh-1349: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
