#!/bin/bash
# tests/box-ops-fly.bh-2661-test.sh — BH-2661 (BH-2518.3): the real Fly machine
# stop/destroy executors in bin/lib/box-ops-fly.sh.
#
# The lib is sourced into a subshell against a scratch $HARNESS: a fleet-conf.sh
# stub that prints alpha and beta, a fly-machine-state.sh stub that pops one
# state per call from $T/states, the builder state file, the pool-app flags and
# a live pool job record. A fake `fly` first on PATH logs every call (and only
# whether a token rode it, never the token), so "no fly call" is observed.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/box-ops-fly.bh-2661-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/box-ops-fly.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin" "$H/env" "$H/flags" "$H/state/fly" "$H/state/fly-pool/alpha" "$T/fakebin"
cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = --projects ] || exit 2
printf 'alpha\nbeta\n'
EOF
cat > "$H/bin/fly-machine-state.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/state-calls"
s=\$(head -n1 "$T/states" 2>/dev/null); sed -i 1d "$T/states" 2>/dev/null
[ -n "\$s" ] || { echo unknown; exit 1; }
echo "\$s"
EOF
cat > "$T/fakebin/fly" <<EOF
#!/bin/bash
echo "\$* token=\${FLY_ACCESS_TOKEN:+present}" >> "$T/fly-calls"
printf '%s\n' "\${FAKE_FLY_OUT:-}"
exit "\${FAKE_FLY_RC:-0}"
EOF
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/fly-machine-state.sh" "$T/fakebin/fly"
echo '{"app":"alpha-builder","machine_id":"bld00001"}' > "$H/state/fly/alpha.json"
echo alpha-pool > "$H/flags/fly-pool-app-alpha"
echo beta-pool  > "$H/flags/fly-pool-app-beta"
echo '{"machine":"job00001","key":"BH-1"}' > "$H/state/fly-pool/alpha/job00001.json"
echo '{"machine":"m1abcdef"}' > "$H/state/fly-pool/alpha/.sweep.json"

# run <fn> <args...> — fresh logs, one subshell with the lib sourced; sets OUT RC
run() {
  rm -f "$T/fly-calls" "$T/state-calls"; : > "$T/fly-calls"; : > "$T/state-calls"
  OUT=$( ( set -u; export HARNESS="$H" PATH="$T/fakebin:$PATH"; . "$LIB"; "$@" ) 2>/dev/null ); RC=$?
  LINES=$(printf '%s\n' "$OUT" | wc -l)
  [ "$LINES" -eq 1 ] && ok || bad "E2: $* printed $LINES lines: '$OUT'"
}
calls()  { wc -l < "$T/fly-calls" | tr -d ' '; }
scalls() { wc -l < "$T/state-calls" | tr -d ' '; }
export FLY_API_TOKEN_ALPHA=tok
unset FAKE_FLY_OUT FAKE_FLY_RC

# --- F1. stop: started → stop → stopped read-back = ok ----------------------
printf 'started\nstopped\n' > "$T/states"
run box_ops_fly_stop m1abcdef alpha alpha-pool
[ "$RC" -eq 0 ] && ok || bad "F1: rc=$RC out='$OUT'"
[ "$OUT" = stopped ] && ok || bad "F1: stdout '$OUT'"
[ "$(cat "$T/fly-calls")" = "machine stop m1abcdef -a alpha-pool token=present" ] && ok || bad "F1: fly calls '$(cat "$T/fly-calls")'"
[ "$(scalls)" = 2 ] && ok || bad "F1: state calls $(scalls)"
[ "$(head -n1 "$T/state-calls")" = "alpha m1abcdef" ] && ok || bad "F1: state call args '$(head -n1 "$T/state-calls")'"

