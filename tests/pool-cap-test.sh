#!/bin/bash
# tests/pool-cap-test.sh — bin/pool-cap.sh resolution order. exit 0 = all pass
#
# Since 2026-09-14 the default is UNLIMITED (0), not 3: the pool sizes itself to
# the queue and an explicit number is a cost-safety ceiling nobody has to write.
# The kill flag POOL_AUTOSCALE=0 must give the pre-2026-09-14 answer for every
# one of these inputs, so each case is asserted twice.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T"; mkdir -p "$T/flags" "$T/fly" "$T/env"
unset POOL_AUTOSCALE POOL_CAP_MAX
PASS=0; FAIL=0; ok() { PASS=$((PASS+1)); }; bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
cap() { "$DIR/bin/pool-cap.sh" p; }
off() { POOL_AUTOSCALE=0 "$DIR/bin/pool-cap.sh" p; }   # the kill flag's answer

# ── the ladder ──────────────────────────────────────────────────────────────
[ "$(cap)" = 0 ] && ok || bad "nothing configured → 0 = unlimited (got $(cap))"
[ "$(off)" = 3 ] && ok || bad "POOL_AUTOSCALE=0: nothing configured → 3 (got $(off))"
printf '# comment\nother 9\np 5\n' > "$T/fly/pool-caps.conf"
[ "$(cap)" = 5 ] && ok || bad "conf line wins over the default (got $(cap))"
[ "$(off)" = 5 ] && ok || bad "POOL_AUTOSCALE=0: conf line still wins (got $(off))"
touch "$T/flags/fly-pool-p"
[ "$(cap)" = 5 ] && ok || bad "an EMPTY flag file (enable switch) keeps the conf value (got $(cap))"
echo 2 > "$T/flags/fly-pool-p"
[ "$(cap)" = 2 ] && ok || bad "a NUMBER in the flag file overrides the conf (got $(cap))"
[ "$(off)" = 2 ] && ok || bad "POOL_AUTOSCALE=0: a NUMBER in the flag file still overrides (got $(off))"
printf 'p 7x\n' > "$T/fly/pool-caps.conf"; : > "$T/flags/fly-pool-p"
[ "$(cap)" = 7 ] && ok || bad "digits only from a conf value (got $(cap))"
printf 'pp 8\n' > "$T/fly/pool-caps.conf"
[ "$(cap)" = 0 ] && ok || bad "a prefix match is not a match — unlimited (got $(cap))"
[ "$(off)" = 3 ] && ok || bad "POOL_AUTOSCALE=0: a prefix match is not a match — 3 (got $(off))"

# ── POOL_CAP_MAX: the one OTHER ceiling (env/global.env) ────────────────────
: > "$T/fly/pool-caps.conf"; : > "$T/flags/fly-pool-p"
printf 'HARNESS_SECRET=x\nPOOL_CAP_MAX=12\n' > "$T/env/global.env"
[ "$(cap)" = 12 ] && ok || bad "POOL_CAP_MAX trims unlimited to itself (got $(cap))"
echo 40 > "$T/flags/fly-pool-p"
[ "$(cap)" = 12 ] && ok || bad "POOL_CAP_MAX trims a per-project number above it (got $(cap))"
echo 4 > "$T/flags/fly-pool-p"
[ "$(cap)" = 4 ] && ok || bad "POOL_CAP_MAX is a ceiling, never a floor (got $(cap))"
[ "$(off)" = 4 ] && ok || bad "POOL_AUTOSCALE=0: the flag number stands (got $(off))"
: > "$T/flags/fly-pool-p"
[ "$(POOL_CAP_MAX=3 "$DIR/bin/pool-cap.sh" p)" = 3 ] \
  && ok || bad "POOL_CAP_MAX from the ENVIRONMENT wins over the file"
# The kill flag must not consult POOL_CAP_MAX at all — that is what
# "byte-for-byte today's behaviour" means for a knob that did not exist.
[ "$(off)" = 3 ] && ok || bad "POOL_AUTOSCALE=0 must ignore POOL_CAP_MAX (got $(off))"
printf 'HARNESS_SECRET=x\nPOOL_CAP_MAX=12\nPOOL_AUTOSCALE=0\n' > "$T/env/global.env"
[ "$(cap)" = 3 ] && ok || bad "POOL_AUTOSCALE=0 read from env/global.env, not only from the env (got $(cap))"

# ── --autoscale: the one reader of the knob ────────────────────────────────
[ "$("$DIR/bin/pool-cap.sh" --autoscale)" = 0 ] \
  && ok || bad "--autoscale must report 0 when global.env turns it off"
printf 'HARNESS_SECRET=x\n' > "$T/env/global.env"
[ "$("$DIR/bin/pool-cap.sh" --autoscale)" = 1 ] \
  && ok || bad "--autoscale must report 1 by default"
[ "$(POOL_AUTOSCALE=0 "$DIR/bin/pool-cap.sh" --autoscale)" = 0 ] \
  && ok || bad "--autoscale must honour the environment"
# A secret in global.env is never echoed by a script whose whole output is a
# number a caller interpolates into a log line.
printf 'HARNESS_SECRET=hunter2\nCLAUDE_CODE_OAUTH_TOKEN=sk-abc\nPOOL_CAP_MAX=6\n' > "$T/env/global.env"
case "$(cap)$("$DIR/bin/pool-cap.sh" --autoscale)" in *hunter2*|*sk-abc*) bad "global.env leaked into stdout" ;; *) ok ;; esac

# ── the repo's own conf ────────────────────────────────────────────────────
# It carries no project lines any more (2026-09-14): unlimited is the default and
# a line here is a hard ceiling written on purpose. Every line that IS there must
# still parse to a number, and resolve to itself. Derived from the conf, never
# a named live project: pinning `project-5` to 0 meant the day someone wrote a
# ceiling for it on purpose, this suite had to be edited too (it was, 5 -> 20).
UNLISTED=pool-cap-test-unlisted
grep -qE "^[[:space:]]*$UNLISTED[[:space:]]" "$DIR/fly/pool-caps.conf" && UNLISTED="$UNLISTED-x"
[ "$(HARNESS="$DIR" "$DIR/bin/pool-cap.sh" "$UNLISTED")" = 0 ] \
  && ok || bad "repo conf: an unlisted project must resolve to 0 = unlimited"
while read -r P N; do
  [ "$(HARNESS="$DIR" "$DIR/bin/pool-cap.sh" "$P")" = "$N" ] \
    && ok || bad "repo conf: project $P is listed at $N but pool-cap.sh resolves $(HARNESS="$DIR" "$DIR/bin/pool-cap.sh" "$P")"
done < <(grep -vE '^\s*(#|$)' "$DIR/fly/pool-caps.conf" | awk 'NF == 2 && $2 ~ /^[0-9]+$/')
BADLINE=$(grep -vE '^\s*(#|$)' "$DIR/fly/pool-caps.conf" | awk 'NF != 2 || $2 !~ /^[0-9]+$/ { print; exit }')
[ -z "$BADLINE" ] && ok || bad "repo conf: unparseable line '$BADLINE'"

echo "pool-cap: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
