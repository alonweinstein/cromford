#!/bin/bash
# tests/fast-lints-list.bh-3860-test.sh — bin/fast-lints.sh --list and its
# CLI contract (BH-3860.0 / BH-3861).
#
# Every case drives the real bin/fast-lints.sh and the real bin/test-impact.sh,
# copied into a fixture repo with its own always-list, rules pack and
# durations file (FAST_LINTS_DURATIONS). HARNESS points at an empty tree so no
# live settings row reaches a knob.
#   A4   the join: <= MAX, --max-s, FAST_LINTS_MAX_S, unmeasured (median
#        stand-in, BH-5292), 0.0, boundary
#   A5   rules-pack suites dropped; always-set failing/empty -> rc 2, no stdout;
#        a bad knob value falls back to 10
#   A8   registry defaults == code fallbacks, both knobs read_in the script
#   A9   identical output under mawk
#   A10  no gh command word
#   S1-6 bad args -> rc 2
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REAL="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

mkdir -p "$T/h"
export HARNESS="$T/h"
unset FAST_LINTS_MAX_S FAST_LINTS_BUDGET_S PROJECT

N=0
fx() { # fx -> sets F to a fresh fixture repo
  N=$((N + 1)); F="$T/f$N"
  mkdir -p "$F/bin" "$F/catalog" "$F/tests"
  git -C "$F" init -q
  cp "$REAL/bin/fast-lints.sh" "$REAL/bin/test-impact.sh" "$F/bin/"
  local s
  for s in a b new-x rp; do printf '#!/bin/bash\nexit 0\n' > "$F/tests/$s-test.sh"; done
  printf '# fixture always list\ntests/a-test.sh a\ntests/b-test.sh b\ntests/new-x-test.sh x\ntests/rp-test.sh rp\n' \
    > "$F/catalog/test-impact-always.txt"
  printf '# fixture rules pack\nrp\ttree\tsuite\ttests/rp-test.sh --x\t-\treason\nac\ttree\tcmd\tbin/x tests/a-test.sh\t-\treason\n' \
    > "$F/catalog/rules-pack.tsv"
}
dur() { # dur <rows...> each "name secs" -> $F/dur.tsv
  : > "$F/dur.tsv"
  local r
  for r in "$@"; do printf 'tests/%s-test.sh\t%s\t1\n' "${r% *}" "${r#* }" >> "$F/dur.tsv"; done
}
run() { # run [args...] -> RC, $F/out, $F/err
  FAST_LINTS_DURATIONS="$F/dur.tsv" "$F/bin/fast-lints.sh" "$@" > "$F/out" 2> "$F/err"
  RC=$?
}
has()  { grep -qxF "$1" "$F/out"; }
errl() { cat "$F/err"; }

echo "A4: the join"
fx; dur "a 1.0" "b 2.0" "new-x 3.0" "rp 1.0"; run --list
want=$'tests/a-test.sh\ntests/b-test.sh\ntests/new-x-test.sh'
[ "$RC" = 0 ] && [ "$(cat "$F/out")" = "$want" ] && ok "A4a stdout sorted, rc 0" || bad "A4a rc=$RC out=$(cat "$F/out")"
[ "$(errl)" = "fast-lints: 3 of 4 always-suites at <=10s; unmeasured: none; over: 0" ] \
  && ok "A4a stderr summary" || bad "A4a stderr=$(errl)"
A4A_OUT=$(cat "$F/out")
A4A_F=$F

fx; dur "a 1.0" "b 2.0" "new-x 12.0" "rp 1.0"; run --list
[ "$RC" = 0 ] && ! has tests/new-x-test.sh && grep -q 'over: 1$' "$F/err" \
  && ok "A4b 12.0 > 10 dropped, over: 1" || bad "A4b rc=$RC err=$(errl)"
FAST_LINTS_MAX_S=15 run --list
[ "$RC" = 0 ] && has tests/new-x-test.sh && grep -q 'at <=15s' "$F/err" \
  && ok "A4c FAST_LINTS_MAX_S=15 keeps it" || bad "A4c rc=$RC err=$(errl)"