# --- F2. stop: already stopped = ok, no fly call ------------------------------
printf 'stopped\n' > "$T/states"
run box_ops_fly_stop m1abcdef alpha alpha-pool
[ "$RC" -eq 0 ] && [ "$OUT" = "already stopped" ] && ok || bad "F2: rc=$RC out='$OUT'"
[ "$(calls)" = 0 ] && ok || bad "F2: fly called"

# --- F3. stop: read-back still started = fail with state + trimmed error ------
printf 'started\nstarted\n' > "$T/states"
LONG=$(printf 'x%.0s' $(seq 1 400))
FAKE_FLY_OUT="$LONG" FAKE_FLY_RC=1 run box_ops_fly_stop m1abcdef alpha alpha-pool
[ "$RC" -eq 1 ] && ok || bad "F3: rc=$RC"
case "$OUT" in "fail: state=started rc=1: x"*) ok ;; *) bad "F3: stdout '${OUT:0:80}'" ;; esac
ERR=${OUT#fail: state=started rc=1: }
[ "${#ERR}" -le 300 ] && [ "${#ERR}" -ge 290 ] && ok || bad "F3: error part is ${#ERR} chars"
[ "$(calls)" = 1 ] && ok || bad "F3: fly calls $(calls)"
# a clean flyctl rc with a non-stopped read-back is still a fail
printf 'running\nstopping\n' > "$T/states"
run box_ops_fly_stop m1abcdef alpha alpha-pool
[ "$RC" -eq 1 ] && case "$OUT" in "fail: state=stopping rc=0"*) true ;; *) false ;; esac && ok || bad "F3b: rc=$RC out='$OUT'"

# --- F4. another project's app / unknown project = refused, nothing called -----
printf 'started\nstopped\n' > "$T/states"
for fn in box_ops_fly_stop box_ops_fly_destroy; do
  run "$fn" m1abcdef alpha beta-pool
  [ "$RC" -eq 1 ] && ok || bad "F4: $fn beta-pool rc=$RC"
  [ "$OUT" = "refused: app beta-pool is not an app of alpha" ] && ok || bad "F4: $fn stdout '$OUT'"
  [ "$(calls)" = 0 ] && [ "$(scalls)" = 0 ] && ok || bad "F4: $fn called fly=$(calls) state=$(scalls)"
  run "$fn" m1abcdef gamma gamma-pool
  [ "$RC" -eq 1 ] && [ "$OUT" = "refused: unknown project gamma" ] && ok || bad "F4: $fn gamma rc=$RC out='$OUT'"
  [ "$(calls)" = 0 ] && [ "$(scalls)" = 0 ] && ok || bad "F4: $fn gamma called something"
done
# stop through the builder app is refused: its read-back cannot be checked (A1)
run box_ops_fly_stop m1abcdef alpha alpha-builder
[ "$RC" -eq 1 ] && [ "$OUT" = "refused: stop read-back only covers the pool app" ] && [ "$(calls)" = 0 ] && ok || bad "F4b: rc=$RC out='$OUT'"

# --- F5. no token = not configured, no call; fly.env is the fallback -----------
( unset FLY_API_TOKEN_ALPHA
  run box_ops_fly_stop m1abcdef alpha alpha-pool
  [ "$RC" -eq 1 ] && [ "$OUT" = "not configured: FLY_API_TOKEN_ALPHA" ] && ok || bad "F5: rc=$RC out='$OUT'"
  [ "$(calls)" = 0 ] && [ "$(scalls)" = 0 ] && ok || bad "F5: something called"
  echo 'FLY_API_TOKEN_ALPHA=fromfile' > "$H/env/fly.env"
  FAKE_FLY_RC=0 run box_ops_fly_destroy m1abcdef alpha alpha-pool
  [ "$RC" -eq 0 ] && grep -q 'token=present' "$T/fly-calls" && ok || bad "F5b: fly.env fallback rc=$RC out='$OUT'"
  rm -f "$H/env/fly.env"
  echo "$PASS $FAIL" > "$T/sub" ); read -r PASS FAIL < "$T/sub"

