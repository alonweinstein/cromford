#!/bin/bash
# tests/wake-loop-new-kinds.bh-4058-test.sh — the two wake kinds BH-4058 adds to
# the receiver (deploy_failed, merge_group) are recorded and ACKED by
# bin/wake-loop.sh, launch nothing, and never write an "unknown kind" line.
#
# Drives the REAL bin/wake-loop.sh over tests/lib/wake-claim-stub.sh, set up the
# way tests/wake-loop-claims.bh-2637-test.sh does it; every lane is a recorder.
#   K1  deploy_failed + merge_group rows: no lane fires, no unknown-kind line,
#       both ids acked
#   K2  control: a deploy row for the same repo still launches postmerge-qa
#   K3  an issue row with event=issues.labeled launches triage like issues.opened
#   K4  D1: a copy of the loop with the quiet arm deleted turns K1 red
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-loop-new-kinds.bh-4058-test.sh
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
LANES="merge-conductor deploy-train postmerge-qa run-triage review-prs rebase-train migration-autopilot
  apply-migrations flaky-detect prompt-eval fleet-propagate review-autopilot reconcile-prs
  check-migration-prs alerts-groom tickets-snapshot-push alerts-resolve-closed-prs"

fresh() {
  scratch_rm "$H"
  mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$H/locks" "$H/state/wcs" "$H/flags" "$H/calls"
  printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
  cp "$LOOP_SRC" "$H/bin/wake-loop.sh"
  cp "$DIR/bin/jobs-client.sh" "$H/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  cp "$DIR/bin/lib/wake-lanes.sh" "$DIR"/bin/lib/wake-class-*.sh "$H/bin/lib/"
  wcs_install "$H/bin"
  wcs_identity "$H/bin" || { echo "wcs_identity failed"; exit 1; }
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\n'; exit 0; }
case "$1/$2" in
  project-3/repo)   echo example-org/project-3 ;;
  project-3/box)    echo box-project-3-1 ;;
  */board_prefix) echo /api/board ;;
  *) exit 1 ;;
esac
SH
  for s in $LANES; do
    printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$H/bin/$s.sh"
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
    "$1" "$2" "$3" "$4" "${5:-ev}"
}
settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.25
    cur=$(cat "$H/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
}
run_as() { BOX_NAME="$1" "$H/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
calls() { if [ -f "$H/calls/$1" ]; then wc -l < "$H/calls/$1" | tr -d " "; else echo 0; fi; }
LOG() { cat "$H/logs/wake-loop.log" 2>/dev/null; }
REQ() { wcs_log; }
none_of() { local s; for s in "$@"; do [ "$(calls "$s")" = 0 ] || { echo "$s recorded: $(cat "$H/calls/$s")"; return 1; }; done; }
# acked <id> — the id is in an ack request body.
acked() { local a; a=$(REQ | awk '$1=="POST" && $2=="/api/wakes/ack"'); jq -e --argjson i "$1" 'any(.ids[]?; . == $i)' <<<"${a#POST /api/wakes/ack }" >/dev/null 2>&1; }

SHA=$(printf 'd%.0s' $(seq 40))
project-3=example-org/project-3

case_K1() { # the two new kinds: recorded, acked, quiet
  local log
  fresh; wakes "$(W 21 $project-3 deploy_failed "$SHA" deployment_status.created)" \
               "$(W 22 $project-3 merge_group "$SHA" merge_group.checks_requested)"
  run_as box-project-3-1
  none_of $LANES || return 1
  log=$(LOG)
  ! grep -q 'unknown kind' <<<"$log" || { echo "K1 unknown-kind line: $log"; return 1; }
  acked 21 && acked 22 || { echo "K1 not acked: $(REQ | grep ack)"; return 1; }
}
case_K2() { # control: the recorders are wired, so K1 is not vacuous
  fresh; wakes "$(W 31 $project-3 deploy "$SHA" deployment_status.created)"
  run_as box-project-3-1
  [ "$(calls postmerge-qa)" -ge 1 ] || { echo "K2 postmerge-qa=$(calls postmerge-qa): $(LOG)"; return 1; }
}
case_K3() { # issues.labeled reaches triage exactly as issues.opened does
  local a b
  fresh; wakes "$(W 41 $project-3 issue 12 issues.opened)"
  run_as box-project-3-1; a=$(cat "$H/calls/run-triage" 2>/dev/null)
  fresh; wakes "$(W 41 $project-3 issue 12 issues.labeled)"
  run_as box-project-3-1; b=$(cat "$H/calls/run-triage" 2>/dev/null)
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "K3 opened='$a' labeled='$b': $(LOG)"; return 1; }
}

check() { local out; if out=$("$1" 2>&1); then ok; else bad "$1 — $out"; fi; }
for c in K1 K2 K3; do check "case_$c"; done

# K4 — D1: delete the quiet arm, and K1 must go red on the unknown-kind line.
MUT="$T/mutant.sh"
sed -e '/^ *deploy_failed|merge_group) ;;/d' "$DIR/bin/wake-loop.sh" > "$MUT"
if cmp -s "$MUT" "$DIR/bin/wake-loop.sh"; then
  bad "K4: the sed did not change the loop (no quiet arm to delete)"
else
  LOOP_SRC="$MUT"
  if out=$(case_K1 2>&1); then bad "K4: case_K1 stayed GREEN with the quiet arm deleted"
  elif grep -q 'unknown kind' <<<"$out"; then ok
  else bad "K4: K1 went red for another reason: $out"; fi
  LOOP_SRC="$DIR/bin/wake-loop.sh"
fi

echo "wake-loop-new-kinds (BH-4058): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
