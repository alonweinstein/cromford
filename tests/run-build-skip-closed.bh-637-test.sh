#!/bin/bash
# tests/run-build-skip-closed.bh-637-test.sh — the closed-issue skip at the
# funnel (BH-637 §3a, updated for BH-1424 REST reads).
#
# WHAT THIS PINS AND WHY. bin/run-build.sh is the only mechanical enqueue point
# in the fleet: the triage session, bin/up10-lane.sh, bin/unblocked-children.sh,
# the READY-QUEUE tick, bin/blocked-resolver.sh's rebuilds and
# fly/builder-runner.sh all funnel through it. On 2026-09-17 three already-merged
# tickets were re-claimed through it minutes after their PRs landed, because
# nothing in that script ever read the issue's state — only the `ai-build` label,
# which no merge took off. So one block, above the enqueue gate, reads the state
# live and refuses.
#
# THE BLOCK IS EXTRACTED VERBATIM from bin/run-build.sh between its own markers
# and EXECUTED, never paraphrased: a copy of the logic in this file would pass
# just as happily against a run-build that lost the block, or one where the block
# sits BELOW the queue write.
#
# THE NEGATIVES CARRY THE WEIGHT. A refusal is terminal — so every case where the
# answer is not a confident CLOSED must build exactly as it does today: an open
# issue, a gh that returned a payload and still exited nonzero, a board project,
# a non-numeric key, a box whose sync has not landed the lib, and both kill
# switches.
#
# Run from anywhere: tests/run-build-skip-closed.bh-637-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RB="$RB_ALL"
[ -r "$RB" ] || { echo "FAIL: bin/run-build.sh is missing"; exit 1; }

# ════════════════════════════════════════════════════════════════════════════
# 1. THE BLOCK EXISTS, AND IT SITS ABOVE THE ENQUEUE GATE.
# ════════════════════════════════════════════════════════════════════════════
A=$(grep -n '^# >>> closed issue skip' "$RB" | head -1 | cut -d: -f1)
B=$(grep -n 'Fly builder trial (Phase 2): enqueue gate' "$RB" | head -1 | cut -d: -f1)
C=$(grep -n '^# <<< closed issue skip' "$RB" | head -1 | cut -d: -f1)
if [ -z "$A" ] || [ -z "$C" ]; then
  bad "bin/run-build.sh has no '# >>> closed issue skip' … '# <<< closed issue skip' block"
elif [ -z "$B" ]; then
  bad "the 'Fly builder trial (Phase 2): enqueue gate' landmark is gone from bin/run-build.sh — re-anchor this test"
else
  [ "$A" -lt "$C" ] && ok || bad "the closed-issue skip markers are out of order ($A then $C)"
  [ "$C" -lt "$B" ] && ok || bad "the closed-issue skip must close BEFORE the enqueue gate (skip ends $C, gate at $B)"
fi

awk '/^# >>> closed issue skip/{f=1;next} /^# <<< closed issue skip/{exit} f' "$RB" > "$T/skip.sh"
[ -s "$T/skip.sh" ] && ok || bad "the extracted closed-issue skip block is empty — there is nothing to drive"

# ════════════════════════════════════════════════════════════════════════════
# the harness fixture: a GitHub-Issues project and a board project, the lib,
# and a recording gh stub whose state answer and rc are knobs.
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/flags" "$T/bin"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
[ -r "$DIR/bin/lib/issue-state-lib.sh" ] && cp "$DIR/bin/lib/issue-state-lib.sh" "$T/h/bin/lib/"
[ -r "$DIR/bin/lib/gh-rest.sh" ] && cp "$DIR/bin/lib/gh-rest.sh" "$T/h/bin/lib/"
: > "$T/h/env/global.env"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
proj   example-org/proj   https://proj.example   -           9 box-1 10.0.0.9
bproj  example-org/bproj  https://bproj.example  /api/board  2 box-1 10.0.0.2
CONF
export FLEET_CONF="$T/h/fleet.conf"