# --- D1. destroy ok --------------------------------------------------------------
FAKE_FLY_RC=0 run box_ops_fly_destroy m1abcdef alpha alpha-pool
[ "$RC" -eq 0 ] && [ "$OUT" = destroyed ] && ok || bad "D1: rc=$RC out='$OUT'"
[ "$(cat "$T/fly-calls")" = "machine destroy m1abcdef -a alpha-pool --force token=present" ] && ok || bad "D1: fly calls '$(cat "$T/fly-calls")'"
# the builder app is an app of alpha, so destroy through it is allowed
FAKE_FLY_RC=0 run box_ops_fly_destroy m1abcdef alpha alpha-builder
[ "$RC" -eq 0 ] && [ "$(cat "$T/fly-calls")" = "machine destroy m1abcdef -a alpha-builder --force token=present" ] && ok || bad "D1b: rc=$RC out='$OUT'"

# --- D2. not-found output = already gone; a generic error is a fail --------------
FAKE_FLY_OUT="Error: machine m1abcdef was not found in app alpha-pool" FAKE_FLY_RC=1 run box_ops_fly_destroy m1abcdef alpha alpha-pool
[ "$RC" -eq 0 ] && [ "$OUT" = "already gone" ] && ok || bad "D2: rc=$RC out='$OUT'"
FAKE_FLY_OUT="Error: unauthorized" FAKE_FLY_RC=1 run box_ops_fly_destroy m1abcdef alpha alpha-pool
[ "$RC" -eq 1 ] && [ "$OUT" = "fail: rc=1: Error: unauthorized" ] && ok || bad "D2b: rc=$RC out='$OUT'"
FAKE_FLY_OUT="" FAKE_FLY_RC=124 run box_ops_fly_destroy m1abcdef alpha alpha-pool
[ "$RC" -eq 1 ] && [ "$OUT" = "fail: rc=124: timeout after 60s" ] && ok || bad "D2c: rc=$RC out='$OUT'"

# --- D3. the builder machine = refused, no call ----------------------------------
run box_ops_fly_destroy bld00001 alpha alpha-pool
[ "$RC" -eq 1 ] && [ "$OUT" = "refused: alpha builder machine" ] && [ "$(calls)" = 0 ] && ok || bad "D3: rc=$RC out='$OUT'"

# --- D4. a machine named by a live pool job = refused, no call -------------------
run box_ops_fly_destroy job00001 alpha alpha-pool
[ "$RC" -eq 1 ] && [ "$(calls)" = 0 ] && case "$OUT" in "refused: live pool job "*job00001.json) true ;; *) false ;; esac && ok || bad "D4: rc=$RC out='$OUT'"
echo '{"machine":"job00002","key":"BH-2"}' > "$H/state/fly-pool/alpha/other.json"
run box_ops_fly_destroy job00002 alpha alpha-pool
[ "$RC" -eq 1 ] && [ "$(calls)" = 0 ] && case "$OUT" in "refused: live pool job "*other.json) true ;; *) false ;; esac && ok || bad "D4b: rc=$RC out='$OUT'"
rm -f "$H/state/fly-pool/alpha/other.json"
# .sweep.json names m1abcdef, and it is not a job record
FAKE_FLY_RC=0 run box_ops_fly_destroy m1abcdef alpha alpha-pool
[ "$RC" -eq 0 ] && [ "$(calls)" = 1 ] && ok || bad "D4c: .sweep.json refused rc=$RC out='$OUT'"
: > "$T/fly-calls"
OUT=$( ( shopt -s dotglob; export HARNESS="$H" PATH="$T/fakebin:$PATH" FAKE_FLY_RC=0; . "$LIB"; box_ops_fly_destroy m1abcdef alpha alpha-pool ) 2>/dev/null ); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = destroyed ] && ok || bad "D4c: .sweep.json refused under dotglob rc=$RC out='$OUT'"
# an unparseable record or builder state fails closed
echo 'not json' > "$H/state/fly-pool/alpha/broken.json"
run box_ops_fly_destroy m1abcdef alpha alpha-pool
[ "$RC" -eq 1 ] && [ "$(calls)" = 0 ] && case "$OUT" in "refused: cannot read pool record "*broken.json) true ;; *) false ;; esac && ok || bad "D4d: rc=$RC out='$OUT'"
rm -f "$H/state/fly-pool/alpha/broken.json"
cp "$H/state/fly/alpha.json" "$T/alpha.json.bak"; echo 'not json' > "$H/state/fly/alpha.json"
run box_ops_fly_destroy m1abcdef alpha alpha-pool
[ "$RC" -eq 1 ] && [ "$(calls)" = 0 ] && [ "$OUT" = "refused: cannot read builder state" ] && ok || bad "D4e: rc=$RC out='$OUT'"
cp "$T/alpha.json.bak" "$H/state/fly/alpha.json"

