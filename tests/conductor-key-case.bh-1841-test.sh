#!/bin/bash
# tests/conductor-key-case.bh-1841-test.sh — the keyed conductor launch folds
# case on both sides (BH-1841, item 3 of BH-1831).
#
# GitHub slugs are case-insensitive, and a webhook can spell a repo differently
# from fleet.conf. bin/wake-loop.sh builds MC_ONLY_PR from the webhook's repo
# name, and bin/merge-conductor.sh matched it case-sensitively against
# fleet.conf's spelling, so a key that differed only in case skipped the project
# and the PR: a keyed launch that did nothing but still spent the cap and the
# cooldown.
#
# WAKE HALF (case A): the real bin/wake-loop.sh emits one lowercased key per PR,
# however the wake rows spell the repo. It runs as the hub (BOX_NAME=
# box-hub, BH-2637): only the hub claims pr/checks rows and runs the
# conductor. The worker is tests/lib/wake-claim-stub.sh.
# CONDUCTOR HALF (cases B-F): the real bin/merge-conductor.sh over fleet.conf's
# example-org/a (#7, #8) and example-org/b (#3). Any key spelling ticks its PR under
# fleet.conf's spelling (no duplicate lowercase row), exact case is #1387 case 6
# byte for byte, folding never becomes prefix matching, and two spellings of one
# key are one key.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/conductor-key-case.bh-1841-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin" "$T/h/bin/lib" "$T/h/bin/lib/jobs" "$T/h/bin/lib/mc" \
         "$T/h/env" "$T/h/logs" "$T/h/locks" "$T/h/state" "$T/h/calls" \
         "$T/fakebin"
printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$T/h/env/global.env"