export GH_ARGS="$T/gh-args.txt"
export ISSUE_JSON="$T/issue.json"

# `rb_all` has already flattened bin/run-build.sh into one text, but the block
# still sources ./lib/issue-state-lib.sh relative to the script's directory. We
# run the extracted block as if it lived in the repo root next to bin/.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_ARGS"
case "$*" in
  *"api -i -X GET"*"issues"*)
    case "${GH_RC:-0}" in
      0) printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$ISSUE_JSON" ;;
      2) printf 'HTTP/1.1 403 Forbidden\r\n\r\n{"message":"rate limit"}\n'; echo "gh: HTTP 403 rate limit" >&2; exit 1 ;;
      *) echo "gh: HTTP 401" >&2; exit "${GH_RC}" ;;
    esac ;;
esac
exit 0
SH
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
RESULT() { printf '%s\n' "$1" > "$T/build/RESULT"; }

# drive <KEY> <PROJECT> [GH_RC]
drive() {
  local key="$1" project="$2" rc
  # The third argument is the stub's bare numeric rc. A non-numeric one (the
  # old `GH_RC=2` env-assignment form) misses every stub branch and passes as
  # a plain failure, so refuse it loudly instead of letting it drive.
  case "${3:-0}" in
    ''|*[!0-9]*) bad "drive: GH_RC must be a bare number, got '$3'"; return 99 ;;
  esac
  export KEY="$key" PROJECT="$project" HARNESS="$T/h" BUILDER_EXEC="" BUILD="$T/build"
  export GH_RC="${3:-0}"
  rm -rf "$T/build"; mkdir -p "$T/build"
  rm -f "$T/h/logs/${project}.log"
  : > "$GH_ARGS"
  ( . "$T/skip.sh" ); rc=$?
  return $rc
}

# ════════════════════════════════════════════════════════════════════════════
# 2. A CLOSED ISSUE REFUSES, AND THE RIGHT THINGS ARE RECORDED.
# ════════════════════════════════════════════════════════════════════════════
printf '{"state":"closed","body":"b","labels":[]}' > "$ISSUE_JSON"
drive TK-2066 proj; RC=$?
[ "$RC" = 3 ] && ok || bad "a closed issue must exit 3 (rc=$RC)"
head -1 "$T/build/RESULT" 2>/dev/null | grep -q '^BUILD_REFUSED SKIP_CLOSED #2066' \
  && ok || bad "RESULT must start BUILD_REFUSED SKIP_CLOSED #2066 (got: $(cat "$T/build/RESULT" 2>/dev/null))"
grep -q 'SKIP_CLOSED #2066' "$T/build/pipeline.log" 2>/dev/null \
  && ok || bad "the build record's pipeline.log must carry SKIP_CLOSED #2066 (got: $(cat "$T/build/pipeline.log" 2>/dev/null))"
grep -q 'SKIP_CLOSED #2066' "$T/h/logs/proj.log" 2>/dev/null \
  && ok || bad "logs/proj.log must carry SKIP_CLOSED #2066 — the operator's sink (got: $(cat "$T/h/logs/proj.log" 2>/dev/null))"
[ "$(grep -c . "$GH_ARGS")" = 1 ] && ok || bad "exactly one gh call (the state read) per entry (got: $(cat "$GH_ARGS"))"
grep -q 'api -i -X GET repos/example-org/proj/issues/2066' "$GH_ARGS" \
  && ok || bad "the call must be the REST issue state read on the fleet.conf repo (got: $(cat "$GH_ARGS"))"

# 2b. THE STATE, NOT THE LABEL
grep -q -- 'api -i -X GET' "$GH_ARGS" && ok || bad "the check must read state via REST (got: $(cat "$GH_ARGS"))"
grep -q -- 'json state' "$GH_ARGS" && bad "the skip must not use GraphQL --json state (got: $(cat "$GH_ARGS"))" || ok

