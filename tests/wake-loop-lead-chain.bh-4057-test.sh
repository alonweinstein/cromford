#!/bin/bash
# tests/wake-loop-lead-chain.bh-4057-test.sh — the lead-chain arms of
# bin/wake-loop.sh (BH-4092, BH-4057.0). A `lead-review` wake row launches
# bin/lead-review.sh tick on the box that owns the repo; a `lead-land` row is
# claimed for EVERY repo by the hub alone and launches bin/lead-review-land.sh
# there. flags/lead-chain-wake-off stops both, and the cron lanes cover it.
#
# Drives the REAL bin/wake-loop.sh and the REAL jobs client on the
# tests/lib/wake-claim-stub.sh worker, the fixture of
# tests/wake-loop-claims.bh-2637-test.sh. bin/lead-review.sh and
# bin/lead-review-land.sh are recorders that also write their open fds, so WL1
# can prove a launched review never holds the loop's own lock.
#
# The stubbed fleet: project-3 -> box-project-3-1, cromford ->
# box-small, project-1 -> local (the hub). The hub is box-hub.
#
# M1-M3 at the end are the D1 self-check: each mutates a copy of the loop and
# asserts the case that pins that behaviour goes RED.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-loop-lead-chain.bh-4057-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
export HARNESS="$H" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
LOOP_SRC="$DIR/bin/wake-loop.sh"
LANES="merge-conductor deploy-train postmerge-qa run-triage review-prs rebase-train"

fresh() {
  scratch_rm "$H"
  mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$H/locks" "$H/state/wcs" "$H/flags" "$H/calls"
  printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
  # The loop and the jobs client with the bin/lib files each sources (BH-4552).
  scratch_install_closure bin/wake-loop.sh "$H" >/dev/null \
    || { echo "FAIL: scratch_install_closure bin/wake-loop.sh"; exit 1; }
  scratch_install_closure bin/jobs-client.sh "$H" >/dev/null \
    || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
  # The loop under test: the real one, or an M* mutant laid over it.
  cp "$LOOP_SRC" "$H/bin/wake-loop.sh"
  wcs_install "$H/bin"
  wcs_identity "$H/bin" || { echo "wcs_identity failed"; exit 1; }
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\ncromford\nproject-1\n'; exit 0; }
case "$1/$2" in
  project-3/repo)       echo example-org/project-3 ;;
  cromford/repo) echo example-org/cromford ;;
  project-1/repo)   echo example-org/project-1 ;;
  project-3/box)        echo box-project-3-1 ;;
  cromford/box)  echo box-small ;;
  project-1/box)    echo local ;;
  */board_prefix)     echo /api/board ;;
  *) exit 1 ;;
esac
SH
  for s in $LANES; do
    printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$H/bin/$s.sh"
  done
  # The two lead lanes: argv to calls/<lane>, every open fd to calls/<lane>.fds.
  for s in lead-review lead-review-land; do
    cat > "$H/bin/$s.sh" <<SH
#!/bin/bash
echo "\$*" >> "\$HARNESS/calls/$s"
for f in /proc/\$\$/fd/*; do printf '%s -> %s\n' "\${f##*/}" "\$(readlink "\$f")"; done >> "\$HARNESS/calls/$s.fds"
sleep 1
SH
  done
  printf '#!/bin/bash\nexit 1\n' > "$H/bin/unblocked-children.sh"
  printf '#!/bin/bash\necho "[]"\n' > "$H/bin/gh"
  printf '#!/bin/bash\nexec "$@"\n' > "$H/bin/setsid"
  chmod +x "$H/bin/"*.sh "$H/bin/gh" "$H/bin/setsid"
  for c in push pr-ci deploy pr-closed flaky split-chain; do touch "$H/flags/wake-lanes-$c"; done
  : > "$T/wakes.json"
}
export WCS_WAKES="$T/wakes.json"
export PATH="$H/bin:$PATH"

wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
W() { # W <id> <repo> <kind> <key> [event]
  printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-10-03T03:00:00Z"}' \
    "$1" "$2" "$3" "$4" "${5:-lane:$3}"
}
settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    sleep 0.25
    cur=$(cat "$H/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 3 ] && return 0
    prev="$cur"
  done
}
run_as() { BOX_NAME="$1" "$H/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
calls() { if [ -f "$H/calls/$1" ]; then wc -l < "$H/calls/$1" | tr -d " "; else echo 0; fi; }
LOG() { cat "$H/logs/wake-loop.log" 2>/dev/null; }
REQ() { wcs_log; }
claim_body() { REQ | awk '$1=="POST" && $2=="/api/wakes/claim" { $1=""; $2=""; sub(/^  /, ""); print; exit }'; }
none_of() { local s; for s in "$@"; do [ "$(calls "$s")" = 0 ] || { echo "$s recorded: $(cat "$H/calls/$s")"; return 1; }; done; }

project-3=example-org/project-3 BH=example-org/cromford MOM=example-org/project-1

case_WL1() { # a box: two lead-review rows of its own repo -> ONE lead-review.sh tick, no cooldown, no fd 9
  fresh; wakes "$(W 1 $project-3 lead-review 41)" "$(W 2 $project-3 lead-review 42)"
  run_as box-project-3-1
  [ "$(calls lead-review)" = 1 ] || { echo "WL1 lead-review launched $(calls lead-review) time(s): $(LOG)"; return 1; }
  [ "$(cat "$H/calls/lead-review")" = tick ] || { echo "WL1 argv: $(cat "$H/calls/lead-review")"; return 1; }
  ! grep -q '/api/wakes/cooldown/take' <<<"$(REQ)" || { echo "WL1 took a cooldown: $(REQ | grep cooldown)"; return 1; }
  [ -s "$H/calls/lead-review.fds" ] || { echo "WL1 no fd record"; return 1; }
  ! grep -q 'wake-loop.lock' "$H/calls/lead-review.fds" || { echo "WL1 the launched review holds the loop lock: $(cat "$H/calls/lead-review.fds")"; return 1; }
  none_of lead-review-land $LANES || return 1
  REQ | grep -q '^POST /api/wakes/ack' || { echo "WL1 rows not acked: $(REQ)"; return 1; }
}
case_WL2() { # the hub claims every repo's lead-land and launches lead-review-land.sh once
  local b
  fresh; wakes "$(W 5 $project-3 lead-land 44)" "$(W 6 $project-3 lead-land 45)"
  run_as box-hub; b=$(claim_body)
  [ "$(jq -c .kinds_all_repos <<<"$b")" = '["pr","checks","lead-land"]' ] || { echo "WL2 hub claim body: $b"; return 1; }
  [ "$(calls lead-review-land)" = 1 ] || { echo "WL2 lead-review-land launched $(calls lead-review-land) time(s): $(LOG)"; return 1; }
  ! grep -q 'another box owns the repo' <<<"$(LOG)" || { echo "WL2 dropped as foreign: $(LOG)"; return 1; }
  ! grep -q 'wake-loop.lock' "$H/calls/lead-review-land.fds" || { echo "WL2 land holds the loop lock"; return 1; }
  none_of lead-review || return 1
}
case_WL3() { # a box handed a lead-land row of its own repo: silent, nothing launched
  fresh; echo 1 > "$H/state/wcs/CLAIM_ALL"; wakes "$(W 1 $project-3 lead-land 41)"
  run_as box-project-3-1
  none_of lead-review lead-review-land || return 1
  ! grep -q 'unknown kind' <<<"$(LOG)" || { echo "WL3 unknown kind line: $(LOG)"; return 1; }
}
case_WL4() { # the hub handed lead-review rows of a repo it owns: one line, no launch
  fresh; wakes "$(W 1 $MOM lead-review 7)" "$(W 2 $MOM lead-review 8)"
  run_as box-hub
  none_of lead-review lead-review-land || return 1
  [ "$(LOG | grep -c 'the hub runs no lead review')" = 1 ] || { echo "WL4 log: $(LOG)"; return 1; }
  REQ | grep -q '^POST /api/wakes/ack' || { echo "WL4 rows not acked: $(REQ)"; return 1; }
}
case_WL5() { # the kill switch: nothing launched, one line, rows still acked and cursor moved
  fresh; touch "$H/flags/lead-chain-wake-off"; wakes "$(W 3 $project-3 lead-review 41)"
  run_as box-project-3-1
  none_of lead-review || return 1
  [ "$(LOG | grep -c 'lead-chain doorbell off')" = 1 ] || { echo "WL5 box log: $(LOG)"; return 1; }
  REQ | grep -q '^POST /api/wakes/ack' && REQ | grep -q '^PUT /api/wakes/cursor {"box":"box-project-3-1","cursor":3}' \
    || { echo "WL5 box ack/cursor: $(REQ)"; return 1; }
  fresh; touch "$H/flags/lead-chain-wake-off"; wakes "$(W 4 $project-3 lead-land 41)"
  run_as box-hub
  none_of lead-review-land || return 1
  [ "$(LOG | grep -c 'lead-chain doorbell off')" = 1 ] || { echo "WL5 hub log: $(LOG)"; return 1; }
  REQ | grep -q '^POST /api/wakes/ack' || { echo "WL5 hub rows not acked: $(REQ)"; return 1; }
  # ...and the switch says nothing on a drain with no lead row in it.
  fresh; touch "$H/flags/lead-chain-wake-off"; wakes "$(W 5 $project-3 push s1)"
  run_as box-project-3-1
  ! grep -q 'lead-chain doorbell off' <<<"$(LOG)" || { echo "WL5 the off line on a drain with no lead row: $(LOG)"; return 1; }
}
case_WL6() { # a box never asks for lead-land, and a mis-filtered one is foreign
  local b
  fresh; echo 1 > "$H/state/wcs/CLAIM_ALL"; wakes "$(W 1 $BH lead-land 3)"
  run_as box-project-3-1; b=$(claim_body)
  [ "$(jq -c .kinds_all_repos <<<"$b")" = '[]' ] || { echo "WL6 box claim body: $b"; return 1; }
  none_of lead-review lead-review-land || return 1
  LOG | grep -q "dropped 1 wake(s): another box owns the repo — $BH" || { echo "WL6 log: $(LOG)"; return 1; }
}

check() { local out; if out=$("$1" 2>&1); then ok; else bad "$1 — $out"; fi; }
for c in WL1 WL2 WL3 WL4 WL5 WL6; do check "case_$c"; done

# ── D1: mutate the loop, and the case that pins the behaviour must go red ───
MUT="$T/mutant.sh"
mutant() { # mutant <name> <case> <sed-expr>
  sed -e "$3" "$DIR/bin/wake-loop.sh" > "$MUT"
  if cmp -s "$MUT" "$DIR/bin/wake-loop.sh"; then bad "$1: the sed did not change the loop (the mutation point moved)"; return; fi
  LOOP_SRC="$MUT"
  if "$2" >/dev/null 2>&1; then bad "$1: $2 stayed GREEN on the mutant"; else ok; fi
  LOOP_SRC="$DIR/bin/wake-loop.sh"
}
# M1: the hub stops claiming lead-land for every repo.
mutant M1 case_WL2 's/ALL_KINDS="pr,checks,lead-land"/ALL_KINDS="pr,checks"/'
# M2: the launch keeps the loop's fd 9.
mutant M2 case_WL1 '/launch "lead-review"/s/exec 9>&-; //'
# M3: the foreign guard lets any box's lead-land through.
mutant M3 case_WL6 's/1:pr|1:checks|1:lead-land)/1:pr|1:checks|*:lead-land)/'

echo "wake-loop-lead-chain (BH-4057): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