run --list --max-s 15
[ "$RC" = 0 ] && has tests/new-x-test.sh && grep -q 'at <=15s' "$F/err" \
  && ok "A4d --max-s 15 keeps it" || bad "A4d rc=$RC err=$(errl)"

# TEST-CHANGE BH-5292: was "no row -> unmeasured, named, LEFT OUT". the operator changed
# the rule (2026-10-07): a missing row weighs the file's median, the stand-in the
# shard split already uses, so the suite still runs. It is still named.
fx; dur "a 1.0" "b 2.0" "rp 1.0"; run --list
[ "$RC" = 0 ] && has tests/new-x-test.sh && grep -q 'unmeasured: tests/new-x-test.sh;' "$F/err" \
  && ok "A4e no row -> median 1.0 <= 10, in the set, named unmeasured" || bad "A4e rc=$RC err=$(errl)"
dur "a 11.0" "b 12.0" "rp 13.0"; run --list
[ "$RC" = 0 ] && ! has tests/new-x-test.sh && grep -q 'unmeasured: tests/new-x-test.sh;' "$F/err" \
  && ok "A4e' no row -> median 12.0 > 10, left out, named" || bad "A4e' rc=$RC out=$(cat "$F/out") err=$(errl)"
: > "$F/dur.tsv"; run --list
[ "$RC" = 0 ] && [ ! -s "$F/out" ] && grep -q 'unmeasured: tests/a-test.sh tests/b-test.sh tests/new-x-test.sh;' "$F/err" \
  && ok "A4e'' an empty durations file has no median: everything unmeasured, nothing listed" || bad "A4e'' rc=$RC out=$(cat "$F/out") err=$(errl)"
dur "a 1.0" "b 2.0" "new-x n/a" "rp 1.0"; run --list
[ "$RC" = 0 ] && ! has tests/new-x-test.sh && grep -q 'unmeasured: tests/new-x-test.sh;' "$F/err" \
  && ok "A4f n/a -> unmeasured, named" || bad "A4f rc=$RC err=$(errl)"
dur "a 1.0" "b 2.0" "new-x 0.0" "rp 1.0"; run --list
[ "$RC" = 0 ] && has tests/new-x-test.sh && ok "A4g 0.0 is fast" || bad "A4g rc=$RC out=$(cat "$F/out")"
dur "a 1.0" "b 2.0" "new-x 10.0" "rp 1.0"; run --list
[ "$RC" = 0 ] && has tests/new-x-test.sh && ok "A4g 10.0 at MAX 10 is fast (<=)" || bad "A4g boundary rc=$RC out=$(cat "$F/out")"

echo "A5: rules pack, broken always set, bad knob"
fx; dur "a 1.0" "b 2.0" "new-x 1.0" "rp 0.5"; run --list
[ "$RC" = 0 ] && ! has tests/rp-test.sh && has tests/a-test.sh \
  && ok "A5a rules-pack suite dropped, cmd row ignored" || bad "A5a rc=$RC out=$(cat "$F/out")"
grep -q '^fast-lints: 3 of 4 always-suites at <=10s; unmeasured: none; over: 0$' "$F/err" \
  && ok "A5a dropped suite is neither unmeasured nor over" || bad "A5a err=$(errl)"

fx; dur "a 1.0" "b 2.0" "new-x 1.0" "rp 1.0"
printf '#!/bin/bash\nexit 1\n' > "$F/bin/test-impact.sh"; run --list
[ "$RC" = 2 ] && [ ! -s "$F/out" ] && grep -q 'always-suite set is unavailable' "$F/err" \
  && ok "A5b always rc 1 -> rc 2, empty stdout" || bad "A5b rc=$RC err=$(errl)"
printf '#!/bin/bash\nexit 0\n' > "$F/bin/test-impact.sh"; run --list
[ "$RC" = 2 ] && [ ! -s "$F/out" ] && ok "A5b' always empty -> rc 2, empty stdout" || bad "A5b' rc=$RC err=$(errl)"
printf '#!/bin/bash\necho tests/a-test.sh\nexit 1\n' > "$F/bin/test-impact.sh"; run --list
[ "$RC" = 2 ] && [ ! -s "$F/out" ] && grep -q 'rc=1' "$F/err" \
  && ok "A5b''' always prints then fails -> rc 2, empty stdout" || bad "A5b''' rc=$RC out=$(cat "$F/out") err=$(errl)"