# ════════════════════════════════════════════════════════════════════════════
# 3. EVERY UNCERTAIN ANSWER BUILDS AS TODAY.
# ════════════════════════════════════════════════════════════════════════════
printf '{"state":"open","body":"b","labels":[]}' > "$ISSUE_JSON"
drive TK-2066 proj; RC=$?
[ "$RC" = 0 ] && ok || bad "an OPEN issue must fall through at rc 0 (rc=$RC)"
[ ! -f "$T/build/RESULT" ] && ok || bad "an OPEN issue must write no RESULT (got: $(cat "$T/build/RESULT"))"
[ ! -s "$T/h/logs/proj.log" ] && ok || bad "an OPEN issue must say nothing in the project log (got: $(cat "$T/h/logs/proj.log"))"

printf '{"state":"closed","body":"b","labels":[]}' > "$ISSUE_JSON"
drive TK-2066 proj 2; RC=$?
[ "$RC" = 0 ] && ok || bad "a gh that returned a payload and still failed must fall through at rc 0 (rc=$RC)"
[ ! -f "$T/build/RESULT" ] && ok || bad "an UNKNOWN answer must never be read as closed (got: $(cat "$T/build/RESULT"))"
grep -q 'closed-issue check unavailable' "$T/build/pipeline.log" 2>/dev/null \
  && ok || bad "an UNKNOWN answer must leave one pipeline.log line (got: $(cat "$T/build/pipeline.log" 2>/dev/null))"

# a board-prefix project has no GitHub issue to read
drive TK-77 bproj; RC=$?
[ "$RC" = 0 ] && ok || bad "a board project must fall through at rc 0 (rc=$RC)"
[ ! -s "$GH_ARGS" ] && ok || bad "a board project must make NO gh call (got: $(cat "$GH_ARGS"))"
[ ! -f "$T/build/RESULT" ] && ok || bad "a board project must write no RESULT"

# a key with no issue number in it
drive READY-QUEUE proj; RC=$?
[ "$RC" = 0 ] && ok || bad "a non-numeric key must fall through at rc 0 (rc=$RC)"
[ ! -s "$GH_ARGS" ] && ok || bad "a non-numeric key must make no gh call (got: $(cat "$GH_ARGS"))"

# ════════════════════════════════════════════════════════════════════════════
# 4. THE KILL SWITCHES, and a box whose sync has not landed the lib.
# ════════════════════════════════════════════════════════════════════════════
printf 'SKIP_CLOSED=0\n' > "$T/h/env/global.env"
drive TK-2066 proj; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/build/RESULT" ] && ok \
  || bad "SKIP_CLOSED=0 in env/global.env must build as before (rc=$RC result=$(cat "$T/build/RESULT" 2>/dev/null))"
: > "$T/h/env/global.env"
touch "$T/h/flags/skip-closed-off"
drive TK-2066 proj; RC=$?
[ "$RC" = 0 ] && [ ! -f "$T/build/RESULT" ] && ok \
  || bad "flags/skip-closed-off must build as before (rc=$RC result=$(cat "$T/build/RESULT" 2>/dev/null))"
rm -f "$T/h/flags/skip-closed-off"

mv "$T/h/bin/lib/issue-state-lib.sh" "$T/lib-away.sh" 2>/dev/null
mv "$T/h/bin/lib/gh-rest.sh" "$T/rest-away.sh" 2>/dev/null
drive TK-2066 proj; RC=$?
[ "$RC" = 0 ] && ok || bad "a box without the lib must behave exactly as today, rc 0 (rc=$RC)"
[ ! -f "$T/build/RESULT" ] && ok || bad "a box without the lib must write no RESULT"
[ ! -s "$GH_ARGS" ] && ok || bad "a box without the lib must make no gh call (got: $(cat "$GH_ARGS"))"
mv "$T/lib-away.sh" "$T/h/bin/lib/issue-state-lib.sh" 2>/dev/null
mv "$T/rest-away.sh" "$T/h/bin/lib/gh-rest.sh" 2>/dev/null

echo "run-build-skip-closed.bh-637: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
