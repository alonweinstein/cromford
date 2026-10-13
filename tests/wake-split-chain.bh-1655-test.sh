#!/bin/bash
# tests/wake-split-chain.bh-1655-test.sh — BH-1655: a push to an in-app board
# project's repo has the OWNING box run its own triage tick now, through the
# real bin/wake-loop.sh and bin/lib/wake-class-split-chain.sh.
#
# Since BH-2637 every box runs the loop, claims its own repos' rows from the
# stub worker (tests/lib/wake-claim-stub.sh) and never ssh's, so the owning box
# launches the tick itself; the split-chain cooldown is the worker's row.
#
#   W1 armed, push for project-3, run as its box box-project-3-2 -> one local
#      run-triage.sh project-3 with WAKE_LAUNCH=1, no ssh; the hub, even handed
#      the row by a mis-filtering worker, runs nothing and ssh's nothing
#   W2 the owning box is `local` (the hub) -> a local run-triage.sh launch, no ssh
#   W3 two pushes in one drain + a second drain inside 120 s -> one launch
#   W4 no state/wake-* un-brake is written by the class
#   W5 GitHub-Issues project -> nothing; class flag unarmed -> nothing
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-split-chain.bh-1655-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "wake-split-chain: jq missing, cannot run" >&2; exit 1; }

export HARNESS="$T"
mkdir -p "$T/bin/lib" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/flags" "$T/calls"
mkdir -p "$T/harness-checkout/.git"
export HARNESS_CHECKOUT="$T/harness-checkout"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/env/global.env"
export WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
HUB=box-hub project-3=box-project-3-2

cp "$DIR/bin/wake-loop.sh" "$T/bin/wake-loop.sh"
cp "$DIR/bin/lib/wake-lanes.sh" "$T/bin/lib/wake-lanes.sh"
CLASS_SRC="$DIR/bin/lib/wake-class-split-chain.sh"
# Test-first: absent until the feature lands.
[ -f "$CLASS_SRC" ] && cp "$CLASS_SRC" "$T/bin/lib/wake-class-split-chain.sh"

# The REAL jobs-client: the wake routes go to the stub worker, and flag_active
# reads flags/<name> (the flag sync's `{}` answer leaves the files alone).
mkdir -p "$T/bin/lib/jobs"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
wcs_install "$T/bin"
wcs_identity "$T/bin" || { echo "wcs_identity failed"; exit 1; }

# project-3: in-app board on box-project-3-2. project-1: in-app board, box
# `local` (the hub's). ts-os: a GitHub-Issues board (board_prefix -) on
# box-ts.
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\nproject-1\nts-os\n'; exit 0; }
case "$1/$2" in
  project-3/repo)             echo example-org/project-3 ;;
  project-3/box)              echo box-project-3-2 ;;
  project-3/board_prefix)     echo /api/feature-board ;;
  project-1/repo)         echo example-org/project-1 ;;
  project-1/box)          echo local ;;
  project-1/board_prefix) echo /api/board ;;
  ts-os/repo)               echo example-org/ts-os ;;
  ts-os/box)                echo box-ts ;;
  ts-os/board_prefix)       echo - ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/unblocked-children.sh"; chmod +x "$T/bin/unblocked-children.sh"
for s in merge-conductor deploy-train postmerge-qa run-triage; do
  printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$T/bin/$s.sh"; chmod +x "$T/bin/$s.sh"
done
# run-triage also records the WAKE_LAUNCH the loop's launch() exports.
printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/run-triage"\necho "$* WAKE_LAUNCH=${WAKE_LAUNCH:-}" >> "$HARNESS/calls/run-triage-env"\n' > "$T/bin/run-triage.sh"
chmod +x "$T/bin/run-triage.sh"
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
"$(dirname "$0")/wcs-routes" "$@" && exit 0
printf '{}\n200'
SH
chmod +x "$T/bin/curl"
printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/ssh"\n' > "$T/bin/ssh"; chmod +x "$T/bin/ssh"
printf '#!/bin/bash\nexit 1\n' > "$T/bin/crontab"; chmod +x "$T/bin/crontab"
printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/gh"\necho "[]"\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"
printf '#!/bin/bash\nexec "$@"\n' > "$T/bin/setsid"; chmod +x "$T/bin/setsid"

