#!/bin/bash
# tests/cost-rows-no-fixture-leak.bh-4005-test.sh — a suite that sources
# tests/lib/scratch.sh never reaches the box's real worker through the box's
# real env dir (BH-4005, Guard 1 of BH-3982).
#
# The hole: a suite points HARNESS at a scratch tree with no env/, so
# bin/lib/env-path.sh rule 3 answers ${ETC_HARNESS_ENV:-/etc/harness/env}, the
# box's REAL env dir. bin/jobs-client.sh then reads the real HARNESS_SECRET and,
# because scratch.sh exported JOBS_URL empty, adopts the real JOBS_URL too. Any
# suite that unsets HARNESS_TEST_SANDBOX (five cost suites do) then POSTs its
# stub runner's cost row to prod, and call-guard, settings, cooldowns and
# catalog reads go the same way. $T/realenv stands in for /etc/harness/env.
#
#   L1  bin/agent-call.sh in a child that sourced scratch.sh: 0 requests to the
#       real JOBS_URL (red on main: a POST to /api/metrics/cost-rows).
#   L2  the same with a real project name (cromford): still 0.
#   L3  the row lands in the scratch tree's cost.csv and nowhere else, and the
#       child ran with HARNESS=$T/a, so L1's zero is not vacuous.
#   L4  scratch.sh exports ETC_HARNESS_ENV to a path inside SCRATCH that does
#       not exist, so harness_env_dir answers the tree's own env/.
#   L5  positive control: an explicit stub JOBS_URL + secret still gets its
#       cost-rows POST, and nothing goes to the real JOBS_URL.
#   L6  a suite that pins ETC_HARNESS_ENV per command after sourcing still wins.
# Run from anywhere: tests/cost-rows-no-fixture-leak.bh-4005-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------------------------------------------------------------------------
# fixtures: recording curl (never a network), stub runner, fake real env dir
# ---------------------------------------------------------------------------
mkdir -p "$T/fakebin" "$T/realenv"
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
printf '%s\n' "${!#}" >> "$CURL_SINK"
exit 7
CURL
cat > "$T/fakebin/claude" <<'EOF'
#!/bin/bash
printf '{"result":"ok","usage":{"input_tokens":10,"output_tokens":2},"total_cost_usd":0.01}\n'
EOF
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/curl" "$T/fakebin/claude" "$T/fakebin/billing-mode.sh" "$T/fakebin/timeout"
printf 'JOBS_URL=https://real-jobs.invalid\nHARNESS_SECRET=realsecret\n' > "$T/realenv/global.env"
printf 'cromford\n' > "$T/fleet.conf"

# A scratch harness tree with NO env/ of its own: the shape that leaked.
mk_tree() {
  mkdir -p "$1/bin/lib/jobs" "$1/logs" "$1/locks" "$1/flags" "$1/state"
  cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$1/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$1/bin/lib/jobs/"
  cp "$DIR/bin/lib/env-path.sh" "$1/bin/lib/"
  echo testbox > "$1/state/box-id"
}

# run_child <tree> <proj> <sink> <preset-etc> <post-source-cmds>
# A child that does what a suite does: arrives with the box's env dir in
# ETC_HARNESS_ENV, sources scratch.sh, drops the sandbox flag (as the cost
# suites do), and runs the real bin/agent-call.sh against <tree>.
run_child() {
  : > "$3"
  RC_TREE="$1" RC_PROJ="$2" RC_SINK="$3" RC_POST="$5" RC_DIR="$DIR" RC_T="$T" \
  ETC_HARNESS_ENV="$4" HARNESS_TEST_SANDBOX=1 bash -c '
    . "$RC_DIR/tests/lib/scratch.sh" || exit 1
    unset HARNESS_TEST_SANDBOX OPENROUTER_API_KEY
    eval "$RC_POST"
    export PATH="$RC_T/fakebin:$PATH" HARNESS="$RC_TREE" HOME="$RC_T" CURL_SINK="$RC_SINK" \
           CONTEXT_BUDGETS="$RC_DIR/catalog/context-budgets.json"
    echo "HARNESS=$HARNESS" > "$RC_TREE/child-harness.txt"
    bash "$RC_DIR/bin/agent-call.sh" review "$RC_PROJ" claude-fable-5 60 "$RC_TREE/out.txt" hello
  ' >"$1/child.log" 2>&1
}

real_hits() { grep -c 'real-jobs.invalid' "$1" 2>/dev/null; }

# ===========================================================================
# L1. the leak shape, fixture project name
# ===========================================================================
mk_tree "$T/a"
run_child "$T/a" lproj "$T/sink.l1" "$T/realenv" ''
N1=$(real_hits "$T/sink.l1")
if [ "$N1" = 0 ]; then ok; else
  C1=$(grep -c 'real-jobs.invalid/api/metrics/cost-rows' "$T/sink.l1")
  [ "$C1" -ge 1 ] && bad "L1: agent-call.sh sent $C1 request(s) to the real JOBS_URL's /api/metrics/cost-rows"
  bad "L1: agent-call.sh sent $N1 request(s) to the real JOBS_URL in all: $(grep 'real-jobs.invalid' "$T/sink.l1" | grep -v '/api/metrics/cost-rows' | sort -u | tr '\n' ' ')"
