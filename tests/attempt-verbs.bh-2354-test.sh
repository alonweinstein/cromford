#!/bin/bash
# tests/attempt-verbs.bh-2354-test.sh — BH-2354 (BH-2311.0): the four attempt-
# ledger verbs in bin/lib/mc/locks.sh, file-backed only in this slice.
#
#   mc_attempt_lines <kinds> <key> <out-file>   whole lines, file order, rc 0/2/1
#   mc_attempt_count <kinds> <key> [head]       a number, 0 on an unreadable file
#   mc_attempt_tail  <kind> <key> <head> [first|last]   field 4 onward
#   mc_attempt_put_n <kind> <key> <head…>       the line `echo >>` writes today
#
# Every match is field-exact on $1/$2 (and $3 given a head), so `requeued` never
# counts `requeued2`, `o/r#12` never counts `o/r#123`, and `x/y#12` is another
# PR. The fixture lines are the shapes the conductor's writers emit.
#
# The module loads through the REAL bin/lib/merge-conductor-lib.sh shim, copied
# into a scratch $HARNESS, and section 0 asserts the verbs came out of
# mc/locks.sh. MC_LOCKS_UNDER_TEST=<path> swaps in a broken copy of the module,
# which is how the mutation checks are run. Flag `pr-state-rows` is absent.
# Run from anywhere: tests/attempt-verbs.bh-2354-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── fixture ─────────────────────────────────────────────────────────────────
mkdir -p "$T/h/bin/lib/mc" "$T/h/env" "$T/h/state/merge-conductor" "$T/h/logs" "$T/h/locks"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
LOCKS_SRC="$DIR/bin/lib/mc/locks.sh"
[ -n "${MC_LOCKS_UNDER_TEST:-}" ] && LOCKS_SRC="$MC_LOCKS_UNDER_TEST"
cp "$LOCKS_SRC" "$T/h/bin/lib/mc/locks.sh"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/main-red-gate.sh" "$DIR/bin/lib/review-provenance.sh" \
   "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
: > "$T/h/env/global.env"

export HARNESS="$T/h"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init

FIX="$T/attempts.txt"
cat > "$FIX" <<'EOF'
requeued o/r#12 h1 100
requeued2 o/r#12 h1 200
requeued o/r#12 h2 300
requeued o/r#12 h1 400
requeued o/r#123 h1 500
requeued x/y#12 h1 600
ejected o/r#12 h1
reejected o/r#12 h2
ejectconflict o/r#12 h3
red o/r#12 h1
identityalert hub gh-app 20260922
EOF
MC_ATTEMPTS="$FIX"
OUT="$T/out"

# ============================================================================
# 0. THE VERBS CAME FROM THE MODULE, THROUGH THE PRODUCTION SHIM (A8)
# ============================================================================
for fn in mc_attempt_lines mc_attempt_count mc_attempt_tail mc_attempt_put_n; do
  src=$( shopt -s extdebug; declare -F "$fn" | awk '{print $3}' )
  [ "$src" = "$T/h/bin/lib/mc/locks.sh" ] && ok \
    || bad "0: $fn must be defined by mc/locks.sh via the shim, got '${src:-<undefined>}'"
done

# ============================================================================
# A1. LINES: field-exact kind and key, whole lines, file order
# ============================================================================
mc_attempt_lines requeued 'o/r#12' "$OUT"; rc=$?
[ "$rc" = 0 ] && ok || bad "A1: rc want 0 got $rc"
want=$'requeued o/r#12 h1 100\nrequeued o/r#12 h2 300\nrequeued o/r#12 h1 400'
[ "$(cat "$OUT" 2>/dev/null)" = "$want" ] && ok \
  || bad "A1: lines want [$want] got [$(cat "$OUT" 2>/dev/null)]"

# ============================================================================
# A2. LINES: a | kind list, and a kind absent from the file
# ============================================================================
mc_attempt_lines 'ejected|reejected|ejectconflict' 'o/r#12' "$OUT"; rc=$?
[ "$rc" = 0 ] && ok || bad "A2: rc want 0 got $rc"
want=$'ejected o/r#12 h1\nreejected o/r#12 h2\nejectconflict o/r#12 h3'
[ "$(cat "$OUT" 2>/dev/null)" = "$want" ] && ok \
  || bad "A2: list want [$want] got [$(cat "$OUT" 2>/dev/null)]"
