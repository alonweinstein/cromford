#!/bin/bash
# tests/e2e-join-lib-test.sh — bin/lib/e2e-join.sh holds the join cap the smoke
# stage will wait on. Two things are pinned: e2e_join_max NEVER refuses to
# answer (an unusable E2E_JOIN_MAX_S still prints 600, it just carries rc 2 so
# the caller can write the ALERT line), and e2e_wait_pid_capped is a BOUNDED
# poll — a bare `wait` would hang on the heartbeat child the caller's shell owns
# and no cap would ever fire. The wait cases assert ordering only (rc, and
# whether the pid is alive afterwards), never elapsed wall-clock time.
#
# No scratch tree: nothing is created, removed, or cd'd into, so there is
# nothing for tests/lib/scratch.sh to own. Every background sleep is killed
# before the summary line.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/e2e-join.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
# shellcheck source=../bin/lib/e2e-join.sh
. "$LIB" || exit 1

check_max() { # check_max <label> <expected stdout> <expected rc>
  local label="$1" want="$2" wantrc="$3" got rc
  got=$(e2e_join_max); rc=$?
  if [ "$got" = "$want" ] && [ "$rc" = "$wantrc" ]; then ok
  else bad "e2e_join_max $label: printed '$got' rc $rc, want '$want' rc $wantrc"; fi
}
with_max() { local E2E_JOIN_MAX_S="$1"; shift; "$@"; }

unset E2E_JOIN_MAX_S
check_max "unset"  600 0
with_max ''   check_max "blank" 600 0
with_max 0    check_max "0 (uncapped)" 0 0
with_max 45   check_max "45" 45 0
with_max abc  check_max "abc" 600 2      # unusable: still answers 600, rc 2 for the ALERT
with_max '-1' check_max "-1" 600 2
[ "$E2E_JOIN_MAX_DEFAULT" = 600 ] && ok || bad "E2E_JOIN_MAX_DEFAULT is '$E2E_JOIN_MAX_DEFAULT', want 600"

# A live pid at the cap: rc 1 (NOT timeout's 124 — that would mean the poll is
# unbounded), and the pid is still running afterwards because the helper never
# kills what it waits on.
sleep 30 & p=$!
timeout 5 bash -c '. "$1"; e2e_wait_pid_capped "$2" 1' _ "$LIB" "$p"; rc=$?
[ "$rc" = 1 ] && ok || bad "cap 1 against a live pid: rc $rc (want 1; 124 means timeout fired and the poll is not bounded)"
kill -0 "$p" 2>/dev/null && ok || bad "cap 1 against a live pid: the helper must not kill the pid"
kill "$p" 2>/dev/null || true

# A pid that exits before the cap: rc 0, well inside the timeout.
sleep 1 & p=$!
timeout 5 bash -c '. "$1"; e2e_wait_pid_capped "$2" 10' _ "$LIB" "$p"; rc=$?
[ "$rc" = 0 ] && ok || bad "cap 10 against a short-lived pid: rc $rc (want 0)"
kill "$p" 2>/dev/null || true

# Cap 0 is "poll until it is gone": rc 0, and only after the pid really went.
sleep 2 & p=$!
timeout 10 bash -c '. "$1"; e2e_wait_pid_capped "$2" 0' _ "$LIB" "$p"; rc=$?
[ "$rc" = 0 ] && ok || bad "cap 0 against a short-lived pid: rc $rc (want 0)"
kill -0 "$p" 2>/dev/null && bad "cap 0 returned 0 while the pid was still alive" || ok
kill "$p" 2>/dev/null || true

echo "e2e-join-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