fi

# ===========================================================================
# L2. a real project name leaks the same way without the guard
# ===========================================================================
mk_tree "$T/b"
run_child "$T/b" cromford "$T/sink.l2" "$T/realenv" ''
N2=$(real_hits "$T/sink.l2")
[ "$N2" = 0 ] && ok \
  || bad "L2: agent-call.sh (project cromford) sent $N2 request(s) to the real JOBS_URL: $(sort -u "$T/sink.l2" | grep 'real-jobs.invalid' | tr '\n' ' ')"

# ===========================================================================
# L3. the row stays in the scratch ledger, and the child really ran
# ===========================================================================
R3=$(grep -c ',lproj,review,' "$T/a/logs/cost.csv" 2>/dev/null)
[ "$R3" = 1 ] && ok \
  || bad "L3: want exactly 1 ',lproj,review,' row in \$T/a/logs/cost.csv, got '${R3:-none}' (did the stub runner run? $(tail -n 3 "$T/a/child.log" | tr '\n' ' '))"
L3_WANT=$(printf '%s\n%s\n' "$T/a/logs/cost.csv" "$T/b/logs/cost.csv" | sort)
L3_GOT=$(find "$T" -name cost.csv | sort)
[ "$L3_GOT" = "$L3_WANT" ] && ok || bad "L3: cost.csv ledgers found: $(echo "$L3_GOT" | tr '\n' ' ')"
[ "$(cat "$T/a/child-harness.txt" 2>/dev/null)" = "HARNESS=$T/a" ] && ok \
  || bad "L3: the child ran with '$(cat "$T/a/child-harness.txt" 2>/dev/null)', want HARNESS=$T/a"

# ===========================================================================
# L4. the scratch contract: ETC_HARNESS_ENV points inside SCRATCH, not real
# ===========================================================================
L4=$(ETC_HARNESS_ENV="$T/realenv" bash -c '
  . "$0/tests/lib/scratch.sh" || exit 1
  printf "%s|%s\n" "$ETC_HARNESS_ENV" "$SCRATCH"
  . "$0/bin/lib/env-path.sh"; harness_env_dir "$1"' "$DIR" "$T/a" 2>&1)
L4_ETC=$(printf '%s\n' "$L4" | sed -n '1s/|.*//p')
L4_SCR=$(printf '%s\n' "$L4" | sed -n '1s/.*|//p')
L4_RES=$(printf '%s\n' "$L4" | sed -n '2p')
if [ -n "$L4_ETC" ] && [ ! -e "$L4_ETC" ] && [ -n "$L4_SCR" ] && case "$L4_ETC" in "$L4_SCR"/*) true ;; *) false ;; esac; then ok
else bad "L4: a child's scratch.sh must export ETC_HARNESS_ENV to a missing path inside its SCRATCH, got '$L4_ETC' (SCRATCH '$L4_SCR')"; fi
[ "$L4_RES" = "$T/a/env" ] && ok || bad "L4: harness_env_dir \$T/a after sourcing printed '$L4_RES', want $T/a/env"
if [ -n "${ETC_HARNESS_ENV:-}" ] && [ ! -e "$ETC_HARNESS_ENV" ] && case "$ETC_HARNESS_ENV" in "$SCRATCH"/*) true ;; *) false ;; esac; then ok
else bad "L4: this suite's own ETC_HARNESS_ENV is '${ETC_HARNESS_ENV:-}', want a missing path under $SCRATCH"; fi
[ -n "$(bash -c 'printf %s "${ETC_HARNESS_ENV:-}"')" ] && ok || bad "L4: ETC_HARNESS_ENV is not exported to children"

# ===========================================================================
# L5. positive control: an explicit stub worker still gets its POST
# ===========================================================================
mk_tree "$T/c"
run_child "$T/c" cromford "$T/sink.l5" "$T/realenv" \
  'export JOBS_URL=https://stub.invalid HARNESS_SECRET=x FLEET_CONF="$RC_T/fleet.conf"'
S5=$(grep -c '^https://stub.invalid/api/metrics/cost-rows$' "$T/sink.l5" 2>/dev/null)
[ "${S5:-0}" -ge 1 ] && ok \
  || bad "L5: the stub JOBS_URL got no cost-rows POST (the transport is broken, so L1/L2 prove nothing): $(sort -u "$T/sink.l5" | tr '\n' ' ')"
N5=$(real_hits "$T/sink.l5")
[ "$N5" = 0 ] && ok || bad "L5: $N5 request(s) still went to the real JOBS_URL: $(grep 'real-jobs.invalid' "$T/sink.l5" | sort -u | tr '\n' ' ')"

# ===========================================================================
# L6. a per-command ETC_HARNESS_ENV after sourcing still wins
# ===========================================================================
L6=$(ETC_HARNESS_ENV="$T/realenv" bash -c '. "$1/bin/lib/env-path.sh"; harness_env_dir "$2"' _ "$DIR" "$T/a")
[ "$L6" = "$T/realenv" ] && ok || bad "L6: a pinned ETC_HARNESS_ENV must win, harness_env_dir printed '$L6'"

echo "cost-rows-no-fixture-leak: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
