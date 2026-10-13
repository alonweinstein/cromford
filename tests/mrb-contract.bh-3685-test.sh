#!/bin/bash
# tests/mrb-contract.bh-3685-test.sh — the main-red-bisect contract (BH-3693,
# split child 1 of 5 of BH-3685). Pins the seven function names, their inert
# stub answers and the documented episode-file keys that every BH-3685 sibling
# imports from bin/lib/mrb-probe.sh, bin/lib/mrb-detect.sh and bin/lib/mrb-act.sh.
# The name is the one the ticket gives (bh-3685, the parent), not bh-3693.
#
# No network, no clock. When a sibling replaces a stub body, it updates the
# stub-behavior case here in the same diff; the signatures never change.
#
# Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/mrb-contract.bh-3685-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/../bin/lib/mrb-probe.sh" || exit 1
. "$(dirname "$0")/../bin/lib/mrb-detect.sh" || exit 1
. "$(dirname "$0")/../bin/lib/mrb-act.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PROBE="$DIR/bin/lib/mrb-probe.sh"
DETECT="$DIR/bin/lib/mrb-detect.sh"
ACT="$DIR/bin/lib/mrb-act.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: expected [$3] got [$2]"; }

# 1. all seven functions are defined after sourcing the three libs
for f in mrb_suites_from_log mrb_probe mrb_bisect mrb_detect_episodes \
         mrb_episode_still_red mrb_act_culprit mrb_act_notmerge; do
  declare -F "$f" >/dev/null && ok || bad "1: $f not defined"
done

# 2. sourcing prints nothing, in a fresh shell under the caller's options
out=$(bash -c '. "$1" && . "$2" && . "$3"' _ "$PROBE" "$DETECT" "$ACT" 2>&1); rc=$?
eq "2 source rc" "$rc" 0
eq "2 source output" "$out" ""

# 3. mrb_suites_from_log reads a realistic log and prints only the red suite, rc 0 (BH-3694)
out=$(printf -- '--- tests/a.sh rc=1\nboom\n--- tests/b.sh rc=0\n' | mrb_suites_from_log); rc=$?
eq "3 rc" "$rc" 0
eq "3 output" "$out" "tests/a.sh"
# a large writer under pipefail must not take SIGPIPE (the body reads all of stdin)
( set -o pipefail; awk 'BEGIN{for(i=0;i<200000;i++)print "--- tests/a.sh rc=1"}' | mrb_suites_from_log >/dev/null ); rc=$?
eq "3 pipefail large log rc" "$rc" 0

# 4. mrb_probe prints exactly norun, rc 0 ($T is not a git repo, so nothing can run)
out=$(mrb_probe "$T" deadbeef /dev/null); rc=$?
eq "4 rc" "$rc" 0
eq "4 output" "$out" "norun"

# 5. mrb_bisect prints exactly one line, rc 0: `true` answers nothing at the
#    first midpoint, so the search aborts there after one probe (BH-3694)
out=$(mrb_bisect true 8 s1 s2); rc=$?
eq "5 rc" "$rc" 0
eq "5 output" "$out" "aborted s1 1"
eq "5 one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1

# 6. mrb_detect_episodes (BH-3695 body): a tick it cannot run is rc 75, never
#    rc 0 with nothing written, and it prints nothing on stdout either way.
#    The full behaviour is tests/mrb-detect.bh-3685-test.sh.
mkdir -p "$T/out"
out=$(mrb_detect_episodes o/r "$T" "$T/out" 2>/dev/null); rc=$?
eq "6 rc (no HARNESS root)" "$rc" 75
eq "6 output" "$out" ""
eq "6 out-dir empty" "$(find "$T/out" -mindepth 1 | wc -l | tr -d ' ')" 0
out=$(HARNESS="$T/h" mrb_detect_episodes o/r "$T/not-a-repo" "$T/out" 2>/dev/null); rc=$?
eq "6 rc (repo-dir not a checkout)" "$rc" 75
eq "6 out-dir still empty" "$(find "$T/out" -mindepth 1 | wc -l | tr -d ' ')" 0

# 7. mrb_episode_still_red (BH-3695 body): 0 while the flag still names the
#    episode's run, 1 once the flag is cleared; nothing on stdout.
printf 'source=flag\nslug=o/r\n' > "$T/ep"
mkdir -p "$T/h/flags"
printf 'sha=abc\nrun=https://github.com/o/r/actions/runs/7\nreason=streak\n' > "$T/h/flags/main-red-o-r"
printf 'source=flag\nslug=o/r\nred=abc\nrun=7\n' > "$T/ep7"
out=$(HARNESS="$T/h" mrb_episode_still_red "$T/ep7"); rc=$?
eq "7 rc (flag names the run)" "$rc" 0
eq "7 output" "$out" ""
rm -f "$T/h/flags/main-red-o-r"
out=$(HARNESS="$T/h" mrb_episode_still_red "$T/ep7"); rc=$?
eq "7 rc (flag cleared)" "$rc" 1
eq "7 output (cleared)" "$out" ""

# 8. both act functions (BH-3697 filled them in) refuse an episode with no
#    culprit and no harness root: non-zero, empty stdout, the episode file left alone
for f in mrb_act_culprit mrb_act_notmerge; do
  out=$(unset HARNESS H; "$f" "$T/ep"); rc=$?
  [ "$rc" -ne 0 ] && ok || bad "8 $f rc: expected non-zero, got 0"
  eq "8 $f output" "$out" ""
done
eq "8 episode file untouched" "$(cat "$T/ep")" "$(printf 'source=flag\nslug=o/r')"

# 9. no forge client, no push, no alert writer in the libs. mrb-detect.sh is
#    the one lib whose job IS forge reads (BH-3695: `gh api` for log and zip
#    bytes, armed via gh-app-auth.sh), so it is held to no curl, no push and
#    no ALERTS.log only.
hits=$(grep -nE '(^|[^[:alnum:]_-])(gh|curl)([^[:alnum:]_-]|$)|git[[:space:]]+push|ALERTS\.log' \
  "$PROBE" "$ACT")
eq "9 forbidden tokens" "$hits" ""
hits=$(grep -nE '(^|[^[:alnum:]_-])curl([^[:alnum:]_-]|$)|git[[:space:]]+push|ALERTS\.log' "$DETECT")
eq "9 detect forbidden tokens" "$hits" ""

# 10. every episode key is documented in a comment line of mrb-detect.sh
for k in source slug red green run wf job suites outcome culprit pr pr_title pr_branch steps bisect; do
  grep -Eq "^#.*(^|[^[:alnum:]_])${k}=" "$DETECT" && ok || bad "10: episode key '$k=' not documented in mrb-detect.sh"
done

echo "mrb-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