# --- harness scripts under test and their dependencies -----------------------
cp "$DIR/bin/wake-loop.sh"         "$T/h/bin/wake-loop.sh"
cp "$DIR/bin/merge-conductor.sh"   "$T/h/bin/merge-conductor.sh"
cp "$DIR/bin/jobs-client.sh"       "$T/h/bin/jobs-client.sh"
cp "$DIR/bin/lib/env-path.sh"      "$T/h/bin/lib/env-path.sh"
cp "$DIR"/bin/lib/jobs/*.sh        "$T/h/bin/lib/jobs/"
cp "$DIR/bin/lib/revdep-lib.sh"    "$T/h/bin/lib/revdep-lib.sh"
cp "$DIR/bin/lib/gh-budget.sh"     "$T/h/bin/lib/gh-budget.sh"
cp "$DIR/bin/lib/heartbeat.sh"     "$T/h/bin/lib/heartbeat.sh"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/merge-conductor-lib.sh"
cp "$DIR/bin/lib/gh-rest.sh"       "$T/h/bin/lib/gh-rest.sh"
cp "$DIR/bin/lib/gh-pr-list.sh"    "$T/h/bin/lib/gh-pr-list.sh"
cp "$DIR/bin/lib/main-red-gate.sh" "$T/h/bin/lib/main-red-gate.sh"
cp "$DIR"/bin/lib/mc/*.sh          "$T/h/bin/lib/mc/"
cp "$DIR/bin/fleet-conf.sh"        "$T/h/bin/fleet-conf.sh"
cp "$DIR/bin/box-for.sh"           "$T/h/bin/box-for.sh"
chmod +x "$T/h/bin/wake-loop.sh" "$T/h/bin/merge-conductor.sh" "$T/h/bin/jobs-client.sh" \
         "$T/h/bin/fleet-conf.sh" "$T/h/bin/box-for.sh"

# Column 6 is the box column the real box-for.sh reads: `local` = the hub's.
printf 'a example-org/a https://a.example /api/board 2 local\nb example-org/b https://b.example /api/board 2 local\n' > "$T/h/fleet.conf"

# --- stubs the wake-loop half needs ----------------------------------------
cat > "$T/h/bin/setsid" <<'SH'
#!/bin/bash
exec "$@"
SH
cat > "$T/h/bin/flock" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$T/h/bin/setsid" "$T/h/bin/flock"

cat > "$T/h/bin/run-triage.sh" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$T/h/bin/deploy-train.sh" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$T/h/bin/postmerge-qa.sh" <<'SH'
#!/bin/bash
exit 0
SH
cat > "$T/h/bin/unblocked-children.sh" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$T/h/bin/run-triage.sh" "$T/h/bin/deploy-train.sh" "$T/h/bin/postmerge-qa.sh" "$T/h/bin/unblocked-children.sh"

# TEST-CHANGE BH-2637: the wake routes are the claim/cursor/cooldown worker
# (tests/lib/wake-claim-stub.sh), and the loop needs its box identity.
wcs_install "$T/h/bin"
wcs_identity "$T/h/bin" || { echo "wcs_identity failed"; exit 1; }
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE
cat > "$T/h/bin/curl" <<'SH'
#!/bin/bash
"$(dirname "$0")/wcs-routes" "$@" && exit 0
printf '{}\n200'
SH
chmod +x "$T/h/bin/curl"

# gh for the wake half. The loop asks GitHub's rate limit through
# bin/lib/gh-budget.sh; without a stub that is the REAL gh on the box — a real
# API call from a test, or, on a machine with no token, a zero-byte
# state/gh-budget cache that kills every later invocation that sources the lib
# (plan BH-1387 A6: the lib is out of scope, so the fixture answers instead).
cat > "$T/h/bin/gh" <<'SH'
#!/bin/bash
case "$*" in
  *"api rate_limit"*) printf '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}\n' ;;
  *) echo "" ;;
esac
exit 0
SH
chmod +x "$T/h/bin/gh"

wake_row() {
  printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-09-22T12:00:00Z"}' \
    "$1" "$2" "$3" "$4" "${5:-ev}"
}
wakes_fixture() {
  printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')"
}

mc_recorder() {
  cat > "$T/h/bin/merge-conductor.sh" <<'SH'
#!/bin/bash
printf '%s\tMC_ONLY_PR=%s\t%s\n' "$1" "${MC_ONLY_PR:-}" "$*" >> "${HARNESS:-/root/harness}/calls/merge-conductor"
SH
  chmod +x "$T/h/bin/merge-conductor.sh"
}

reset_wl() {
  # BH-2637: the cursor and cooldowns are worker rows (state/wcs), not files.
  rm -rf "$T/h/calls" "$T/h/state/wcs" "$T/h/logs/wake-loop.log" \
         "$T/h/wakes.json" "$T/h/ssh.log"
  mkdir -p "$T/h/calls" "$T/h/state/wcs"
  : > "$T/h/logs/wake-loop.log"
  mc_recorder
}

settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6; do
    sleep 0.25
    cur=$(cat "$T/h/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 2 ] && return 0
    prev="$cur"
  done
  return 0
}
waitfor() {
  local i
  for i in $(seq 1 40); do [ -s "$1" ] && return 0; sleep 0.25; done
  return 1
}

run_wl() {
  local json="$1"
  printf '%s\n' "$json" > "$T/h/wakes.json"
  export PATH="$T/h/bin:$PATH"
  HARNESS="$T/h" BOX_NAME=box-hub \
    WAKE_LOOP_CYCLES=1 \
    WAKE_LOOP_INTERVAL_S=0 \
    FLEET_CONF="$T/h/fleet.conf" WAKE_CONDUCTOR_KEYED="${WAKE_CONDUCTOR_KEYED:-1}" \
    bash "$T/h/bin/wake-loop.sh" >/dev/null 2>&1 || true
  settle
}

# The recorder's second field, from the FIRST recorded launch. Field 1 is the
# conductor's own argv[1] (empty: the lane takes no arguments), so the value
# under test is field 2 and reading it by position is what makes an empty
# MC_ONLY_PR distinguishable from a line that was never written.
mc_only_value() {
  awk -F'\t' '{sub(/^MC_ONLY_PR=/,"",$2); print $2; exit}' "$T/h/calls/merge-conductor" 2>/dev/null
}

# ---------------------------------------------------------------------------
# WAKE-LOOP HALF
# ---------------------------------------------------------------------------

# A. Two wake rows for one PR, spelled two ways -> one launch, one lowercased key.
reset_wl
FLEET_CONF="$T/h/fleet.conf" WAKE_CONDUCTOR_KEYED=1 run_wl "$(wakes_fixture \
  "$(wake_row 1 example-org/A pr 7)" \
  "$(wake_row 2 example-org/a checks 7)")"
waitfor "$T/h/calls/merge-conductor" || true
[ "$(wc -l < "$T/h/calls/merge-conductor" 2>/dev/null | tr -d ' ')" = 1 ] && ok \
  || bad "case A: expected exactly one conductor launch: $(cat "$T/h/calls/merge-conductor" 2>/dev/null)"
[ "$(mc_only_value)" = 'example-org/a#7' ] && ok || bad "case A: expected exactly 'example-org/a#7', got '$(mc_only_value)'"
grep -qF 'pr/checks[example-org/a#7]: launched merge-conductor.sh' "$T/h/logs/wake-loop.log" && ok \
  || bad "case A: the launch label must carry the lowercased key: $(cat "$T/h/logs/wake-loop.log")"
[ ! -s "$T/h/ssh.log" ] && ok || bad "case A: the hub's conductor launch must never ssh: $(cat "$T/h/ssh.log")"

# ---------------------------------------------------------------------------
# CONDUCTOR HALF: restore the real merge-conductor and add its own stubs.
# ---------------------------------------------------------------------------
cp "$DIR/bin/merge-conductor.sh" "$T/h/bin/merge-conductor.sh"
chmod +x "$T/h/bin/merge-conductor.sh"
# THE REAL flock FROM HERE ON. The wake half stubs it to exit 0 because nothing
# there is under a lock worth taking; the conductor ticks one project per
# background subshell and mc_row_put's critical section is what keeps three of
# them from losing each other's rows, so a no-op flock would make this half's
# assertions a coin toss.
rm -f "$T/h/bin/flock"

cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"
chmod +x "$T/fakebin/restpr"

# The main-red detector is a FULL-FLEET Actions sweep, not a flag read: it loops
# every repo in fleet.conf and asks repos/<slug>/actions/runs for each. A keyed
# tick must not buy that off one PR's doorbell, and an unkeyed tick still must
# run it. Every OTHER conductor fixture leaves the script out of its scratch
# bin/, so `[ -x ... ]` is false there and nothing ever pinned this; this one
# drops a recorder in on purpose.
cat > "$T/h/bin/main-red-detector.sh" <<'SH'
#!/bin/bash
printf 'ran\n' >> "${HARNESS:-/root/harness}/calls/main-red-detector"
SH
chmod +x "$T/h/bin/main-red-detector.sh"

H1=aaaaaaaa1111; H2=bbbbbbbb2222; H3=cccccccc3333

cat > "$T/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "" > "$4"; exit 0
SH
chmod +x "$T/h/bin/agent-call.sh"

cat > "$T/h/bin/batch-resolve.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${HARNESS:-/root/harness}/calls/batch-resolve"
SH
chmod +x "$T/h/bin/batch-resolve.sh"

# ls-remote answers a real-looking main sha, so a tick that reads it sees main
# MOVED from the recorded land sha (seed_land) and would fan out a land rebase.
cat > "$T/fakebin/git" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${GIT_CALLS:-/dev/null}"
case "$*" in
  *ls-remote*refs/heads/main*) printf '2222222222222222222222222222222222222222\trefs/heads/main\n' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/git"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\${GH_CALLS:-/dev/null}"
case "\$*" in
  *"pr list -R example-org/a --state open"*)
    cat <<'JR'
[
 {"number":7,"url":"https://github.com/example-org/a/pull/7","headRefOid":"$H1","headRefName":"ticket/TK-7","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"isInMergeQueue":false},
 {"number":8,"url":"https://github.com/example-org/a/pull/8","headRefOid":"$H2","headRefName":"ticket/TK-8","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"isInMergeQueue":false}
]
JR
    ;;
  *"pr list -R example-org/a --state closed"*|*"repos/example-org/a/pulls?state=closed"*) printf 'HTTP/2.0 200\\r\\n\\r\\n[]' ;;
  *"pr list -R example-org/b --state open"*)
    cat <<'JR'
[{"number":3,"url":"https://github.com/example-org/b/pull/3","headRefOid":"$H3","headRefName":"ticket/TK-3","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"isInMergeQueue":false}]
JR
    ;;
  *"pr list -R example-org/b --state closed"*|*"repos/example-org/b/pulls?state=closed"*) printf 'HTTP/2.0 200\\r\\n\\r\\n[]' ;;
  *"api -i -X GET repos/example-org/a/pulls/7"*) restpr OPEN "$H1" ticket/TK-7 main "" MERGEABLE CLEAN app/cromford "" ;;
  *"api -i -X GET repos/example-org/a/pulls/8"*) restpr OPEN "$H2" ticket/TK-8 main "" MERGEABLE CLEAN app/cromford "" ;;
  *"api -i -X GET repos/example-org/a/pulls/9"*) restpr CLOSED "$H2" ticket/TK-9 main ;;
  *"api -i -X GET repos/example-org/b/pulls/3"*) restpr OPEN "$H3" ticket/TK-3 main "" MERGEABLE CLEAN app/cromford "" ;;
  *"actions/runs?head_sha=$H1"*|*"actions/runs?head_sha=$H2"*|*"actions/runs?head_sha=$H3"*) printf 'completed|success\\n' ;;
  *"api rate_limit"*) printf '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}\\n' ;;
  *"pr view"*) echo '{"body":"harness build"}' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\\n+const a = 1;\\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# The open-PR list is REST since BH-1585 (a `pulls?state=open` page plus lazy
# per-PR reads). This stub still describes it as the GraphQL `pr list --state
# open`, so the bridge answers the REST reads from that description, as in every
# sibling conductor suite. Without it the conductor half sees no rows at all.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/conductor/held*)
    if [ -s "${HELD_JSON:-}" ]; then cat "$HELD_JSON"; printf '\n200\n'; else printf '{"error":"not found"}\n404\n'; fi ;;
  "POST "*/api/conductor/held/release) printf '{"released":1}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"