W() { printf '{"id":%s,"repo":"%s","kind":"push","key":"%s","event":"push","at":"2026-09-23T13:18:00Z"}' "$1" "$2" "${3:-abc$1}"; }
wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
reset() {
  rm -rf "$T/calls" "$T/state" "$T/flags" "$T/logs"
  mkdir -p "$T/calls" "$T/state" "$T/flags" "$T/logs"
}
settle() {
  local prev="" cur i
  for i in $(seq 1 12); do
    sleep 0.25
    cur=$(cat "$T/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
  return 0
}
# run_as <box> — one loop invocation as that box (bin/box-name.sh reads BOX_NAME).
run_as() { BOX_NAME="$1" PATH="$T/bin:$PATH" "$T/bin/wake-loop.sh" >/dev/null 2>&1; settle; }
run() { run_as "$HUB"; }
calls() { [ -f "$T/calls/$1" ] && wc -l < "$T/calls/$1" | tr -d ' ' || echo 0; }
sshtriage() { grep -c 'run-triage.sh project-3' "$T/calls/ssh" 2>/dev/null || echo 0; }
# project-3_triage — run-triage.sh project-3 launches on THIS test's box.
project-3_triage() { grep -cx 'project-3' "$T/calls/run-triage" 2>/dev/null || echo 0; }

# --- W1 + W4: armed, one in-app push -> the owning box's own tick, no ssh -------
reset
touch "$T/flags/wake-lanes-split-chain"
wakes "$(W 1 example-org/project-3)"
run_as "$project-3"
# TEST-CHANGE BH-2637: was "one ssh running run-triage.sh project-3" from the hub;
# the owning box claims the push and launches the tick itself, and nobody ssh's.
[ "$(project-3_triage)" = 1 ] && [ "$(sshtriage)" = 0 ] && ok || bad "W1: want one local run-triage.sh project-3 on $project-3 and no ssh, got $(project-3_triage) local, $(sshtriage) ssh ($(cat "$T/calls/ssh" 2>/dev/null))"
# TEST-CHANGE BH-2637: was "the ssh carries WAKE_LAUNCH=1"; the owning box's own
# launch carries it.
grep -qx 'project-3 WAKE_LAUNCH=1' "$T/calls/run-triage-env" 2>/dev/null && ok || bad "W1: the launch must carry WAKE_LAUNCH=1 (got: $(cat "$T/calls/run-triage-env" 2>/dev/null))"
# TEST-CHANGE BH-2637: was "the ssh must not touch state/wake-project-3"; there is
# no ssh, and the owning box's launch must not write that un-brake either.
{ [ -f "$T/calls/ssh" ] || [ -e "$T/state/wake-project-3" ]; } && bad "W1: an ssh ran or the launch touched state/wake-project-3" || ok
ls "$T/state"/wake-project-3 "$T/state"/wake-keys-project-3 >/dev/null 2>&1 && bad "W4: the class wrote a state/wake-* un-brake" || ok
# TEST-CHANGE BH-2637: was asserted on the same (hub) run as the ssh; the hub is
# now a run of its own, handed the row by a mis-filtering worker (CLAIM_ALL=1)
# so the loop's own ownership guard is what keeps project-3's tick off it.
reset
touch "$T/flags/wake-lanes-split-chain"
wakes "$(W 1 example-org/project-3)"
CLAIM_ALL=1 run
[ "$(calls run-triage)" = 0 ] && [ "$(calls ssh)" = 0 ] && ok || bad "W1: a remote box's tick must not run on the hub (run-triage=$(calls run-triage), ssh=$(calls ssh))"

# --- W2: the owning box is this one -> local launch, no ssh -------------------
reset
touch "$T/flags/wake-lanes-split-chain"
wakes "$(W 2 example-org/project-1)"
run
[ "$(calls run-triage)" = 1 ] && grep -qx 'project-1' "$T/calls/run-triage" && ok \
  || bad "W2: want one local run-triage.sh project-1, got $(cat "$T/calls/run-triage" 2>/dev/null)"
[ "$(calls ssh)" = 0 ] && ok || bad "W2: a local owner must not ssh (got $(calls ssh))"

# --- W3: two pushes in one drain, then a second drain inside 120 s ------------
reset
touch "$T/flags/wake-lanes-split-chain"
wakes "$(W 3 example-org/project-3)" "$(W 4 example-org/project-3)"
run_as "$project-3"
wakes "$(W 5 example-org/project-3)"
run_as "$project-3"
# TEST-CHANGE BH-2637: the launches are the owning box's own, not ssh's; the
# 120 s window is the worker's split-chain[project-3] cooldown row.
[ "$(project-3_triage)" = 1 ] && [ "$(sshtriage)" = 0 ] && ok || bad "W3: three pushes inside the cooldown must make one launch, got $(project-3_triage) (ssh $(sshtriage))"
[ -s "$T/state/wcs/cool/split-chain-project-3" ] && ok || bad "W3: the cooldown must be the worker's split-chain[project-3] row"

# --- W5: a GitHub-Issues project, and the class unarmed -----------------------
reset
touch "$T/flags/wake-lanes-split-chain"
wakes "$(W 6 example-org/ts-os)"
# ts-os's own box claims its push (BH-2637: the hub never sees another box's push).
run_as box-ts
grep -q 'split-chain\[' "$T/logs/"*.log 2>/dev/null && bad "W5: a GitHub-Issues push must not reach the class launch" || ok
grep -q 'run-triage.sh ts-os' "$T/calls/ssh" 2>/dev/null && bad "W5: a GitHub-Issues push launched a triage tick" || ok
[ "$(calls run-triage)" = 0 ] && ok || bad "W5: a GitHub-Issues push launched a local triage tick ($(cat "$T/calls/run-triage" 2>/dev/null))"
reset
wakes "$(W 7 example-org/project-3)"
run_as "$project-3"
# TEST-CHANGE BH-2637: run as the owning box, which is where an armed class
# would now launch; nothing there and nothing over ssh.
[ "$(project-3_triage)" = 0 ] && [ "$(sshtriage)" = 0 ] && ok || bad "W5: an unarmed class must launch nothing, got $(project-3_triage) local, $(sshtriage) ssh"
[ "$(calls ssh)" = 0 ] && ok || bad "W5: an unarmed class leaves the push arm's ssh count at 0, got $(calls ssh)"

echo "wake-split-chain: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
