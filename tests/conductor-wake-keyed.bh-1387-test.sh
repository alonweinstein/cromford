#!/bin/bash
# tests/conductor-wake-keyed.bh-1387-test.sh — keyed conductor launch from
# bin/wake-loop.sh and the keyed tick path in bin/merge-conductor.sh (BH-1387).
#
# WAKE HALF (cases 1-5e): the real bin/wake-loop.sh drains a wakes fixture and a
# recorder stands in for the conductor, writing `argv1 TAB MC_ONLY_PR=… TAB argv`.
# One launch carries every deduped pr/checks key; issue/push wakes, non-fleet
# repos and keys that are '-', empty or not a number carry none; a knob that is
# not 0 or 1 is 0 with one line; the knob unset is today's argv and label. The
# loop runs as the hub (BOX_NAME=box-hub, BH-2637): only the hub claims
# pr/checks rows and runs the conductor. The worker is
# tests/lib/wake-claim-stub.sh.
# CONDUCTOR HALF (cases 6-10): the real bin/merge-conductor.sh over repos a (#7,
# #8) and b (#3). A keyed tick reads only keyed repos, rows only keyed PRs, and
# runs no LAND fan-out, batch spawn, main-red detector, gc, held-page flush or
# tick-<p>.json write, and it hands the closed candidates it doesn't own back to
# the cron tick (case 9); an unkeyed or unparseable MC_ONLY_PR is today's full
# tick, which is also the positive control for every sweep the keyed tick skips.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/conductor-wake-keyed.bh-1387-test.sh
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

# 1. Two pr wakes across two repos -> one keyed launch carrying both keys.
reset_wl
FLEET_CONF="$T/h/fleet.conf" WAKE_CONDUCTOR_KEYED=1 run_wl "$(wakes_fixture \
  "$(wake_row 1 example-org/a pr 7)" \
  "$(wake_row 2 example-org/b pr 3)")"