# --- D5. a bad machine id = refused, no call, never echoed -----------------------
for fn in box_ops_fly_stop box_ops_fly_destroy; do
  printf 'started\nstopped\n' > "$T/states"
  run "$fn" 'abc12345;rm' alpha alpha-pool
  [ "$RC" -eq 1 ] && [ "$OUT" = "refused: bad machine id" ] && ok || bad "D5: $fn rc=$RC out='$OUT'"
  [ "$(calls)" = 0 ] && [ "$(scalls)" = 0 ] && ok || bad "D5: $fn called something"
  run "$fn" ABC12345 alpha alpha-pool
  [ "$RC" -eq 1 ] && [ "$OUT" = "refused: bad machine id" ] && ok || bad "D5b: $fn uppercase id rc=$RC out='$OUT'"
done

# --- E1. no args under set -u: one refused line, the caller survives -------------
for fn in box_ops_fly_stop box_ops_fly_destroy; do
  OUT=$( ( set -u; export HARNESS="$H" PATH="$T/fakebin:$PATH"; . "$LIB"; "$fn"; echo "alive rc=$?" ) 2>/dev/null )
  [ "$OUT" = "refused: bad machine id
alive rc=1" ] && ok || bad "E1: $fn with no args got '$OUT'"
done

# --- NR. BH-2613 root contract (docs/notes/2026-09-26-BH-2613-lib-root-resolution.md):
# the root is ${HARNESS:-${H:-}}, never a /root/harness literal (bin/box-ops.sh,
# the entry point, owns that default and exports HARNESS). The caller's H is
# honoured when HARNESS is empty; with neither, both verbs refuse before any
# call and no path is built from the empty root.
printf 'stopped\n' > "$T/states"; : > "$T/fly-calls"; : > "$T/state-calls"
OUT=$( ( set -u; unset HARNESS; export PATH="$T/fakebin:$PATH"; . "$LIB"; box_ops_fly_stop m1abcdef alpha alpha-pool ) 2>/dev/null ); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = "already stopped" ] && ok || bad "NR1: the caller's H is the root: rc=$RC out='$OUT'"
for fn in box_ops_fly_stop box_ops_fly_destroy; do
  : > "$T/fly-calls"; : > "$T/state-calls"
  OUT=$( ( set -u; unset HARNESS H; export PATH="$T/fakebin:$PATH"; . "$LIB"; "$fn" m1abcdef alpha alpha-pool; echo "alive rc=$?" ) 2>/dev/null )
  [ "$OUT" = "refused: no harness root
alive rc=1" ] && ok || bad "NR2: $fn with no root got '$OUT'"
  [ "$(calls)" = 0 ] && [ "$(scalls)" = 0 ] && ok || bad "NR2: $fn with no root called something"
done
! grep -nE '\$\{HARNESS:-/root/harness' "$LIB" >/dev/null && ok || bad "NR3: $LIB falls back to the /root/harness literal"

echo "box-ops-fly bh-2661: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
