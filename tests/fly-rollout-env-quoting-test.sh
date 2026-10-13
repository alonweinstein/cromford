#!/bin/bash
# tests/fly-rollout-env-quoting-test.sh — env/fly.env must never be left in a
# state that breaks the next reader's `source`.
#
# BH-666: a Fly token is `FlyV1 fm2_...` — it CONTAINS A SPACE, so the append
# has to be quoted (it is, since BH-490) and, more importantly, the rollout has
# to find out at WRITE time whether the line it just appended round-trips. Every
# script that reads env/fly.env (bin/fly-api.sh, bin/fly-dispatch.sh,
# bin/fly-pool.sh, bin/run-build.sh and friends) dies on a value the quoted form
# cannot carry, and the first symptom is somewhere else entirely.
#
# Case A is the regression pin on the quoting. Case B is the new guard: a token
# the file cannot carry is rejected, the file is restored byte-for-byte, and the
# project is skipped instead of "saved".
# Case C is the guard's OTHER half, and the one that needs a test of its own:
# B's value breaks the file at PARSE time, so `. "$1" || exit 1` alone rejects it
# and the round-trip COMPARE never decides anything. A `$`-bearing token parses
# fine and comes back SHORTER than it went in — only the compare catches that,
# and without it a silently truncated credential is saved and reported as
# success.
# Case D: the rollback is `cat "$BAK" >`, which truncates its target first, so a
# backup that never landed must stop the append instead of emptying the file.
# Run from anywhere: tests/fly-rollout-env-quoting-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/fly-rollout-fixture.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# ---------- A. a real-shaped token survives the round trip ----------
rollout_reset_knobs
rollout_fixture "$T/a" "$DIR"
TOKA='FlyV1 fm2_abc,def=='
export MINT_TOKEN="$TOKA" SMOKE_RESULT=SMOKE_OK
cp "$T/a/h/env/fly.env" "$T/a/fly.env.before"
rollout_run "$T/a" proj-x
RC=$?

# What a reader gets is the assertion — not what the line looks like.
GOT=$(env -i bash -c 'set -a; . "$1" || exit 1; printf %s "$FLY_API_TOKEN_PROJ_X"' _ "$T/a/h/env/fly.env" 2>/dev/null)
SRC_RC=$?
[ "$SRC_RC" = 0 ] \
  && ok || bad "A env/fly.env must still source cleanly after the append (rc $SRC_RC)"
[ "$GOT" = "$TOKA" ] \
  && ok || bad "A the token must round-trip byte-for-byte (got: [$GOT])"
[ "$(grep -c "^FLY_API_TOKEN_PROJ_X=\"$TOKA\"\$" "$T/a/h/env/fly.env")" = 1 ] \
  && ok || bad "A the appended line must be the quoted form, exactly once (got: $(grep -n 'FLY_API_TOKEN_PROJ_X' "$T/a/h/env/fly.env"))"
rollout_log "$T/a" | grep -q 'minted + appended' \
  && ok || bad "A a verified append must log that it happened"
[ "$RC" = 0 ] \
  && ok || bad "A a clean pass must exit 0 (got $RC)"
[ -e "$T/a/h/logs/ALERTS.log" ] \
  && bad "A a clean pass must write no ALERT (got: $(rollout_alerts "$T/a"))" || ok

# ---------- B. a token the file cannot carry is refused, not saved ----------
rollout_reset_knobs
rollout_fixture "$T/b" "$DIR"
export MINT_TOKEN='FlyV1 fm2_x"y' SMOKE_RESULT=SMOKE_OK
cp "$T/b/h/env/fly.env" "$T/b/fly.env.before"
rollout_run "$T/b" proj-x
RC=$?

cmp -s "$T/b/fly.env.before" "$T/b/h/env/fly.env" \
  && ok || bad "B a rejected append must leave env/fly.env byte-identical (diff: $(diff "$T/b/fly.env.before" "$T/b/h/env/fly.env" | tr '\n' ' '))"
env -i bash -c 'set -a; . "$1"' _ "$T/b/h/env/fly.env" >/dev/null 2>&1 \
  && ok || bad "B env/fly.env must still source cleanly for every script that reads it"
[ "$(rollout_alerts "$T/b" | grep -c REJECTED)" = 1 ] \
  && ok || bad "B exactly one ALERT must name the rejected append (got: $(rollout_alerts "$T/b"))"
[ -e "$T/b/h/flags/fly-pool-proj-x" ] \
  && bad "B a project whose token was never saved must not be enabled" || ok