waitfor "$T/h/calls/merge-conductor" || true
c1=$(wc -l < "$T/h/calls/merge-conductor" 2>/dev/null | tr -d ' ') || c1=0
if [ "$c1" -eq 1 ]; then ok; else bad "case 1: expected one conductor launch, got ${c1:-0}"; fi
v1=$(mc_only_value)
if [[ "$v1" == *a#7* ]]; then ok; else bad "case 1: missing a#7 in MC_ONLY_PR (got '$v1')"; fi
if [[ "$v1" == *b#3* ]]; then ok; else bad "case 1: missing b#3 in MC_ONLY_PR (got '$v1')"; fi
if [[ "$v1" == *a#7*a#7* || "$v1" == *b#3*b#3* ]]; then
  bad "case 1: duplicate key in MC_ONLY_PR (got '$v1')"
else
  ok
fi

# 2. Same PR twice is deduped to one key.
reset_wl
FLEET_CONF="$T/h/fleet.conf" WAKE_CONDUCTOR_KEYED=1 run_wl "$(wakes_fixture \
  "$(wake_row 1 example-org/a pr 7)" \
  "$(wake_row 2 example-org/a pr 7)")"
waitfor "$T/h/calls/merge-conductor" || true
c2=$(wc -l < "$T/h/calls/merge-conductor" 2>/dev/null | tr -d ' ') || c2=0
if [ "$c2" -eq 1 ]; then ok; else bad "case 2: expected one launch for duplicate wakes, got ${c2:-0}"; fi
v2=$(mc_only_value)
if [[ "$v2" == *a#7* ]]; then
  n2=$(grep -o 'a#7' <<<"$v2" | wc -l | tr -d ' ')
  if [ "$n2" -eq 1 ]; then ok; else bad "case 2: a#7 appeared $n2 times"; fi
else
  bad "case 2: missing a#7 in MC_ONLY_PR (got '$v2')"
fi

# 3. An issue wake contributes no conductor key and no conductor launch.
reset_wl
FLEET_CONF="$T/h/fleet.conf" WAKE_CONDUCTOR_KEYED=1 run_wl "$(wakes_fixture \
  "$(wake_row 1 example-org/a issue 99)")"
if [ ! -s "$T/h/calls/merge-conductor" ]; then
  ok
else
  bad "case 3: issue wake must not launch conductor (got $(cat "$T/h/calls/merge-conductor"))"
fi

# 4. A non-fleet repo contributes no key and no launch.
reset_wl
FLEET_CONF="$T/h/fleet.conf" WAKE_CONDUCTOR_KEYED=1 run_wl "$(wakes_fixture \
  "$(wake_row 1 example-org/unknown pr 5)")"
if [ ! -s "$T/h/calls/merge-conductor" ]; then
  ok
else
  bad "case 4: non-fleet repo must not launch conductor (got $(cat "$T/h/calls/merge-conductor"))"
fi

# 5. Invalid WAKE_CONDUCTOR_KEYED is clamped to 0 and logged once.
reset_wl
FLEET_CONF="$T/h/fleet.conf" WAKE_CONDUCTOR_KEYED=abc run_wl "$(wakes_fixture \
  "$(wake_row 1 example-org/a pr 7)")"
waitfor "$T/h/calls/merge-conductor" || true
c5=$(wc -l < "$T/h/calls/merge-conductor" 2>/dev/null | tr -d ' ') || c5=0
if [ "$c5" -eq 1 ]; then ok; else bad "case 5: expected one unkeyed launch with invalid knob, got ${c5:-0}"; fi
v5=$(mc_only_value)
if [ -z "$v5" ]; then
  ok
else
  bad "case 5: invalid knob must not pass MC_ONLY_PR (got '$v5')"
fi
nc5=$(grep -c "WAKE_CONDUCTOR_KEYED='abc' is not 0 or 1 — using 0" "$T/h/logs/wake-loop.log" 2>/dev/null) || nc5=0
if [ "$nc5" -eq 1 ]; then ok; else bad "case 5: expected one log mention of WAKE_CONDUCTOR_KEYED, got $nc5"; fi

# 5b. A number that is not 0 or 1 is not an opt-in either.
reset_wl
FLEET_CONF="$T/h/fleet.conf" WAKE_CONDUCTOR_KEYED=2 run_wl "$(wakes_fixture \
  "$(wake_row 1 example-org/a pr 7)")"
waitfor "$T/h/calls/merge-conductor" || true
[ -z "$(mc_only_value)" ] && ok || bad "case 5b: WAKE_CONDUCTOR_KEYED=2 must launch unkeyed (got '$(mc_only_value)')"
[ "$(grep -c "WAKE_CONDUCTOR_KEYED='2' is not 0 or 1" "$T/h/logs/wake-loop.log")" = 1 ] && ok \
  || bad "case 5b: expected one 'is not 0 or 1' line: $(cat "$T/h/logs/wake-loop.log")"

# 5c. KNOB UNSET = TODAY. One launch, an empty MC_ONLY_PR, today's argv and
# today's label, and no word about the knob.
reset_wl
( unset WAKE_CONDUCTOR_KEYED
  printf '%s\n' "$(wakes_fixture "$(wake_row 1 example-org/a pr 7)" "$(wake_row 2 example-org/b pr 3)")" > "$T/h/wakes.json"
  PATH="$T/h/bin:$PATH" HARNESS="$T/h" BOX_NAME=box-hub WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 \
    FLEET_CONF="$T/h/fleet.conf" bash "$T/h/bin/wake-loop.sh" >/dev/null 2>&1 || true )
settle
waitfor "$T/h/calls/merge-conductor" || true
[ "$(wc -l < "$T/h/calls/merge-conductor" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "case 5c: knob unset must launch exactly once: $(cat "$T/h/calls/merge-conductor" 2>/dev/null)"
[ "$(cat "$T/h/calls/merge-conductor" 2>/dev/null)" = "$(printf '\tMC_ONLY_PR=\t')" ] && ok \
  || bad "case 5c: knob unset must pass no argv and no MC_ONLY_PR: '$(cat "$T/h/calls/merge-conductor" 2>/dev/null)'"
grep -q 'pr/checks: launched merge-conductor.sh' "$T/h/logs/wake-loop.log" && ok || bad "case 5c: today's launch label is gone: $(cat "$T/h/logs/wake-loop.log")"
grep -q 'WAKE_CONDUCTOR_KEYED' "$T/h/logs/wake-loop.log" && bad "case 5c: the knob unset must say nothing about it" || ok

# 5d. ADVERSARIAL KEYS. A pr/checks wake whose key is '-', empty or not a
# number names no PR, and a push wake's key is a sha: none of them may become a
# key. The pr ones still want the conductor, so the launch is today's unkeyed one.
# TEST-CHANGE BH-5521: that unkeyed launch is the legacy path, pinned under
# WAKE_CONDUCTOR_FULL=1; the default launches nothing for a batch that names no
# PR (tests/conductor-events.bh-5521-test.sh E13).
reset_wl
FLEET_CONF="$T/h/fleet.conf" WAKE_CONDUCTOR_KEYED=1 WAKE_CONDUCTOR_FULL=1 run_wl "$(wakes_fixture \
  "$(wake_row 1 example-org/a pr -)" \
  "$(wake_row 2 example-org/a checks '')" \
  "$(wake_row 3 example-org/a pr abc)" \
  "$(wake_row 4 example-org/b push 0123456789abcdef0123456789abcdef01234567)")"
waitfor "$T/h/calls/merge-conductor" || true
[ "$(wc -l < "$T/h/calls/merge-conductor" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "case 5d: expected one unkeyed launch: $(cat "$T/h/calls/merge-conductor" 2>/dev/null)"
[ -z "$(mc_only_value)" ] && ok || bad "case 5d: a non-PR key leaked into MC_ONLY_PR: '$(mc_only_value)'"

# 5e. ...and beside a real key, only the real key rides.
reset_wl
FLEET_CONF="$T/h/fleet.conf" WAKE_CONDUCTOR_KEYED=1 run_wl "$(wakes_fixture \
  "$(wake_row 1 example-org/a pr -)" \
  "$(wake_row 2 example-org/a checks 7)" \
  "$(wake_row 3 example-org/b pr 3x)")"
waitfor "$T/h/calls/merge-conductor" || true
[ "$(mc_only_value)" = 'example-org/a#7' ] && ok || bad "case 5e: expected exactly 'example-org/a#7' (lowercased, BH-1841), got '$(mc_only_value)'"
grep -qF 'pr/checks[example-org/a#7]: launched merge-conductor.sh' "$T/h/logs/wake-loop.log" && ok \
  || bad "case 5e: the keyed launch must name its keys in the label: $(cat "$T/h/logs/wake-loop.log")"
[ ! -s "$T/h/ssh.log" ] && ok || bad "case 5e: the hub's conductor launch must never ssh: $(cat "$T/h/ssh.log")"

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

# 6. Keyed tick with MC_ONLY_PR=example-org/a#7: only repo a, only PR 7, no side lanes.
reset_mc
seed_land
mkdir -p "$T/h/state/merge-conductor/rereview"
touch -d '4 days ago' "$T/h/state/merge-conductor/rereview/old-sentinel.json"
run_mc env MC_ONLY_PR=example-org/a#7

if grep -q 'example-org/b' "$T/gh-calls.txt" 2>/dev/null; then
  bad "case 6: keyed tick read repo b ($(grep 'example-org/b' "$T/gh-calls.txt"))"
else
  ok
fi
grep -q 'pr list -R example-org/a --state open' "$T/gh-calls.txt" && ok || bad "case 6: keyed tick did not list repo a's PRs: $(cat "$T/gh-calls.txt")"
if [ -n "$(state_of 'example-org/a#7')" ]; then ok; else bad "case 6: pr-state.tsv missing example-org/a#7: $(mclog)"; fi
if [ -z "$(state_of 'example-org/a#8')" ]; then ok; else bad "case 6: keyed tick must not add example-org/a#8"; fi
if [ -z "$(state_of 'example-org/b#3')" ]; then ok; else bad "case 6: keyed tick must not add example-org/b#3"; fi
if [ ! -s "$T/h/calls/batch-resolve" ]; then ok; else bad "case 6: keyed tick spawned batch-resolve ($(cat "$T/h/calls/batch-resolve"))"; fi
if [ ! -s "$T/git-calls.txt" ]; then ok; else bad "case 6: keyed tick caused git/land-rebase activity ($(cat "$T/git-calls.txt"))"; fi
[ "$(cat "$T/h/state/merge-conductor/land/a")" = "$LAND_OLD" ] && ok || bad "case 6: keyed tick advanced the land sha: $(cat "$T/h/state/merge-conductor/land/a")"
grep -q 'LAND' "$T/h/logs/merge-conductor.log" && bad "case 6: keyed tick ran the LAND block: $(grep LAND "$T/h/logs/merge-conductor.log")" || ok
if [ -f "$T/h/state/merge-conductor/rereview/old-sentinel.json" ]; then ok; else bad "case 6: keyed tick ran GC side-effects (old-sentinel removed)"; fi
if [ ! -s "$T/h/calls/main-red-detector" ]; then ok; else bad "case 6: keyed tick ran the fleet-wide main-red detector"; fi
grep -q 'main-red detector:' "$T/h/logs/merge-conductor.log" && bad "case 6: keyed tick logged a main-red detector line" || ok
[ "$(grep -c 'keyed tick: 1 key(s) — example-org/a#7' "$T/h/logs/merge-conductor.log")" = 1 ] && ok || bad "case 6: expected exactly one 'keyed tick: 1 key(s) — example-org/a#7' line: $(mclog)"
[ ! -e "$T/h/state/merge-conductor/tick-a.json" ] && ok || bad "case 6: keyed tick wrote tick-a.json (it would push back the cadence hold)"
[ ! -e "$T/h/state/merge-conductor/tick-b.json" ] && ok || bad "case 6: keyed tick wrote tick-b.json for a project it skipped"

# 6a. NEAR MISSES. The padded exact-token match: a key #70 matches neither #7
# nor #8, and a slug that merely STARTS with the project's slug is another repo.
reset_mc
run_mc env MC_ONLY_PR='example-org/a#70'
[ -z "$(state_of 'example-org/a#7')$(state_of 'example-org/a#8')$(state_of 'example-org/b#3')" ] && ok \
  || bad "case 6a: MC_ONLY_PR=example-org/a#70 ticked a PR: $(cat "$T/h/state/merge-conductor/pr-state.tsv")"
reset_mc
run_mc env MC_ONLY_PR='example-org/ab#7'
[ -z "$(state_of 'example-org/a#7')" ] && ok || bad "case 6a: slug example-org/ab matched project example-org/a"
grep -q 'pr list -R example-org/a ' "$T/gh-calls.txt" && bad "case 6a: slug example-org/ab read repo a's list" || ok
# A trailing comma is one key, not two.
reset_mc
run_mc env MC_ONLY_PR='example-org/a#7,'
[ "$(grep -c 'keyed tick: 1 key(s)' "$T/h/logs/merge-conductor.log")" = 1 ] && ok || bad "case 6a: 'example-org/a#7,' is one key: $(mclog)"
[ -n "$(state_of 'example-org/a#7')" ] && [ -z "$(state_of 'example-org/a#8')" ] && ok || bad "case 6a: 'example-org/a#7,' must tick exactly a#7: $(cat "$T/h/state/merge-conductor/pr-state.tsv")"
# Two keys across two repos: both, and nothing else.
reset_mc
run_mc env MC_ONLY_PR='example-org/a#8,example-org/b#3'
[ -z "$(state_of 'example-org/a#7')" ] && [ -n "$(state_of 'example-org/a#8')" ] && [ -n "$(state_of 'example-org/b#3')" ] && ok \
  || bad "case 6a: two keys must tick exactly a#8 and b#3: $(cat "$T/h/state/merge-conductor/pr-state.tsv")"

# 6b. MC_ONLY_PR set but unparseable: today's full tick, and a log line that does
# NOT carry the token the cadence child counts keyed ticks with.
reset_mc
run_mc env MC_ONLY_PR='example-org/a#abc'
for k in example-org/a#7 example-org/a#8 example-org/b#3; do
  if [ -n "$(state_of "$k")" ]; then ok; else bad "case 6b: unparseable MC_ONLY_PR must run the full tick, missing $k"; fi
done
[ "$(grep -c "MC_ONLY_PR ignored: 'example-org/a#abc'" "$T/h/logs/merge-conductor.log")" = 1 ] && ok || bad "case 6b: expected one 'MC_ONLY_PR ignored' log line: $(mclog)"
[ "$(nkeyed)" = 0 ] && ok || bad "case 6b: a full fleet sweep logged the words 'keyed tick'"
reset_mc
run_mc env MC_ONLY_PR=garbage
for k in example-org/a#7 example-org/a#8 example-org/b#3; do
  if [ -n "$(state_of "$k")" ]; then ok; else bad "case 6b: MC_ONLY_PR=garbage must run the full tick, missing $k"; fi
done
[ "$(grep -c "MC_ONLY_PR ignored: 'garbage'" "$T/h/logs/merge-conductor.log")" = 1 ] && ok || bad "case 6b: expected one 'MC_ONLY_PR ignored' line for garbage: $(mclog)"

# 7. Unset MC_ONLY_PR -> all three fixture PRs are processed as today, and the
# fleet sweeps a keyed tick skips DO run here (the positive controls for case 6).
reset_mc
seed_land
run_mc
for k in example-org/a#7 example-org/a#8 example-org/b#3; do
  if [ -n "$(state_of "$k")" ]; then
    ok
  else
    bad "case 7: unkeyed tick missing $k"
  fi
done
if [ -s "$T/h/calls/main-red-detector" ]; then ok; else bad "case 7: unkeyed tick did not run the main-red detector"; fi
[ -e "$T/h/state/merge-conductor/tick-a.json" ] && ok || bad "case 7: unkeyed tick wrote no tick-a.json"
grep -q 'LAND main moved' "$T/h/logs/merge-conductor.log" && ok || bad "case 7: unkeyed tick did not see the moved land sha: $(grep LAND "$T/h/logs/merge-conductor.log")"
[ "$(nkeyed)" = 0 ] && ok || bad "case 7: an unkeyed tick logged 'keyed tick'"

# 8. MC_ONLY_PR crosses a process boundary from a webhook-fed wake row, so the
# split must not be globbed against the conductor's cwd. `example-org/*#7` passes
# the key regex (`*` is neither `#` nor space), so an unquoted split would
# expand it to the real file below and key the tick on a PR nobody woke.
reset_mc
mkdir -p "$T/example-org"; : > "$T/example-org/a#7"
run_mc env MC_ONLY_PR='example-org/*#7'
for k in example-org/a#7 example-org/a#8 example-org/b#3; do
  if [ -z "$(state_of "$k")" ]; then ok; else bad "case 8: cwd glob became a key — $k was ticked"; fi
done
rm -rf "$T/example-org"

# 9. A KEYED TICK LEAVES NON-KEYED CLOSED CANDIDATES RE-OFFERABLE (BH-1592 memo).
# a#9 is a harness PR the ledger still has open and GitHub answers CLOSED. The
# a#7 tick's probe finds it closed, but it is not this tick's key: it must not
# settle it AND must not leave the memo saying `closed`, or no later tick would
# ever read it again. The unkeyed tick after it is the positive control.
CW="$T/h/state/merge-conductor/closed-watch/example-org_a"
seed_a9() { printf 'example-org/a#9\tWAIT_CI\t1\t%s\t-\t-\twaiting\thttps://github.com/example-org/a/pull/9\n' "$H2" \
  >> "$T/h/state/merge-conductor/pr-state.tsv"; }
reset_mc
seed_a9
run_mc env MC_ONLY_PR=example-org/a#7
grep -q 'repos/example-org/a/pulls/9' "$T/gh-calls.txt" && ok || bad "case 9: the keyed tick never probed a#9 (fixture drift): $(mclog)"
[ "$(state_of 'example-org/a#9')" = WAIT_CI ] && ok || bad "case 9: a keyed a#7 tick settled a#9: $(state_of 'example-org/a#9')"
[ "$(cut -f1,2 "$CW/9" 2>/dev/null)" = "$(printf 'open\t0')" ] && ok \
  || bad "case 9: a#9's memo must read 'open<TAB>0' after the keyed tick, got '$(cat "$CW/9" 2>/dev/null)' ($(ls "$T/h/state/merge-conductor/closed-watch" 2>/dev/null))"
run_mc
[ "$(state_of 'example-org/a#9')" = CLOSED ] && ok || bad "case 9: the unkeyed tick after it did not settle a#9: $(state_of 'example-org/a#9') $(mclog)"

# 10. A KEYED TICK DOES NOT RUN THE FLEET-WIDE HELD-PAGE FLUSH (BH-1201/BH-1382).
# One held BUDGET row for b#3, actions mode (the flush runs in actions|merge).
# The a#7 tick may READ the held list (BH-1840: it loads the cache its own pagers
# defer to) but must never flush or release it; the unkeyed tick (control) pages it.
seed_b3() { printf 'example-org/b#3\tREADY\t900\t%s\t-\t-\tclean\thttps://github.com/example-org/b/pull/3\n' "$H3" \
  >> "$T/h/state/merge-conductor/pr-state.tsv"; }
jq -nc --arg h "$H3" '{rows:[{repo:"example-org/b",number:3,state:"READY",head:$h,kind:"BUDGET",
  text:"20m in READY: held-b3-page",mark:"READY@900",mode:"kill-switch",
  first_held_at:"2026-09-23T00:00:00Z",last_seen_at:"2026-09-23T00:00:00Z"}],n_total:1}' > "$T/held.json"
mkdir -p "$T/h/flags"; touch "$T/h/flags/merge-conductor-actions"
reset_mc; rm -f "$T/h/logs/ALERTS.log"
seed_b3
run_mc env MC_ONLY_PR=example-org/a#7 HELD_JSON="$T/held.json"
grep -q 'POST .*api/conductor/held/release' "$T/req.txt" && bad "case 10: a keyed tick released held pages: $(grep held "$T/req.txt")" || ok
grep -qE 'flushed:|held pages' "$T/h/logs/merge-conductor.log" && bad "case 10: a keyed tick ran the flush: $(mclog)" || ok
grep -q 'held-b3-page' "$T/h/logs/ALERTS.log" 2>/dev/null && bad "case 10: a keyed a#7 tick paged b#3's held page" || ok
reset_mc; rm -f "$T/h/logs/ALERTS.log"
seed_b3
run_mc env HELD_JSON="$T/held.json"
grep -q 'example-org/b#3 BUDGET flushed' "$T/h/logs/merge-conductor.log" && ok || bad "case 10: the unkeyed tick did not flush b#3: $(mclog)"
grep -q 'held-b3-page' "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "case 10: the unkeyed tick's flush sent no page for b#3"
rm -f "$T/h/flags/merge-conductor-actions" "$T/held.json"

echo "conductor-wake-keyed.bh-1387-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