printf '#!/bin/bash\nprintf "tests/b-test.sh\\ntests/a-test.sh\\ntests/a-test.sh\\n"\n' > "$F/bin/test-impact.sh"; run --list
[ "$RC" = 0 ] && [ "$(cat "$F/out")" = $'tests/a-test.sh\ntests/b-test.sh' ] \
  && ok "A4h stdout is sort -u even when the always set is not" || bad "A4h rc=$RC out=$(cat "$F/out")"
rm -f "$F/bin/test-impact.sh"; run --list
[ "$RC" = 2 ] && [ ! -s "$F/out" ] && ok "A5b'' test-impact.sh missing -> rc 2" || bad "A5b'' rc=$RC err=$(errl)"

fx; dur "a 1.0" "b 11.0" "new-x 10.0" "rp 1.0"
for v in abc 0 -3; do
  FAST_LINTS_MAX_S=$v run --list
  [ "$RC" = 0 ] && has tests/new-x-test.sh && ! has tests/b-test.sh && grep -q 'at <=10s' "$F/err" \
    && ok "A5c FAST_LINTS_MAX_S=$v falls back to 10" || bad "A5c $v rc=$RC err=$(errl)"
done

echo "A8: registry defaults == code fallbacks"
for pair in FAST_LINTS_MAX_S:10 FAST_LINTS_BUDGET_S:159; do
  k=${pair%%:*} d=${pair#*:}
  reg=$(jq -r --arg k "$k" '.knobs[]|select(.env==$k)|"\(.default) \(.read_in)"' "$REAL/catalog/lanes.d/fly-pool.json")
  [ "$reg" = "$d bin/fast-lints.sh" ] && ok "A8 $k registry: $reg" || bad "A8 $k registry='$reg'"
  code=$(grep -oE "fl_knob $k [0-9]+" "$REAL/bin/fast-lints.sh" | awk '{print $3}' | sort -u)
  [ -n "$code" ] && [ "$code" = "$d" ] && ok "A8 $k code fallback $code" || bad "A8 $k code fallback='$code'"
done

echo "A9: mawk"
if command -v mawk >/dev/null 2>&1; then
  mkdir -p "$T/mbin"; ln -sf "$(command -v mawk)" "$T/mbin/awk"
  F=$A4A_F; dur "a 1.0" "b 2.0" "new-x 3.0" "rp 1.0"
  PATH="$T/mbin:$PATH" run --list
  [ "$RC" = 0 ] && [ "$(cat "$F/out")" = "$A4A_OUT" ] && ok "A9 identical under mawk" || bad "A9 rc=$RC out=$(cat "$F/out")"
else
  echo "  skip: no mawk"
fi

echo "A10: no gh call"
if [ ! -s "$REAL/bin/fast-lints.sh" ]; then bad "A10 bin/fast-lints.sh missing"
elif grep -vE '^[[:space:]]*#' "$REAL/bin/fast-lints.sh" | grep -qwE 'gh'; then bad "A10 a gh word in code"
else ok "A10 no gh word"; fi

echo "S: the verbs are no longer stubs; bad args"
fx; dur "a 1.0"
run --assert-budget "$T/no-such-timings.tsv"
[ "$RC" = 2 ] && ! grep -q 'not implemented' "$F/err" && ok "assert-budget on a missing file rc 2, not a stub" \
  || bad "assert-budget missing rc=$RC err=$(errl)"
for args in "" "--nope" "--list --max-s" "--list --max-s 0" "--list --max-s x" "--assert-budget" "--list --bogus" "--run --out"; do
  # shellcheck disable=SC2086
  run $args
  [ "$RC" = 2 ] && grep -qi 'usage' "$F/err" && [ ! -s "$F/out" ] && ok "bad args '$args' rc 2 usage" || bad "bad args '$args' rc=$RC err=$(errl)"
done

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