state_of() { awk -F'\t' -v k="$1" '$1==k {print $2; exit}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }

reset_mc() {
  rm -rf "$T/h/state/merge-conductor" "$T/h/logs/merge-conductor.log" \
         "$T/h/calls/batch-resolve" "$T/h/calls/main-red-detector" \
         "$T/gh-calls.txt" "$T/git-calls.txt" \
         "$T/req.txt" "$T/mc.err"
  mkdir -p "$T/h/state/merge-conductor" "$T/h/logs" "$T/h/calls"
  : > "$T/h/logs/merge-conductor.log"
  : > "$T/gh-calls.txt"
  : > "$T/git-calls.txt"
  : > "$T/req.txt"
}

run_mc() {
  (
    cd "$T" &&
    export PATH="$T/fakebin:$T/h/bin:$PATH" &&
    HARNESS="$T/h" HARNESS_SECRET=x REQ_SINK="$T/req.txt" \
      GH_CALLS="$T/gh-calls.txt" GIT_CALLS="$T/git-calls.txt" \
      FLEET_CONF="$T/h/fleet.conf" MC_REHYDRATE=0 LAND_FIRE=0 GH_TOKEN=fixture-token \
      "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/mc.err"
  ) || { echo "mc rc=$? stderr:"; cat "$T/mc.err"; }
}

LAND_OLD=1111111111111111111111111111111111111111
seed_land() { mkdir -p "$T/h/state/merge-conductor/land"; printf '%s\n' "$LAND_OLD" > "$T/h/state/merge-conductor/land/a"; }
nkeyed() { grep -c 'keyed tick' "$T/h/logs/merge-conductor.log" 2>/dev/null || true; }
mclog() { cat "$T/h/logs/merge-conductor.log" 2>/dev/null; }
pr_state() { cat "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }

# B. A key spelled differently from fleet.conf only in case ticks its PR, under
# fleet.conf's spelling, and nothing else.
reset_mc
run_mc env MC_ONLY_PR='example-org/A#7'
[ "$(grep -c 'keyed tick: 1 key(s)' "$T/h/logs/merge-conductor.log")" = 1 ] && ok || bad "case B: expected one 'keyed tick: 1 key(s)' line: $(mclog)"
[ -n "$(state_of 'example-org/a#7')" ] && ok || bad "case B: example-org/A#7 did not tick example-org/a#7: $(pr_state) $(mclog)"
[ -z "$(state_of 'example-org/a#7')" ] && ok || bad "case B: a lowercase duplicate identity row was written: $(pr_state)"
[ -z "$(state_of 'example-org/a#8')" ] && ok || bad "case B: keyed tick must not add example-org/a#8"
[ -z "$(state_of 'example-org/b#3')" ] && ok || bad "case B: keyed tick must not add example-org/b#3"
grep -q 'pr list -R example-org/a --state open' "$T/gh-calls.txt" && ok || bad "case B: gh must use fleet.conf's spelling (-R example-org/a): $(cat "$T/gh-calls.txt")"
grep -q 'example-org/b' "$T/gh-calls.txt" && bad "case B: keyed tick read repo b: $(grep 'example-org/b' "$T/gh-calls.txt")" || ok

# C. CONTROL: exact case is exactly #1387 case 6.
reset_mc
run_mc env MC_ONLY_PR='example-org/a#7'
[ "$(grep -c 'keyed tick: 1 key(s) — example-org/a#7' "$T/h/logs/merge-conductor.log")" = 1 ] && ok || bad "case C: expected exactly one 'keyed tick: 1 key(s) — example-org/a#7' line: $(mclog)"
[ -n "$(state_of 'example-org/a#7')" ] && [ -z "$(state_of 'example-org/a#8')" ] && [ -z "$(state_of 'example-org/b#3')" ] && ok \
  || bad "case C: must tick exactly example-org/a#7: $(pr_state)"
[ ! -e "$T/h/state/merge-conductor/tick-a.json" ] && ok || bad "case C: keyed tick wrote tick-a.json"

# D. NEGATIVE: folding is not prefix matching.
reset_mc
run_mc env MC_ONLY_PR='example-org/ab#7'
[ -z "$(state_of 'example-org/a#7')$(state_of 'example-org/a#8')$(state_of 'example-org/b#3')" ] && ok || bad "case D: example-org/ab#7 ticked a PR: $(pr_state)"
grep -q 'pr list -R example-org/a ' "$T/gh-calls.txt" && bad "case D: slug example-org/ab read repo a's list" || ok
reset_mc
run_mc env MC_ONLY_PR='example-org/A#70'
[ -z "$(state_of 'example-org/a#7')$(state_of 'example-org/a#8')" ] && ok || bad "case D: example-org/A#70 ticked a#7 or a#8: $(pr_state)"

# E. Two spellings of one key are one key.
reset_mc
run_mc env MC_ONLY_PR='example-org/a#7,example-org/A#7'
[ "$(grep -c 'keyed tick: 1 key(s)' "$T/h/logs/merge-conductor.log")" = 1 ] && ok || bad "case E: two spellings of a#7 must be one key: $(mclog)"
[ -n "$(state_of 'example-org/a#7')" ] && ok || bad "case E: a#7 not ticked: $(pr_state)"

# F. INVERSE CASE (D17): keys in upper and mixed case against a lowercase-folded probe.
reset_mc
run_mc env MC_ONLY_PR='example-org/A#7,example-org/B#3'
[ -n "$(state_of 'example-org/a#7')" ] && [ -n "$(state_of 'example-org/b#3')" ] && [ -z "$(state_of 'example-org/a#8')" ] && ok \
  || bad "case F: must tick exactly a#7 and b#3: $(pr_state) $(mclog)"

echo "conductor-key-case.bh-1841-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