mc_attempt_lines 'ejected|nosuch' 'o/r#12' "$OUT"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$OUT" 2>/dev/null)" = "ejected o/r#12 h1" ] && ok \
  || bad "A2: 'ejected|nosuch' want rc 0 + one line, got rc $rc [$(cat "$OUT" 2>/dev/null)]"

# ============================================================================
# A3. LINES: measured none rc 2, bad args rc 1, missing file rc 2
# ============================================================================
echo stale > "$OUT"
mc_attempt_lines mergefail 'o/r#12' "$OUT"; rc=$?
[ "$rc" = 2 ] && ok || bad "A3: no match want rc 2 got $rc"
[ -f "$OUT" ] && [ ! -s "$OUT" ] && ok || bad "A3: no match must leave out EMPTY (got [$(cat "$OUT" 2>/dev/null)])"
mc_attempt_lines '' 'o/r#12' "$OUT"; rc=$?
[ "$rc" = 1 ] && ok || bad "A3: empty kind want rc 1 got $rc"
mc_attempt_lines requeued '' "$OUT"; rc=$?
[ "$rc" = 1 ] && ok || bad "A3: empty key want rc 1 got $rc"
mc_attempt_lines requeued 'o/r#12' "$T/no/such/dir/out"; rc=$?
[ "$rc" = 1 ] && ok || bad "A3: unwritable out want rc 1 got $rc"
echo stale > "$OUT"
MC_ATTEMPTS="$T/missing.txt"
mc_attempt_lines requeued 'o/r#12' "$OUT"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$OUT" ] && ok || bad "A3: missing file want rc 2 + empty out, got rc $rc"
MC_ATTEMPTS="$FIX"

# ============================================================================
# A4. COUNT: with and without head, kind list, prefix kind
# ============================================================================
chk_count() {  # <want> <label> <args…>
  local want="$1" label="$2" got; shift 2
  got=$(mc_attempt_count "$@"); local rc=$?
  [ "$got" = "$want" ] && [ "$rc" = 0 ] && ok || bad "A4/5: $label want $want rc 0, got [$got] rc $rc"
}
chk_count 3 "requeued o/r#12" requeued 'o/r#12'
chk_count 2 "requeued o/r#12 h1" requeued 'o/r#12' h1
chk_count 1 "requeued o/r#12 h2" requeued 'o/r#12' h2
chk_count 2 "ejected|reejected o/r#12" 'ejected|reejected' 'o/r#12'
chk_count 1 "requeued2 o/r#12" requeued2 'o/r#12'
chk_count 1 "requeued o/r#123" requeued 'o/r#123'
chk_count 1 "requeued x/y#12" requeued 'x/y#12'
chk_count 0 "requeued o/r#12 h9" requeued 'o/r#12' h9
# String equality, not awk's numeric compare: head 100 is not head 0100 / 1e2.
printf 'cirerun o/r#12 0100 5\ncirerun o/r#12 1e2 6\n' > "$T/num.txt"
MC_ATTEMPTS="$T/num.txt"
chk_count 0 "numeric-looking head 100 vs 0100/1e2" cirerun 'o/r#12' 100
chk_count 1 "head 0100 exact" cirerun 'o/r#12' 0100
MC_ATTEMPTS="$FIX"

# ============================================================================
# A5. COUNT: 0 on a missing file; parity with today's call-site greps
# ============================================================================
MC_ATTEMPTS="$T/missing.txt"
chk_count 0 "missing file" requeued 'o/r#12'
chk_count 0 "missing file with head" red 'o/r#12' h1
MC_ATTEMPTS="$FIX"
chk_count 0 "empty kind" '' 'o/r#12'
# merge-conductor.sh's shape: grep -c "^<kind> $KEY $HEAD"
old=$(grep -c "^red o/r#12 h1\$" "$MC_ATTEMPTS" 2>/dev/null || true)
chk_count "$old" "parity with grep -c ^red KEY HEAD" red 'o/r#12' h1
# queue.sh:701's shape: grep -cE "^(ejected|reejected) $1 "
old=$(grep -cE "^(ejected|reejected) o/r#12 " "$MC_ATTEMPTS" 2>/dev/null || true)
chk_count "$old" "parity with grep -cE ^(ejected|reejected) KEY" 'ejected|reejected' 'o/r#12'

