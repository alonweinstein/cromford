#!/bin/bash
# tests/dequeue-watch-act.bh-3835-test.sh — BH-3835: dequeue-watch resolves the
# culprit's ticket and issue from a rebuild-ladder branch (ticket/bh-77-r2) the
# same as from ticket/bh-77, through the shared bin/lib/ticket-branch.sh.
#
# Sources the REAL bin/lib/dequeue-watch/act.sh (which sources the REAL
# bin/lib/ticket-branch.sh) and drives dqw_act, the production entry point.
# The stub scaffolding is copied from tests/dequeue-watch-act.bh-3719-test.sh:
# every stub appends one line to $CALLS and the cases read those lines.
# Run from anywhere: tests/dequeue-watch-act.bh-3835-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$HARNESS/bin" "$HARNESS/logs"
CALLS="$T/calls.txt"; export CALLS
LOG="$HARNESS/logs/dequeue-watch.log"

# ── script stubs ──────────────────────────────────────────────────────────────
cat > "$HARNESS/bin/needs-human-hold.sh" <<'EOF'
#!/bin/bash
echo "needs-human-hold $*" >> "$CALLS"
exit 0
EOF
cat > "$HARNESS/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
echo "lane-alert $*" >> "$CALLS"
exit 0
EOF
cat > "$HARNESS/bin/box-for.sh" <<'EOF'
#!/bin/bash
echo "box-for $*" >> "$CALLS"
echo box-2
EOF
chmod +x "$HARNESS/bin/"*.sh

# shellcheck source=../bin/lib/dequeue-watch/act.sh
. "$DIR/bin/lib/dequeue-watch/act.sh" || { echo "FAIL: bin/lib/dequeue-watch/act.sh could not be sourced"; exit 1; }

# ── function stubs (defined after the lib so they win) ───────────────────────
dqw_action_claim() {
  echo "dqw_action_claim $*" >> "$CALLS"
  jq -nc --arg a "$5" '{claimed:true, row:{action:$a, status:"claimed"}}'
}
dqw_action_set() { echo "dqw_action_set $*" >> "$CALLS"; return 0; }
dqw_rounds_count() { echo "dqw_rounds_count $*" >> "$CALLS"; echo "${STUB_COUNT:-0}"; }
mc_attempt_put() { echo "mc_attempt_put $*" >> "$CALLS"; }
fix_round_enqueue() {
  echo "fix_round_enqueue $*" >> "$CALLS"
  echo '{"id":"job-77","status":"queued"}'
}
nh_fingerprint() { echo "nh_fingerprint $*" >> "$CALLS"; echo abcdef0123456789; }

HEAD=0123456789abcdef0123456789abcdef01234567
SLUG=example-org/cromford
URL=https://github.com/$SLUG/pull/42
ctx() {  # ctx <head_ref>
  jq -nc --arg r "$1" \
    '{rule_id:"D43", suite:"tests/a-test.sh", fail_lines:"FAIL: a broke", hint:"h", brief:"b",
      run_id:"991", run_url:"https://github.com/example-org/cromford/actions/runs/991",
      draft:false, head_ref:$r, verdict_word:"MERGE"}'
}
reset() { : > "$CALLS"; : > "$LOG"; unset STUB_COUNT; }
n() { grep -c -- "$1" "$CALLS"; }
alert_has() { awk -v p="$1" '/lane-alert/ && index($0, p) { f = 1 } END { exit !f }' "$CALLS"; }
# The lane ships observe-only (BH-3859); these cases act unless one sets 0.
act() { DEQUEUE_WATCH_ACT="${DEQUEUE_WATCH_ACT:-1}" dqw_act proj "$SLUG" 42 "$URL" "$HEAD" "$@"; }
hold() { reset; STUB_COUNT=2; export STUB_COUNT; act rule-break "$(ctx "$1")"; }

# ── A1: hold on a rebuild branch places the hold on the ticket's issue ───────
hold ticket/bh-77-r2
[ "$(n 'needs-human-hold proj 77 abcdef0123456789 ')" = 1 ] && ok \
  || bad "A1: ticket/bh-77-r2 must hold issue 77, calls: $(tr '\n' '|' < "$CALLS")"
alert_has 'no ticket issue' && bad "A1: ticket/bh-77-r2 alert says no ticket issue" || ok
alert_has 'dqw-hold:proj:42:rule-break' && ok || bad "A1: no hold alert was raised"

# ── A2: a fix round on a rebuild branch carries the ticket key ───────────────
reset; act rule-break "$(ctx ticket/bh-77-r2)"
line=$(grep '^fix_round_enqueue ' "$CALLS")
case "$line" in
  *" queue-dequeued $URL - BH-77") ok ;;
  *) bad "A2: fix_round_enqueue argv must end 'queue-dequeued $URL - BH-77', got: $line" ;;
esac

# ── A3: -r12 and the plain shape both resolve ────────────────────────────────
for ref in ticket/bh-77-r12 ticket/bh-77; do
  hold "$ref"
  [ "$(n 'needs-human-hold proj 77 abcdef0123456789 ')" = 1 ] && ok \
    || bad "A3: $ref must hold issue 77, calls: $(tr '\n' '|' < "$CALLS")"
done
reset; act rule-break "$(ctx ticket/bh-77)"
grep -q "^fix_round_enqueue .* - BH-77\$" "$CALLS" && ok || bad "A3: ticket/bh-77 fix round must carry BH-77"

# ── A4: what is NOT a ticket branch places no hold ───────────────────────────
for ref in ticket/bh-1510-0 ticket/bh-77-local ticket/bh-77-R2 feature/bh-77; do
  hold "$ref"
  [ "$(n needs-human-hold)" = 0 ] && ok || bad "A4: $ref must place no hold, calls: $(tr '\n' '|' < "$CALLS")"
  alert_has 'no ticket issue, so no hold was placed.' && ok || bad "A4: $ref alert must say no ticket issue"
done

# ── A5: the lib missing is logged, not silent ────────────────────────────────
mkdir -p "$T/nolib/bin/lib/dequeue-watch"
cp "$DIR/bin/lib/dequeue-watch/act.sh" "$T/nolib/bin/lib/dequeue-watch/act.sh"
out=$(HARNESS="$T/h5" bash -c '. "$1" 2>/dev/null; _dqw_ticket ticket/bh-77; echo "rc=$?"' _ "$T/nolib/bin/lib/dequeue-watch/act.sh")
[ "$out" = "rc=0" ] && ok || bad "A5: without the lib _dqw_ticket must print nothing, rc 0; got '$out'"
grep -q 'act: bin/lib/ticket-branch.sh not loaded, no ticket for ticket/bh-77' "$T/h5/logs/dequeue-watch.log" 2>/dev/null && ok \
  || bad "A5: without the lib no 'ticket-branch.sh not loaded' log line"

echo "dequeue-watch-act.bh-3835: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