[ "$RC" != 0 ] \
  && ok || bad "B a rejected append must make the pass exit non-zero (got $RC)"
grep -q 'minted + appended' <<<"$(rollout_log "$T/b")" \
  && bad "B the rollout must not claim it appended a line it rolled back" || ok

# ---------- C. a token that parses but does not come back whole ----------
rollout_reset_knobs
rollout_fixture "$T/c" "$DIR"
TOKC='FlyV1 fm2_a$b'
export MINT_TOKEN="$TOKC" SMOKE_RESULT=SMOKE_OK
cp "$T/c/h/env/fly.env" "$T/c/fly.env.before"
rollout_run "$T/c" proj-x
RC=$?

cmp -s "$T/c/fly.env.before" "$T/c/h/env/fly.env" \
  && ok || bad "C a value that does not round-trip must leave env/fly.env byte-identical (diff: $(diff "$T/c/fly.env.before" "$T/c/h/env/fly.env" | tr '\n' ' '))"
[ "$(grep -c FLY_API_TOKEN_PROJ_X "$T/c/h/env/fly.env")" = 0 ] \
  && ok || bad "C a truncated credential must never be saved (got: $(grep -n FLY_API_TOKEN_PROJ_X "$T/c/h/env/fly.env"))"
[ "$(rollout_alerts "$T/c" | grep -c REJECTED)" = 1 ] \
  && ok || bad "C exactly one ALERT must name the rejected append (got: $(rollout_alerts "$T/c"))"
[ "$RC" != 0 ] \
  && ok || bad "C a value that comes back short must make the pass exit non-zero (got $RC)"
grep -q 'minted + appended' <<<"$(rollout_log "$T/c")" \
  && bad "C the rollout must not claim it appended a line it rolled back" || ok
[ -e "$T/c/h/flags/fly-pool-proj-x" ] \
  && bad "C a project whose token was never saved must not be enabled" || ok

# ---------- D. no backup, no append ----------
rollout_reset_knobs
rollout_fixture "$T/d" "$DIR"
export MINT_TOKEN='FlyV1 fm2_minted' SMOKE_RESULT=SMOKE_OK MKTEMP_FAIL_FLYENV=1
cp "$T/d/h/env/fly.env" "$T/d/fly.env.before"
rollout_run "$T/d" proj-x
RC=$?

[ -s "$T/d/h/env/fly.env" ] \
  && ok || bad "D env/fly.env must never be truncated (size: $(wc -c < "$T/d/h/env/fly.env"))"
cmp -s "$T/d/fly.env.before" "$T/d/h/env/fly.env" \
  && ok || bad "D with no backup to put back, nothing may be appended (diff: $(diff "$T/d/fly.env.before" "$T/d/h/env/fly.env" | tr '\n' ' '))"
[ "$(rollout_alerts "$T/d" | grep -c 'back up env/fly.env')" = 1 ] \
  && ok || bad "D one ALERT must say the backup is what failed (got: $(rollout_alerts "$T/d"))"
[ "$RC" != 0 ] \
  && ok || bad "D a token that could not be stored must make the pass exit non-zero (got $RC)"
[ -e "$T/d/h/flags/fly-pool-proj-x" ] \
  && bad "D a project whose token was never saved must not be enabled" || ok

# ---------- E. no backup AND a value that would be rolled back ----------
# The two failures together are what empties env/fly.env: the append lands, the
# verify rejects it, and `cat "$BAK" >` truncates the file it then cannot fill.
rollout_reset_knobs
rollout_fixture "$T/e" "$DIR"
export MINT_TOKEN='FlyV1 fm2_a$b' SMOKE_RESULT=SMOKE_OK MKTEMP_FAIL_FLYENV=1
cp "$T/e/h/env/fly.env" "$T/e/fly.env.before"
rollout_run "$T/e" proj-x
RC=$?

cmp -s "$T/e/fly.env.before" "$T/e/h/env/fly.env" \
  && ok || bad "E env/fly.env must survive both failures at once (diff: $(diff "$T/e/fly.env.before" "$T/e/h/env/fly.env" | tr '\n' ' '))"
env -i bash -c 'set -a; . "$1"' _ "$T/e/h/env/fly.env" >/dev/null 2>&1 \
  && ok || bad "E env/fly.env must still source cleanly for every script that reads it"
[ "$RC" != 0 ] \
  && ok || bad "E the pass must exit non-zero (got $RC)"

echo "fly-rollout-env-quoting-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