# ============================================================================
# A6. TAIL: last by default, first on request, nothing on none, rc 1 bad mode
# ============================================================================
chk_tail() {  # <want> <label> <args…>
  local want="$1" label="$2" got; shift 2
  got=$(mc_attempt_tail "$@"); local rc=$?
  [ "$got" = "$want" ] && [ "$rc" = 0 ] && ok || bad "A6: $label want [$want] rc 0, got [$got] rc $rc"
}
chk_tail 400 "last (default)" requeued 'o/r#12' h1
chk_tail 400 "last" requeued 'o/r#12' h1 last
chk_tail 100 "first" requeued 'o/r#12' h1 first
chk_tail 300 "other head" requeued 'o/r#12' h2
chk_tail ""  "no such head" requeued 'o/r#12' h9
chk_tail ""  "3-field line prints no head" red 'o/r#12' h1
chk_tail 20260922 "non-PR key" identityalert hub gh-app
printf 'lanedown o/r#12 h1 1700000000 extra words\n' > "$T/multi.txt"
MC_ATTEMPTS="$T/multi.txt"
chk_tail "1700000000 extra words" "field 4 onward" lanedown 'o/r#12' h1
MC_ATTEMPTS="$T/missing.txt"
chk_tail "" "missing file" requeued 'o/r#12' h1
MC_ATTEMPTS="$FIX"
got=$(mc_attempt_tail requeued 'o/r#12' h1 middle); rc=$?
[ "$rc" = 1 ] && [ -z "$got" ] && ok || bad "A6: bad mode want rc 1 + nothing, got [$got] rc $rc"
# classify.sh's first-match shape: awk '$1==k && $2==key && $3==h {print $4; exit}'
old=$(awk -v k='o/r#12' -v h=h1 '$1=="requeued" && $2==k && $3==h {print $4; exit}' "$MC_ATTEMPTS")
chk_tail "$old" "parity with classify.sh first-match awk" requeued 'o/r#12' h1 first

# ============================================================================
# A7. PUT_N: byte-identical to `echo >>`, the row twin called once, no heads rc 1
# ============================================================================
: > "$T/put.txt"; : > "$T/want.txt"
MC_ATTEMPTS="$T/put.txt"
# Flag absent: the real mc_attempt_row_put runs and is a no-op.
mc_attempt_put_n lanedown 'o/r#12' h1 1700000000; rc=$?
echo "lanedown o/r#12 h1 1700000000" >> "$T/want.txt"
[ "$rc" = 0 ] && ok || bad "A7: put_n rc want 0 got $rc"
cmp -s "$T/put.txt" "$T/want.txt" && ok \
  || bad "A7: put_n (flag down) wrote [$(cat "$T/put.txt")], want [$(cat "$T/want.txt")]"
# The row twin is handed the same line, once.
ROWLOG="$T/rowput.log"; : > "$ROWLOG"
eval "$(declare -f mc_attempt_row_put | sed '1s/mc_attempt_row_put/_real_row_put/')"
mc_attempt_row_put() { printf '%s\n' "$1" >> "$ROWLOG"; return 7; }
mc_attempt_put_n rebase 'o/r#12' h2; rc=$?
echo "rebase o/r#12 h2" >> "$T/want.txt"
cmp -s "$T/put.txt" "$T/want.txt" && ok || bad "A7: second put_n not byte-identical: [$(cat "$T/put.txt")]"
[ "$(cat "$ROWLOG")" = "rebase o/r#12 h2" ] && ok \
  || bad "A7: mc_attempt_row_put want one call with 'rebase o/r#12 h2', got [$(cat "$ROWLOG")]"
cp "$T/put.txt" "$T/before.txt"; : > "$ROWLOG"
mc_attempt_put_n rebase 'o/r#12'; rc=$?
[ "$rc" = 1 ] && ok || bad "A7: no heads want rc 1 got $rc"
cmp -s "$T/put.txt" "$T/before.txt" && [ ! -s "$ROWLOG" ] && ok \
  || bad "A7: no heads must leave the file and the row untouched"
err=$( ( set -u; mc_attempt_lines requeued ) 2>&1 >/dev/null ); rc=$?
[ "$rc" = 1 ] && [ -z "$err" ] && ok || bad "A3: missing args under set -u want a clean rc 1, got rc $rc [$err]"
mc_attempt_put_n '' 'o/r#12' h1; rc=$?
[ "$rc" = 1 ] && cmp -s "$T/put.txt" "$T/before.txt" && ok || bad "A7: empty kind want rc 1, file untouched"
eval "$(declare -f _real_row_put | sed '1s/_real_row_put/mc_attempt_row_put/')"
MC_ATTEMPTS="$FIX"

echo "attempt-verbs.bh-2354: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
